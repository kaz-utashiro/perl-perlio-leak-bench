# Does re-opening a handle over a dup keep the handle's own PerlIO
# layer stack, or adopt the dup source's?  Give the target and the dup
# source different layers so the two cases can be told apart.
use strict; use warnings;

my $dir = $ENV{TMPDIR} || '/tmp';
my $tag = "asym-$$";
my @tmp;
sub tmpname { my $f = "$dir/$tag-" . scalar(@tmp); push @tmp, $f; $f }
sub layers { join ' ', PerlIO::get_layers($_[0]) }
sub verdict { $_[0] =~ /cp932/ ? 'KEPT' : 'ADOPTED' }

my %result;

# plain dup sources, deliberately without the marker layer
open my $src_w, '>', tmpname() or die $!;
my $readable = tmpname();
open my $seed, '>', $readable or die $!; print {$seed} "x\n"; close $seed;
open my $src_r, '<', $readable or die $!;

# --- the three standard handles ---
binmode STDERR, ':encoding(cp932)';
open STDERR, '>&', $src_w or die $!;
$result{STDERR} = verdict(layers(\*STDERR));

binmode STDIN, ':encoding(cp932)';
open STDIN, '<&', $src_r or die $!;
$result{STDIN} = verdict(layers(\*STDIN));

binmode STDOUT, ':encoding(cp932)';
open STDOUT, '>&', $src_w or die $!;
$result{STDOUT} = verdict(layers(\*STDOUT));

# --- ordinary handles ---
open BAREWORD, '>', tmpname() or die $!;
binmode BAREWORD, ':encoding(cp932)';
open BAREWORD, '>&', $src_w or die $!;
$result{bareword} = verdict(layers(\*BAREWORD));

open my $lex, '>', tmpname() or die $!;
binmode $lex, ':encoding(cp932)';
open $lex, '>&', $src_w or die $!;
$result{lexical} = verdict(layers($lex));

# --- does the cycle accumulate, per handle kind? ---
sub cycles {
    my($fh, $n) = @_;
    open my $t, '+>', tmpname() or die $!;
    my $start = () = PerlIO::get_layers($fh);
    for (1 .. $n) {
        open my $save, '>&', $fh or die $!;
        open $fh, '>&', $t or die $!;
        binmode $fh, ':encoding(utf8)';
        open $fh, '>&', $save or die $!;
        close $save;
    }
    my $end = () = PerlIO::get_layers($fh);
    $end > $start ? 'GROW' : 'stable';
}
open ORD, '>', tmpname() or die $!;
$result{cycle_ordinary} = cycles(\*ORD, 5);
$result{cycle_STDOUT}   = cycles(\*STDOUT, 5);

# report on a handle we have not been mangling
open my $out, '>&', $src_w or die $!;
my @keys = qw(STDIN STDOUT STDERR bareword lexical cycle_ordinary cycle_STDOUT);
my $line = sprintf "RESULT perl=%vd %s\n", $^V,
    join ' ', map { "$_=$result{$_}" } @keys;
print {$out} $line;
open my $real, '>', "$dir/$tag.out" or die $!;
print {$real} $line;
close $real;
unlink @tmp;
