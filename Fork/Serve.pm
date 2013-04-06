package AnyEvent::Fork::Serve;

use common::sense; # actually required to avoid spurious warnings...
use IO::FDPass;

our $OWNER; # pid of process "owning" us

# commands understood:
# e_val perlcode string...
# f_ork
# h_andle + fd
# a_rgs string...
# r_un func

sub serve;

sub error {
   warn "[$0] ERROR: $_[0]\n";
   last;
}

# the goal here is to keep this simple, small and efficient
sub serve {
   undef &me; # free a tiny bit of memory

   my $master = shift;

   my @arg;

   my ($cmd, $fd);

   while () {
      # we must not ever read "too much" data, as we might accidentally read
      # an IO::FDPass::send request.

      my $len;
      sysread $master, $len, 5 - length $len, length $len or return
         while 5 > length $len;
      ($cmd, $len) = unpack "a L", $len;

      my $buf;
      sysread $master, $buf, $len - length $buf, length $buf or return
         while $len > length $buf;

      #warn "cmd<$cmd,$buf>\n";
      if ($cmd eq "h") {
         $fd = IO::FDPass::recv fileno $master;
         $fd >= 0 or error "AnyEvent::Fork::Serve: fd_recv() failed: $!";
         open my $fh, "+<&=$fd" or error "AnyEvent::Fork::Serve: open (fd_recv) failed: $!";
         push @arg, $fh;

      } elsif ($cmd eq "a") {
         push @arg, unpack "(w/a*)*", $buf;

      } elsif ($cmd eq "f") {
         my $pid = fork;

         if ($pid eq 0) {
            $0 = "AnyEvent::Fork of $OWNER";
            @_ = pop @arg;
            goto &serve;
         } else {
            @arg = ();

            $pid
               or error "AnyEvent::Fork::Serve: fork() failed: $!";
         }

      } elsif ($cmd eq "e") {
         ($cmd, @_) = unpack "(w/a*)*", $buf;

         # $cmd is allowed to access @_ and @arg, and nothing else
         package main;
         eval $cmd;
         AnyEvent::Fork::Serve::error "$@" if $@;
        
      } elsif ($cmd eq "r") {
         # we could free &serve etc., but this might just unshare
         # memory that could be shared otherwise.
         @_ = ($master, @arg);
         $0 = "$buf of $OWNER";
         package main;
         goto &$buf;

      } else {
         error "AnyEvent::Fork::Serve received unknown request '$cmd' - stream corrupted?";
      }
   }
}

# the entry point for new_exec
sub me {
   #$^F = 2; # should always be the case

   open my $fh, "<&=$ARGV[0]"
      or die "AnyEvent::Fork::Serve::me unable to open communication socket: $!\n";

   $OWNER = $ARGV[1];

   $0 = "AnyEvent::Fork/exec of $OWNER";
   $SIG{CHLD} = 'IGNORE';

   @ARGV = ();
   @_ = $fh;
   goto &serve;
}

1

