BEGIN {
   if ($^O eq "MSWin32") {
      print "1..0 # SKIP broken perl detected, skipping\n";
      exit;
   }
}

BEGIN { $| = 1; print "1..3\n"; }

use AnyEvent::Fork::Template;

print $TEMPLATE ? "" : "not ", "ok 1\n";

$TEMPLATE->eval ('print "ok 2\n"; exit 0');

my $w = AE::io $TEMPLATE->[1], 0, my $cv = AE::cv;
$cv->recv;

print "ok 3\n";
