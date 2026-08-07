# LINT_SETUP.md — Luau 静的チェックの導入と既存警告の解消

## 0. この文書について

`luau-lsp` による静的チェックを開発ワークフローに組み込み、現時点で検出されている
3件の警告を解消する。**ゲームの挙動は一切変更しない**。

推奨モデル: **Sonnet**
理由: 変更対象は3ファイル・各数行の機械的な等価変換と、新規 `.bat` 1本の作成のみ。
設計判断を伴わないため Opus は不要。ただし複数ファイルにまたがるため Haiku は使わない。

---

## 1. 前提（ユーザー側で完了済み。再実行不要）

以下はすべて導入済みである。**やり直さないこと。**

- VS Code 拡張 `Luau Language Server` (JohnnyMorganz) をインストール済み
- `luau-lsp.exe` を `C:\tools` に配置し、ユーザー環境変数 `Path` に登録済み
  - `luau-lsp --version` が通ることを確認済み
- `globalTypes.d.luau`（約663KB）をプロジェクト直下にダウンロード済み
- `sourcemap.json` を生成済み

### 重要: 日本語パス問題とジャンクション

プロジェクトの実体は以下にある。

```
C:\Users\h_jun\OneDrive\Desktop\ロブロックス破壊ゲーム
```

`luau-lsp` は**この日本語パスを解決できない**（`path does not exist` になる）。
そのため回避策として、ASCII のみのジャンクションを作成済みである。

```
C:\rbxgame  →  C:\Users\h_jun\OneDrive\Desktop\ロブロックス破壊ゲーム
```

**運用ルール（厳守）**

| 用途 | 使うパス |
|---|---|
| ファイルの編集・Rojo・Git | 元の日本語パス（現在の作業ディレクトリ） |
| `luau-lsp` の実行のみ | `C:\rbxgame` |

ジャンクション経由でファイルを編集しないこと。OneDrive の同期が混乱する恐れがある。
実体は同一なので、編集は必ず元のパス側で行う。

---

## 2. スコープ外（やらないこと）

- ゲームロジック・バランス値・仕様の変更
- `luau-lsp` が今後追加で検出する警告のうち、本書に明記されていないものの修正
  （検出した場合は**報告のみ**行い、修正はしない）
- 型注釈の追加による型安全性の向上（別タスク）
- `.luaurc` の作成（現状の警告件数が少ないため不要）
- `CURRENT_SPEC.md` の更新（挙動変更が無いため）

---

## 3. 手順1: 計画の報告（実装前に必ず停止）

コードに触れる前に、以下を報告して**ユーザーの承認を待つこと**。

1. 手順2〜7で触るファイルの一覧
2. 手順4-3（`rng` の扱い）について、実際にコードを読んだ上での判断と根拠
3. 本書の記述と実コードに食い違いがあれば、その内容

承認が出るまで一切の編集を行わない。

---

## 4. 手順2: `lint.bat` の作成

プロジェクト直下（`default.project.json` と同じ階層）に `lint.bat` を新規作成する。

```bat
@echo off
chcp 932 > nul
cd /d C:\rbxgame
echo === sourcemap を更新中 ===
rojo sourcemap default.project.json --output sourcemap.json
echo === 静的チェック実行中 ===
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau ServerScriptService ReplicatedStorage StarterPlayer > lint.txt 2>&1
type lint.txt
echo.
echo === 完了 ===
pause
```

**設計意図（変更しないこと）**

- `cd /d C:\rbxgame` を先頭に置くことで、この `.bat` をどこから起動しても日本語パスを踏まない
- `chcp 932` は出力の文字化け防止
- `sourcemap.json` を毎回再生成する。ファイル追加直後でも正しく解決させるため
- `2>&1` が必須。`luau-lsp` は INFO/WARN も標準エラー出力に書くため、これが無いと
  PowerShell 経由で実行したときに正常なお知らせまで赤いエラー表示になる
- 検査範囲は `ServerScriptService` / `ReplicatedStorage` / `StarterPlayer` の3つ

---

## 5. 手順3: 初回実行と現状把握

`lint.bat` を実行し、`lint.txt` の全内容を報告する。

**予想される内容**（ユーザーが `ServerScriptService` のみで実行済みの結果）

```
NPCManager.lua(315,4):   TypeError: Value of type 'any?' could be nil
EnemyManager.lua(788,4): TypeError: Value of type 'any?' could be nil
WeaponServer.lua(20,7):  LocalUnused: Variable 'rng' is never used
```

今回は `ReplicatedStorage` と `StarterPlayer` を範囲に追加しているため、
**上記以外の新規警告が出る可能性がある**。出た場合は:

- 内容を一覧にして報告する
- **修正はせず**、手順4の3件のみを対象とする
- 報告の中で「実害があるか / 型チェッカーの限界か」の見立てを添える

---

