package Helm::Task::run;
use strict;
use warnings;
use Moose;

extends 'Helm::Task';
has command => (is => 'ro', writer => '_command', isa => 'Str');

sub validate {
    my $self = shift;
    my $helm = $self->helm;
    my $cmd  = $helm->extra_options->{command} || $helm->extra_args->[0];

    $helm->die('Missing option: command') unless $cmd;
    $self->_command($cmd);
}

sub help {
    my $self = shift;
    return <<END;
Run a command on a remote server(s). This command can either
be specified as the first positional argument:

    helm run 'ls /'

Or as the named --command option:

    helm run --command 'ls /'
END
}


sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $helm    = $self->helm;
    my $command = $self->command;

    $helm->run_remote_command(command => $command, ssh => $ssh);
}

__PACKAGE__->meta->make_immutable;

1;
