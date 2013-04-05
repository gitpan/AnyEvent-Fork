=head1 NAME

AnyEvent::Fork - everything you wanted to use fork() for, but couldn't

=head1 SYNOPSIS

   use AnyEvent::Fork;

   ##################################################################
   # create a single new process, tell it to run your worker function

   AnyEvent::Fork
      ->new
      ->require ("MyModule")
      ->run ("MyModule::worker, sub {
         my ($master_filehandle) = @_;

         # now $master_filehandle is connected to the
         # $slave_filehandle in the new process.
      });

   # MyModule::worker might look like this
   sub MyModule::worker {
      my ($slave_filehandle) = @_;

      # now $slave_filehandle is connected to the $master_filehandle
      # in the original prorcess. have fun!
   }

   ##################################################################
   # create a pool of server processes all accepting on the same socket

   # create listener socket
   my $listener = ...;

   # create a pool template, initialise it and give it the socket
   my $pool = AnyEvent::Fork
                 ->new
                 ->require ("Some::Stuff", "My::Server")
                 ->send_fh ($listener);

   # now create 10 identical workers
   for my $id (1..10) {
      $pool
         ->fork
         ->send_arg ($id)
         ->run ("My::Server::run");
   }

   # now do other things - maybe use the filehandle provided by run
   # to wait for the processes to die. or whatever.

   # My::Server::run might look like this
   sub My::Server::run {
      my ($slave, $listener, $id) = @_;

      close $slave; # we do not use the socket, so close it to save resources

      # we could go ballistic and use e.g. AnyEvent here, or IO::AIO,
      # or anything we usually couldn't do in a process forked normally.
      while (my $socket = $listener->accept) {
         # do sth. with new socket
      }
   }

=head1 DESCRIPTION

This module allows you to create new processes, without actually forking
them from your current process (avoiding the problems of forking), but
preserving most of the advantages of fork.

It can be used to create new worker processes or new independent
subprocesses for short- and long-running jobs, process pools (e.g. for use
in pre-forked servers) but also to spawn new external processes (such as
CGI scripts from a webserver), which can be faster (and more well behaved)
than using fork+exec in big processes.

Special care has been taken to make this module useful from other modules,
while still supporting specialised environments such as L<App::Staticperl>
or L<PAR::Packer>.

=head1 PROBLEM STATEMENT

There are two ways to implement parallel processing on UNIX like operating
systems - fork and process, and fork+exec and process. They have different
advantages and disadvantages that I describe below, together with how this
module tries to mitigate the disadvantages.

=over 4

=item Forking from a big process can be very slow (a 5GB process needs
0.05s to fork on my 3.6GHz amd64 GNU/Linux box for example). This overhead
is often shared with exec (because you have to fork first), but in some
circumstances (e.g. when vfork is used), fork+exec can be much faster.

This module can help here by telling a small(er) helper process to fork,
or fork+exec instead.

=item Forking usually creates a copy-on-write copy of the parent
process. Memory (for example, modules or data files that have been
will not take additional memory). When exec'ing a new process, modules
and data files might need to be loaded again, at extra cpu and memory
cost. Likewise when forking, all data structures are copied as well - if
the program frees them and replaces them by new data, the child processes
will retain the memory even if it isn't used.

This module allows the main program to do a controlled fork, and allows
modules to exec processes safely at any time. When creating a custom
process pool you can take advantage of data sharing via fork without
risking to share large dynamic data structures that will blow up child
memory usage.

=item Exec'ing a new perl process might be difficult and slow. For
example, it is not easy to find the correct path to the perl interpreter,
and all modules have to be loaded from disk again. Long running processes
might run into problems when perl is upgraded for example.

This module supports creating pre-initialised perl processes to be used
as template, and also tries hard to identify the correct path to the perl
interpreter. With a cooperative main program, exec'ing the interpreter
might not even be necessary.

=item Forking might be impossible when a program is running. For example,
POSIX makes it almost impossible to fork from a multithreaded program and
do anything useful in the child - strictly speaking, if your perl program
uses posix threads (even indirectly via e.g. L<IO::AIO> or L<threads>),
you cannot call fork on the perl level anymore, at all.

