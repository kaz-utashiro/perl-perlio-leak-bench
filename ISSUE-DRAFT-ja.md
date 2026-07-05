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

このサイクル 300 回を 3 ラウンド実行すると（ubuntu-latest、perl 5.42.2）：

```
ラウンドごとの時間:      0.56 / 2.11 / 4.70 秒   （二次関数的）
STDOUT のレイヤー数:      602 / 1202 / 1802
実行後のプロセス RSS:    276 MB
```

5.12.5 から 5.42.2 まで、およびソースからビルドした blead でベンチ
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
にリダイレクトします。約 1000 回の実行後、プロセスは数千の encoding
レイヤーを積み上げ、実行ごとに fork するより遅くなり、なお増え続け
ていました。encoding レイヤー付きで古典的な退避／リダイレクト／復元
イディオムを使う長時間稼働プログラムは、すべてこれを踏みます。

## Perl configuration（環境）

ubuntu-latest + shogo82148/actions-setup-perl のビルド
（5.12.5〜5.42.2）と、ソースからビルドした blead で測定。
macOS/arm64（システム標準 perl 5.34.1 と Homebrew 5.42.2）でも再現。

（`<details>` ブロックに perl -V 全文を貼る）
