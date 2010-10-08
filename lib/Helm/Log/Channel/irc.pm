package Helm::Log::Channel::irc;
use strict;
use warnings;
use Moose;
use namespace::autoclean;
use DateTime;
use AnyEvent;
use IO::Pipe;

BEGIN {
    eval { require AnyEvent::IRC::Client };
    die "Could not load AnyEvent::IRC::Client. It must be installed to use Helm's irc logging"
      if $@;
}

extends 'Helm::Log::Channel';
has irc_pipe    => (is => 'ro', writer => '_irc_pipe');
has pipes       => (is => 'ro', writer => '_pipes', isa => 'HashRef');
has is_parallel => (is => 'rw', isa    => 'Bool', default => 0);
has irc_pause   => (is => 'ro', writer => '_irc_pause', isa => 'Int', default => 0);

my $DISCONNECT = 'Disconnecting';
my $DEBUG;

# first parse the IRC URI into some parts that we can use to create an IRC connection.
# Then fork off an IRC worker process to go into an event loop that will read input
# from the main process via a pipe and then output that to the IRC server. We need
# to do it in an event loop because it needs to also respond asynchronously to the
# IRC server for pings and such.
sub initialize {
    my ($self, $helm) = @_;
    my $options = $helm->extra_options;
    my $pause = $options->{'irc-pause'} || $options->{'irc_pause'};
    $self->_irc_pause($pause) if $pause;

    my %irc_info;
$DEBUG = IO::File->new('>> debug.log');
$DEBUG->autoflush(1);
print $DEBUG _timestamp() . " $$ main process\n";

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
    my $irc_pipe = IO::Pipe->new();

    # fork off a child process
    my $pid = fork();
    $helm->die("Couldn't fork IRC bot process") if !defined $pid;
    if ($pid) {
        # parent here
        $irc_pipe->writer;
        $irc_pipe->autoflush(1);
        $self->_irc_pipe($irc_pipe);
print $DEBUG _timestamp() . " $$ parent IRC pipe set up\n";
    } else {
$DEBUG = IO::File->new('>> debug.log');
$DEBUG->autoflush(1);
print $DEBUG _timestamp() . " $$ child IRC worker process\n";
        # child here
        $irc_pipe->reader;
        $irc_pipe->autoflush(1);
print $DEBUG _timestamp() . " $$ child IRC pipe set up\n";
        $self->_irc_events($irc_pipe, %irc_info);
    }
}

sub finalize {
    my ($self, $helm) = @_;

    # if we're in parallel mode, then wait until our IO worker is done
    if( $self->is_parallel ) {
        my $pid = wait;
print $DEBUG _timestamp() . " $$ parent reaped IO worker child $pid\n";
    }
}

sub start_server {
    my ($self, $server) = @_;
    $self->SUPER::start_server($server);
    $self->_say("BEGIN Helm task \"" . $self->task . "\" on $server");
}

sub end_server {
    my ($self, $server) = @_;
    $self->SUPER::end_server($server);
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
print $DEBUG _timestamp() . " $$ sending message to IO worker: $msg\n";
    $self->irc_pipe->print("MSG: $msg\n") or CORE::die("Could not print message to IO Worker: $!");
}

