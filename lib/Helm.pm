package Helm;
use strict;
use warnings;
use Moose;
use Moose::Util::TypeConstraints qw(enum);
use URI;
use namespace::autoclean;
use Try::Tiny;
use File::Spec::Functions qw(catdir catfile tmpdir);
use File::HomeDir;
use Net::OpenSSH;
use Fcntl qw(:flock);
use File::Basename qw(basename);
use Carp qw(croak);
use Helm::Notify;

our $VERION = 0.1;

enum NOTIFY_LEVEL => qw(debug info warn error);
enum LOCK_TYPE    => qw(none local remote both);

has task           => (is => 'ro', writer => '_task',           required => 1);
has extra_options  => (is => 'ro', isa    => 'HashRef',         default  => sub { {} });
has config_uri     => (is => 'ro', writer => '_config_uri',     isa      => 'Str');
has config         => (is => 'ro', writer => '_config',         isa      => 'Helm::Conf');
has sudo           => (is => 'ro', writer => '_sudo',           isa      => 'Str');
has lock_type      => (is => 'ro', writer => '_lock_type',      isa      => 'LOCK_TYPE');
has sleep          => (is => 'ro', writer => '_sleep',          isa      => 'Num');
has current_server => (is => 'ro', writer => '_current_server', isa      => 'Str');
has notify         => (is => 'ro', writer => '_notify',         isa      => 'Helm::Notify');
has local_lock_handle => (is => 'ro', writer => '_local_lock_handle', isa => 'FileHandle|Undef');
has servers    => (
    is      => 'ro',
    writer  => '_servers',
    isa     => 'ArrayRef',
    default => sub { [] },
);
has roles => (
    is      => 'ro',
    writer  => '_roles',
    isa     => 'ArrayRef[Str]',
    default => sub { [] },
);
has notify_level => (
    is      => 'ro',
    writer  => '_notify_level',
    isa     => 'NOTIFY_LEVEL',
    default => 'info',
);

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    my %args  = (@_ == 1 && ref $_[0] && ref $_[0] eq 'HASH') ? %{$_[0]} : @_;

    # allow "notifies" list of URIs to be passed into new() and then convert them into
    # a Helm::Notify object with various Helm::Notify::Channel objects
    if (my $notify_uris = delete $args{notifies}) {
        my $notify =
          Helm::Notify->new($args{notify_level} ? (notify_level => $args{notify_level}) : ());
        foreach my $uri (@$notify_uris) {
            # console is a special case
            $uri = 'console://blah' if $uri eq 'console';
            $uri = try {
                URI->new($uri);
            }
            catch {
                croak("Invalid notification URI $uri");
            };
            $notify->load_channel($uri);
        }
        $args{notify} = $notify;
    }

    return $class->$orig(%args);
};

sub BUILD {
    my $self = shift;

    # create a config object from the config URI string (if it's not already a config object)
    if ($self->config_uri && !$self->config ) {
        $self->_config($self->load_configuration($self->config_uri));
    }

    # if we have servers, let's fully expand their names in case we're using abbreviations
    my @servers = @{$self->servers};
    if(@servers) {
        if( my $config = $self->config ) {
            $self->_servers([map { $config->expand_server_name($_) } @servers]);
        }
    }

    # if we have any roles, then get the servers with those roles
    my @roles = @{$self->roles};
    if( @roles ) {
        croak("Can't specify roles without a config") if !$self->config;
        my @servers = @{$self->servers};
        push(@servers, $self->config->get_server_names_by_roles(@roles));
        $self->_servers(\@servers);
    }
    
    # if we still don't have any servers, then use 'em all
    @servers = @{$self->servers};
    if(!@servers) {
        croak("You must specify servers if you don't have a config") if !$self->config;
        $self->_servers([$self->config->get_all_server_names]);
    }
}

