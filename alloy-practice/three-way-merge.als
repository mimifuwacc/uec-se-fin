-- Gitのオブジェクト識別子
sig OID {}

-- Git の基本オブジェクト
abstract sig Object {
  oid: one OID
}

-- OID は一意でなければならない
fact OIDUnique {
  all disj o1, o2: Object | o1.oid != o2.oid
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

-- コミットの親子関係は循環してはならない
fact CommitAcyclic {
  all c: Commit | c not in c.^parents
}

-- ツリーエントリのモード
-- 100644: 通常のファイル
-- 100755: 実行可能ファイル
-- 120000: シンボリックリンク
-- 040000: ディレクトリ
-- 160000: サブモジュール (ここでは扱わない)
abstract sig Mode {}
one sig Mode100644, Mode100755, Mode120000, Mode040000 extends Mode {}

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

-- モードに応じたオブジェクト型の制約
fact NameEntryTypeConstraint {
  all e: NameEntry |
  (e.mode in Mode040000 implies e.object in Tree) and
  (e.mode not in Mode040000 implies e.object in Blob)
}

-- ディレクトリ構造を表すツリーオブジェクト
sig Tree extends Object {
  -- ツリー内のエントリ集合
  entries: set NameEntry
}

-- 同じツリー内で同じパスは存在しない
fact TreeEntryUnique {
  all t: Tree | all disj e1, e2: t.entries | e1.path != e2.path
}

-- ツリーのエントリ関係は循環してはならない
fact TreeAcyclic {
  all t: Tree | t not in t.^(entries.object :> Tree)
}

-- ファイル内容を表すブロブオブジェクトおよびタグオブジェクト
-- マージの検証においてはファイル内容は考慮しない
-- ref. https://github.com/git/git/blob/b2826b52eb7caff9f4ed6e85ec45e338bf02ad09/object.h#L93-L109
sig Blob extends Object {}
sig Tag extends Object {}

-- 2つのコミットの共通祖先の集合
fun commonAncestors[c1, c2: Commit]: set Commit {
  c1.^parents & c2.^parents
}

-- 最も近い共通祖先 (マージベース) の抽出
fun mergeBases[c1, c2: Commit]: set Commit {
  let common = commonAncestors[c1, c2] |
  { ca: common | no other: common - ca | other in ca.^parents }
}

-- 指定したツリーに含まれる，特定のパスを持つエントリを取得
fun entryAt[t: Tree, p: Path]: lone NameEntry {
  { e: t.entries | e.path = p}
}

-- 2つのエントリ集合が等しいかを判定 (両方空，または両方同じエントリ) 
pred entriesEqual[e1, e2: set NameEntry] {
  #e1 = #e2
  and
  (no e1 or e1.mode = e2.mode and e1.object = e2.object)
}

-- マージ結果を表す
-- コンフリクトしているパスの集合を含む
sig MergeResult {
  tree: Tree,
  conflicts: set Path,
}

-- 3-wayマージを実行し，マージ結果を返す
--
-- パラメータ:
--   base: マージベースのコミット
--   c1  : マージ対象のコミット1
--   c2  : マージ対象のコミット2
-- 戻り値:
--   MergeResult: マージ結果のツリーと競合しているパスの集合
--                マージ結果が存在しない場合はnone
--
-- マージの振る舞いはGitの3-wayマージアルゴリズムに基づく
-- process_entry() 内の match_mask によるケース分けをモデル化している
-- cf. https://github.com/git/git/blob/b2826b52eb7caff9f4ed6e85ec45e338bf02ad09/merge-ort.c#L4190-L4210
fun threeWayMerge[base, c1, c2: Commit]: lone MergeResult {
  { res: MergeResult |
    let t_base = base.tree, t1 = c1.tree, t2 = c2.tree | {
      -- 競合としてマークされているパスは，3つのツリーに現れるパスのいずれかである
      res.conflicts in (t_base.entries.path + t1.entries.path + t2.entries.path)
      and
      -- 3つのツリーに現れる全てのパスについて調べる
      all p: (t_base.entries.path + t1.entries.path + t2.entries.path) |
        -- あるパス p に対して，各ツリーからそのパスのエントリを取得
        -- e_base: マージベースのエントリ
        -- e1    : コミット1のエントリ
        -- e2    : コミット2のエントリ
        -- e_res : マージ結果のエントリ
        let e_base = {e: t_base.entries | e.path = p},
            e1 = {e: t1.entries | e.path = p},
            e2 = {e: t2.entries | e.path = p},
            e_res = {e: res.tree.entries | e.path = p} |

          let e1_eq_e2 = entriesEqual[e1, e2],
              e1_eq_base = entriesEqual[e1, e_base],
              e2_eq_base = entriesEqual[e2, e_base] |

          -- 両方とも同じ状態 (変更なし，または同じ変更)
          -- match_mask == 6 の場合
          (e1_eq_e2 and entriesEqual[e_res, e1] and p not in res.conflicts)
          or
          -- c1 がベースと同じ (c2 だけ変更)
          -- match_mask == 3 (011) の場合
          (e1_eq_base and not e2_eq_base and entriesEqual[e_res, e2] and p not in res.conflicts)
          or
          -- c2 がベースと同じ (c1 だけ変更)
          -- match_mask == 5 (101) の場合
          (e2_eq_base and not e1_eq_base and entriesEqual[e_res, e1] and p not in res.conflicts)
          or
          -- e1 と e2 が異なり，かつどちらもベースと異なる
          -- match_mask == 0 (000) の場合
          -- 実装では，さらにファイルの種類も考慮して自動でコンフリクトを解決する場合があるが，
          -- ここでは考慮しないものとする
          (not e1_eq_e2 and not e1_eq_base and not e2_eq_base and p in res.conflicts and no e_res)
    }
  }
}


-- 両方が同じ変更を加えたマージ
pred showSameChange {
  some b, c1, c2: Commit, res: MergeResult, p: Path | {
    b in mergeBases[c1, c2]
    res = threeWayMerge[b, c1, c2]
    -- パス p が少なくともマージ対象のいずれかに存在する場合のみを考える
    p in (b.tree.entries.path + c1.tree.entries.path + c2.tree.entries.path)

    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |

      -- c1とc2が同じで，baseとは異なる
      entriesEqual[e1, e2] and
      not entriesEqual[e1, e_base] and
      -- 結果はc1 (c2) と同じで，そのパスは競合していない
      entriesEqual[e_res, e1] and
      p not in res.conflicts and
      -- 全体的にも競合はない
      not some res.conflicts
  }
}

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

-- 片方だけ変更されたマージ
-- ここでは c2 が変更を加え，c1 は base と同じ場合を示す
pred showOneSideChange {
  some b, c1, c2: Commit, res: MergeResult, p: Path | {
    b in mergeBases[c1, c2]
    res = threeWayMerge[b, c1, c2]
    -- パス p が少なくともマージ対象のいずれかに存在する場合のみを考える
    p in (b.tree.entries.path + c1.tree.entries.path + c2.tree.entries.path)

    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p],
        e_res = entryAt[res.tree, p] |

      -- c1がbaseと同じでc2が異なる
      entriesEqual[e1, e_base] and
      not entriesEqual[e2, e_base] and
      -- 結果はc2と同じで，そのパスは競合していない
      entriesEqual[e_res, e2] and
      p not in res.conflicts and
      -- 全体的にも競合はない
      not some res.conflicts
  }
}

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

-- 競合が発生したマージ
pred showConflict {
  some b, c1, c2: Commit, res: MergeResult, p: Path | {
    b in mergeBases[c1, c2]
    res = threeWayMerge[b, c1, c2]
    -- パス p が少なくともマージ対象のいずれかに存在する場合のみを考える
    p in (b.tree.entries.path + c1.tree.entries.path + c2.tree.entries.path)

    let e_base = entryAt[b.tree, p],
        e1 = entryAt[c1.tree, p],
        e2 = entryAt[c2.tree, p] |

      -- 両側がbaseと異なり，かつ両側の変更も異なる
      not entriesEqual[e1, e_base] and
      not entriesEqual[e2, e_base] and
      not entriesEqual[e1, e2] and
      -- そのパスは競合としてマークされている
      p in res.conflicts
  }
}

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

run showSameChange for 6 but 3 Commit, 1 MergeResult
check SameChangeAdopted for 6 but 3 Commit, 1 MergeResult

run showOneSideChange for 6 but 3 Commit, 1 MergeResult
check OneSideChangeAdopted for 6 but 3 Commit, 1 MergeResult

run showConflict for 6 but 3 Commit, 1 MergeResult
check ConflictWhenDifferentChanges for 6 but 3 Commit, 1 MergeResult