This module can safely fork helper processes at any time, by caling
fork+exec in C, in a POSIX-compatible way.

=item Parallel processing with fork might be inconvenient or difficult
to implement. For example, when a program uses an event loop and creates
watchers it becomes very hard to use the event loop from a child
program, as the watchers already exist but are only meaningful in the
parent. Worse, a module might want to use such a system, not knowing
whether another module or the main program also does, leading to problems.

This module only lets the main program create pools by forking (because
only the main program can know when it is still safe to do so) - all other
pools are created by fork+exec, after which such modules can again be
loaded.

=back

=head1 CONCEPTS

This module can create new processes either by executing a new perl
process, or by forking from an existing "template" process.

Each such process comes with its own file handle that can be used to
communicate with it (it's actually a socket - one end in the new process,
one end in the main process), and among the things you can do in it are
load modules, fork new processes, send file handles to it, and execute
functions.

There are multiple ways to create additional processes to execute some
jobs:

=over 4

=item fork a new process from the "default" template process, load code,
run it

This module has a "default" template process which it executes when it is
needed the first time. Forking from this process shares the memory used
for the perl interpreter with the new process, but loading modules takes
time, and the memory is not shared with anything else.

This is ideal for when you only need one extra process of a kind, with the
option of starting and stipping it on demand.

Example:

   AnyEvent::Fork
      ->new
      ->require ("Some::Module")
      ->run ("Some::Module::run", sub {
         my ($fork_fh) = @_;
      });

=item fork a new template process, load code, then fork processes off of
it and run the code

When you need to have a bunch of processes that all execute the same (or
very similar) tasks, then a good way is to create a new template process
for them, loading all the modules you need, and then create your worker
processes from this new template process.

This way, all code (and data structures) that can be shared (e.g. the
modules you loaded) is shared between the processes, and each new process
consumes relatively little memory of its own.

The disadvantage of this approach is that you need to create a template
process for the sole purpose of forking new processes from it, but if you
only need a fixed number of proceses you can create them, and then destroy
the template process.

Example:

   my $template = AnyEvent::Fork->new->require ("Some::Module");
   
   for (1..10) {
      $template->fork->run ("Some::Module::run", sub {
         my ($fork_fh) = @_;
      });
   }

   # at this point, you can keep $template around to fork new processes
   # later, or you can destroy it, which causes it to vanish.

=item execute a new perl interpreter, load some code, run it

This is relatively slow, and doesn't allow you to share memory between
multiple processes.

The only advantage is that you don't have to have a template process
hanging around all the time to fork off some new processes, which might be
an advantage when there are long time spans where no extra processes are
needed.

Example:

   AnyEvent::Fork
      ->new_exec
      ->require ("Some::Module")
      ->run ("Some::Module::run", sub {
         my ($fork_fh) = @_;
      });

=back

=head1 FUNCTIONS

=over 4

=cut

package AnyEvent::Fork;

use common::sense;

use Socket ();

use AnyEvent;
use AnyEvent::Util ();

use IO::FDPass;

our $VERSION = 0.2;

our $PERL; # the path to the perl interpreter, deduces with various forms of magic

=item my $pool = new AnyEvent::Fork key => value...

Create a new process pool. The following named parameters are supported:

=over 4

=back

=cut

# the early fork template process
our $EARLY;

# the empty template process
our $TEMPLATE;

