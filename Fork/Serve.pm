package AnyEvent::Fork::Serve;

use common::sense;
use AnyEvent::Fork::Util;

our $OWNER; # pid of process "owning" us

# commands understood:
# e eval
# f fork [fh]
# h handle
# a args
# r run func [args...]

sub serve;

sub error {
   warn "$_[0]\n";
   last;
}

sub serve {
   undef &me; # free a tiny bit of memory

   my $master = shift;

   my @arg;

   while () {
      # we must not ever read "too much" data, as we might accidentally read
      # an fd_send request. maybe fd_recv should actually receive any amount of
      # data and fds, but then we still don't know which fd corresponds to which request.

      my $len;
      sysread $master, $len, 4 - length $len, length $len or return
         while 4 > length $len;
      $len = unpack "N", $len;

      my $buf;
      sysread $master, $buf, $len - length $buf, length $buf or return
         while $len > length $buf;

      my ($cmd, @val) = unpack "(w/a)*", $buf;

      #warn "cmd<$cmd,@val>\n";
      if ($cmd eq "h") {
         my $fd = AnyEvent::Fork::Util::fd_recv fileno $master;
         $fd >= 0 or error "AnyEvent::Fork::Serve: fd_recv() failed: $!";
         open my $fh, "+>&=$fd" or error "AnyEvent::Fork::Serve: open (fd_recv) failed: $!";
         push @arg, $fh;

      } elsif ($cmd eq "a") {
         push @arg, @val;

      } elsif ($cmd eq "f") {
         my $pid = fork;

         if ($pid eq 0) {
            $0 = "fork/fork of $OWNER";
            @_ = pop @arg;
            goto &serve;
         } else {
            @arg = ();

            $pid
               or error "AnyEvent::Fork::Serve: fork() failed: $!";
         }

      } elsif ($cmd eq "e") {
         $cmd = shift @val;
         eval $cmd;
         error "$@" if $@;
        
      } elsif ($cmd eq "r") {
         # we could free &serve etc., but this might just unshare
         # memory that could be shared otherwise.
         @_ = ($master, @arg);
         goto &{ $val[0] };

      } else {
         error "AnyEvent::Fork::Serve received unknown request '$cmd' - stream corrupted?";
      }
   }
}

sub me {
   #$^F = 2; # should always be the case

   open my $fh, "<&=$ARGV[0]"
      or die "AnyEvent::Fork::Serve::me unable to open communication socket: $!\n";

   $OWNER = $ARGV[1];

   $0 = "fork/exec of $OWNER";

   @ARGV = ();
   @_ = $fh;
   goto &serve;
}

1

