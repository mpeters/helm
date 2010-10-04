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
use Helm::Log;
use Helm::Server;
use Scalar::Util qw(blessed);

our $VERION = 0.1;

enum LOG_LEVEL => qw(debug info warn error);
enum LOCK_TYPE => qw(none local remote both);

has task           => (is => 'ro', writer => '_task',           required => 1);
has extra_options  => (is => 'ro', isa    => 'HashRef',         default  => sub { {} });
has extra_args     => (is => 'ro', isa    => 'ArrayRef',        default  => sub { [] });
has config_uri     => (is => 'ro', writer => '_config_uri',     isa      => 'Str');
has config         => (is => 'ro', writer => '_config',         isa      => 'Helm::Conf');
has sudo           => (is => 'ro', writer => '_sudo',           isa      => 'Str');
has lock_type      => (is => 'ro', writer => '_lock_type',      isa      => 'LOCK_TYPE');
has sleep          => (is => 'ro', writer => '_sleep',          isa      => 'Num');
has current_server => (is => 'ro', writer => '_current_server', isa      => 'Helm::Server');
has log            => (is => 'ro', writer => '_log',            isa      => 'Helm::Log');
has default_port   => (is => 'ro', writer => '_port',           isa      => 'Int');
has timeout        => (is => 'ro', writer => '_timeout',        isa      => 'Int');
has local_lock_handle  => (is => 'ro', writer => '_local_lock_handle',  isa => 'FileHandle|Undef');
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
has log_level => (
    is      => 'ro',
    writer  => '_log_level',
    isa     => 'LOG_LEVEL',
    default => 'info',
);

my %REGISTERED_MODULES = (
    task => {
        get       => 'Helm::Task::get',
        patch     => 'Helm::Task::patch',
        put       => 'Helm::Task::put',
        rsync_put => 'Helm::Task::rsync_put',
        run       => 'Helm::Task::run',
        exec      => 'Helm::Task::run',
    },
    log => {
        console => 'Helm::Log::Channel::console',
        file    => 'Helm::Log::Channel::file',
        mailto  => 'Helm::Log::Channel::email',
        irc     => 'Helm::Log::Channel::irc',
    },
    configuration => {helm => 'Helm::Conf::Loader::helm'},
);

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    my %args  = (@_ == 1 && ref $_[0] && ref $_[0] eq 'HASH') ? %{$_[0]} : @_;

    # allow "log" list of URIs to be passed into new() and then convert them into
    # a Helm::Log object with various Helm::Log::Channel objects
    if (my $log_uris = delete $args{log}) {
        my $log =
          Helm::Log->new($args{log_level} ? (log_level => $args{log_level}) : ());
        foreach my $uri (@$log_uris) {
            # console is a special case
            $uri = 'console://blah' if $uri eq 'console';
            $uri = try {
                URI->new($uri);
            } catch {
                CORE::die("Invalid log URI $uri");
            };
            my $scheme = $uri->scheme;
            CORE::die("Unknown log type for $uri") unless $scheme;
            my $log_class  = $REGISTERED_MODULES{log}->{$scheme};
            CORE::die("Unknown log type for $uri") unless $log_class;
            eval "require $log_class";

            if( $@ ) {
                my $log_class_file = $log_class;
                $log_class_file =~ s/::/\//g;
                if( $@ =~ /Can't locate \Q$log_class_file\E\.pm/ ) {
                    CORE::die("Can not find module $log_class for log type $scheme");
                } else {
                    CORE::die("Could not load module $log_class for log type $scheme: $@");
                }
            }
            $log->add_channel($log_class->new(uri => $uri, task => $args{task}));
        }
        $args{log} = $log;
    }

    return $class->$orig(%args);
};

sub BUILD {
    my $self = shift;

    $self->log->initialize($self);

    # create a config object from the config URI string (if it's not already a config object)
    if ($self->config_uri && !$self->config ) {
        $self->_config($self->load_configuration($self->config_uri));
    }

    # if we have servers let's turn them into Helm::Server objects, let's fully expand their names in case we're using abbreviations
    my @server_names = @{$self->servers};
    if(@server_names) {
        my @server_objs;
        foreach my $server_name (Helm::Server->expand_server_names(@server_names)) {
            # if it's already a Helm::Server just keep it
            if( ref $server_name && blessed($server_name) && $server_name->isa('Helm::Server') ) {
                push(@server_objs, $server_name);
            } elsif( my $config = $self->config ) {
                # with a config file we can find out more about these servers
                my $server = $config->get_server_by_abbrev($server_name, $self)
                  || Helm::Server->new(name => $server_name);
                push(@server_objs, $server);
            } else {
                push(@server_objs, Helm::Server->new(name => $server_name));
            }
        }
        $self->_servers(\@server_objs);
    }

    # if we have any roles, then get the servers with those roles
    my @roles = @{$self->roles};
    if( @roles ) {
        $self->die("Can't specify roles without a config") if !$self->config;
        my @servers = @{$self->servers};
        push(@servers, $self->config->get_servers_by_roles(@roles));
        $self->_servers(\@servers);
    }
    
    # if we still don't have any servers, then use 'em all
    my @servers = @{$self->servers};
    if(!@servers) {
        $self->die("You must specify servers if you don't have a config") if !$self->config;
        $self->_servers($self->config->servers);
    }
}