sub _cmd {
   my $self = shift;

   #TODO: maybe append the packet to any existing string command already in the queue

   # ideally, we would want to use "a (w/a)*" as format string, but perl versions
   # from at least 5.8.9 to 5.16.3 are all buggy and can't unpack it.
   push @{ $self->[2] }, pack "N/a*", pack "(w/a*)*", @_;

   $self->[3] ||= AE::io $self->[1], 1, sub {
      # send the next "thing" in the queue - either a reference to an fh,
      # or a plain string.

      if (ref $self->[2][0]) {
         # send fh
         IO::FDPass::send fileno $self->[1], fileno ${ $self->[2][0] }
            and shift @{ $self->[2] };

      } else {
         # send string
         my $len = syswrite $self->[1], $self->[2][0]
            or do { undef $self->[3]; die "AnyEvent::Fork: command write failure: $!" };

         substr $self->[2][0], 0, $len, "";
         shift @{ $self->[2] } unless length $self->[2][0];
      }

      unless (@{ $self->[2] }) {
         undef $self->[3];
         # invoke run callback
         $self->[0]->($self->[1]) if $self->[0];
      }
   };

   () # make sure we don't leak the watcher
}

sub _new {
   my ($self, $fh) = @_;

   AnyEvent::Util::fh_nonblocking $fh, 1;

   $self = bless [
      undef, # run callback
      $fh,
      [],    # write queue - strings or fd's
      undef, # AE watcher
   ], $self;

   $self
}

# fork template from current process, used by AnyEvent::Fork::Early/Template
sub _new_fork {
   my ($fh, $slave) = AnyEvent::Util::portable_socketpair;
   my $parent = $$;

   my $pid = fork;

   if ($pid eq 0) {
      require AnyEvent::Fork::Serve;
      $AnyEvent::Fork::Serve::OWNER = $parent;
      close $fh;
      $0 = "$_[1] of $parent";
      AnyEvent::Fork::Serve::serve ($slave);
      exit 0;
   } elsif (!$pid) {
      die "AnyEvent::Fork::Early/Template: unable to fork template process: $!";
   }

   AnyEvent::Fork->_new ($fh)
}

=item my $proc = new AnyEvent::Fork

Create a new "empty" perl interpreter process and returns its process
object for further manipulation.

The new process is forked from a template process that is kept around
for this purpose. When it doesn't exist yet, it is created by a call to
C<new_exec> and kept around for future calls.

When the process object is destroyed, it will release the file handle
that connects it with the new process. When the new process has not yet
called C<run>, then the process will exit. Otherwise, what happens depends
entirely on the code that is executed.

=cut

sub new {
   my $class = shift;

   $TEMPLATE ||= $class->new_exec;
   $TEMPLATE->fork
}

=item $new_proc = $proc->fork

Forks C<$proc>, creating a new process, and returns the process object
of the new process.

If any of the C<send_> functions have been called before fork, then they
will be cloned in the child. For example, in a pre-forked server, you
might C<send_fh> the listening socket into the template process, and then
keep calling C<fork> and C<run>.

=cut

sub fork {
   my ($self) = @_;

   my ($fh, $slave) = AnyEvent::Util::portable_socketpair;

   $self->send_fh ($slave);
   $self->_cmd ("f");

   AnyEvent::Fork->_new ($fh)
}

=item my $proc = new_exec AnyEvent::Fork

Create a new "empty" perl interpreter process and returns its process
object for further manipulation.

Unlike the C<new> method, this method I<always> spawns a new perl process
(except in some cases, see L<AnyEvent::Fork::Early> for details). This
reduces the amount of memory sharing that is possible, and is also slower.

You should use C<new> whenever possible, except when having a template
process around is unacceptable.

The path to the perl interpreter is divined usign various methods - first
C<$^X> is investigated to see if the path ends with something that sounds
as if it were the perl interpreter. Failing this, the module falls back to
using C<$Config::Config{perlpath}>.

=cut

