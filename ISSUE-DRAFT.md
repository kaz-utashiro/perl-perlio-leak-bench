# Title

Encoding layers accumulate without bound when a redirected filehandle is restored with open FH, '>&', ...

# Body

## Description

When a filehandle is redirected and restored with `open FH, '>&', ...`
while an `:encoding` layer is pushed in between — the natural way to
temporarily redirect STDOUT to a file in-process — the encoding layer
is not removed.  Repeating the cycle accumulates one layer pair per
iteration without bound:

- re-opening an existing filehandle over a dup keeps the handle's
  current layer stack instead of resetting it, and
- `binmode FH, ':encoding(utf8)'` pushes a new layer even when one is
  already present (#10454).

Every subsequent operation on the handle passes through the whole
stack, so a loop doing this is quadratic in time, and each leaked
layer keeps its buffers, so memory grows without bound.

## Steps to Reproduce

```perl
my $file = "/tmp/layers-$$.tmp";
open my $tmp, '+>', $file or die;
for my $i (1 .. 3) {
    open my $save, '>&', \*STDOUT or die;
    open STDOUT, '>&', $tmp or die;
    binmode STDOUT, ':encoding(utf8)';
    open STDOUT, '>&', $save or die;    # restore
    close $save;
    print STDERR "cycle $i: @{[ PerlIO::get_layers(STDOUT) ]}\n";
}
```

```
cycle 1: unix perlio encoding(utf8) utf8
cycle 2: unix perlio encoding(utf8) utf8 encoding(utf8) utf8
cycle 3: unix perlio encoding(utf8) utf8 encoding(utf8) utf8 encoding(utf8) utf8
```

Doing 3 rounds of 300 such cycles (ubuntu-latest, perl 5.42.2):

```
time per round:      0.56 / 2.11 / 4.70 sec     (quadratic)
STDOUT layer count:   602 / 1202 / 1802
process RSS after:   276 MB
```

I benchmarked 5.12.5 through 5.42.2 and blead built from source: the
behavior is identical in every version tested.  Unrelated file I/O
through other handles is not affected.  Results and workflows:
https://github.com/kaz-utashiro/perl-perlio-leak-bench

Replacing `:encoding(utf8)` with `:utf8`, or popping the layer with
`binmode STDOUT, ':pop'` before restoring, avoids the problem
entirely.

## Discussion

Each of the two ingredients may arguably be intended behavior on its
own — the layer-keeping of re-open over dup does not seem to be
documented either way, and the non-idempotency of binmode is #10454 —
but their combination turns an ordinary redirect-and-restore pattern
into an unbounded leak that is quite hard to diagnose (the handle
looks perfectly normal, and the slowdown creeps in gradually).

Possible directions, in decreasing order of ambition:

- make re-opening a filehandle reset its layer stack to the newly
  computed one (as a fresh open does);
- make pushing `:encoding` replace an existing topmost encoding layer
  instead of stacking (#10454);
- or at least document the accumulation hazard in open/binmode/perlio
  documentation.

## Real-world impact

Found in [Command::Run](https://github.com/tecolicom/Command-Run),
which redirects STDIN/STDOUT to temporary files on each in-process
(nofork) execution.  After ~1000 executions the process had thousands
of stacked encoding layers, was slower than fork-per-execution, and
kept growing.  Any long-running program using the classic
save/redirect/restore idiom with an encoding layer will hit this.

## Perl configuration

Measured on ubuntu-latest with shogo82148/actions-setup-perl builds
(5.12.5 through 5.42.2) and blead built from source; also reproduced
on macOS/arm64 (system perl 5.34.1 and Homebrew 5.42.2).

<details><summary>perl -V (Homebrew 5.42.2, macOS arm64)</summary>

```
（ここに perl -V の全文を貼る）
```

</details>
