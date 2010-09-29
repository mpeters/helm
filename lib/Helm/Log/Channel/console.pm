package Helm::Log::Channel::console;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Term::ANSIColor qw(colored);

extends 'Helm::Log::Channel';

sub initialize {
    my ($self, $helm) = @_;
    # nothing to do here
}

sub finalize {
    my ($self, $helm) = @_;
    # nothing to do here
}

sub start_server {
    my ($self, $server) = @_;
    my $line = '-' x 70;
    print STDERR colored("$line\n$server\n$line\n", 'blue');
}

sub end_server {
    my ($self, $server) = @_;
    print STDERR "\n";
}

sub debug {
    my ($self, $msg) = @_;
    print STDERR colored("[DEBUG] $msg\n", 'bright_blue');
}

sub info {
    my ($self, $msg) = @_;
    print STDERR colored("$msg\n", 'bright_green');
}

sub warn {
    my ($self, $msg) = @_;
    print STDERR colored("[WARN] $msg\n", 'yellow');
}

sub error {
    my ($self, $msg) = @_;
    print STDERR colored("[ERROR] $msg\n", 'red');
}

__PACKAGE__->meta->make_immutable;

1;