## 6. 手順4: 3件の警告を解消する

### 4-1. `NPCManager.lua` 315行目付近

`killNpc` 内の Weld 破壊処理。現状:

```luau
	for _ = 1, rng:NextInteger(2, 3) do
		if #welds > 0 then
			table.remove(welds, rng:NextInteger(1, #welds)):Destroy()
		end
	end
```

`table.remove` の戻り値は `any?`（nil の可能性あり）だが、直接 `:Destroy()` を呼んでいる。
`if #welds > 0` があるため実行時には nil にならないが、型チェッカーはその関係を追えない。

**修正後:**

```luau
	for _ = 1, rng:NextInteger(2, 3) do
		if #welds > 0 then
			local w = table.remove(welds, rng:NextInteger(1, #welds))
			if w then
				w:Destroy()
			end
		end
	end
```

挙動は完全に等価。将来 `welds` を操作する行が増えたときに保証が静かに壊れるのを防ぐ。

### 4-2. `EnemyManager.lua` 788行目付近

`NPCManager.killNpc` の手法をコピーした撃破時のラグドール化処理。
**4-1 と同一パターンのはず**なので、同じ形に修正する。

ただし実コードを必ず読むこと。パターンが異なっていた場合は、
勝手に判断せず**報告して停止する**。

### 4-3. `WeaponServer.lua` 20行目 — `rng` 未使用

```
LocalUnused: Variable 'rng' is never used; prefix with '_' to silence
```

**背景の推測**: Step 4c（絨毯爆撃）でエアストライクの `Scatter` と `BombCount` を
削除した際に、乱数の使い道が無くなって取り残されたものと思われる。

**手順:**

1. `WeaponServer.lua` 全体で `rng` を検索する
2. **どこにも使われていない場合** → 20行目の宣言を削除する
3. **どこかで使われている場合** → 警告の内容と食い違うため、
   削除せずに状況を報告して停止する

削除を第一候補とする。使われていない変数は、後から読む人に
「これは何かに使うのだろう」と誤解させる負債になるため。

---

## 7. 手順5: 再実行と差分確認

`lint.bat` を再実行し、以下を確認する。

- 上記3件が消えていること
- **新しい警告が増えていないこと**（最重要）

増えていた場合は、直前の修正が原因である可能性が高い。報告して停止する。

---

## 8. 手順6: `.gitignore` の更新

以下の2行を `.gitignore` に追加する（既にあれば追加しない）。

```
sourcemap.json
lint.txt
```

**`globalTypes.d.luau` は追加しない**（=Git 管理下に置く）。
約663KB とやや大きいが、無視すると別環境や Claude Code 実行時に
毎回ダウンロードが必要になる。ソロ開発のため、コミットする方が運用が楽である。

---

## 9. 手順7: `PROGRESS.md` への追記

`PROGRESS.md` の末尾に、以下の見出しで節を追加する。

```
# Luau 静的チェックの導入（2026-08-07）
```

記載する内容:

- **実装したもの**: `lint.bat` の追加、3件の警告修正（ファイル名と行を明記）
- **ハマった点と対処**: `luau-lsp` が日本語パスを解決できず `path does not exist` に
  なる件と、`C:\rbxgame` ジャンクションによる回避。PowerShell が標準エラー出力を
  すべてエラー扱いする件と `2>&1` による対処
- **ユーザー手作業**: 環境変数 `Path` への `C:\tools` 追加、
  ジャンクション作成（`mklink /J`）はセットアップ済みだが、
  **PC を変えた場合は再実行が必要**である旨
- **次ステップへの申し送り**: 以降の実装作業では、完了報告の前に `lint.bat` を
  実行し、既存の警告との差分を報告に含めること

---

## 10. 完了条件

1. `lint.bat` がプロジェクト直下に存在し、ダブルクリックで動作する
2. `lint.txt` に上記3件の警告が出ていない
3. 3件の修正によって新規の警告が増えていない
4. `.gitignore` が更新されている
5. `PROGRESS.md` に節が追加されている
6. **ゲームの挙動が変わっていない**（等価変換のみ）

---

## 11. 動作確認（実装後）

`roblox-playtest` スキルでプレイテストを行い、以下を確認する。

- 市民NPC（`NPCManager`）を爆発に巻き込み、ラグドール化が従来どおり起きること
- 警官（`EnemyManager`）を撃破し、ラグドール化が従来どおり起きること
- エアストライク（絨毯爆撃）が従来どおり動作すること
- コンソールに新規のエラー・警告が出ていないこと

---

## 12. 報告フォーマット

完了時、以下を報告する。

1. 変更したファイルと変更内容の要約
2. 修正前後の `lint.txt` の内容
3. 手順3で新規に検出された警告があれば、その一覧と見立て（未修正のまま）
4. プレイテストの結果
5. ユーザーが追加で行う必要がある作業があれば、その具体的手順
