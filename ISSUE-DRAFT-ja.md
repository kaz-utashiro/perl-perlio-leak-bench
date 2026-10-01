# タイトル

Encoding layers accumulate without bound when a redirected filehandle is restored with open FH, '>&', ...
（リダイレクトしたファイルハンドルを open FH, '>&', ... で復元すると encoding レイヤーが際限なく蓄積する）

# 本文

## Description（説明）

ファイルハンドルを `open FH, '>&', ...` でリダイレクトして復元する
際、その間に `:encoding` レイヤーを push していると — プロセス内で
STDOUT を一時的にファイルへ向ける自然な書き方です — encoding レイ
ヤーが除去されません。このサイクルを繰り返すと、1 回ごとにレイヤー
が 1 組ずつ際限なく蓄積します：

- dup による既存ハンドルへの再オープンは、ハンドルの現在のレイヤー
  スタックをリセットせず温存する
- `binmode FH, ':encoding(utf8)'` は既に同じレイヤーがあっても新し
  いレイヤーを push する（#10454）

以後の操作はすべてスタック全段を通るため、このループは時間的に二次
関数となり、リークした各レイヤーはバッファを保持し続けるため、メモ
リも際限なく増えます。

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

## Discussion（議論）

2 つの要素はそれぞれ単体では意図された挙動かもしれません — dup 再
オープンのレイヤー温存はどちらとも文書化されていないようですし、
binmode の非冪等性は #10454 です — が、組み合わさると、ごく普通の
リダイレクト＆復元パターンが際限のないリークに変わります。しかも診
断が非常に困難です（ハンドルは一見正常で、遅さは徐々に忍び寄る）。

考えられる方向性を野心的な順に：

- ハンドルの再オープン時にレイヤースタックを（新規オープンと同様
  に）計算し直したものへリセットする
- `:encoding` の push を、既存の最上位 encoding レイヤーの置き換え
  にする（#10454）
- 少なくとも open / binmode / perlio のドキュメントにこの蓄積の危険
  を記載する

## Real-world impact（実世界での影響）

[Command::Run](https://github.com/tecolicom/Command-Run) で発見しま
した。プロセス内（nofork）実行のたびに STDIN/STDOUT を一時ファイル
にリダイレクトします。約 1000 回の実行後、標準ハンドルは数千の
encoding レイヤーを積み上げ、プロセス内実行が実行ごとに fork するよ
り遅くなり、メモリも増え続けていました。当初はリークに見え、モジュー
ルのドキュメントにもそう書いていましたが、原因はこの蓄積でした。

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
