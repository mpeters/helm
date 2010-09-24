package Helm::Task::run;
use strict;
use warnings;
use Moose;
use Net::OpenSSH;

extends 'Helm::Task';

sub validate {
    my $self          = shift;
    my $helm          = $self->helm;
    my $extra_options = $helm->extra_options;

    $helm->die('Missing option: command') unless $extra_options->{command};
}

sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $helm    = $self->helm;
    my $command = $helm->extra_options->{command};

    if( my $sudo = $helm->sudo ) {
        $command = "sudo -u $sudo $command";
    }

    $helm->notify->info("Running command ($command) on server $server");
    $ssh->system({tty => 1}, $command)
      || $helm->die("Can't execute command ($command) on server $server: " . $ssh->error);
}

__PACKAGE__->meta->make_immutable;

1;
