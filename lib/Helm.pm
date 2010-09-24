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
use Carp qw(croak);
use Fcntl qw(:flock);
use File::Basename qw(basename);

our $VERION = 0.1;

enum NOTIFY_LEVEL => qw(debug info warn error fatal);
enum LOCK_TYPE    => qw(none local remote both);
has task              => (is => 'ro', writer => '_task',              required => 1);
has extra_options     => (is => 'ro', isa    => 'HashRef',            default  => sub { {} });
has config_uri        => (is => 'ro', writer => '_config_uri',        isa      => 'Str');
has config            => (is => 'ro', writer => '_config',            isa      => 'Helm::Conf');
has sudo              => (is => 'ro', writer => '_sudo',              isa      => 'Str');
has lock_type         => (is => 'ro', writer => '_lock_type',         isa      => 'LOCK_TYPE');
has local_lock_handle => (is => 'ro', writer => '_local_lock_handle', isa      => 'FileHandle');
has sleep             => (is => 'ro', writer => '_sleep',             isa      => 'Num');
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
has notifies => (
    is      => 'ro',
    writer  => '_notifies',
    isa     => 'ArrayRef',
    default => sub { [] },
);
has notify_level => (
    is      => 'ro',
    writer  => '_notify_level',
    isa     => 'NOTIFY_LEVEL',
    default => 'info',
);

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

    # TODO - expand any notify URIs into objects
    
}

sub steer {
    my $self = shift;
    my $task = $self->task;

    # make sure it's a task we know about and can load
    my $task_class = "Helm::Task::$task";
    eval "require $task_class";

    # TODO - different exception if we can't find the module vs can't compile it
    if( $@ ) {
        if( $@ =~ /Can't locate Helm\/Task\/$task.pm/ ) {
            croak("Unknown task $task");
        } else {
            croak("Could not load module $task_class for $task");
        }
    }

    my $task_obj = $task_class->new($self);
    $task_obj->validate();

    # make sure have a local lock if we need it
    croak("Cannot obtain a local helm lock. Is another helm process running?")
      if ($self->lock_type eq 'local' || $self->lock_type eq 'both') && !$self->_get_local_lock;

    # make sure we can connect to all of the servers
    my %ssh_connections;
    my @servers = @{$self->servers};
    foreach my $server (@servers) {
        my $ssh = Net::OpenSSH->new(
            $server,
            ctl_dir     => catdir(File::HomeDir->my_home, '.helm'),
            strict_mode => 0,
        );
        $ssh->error && croak("Can't ssh to $server: " . $ssh->error);
        $ssh_connections{$server} = $ssh;
    }

    my $fat_line = '=' x 70;
    my $thin_line = '-' x 70;
    foreach my $i (0..$#servers) {
        my $server = $servers[$i];
        warn "$server\n$fat_line\n";
        $task_obj->execute(
            ssh    => $ssh_connections{$server},
            server => $server,
        );
        warn "$thin_line\n";
        warn "\n" unless $i == $#servers;
        sleep($self->sleep) if $self->sleep;
    }

    # release the local lock
}

sub load_configuration {
    my ($class, $uri) = @_;
    $uri = try { 
        URI->new($uri) 
    } catch {
        croak("Invalid configuration URI $uri");
    };

    # try to load the right config module
    my $scheme = $uri->scheme;
    my $loader_class  = "Helm::Conf::Loader::$scheme";
    eval "require $loader_class";
    croak("Unknown config type: $scheme. Couldn't load $loader_class: $@") if $@;

    return $loader_class->load($uri);
}

sub _get_local_lock {
    my $self = shift;
    # lock the file so nothing else can run at the same time
    my $lock_handle;
    my $lock_file = $self->_local_lock_file();
    open($lock_handle, '>', $lock_file) or croak("Can't open $lock_file for locking: $!");
    if (flock($lock_handle, LOCK_EX | LOCK_NB)) {
        $self->_local_lock_handle($lock_handle);
        return 1;
    } else {
        return 0;
    }
}

sub _release_local_lock {
    my $self = shift;
    close($self->_local_lock_handle) if $self->_local_lock_handle;
}

sub _local_lock_file {
    my $self = shift;
    return catfile(tmpdir(), 'helm.lock');
}

__PACKAGE__->meta->make_immutable;

1;
