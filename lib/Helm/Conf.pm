package Helm::Conf;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Helm::Server;
use Carp qw(croak);

has servers => (is => 'ro', writer => '_servers', isa => 'ArrayRef[Helm::Server]');

sub get_server_names_by_roles {
    my ($self, @roles) = @_;
    return map { $_->name } grep { $_->has_role(@roles) } @{$self->servers};
}

sub expand_server_name {
    my ($self, $name) = @_;
    my $name_length = length $name;
    my $match;
    foreach my $server (@{$self->servers}) {
        if ($server->name_length >= $name_length) {
            if (substr($server->name, 0, $name_length) eq $name) {
                if (!$match || $name eq $server->name) {
                    $match = $server->name;
                } else {
                    croak("Server abbreviation $name is ambiguous. Looks like $match and " . $self->name);
                }
            }
        }
    }
    return $match;
}

sub get_all_server_names {
    my $self = shift;
    return map { $_->name } @{$self->servers};
}


__PACKAGE__->meta->make_immutable;

1;
