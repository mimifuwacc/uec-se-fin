# Alloyによる形式検証の実習

## 検証対象のOSS

### Git

Gitは2005年にLinus Torvaldsによって開発された分散型バージョン管理システムであり，Linuxカーネルの開発における効率的なソースコード管理を目的として作成された．

Gitの主な特徴は以下の通りである:

- 完全分散型の開発環境: 各開発者がリポジトリの完全な複製を保持することで，中央サーバーに依存せず，ネットワーク環境を問わない自律的な開発を可能にする
- 高度な並行開発の支援: 複雑な開発ラインをブランチとして軽量に切り出し，それらを効率的に統合する強力なマージ機能を提供する
- ハッシュ値による厳格なデータ保護: すべてのオブジェクトを固有のハッシュ値（SHA-1, SHA-256等）で一意に識別し，コンテンツのアドレス指定を行うことで，データの整合性と改ざん耐性を保証する

参考文献:

- Gitソースコード: https://github.com/git/git
- Git公式ドキュメント: https://git-scm.com/doc

### 検証対象: 3-wayマージアルゴリズム

Gitのマージ機能は，複数の開発者の変更を統合する際に使用される重要な機能である．特に3-wayマージは，以下の3つのコミットを比較してマージを行う:

- マージベース (base): 両方のブランチの共通祖先
- コミット1 (c1): 一方のブランチの先頭
- コミット2 (c2): もう一方のブランチの先頭

このアルゴリズムは，Gitの`merge-ort.c` (Ostensibly Recursive Tactics) で実装されている．

## 検証すべき性質

