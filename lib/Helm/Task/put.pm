package Helm::Task::put;
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

    # make sure we have local and remote options and that the local file exists and is readable
    my $local = $extra_options->{local};
    croak('Missing option: local',  option => 'local')  unless $local;
    croak('Missing option: remote', option => 'remote') unless $extra_options->{remote};
    croak("Invalid option: local - File \"$local\" does not exist")  unless -e $local;
    croak("Invalid option: local - File \"$local\" is not readable") unless -r $local;
}

sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $helm    = $self->helm;
    my $options = $helm->extra_options;
    my $local   = $options->{local};
    my $remote  = $options->{remote};
    my $sudo    = $helm->sudo;

    # if we're using sudo then use a temp file to move the file over
    my $dest = $sudo ? $self->unique_tmp_file : $remote;

    # send our file over there
    $ssh->scp_put($local, $remote)
      || croak("Can't scp file ($local) to server $server: " . $ssh->error);
    warn "File $local copied to $server:$remote\n";

    if ($sudo) {
        # make it owned by the sudo user
        my $cmd = "sudo chown $sudo.$sudo $dest";
        $ssh->system($cmd)
          || croak("Can't execute command ($cmd) on server $server: " . $ssh->error);

        # move the file over to the correct location
        my $cmd = "sudo mv $dest $remote";
        $ssh->system($cmd)
          || croak("Can't execute command ($cmd) on server $server: " . $ssh->error);
    }
}

__PACKAGE__->meta->make_immutable;

1;
