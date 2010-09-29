package Helm::Log::Channel;
use strict;
use warnings;
use Moose;
use namespace::autoclean;

has uri => (is => 'ro', writer => '_uri', isa => 'URI');

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    if (@_ == 1 && !(ref $_[0] && ref $_[0] eq 'HASH')) {
        return $class->$orig(uri => $_[0]);
    } else {
        return $class->$orig(@_);
    }
};

sub initialize {
    my ($self, $helm) = @_;
    die "You must implement the initialize() method in your child class " . ref($self) . "!";
}

sub finalize {
    my ($self, $helm) = @_;
    die "You must implement the finalize() method in your child class " . ref($self) . "!";
}

sub start_server {
    my ($self, $server) = @_;
    die "You must implement the start_server() method in your child class " . ref($self) . "!";
}

sub end_server {
    my ($self, $server) = @_;
    die "You must implement the end_server() method in your child class " . ref($self) . "!";
}

sub debug {
    my ($self, $msg) = @_;
    die "You must implement the debug() method in your child class " . ref($self) . "!";
}

sub info {
    my ($self, $msg) = @_;
    die "You must implement the info() method in your child class " . ref($self) . "!";
}

sub warn {
    my ($self, $msg) = @_;
    die "You must implement the warn() method in your child class " . ref($self) . "!";
}

sub error {
    my ($self, $msg) = @_;
    die "You must implement the error() method in your child class " . ref($self) . "!";
}

__PACKAGE__->meta->make_immutable;

1;
