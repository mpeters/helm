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

sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $helm    = $self->helm;
    my $command = $self->command;

    if (my $sudo = $helm->sudo) {
        $command = "sudo -u $sudo $command";
    }

    $helm->log->info("Running command ($command) on server $server");
    $ssh->system({tty => 1}, $command)
      || $helm->die("Can't execute command ($command) on server $server: " . $ssh->error);
}

__PACKAGE__->meta->make_immutable;

1;
