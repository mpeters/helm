package Helm::Log::Channel::file;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use DateTime;

extends 'Helm::Log::Channel';
has fh => (is => 'ro', writer => '_fh', isa => 'FileHandle | Undef');

sub initialize {
    my ($self, $helm) = @_;

    # file the file and open it for appending
    my $file = $self->uri->file;
    open(my $fh, '>>', $file) or $helm->die("Could not open file $file for appending: $@");
    $self->_fh($fh);
}

sub finalize {
    my ($self, $helm) = @_;

    # close our FH
    if( $self->fh ) {
        close($self->fh);
        $self->_fh(undef);
    }
}

sub start_server {
    my ($self, $server) = @_;
    my $fh = $self->fh;
    print $fh $self->_timestamp . " BEGIN HELM TASK ON $server\n";
}

sub end_server {
    my ($self, $server) = @_;
    my $fh = $self->fh;
    print $fh $self->_timestamp . " END HELM TASK ON $server\n";
}

sub debug {
    my ($self, $msg) = @_;
    my $fh = $self->fh;
    print $fh $self->_timestamp . " [debug] $msg\n";
}

sub info {
    my ($self, $msg) = @_;
    my $fh = $self->fh;
    print $fh $self->_timestamp . " $msg\n";
}

sub warn {
    my ($self, $msg) = @_;
    my $fh = $self->fh;
    print $fh $self->_timestamp . " [warn] $msg\n";
}

sub error {
    my ($self, $msg) = @_;
    my $fh = $self->fh;
    print $fh $self->_timestamp . " [error] $msg\n";
}

sub _timestamp {
    my $self = shift;
    return '[' . DateTime->now->strftime('%a %b %d %H:%M:%S %Y') . ']';
}

__PACKAGE__->meta->make_immutable;

1;