sub steer {
    my $self = shift;
    my $task = $self->task;

    # make sure it's a task we know about and can load
    my $task_class = $REGISTERED_MODULES{task}->{$task};
    $self->die("Unknown task $task") unless $task_class;
    eval "require $task_class";

    if( $@ ) {
        if( $@ =~ /Can't locate \S+.pm/ ) {
            $self->die("Can not find module $task_class for task $task");
        } else {
            $self->die("Could not load module $task_class for task $task");
        }
    }

    my $task_obj = $task_class->new($self);
    $task_obj->validate();

    # make sure have a local lock if we need it
    $self->die("Cannot obtain a local helm lock. Is another helm process running?")
      if ($self->lock_type eq 'local' || $self->lock_type eq 'both') && !$self->_get_local_lock;

    my @servers = @{$self->servers};
    $self->log->debug("Running task $task on servers: " . join(', ', @servers) . "\n");

    # execute the task for each server
    foreach my $server (@servers) {
        $self->_current_server($server);
        $self->log->start_server($server);

        my $port = $server->port || $self->default_port;
        my %ssh_args = (
            ctl_dir     => catdir(File::HomeDir->my_home, '.helm'),
            strict_mode => 0,
        );
        $ssh_args{port}    = $port if $port;
        $ssh_args{timeout} = $self->timeout      if $self->timeout;
        $self->log->debug("Setting up SSH connection to $server" . ($port ? ":$port" : ''));
        my $ssh = Net::OpenSSH->new($server->name, %ssh_args);
        $ssh->error && $self->die("Can't ssh to $server: " . $ssh->error);

        # get a lock on the server if we need to
        $self->die("Cannot obtain remote lock on $server. Is another helm process working there?")
          if ($self->lock_type eq 'remote' || $self->lock_type eq 'both')
          && !$self->_get_remote_lock($ssh);

        $task_obj->execute(
            ssh    => $ssh,
            server => $server,
        );

        $self->log->end_server($server);
        $self->_release_remote_lock($ssh);
        sleep($self->sleep) if $self->sleep;
    }

    # release the local lock
    $self->_release_local_lock();
    $self->log->finalize($self);
}

sub load_configuration {
    my ($self, $uri) = @_;
    $uri = try { 
        URI->new($uri) 
    } catch {
        $self->die("Invalid configuration URI $uri");
    };

    # try to load the right config module
    my $scheme = $uri->scheme;
    $self->die("Unknown config type for $uri") unless $scheme;
    my $loader_class  = $REGISTERED_MODULES{configuration}->{$scheme};
    $self->die("Unknown config type for $uri") unless $loader_class;
    eval "require $loader_class";

    if( $@ ) {
        if( $@ =~ /Can't locate \S+.pm/ ) {
            $self->die("Can not find module $loader_class for configuration type $scheme");
        } else {
            $self->die("Could not load module $loader_class for configuration type $scheme: $@");
        }
    }

    $self->log->debug("Loading configuration for $uri from $loader_class");
    return $loader_class->load(uri => $uri, helm => $self);
}

sub task_help {
    my ($class, $task) = @_;
    # make sure it's a task we know about and can load
    my $task_class = $REGISTERED_MODULES{task}->{$task};
    CORE::die(qq(Unknown task "$task")) unless $task_class;
    eval "require $task_class";
    die $@ if $@;

    return $task_class->help();
}

sub known_tasks {
    my $class = shift;
    return sort keys %{$REGISTERED_MODULES{task}};
}

sub _get_local_lock {
    my $self = shift;
    $self->log->debug("Trying to acquire global local helm lock");
    # lock the file so nothing else can run at the same time
    my $lock_handle;
    my $lock_file = $self->_local_lock_file();
    open($lock_handle, '>', $lock_file) or $self->die("Can't open $lock_file for locking: $!");
    if (flock($lock_handle, LOCK_EX | LOCK_NB)) {
        $self->_local_lock_handle($lock_handle);
        $self->log->debug("Local helm lock obtained");
        return 1;
    } else {
        return 0;
    }
}

sub _release_local_lock {
    my $self = shift;
    if($self->local_lock_handle) {
        $self->log->debug("Releasing global local helm lock");
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
    $self->log->debug("Trying to obtain remote server lock for $server");

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
        $self->log->debug("Remote server lock for $server obtained");
        return 1;
    }
}

sub _release_remote_lock {
    my ($self, $ssh) = @_;
    if( $self->lock_type eq 'remote' || $self->lock_type eq 'both' ) {
        $self->log->debug("Releasing remote server lock for " . $self->current_server);
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
    my $sudo        = $self->sudo;

    if( $sudo && !$args{no_sudo}) {
        $cmd = "sudo -u $sudo $cmd";
        $ssh_options->{tty} = 1;
    }

    $self->log->debug("Running remote command ($cmd) on server $server");
    $ssh->$ssh_method($ssh_options, $cmd)
      or $self->die("Can't execute command ($cmd) on server $server: " . $ssh->error);
}

sub die {
    my ($self, $msg) = @_;
    $self->log->error($msg);
    exit(1);
}

sub register_module {
    my ($class, $type, $key, $module) = @_;
    CORE::die("Unknown Helm module type '$type'!") unless exists $REGISTERED_MODULES{$type};
    $REGISTERED_MODULES{$type}->{$key} = $module;
}

__PACKAGE__->meta->make_immutable;

1;
