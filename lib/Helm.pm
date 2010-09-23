package Helm;
use strict;
use warnings;
use Moose;
use Moose::Util::TypeConstraints qw(enum);
use URI;
use namespace::autoclean;
use Try::Tiny;
use File::Spec::Functions qw(catdir);
use File::HomeDir;
use Net::OpenSSH;
use Carp qw(croak);

our $VERION = 0.1;

enum NOTIFY_LEVEL => qw(debug info warn error fatal);
has task          => (is => 'ro', writer => '_task',       required => 1);
has extra_options => (is => 'ro', isa    => 'HashRef',     default  => sub { {} });
has config_uri    => (is => 'ro', writer => '_config_uri', isa      => 'Str');
has config        => (is => 'ro', writer => '_config',     isa      => 'Helm::Conf');
has sudo          => (is => 'ro', writer => '_sudo',       isa      => 'Str');
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
        my $config = $self->config;
        $self->_servers([map { $config->expand_server_name($_) } @servers]);
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

    my $header = '=' x 70;
    foreach my $server (@servers) {
        warn "$header\n$server\n$header\n";
        $task_obj->execute(
            ssh    => $ssh_connections{$server},
            server => $server,
        );
    }
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

__PACKAGE__->meta->make_immutable;

1;
