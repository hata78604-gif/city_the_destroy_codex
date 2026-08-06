# 修正指示: help! フキダシを BillboardGui 方式に差し替える

## 0. この指示書について

- `npc_panic_spec.md`（NPCパニック挙動）の **セクション3.6 の実装のみを差し替える**修正指示である
- それ以外（配色・四角い頭・手挙げ・逃走・フェードアウト消滅・Config構成）は**現状の実装のままでよい。触らないこと**
- 対象ファイル: `ServerScriptService/Modules/NPCManager.lua`（および必要なら `ReplicatedStorage/Config.lua`）

## 1. 差し替える理由

現在の実装は `TextChatService:DisplayBubble()` を使っているが、**この方式では吹き出しが表示されない**。理由:

- `DisplayBubble()` は**サーバーから呼んでもクライアントに複製されない**（クライアントで実行した場合のみ動作する）。NPCManager はサーバーモジュールなので、呼んでも何も起きない
- さらに 2026年以降、この API 自体が正常に動作しないという報告が多数ある（NPCに対して効かない、呼んでも吹き出しが出ない等）
- 現在 `pcall` で包んでいるため、エラーも出ずに黙って無視されている状態

→ **TextChatService を使う実装は完全に削除し、BillboardGui による自作フキダシに置き換える。**

## 2. 新しい実装方針

### 2.1 基本方針
- サーバー側で `BillboardGui` を生成し、NPCの頭（Head パーツ）に親子付けする
- BillboardGui は通常の Instance なので、**サーバーで作れば自動的に全クライアントへ複製される**。RemoteEvent やクライアント側スクリプトの追加は不要（既存のサーバー権威設計を維持）
- `TextChatService` の取得・呼び出しコードはすべて削除する

### 2.2 生成タイミング（重要）
- **NPC生成時（`spawnNpc` 内）にフキダシを1つ作っておき、`Enabled = false` で隠しておく**
- パニック開始時は `Enabled = true` にするだけにする
- 理由: 爆発の瞬間に複数NPCが同時にInstanceを生成すると負荷が集中する。あらかじめ作っておけば、パニック時はフラグを立てるだけで済む
- NPCが消滅するとき、フキダシは Head の子なのでモデルごと自動的に消える（個別の削除処理は不要）

### 2.3 見た目の構成
漫画風の吹き出しに近づける。構成:

- `BillboardGui`
  - `Size`: おおよそ 100x40 ピクセル程度（`UDim2.fromOffset`）
  - `StudsOffset`: 頭の上に浮かせる（例 `Vector3.new(0, 2.2, 0)`）
  - `AlwaysOnTop = false`（建物の陰に隠れるほうが自然。ただし見えにくければ true でもよい）
  - `LightInfluence = 0`（暗くならず常にはっきり見える）
  - `MaxDistance`: **必ず設定する**（例 150）。遠くのNPCのフキダシを描画しないことで負荷を抑える
  - `Enabled = false`（初期状態）
- 中身:
  - 白い `Frame` に `UICorner`（角丸）を付けて吹き出し本体にする
  - `TextLabel` に `Config.NPC.PanicText`（="help!"）を表示。文字色は黒、`Font` は太めのもの（`Enum.Font.FredokaOne` や `GothamBold` など読みやすいもの）、`TextScaled = true`
  - **尻尾（吹き出しの下の三角）**: 小さな正方形 `Frame` を45度回転（`Rotation = 45`）させ、本体と同じ白色で下端中央に配置すると、三角の尻尾に見える。凝った画像は不要

### 2.4 パニックとの連動
- `showHelpBubble(npc)` の中身を「`npc.bubbleGui.Enabled = true`」に置き換える
- パニックが延長された場合も、すでに表示中なので何もしなくてよい（現状の「延長時は呼ばない」制御はそのまま）
- 逃走消滅（`fleeAway`）のフェードアウト時、フキダシも一緒に消えるようにする。`BasePart` の Transparency を上げるだけでは GUI は消えないため、**フェード開始時に `Enabled = false` にする**か、TextLabel/Frame の `BackgroundTransparency` / `TextTransparency` も併せて補間すること（簡単なので前者でよい）

### 2.5 npc テーブルへの追加
- `npc.bubbleGui` として BillboardGui の参照を持たせる（`spawnNpc` 内で設定）
- 既存の `npc.head` 参照はそのまま利用してよい

## 3. Config（任意）

見た目を後から調整できるよう、以下を `Config.NPC` に追加してもよい（必須ではない）:

```lua
Config.NPC.BubbleMaxDistance = 150   -- フキダシを描画する最大距離
```

- 既存の `Config.NPC.PanicText` はそのまま使う
- 新規キーが無くても動くようフォールバック既定値を持たせること（既存方針に倣う）

## 4. 削除すること

- `game:GetService("TextChatService")` の取得
- `TextChatService:DisplayBubble(...)` の呼び出しと、それを包んでいた `pcall`
- 関連する「TextChatServiceが使えない環境がある」旨のコメント（新方式の説明コメントに書き換える）

## 5. 受け入れ基準

- [ ] 建物を壊すと、パニックしたNPCの頭上に白い「help!」の吹き出しが表示される
- [ ] 吹き出しが漫画風（角丸＋下向きの三角の尻尾）に見える
- [ ] 逃走NPCが消えるとき、吹き出しも一緒に消える
- [ ] 遠くのNPCの吹き出しは表示されない（MaxDistance が効いている）
- [ ] エアストライク連発でもカクつかない
- [ ] 出力に赤いエラーが出ない
- [ ] 配色・四角い頭・手挙げ・逃走・消滅など、他の挙動は変わっていない
