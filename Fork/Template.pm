=head1 NAME

AnyEvent::Fork::Template - generate a template process from the main program

=head1 SYNOPSIS

   # only usable in the main program

   # preload some harmless modules (just examples)
   use Other::Module;
   use Some::Harmless::Module;
   use My::Worker::Module;

   # now fork and keep the template
   use AnyEvent::Fork::Template;

   # now do less harmless stuff (just examples)
   use Gtk2 -init;
   my $w = AE::io ...;

   # and finally, use the template to run some workers
   $TEMPLATE->fork->run ("My::Worker::Module::run_worker", sub { ... });

=head1 DESCRIPTION

=head1 EXPORTS

By default, this module exports the C<$TEMPLATE> variable.

=cut

package AnyEvent::Fork::Template;

use AnyEvent::Fork ();

require Exporter;

our @ISA = Exporter::;
our @EXPORT = qw($TEMPLATE);

# this does not work on win32, due to the atrociously bad fake perl fork
die "AnyEvent::Fork::Template does not work on WIN32 due to bugs in perl\n"
   if AnyEvent::Fork::Util::WIN32;

our $TEMPLATE = AnyEvent::Fork->_new_fork ("fork/template");

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

