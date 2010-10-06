package Helm::Log::Channel::irc;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use DateTime;
use Errno qw(EAGAIN);

BEGIN {
    eval { require AnyEvent };
    die "Could not load AnyEvent. It must be installed to use Helm's irc logging" if $@;
    eval { require AnyEvent::IRC::Client };
    die "Could not load AnyEvent::IRC::Client. It must be installed to use Helm's irc logging" if $@;
    eval { require IO::Pipe };
    die "Could not load IO::Pipe. It must be installed to use Helm's irc logging" if $@;
}

extends 'Helm::Log::Channel';
has pipe => (is => 'ro', writer => '_pipe');
has child_pid => (is => 'ro', writer => '_child_pid', isa => 'Int');

# TODO - handle signals from parent process

my $TERMINATE = 'TERMINATE';

sub initialize {
    my ($self, $helm) = @_;
    my %irc_info;

    # file the file and open it for appending
    my $uri = $self->uri;
    if ($uri->authority =~ /@/) {
        my ($nick, $host) = split(/@/, $uri->authority);
        $irc_info{nick}   = $nick;
        $irc_info{server} = $host;
    } else {
        $irc_info{nick}   = 'helm';
        $irc_info{server} = $uri->authority;
    }
    $helm->die("No IRC server given in URI $uri") unless $irc_info{server};

    # get the channel
    my $channel = $uri->path;
    $helm->die("No IRC channel given in URI $uri") unless $channel;
    $channel =~ s/^\///;    # remove leading slash
    $channel = "#$channel" unless $channel =~ /^#/;
    $irc_info{channel} = $channel;

    # do we need a password
    my $query = $uri->query;
    if ($query && $query =~ /(?:^|&|;)(pass|pw|password|passw|passwd)=(.*)(?:$|&|;)/) {
        $irc_info{password} = $1;
    }

    # do we have a port?
    if ($irc_info{server} =~ /:(\d+)$/) {
        $irc_info{port} = $1;
        $irc_info{server} =~ s/:(\d+)$//;
    } else {
        $irc_info{port} = 6667;
    }

    # setup a pipe for communicating
    my $pipe = IO::Pipe->new();

    # fork off a child process
    FORK: {
        my $pid;
        if($pid = fork) {
            # parent here
            $pipe->writer;
            $pipe->autoflush(1);
            $self->_pipe($pipe);
            $self->_child_pid($pid);
        } elsif( defined $pid ) {
            # child here
            $pipe->reader;
            $self->_irc_events($pipe, %irc_info);
        } elsif( $! == EAGAIN ) {
            # supposedly recoverable
            sleep(2);
            redo FORK;
        } else {
            $helm->die("Couldn't fork IRC bot process");
        }
    }
}

sub finalize {
    my ($self, $helm) = @_;
    # send a terminate message to our child process and wait for it to exit
    my $pipe = $self->pipe;
    print $pipe "$TERMINATE\n";
    wait;
}

sub start_server {
    my ($self, $server) = @_;
    $self->_say("BEGIN Helm task \"" . $self->task . "\" on $server");
}

sub end_server {
    my ($self, $server) = @_;
    $self->_say("END Helm task \"" . $self->task . "\" on $server");
}

sub debug {
    my ($self, $msg) = @_;
    $self->_say("[debug] $msg");
}

sub info {
    my ($self, $msg) = @_;
    $self->_say("$msg");
}

sub warn {
    my ($self, $msg) = @_;
    $self->_say("[warn] $msg");
}

sub error {
    my ($self, $msg) = @_;
    $self->_say("[error] $msg");
}

sub _say {
    my ($self, $msg) = @_;
    my $pipe = $self->pipe;
    print $pipe "MSG: $msg\n";
}

sub _irc_events {
    my ($self, $pipe, %args) = @_;
    my $irc  = AnyEvent::IRC::Client->new();
    my $done = AnyEvent->condvar;

    $irc->reg_cb(
        join => sub {
            my ($irc, $nick, $channel, $is_myself) = @_;
            # send the initial message
            $irc->send_chan($channel,
                PRIVMSG => ($channel, "Helm execution started by " . getlogin));
            if ($is_myself && $channel eq $args{channel}) {
                my $io_watcher;
                $io_watcher = AnyEvent->io(
                    fh => $pipe,
                    poll => 'r',
                    cb => sub {
                        my $msg = <$pipe> || $TERMINATE;
                        chomp($msg);
                        if( $msg eq $TERMINATE ) {
                            $done->send(); 
                            undef $io_watcher;
                        } elsif( $msg =~ /^MSG: (.*)/ ) {
                            $irc->send_chan( $channel, PRIVMSG => ($channel, $1) );
                        }
                    }
                );
            }
        }
    );

    $irc->connect($args{server}, $args{port}, {nick => $args{nick}});
    $irc->send_srv(JOIN => ($args{channel}));
    $done->recv;
    $irc->disconnect();
    exit(0);
}

__PACKAGE__->meta->make_immutable;

1;
