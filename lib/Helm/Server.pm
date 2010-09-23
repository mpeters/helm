package Helm::Server;
use strict;
use warnings;
use Moose;
use namespace::autoclean;

has name => (is => 'ro', writer => '_name', isa => 'Str', required => 1);
has name_length => (is => 'ro', writer => '_name_length', isa => 'Str');
has roles => (is => 'ro', writer => '_roles', isa => 'ArrayRef[Str]', default => sub { [] });

sub BUILD {
    my $self = shift;
    $self->_name_length(length $self->name);
}

sub has_role {
    my ($self, @possible_roles) = @_;
    foreach my $role (@{$self->roles}) {
        foreach my $possible (@possible_roles) {
            return 1 if $possible eq $role;
        }
    }
    return 0;
}

__PACKAGE__->meta->make_immutable;

1;
