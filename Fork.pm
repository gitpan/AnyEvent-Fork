=head1 NAME

AnyEvent::Fork - everything you wanted to use fork() for, but couldn't

=head1 SYNOPSIS

   use AnyEvent::Fork;

   AnyEvent::Fork
      ->new
      ->require ("MyModule")
      ->run ("MyModule::server", my $cv = AE::cv);

   my $fh = $cv->recv;

=head1 DESCRIPTION

This module allows you to create new processes, without actually forking
them from your current process (avoiding the problems of forking), but
preserving most of the advantages of fork.

It can be used to create new worker processes or new independent
subprocesses for short- and long-running jobs, process pools (e.g. for use
in pre-forked servers) but also to spawn new external processes (such as
CGI scripts from a web server), which can be faster (and more well behaved)
than using fork+exec in big processes.

Special care has been taken to make this module useful from other modules,
while still supporting specialised environments such as L<App::Staticperl>
or L<PAR::Packer>.

=head2 WHAT THIS MODULE IS NOT

This module only creates processes and lets you pass file handles and
strings to it, and run perl code. It does not implement any kind of RPC -
there is no back channel from the process back to you, and there is no RPC
or message passing going on.

If you need some form of RPC, you could use the L<AnyEvent::Fork::RPC>
companion module, which adds simple RPC/job queueing to a process created
by this module.

And if you need some automatic process pool management on top of
L<AnyEvent::Fork::RPC>, you can look at the L<AnyEvent::Fork::Pool>
companion module.

Or you can implement it yourself in whatever way you like: use some
message-passing module such as L<AnyEvent::MP>, some pipe such as
L<AnyEvent::ZeroMQ>, use L<AnyEvent::Handle> on both sides to send
e.g. JSON or Storable messages, and so on.

=head2 COMPARISON TO OTHER MODULES

There is an abundance of modules on CPAN that do "something fork", such as
L<Parallel::ForkManager>, L<AnyEvent::ForkManager>, L<AnyEvent::Worker>
or L<AnyEvent::Subprocess>. There are modules that implement their own
process management, such as L<AnyEvent::DBI>.

The problems that all these modules try to solve are real, however, none
of them (from what I have seen) tackle the very real problems of unwanted
memory sharing, efficiency, not being able to use event processing or
similar modules in the processes they create.

This module doesn't try to replace any of them - instead it tries to solve
the problem of creating processes with a minimum of fuss and overhead (and
also luxury). Ideally, most of these would use AnyEvent::Fork internally,
except they were written before AnyEvent:Fork was available, so obviously
had to roll their own.

=head2 PROBLEM STATEMENT

There are two traditional ways to implement parallel processing on UNIX
like operating systems - fork and process, and fork+exec and process. They
have different advantages and disadvantages that I describe below,
together with how this module tries to mitigate the disadvantages.

=over 4

=item Forking from a big process can be very slow.

A 5GB process needs 0.05s to fork on my 3.6GHz amd64 GNU/Linux box. This
overhead is often shared with exec (because you have to fork first), but
in some circumstances (e.g. when vfork is used), fork+exec can be much
faster.

This module can help here by telling a small(er) helper process to fork,
which is faster then forking the main process, and also uses vfork where
possible. This gives the speed of vfork, with the flexibility of fork.

=item Forking usually creates a copy-on-write copy of the parent
process.

For example, modules or data files that are loaded will not use additional
memory after a fork. When exec'ing a new process, modules and data files
might need to be loaded again, at extra CPU and memory cost. But when
forking, literally all data structures are copied - if the program frees
them and replaces them by new data, the child processes will retain the
old version even if it isn't used, which can suddenly and unexpectedly
increase memory usage when freeing memory.

The trade-off is between more sharing with fork (which can be good or
bad), and no sharing with exec.

This module allows the main program to do a controlled fork, and allows
modules to exec processes safely at any time. When creating a custom
process pool you can take advantage of data sharing via fork without
risking to share large dynamic data structures that will blow up child
memory usage.

In other words, this module puts you into control over what is being
shared and what isn't, at all times.

=item Exec'ing a new perl process might be difficult.

For example, it is not easy to find the correct path to the perl
interpreter - C<$^X> might not be a perl interpreter at all.

