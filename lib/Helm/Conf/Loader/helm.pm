package Helm::Conf::Loader::helm;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use Try::Tiny;
use Config::ApacheFormat;
use Helm::Conf;
use Helm::Server;

extends 'Helm::Conf::Loader';

sub load {
    my ($class, %args) = @_;
    my $uri = $args{uri};
    my $helm = $args{helm};
    my $file = $uri->path || $uri->authority;
    $helm->die("Config file $file does not exist!") unless -e $file;
    $helm->die("Config file $file is not readable!") unless -r $file;

    my $config = Config::ApacheFormat->new(
        expand_vars          => 1,
        duplicate_directives => 'combine',
    );
    try {
        $config->read($file);
    } catch {
        $helm->die("Cannot process config file $file: $_");
    };

    my @server_blocks = $config->get('Server');
    $helm->die("No servers listed in config file $file") unless @server_blocks;

    my @servers;
    my %seen_server_names;
    foreach my $server_block (@server_blocks) {
        my $server_name = $server_block->[1];
        my $conf_block  = $config->block(Server => $server_name);
        my @roles       = $conf_block->get('Role');
        my $port        = $conf_block->get('Port');

        # if server name is a range then expand it
        if ($server_name =~ /\[(\d+)\-(\d+)\]/) {
            my $start = $1;
            my $end   = $2;
            for my $i ($start .. $end) {
                (my $new_name = $server_name) =~ s/\[\d+\-\d+\]/$i/;
                $helm->die("Already seen server $new_name in $file. Duplicate entries not allowed.")
                  if $seen_server_names{$new_name};
                push(@servers,
                    Helm::Server->new(name => $new_name, roles => \@roles, port => $port));
                $seen_server_names{$new_name}++;
            }
        } else {
            $helm->die("Already seen server $server_name in $file. Duplicate entries not allowed.")
              if $seen_server_names{$server_name};
            push(@servers,
                Helm::Server->new(name => $server_name, roles => \@roles, port => $port));
            $seen_server_names{$server_name}++;
        }
    }

    return Helm::Conf->new(servers => \@servers);
}

__PACKAGE__->meta->make_immutable;

1;
