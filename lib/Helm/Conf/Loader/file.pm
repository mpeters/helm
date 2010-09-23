package Helm::Conf::Loader::file;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Config::ApacheFormat;
use Helm::Conf;
use Helm::Server;
use Carp qw(croak);

extends 'Helm::Conf::Loader';

sub load {
    my ($class, $uri) = @_;
    my $file = $uri->path || $uri->authority;
    croak("Config file $file does not exist!") unless -e $file;
    croak("Config file $file is not readable!") unless -r $file;

    my $config = Config::ApacheFormat->new(
        expand_vars          => 1,
        duplicate_directives => 'combine',
    );
    try {
        $config->read($file);
    } catch {
        croak("Cannot process config file $file: $_");
    };

    my @server_blocks = $config->get('Server');
    croak("No servers listed in config file $file") unless @server_blocks;

    my @servers;
    my %seen_server_names;
    foreach my $server_block (@server_blocks) {
        my $server_name = $server_block->[1];
        my @roles = $config->block(Server => $server_name)->get('Role');

        # if server name is a range then expand it
        if ($server_name =~ /\[(\d+)\-(\d+)\]/) {
            my $start = $1;
            my $end   = $2;
            for my $i ($start .. $end) {
                (my $new_name = $server_name) =~ s/\[\d+\-\d+\]/$i/;
                croak("Already seen server $new_name in $file. Duplicate entries not allowed.")
                  if $seen_server_names{$new_name};
                push(@servers, Helm::Server->new(name => $new_name, roles => \@roles));
                $seen_server_names{$new_name}++;
            }
        } else {
            croak("Already seen server $server_name in $file. Duplicate entries not allowed.")
              if $seen_server_names{$server_name};
            push(@servers, Helm::Server->new(name => $server_name, roles => \@roles));
            $seen_server_names{$server_name}++;
        }
    }

    return Helm::Conf->new(servers => \@servers);
}

__PACKAGE__->meta->make_immutable;

1;
