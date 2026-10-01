# Title

Encoding layers accumulate without bound on the standard filehandles when redirected and restored with open FH, '>&', ...

# Body

## Description

When one of the standard filehandles is redirected and restored with
`open FH, '>&', ...` while an `:encoding` layer is pushed in between —
the natural way to temporarily redirect STDOUT to a file in-process —
the encoding layer is not removed.  Repeating the cycle accumulates
one layer per iteration without bound.  Two things combine:

- re-opening a handle that sits on fd 0, 1 or 2 keeps the handle's
  *existing* PerlIO object, dup2()ing the new descriptor underneath it
  and throwing away the freshly opened handle together with the layers
  the open would have given it, and
- `binmode FH, ':encoding(utf8)'` pushes a new layer even when one is
  already present (#10454).

Every subsequent operation on the handle passes through the whole
stack, so a loop doing this is quadratic in time, and each layer keeps
its buffers, so memory grows without bound.

Only the standard handles are affected.  Every other handle *adopts
the layer stack of the dup source*, which makes the same
redirect-and-restore cycle self-cleaning: `open my $save, '>&', FH`
snapshots the layers, and restoring from `$save` brings exactly those
layers back.  So the idiom already works correctly — just not on the
handles it is normally used on.

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

The difference between the standard handles and the rest is direct to
see.  Give the handle and the dup source different layers, so that
"kept its own" and "adopted the source's" can be told apart:

```perl
open my $plain, '>', "/tmp/src" or die;     # dup source, no extra layers

binmode STDOUT, ':encoding(cp932)';
open STDOUT, '>&', $plain or die;
warn "STDOUT  : @{[ PerlIO::get_layers(*STDOUT) ]}\n";

open FH, '>', "/tmp/fh" or die;
binmode FH, ':encoding(cp932)';
open FH, '>&', $plain or die;
warn "ordinary: @{[ PerlIO::get_layers(*FH) ]}\n";
```

```
STDOUT  : unix perlio encoding(cp932) utf8      <- kept its own
ordinary: unix perlio                           <- adopted the source's
```

Consequently the redirect/restore loop above, run on an ordinary
handle instead of STDOUT, does not accumulate at all:

```
start   : [unix perlio]
cycle 1 : [unix perlio]
cycle 2 : [unix perlio]
cycle 3 : [unix perlio]
cycle 4 : [unix perlio]
```

Doing 3 rounds of 300 such cycles (ubuntu-latest, perl 5.44.0):

```
time per round:      0.56 / 2.11 / 4.70 sec     (quadratic)
STDOUT layer count:   602 / 1202 / 1802
process RSS after:   276 MB
```

I benchmarked 5.12.5 through 5.44.0 and blead built from source: the
behavior is identical in every version tested, and so is the
standard-handle/ordinary-handle split above —

```
RESULT perl=5.12.5 STDIN=KEPT STDOUT=KEPT STDERR=KEPT bareword=ADOPTED lexical=ADOPTED cycle_ordinary=stable cycle_STDOUT=GROW
...
RESULT perl=5.44.0 STDIN=KEPT STDOUT=KEPT STDERR=KEPT bareword=ADOPTED lexical=ADOPTED cycle_ordinary=stable cycle_STDOUT=GROW
```

identical for all ten releases probed.  Unrelated file I/O through
other handles is not affected.  Results and workflows:
https://github.com/kaz-utashiro/perl-perlio-leak-bench

Replacing `:encoding(utf8)` with `:utf8`, or popping the layer with
`binmode STDOUT, ':pop'` before restoring, avoids the problem
entirely.

## Where this comes from

`S_openn_setup()` in doio.c keeps the old PerlIO object when the
handle being re-opened is on a low descriptor:

```c
const int old_fd = PerlIO_fileno(IoIFP(io));

if (inRANGE(old_fd, 0, PL_maxsysfd)) {
    /* This is one of the original STD* handles */
    *saveifp  = IoIFP(io);
    ...
```

`PL_maxsysfd` is `MAXSYSFD`, 2 — so the test is really "fd 0, 1 or 2".
`S_openn_cleanup()` then discards the handle that was just opened and
reinstates the saved one, which is what preserves the old layer stack:

```c
/* Eeek - FIXME !!!
 * If this is a standard handle we discard all the layer stuff
 * and just dup the fd into whatever was on the handle before !
 */

if (saveifp) {		/* must use old fp? */
    ...
        PerlLIO_dup2(fd, savefd)
    ...
        PerlIO_close(fp);
    }
    fp = saveifp;
```

So the behaviour is not a deliberate guarantee; the source marks it as
something to fix.

## Discussion

The non-idempotency of `binmode :encoding` is #10454 and arguably
intended.  What turns it into an unbounded accumulation is the
standard-handle special case above, and that one looks like the part
worth changing: every other handle already adopts the dup source's
layers, which makes save/redirect/restore come out right by itself.

Possible directions:

- make the standard handles follow the same rule as every other
  handle, i.e. let a re-open over a dup adopt the dup source's layer
  stack, as the FIXME contemplates.  This both removes the
  accumulation and makes the save/restore idiom actually restore the
  layers that were saved;
- or make pushing `:encoding` replace an existing topmost encoding
  layer instead of stacking (#10454) — but that silently takes away a
  layer the caller set when the two encodings happen to match, so it
  is the riskier of the two;
- or at least document the special case, which is currently not
  mentioned under "Duping filehandles" in perlfunc, nor in PerlIO —
  whose description of open ("the handle will be opened with the
  layers specified by the `${^OPEN}` variable ... or the default layer
  stack") reads as if the standard handles behaved like the rest.

## Real-world impact

Found in [Command::Run](https://github.com/tecolicom/Command-Run),
which redirects STDIN/STDOUT to temporary files on each in-process
(nofork) execution.  After ~1000 executions the standard handles
carried thousands of stacked encoding layers, the in-process path had
become slower than fork-per-execution, and memory kept growing.  It
looked like a leak at first, and the module's documentation described
it as one, until the cause turned out to be this accumulation.  The
module documents the behaviour at
https://metacpan.org/pod/Command::Run#PerlIO-Encoding-Layer-Accumulation

The module now unwinds the layer change before restoring the handles
— check that the topmost layer is the encoding layer, then
`binmode FH, ':pop'` — released in 1.02.  On a 1000-iteration
benchmark with a 100-byte input:

                        before      after
    fork                 399/s      495/s
    nofork :encoding     316/s   15,997/s
    nofork :utf8 (raw) 13,433/s   20,038/s

The accumulation accounted for essentially the whole gap: raw mode
was 42x faster than `:encoding` only because of it, and is now an
optional optimization rather than a required workaround.

Any long-running program using the classic save/redirect/restore
idiom with an encoding layer will hit this.

## Perl configuration

Measured on ubuntu-latest with shogo82148/actions-setup-perl builds
(5.12.5 through 5.44.0) and blead built from source; also reproduced
on macOS/arm64 (system perl 5.34.1 and Homebrew 5.44.0).

<details><summary>perl -V (Homebrew 5.44.0, macOS arm64)</summary>

```
Summary of my perl5 (revision 5 version 44 subversion 0) configuration:
   
  Platform:
    osname=darwin
    osvers=24.6.0
    archname=darwin-thread-multi-2level
    uname='darwin sequoia-arm64.local 24.6.0 darwin kernel version 24.6.0: fri feb 27 19:34:48 pst 2026; root:xnu-11417.140.69.709.8~1release_arm64_vmapple arm64 '
    config_args='-des -Dinstallstyle=lib/perl5 -Dinstallprefix=/opt/homebrew/Cellar/perl/5.44.0 -Dprefix=/opt/homebrew/opt/perl -Dprivlib=/opt/homebrew/opt/perl/lib/perl5/5.44 -Dsitelib=/opt/homebrew/opt/perl/lib/perl5/site_perl/5.44 -Dotherlibdirs=/opt/homebrew/lib/perl5/site_perl/5.44 -Dvendorlib=/opt/homebrew/lib/perl5/vendor_perl/5.44 -Dvendorprefix=/opt/homebrew -Dperlpath=/opt/homebrew/opt/perl/bin/perl -Dstartperl=#!/opt/homebrew/opt/perl/bin/perl -Dman1dir=/opt/homebrew/opt/perl/share/man/man1 -Dman3dir=/opt/homebrew/opt/perl/share/man/man3 -Duseshrplib -Duselargefiles -Dusethreads'
    hint=recommended
    useposix=true
    d_sigaction=define
    useithreads=define
    usemultiplicity=define
    use64bitint=define
    use64bitall=define
    uselongdouble=undef
    usemymalloc=n
    default_inc_excludes_dot=define
  Compiler:
    cc='cc'
    ccflags ='-fno-common -DPERL_DARWIN -DNO_THREAD_SAFE_QUERYLOCALE -DNO_POSIX_2008_LOCALE -DHAS_BROKEN_LANGINFO_CODESET -DNO_LOCALE_COLLATE -fno-strict-aliasing -pipe -fstack-protector-strong'
    optimize='-O3'
    cppflags='-fno-common -DPERL_DARWIN -DNO_THREAD_SAFE_QUERYLOCALE -DNO_POSIX_2008_LOCALE -DHAS_BROKEN_LANGINFO_CODESET -DNO_LOCALE_COLLATE -fno-strict-aliasing -pipe -fstack-protector-strong'
    ccversion=''
    gccversion='Apple LLVM 17.0.0 (clang-1700.6.4.2)'
    gccosandvers=''
    intsize=4
    longsize=8
    ptrsize=8
    doublesize=8
    byteorder=12345678
    doublekind=3
    d_longlong=define
    longlongsize=8
    d_longdbl=define
    longdblsize=8
    longdblkind=0
    ivtype='long'
    ivsize=8
    nvtype='double'
    nvsize=8
    Off_t='off_t'
    lseeksize=8
    alignbytes=8
    prototype=define
  Linker and Libraries:
    ld='cc'
    ldflags =' -fstack-protector-strong'
    libpth=/opt/homebrew/lib /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/lib /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk/usr/lib /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib /usr/lib
    libs=-lgdbm
    perllibs=
    libc=
    so=dylib
    useshrplib=true
    libperl=libperl.dylib
    gnulibc_version=''
  Dynamic Linking:
    dlsrc=dl_dlopen.xs
    dlext=bundle
    d_dlsymun=undef
    ccdlflags=' '
    cccdlflags=' '
    lddlflags='-bundle -undefined dynamic_lookup -fstack-protector-strong'


Characteristics of this binary (from libperl): 
  Compile-time options:
    HAS_LONG_DOUBLE
    HAS_STRTOLD
    HAS_TIMES
    MULTIPLICITY
    PERLIO_LAYERS
    PERL_COPY_ON_WRITE
    PERL_HASH_FUNC_SIPHASH13
    PERL_HASH_USE_SBOX32
    PERL_MALLOC_WRAP
    PERL_OP_PARENT
    PERL_PRESERVE_IVUV
    PERL_USE_SAFE_PUTENV
    USE_64_BIT_ALL
    USE_64_BIT_INT
    USE_ITHREADS
    USE_LARGE_FILES
    USE_LOCALE
    USE_LOCALE_CTYPE
    USE_LOCALE_NUMERIC
    USE_LOCALE_TIME
    USE_PERLIO
    USE_PERL_ATOF
    USE_REENTRANT_API
  Built under darwin
  Compiled at Jul 15 2026 11:53:55
  %ENV:
    PERLDOC="-MPod::Text::Termcap"
    PERL_BADLANG="0"
  @INC:
    /opt/homebrew/opt/perl/lib/perl5/site_perl/5.44/darwin-thread-multi-2level
    /opt/homebrew/opt/perl/lib/perl5/site_perl/5.44
    /opt/homebrew/lib/perl5/vendor_perl/5.44/darwin-thread-multi-2level
    /opt/homebrew/lib/perl5/vendor_perl/5.44
    /opt/homebrew/opt/perl/lib/perl5/5.44/darwin-thread-multi-2level
    /opt/homebrew/opt/perl/lib/perl5/5.44
    /opt/homebrew/lib/perl5/site_perl/5.44/darwin-thread-multi-2level
    /opt/homebrew/lib/perl5/site_perl/5.44
```

</details>
