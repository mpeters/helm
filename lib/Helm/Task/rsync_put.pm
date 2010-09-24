package Helm::Task::rsync_put;
use strict;
use warnings;
use Moose;
use Net::OpenSSH;
use Data::UUID;

extends 'Helm::Task';

sub validate {
    my $self          = shift;
    my $helm          = $self->helm;
    my $extra_options = $helm->extra_options;

    # make sure we have local and remote options and that the local file exists and is readable
    my $local = $extra_options->{local};
    $helm->die('Missing option: local')  unless $local;
    $helm->die('Missing option: remote') unless $extra_options->{remote};
    $helm->die("Invalid option: local - Directory \"$local\" does not exist") unless -d $local;
}

sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $options = $self->helm->extra_options;
    my $local   = $options->{local};
    my $remote  = $options->{remote};

    # send our file over there
    $ssh->rsync_put({archive => 1}, $local, $remote)
      || $helm->die("Can't rsync directory ($local) to server $server: " . $ssh->error);
    $helm->notify->info("Directory $local rsync'ed to $server:$remote");
}

__PACKAGE__->meta->make_immutable;

1;
