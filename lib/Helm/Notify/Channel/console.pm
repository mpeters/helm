package Helm::Notify::Channel::console;
use strict;
use warnings;
use Moose;
use namespace::autoclean;

extends 'Helm::Notify::Channel';

sub initialize {
    my ($self, $helm) = @_;
    # nothing to do here
}

sub finalize {
    my ($self, $helm) = @_;
    # nothing to do here
}

sub debug {
    my ($self, $msg) = @_;
    CORE::warn("[DEBUG] $msg\n");
}

sub info {
    my ($self, $msg) = @_;
    CORE::warn("$msg\n");
}

sub warn {
    my ($self, $msg) = @_;
    CORE::warn("[WARN] $msg\n");
}

sub error {
    my ($self, $msg) = @_;
    CORE::warn("[ERROR] $msg\n");
}

__PACKAGE__->meta->make_immutable;

1;
