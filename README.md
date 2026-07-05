# perl-perlio-leak-bench

Demonstrates that PerlIO layers accumulate without bound when a
filehandle is repeatedly redirected and restored with
`open FH, '>&', ...` while an `:encoding` layer is pushed in between —
the pattern used by nofork-style command executors which redirect
STDIN/STDOUT to temporary files.

```perl
open my $save, '>&', \*STDOUT;
open STDOUT, '>&', $tmp;             # redirect
binmode STDOUT, ':encoding(utf8)';
open STDOUT, '>&', $save;            # restore
```

Two behaviors combine:

1. Re-opening an existing filehandle over a dup (`open FH, '>&', ...`)
   keeps the handle's current layer stack instead of resetting it.
2. `binmode FH, ':encoding(utf8)'` pushes a new layer even when one is
   already present (perl/perl5#10454, "binmode (encoding) is not
   idempotent").

So every cycle adds one `encoding(utf8)` + `utf8` pair to STDOUT:

```
cycle 1: unix perlio encoding(utf8) utf8
cycle 2: unix perlio encoding(utf8) utf8 encoding(utf8) utf8
cycle 3: unix perlio encoding(utf8) utf8 encoding(utf8) utf8 encoding(utf8) utf8
```

Each subsequent operation on the handle passes through the whole
stack, so the loop is quadratic overall, and each layer keeps its
buffers, so memory grows without bound (~250MB after 900 cycles).
Unrelated file I/O through other handles is not affected.

## Results

3 rounds of 300 redirect cycles; layer count of STDOUT after each
round; time per round; unrelated I/O (1000 open/print/close on a
separate file) before and after
([full run](https://github.com/kaz-utashiro/perl-perlio-leak-bench/actions/runs/28724464058),
[blead run](https://github.com/kaz-utashiro/perl-perlio-leak-bench/actions/runs/28724464522);
see [leak-bench.pl](leak-bench.pl)):

| perl | sec (r1/r2/r3) | layers (r1/r2/r3) | rss | unrelated io |
|---|---|---|---:|---|
| 5.12.5 | 0.51 / 2.12 / 4.42 | 602 / 1202 / 1802 | 260MB | 0.26 -> 0.19 (none) |
| 5.16.3 | 0.61 / 2.67 / 6.12 | 602 / 1202 / 1802 | 255MB | none |
| 5.20.3 | 0.56 / 2.23 / 4.64 | 602 / 1202 / 1802 | 255MB | none |
| 5.26.3 | 0.51 / 2.13 / 4.65 | 602 / 1202 / 1802 | 274MB | none |
| 5.32.1 | 0.51 / 2.09 / 4.63 | 602 / 1202 / 1802 | 275MB | none |
| 5.36.3 | 0.54 / 2.39 / 5.57 | 602 / 1202 / 1802 | 276MB | none |
| 5.38.5 | 0.54 / 2.43 / 5.61 | 602 / 1202 / 1802 | 276MB | none |
| 5.40.4 | 0.52 / 2.17 / 4.89 | 602 / 1202 / 1802 | 276MB | none |
| 5.42.2 | 0.56 / 2.11 / 4.70 | 602 / 1202 / 1802 | 276MB | none |
| blead 2026-07-05 | 0.32 / 1.48 / 3.43 | 602 / 1202 / 1802 | 276MB | none |

Present unchanged in every release tested (5.12.5 through blead).

## Workarounds

- Use `:utf8` instead of `:encoding(utf8)` (no layer object with
  buffers; also the redirect keeps the flag without stacking).
- Or pop the encoding layer before restoring:
  `binmode STDOUT, ':pop'`.

## Background

Found in [Command::Run](https://github.com/tecolicom/Command-Run)
(see its "PerlIO Encoding Leak" section), whose nofork mode redirects
STDIN/STDOUT to temporary files on each execution.

Related: perl/perl5#10454, perl/perl5#24531,
[perl-substr-bench](https://github.com/kaz-utashiro/perl-substr-bench),
[perl-matchvars-bench](https://github.com/kaz-utashiro/perl-matchvars-bench).