sub new_exec {
   my ($self) = @_;

   return $EARLY->fork
      if $EARLY;

   # first find path of perl
   my $perl = $;

   # first we try $^X, but the path must be absolute (always on win32), and end in sth.
   # that looks like perl. this obviously only works for posix and win32
   unless (
      ($^O eq "MSWin32" || $perl =~ m%^/%)
      && $perl =~ m%[/\\]perl(?:[0-9]+(\.[0-9]+)+)?(\.exe)?$%i
   ) {
      # if it doesn't look perlish enough, try Config
      require Config;
      $perl = $Config::Config{perlpath};
      $perl =~ s/(?:\Q$Config::Config{_exe}\E)?$/$Config::Config{_exe}/;
   }

   require Proc::FastSpawn;

   my ($fh, $slave) = AnyEvent::Util::portable_socketpair;
   Proc::FastSpawn::fd_inherit (fileno $slave);

   # new fh's should always be set cloexec (due to $^F),
   # but hey, not on win32, so we always clear the inherit flag.
   Proc::FastSpawn::fd_inherit (fileno $fh, 0);

   # quick. also doesn't work in win32. of course. what did you expect
   #local $ENV{PERL5LIB} = join ":", grep !ref, @INC;
   my %env = %ENV;
   $env{PERL5LIB} = join +($^O eq "MSWin32" ? ";" : ":"), grep !ref, @INC;

   Proc::FastSpawn::spawn (
      $perl,
      ["perl", "-MAnyEvent::Fork::Serve", "-e", "AnyEvent::Fork::Serve::me", fileno $slave, $$],
      [map "$_=$env{$_}", keys %env],
   ) or die "unable to spawn AnyEvent::Fork server: $!";

   $self->_new ($fh)
}

=item $proc = $proc->eval ($perlcode, @args)

Evaluates the given C<$perlcode> as ... perl code, while setting C<@_> to
the strings specified by C<@args>.

This call is meant to do any custom initialisation that might be required
(for example, the C<require> method uses it). It's not supposed to be used
to completely take over the process, use C<run> for that.

The code will usually be executed after this call returns, and there is no
way to pass anything back to the calling process. Any evaluation errors
will be reported to stderr and cause the process to exit.

Returns the process object for easy chaining of method calls.

=cut

sub eval {
   my ($self, $code, @args) = @_;

   $self->_cmd (e => $code, @args);

   $self
}

=item $proc = $proc->require ($module, ...)

Tries to load the given module(s) into the process

Returns the process object for easy chaining of method calls.

=cut

sub require {
   my ($self, @modules) = @_;

   s%::%/%g for @modules;
   $self->eval ('require "$_.pm" for @_', @modules);

   $self
}

=item $proc = $proc->send_fh ($handle, ...)

Send one or more file handles (I<not> file descriptors) to the process,
to prepare a call to C<run>.

The process object keeps a reference to the handles until this is done,
so you must not explicitly close the handles. This is most easily
accomplished by simply not storing the file handles anywhere after passing
them to this method.

Returns the process object for easy chaining of method calls.

Example: pass an fh to a process, and release it without closing. it will
be closed automatically when it is no longer used.

   $proc->send_fh ($my_fh);
   undef $my_fh; # free the reference if you want, but DO NOT CLOSE IT

=cut

sub send_fh {
   my ($self, @fh) = @_;

   for my $fh (@fh) {
      $self->_cmd ("h");
      push @{ $self->[2] }, \$fh;
   }

   $self
}

=item $proc = $proc->send_arg ($string, ...)

Send one or more argument strings to the process, to prepare a call to
C<run>. The strings can be any octet string.

Returns the process object for easy chaining of emthod calls.

=cut

sub send_arg {
   my ($self, @arg) = @_;

   $self->_cmd (a => @arg);

   $self
}

=item $proc->run ($func, $cb->($fh))

Enter the function specified by the fully qualified name in C<$func> in
the process. The function is called with the communication socket as first
argument, followed by all file handles and string arguments sent earlier
via C<send_fh> and C<send_arg> methods, in the order they were called.

If the called function returns, the process exits.

Preparing the process can take time - when the process is ready, the
callback is invoked with the local communications socket as argument.

The process object becomes unusable on return from this function.

If the communication socket isn't used, it should be closed on both sides,
to save on kernel memory.

The socket is non-blocking in the parent, and blocking in the newly
created process. The close-on-exec flag is set on both. Even if not used
otherwise, the socket can be a good indicator for the existance of the
process - if the other process exits, you get a readable event on it,
because exiting the process closes the socket (if it didn't create any
children using fork).

