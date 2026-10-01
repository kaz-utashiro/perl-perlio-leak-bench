# タイトル

Encoding layers accumulate without bound on the standard filehandles when redirected and restored with open FH, '>&', ...
（標準ファイルハンドルをリダイレクトして open FH, '>&', ... で復元すると encoding レイヤーが際限なく蓄積する）

# 本文

## Description（説明）

標準ファイルハンドルを `open FH, '>&', ...` でリダイレクトして復元
する際、その間に `:encoding` レイヤーを push していると — プロセス
内で STDOUT を一時的にファイルへ向ける自然な書き方です — encoding
レイヤーが除去されません。サイクルを繰り返すと 1 回ごとに 1 層ずつ
際限なく蓄積します。2 つの挙動の合成です：

- fd 0・1・2 に載っているハンドルへの再オープンは、ハンドルの
  *既存の* PerlIO オブジェクトを温存し、新しいディスクリプタを
  その下に dup2 して、開いたばかりのハンドルを（本来そのオープンが
  与えるはずだったレイヤーごと）捨てる
- `binmode FH, ':encoding(utf8)'` は既に同じレイヤーがあっても新し
  いレイヤーを push する（#10454）

以後の操作はすべてスタック全段を通るため、このループは時間的に二次
関数となり、各レイヤーはバッファを保持し続けるため、メモリも際限な
く増えます。

**影響を受けるのは標準ハンドルだけです。** それ以外のハンドルは
*dup 元のレイヤースタックを継承*するため、同じリダイレクト／復元の
サイクルが自己完結します。`open my $save, '>&', FH` がレイヤーの
スナップショットになり、`$save` からの復元がまさにそのレイヤーを
戻すからです。つまりイディオム自体は既に正しく動いており、通常それ
が使われるハンドルでだけ動かない、という状態です。

## Steps to Reproduce（再現手順）

```perl
my $file = "/tmp/layers-$$.tmp";
open my $tmp, '+>', $file or die;
for my $i (1 .. 3) {
    open my $save, '>&', \*STDOUT or die;
    open STDOUT, '>&', $tmp or die;
    binmode STDOUT, ':encoding(utf8)';
    open STDOUT, '>&', $save or die;    # 復元
    close $save;
    print STDERR "cycle $i: @{[ PerlIO::get_layers(STDOUT) ]}\n";
}
```

```
cycle 1: unix perlio encoding(utf8) utf8
cycle 2: unix perlio encoding(utf8) utf8 encoding(utf8) utf8
cycle 3: unix perlio encoding(utf8) utf8 encoding(utf8) utf8 encoding(utf8) utf8
```

2 つの要因のうち 1 つ目は単独で示せます。新規の open はレイヤスタッ
クをリセットしますが、dup に対する再 open は保持します：

```perl
open my $a, '>', "/tmp/a1" or die;
binmode $a, ':encoding(utf8)';
open my $dup, '>&', $a or die;
open $a, '>&', $dup or die;                 # dup に対する再 open
print "over dup   : @{[ PerlIO::get_layers($a) ]}\n";

open my $b, '>', "/tmp/b1" or die;
binmode $b, ':encoding(utf8)';
open $b, '>', "/tmp/b2" or die;             # 通常ファイルへの再 open
print "plain file : @{[ PerlIO::get_layers($b) ]}\n";
```

```
over dup   : unix perlio encoding(utf8) utf8
plain file : unix perlio
```

このサイクル 300 回を 3 ラウンド実行すると（ubuntu-latest、perl 5.44.0）：

```
ラウンドごとの時間:      0.56 / 2.11 / 4.70 秒   （二次関数的）
STDOUT のレイヤー数:      602 / 1202 / 1802
実行後のプロセス RSS:    276 MB
```

5.12.5 から 5.44.0 まで、およびソースからビルドした blead でベンチ
マークしました。テストした全バージョンで挙動は同一です。他のハンド
ルを通る無関係なファイル I/O は影響を受けません。結果とワークフロー：
https://github.com/kaz-utashiro/perl-perlio-leak-bench

`:encoding(utf8)` を `:utf8` に替えるか、復元前に
`binmode STDOUT, ':pop'` でレイヤーを取り除けば、問題は完全に回避で
きます。

## Where this comes from（原因の所在）

doio.c の `S_openn_setup()` は、再オープン対象のハンドルが低い
ディスクリプタに載っている場合、古い PerlIO オブジェクトを温存します：

```c
const int old_fd = PerlIO_fileno(IoIFP(io));

if (inRANGE(old_fd, 0, PL_maxsysfd)) {
    /* This is one of the original STD* handles */
    *saveifp  = IoIFP(io);
    ...
```

`PL_maxsysfd` は `MAXSYSFD` = 2 なので、判定は実質「fd 0・1・2 か」
です。続く `S_openn_cleanup()` が、開いたばかりのハンドルを捨てて
保存したものを復帰させます。これが古いレイヤースタックを残します：

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

つまりこの挙動は意図的な保証ではなく、ソース自身が直すべきものとして
印を付けています。

## Earlier reports（既存の報告）

この特例自体は新しい話ではありません。繰り返し報告され、いずれも
open のままです：

