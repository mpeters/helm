package Helm::Task::patch;
use strict;
use warnings;
use Moose;
use Net::OpenSSH;
use Carp qw(croak);

extends 'Helm::Task';

sub validate {
    my $self          = shift;
    my $helm          = $self->helm;
    my $extra_options = $helm->extra_options;

    # make sure we have a file and target and that file exists and is readable
    croak('Missing option: file') unless $extra_options->{file};
    croak('Missing option: target') unless $extra_options->{target};
    croak('Invalid option: file. File does not exist') unless -e $extra_options->{file};
    croak('Invalid option: file. File is not readable') unless -r $extra_options->{file};
}

sub execute {
    my ($self, %args) = @_;
    my $server  = $args{server};
    my $ssh     = $args{ssh};
    my $helm    = $self->helm;
    my $options = $helm->extra_options;
    my $file    = $options->{file};
    my $target  = $options->{target};
    my $sudo    = $helm->sudo;
    my $cmd;

    # first get our patch file over there with a unique name so there are no collisions
    my $dest = $self->unique_tmp_file(suffix => '.patch');
    $ssh->scp_put($file, $dest) || croak("Can't scp file ($file) to server $server: " . $ssh->error);

    # if we are using sudo, then let's make sure the file is owned by the other user
    if( $sudo ) {
        $cmd = "sudo chown $sudo.$sudo $dest";
        $ssh->system($cmd) || croak("Can't execute command ($cmd) on server $server: " . $ssh->error);
    }

    # now patch the file
    $cmd = "patch $target $dest";
    $cmd = "sudo -u $sudo $cmd" if $sudo;
    $ssh->system($cmd) || croak("Can't execute command ($cmd) on server $server: " . $ssh->error);

    # now remove our file so we leave the server clean
    $cmd = "rm -f $dest";
    $cmd = "sudo -u $sudo $cmd" if $sudo;
    $ssh->system($cmd) || croak("Can't execute command ($cmd) on server $server: " . $ssh->error);
}

__PACKAGE__->meta->make_immutable;

1;