Gitの3-wayマージアルゴリズムにおいて，以下の3つの性質が正しく保たれることを検証する．
それぞれの性質の妥当性については，[Git公式ドキュメント](https://git-scm.com/book/ja/v2/Git-%E3%81%AE%E3%83%96%E3%83%A9%E3%83%B3%E3%83%81%E6%A9%9F%E8%83%BD-%E3%83%96%E3%83%A9%E3%83%B3%E3%83%81%E3%81%A8%E3%83%9E%E3%83%BC%E3%82%B8%E3%81%AE%E5%9F%BA%E6%9C%AC) を根拠とした．

### 1. 両側が同じ変更を行った場合の性質

性質: 両方のブランチが同じ変更を行った場合，その変更がマージ結果に採用され，競合は発生しない．

例:

- base: ファイル`foo.txt`に`"Hello"`と記述
- c1: `"Hello"`を`"Hello, World!"`に変更
- c2: `"Hello"`を`"Hello, World!"`に変更 (c1と同じ変更)
- 期待される結果: `"Hello, World!"`が採用され，競合は発生しない

### 2. 片方のみが変更を行った場合の性質

性質: 一方のブランチのみが変更を行い，もう一方が変更を行わなかった場合，その変更がマージ結果に採用され，競合は発生しない．

例:

- base: ファイル`bar.txt`に`"v1.0"`と記述
- c1: 変更なし (`"v1.0"`のまま)
- c2: `"v1.0"`を`"v2.0"`に変更
- 期待される結果: `"v2.0"`が採用され，競合なし

### 3. 両側が異なる変更を行った場合の性質

性質: 両方のブランチが異なる変更を行った場合，競合が発生する．
Gitの実装では，さらにファイルの種類も考慮して自動でコンフリクトを解決する場合があるが，ここでは考慮しないものとする．

例:

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

Git実装との対応:

- `OID` → GitのオブジェクトID
- `Object` → `struct object_id` (`object.h`)
- `Commit` → `struct commit` (`commit.h`)
  - `tree` → `*maybe_tree;` (Gitの実装では遅延読み込みのために `NULL` となることもあるがここでは考慮しない)
  - `parents` → `struct commit_list *parents` (親コミットのリスト)

```alloy
-- ディレクトリ構造を表すツリーオブジェクト
sig Tree extends Object {
  -- ツリー内のエントリ集合
  entries: set NameEntry
}

-- ファイル内容を表すブロブオブジェクトおよびタグオブジェクト
-- マージの検証においてはファイル内容は考慮しない
-- ref. https://github.com/git/git/blob/b2826b52eb7caff9f4ed6e85ec45e338bf02ad09/object.h#L93-L109
sig Blob extends Object {}
sig Tag extends Object {}
```

Git実装との対応:

- `Tree` → `struct tree` (`tree.h`)
- `Blob` → `struct blob` (`blob.h`)
- `Tag` → `struct tag` (`tag.h`)

#### ツリーエントリ

Gitのツリーオブジェクトは，ファイルやサブディレクトリへの参照 (エントリ) の集合である．

```alloy
-- ファイルモード
abstract sig Mode {}
one sig Mode100644, Mode100755, Mode120000, Mode040000 extends Mode {}
```

ファイルモードの意味:

- `100644`: 通常のファイル
- `100755`: 実行可能ファイル
- `120000`: シンボリックリンク
- `040000`: ディレクトリ (サブツリー)

Git実装との対応: `tree-walk.h`内の`struct name_entry`

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

モードに関する制約:

```alloy
-- モードに応じたオブジェクト型の制約
fact NameEntryTypeConstraint {
  all e: NameEntry |
  (e.mode in Mode040000 implies e.object in Tree) and
  (e.mode not in Mode040000 implies e.object in Blob)
}
```

この制約は，Gitの実装において「ディレクトリ (mode 040000) はツリーオブジェクトを指し，ファイルはブロブオブジェクトを指す」という事実をモデル化している．

#### データ構造の条件

Gitのリポジトリが満たすべき条件は以下の通りである．

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

3-wayマージでは，まず2つのコミットの「最も近い共通祖先」を見つける必要がある．

```alloy
-- 2つのコミットの共通祖先の集合
fun commonAncestors[c1, c2: Commit]: set Commit {
  c1.^parents & c2.^parents
}

-- 最も近い共通祖先 (マージベース)
fun mergeBases[c1, c2: Commit]: set Commit {
  let common = commonAncestors[c1, c2] |
  { ca: common | no other: common - ca | other in ca.^parents }
}
```

Git実装との対応:

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

2つのエントリ集合が等しいかどうかを判定する述語:

```alloy
-- 2つのエントリ集合が等しいかを判定
pred entriesEqual[e1, e2: set NameEntry] {
  #e1 = #e2
  and
  (no e1 or e1.mode = e2.mode and e1.object = e2.object)
}
```

- `#e1 = #e2`: 両方とも空，または両方とも1つのエントリを持つ
- `no e1 or ...`: e1が空の場合，またはe1とe2の内容 (モードとオブジェクト) が等しい場合

#### threeWayMerge関数

3-wayマージの本体:

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
        -- ケース2: c1がベースと同じ (c2だけ変更)
        (e1_eq_base and not e2_eq_base and entriesEqual[e_res, e2] and p not in res.conflicts)
        or
        -- ケース3: c2がベースと同じ (c1だけ変更)
        (e2_eq_base and not e1_eq_base and entriesEqual[e_res, e1] and p not in res.conflicts)
        or
        -- ケース4: 両側がbaseと異なり，互いにも異なる
        (not e1_eq_e2 and not e1_eq_base and not e2_eq_base and p in res.conflicts and no e_res)
    }
  }
}
```

#### Git実装との対応

このモデルはGitの`merge-ort.c`の`process_entry()`関数内の`match_mask`によるケース分けに対応している．
cf. https://github.com/git/git/blob/b2826b52eb7caff9f4ed6e85ec45e338bf02ad09/merge-ort.c#L4190-L4210

Alloyモデルの4つのケースは，この`match_mask`の値に対応している:

| Alloyモデルの条件                                    | match_mask | マージ結果 |
| ---------------------------------------------------- | ---------- | ---------- |
| `e1_eq_e2`                                           | 6 (110)    | e1を採用   |
| `e1_eq_base and not e2_eq_base`                      | 3 (011)    | e2を採用   |
| `e2_eq_base and not e1_eq_base`                      | 5 (101)    | e1を採用   |
| `not e1_eq_e2 and not e1_eq_base and not e2_eq_base` | 0 (000)    | 競合       |

## 検証手法

### 検証の考え方

3-wayマージアルゴリズムの正しさを検証するため，以下の方針でモデル化と検証を行った．

#### モデル化における抽象化の方針

Gitの実際の実装では，ファイル内容 (テキスト，バイナリ) や行単位のdiffなど，多くの詳細情報を扱う．しかし，3-wayマージの基本的な振る舞いは，各パスについてbase・c1・c2の3つの状態を比較し，それに基づいて結果を決定する．

そこで，本モデルでは以下の抽象化を行った:

1. ファイル内容の省略: Blobオブジェクトを識別子のみで表現し，内容 (文字列) は扱わない
2. エントリ単位での比較: ファイル内容の詳細な差分ではなく，NameEntry (mode + object) の等価性のみで判定
3. パス単位での独立性: 各パスは独立にマージ判定される (実際のGitでも基本的にはパス単位で判定される)

この抽象化により，「検証すべき性質」で述べた具体例 (`"Hello"` → `"Hello, World!"`など) は以下のように対応する:

| 検証すべき性質の例                  | Alloyモデルでの表現                   |
| ----------------------------------- | ------------------------------------- |
| `foo.txt`の内容`"Hello"`            | パス`p`に対応するBlob `b1`            |
| `"Hello"` → `"Hello, World!"`の変更 | Blob `b1`から`b2`への変更 (異なるOID) |
| 両ブランチが同じ変更                | c1とc2で同じBlob `b2`を参照           |
| 両ブランチが異なる変更              | c1は`b2`，c2は`b3`を参照 (`b2 ≠ b3`)  |

抽象化の妥当性:

- Gitの実装 (`merge-ort.c`の`process_entry()`) も，まずエントリレベルでの比較 (match_mask) を行い，その後に必要に応じてファイル内容のマージを実行する
- エントリレベルでの判定ロジックが正しければ，ファイル内容の詳細を考慮しなくても3-wayマージの基本的な性質は検証できる

### 検証する性質と対応するAlloyスクリプト

#### 1. SameChangeAdopted: 両側が同じ変更なら採用

検証すべき性質 (再掲):

両方のブランチが同じ変更を行った場合，その変更がマージ結果に採用され，競合は発生しない．

検証の考え方:

この性質は，Gitの`match_mask == 6 (110)`のケースに対応する．すなわち，side1とside2のエントリが一致する場合である．

検証すべき性質の例:

- base: `foo.txt`に`"Hello"`
- c1: `"Hello"` → `"Hello, World!"`
- c2: `"Hello"` → `"Hello, World!"` (c1と同じ変更)
- 期待: `"Hello, World!"`が採用され，競合なし

Alloyモデルでは:

- base: パス`p`にBlob `b1`のエントリ
- c1: パス`p`にBlob `b2`のエントリ (`b2 ≠ b1`)
- c2: パス`p`にBlob `b2`のエントリ (c1と同じ)
- 期待: マージ結果のパス`p`もBlob `b2`のエントリで，`p not in res.conflicts`

Alloyスクリプト:

```alloy
-- 検証: 両側が同じ変更なら，その変更が採用され競合しない
assert SameChangeAdopted {
  all b, c1, c2: Commit, res: MergeResult, p: Path |
    (
      b in mergeBases[c1, c2] and
      res = threeWayMerge[b, c1, c2] and
      -- パス p が少なくともマージ対象のいずれかに存在する場合のみを考える
      p in (c1.tree.entries.path + c2.tree.entries.path + b.tree.entries.path)
    )
    implies

    let e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |

      -- c1とc2が同じ状態であれば
      entriesEqual[e1, e2]
      implies
      -- 結果もそれと同じになり，かつ競合リストに含まれない
      (entriesEqual[e_res, e1] and p not in res.conflicts)
}
```

「検証すべき性質」との対応:

- assertの前提条件: `b in mergeBases[c1, c2]`により，bがマージベースであることを保証
- assertの結論部分: `entriesEqual[e1, e2] implies (entriesEqual[e_res, e1] and p not in res.conflicts)`
  - `entriesEqual[e1, e2]`: 「両方のブランチが同じ変更」に対応
  - `entriesEqual[e_res, e1]`: 「その変更がマージ結果に採用」に対応
  - `p not in res.conflicts`: 「競合は発生しない」に対応

#### 2. OneSideChangeAdopted: 片方のみ変更なら採用

検証すべき性質 (再掲): 一方のブランチのみが変更を行い，もう一方が変更を行わなかった場合，その変更がマージ結果に採用され，競合は発生しない．

検証の考え方:

この性質は，Gitの`match_mask == 3 (011)`または`match_mask == 5 (101)`のケースに対応する．すなわち，片方のブランチのみがbaseと異なる場合である．

検証すべき性質の例:

- base: `bar.txt`に`"v1.0"`
- c1: 変更なし (`"v1.0"`のまま)
- c2: `"v1.0"` → `"v2.0"`
- 期待: `"v2.0"`が採用され，競合なし

Alloyモデルでは:

- base: パス`p`にBlob `b1`のエントリ
- c1: パス`p`にBlob `b1`のエントリ (baseと同じ)
- c2: パス`p`にBlob `b2`のエントリ (`b2 ≠ b1`)
- 期待: マージ結果のパス`p`はBlob `b2`のエントリで，`p not in res.conflicts`

Alloyスクリプト:

```alloy
-- 検証: 片方だけ変更された場合，その変更が採用され競合しない
assert OneSideChangeAdopted {
  all b, c1, c2: Commit, res: MergeResult, p: Path |
    (
      b in mergeBases[c1, c2] and
      res = threeWayMerge[b, c1, c2] and
      -- パス p が少なくともマージ対象のいずれかに存在する場合のみを考える
      p in (c1.tree.entries.path + c2.tree.entries.path + b.tree.entries.path)
    )
    implies

    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |

      -- c1がbaseと同じでc2が異なる場合
      (entriesEqual[e1, e_base] and not entriesEqual[e2, e_base])
      implies
      -- 結果はc2と同じで，かつ競合しない
      (entriesEqual[e_res, e2] and p not in res.conflicts)
}
```

「検証すべき性質」との対応:

- assertの結論部分: `(entriesEqual[e1, e_base] and not entriesEqual[e2, e_base]) implies (entriesEqual[e_res, e2] and p not in res.conflicts)`
  - `entriesEqual[e1, e_base]`: 「c1が変更を行わなかった」に対応
  - `not entriesEqual[e2, e_base]`: 「c2が変更を行った」に対応
  - `entriesEqual[e_res, e2]`: 「その変更 (c2の変更) がマージ結果に採用」に対応
  - `p not in res.conflicts`: 「競合は発生しない」に対応

このassertは`c1がbaseと同じ`のケースのみを検証しているが，`threeWayMerge`関数は対称的に定義されているため，`c2がbaseと同じ`のケースも同様に保証される (`match_mask == 5`のケース) ことに注意．

#### 3. ConflictWhenDifferentChanges: 両側が異なる変更なら競合

検証すべき性質 (再掲): 両方のブランチが異なる変更を行った場合，競合が発生する．

検証の考え方:

この性質は，Gitの`match_mask == 0 (000)`のケースに対応する．すなわち，3つの状態 (base, side1, side2) がすべて異なる場合である．

検証すべき性質の例:

- base: `version.txt`に`"1.0"`
- c1: `"1.0"` → `"2.0"`
- c2: `"1.0"` → `"3.0"`
- 期待: 競合が発生

Alloyモデルでは:

- base: パス`p`にBlob `b1`のエントリ
- c1: パス`p`にBlob `b2`のエントリ (`b2 ≠ b1`)
- c2: パス`p`にBlob `b3`のエントリ (`b3 ≠ b1` かつ `b3 ≠ b2`)
- 期待: `p in res.conflicts`

Alloyスクリプト:

```alloy
-- 検証: 両側が異なる変更なら競合が発生する
assert ConflictWhenDifferentChanges {
  all b, c1, c2: Commit, res: MergeResult, p: Path |
    (
      b in mergeBases[c1, c2] and
      res = threeWayMerge[b, c1, c2] and
      -- パス p が少なくともマージ対象のいずれかに存在する場合のみを考える
      p in (c1.tree.entries.path + c2.tree.entries.path + b.tree.entries.path)
    )
    implies

    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p] |

      -- 両側がbaseと異なり，かつ両側の変更も異なる場合
      (
        not entriesEqual[e1, e_base] and
        not entriesEqual[e2, e_base] and
        not entriesEqual[e1, e2]
      )
      implies
      -- そのパスは競合としてマークされている
      p in res.conflicts
}
```

「検証すべき性質」との対応:

- assertの結論部分: `(not entriesEqual[e1, e_base] and not entriesEqual[e2, e_base] and not entriesEqual[e1, e2]) implies p in res.conflicts`
  - `not entriesEqual[e1, e_base]`: 「c1がbaseと異なる変更を行った」に対応
  - `not entriesEqual[e2, e_base]`: 「c2がbaseと異なる変更を行った」に対応
  - `not entriesEqual[e1, e2]`: 「c1とc2の変更が異なる」に対応
  - `p in res.conflicts`: 「競合が発生する」に対応

### スコープの設定

検証にはスコープ「`for 6 but 3 Commit, 1 MergeResult`」を使用している:

- `for 6`: 各シグネチャのインスタンス数を最大6個に制限
- `but 3 Commit`: Commitインスタンスを最大3個に制限
  - base, c1, c2の3つのコミットを表現するのに十分
- `1 MergeResult`: MergeResultインスタンスをちょうど1個に制限
  - マージ結果は1つだけ存在すれば十分
