# Alloyによる形式検証の実習

## 検証対象のOSS

### Git

Gitは分散型バージョン管理システムであり，ソフトウェア開発におけるソースコードの履歴管理を目的として開発された。Linuxカーネルの開発のために2005年にLinus Torvaldsによって作成された。

Gitの主な特徴:

- 分散型：各開発者がリポジトリの完全なコピーを持つ
- ブランチとマージ：並行開発を支援する機能
- 高速な操作：ほとんどの操作がローカルで実行される
- コンテンツアドレス可能ストレージ：オブジェクトはSHA-1ハッシュで識別される

**参考文献**:

- Git公式ドキュメント: https://git-scm.com/doc
- Gitソースコード: https://github.com/git/git

### 検証対象：3-wayマージアルゴリズム

Gitのマージ機能は，複数の開発者の変更を統合する際に使用される重要な機能である。特に3-wayマージは，以下の3つのコミットを比較してマージを行う：

- **マージベース (base)**: 両方のブランチの共通祖先
- **コミット1 (c1)**: 一方のブランチの先頭
- **コミット2 (c2)**: もう一方のブランチの先頭

このアルゴリズムは，Gitの`merge-ort.c`（ORT = Ostensibly Recursive Tactics）で実装されている。

## 検証すべき性質

Gitの3-wayマージアルゴリズムにおいて，以下の3つの性質が正しく保たれることを検証する。
それぞれの性質の妥当性については，[Git公式ドキュメント](https://git-scm.com/book/ja/v2/Git-%E3%81%AE%E3%83%96%E3%83%A9%E3%83%B3%E3%83%81%E6%A9%9F%E8%83%BD-%E3%83%96%E3%83%A9%E3%83%B3%E3%83%81%E3%81%A8%E3%83%9E%E3%83%BC%E3%82%B8%E3%81%AE%E5%9F%BA%E6%9C%AC) を根拠とした．

### 1. 両側が同じ変更を行った場合の性質

**性質**: 両方のブランチが同じ変更を行った場合，その変更がマージ結果に採用され，競合は発生しない。

**例**:

- base: ファイル`foo.txt`に`"Hello"`と記述
- c1: `"Hello"`を`"Hello, World!"`に変更
- c2: `"Hello"`を`"Hello, World!"`に変更（c1と同じ変更）
- 期待される結果: `"Hello, World!"`が採用され，競合は発生しない

### 2. 片方のみが変更を行った場合の性質

**性質**: 一方のブランチのみが変更を行い，もう一方が変更を行わなかった場合，その変更がマージ結果に採用され，競合は発生しない。

**例**:

- base: ファイル`bar.txt`に`"v1.0"`と記述
- c1: 変更なし（`"v1.0"`のまま）
- c2: `"v1.0"`を`"v2.0"`に変更
- 期待される結果: `"v2.0"`が採用され，競合なし

### 3. 両側が異なる変更を行った場合の性質

**性質**: 両方のブランチが異なる変更を行った場合，競合が発生する。
Gitの実装では，さらにファイルの種類も考慮して自動でコンフリクトを解決する場合があるが，ここでは考慮しないものとする．

**例**:

- base: ファイル`version.txt`に`"1.0"`と記述
- c1: `"1.0"`を`"2.0"`に変更
- c2: `"1.0"`を`"3.0"`に変更
- 期待される結果: 競合が発生し，手動解決が必要

## モデル化

### GitオブジェクトモデルのAlloyによる定義

GitのオブジェクトモデルをAlloyでモデル化する．

#### 基本オブジェクト

```alloy
-- Gitのオブジェクト識別子
sig OID {}

-- Gitの基本オブジェクト
abstract sig Object {
  oid: one OID
}

-- コミットオブジェクト
sig Commit extends Object {
  -- 常に一つのツリーを指す
  tree: one Tree,

  -- 親コミットは0個以上
  -- 0: 初回コミット
  -- 1: 通常のコミット
  -- 2以上: マージコミット
  parents: set Commit,
}
```

**Git実装との対応**:

- `OID` → GitのオブジェクトID
- `Object` → `struct object_id` (object.h)
- `Commit` → `struct commit` (commit.h)
  - `tree` → `*maybe_tree;` (Gitの実装では遅延読み込みのために `NULL` となることもあるがここでは考慮しない)
  - `parents` → `struct commit_list *parents` (親コミットのリスト)

```alloy
-- ディレクトリ構造を表すツリーオブジェクト
sig Tree extends Object {
  -- ツリー内のエントリ集合
  entries: set NameEntry
}

-- ファイルの内容を表すブロブオブジェクトおよびタグオブジェクト
-- マージの検証においては内容は考慮しない
-- ref. https://github.com/git/git/blob/b2826b52eb7caff9f4ed6e85ec45e338bf02ad09/object.h#L93-L109
sig Blob extends Object {}
sig Tag extends Object {}
```

**Git実装との対応**:

- `Tree` → `struct tree` (`tree.h`)
- `Blob` → `struct blob` (`blob.h`)
- `Tag` → `struct tag` (`tag.h`)

#### ツリーエントリ

Gitのツリーオブジェクトは，ファイルやサブディレクトリへの参照（エントリ）の集合である。

```alloy
-- ファイルモード
abstract sig Mode {}
one sig Mode100644, Mode100755, Mode120000, Mode040000 extends Mode {}
```

**ファイルモードの意味**:

- `100644`: 通常のファイル
- `100755`: 実行可能ファイル
- `120000`: シンボリックリンク
- `040000`: ディレクトリ（サブツリー）

**Git実装との対応**: `tree-walk.h`内の`struct name_entry`

```alloy
-- ファイル名 / ディレクトリ名を表すパス
sig Path {}

-- Gitのツリーオブジェクト内のエントリ
-- 各エントリはファイル名，ファイルモード及びその実態となるオブジェクトを持つ
-- ref. https://github.com/git/git/blob/b2826b52eb7caff9f4ed6e85ec45e338bf02ad09/tree-walk.h
sig NameEntry {
  mode: one Mode,
  path: one Path,
  object: one Object,
}
```

**モードに関する制約**:

```alloy
-- モードに応じたオブジェクト型の制約
fact NameEntryTypeConstraint {
  all e: NameEntry |
  (e.mode in Mode040000 implies e.object in Tree) and
  (e.mode not in Mode040000 implies e.object in Blob)
}
```

この制約は，Gitの実装において「ディレクトリ（mode 040000）はツリーオブジェクトを指し，ファイルはブロブオブジェクトを指す」という事実をモデル化している。

#### データ構造の条件

Gitのリポジトリが満たすべき条件は以下の通りである。

```alloy
-- OIDは一意でなければならない
fact OIDUnique {
  all disj o1, o2: Object | o1.oid != o2.oid
}

-- コミットの親子関係は循環してはならない
fact CommitAcyclic {
  all c: Commit | c not in c.^parents
}

-- 同じツリー内で同じパスは存在しない
fact TreeEntryUnique {
  all t: Tree | all disj e1, e2: t.entries | e1.path != e2.path
}

-- ツリーのエントリ関係は循環してはならない
fact TreeAcyclic {
  all t: Tree | t not in t.^(entries.object :> Tree)
}
```

### マージベースの抽出

3-wayマージでは，まず2つのコミットの「最も近い共通祖先」を見つける必要がある。

```alloy
-- 2つのコミットの共通祖先の集合
fun commonAncestors[c1, c2: Commit]: set Commit {
  c1.^parents & c2.^parents
}

-- 最も近い共通祖先（マージベース）
fun mergeBases[c1, c2: Commit]: set Commit {
  let common = commonAncestors[c1, c2] |
  { ca: common | no other: common - ca | other in ca.^parents }
}
```

**Git実装との対応**:

- `merge_bases()` 関数 (`merge-ort.c`)
- `get_merge_bases()` 関数 (`commit.c`)
- 「最も近い共通祖先」は，共通祖先の中で他の共通祖先の子孫でないもの

### 3-wayマージアルゴリズムのモデル化

```alloy
-- マージ結果を表す
-- コンフリクトしているパスの集合を含む
sig MergeResult {
  tree: Tree,
  conflicts: set Path,
}
```

#### エントリの等価性判定

2つのエントリ集合が等しいかどうかを判定する述語：

```alloy
-- 2つのエントリ集合が等しいかを判定
pred entriesEqual[e1, e2: set NameEntry] {
  #e1 = #e2
  and
  (no e1 or e1.mode = e2.mode and e1.object = e2.object)
}
```

- `#e1 = #e2`: 両方とも空，または両方とも1つのエントリを持つ
- `no e1 or ...`: e1が空の場合，またはe1とe2の内容（モードとオブジェクト）が等しい場合

#### threeWayMerge関数

3-wayマージの本体：

```alloy
fun threeWayMerge[base, c1, c2: Commit]: lone MergeResult {
  { res: MergeResult |
    let t_base = base.tree, t1 = c1.tree, t2 = c2.tree | {
      -- 競合としてマークされているパスは，3つのツリーに現れるパスのいずれかである
      res.conflicts in (t_base.entries.path + t1.entries.path + t2.entries.path)
      and
      -- 3つのツリーに現れる全てのパスについて調べる
      all p: (t_base.entries.path + t1.entries.path + t2.entries.path) |
        let e_base = {e: t_base.entries | e.path = p},
            e1 = {e: t1.entries | e.path = p},
            e2 = {e: t2.entries | e.path = p},
            e_res = {e: res.tree.entries | e.path = p} |

        let e1_eq_e2 = entriesEqual[e1, e2],
            e1_eq_base = entriesEqual[e1, e_base],
            e2_eq_base = entriesEqual[e2, e_base] |

        -- 4つのケースに分けてマージ処理
        -- ケース1: 両方が同じ状態
        (e1_eq_e2 and entriesEqual[e_res, e1] and p not in res.conflicts)
        or
        -- ケース2: c1がベースと同じ（c2だけ変更）
        (e1_eq_base and not e2_eq_base and entriesEqual[e_res, e2] and p not in res.conflicts)
        or
        -- ケース3: c2がベースと同じ（c1だけ変更）
        (e2_eq_base and not e1_eq_base and entriesEqual[e_res, e1] and p not in res.conflicts)
        or
        -- ケース4: 両側がbaseと異なり，互いにも異なる
        (not e1_eq_e2 and not e1_eq_base and not e2_eq_base and p in res.conflicts and no e_res)
    }
  }
}
```

#### Git実装との対応

このモデルはGitの`merge-ort.c`の`process_entry()`関数内の`match_mask`によるケース分けに対応している。

```c
// merge-ort.c L4190-L4210 より抜粋
unsigned match_mask = 0;
if (ci->match_mask & 1) // MERGE_BASE
    match_mask |= 1;
if (ci->match_mask & 2) // MERGE_SIDE1
    match_mask |= 2;
if (ci->match_mask & 4) // MERGE_SIDE2
    match_mask |= 4;

/* match_mask:
 * 0 (000): 全て異なる → 競合
 * 3 (011): baseとside1のみが同じ → side2を採用
 * 5 (101): baseとside2のみが同じ → side1を採用
 * 6 (110): side1とside2が同じ → その内容を採用
 */
```

Alloyモデルの4つのケースは，この`match_mask`の値に対応している：

| Alloyモデルの条件                       | match_mask | マージ結果 |
| --------------------------------------- | ---------- | ---------- |
| `e1_eq_e2`                              | 6 (110)    | e1を採用   |
| `e1_eq_base ∧ ¬e2_eq_base`              | 3 (011)    | e2を採用   |
| `e2_eq_base ∧ ¬e1_eq_base`              | 5 (101)    | e1を採用   |
| `¬e1_eq_e2 ∧ ¬e1_eq_base ∧ ¬e2_eq_base` | 0 (000)    | 競合       |

## 検証手法

### 概要

Alloyの`assert`と`check`コマンドを使用して，3-wayマージアルゴリズムが満たすべき性質を検証する。各assertionについて，Alloy Analyzerによって反例が存在しないかを探索し，モデルの正当性を確認する。

### 検証する性質と対応するAlloyコード

#### 1. SameChangeAdopted：両側が同じ変更なら採用

**検証する性質**: 両方のブランチが同じ状態であれば，マージ結果もその状態になり，競合しない。

**Alloyコード**:

```alloy
assert SameChangeAdopted {
  all b, c1, c2: Commit, res: MergeResult, p: Path |
    -- 前提条件
    (b in mergeBases[c1, c2] and
     res = threeWayMerge[b, c1, c2] and
     p in (c1.tree.entries.path + c2.tree.entries.path + b.tree.entries.path))
    implies
    let e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |
      -- 結論：e1とe2が等しいなら，結果もe1と等しく，競合しない
      entriesEqual[e1, e2] implies
      (entriesEqual[e_res, e1] and p not in res.conflicts)
}
```

**論理構造**:

- 前提：bがc1とc2のマージベースであり，resがその3-wayマージの結果である
- 結論：任意のパスpについて，c1とc2のエントリが等しければ，マージ結果のエントリもそれと等しく，pは競合しない

**検証コマンド**:

```alloy
check SameChangeAdopted for 6 but 3 Commit, 1 MergeResult
```

**結果**: 反例なし（スコープ6，3コミット，1マージ結果において）

#### 2. OneSideChangeAdopted：片方のみ変更なら採用

**検証する性質**: 一方のブランチのみが変更を行った場合，その変更がマージ結果に採用され，競合しない。

**Alloyコード**:

```alloy
assert OneSideChangeAdopted {
  all b, c1, c2: Commit, res: MergeResult, p: Path |
    -- 前提条件
    (b in mergeBases[c1, c2] and
     res = threeWayMerge[b, c1, c2] and
     p in (c1.tree.entries.path + c2.tree.entries.path + b.tree.entries.path))
    implies
    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |
      -- 結論：e1がbaseと同じでe2が異なるなら，結果はe2と等しく，競合しない
      (entriesEqual[e1, e_base] and not entriesEqual[e2, e_base]) implies
      (entriesEqual[e_res, e2] and p not in res.conflicts)
}
```

**論理構造**:

- 前提：SameChangeAdoptedと同じ
- 結論：c1がbaseと同じでc2が異なる場合，マージ結果はc2と等しく，pは競合しない

**検証コマンド**:

```alloy
check OneSideChangeAdopted for 6 but 3 Commit, 1 MergeResult
```

**結果**: 反例なし（スコープ6，3コミット，1マージ結果において）

#### 3. ConflictWhenDifferentChanges：両側が異なる変更なら競合

**検証する性質**: 両方のブランチがベースと異なる変更を行い，かつ互いの変更も異なる場合，競合が発生する。

**Alloyコード**:

```alloy
assert ConflictWhenDifferentChanges {
  all b, c1, c2: Commit, res: MergeResult, p: Path |
    -- 前提条件
    (b in mergeBases[c1, c2] and
     res = threeWayMerge[b, c1, c2] and
     p in (c1.tree.entries.path + c2.tree.entries.path + b.tree.entries.path))
    implies
    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p] |
      -- 結論：e1とe2がbaseと異なり，かつe1とe2も異なるなら，pは競合する
      (not entriesEqual[e1, e_base] and
       not entriesEqual[e2, e_base] and
       not entriesEqual[e1, e2]) implies
      p in res.conflicts
}
```

**論理構造**:

- 前提：SameChangeAdoptedと同じ
- 結論：c1とc2がbaseと異なり，かつc1とc2も異なる場合，pは競合としてマークされる

**検証コマンド**:

```alloy
check ConflictWhenDifferentChanges for 6 but 3 Commit, 1 MergeResult
```

**結果**: 反例なし（スコープ6，3コミット，1マージ結果において）

### スコープの設定

検証にはスコープ「`for 6 but 3 Commit, 1 MergeResult`」を使用している：

- `for 6`: 各シグネチャのインスタンス数を最大6個に制限
  - すべてのシグネチャ（OID, Object, Commit, Tree, Blob, Tag, Path, NameEntry, Mode, MergeResult）に適用
- `but 3 Commit`: Commitインスタンスを最大3個に制限
  - base, c1, c2の3つのコミットを表現するのに十分
- `1 MergeResult`: MergeResultインスタンスをちょうど1個に制限
  - マージ結果は1つだけ存在すれば十分

このスコープ設定により：

- 計算量を適切に制御しつつ，意味のある検証が可能
- 3コミットのマージシナリオを十分に表現できる
- 反例探索の計算時間を現実的な範囲に収める

### 例の生成

assertionの検証に加え，`pred`と`run`コマンドを使用して各シナリオの具体例を生成する。

```alloy
-- 両方が同じ変更を加えたマージの例
pred showSameChange {
  some b, c1, c2: Commit, res: MergeResult, p: Path | {
    b in mergeBases[c1, c2]
    res = threeWayMerge[b, c1, c2]
    p in (b.tree.entries.path + c1.tree.entries.path + c2.tree.entries.path)

    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |

      entriesEqual[e1, e2] and
      not entriesEqual[e1, e_base] and
      entriesEqual[e_res, e1] and
      p not in res.conflicts and
      not some res.conflicts
  }
}

run showSameChange for 6 but 3 Commit, 1 MergeResult
```

同様に，`showOneSideChange`（片方のみ変更）と`showConflict`（競合発生）のpredを定義し，具体例を生成する。

これにより：

- Alloy Analyzerのビジュアライザでマージの様子を視覚的に確認できる
- モデルが意図した通りの挙動をしているかを検証できる

## 補足事項

### 使用方法

#### Alloy Analyzerのインストール

1. [Alloy Analyzer](https://alloytools.org/)にアクセス
2. 最新版をダウンロード（今回はAlloy 5.0.0を使用）
3. インストーラーに従ってインストール

#### 実行手順

1. Alloy Analyzerを起動
2. メニューから `File → Open` を選択し，`a.als`ファイルを開く
3. 以下のコマンドを実行：

**検証を行う場合（assertionのチェック）**:

```
check SameChangeAdopted for 6 but 3 Commit, 1 MergeResult
check OneSideChangeAdopted for 6 but 3 Commit, 1 MergeResult
check ConflictWhenDifferentChanges for 6 but 3 Commit, 1 MergeResult
```

**例を生成する場合（predicateの実行）**:

```
run showSameChange for 6 but 3 Commit, 1 MergeResult
run showOneSideChange for 6 but 3 Commit, 1 MergeResult
run showConflict for 6 but 3 Commit, 1 MergeResult
```

#### ビジュアライザの使い方

Alloy Analyzerのビジュアライザでは：

- **グラフ表示**: コミットグラフの構造を確認できる
- **テーブル表示**: 各シグネチャのインスタンス一覧を確認できる
- **詳細パネル**: 各オブジェクトの属性値を確認できる

特に，以下を確認すると理解が深まる：

- `MergeResult`ノードを選択し，`tree`属性と`conflicts`属性を確認
- 各`Commit`ノードの`tree`属性を辿り，ツリー構造を確認
- `NameEntry`テーブルで，どのパスが競合しているかを確認

### ファイル構成

本リポジトリの`alloy-practice`ディレクトリには以下のファイルが含まれる：

- `a.als`: Alloyモデルの本体
  - Gitオブジェクトモデルの定義
  - 3-wayマージアルゴリズムの実装
  - 3つのassertion（SameChangeAdopted, OneSideChangeAdopted, ConflictWhenDifferentChanges）
  - 3つのpredicate（showSameChange, showOneSideChange, showConflict）

### モデルの制約と簡略化

本研究では以下の点を簡略化している：

1. **ファイルの内容**: ブロブオブジェクトの中身はモデル化していない
   - マージにおいてファイルの内容そのものではなく，オブジェクトの同一性に焦点を当てているため

2. **高度なマージ戦略**: Gitの実装には含まれる以下の機能はモデル化していない
   - リネーム検出
   - ファイル種類に基づく自動競合解決
   - content merge（テキスト行単位のマージ）
   - サブモジュール（mode 160000）のサポート

3. **スコープの制限**: 検証は小さなスコープ（最大6オブジェクト）で行っている
   - 実際のリポジトリははるかに大規模だが，形式的検証では小さいスコープでの反例探索が一般的

### 今後の拡張可能性

このモデルをベースに，以下の拡張が考えられる：

1. **content mergeのモデル化**: テキストファイルの行単位マージの検証
2. **リネーム検出のモデル化**: ファイル名変更を考慮したマージ
3. **マージ戦略の比較**: recursive戦略とort戦略の形式的検証
4. **パフォーマンス特性**: マージの計算複雑性の分析

### 参考文献

- Gitソースコード（コミットハッシュ: b2826b52eb7caff9f4ed6e85ec45e338bf02ad09）
  - `merge-ort.c`: L4064-L4358, `process_entry()`関数
  - `merge-ort.c`: L4190-L4210, `match_mask`によるケース分け
  - `tree-walk.h`: ツリーオブジェクト構造の定義
  - `object.h`: L93-L109, オブジェクト型定義

- Gitドキュメント
  - Git公式ドキュメント: https://git-scm.com/doc
  - Git Merge Strategies: https://git-scm.com/docs/merge-strategies

- Alloy関連
  - Alloy公式サイト: https://alloytools.org/
  - Daniel Jackson, "Software Abstractions: Logic, Language, and Analysis", MIT Press, 2012