Example: create a template for a process pool, pass a few strings, some
file handles, then fork, pass one more string, and run some code.

   my $pool = AnyEvent::Fork
                 ->new
                 ->send_arg ("str1", "str2")
                 ->send_fh ($fh1, $fh2);

   for (1..2) {
      $pool
         ->fork
         ->send_arg ("str3")
         ->run ("Some::function", sub {
            my ($fh) = @_;

            # fh is nonblocking, but we trust that the OS can accept these
            # extra 3 octets anyway.
            syswrite $fh, "hi #$_\n";

            # $fh is being closed here, as we don't store it anywhere
         });
   }

   # Some::function might look like this - all parameters passed before fork
   # and after will be passed, in order, after the communications socket.
   sub Some::function {
      my ($fh, $str1, $str2, $fh1, $fh2, $str3) = @_;

      print scalar <$fh>; # prints "hi 1\n" and "hi 2\n"
   }

=cut

sub run {
   my ($self, $func, $cb) = @_;

   $self->[0] = $cb;
   $self->_cmd (r => $func);
}

=back

=head1 TYPICAL PROBLEMS

This section lists typical problems that remain. I hope by recognising
them, most can be avoided.

=over 4

=item "leaked" file descriptors for exec'ed processes

POSIX systems inherit file descriptors by default when exec'ing a new
process. While perl itself laudably sets the close-on-exec flags on new
file handles, most C libraries don't care, and even if all cared, it's
often not possible to set the flag in a race-free manner.

That means some file descriptors can leak through. And since it isn't
possible to know which file descriptors are "good" and "neccessary" (or
even to know which file descreiptors are open), there is no good way to
close the ones that might harm.

As an example of what "harm" can be done consider a web server that
accepts connections and afterwards some module uses AnyEvent::Fork for the
first time, causing it to fork and exec a new process, which might inherit
the network socket. When the server closes the socket, it is still open
in the child (which doesn't even know that) and the client might conclude
that the connection is still fine.

For the main program, there are multiple remedies available -
L<AnyEvent::Fork::Early> is one, creating a process early and not using
C<new_exec> is another, as in both cases, the first process can be exec'ed
well before many random file descriptors are open.

In general, the solution for these kind of problems is to fix the
libraries or the code that leaks those file descriptors.

Fortunately, most of these lekaed descriptors do no harm, other than
sitting on some resources.

=item "leaked" file descriptors for fork'ed processes

Normally, L<AnyEvent::Fork> does start new processes by exec'ing them,
which closes file descriptors not marked for being inherited.

However, L<AnyEvent::Fork::Early> and L<AnyEvent::Fork::Template> offer
a way to create these processes by forking, and this leaks more file
descriptors than exec'ing them, as there is no way to mark descriptors as
"close on fork".

An example would be modules like L<EV>, L<IO::AIO> or L<Gtk2>. Both create
pipes for internal uses, and L<Gtk2> might open a connection to the X
server. L<EV> and L<IO::AIO> can deal with fork, but Gtk2 might have
trouble with a fork.

The solution is to either not load these modules before use'ing
L<AnyEvent::Fork::Early> or L<AnyEvent::Fork::Template>, or to delay
initialising them, for example, by calling C<init Gtk2> manually.

=back

=head1 PORTABILITY NOTES

Native win32 perls are somewhat supported (AnyEvent::Fork::Early is a nop,
and ::Template is not going to work), and it cost a lot of blood and sweat
to make it so, mostly due to the bloody broken perl that nobody seems to
care about. The fork emulation is a bad joke - I have yet to see something
useful that you cna do with it without running into memory corruption
issues or other braindamage. Hrrrr.

Cygwin perl is not supported at the moment, as it should implement fd
passing, but doesn't, and rolling my own is hard, as cygwin doesn't
support enough functionality to do it.

=head1 SEE ALSO

L<AnyEvent::Fork::Early> (to avoid executing a perl interpreter),
L<AnyEvent::Fork::Template> (to create a process by forking the main
program at a convenient time).

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

