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

The first of the two ingredients can be shown on its own.  A fresh
open resets the handle's layer stack; a re-open over a dup keeps it:

```perl
open my $a, '>', "/tmp/a1" or die;
binmode $a, ':encoding(utf8)';
open my $dup, '>&', $a or die;
open $a, '>&', $dup or die;                 # re-open over a dup
print "over dup   : @{[ PerlIO::get_layers($a) ]}\n";

open my $b, '>', "/tmp/b1" or die;
binmode $b, ':encoding(utf8)';
open $b, '>', "/tmp/b2" or die;             # re-open, plain file
print "plain file : @{[ PerlIO::get_layers($b) ]}\n";
```

```
over dup   : unix perlio encoding(utf8) utf8
plain file : unix perlio
```

Doing 3 rounds of 300 such cycles (ubuntu-latest, perl 5.44.0):

```
time per round:      0.56 / 2.11 / 4.70 sec     (quadratic)
STDOUT layer count:   602 / 1202 / 1802
process RSS after:   276 MB
```

I benchmarked 5.12.5 through 5.44.0 and blead built from source: the
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
