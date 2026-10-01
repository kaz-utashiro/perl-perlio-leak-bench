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

The first ingredient is easy to see on its own: a fresh open resets
the layer stack, a re-open over a dup does not.

```
re-open over a dup : unix perlio encoding(utf8) utf8
re-open plain file : unix perlio
```

So every cycle adds one `encoding(utf8)` + `utf8` pair to STDOUT:

```
cycle 1: unix perlio encoding(utf8) utf8
cycle 2: unix perlio encoding(utf8) utf8 encoding(utf8) utf8
cycle 3: unix perlio encoding(utf8) utf8 encoding(utf8) utf8 encoding(utf8) utf8
```

Each subsequent operation on the handle passes through the whole
stack, so the loop is quadratic overall, and each layer keeps its
buffers, so memory grows without bound (~270MB after 900 cycles).
Unrelated file I/O through other handles is not affected.

## Results

3 rounds of 300 redirect cycles; layer count of STDOUT after each
round; time per round; unrelated I/O (1000 open/print/close on a
separate file) before and after; measured 2026-10-01
([full run](https://github.com/kaz-utashiro/perl-perlio-leak-bench/actions/runs/36829296263),
[blead run](https://github.com/kaz-utashiro/perl-perlio-leak-bench/actions/runs/36829296272);
see [leak-bench.pl](leak-bench.pl)):

| perl | sec (r1/r2/r3) | layers (r1/r2/r3) | rss | unrelated io |
|---|---|---|---:|---|
| 5.12.5 | 0.43 / 1.72 / 3.70 | 602 / 1202 / 1802 | 255MB | 0.44 -> 1.38 |
| 5.16.3 | 0.37 / 1.55 / 3.42 | 602 / 1202 / 1802 | 249MB | 0.43 -> 0.40 |
| 5.20.3 | 0.58 / 2.34 / 5.22 | 602 / 1202 / 1802 | 249MB | 0.26 -> 0.24 |
| 5.26.3 | 0.55 / 2.36 / 5.24 | 602 / 1202 / 1802 | 268MB | 0.27 -> 0.25 |
| 5.32.1 | 0.48 / 2.56 / 6.20 | 602 / 1202 / 1802 | 269MB | 0.25 -> 0.71 |
| 5.36.3 | 0.26 / 1.20 / 2.71 | 602 / 1202 / 1802 | 269MB | 3.35 -> 2.24 |
| 5.38.5 | 0.52 / 2.32 / 5.34 | 602 / 1202 / 1802 | 269MB | 0.24 -> 0.21 |
| 5.40.4 | 0.59 / 2.41 / 5.31 | 602 / 1202 / 1802 | 269MB | 0.18 -> 0.81 |
| 5.42.2 | 0.52 / 2.12 / 4.62 | 602 / 1202 / 1802 | 269MB | 0.63 -> 0.17 |
| 5.44.0 | 0.47 / 1.98 / 4.51 | 602 / 1202 / 1802 | 269MB | 0.24 -> 0.24 |
| blead 5.45.4 | 0.46 / 2.01 / 4.58 | 602 / 1202 / 1802 | 269MB | 0.24 -> 0.22 |

The `unrelated io` column is shared-runner noise — individual pairs
move in both directions (5.36.3 gets faster, 5.12.5 slower) and there
is no systematic growth.  It is here only to show that the leak does
not spread to other handles; the `layers` and `sec` columns are the
measurement.

Present unchanged in every release tested (5.12.5 through blead).

## Workarounds

- Use `:utf8` instead of `:encoding(utf8)` (no layer object with
  buffers; also the redirect keeps the flag without stacking).
- Or pop the encoding layer before restoring:
  `binmode STDOUT, ':pop'`.

## Background

Found in [Command::Run](https://github.com/tecolicom/Command-Run),
whose nofork mode redirects STDIN/STDOUT to temporary files on each
execution — see its
["PerlIO Encoding Layer Accumulation"](https://metacpan.org/pod/Command::Run#PerlIO-Encoding-Layer-Accumulation)
section, and
`nofork-tmpfile-reuse.md` for the longer Japanese write-up.  It looked
like a leak there at first, hence this repository's name; the cause is
accumulation.  Command::Run 1.02 works around it by popping the
encoding layer before restoring the handles, which took nofork with
`:encoding` from 316/s to 15,997/s on a 1000-iteration benchmark.

Related: perl/perl5#10454, perl/perl5#24531,
[perl-substr-bench](https://github.com/kaz-utashiro/perl-substr-bench),
[perl-matchvars-bench](https://github.com/kaz-utashiro/perl-matchvars-bench).