This module tries hard to identify the correct path to the perl
interpreter. With a cooperative main program, exec'ing the interpreter
might not even be necessary, but even without help from the main program,
it will still work when used from a module.

=item Exec'ing a new perl process might be slow, as all necessary modules
have to be loaded from disk again, with no guarantees of success.

Long running processes might run into problems when perl is upgraded
and modules are no longer loadable because they refer to a different
perl version, or parts of a distribution are newer than the ones already
loaded.

This module supports creating pre-initialised perl processes to be used as
a template for new processes.

=item Forking might be impossible when a program is running.

For example, POSIX makes it almost impossible to fork from a
multi-threaded program while doing anything useful in the child - in
fact, if your perl program uses POSIX threads (even indirectly via
e.g. L<IO::AIO> or L<threads>), you cannot call fork on the perl level
anymore without risking corruption issues on a number of operating
systems.

This module can safely fork helper processes at any time, by calling
fork+exec in C, in a POSIX-compatible way (via L<Proc::FastSpawn>).

=item Parallel processing with fork might be inconvenient or difficult
to implement. Modules might not work in both parent and child.

For example, when a program uses an event loop and creates watchers it
becomes very hard to use the event loop from a child program, as the
watchers already exist but are only meaningful in the parent. Worse, a
module might want to use such a module, not knowing whether another module
or the main program also does, leading to problems.

Apart from event loops, graphical toolkits also commonly fall into the
"unsafe module" category, or just about anything that communicates with
the external world, such as network libraries and file I/O modules, which
usually don't like being copied and then allowed to continue in two
processes.

With this module only the main program is allowed to create new processes
by forking (because only the main program can know when it is still safe
to do so) - all other processes are created via fork+exec, which makes it
possible to use modules such as event loops or window interfaces safely.

=back

=head1 EXAMPLES

=head2 Create a single new process, tell it to run your worker function.

   AnyEvent::Fork
      ->new
      ->require ("MyModule")
      ->run ("MyModule::worker, sub {
         my ($master_filehandle) = @_;

         # now $master_filehandle is connected to the
         # $slave_filehandle in the new process.
      });

C<MyModule> might look like this:

   package MyModule;

   sub worker {
      my ($slave_filehandle) = @_;

      # now $slave_filehandle is connected to the $master_filehandle
      # in the original prorcess. have fun!
   }

=head2 Create a pool of server processes all accepting on the same socket.

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

C<My::Server> might look like this:

   package My::Server;

   sub run {
      my ($slave, $listener, $id) = @_;

      close $slave; # we do not use the socket, so close it to save resources

      # we could go ballistic and use e.g. AnyEvent here, or IO::AIO,
      # or anything we usually couldn't do in a process forked normally.
      while (my $socket = $listener->accept) {
         # do sth. with new socket
      }
   }

=head2 use AnyEvent::Fork as a faster fork+exec

