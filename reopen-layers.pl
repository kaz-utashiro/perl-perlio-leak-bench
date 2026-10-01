# The reproducer from perl/perl5#12249 (RT 113982, 2012): after
# re-opening STDOUT over a dup of itself, are the :utf8 layers still
# there -- on the input side and on the output side?
#
# The result is written to a file, never to STDOUT, because printing to
# the handle under test perturbs the measurement.  Run it once with
# STDOUT on a regular file and once on a pipe: the answer differs.
use strict; use warnings;

my $dir  = $ENV{TMPDIR} || '/tmp';
my $slot = $ENV{PROBE_SLOT} || 'x';

my $dest = -f STDOUT ? 'file' : -p STDOUT ? 'pipe' : -c STDOUT ? 'chr' : 'other';

binmode STDOUT, ':utf8';
my $has = sub { grep { $_ eq 'utf8' } @_ };
my %r;
$r{in_before}  = $has->(PerlIO::get_layers(*STDOUT))               ? 'utf8' : 'NO';
$r{out_before} = $has->(PerlIO::get_layers(*STDOUT, output => 1))  ? 'utf8' : 'NO';

open my $fh, '>&STDOUT' or die "can't dup: $!";
open STDOUT, '>&', $fh  or die "can't dup2: $!";

$r{in_after}  = $has->(PerlIO::get_layers(*STDOUT))              ? 'utf8' : 'NO';
$r{out_after} = $has->(PerlIO::get_layers(*STDOUT, output => 1)) ? 'utf8' : 'NO';
$r{fh_out}    = $has->(PerlIO::get_layers($fh, output => 1))     ? 'utf8' : 'NO';
$r{verdict}   = ($r{out_after} eq 'utf8' && $r{fh_out} eq 'utf8')
              ? 'PRESERVED' : 'CLOBBERED';

open my $out, '>', "$dir/reopen-$slot-$$.out" or die $!;
printf {$out} "RESULT perl=%vd dest=%s %s\n", $^V, $dest,
    join ' ', map { "$_=$r{$_}" } qw(in_before out_before in_after out_after fh_out verdict);
close $out;
