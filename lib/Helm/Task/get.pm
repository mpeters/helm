package Helm::Task::get;
use strict;
use warnings;
use Moose;
use Net::OpenSSH;
use Data::UUID;
use Carp qw(croak);

extends 'Helm::Task';

sub validate {
    my $self          = shift;
    my $helm          = $self->helm;
    my $extra_options = $helm->extra_options;

    # make sure we have local and remote options
    croak('Missing option: local')  unless $extra_options->{local};
    croak('Missing option: remote') unless $extra_options->{remote};
}

sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $options = $self->helm->extra_options;
    my $local   = $options->{local};
    my $remote  = $options->{remote};

    # get our file over here with a new name
    $ssh->scp_get($remote, "$local.$server")
      || croak("Can't scp file ($remote) from server $server: " . $ssh->error);
    warn "File $server:$remote copied to $local.$server\n";
}

__PACKAGE__->meta->make_immutable;

1;