sub steer {
    my $self = shift;
    my $task = $self->task;

    # make sure it's a task we know about and can load
    my $task_class = "Helm::Task::$task";
    eval "require $task_class";

    if( $@ ) {
        if( $@ =~ /Can't locate Helm\/Task\/$task.pm/ ) {
            croak("Unknown task $task");
        } else {
            croak("Could not load module $task_class for $task");
        }
    }

    $self->notify->initialize($self);

    my $task_obj = $task_class->new($self);
    $task_obj->validate();

    # make sure have a local lock if we need it
    $self->die("Cannot obtain a local helm lock. Is another helm process running?")
      if ($self->lock_type eq 'local' || $self->lock_type eq 'both') && !$self->_get_local_lock;

    # execute the task for each server
    my @servers = @{$self->servers};
    foreach my $i (0..$#servers) {
        my $server = $servers[$i];
        $self->_current_server($server);

        $self->notify->debug("Setting up SSH connection to $server");
        my $ssh = Net::OpenSSH->new(
            $server,
            ctl_dir     => catdir(File::HomeDir->my_home, '.helm'),
            strict_mode => 0,
        );
        $ssh->error && croak("Can't ssh to $server: " . $ssh->error);

        $self->notify->start_server($server);

        # get a lock on the server if we need to
        $self->die("Cannot obtain remote lock on $server. Is another helm process working there?")
          if ($self->lock_type eq 'remote' || $self->lock_type eq 'both')
          && !$self->_get_remote_lock($ssh);

        $task_obj->execute(
            ssh    => $ssh,
            server => $server,
        );

        $self->notify->end_server($server);
        $self->_release_remote_lock($ssh);
        sleep($self->sleep) if $self->sleep;
    }

    # release the local lock
    $self->_release_local_lock();
    $self->notify->finalize($self);
}

sub load_configuration {
    my ($self, $uri) = @_;
    $uri = try { 
        URI->new($uri) 
    } catch {
        croak("Invalid configuration URI $uri");
    };

    # try to load the right config module
    my $scheme = $uri->scheme;
    croak("Unknown config type for $uri") unless $scheme;
    my $loader_class  = "Helm::Conf::Loader::$scheme";
    eval "require $loader_class";
    croak("Unknown config type: $scheme. Couldn't load $loader_class: $@") if $@;

    $self->notify->debug("Loading configuration for $uri from $loader_class");
    return $loader_class->load($uri);
}

sub _get_local_lock {
    my $self = shift;
    $self->notify->debug("Trying to acquire global local helm lock");
    # lock the file so nothing else can run at the same time
    my $lock_handle;
    my $lock_file = $self->_local_lock_file();
    open($lock_handle, '>', $lock_file) or croak("Can't open $lock_file for locking: $!");
    if (flock($lock_handle, LOCK_EX | LOCK_NB)) {
        $self->_local_lock_handle($lock_handle);
        $self->notify->debug("Local helm lock obtained");
        return 1;
    } else {
        return 0;
    }
}

sub _release_local_lock {
    my $self = shift;
    if($self->local_lock_handle) {
        $self->notify->debug("Releasing global local helm lock");
        close($self->local_lock_handle) 
    }
}

sub _local_lock_file {
    my $self = shift;
    return catfile(tmpdir(), 'helm.lock');
}

sub _get_remote_lock {
    my ($self, $ssh) = @_;
    my $server = $self->current_server;
    $self->notify->debug("Trying to obtain remote server lock for $server");

    # make sure the lock file on the server doesn't exist
    my $lock_file = $self->_remote_lock_file();
    my $output = $self->run_remote_command(
        ssh        => $ssh,
        command    => qq(if [ -e "/tmp/helm.remote.lock" ]; then echo "lock found"; else echo "no lock found"; fi),
        ssh_method => 'capture',
    );
    chomp($output);
    if( $output eq 'lock found') {
        return 0;
    } else {
        # XXX - there's a race condition here, not sure what the right fix is though
        $self->run_remote_command(ssh => $ssh, command => "touch $lock_file");
        $self->notify->debug("Remote server lock for $server obtained");
        return 1;
    }
}

sub _release_remote_lock {
    my ($self, $ssh) = @_;
    if( $self->lock_type eq 'remote' || $self->lock_type eq 'both' ) {
        $self->notify->debug("Releasing remote server lock for " . $self->current_server);
        my $lock_file = $self->_remote_lock_file();
        $self->run_remote_command(ssh => $ssh, command => "rm -f $lock_file");
    }
}

sub _remote_lock_file {
    my $self = shift;
    return catfile(tmpdir(), 'helm.remote.lock');
}

sub run_remote_command {
    my ($self, %args) = @_;
    my $ssh         = $args{ssh};
    my $ssh_options = $args{ssh_options} || {};
    my $cmd         = $args{command};
    my $ssh_method  = $args{ssh_method} || 'system';
    my $server      = $args{server} || $self->current_server;

    $self->notify->debug("Running remote command ($cmd) on server $server");
    $ssh->$ssh_method($ssh_options, $cmd)
      or $self->die("Can't execute command ($cmd) on server $server: " . $ssh->error);
}

sub die {
    my ($self, $msg) = @_;
    $self->notify->error($msg);
    exit(1);
}

__PACKAGE__->meta->make_immutable;

1;