sub _irc_events {
    my ($self, $irc_pipe, %args) = @_;
    my $irc  = AnyEvent::IRC::Client->new();
    my $done = AnyEvent->condvar;
    my $io_watcher;

    $irc->reg_cb(
        join => sub {
            my ($irc, $nick, $channel, $is_myself) = @_;
print $DEBUG _timestamp() . " $$ IRC worker joined channel $channel\n";
print $DEBUG _timestamp() . " registered? " . $irc->registered . "\n";
            # send the initial message
            $irc->send_msg(PRIVMSG => $channel, "Helm execution started by " . getlogin);
            if ($is_myself && $channel eq $args{channel}) {
                $io_watcher = AnyEvent->io(
                    fh   => $irc_pipe,
                    poll => 'r',
                    cb   => sub {
                        my $msg = <$irc_pipe>;
                        if(!$msg) {
print $DEBUG _timestamp() . " $$ IRC worker ran out of pipe\n";
                            $irc->send_msg(PRIVMSG => $channel, $DISCONNECT);
                            undef $io_watcher;
                        } else {
                            chomp($msg);
                            if ($msg =~ /^MSG: (.*)/) {
                                my $content = $1;
                                chomp($content);
                                sleep($self->irc_pause) if $self->irc_pause;
print $DEBUG _timestamp() . " $$ IRC worker sending message to IRC channel: $content\n";
                                $irc->send_msg(PRIVMSG => $channel, $content);
                            }
                        }
                    }
                );
            }
        }
    );

    # we aren't done until the server acknowledges the send disconnect message
    $irc->reg_cb(
        sent => sub {
            my ($irc, $junk, $type, $channel, $msg) = @_;
            if( $type eq 'PRIVMSG' && $msg eq $DISCONNECT ) {
print $DEBUG _timestamp() . " $$ IRC channel received DISCONNECT message\n";
                $done->send();
            }
        }
    );

print $DEBUG _timestamp() . " $$ IRC worker connecting to server $args{server}\n";
    $irc->connect($args{server}, $args{port}, {nick => $args{nick}});
print $DEBUG _timestamp() . " $$ IRC worker trying to join channel $args{channel}\n";
    $irc->send_srv(JOIN => ($args{channel}));
print $DEBUG _timestamp() . " $$ IRC worker waiting for work\n";
    $done->recv;
print $DEBUG _timestamp() . " $$ IRC worker done with work, disconnecting\n";
    $irc->disconnect();
    exit(0);
}

# we already have an IRC bot forked off which has a pipe to our main process for
# communication. But if we then share that pipe in all our children we'll end up
# with garbled messages. So we need to fork off another worker process which has
# multiple pipes, one for each possible server that we'll be executing tasks on.
# This extra IO worker process will multi-plex the output coming from those pipes
# into something reasonable for the IRC bot to handle.
sub parallelize {
die "IRC logging doesn't work with --parallel yet!";
    my ($self, $helm) = @_;
    $self->is_parallel(1);

    # if we're going to do parallel stuff, then create a pipe for each server now
    # that we can use to communicate with the child processes later
    my %pipes = map { $_->name => IO::Pipe->new } (@{$helm->servers});
    $self->_pipes(\%pipes);

    # fork off an IO worker process
    my $pid = fork();
$DEBUG = IO::File->new('>> debug.log');
$DEBUG->autoflush(1);
    $helm->die("Couldn't fork IRC IO worker process") if !defined $pid;
    if (!$pid) {
print $DEBUG _timestamp() . " $$ IO worker forked\n";
        # child here
        my %pipe_cleaners;
        my $all_clean = AnyEvent->condvar;
        foreach my $server (keys %pipes) {
            my $pipe = $pipes{$server};
            $pipe->reader;

print $DEBUG _timestamp() . " $$ IO worker setting up AnyEvent reads on pipe for $server\n";
            # create an IO watcher for this pipe
            $pipe_cleaners{$server} = AnyEvent->io(
                fh   => $pipe,
                poll => 'r',
                cb   => sub {
                    my $msg = <$pipe>;
                    if ($msg) {
print $DEBUG _timestamp() . " $$ print message to IRC PIPE: $msg";
                        $self->irc_pipe->print($msg) or CORE::die "Could not print message to IRC PIPE: $!";
                    } else {
                        delete $pipe_cleaners{$server};
print $DEBUG _timestamp() . " $$ removing IO pipe for $server\n";
                        # tell the main program we're done if this is the last broom
                        $all_clean->send unless %pipe_cleaners;
                    }
                },
            );
        }

print $DEBUG _timestamp() ." $$ waiting for IO\n";
        $all_clean->recv;
print $DEBUG _timestamp() ." $$ all done with IO\n";
        exit(0);
    }
}

sub _timestamp {
    use DateTime;
    return '[' . DateTime->now->strftime('%a %b %d %H:%M:%S %Y') . ']';
}

# we've been forked, and if it's a child we want to initialize the pipe
# for this worker child's server
sub forked {
    my ($self, $type) = @_;

    if ($type eq 'child') {
print $DEBUG _timestamp() . " $$ forked worker process for " . $self->current_server->name . "\n";
        my $pipes = $self->pipes;
        my $pipe  = $pipes->{$self->current_server->name};
        $pipe->writer();
        $pipe->autoflush(1);
        $self->_irc_pipe($pipe);
    }
}

__PACKAGE__->meta->make_immutable;

1;
