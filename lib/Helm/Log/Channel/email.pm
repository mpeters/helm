package Helm::Log::Channel::email;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use DateTime;

BEGIN {
    eval { require Email::Simple };
    die "Could not load Email::Simple. It must be installed to use Helm's email logging" if $@;
    eval { require Email::Simple::Creator };
    die "Could not load Email::Simple::Creator. It must be installed to use Helm's email logging" if $@;
    eval { require Email::Sender::Simple };
    die "Could not load Email::Sender::Simple. It must be installed to use Helm's email logging" if $@;
    eval { require Email::Valid };
    die "Could not load Email::Valid::Simple. It must be installed to use Helm's email logging" if $@;
}

extends 'Helm::Log::Channel';
has email_address => (is => 'ro', writer => '_email_address', isa => 'Str');
has email_body    => (is => 'ro', writer => '_email_body',    isa => 'Str', default => '');
has from          => (is => 'ro', writer => '_from',          isa => 'Str', default => '');

sub initialize {
    my ($self, $helm) = @_;

    # file the file and open it for appending
    my $uri = $self->uri;
    my $email = $uri->to;
    my %headers = $uri->headers();
    my $from = $headers{from} || $headers{From} || $headers{FROM};
    $helm->die(qq(No "From" specified in mailto URI $uri)) unless $from;

    # remove possible leading double slash if someone does "mailto://" instead of "mailto:"
    $email =~ s/^\/\///; 

    $helm->die(qq("$email" is not a valid email address)) unless Email::Valid->address($email);
    $self->_email_address($email);
    $self->_from($from);
}

sub finalize {
    my ($self, $helm) = @_;

    # send the email
    my $email = Email::Simple->create(
        header => [
            To      => $self->email_address,
            From    => $self->from,
            Subject => 'HELM: Task ' . $self->task,
        ],
        body => $self->email_body,
    );
    Email::Sender::Simple->send($email);
}

sub start_server {
    my ($self, $server) = @_;
    my $line = '=' x 70;
    $self->_append_body("$line\n$server\n$line\n");
}

sub end_server {
    my ($self, $server) = @_;
    $self->_append_body("\n\n");
}

sub debug {
    my ($self, $msg) = @_;
    $self->_append_body("  [debug] $msg\n");
}

sub info {
    my ($self, $msg) = @_;
    $self->_append_body("  $msg\n");
}

sub warn {
    my ($self, $msg) = @_;
    $self->_append_body("  [warn] $msg\n");
}

sub error {
    my ($self, $msg) = @_;
    $self->_append_body("  [error] $msg\n");
}

sub _append_body {
    my ($self, $text) = @_;
    $self->_email_body($self->email_body . $text);
}

__PACKAGE__->meta->make_immutable;

1;
