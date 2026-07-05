# Repeatedly redirect STDOUT with :encoding layer and restore, in the
# way a nofork-style executor does.  Watch the layer stack grow.
use strict; use warnings;
use Time::HiRes qw(time);
my $tmpf = "/tmp/leak-$$-a.tmp";
my $iof  = "/tmp/leak-$$-b.tmp";
open my $tmp, '+>', $tmpf or die $!;

sub cycles {
    my $n = shift;
    for (1 .. $n) {
        open my $save, '>&', \*STDOUT or die $!;
        open STDOUT, '>&', $tmp or die $!;
        binmode STDOUT, ':encoding(utf8)';
        open STDOUT, '>&', $save or die $!;
        close $save;
    }
}
sub unrelated_io {
    my $t = time;
    for (1 .. 1000) {
        open my $w, '>', $iof or die $!; print $w "x" x 100; close $w;
        open my $r, '<', $iof or die $!; my $x = <$r>; close $r;
    }
    time - $t;
}
my $u0 = unrelated_io();
my(@sec, @nlayers);
for my $round (1 .. 3) {
    my $t = time;
    cycles(300);
    push @sec, time - $t;
    push @nlayers, scalar(() = PerlIO::get_layers(STDOUT));
}
my $u1 = unrelated_io();
my($rss) = `ps -o rss= -p $$` =~ /(\d+)/;
printf STDERR "RESULT perl=%vd sec=%.2f/%.2f/%.2f layers=%d/%d/%d rss=%dKB unrelated=%.3f->%.3f verdict=%s\n",
    $^V, @sec, @nlayers, $rss, $u0, $u1,
    ($nlayers[2] > $nlayers[0] ? "GROW" : "ok");
unlink $tmpf, $iof;