- #7854 (2005), open sometimes ignores perlio layers when duping
- #8998 (2007), Layers not applied to reopened STDOUT
- #12249 (2012), Reopening filehandles can clobber PerlIO layers
- #14229 (2014), copy encoding settings when duping file descriptors (?)
- #15392 (2016), IO layer for STDERR not set
- #21881 (2024), Reopening STDOUT to in-memory scalar interferes with "-|" piping

Leon Timmermans は 2012 年に #12249 で既に `Eeek - FIXME !!!` を引用
し、2001 年から残っていることを指摘しています。

#12249 は実のところ同じ特例を反対側から見たものです。あちらは再
オープンで**出力側**のレイヤーが失われるという報告で、本報告は
**入力側**のレイヤーが保たれて積み上がるという話です。あちらは今も
再現します。再現しないように見えてきた理由は、答えが STDOUT の接続
先に依存することです：

| STDOUT の先 | 入力側 | 出力側 | 5.12.5 – 5.44.0 |
|---|---|---|---|
| キャラクタデバイス（端末、`/dev/null`） | 保持 | **消失** | 10 バージョン全て消失 |
| 通常ファイル | 保持 | 保持 | 10 バージョン全て保持 |
| パイプ | 保持 | 保持 | 10 バージョン全て保持 |

`S_openn_cleanup()` は `saveofp` が `saveifp` と別の PerlIO オブジェ
クトであるときにそれを閉じるため、出力側のレイヤーが失われます。
これを再測定する人は、結果を STDOUT 以外に書いてください。試験対象
のハンドルに print すると観測結果が変わります（私は最初それで誤った
結論を出しました）。

したがって本報告で新しいのは挙動ではなく**帰結**です。#10454 と
組み合わさることで、ごく普通のリダイレクト＆復元のループが際限なく
蓄積する（時間は二次関数、メモリは無制限）こと、そしてそうなるのは
標準ハンドルだけであること、の 2 点です。

## Discussion（議論）

`binmode :encoding` の非冪等性は #10454 で、単体では意図された挙動
とも言えます。それを際限のない蓄積に変えているのは上記の標準ハンド
ル特例であり、変えるべきはそちらだと思われます。他のすべてのハンド
ルは既に dup 元のレイヤーを継承しており、その結果 退避／リダイレク
ト／復元が自然に正しく収まるからです。

考えられる方向性：

- 標準ハンドルを他のハンドルと同じ規則に揃える。すなわち dup への
  再オープンで dup 元のレイヤースタックを継承させる（FIXME が想定
  しているのはこれです）。蓄積がなくなるだけでなく、save/restore
  イディオムが本当に「保存したレイヤーを復元する」ようになります
- あるいは `:encoding` の push を既存の最上位 encoding レイヤーの
  置き換えにする（#10454）。ただし両者の encoding が一致した場合に
  呼び出し側が設定したレイヤーを黙って奪うので、こちらの方が危険です
- 少なくともこの特例を文書化する。現在 perlfunc の "Duping
  filehandles" にも PerlIO にも記載がなく、PerlIO の open の説明
  （「レイヤーが明示されなければ `${^OPEN}` のレイヤー…またはデフォ
  ルトのレイヤースタックで開かれる」）は、標準ハンドルも他と同様に
  振る舞うかのように読めます

## Real-world impact（実世界での影響）

[Command::Run](https://github.com/tecolicom/Command-Run) で発見しま
した。プロセス内（nofork）実行のたびに STDIN/STDOUT を一時ファイル
にリダイレクトします。約 1000 回の実行後、標準ハンドルは数千の
encoding レイヤーを積み上げ、プロセス内実行が実行ごとに fork するよ
り遅くなり、メモリも増え続けていました。当初はリークに見え、モジュー
ルのドキュメントにもそう書いていましたが、原因はこの蓄積でした。
モジュール側の記述は
https://metacpan.org/pod/Command::Run#PerlIO-Encoding-Layer-Accumulation
にあります。

現在は復元の直前にレイヤー変更を巻き戻しています（最上位が encoding
レイヤーであることを確認して `binmode FH, ':pop'`）。1.02 でリリース
済みです。100 バイト入力・1000 回のベンチマーク：

                        修正前      修正後
    fork                 399/s      495/s
    nofork :encoding     316/s   15,997/s
    nofork :utf8 (raw) 13,433/s   20,038/s

差のほぼ全部が蓄積の寄与でした。raw モードが `:encoding` の 42 倍速
かったのはこれが理由で、いまは必須の回避策ではなく任意の最適化に
なっています。

encoding レイヤー付きで古典的な退避／リダイレクト／復元イディオムを
使う長時間稼働プログラムは、すべてこれを踏みます。

## Perl configuration（環境）

ubuntu-latest + shogo82148/actions-setup-perl のビルド
（5.12.5〜5.44.0）と、ソースからビルドした blead で測定。
macOS/arm64（システム標準 perl 5.34.1 と Homebrew 5.44.0）でも再現。

perl -V の全文は英語版 (ISSUE-DRAFT.md) の `<details>` ブロックに
あります。