This runs C</bin/echo hi>, with standard output redirected to F</tmp/log>
and standard error redirected to the communications socket. It is usually
faster than fork+exec, but still lets you prepare the environment.

   open my $output, ">/tmp/log" or die "$!";

   AnyEvent::Fork
      ->new
      ->eval ('
           # compile a helper function for later use
           sub run {
              my ($fh, $output, @cmd) = @_;

              # perl will clear close-on-exec on STDOUT/STDERR
              open STDOUT, ">&", $output or die;
              open STDERR, ">&", $fh or die;

              exec @cmd;
           }
        ')
      ->send_fh ($output)
      ->send_arg ("/bin/echo", "hi")
      ->run ("run", my $cv = AE::cv);

   my $stderr = $cv->recv;

=head2 For stingy users: put the worker code into a C<DATA> section.

When you want to be stingy with files, you cna put your code into the
C<DATA> section of your module (or program):

   use AnyEvent::Fork;

   AnyEvent::Fork
      ->new
      ->eval (do { local $/; <DATA> })
      ->run ("doit", sub { ... });

   __DATA__

   sub doit {
      ... do something!
   }

=head2 For stingy standalone programs: do not rely on external files at
all.

For single-file scripts it can be inconvenient to rely on external
files - even when using < C<DATA> section, you still need to C<exec>
an external perl interpreter, which might not be available when using
L<App::Staticperl>, L<Urlader> or L<PAR::Packer> for example.

Two modules help here - L<AnyEvent::Fork::Early> forks a template process
for all further calls to C<new_exec>, and L<AnyEvent::Fork::Template>
forks the main program as a template process.

Here is how your main program should look like:

   #! perl

   # optional, as the very first thing.
   # in case modules want to create their own processes.
   use AnyEvent::Fork::Early;

   # next, load all modules you need in your template process
   use Example::My::Module
   use Example::Whatever;

   # next, put your run function definition and anything else you
   # need, but do not use code outside of BEGIN blocks.
   sub worker_run {
      my ($fh, @args) = @_;
      ...
   }

   # now preserve everything so far as AnyEvent::Fork object
   # in §TEMPLATE.
   use AnyEvent::Fork::Template;

   # do not put code outside of BEGIN blocks until here

   # now use the $TEMPLATE process in any way you like

   # for example: create 10 worker processes
   my @worker;
   my $cv = AE::cv;
   for (1..10) {
      $cv->begin;
      $TEMPLATE->fork->send_arg ($_)->run ("worker_run", sub {
         push @worker, shift;
         $cv->end;
      });
   }
   $cv->recv;

=head1 CONCEPTS

This module can create new processes either by executing a new perl
process, or by forking from an existing "template" process.

All these processes are called "child processes" (whether they are direct
children or not), while the process that manages them is called the
"parent process".

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
option of starting and stopping it on demand.

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
only need a fixed number of processes you can create them, and then destroy
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

=head1 THE C<AnyEvent::Fork> CLASS

This module exports nothing, and only implements a single class -
C<AnyEvent::Fork>.

There are two class constructors that both create new processes - C<new>
and C<new_exec>. The C<fork> method creates a new process by forking an
existing one and could be considered a third constructor.

Most of the remaining methods deal with preparing the new process, by
loading code, evaluating code and sending data to the new process. They
usually return the process object, so you can chain method calls.

If a process object is destroyed before calling its C<run> method, then
the process simply exits. After C<run> is called, all responsibility is
passed to the specified function.

As long as there is any outstanding work to be done, process objects
resist being destroyed, so there is no reason to store them unless you
need them later - configure and forget works just fine.

=over 4

=cut

package AnyEvent::Fork;

use common::sense;

use Errno ();

use AnyEvent;
use AnyEvent::Util ();

use IO::FDPass;

our $VERSION = 1.2;

# the early fork template process
our $EARLY;

# the empty template process
our $TEMPLATE;

sub QUEUE() { 0 }
sub FH()    { 1 }
sub WW()    { 2 }
sub PID()   { 3 }
sub CB()    { 4 }

sub _new {
   my ($self, $fh, $pid) = @_;

   AnyEvent::Util::fh_nonblocking $fh, 1;

   $self = bless [
      [],    # write queue - strings or fd's
      $fh,
      undef, # AE watcher
      $pid,
   ], $self;

   $self
}

sub _cmd {
   my $self = shift;

   # ideally, we would want to use "a (w/a)*" as format string, but perl
   # versions from at least 5.8.9 to 5.16.3 are all buggy and can't unpack
   # it.
   push @{ $self->[QUEUE] }, pack "a L/a*", $_[0], $_[1];

   $self->[WW] ||= AE::io $self->[FH], 1, sub {
      do {
         # send the next "thing" in the queue - either a reference to an fh,
         # or a plain string.

         if (ref $self->[QUEUE][0]) {
            # send fh
            unless (IO::FDPass::send fileno $self->[FH], fileno ${ $self->[QUEUE][0] }) {
               return if $! == Errno::EAGAIN || $! == Errno::EWOULDBLOCK;
               undef $self->[WW];
               die "AnyEvent::Fork: file descriptor send failure: $!";
            }

            shift @{ $self->[QUEUE] };

         } else {
            # send string
            my $len = syswrite $self->[FH], $self->[QUEUE][0];

            unless ($len) {
               return if $! == Errno::EAGAIN || $! == Errno::EWOULDBLOCK;
               undef $self->[WW];
               die "AnyEvent::Fork: command write failure: $!";
            }

            substr $self->[QUEUE][0], 0, $len, "";
            shift @{ $self->[QUEUE] } unless length $self->[QUEUE][0];
         }
      } while @{ $self->[QUEUE] };

      # everything written
      undef $self->[WW];

      # invoke run callback, if any
      if ($self->[CB]) {
         $self->[CB]->($self->[FH]);
         @$self = ();
      }
   };

   () # make sure we don't leak the watcher
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

   AnyEvent::Fork->_new ($fh, $pid)
}

=item my $proc = new AnyEvent::Fork

Create a new "empty" perl interpreter process and returns its process
object for further manipulation.

The new process is forked from a template process that is kept around
for this purpose. When it doesn't exist yet, it is created by a call to
C<new_exec> first and then stays around for future calls.

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

The path to the perl interpreter is divined using various methods - first
C<$^X> is investigated to see if the path ends with something that looks
as if it were the perl interpreter. Failing this, the module falls back to
using C<$Config::Config{perlpath}>.

The path to perl can also be overriden by setting the global variable
C<$AnyEvent::Fork::PERL> - it's value will be used for all subsequent
invocations.

=cut

our $PERL;

sub new_exec {
   my ($self) = @_;

   return $EARLY->fork
      if $EARLY;

   unless (defined $PERL) {
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

      $PERL = $perl;
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

   my $pid = Proc::FastSpawn::spawn (
      $PERL,
      ["perl", "-MAnyEvent::Fork::Serve", "-e", "AnyEvent::Fork::Serve::me", fileno $slave, $$],
      [map "$_=$env{$_}", keys %env],
   ) or die "unable to spawn AnyEvent::Fork server: $!";

   $self->_new ($fh, $pid)
}

=item $pid = $proc->pid

Returns the process id of the process I<iff it is a direct child of the
process running AnyEvent::Fork>, and C<undef> otherwise. As a general
rule (that you cannot rely upon), processes created via C<new_exec>,
L<AnyEvent::Fork::Early> or L<AnyEvent::Fork::Template> are direct
children, while all other processes are not.

Or in other words, you do not normally have to take care of zombies for
processes created via C<new>, but when in doubt, or zombies are a problem,
you need to check whether a process is a diretc child by calling this
method, and possibly creating a child watcher or reap it manually.

=cut

sub pid {
   $_[0][PID]
}

=item $proc = $proc->eval ($perlcode, @args)

Evaluates the given C<$perlcode> as ... Perl code, while setting C<@_> to
the strings specified by C<@args>, in the "main" package.

This call is meant to do any custom initialisation that might be required
(for example, the C<require> method uses it). It's not supposed to be used
to completely take over the process, use C<run> for that.

The code will usually be executed after this call returns, and there is no
way to pass anything back to the calling process. Any evaluation errors
will be reported to stderr and cause the process to exit.

If you want to execute some code (that isn't in a module) to take over the
process, you should compile a function via C<eval> first, and then call
it via C<run>. This also gives you access to any arguments passed via the
C<send_xxx> methods, such as file handles. See the L<use AnyEvent::Fork as
a faster fork+exec> example to see it in action.

Returns the process object for easy chaining of method calls.

=cut

sub eval {
   my ($self, $code, @args) = @_;

   $self->_cmd (e => pack "(w/a*)*", $code, @args);

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

The process object keeps a reference to the handles until they have
been passed over to the process, so you must not explicitly close the
handles. This is most easily accomplished by simply not storing the file
handles anywhere after passing them to this method - when AnyEvent::Fork
is finished using them, perl will automatically close them.

Returns the process object for easy chaining of method calls.

Example: pass a file handle to a process, and release it without
closing. It will be closed automatically when it is no longer used.

   $proc->send_fh ($my_fh);
   undef $my_fh; # free the reference if you want, but DO NOT CLOSE IT

=cut

sub send_fh {
   my ($self, @fh) = @_;

   for my $fh (@fh) {
      $self->_cmd ("h");
      push @{ $self->[QUEUE] }, \$fh;
   }

   $self
}

=item $proc = $proc->send_arg ($string, ...)

Send one or more argument strings to the process, to prepare a call to
C<run>. The strings can be any octet strings.

The protocol is optimised to pass a moderate number of relatively short
strings - while you can pass up to 4GB of data in one go, this is more
meant to pass some ID information or other startup info, not big chunks of
data.

Returns the process object for easy chaining of method calls.

=cut

sub send_arg {
   my ($self, @arg) = @_;

   $self->_cmd (a => pack "(w/a*)*", @arg);

   $self
}

=item $proc->run ($func, $cb->($fh))

Enter the function specified by the function name in C<$func> in the
process. The function is called with the communication socket as first
argument, followed by all file handles and string arguments sent earlier
via C<send_fh> and C<send_arg> methods, in the order they were called.

The process object becomes unusable on return from this function - any
further method calls result in undefined behaviour.

The function name should be fully qualified, but if it isn't, it will be
looked up in the C<main> package.

If the called function returns, doesn't exist, or any error occurs, the
process exits.

Preparing the process is done in the background - when all commands have
been sent, the callback is invoked with the local communications socket
as argument. At this point you can start using the socket in any way you
like.

If the communication socket isn't used, it should be closed on both sides,
to save on kernel memory.

The socket is non-blocking in the parent, and blocking in the newly
created process. The close-on-exec flag is set in both.

Even if not used otherwise, the socket can be a good indicator for the
existence of the process - if the other process exits, you get a readable
event on it, because exiting the process closes the socket (if it didn't
create any children using fork).

=over 4

=item Compatibility to L<AnyEvent::Fork::Remote>

If you want to write code that works with both this module and
L<AnyEvent::Fork::Remote>, you need to write your code so that it assumes
there are two file handles for communications, which might not be unix
domain sockets. The C<run> function should start like this:

   sub run {
      my ($rfh, @args) = @_; # @args is your normal arguments
      my $wfh = fileno $rfh ? $rfh : *STDOUT;

      # now use $rfh for reading and $wfh for writing
   }

This checks whether the passed file handle is, in fact, the process
C<STDIN> handle. If it is, then the function was invoked visa
L<AnyEvent::Fork::Remote>, so STDIN should be used for reading and
C<STDOUT> should be used for writing.

In all other cases, the function was called via this module, and there is
only one file handle that should be sued for reading and writing.

=back

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
            # few octets anyway.
            syswrite $fh, "hi #$_\n";

            # $fh is being closed here, as we don't store it anywhere
         });
   }

   # Some::function might look like this - all parameters passed before fork
   # and after will be passed, in order, after the communications socket.
   sub Some::function {
      my ($fh, $str1, $str2, $fh1, $fh2, $str3) = @_;

      print scalar <$fh>; # prints "hi #1\n" and "hi #2\n" in any order
   }

=cut

sub run {
   my ($self, $func, $cb) = @_;

   $self->[CB] = $cb;
   $self->_cmd (r => $func);
}

=back

=head2 EXPERIMENTAL METHODS

These methods might go away completely or change behaviour, at any time.

=over 4

=item $proc->to_fh ($cb->($fh))    # EXPERIMENTAL, MIGHT BE REMOVED

Flushes all commands out to the process and then calls the callback with
the communications socket.

The process object becomes unusable on return from this function - any
further method calls result in undefined behaviour.

The point of this method is to give you a file handle that you can pass
to another process. In that other process, you can call C<new_from_fh
AnyEvent::Fork $fh> to create a new C<AnyEvent::Fork> object from it,
thereby effectively passing a fork object to another process.

=cut

sub to_fh {
   my ($self, $cb) = @_;

   $self->[CB] = $cb;

   unless ($self->[WW]) {
      $self->[CB]->($self->[FH]);
      @$self = ();
   }
}

=item new_from_fh AnyEvent::Fork $fh    # EXPERIMENTAL, MIGHT BE REMOVED

Takes a file handle originally rceeived by the C<to_fh> method and creates
a new C<AnyEvent:Fork> object. The child process itself will not change in
any way, i.e. it will keep all the modifications done to it before calling
C<to_fh>.

The new object is very much like the original object, except that the
C<pid> method will return C<undef> even if the process is a direct child.

=cut

sub new_from_fh {
   my ($class, $fh) = @_;

   $class->_new ($fh)
}

=back

=head1 PERFORMANCE

Now for some unscientific benchmark numbers (all done on an amd64
GNU/Linux box). These are intended to give you an idea of the relative
performance you can expect, they are not meant to be absolute performance
numbers.

OK, so, I ran a simple benchmark that creates a socket pair, forks, calls
exit in the child and waits for the socket to close in the parent. I did
load AnyEvent, EV and AnyEvent::Fork, for a total process size of 5100kB.

   2079 new processes per second, using manual socketpair + fork

Then I did the same thing, but instead of calling fork, I called
AnyEvent::Fork->new->run ("CORE::exit") and then again waited for the
socket from the child to close on exit. This does the same thing as manual
socket pair + fork, except that what is forked is the template process
(2440kB), and the socket needs to be passed to the server at the other end
of the socket first.

   2307 new processes per second, using AnyEvent::Fork->new

And finally, using C<new_exec> instead C<new>, using vforks+execs to exec
a new perl interpreter and compile the small server each time, I get:

    479 vfork+execs per second, using AnyEvent::Fork->new_exec

So how can C<< AnyEvent->new >> be faster than a standard fork, even
though it uses the same operations, but adds a lot of overhead?

The difference is simply the process size: forking the 5MB process takes
so much longer than forking the 2.5MB template process that the extra
overhead is canceled out.

If the benchmark process grows, the normal fork becomes even slower:

   1340 new processes, manual fork of a 20MB process
    731 new processes, manual fork of a 200MB process
    235 new processes, manual fork of a 2000MB process

What that means (to me) is that I can use this module without having a bad
conscience because of the extra overhead required to start new processes.

=head1 TYPICAL PROBLEMS

This section lists typical problems that remain. I hope by recognising
them, most can be avoided.

=over 4

=item leaked file descriptors for exec'ed processes

POSIX systems inherit file descriptors by default when exec'ing a new
process. While perl itself laudably sets the close-on-exec flags on new
file handles, most C libraries don't care, and even if all cared, it's
often not possible to set the flag in a race-free manner.

That means some file descriptors can leak through. And since it isn't
possible to know which file descriptors are "good" and "necessary" (or
even to know which file descriptors are open), there is no good way to
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

Fortunately, most of these leaked descriptors do no harm, other than
sitting on some resources.

=item leaked file descriptors for fork'ed processes

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

=item exiting calls object destructors

This only applies to users of L<AnyEvent::Fork:Early> and
L<AnyEvent::Fork::Template>, or when initialising code creates objects
that reference external resources.

When a process created by AnyEvent::Fork exits, it might do so by calling
exit, or simply letting perl reach the end of the program. At which point
Perl runs all destructors.

Not all destructors are fork-safe - for example, an object that represents
the connection to an X display might tell the X server to free resources,
which is inconvenient when the "real" object in the parent still needs to
use them.

This is obviously not a problem for L<AnyEvent::Fork::Early>, as you used
it as the very first thing, right?

It is a problem for L<AnyEvent::Fork::Template> though - and the solution
is to not create objects with nontrivial destructors that might have an
effect outside of Perl.

=back

=head1 PORTABILITY NOTES

Native win32 perls are somewhat supported (AnyEvent::Fork::Early is a nop,
and ::Template is not going to work), and it cost a lot of blood and sweat
to make it so, mostly due to the bloody broken perl that nobody seems to
care about. The fork emulation is a bad joke - I have yet to see something
useful that you can do with it without running into memory corruption
issues or other braindamage. Hrrrr.

Since fork is endlessly broken on win32 perls (it doesn't even remotely
work within it's documented limits) and quite obviously it's not getting
improved any time soon, the best way to proceed on windows would be to
always use C<new_exec> and thus never rely on perl's fork "emulation".

Cygwin perl is not supported at the moment due to some hilarious
shortcomings of its API - see L<IO::FDPoll> for more details. If you never
use C<send_fh> and always use C<new_exec> to create processes, it should
work though.

=head1 SEE ALSO

L<AnyEvent::Fork::Early>, to avoid executing a perl interpreter at all
(part of this distribution).

L<AnyEvent::Fork::Template>, to create a process by forking the main
program at a convenient time (part of this distribution).

L<AnyEvent::Fork::Remote>, for another way to create processes that is
mostly compatible to this module and modules building on top of it, but
works better with remote processes.

L<AnyEvent::Fork::RPC>, for simple RPC to child processes (on CPAN).

L<AnyEvent::Fork::Pool>, for simple worker process pool (on CPAN).

=head1 AUTHOR AND CONTACT INFORMATION

 Marc Lehmann <schmorp@schmorp.de>
 http://software.schmorp.de/pkg/AnyEvent-Fork

=cut

1

