=head1 NAME

AnyEvent::Fork::Util - internal module

=head1 SYNOPSIS

   # none

=head1 DESCRIPTION

This module implements utility functions for L<AnyEvent::Fork>. It has no
user-servicable parts inside.

=cut

package AnyEvent::Fork::Util;

BEGIN {
  our $VERSION = '0.01';

  require XSLoader;
  XSLoader::load ("AnyEvent::Fork", $VERSION);
}

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

