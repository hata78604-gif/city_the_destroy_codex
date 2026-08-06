# 追加指示書3: NPCの見た目変更 + 破壊時の逃走パニック挙動

## 0. この指示書について

- `roblox_destruction_game_spec.md`（本体）と既存の `NPCManager.lua` への**追加改修指示**である。既存の方針（サーバー権威、Config集約、日本語コメント、SETUP.md更新）はすべて維持すること
- 目的:
  1. 緑一色の軽量NPCを「Roblox標準アバター風（R6ブロック体・部位別カラー・四角い頭）」の見た目にする
  2. 建物ブロックが破壊されたとき、近くのNPCが「両手を挙げて `help!` と叫びながら逃げ、最後は消える」パニック挙動を追加する
- **重要な前提**: このNPCは意図的に **Humanoid を使わない軽量設計**（Part集合を WeldConstraint で結合し、アンカーのまま CFrame/PivotTo で徘徊）。この軽量設計は絶対に壊さないこと。Humanoid や AnimationController への置き換えは禁止。関節（Motor6D）も導入しない
- **ロジックを変えない部分**: 徘徊AIの基本構造、爆風での即死・ラグドール化・スコア加算・再スポーン維持は現状の挙動を保つこと。今回足すのは「見た目」と「即死しなかった近隣NPCの逃走」のみ

---

## 1. 対象ファイル

- `ServerScriptService/Modules/NPCManager.lua` ← 中身をほぼ全面改修（下記1〜4を実装）
- `ReplicatedStorage/Config.lua` ← `Config.NPC` に項目追加（下記セクション5）
- `SETUP.md` ← 変更点を追記（下記セクション7）
- `ServerScriptService/Modules/DestructionManager.lua` は**変更しない**（`onNpcExplosion(position, radius, attacker)` 経由で既に必要情報が渡っているため。配線の新設不要）

### 作業環境について（重要）

- このプロジェクトは **Rojo でファイル → Roblox Studio へ自動同期**している。ファイルを編集・保存すればStudioに反映されるため、「Studioに手で貼り付ける」手順の案内は不要
- **必ず既存ファイルを読んでから編集すること**。特に `Config.lua` の `Config.NPC` に実際どのキーが定義されているか（`Count` / `WanderRange` / `WalkSpeed` / `DespawnTime` / `RespawnDelay` など）を確認し、**実際のキー名に合わせる**こと。この指示書のキー名は既存コードから推測したものなので、食い違う場合は既存ファイルを正とする
- `NPCManager.lua` と `DestructionManager.lua` の現行実装を読み、既存の構造・命名・コメントのスタイルに合わせること

---

## 2. 見た目の変更（NPC生成部分）

現状の `makePart()` は全パーツに `Config.NPC.Color`（緑一色）を適用し、頭を `Enum.PartType.Ball`（球）にしている。これを標準R6アバター風に変える。

### 2.1 部位別カラー
`makePart()` に色引数を追加し、部位ごとに色を指定できるようにする。配色は Config から取得（セクション5参照）。デフォルト配色の目安:

- Head / LeftArm / RightArm → 肌色系（例: `Color3.fromRGB(255, 204, 153)` 相当。Config.NPC.SkinColor）
- Torso → シャツ色（例: `Color3.fromRGB(0, 162, 255)` 相当。Config.NPC.ShirtColor）
- LeftLeg / RightLeg → ズボン色（例: `Color3.fromRGB(60, 60, 70)` 相当。Config.NPC.PantsColor）

- 既存の `Config.NPC.Color` は削除せず、後方互換のため残してよい（未使用でも可）。ただし新しい3色が無い場合は `Config.NPC.Color` にフォールバックすること（Config貼り替え漏れでも動くように。既存の DestructionManager の Config フォールバック方針に倣う）

### 2.2 四角い頭
`head.Shape = Enum.PartType.Ball` の行を削除し、頭を通常の直方体（Block）に戻す。標準R6風に、頭サイズは現状の `Vector3.new(1.2, 1.2, 1.2)` のままでよい（四角い頭になる）。

### 2.3 変えないこと
- パーツ構成（Torso/Head/両腕/両脚の6パーツ）、サイズ、相対位置、Weld結合の仕組みは維持
- `Anchored = true`（徘徊中アンカー）、`CanCollide = false`、`CastShadow = false` は維持

---

## 3. パニック逃走挙動（新規）

### 3.1 状態の持ち方
NPCテーブル（`npc = { model, torso, alive, target }`）に以下を追加する:
- `npc.panicUntil`（number/nil）: パニック終了時刻（`os.clock()` 基準）。nil または過去時刻なら通常徘徊
- `npc.fleeing`（bool）: 逃走中フラグ（消滅処理の二重起動防止）

### 3.2 パニックのトリガー
`NPCManager.OnExplosion(position, radius, attacker)` を拡張する。現状は「半径+2以内のNPCを即死」させているが、ここに以下を追加:

- **即死判定は現状維持**: `(npc.torso.Position - position).Magnitude <= radius + 2` → `killNpc`（従来通り）
- **パニック判定を新設**: 即死しなかった生存NPCのうち、`Config.NPC.PanicRadius`（=35）以内にいるものを `startPanic(npc, position)` でパニックさせる
- 距離判定は1回のループ内でまとめて行う（即死 → それ以外でパニック範囲内、の順で分岐）

### 3.3 startPanic(npc, blastPos) の処理
1. すでに `npc.fleeing` なら、`panicUntil` を延長するだけで return（二重処理防止・爆発連発対策）
2. `npc.panicUntil = os.clock() + Config.NPC.PanicDuration`（=8秒）
3. `npc.fleeing = true`
4. **逃走目的地の設定**: 破壊地点と反対方向へ。`dir = (npc.torso.Position - blastPos)` を水平化して正規化 → `npc.target = npc.torso.Position + dir * (大きめの距離、例120)`。マップ範囲（`Config.NPC.WanderRange`）で軽くclampしてよいが、多少はみ出す程度は許容（逃げてる感が出る）
5. **両手を挙げる**: `raiseArms(npc)` を呼ぶ（3.5参照）
6. **フキダシ**: `showHelpBubble(npc)` を呼ぶ（3.6参照）

### 3.4 逃走の移動（Heartbeatループの拡張）
既存の徘徊Heartbeatループを拡張する:
- `npc.panicUntil` が現在時刻より未来なら **パニック中**: 移動速度を `Config.NPC.PanicSpeed`（=24）にする。目的地到着（`to.Magnitude < 2`）しても `randomPoint()` で通常徘徊に戻さず、逃走目的地を維持（さらに遠くへ延長してもよい）
- パニック中でなければ従来の徘徊速度 `Config.NPC.WalkSpeed`
- **消滅**: パニック中のNPCで `os.clock() >= npc.panicUntil` になったら `fleeAway(npc)` を呼んでフェードアウト消滅させる（3.7参照）。この判定はHeartbeat内で1回だけ走るよう、`fleeing` フラグで制御

### 3.5 raiseArms(npc) — 両手を挙げる
- Humanoid/Motor6D が無いため、腕Partを直接「上向き」に再配置する
- 実装方針: LeftArm / RightArm の既存 WeldConstraint を一度 Destroy し、腕を斜め上に向けた相対CFrameで Torso に再溶接する
  - 手順: 腕の `CFrame` を、Torso基準で「肩から斜め上・前方に突き出す角度」に設定 → 新しい WeldConstraint（Part0=Torso, Part1=腕）を作成
  - こうすれば以後の `PivotTo`（モデル全体移動）に腕も追従し、上げたポーズを保ったまま逃げる
- 角度の目安: 腕が真横〜斜め上（万歳の少し手前）で「助けを求めてる」感が出ればよい。厳密なアニメは不要
- **注意**: 徘徊は `model:PivotTo(CFrame.lookAt(...))` でモデル全体を動かしている。腕はWeldでTorsoに固定されているのでPivotToに追従する。再溶接後も相対位置が保たれることを確認すること

### 3.6 showHelpBubble(npc) — help! の吹き出し
- **`Chat:Chat()` は使わない**（レガシーで動作しない環境がある）
- `TextChatService:DisplayBubble(npc.head, "help!")` を使う。第1引数は吹き出しを出す BasePart（頭）
  - `TextChatService` を `game:GetService("TextChatService")` で取得
  - **サーバーから呼べる**が、環境によって挙動差があるため `pcall` で包み、失敗しても逃走処理は続行すること
  - `spawnNpc` 時に head を npc テーブルに保持していない場合は、`npc.head` を持たせるよう生成部を修正する（現状 torso は保持しているが head は未保持）
- テキストは `Config.NPC.PanicText`（="help!"）から取得
- 表示時間の細かい制御は不要（標準の表示時間でよい）

### 3.7 fleeAway(npc) — フェードアウト消滅
- `killNpc` とは**別経路**（スコア加算なし・ラグドール化なし・npcKillエフェクトなし）
- 処理:
  1. `npc.alive = false`、`npcs[npc] = nil`
  2. モデルの全 BasePart を `Config.NPC.FleeFadeTime`（=1秒）かけて `Transparency = 1` へTweenService補間
  3. フェード完了後に `model:Destroy()`
  4. **頭数維持**: 消滅後、`Config.NPC.RespawnDelay` 後に `spawnNpc(randomPoint())` で補充（既存の再スポーンと同じ考え方。常時 `Config.NPC.Count` 体を保つ）
- フェード中はHeartbeatループが触らないよう、`alive=false` でループ対象から外れることを利用する（既存ループは `npc.alive` を見ている）

### 3.8 大量破壊時の負荷対策
- エアストライク等で短時間に複数回 `OnExplosion` が呼ばれる。3.3-1 の「fleeing中はpanicUntil延長のみ」で再計算を防ぐこと
- raiseArms / showHelpBubble はパニック開始の1回だけ実行（延長時は呼ばない）

---

## 4. 既存挙動の保全（回帰チェック）

改修後も以下が壊れていないこと:
- 徘徊: 通常時、NPCが従来通りゆっくりマップ内を歩く
- 即死・ラグドール: 爆心付近のNPCが従来通り吹き飛び+100点・10秒で消える
- 頭数維持: 常時 `Config.NPC.Count`（≒10）体が保たれる（即死経由・逃走消滅経由どちらでも補充される）
- ラウンド制御: `Start` / `Stop` / `Clear` が従来通り動く。`Clear` でパニック中NPCも含めて全消去されること

---

## 5. Config 追加項目（Config.NPC に追記）

```lua
-- 見た目（R6標準アバター風の部位別カラー）
Config.NPC.SkinColor  = Color3.fromRGB(255, 204, 153)  -- 頭・腕
Config.NPC.ShirtColor = Color3.fromRGB(0, 162, 255)    -- 胴体
Config.NPC.PantsColor = Color3.fromRGB(60, 60, 70)     -- 脚
-- （既存の Config.NPC.Color は後方互換フォールバック用に残す）

-- パニック逃走
Config.NPC.PanicRadius   = 35    -- この半径内(即死しなかったNPC)がパニックする
Config.NPC.PanicSpeed    = 24    -- 逃走速度(通常WalkSpeedの約2倍想定)
Config.NPC.PanicDuration = 8     -- 逃げ続ける秒数。この後フェードアウト
Config.NPC.FleeFadeTime  = 1     -- 逃走消滅のフェード秒数
Config.NPC.PanicText     = "help!"  -- 吹き出しに出す文字
```

- 既存の `Config.NPC`（Count / WanderRange / WalkSpeed / DespawnTime / RespawnDelay など）の構成・値は変えない

---

## 6. 実装上の注意まとめ

- Humanoid・Motor6D・AnimationController は導入しない（軽量設計維持）
- 新しい RemoteEvent やクライアント配線は追加しない（フキダシもサーバー発行）
- Config キー不足でも落ちないよう、新規キーはフォールバック既定値を持たせる（DestructionManager の既存方針に倣う）
- 日本語コメントを維持・追記する
- サーバー権威を維持（クライアントに判定を移さない）

---

## 7. SETUP.md への追記事項

1. NPCの見た目が「緑一色」から「Roblox標準アバター風（肌色の頭腕・青い胴・四角い頭）」に変わった旨
2. 破壊時パニックの動作確認ポイントを Phase 3 付近に追記:
   - [ ] 建物を壊すと、爆心付近のNPCは即死（従来通り）
   - [ ] 即死しなかった半径35stud以内のNPCが、両手を挙げて `help!` の吹き出しを出し、破壊地点と反対方向へ速く逃げる
   - [ ] 逃げたNPCは約8秒後にスーッと消え、別地点に新しいNPCが湧いて頭数が保たれる
   - [ ] エアストライクで連続爆発させても、パニックが二重に走らずカクつかない
3. Config.NPC の新項目（PanicRadius / PanicSpeed / PanicDuration / 配色）の説明を「ゲームバランスの調整」節に追記

---

## 8. 受け入れ基準

- [ ] NPCが標準アバター風（部位別カラー・四角い頭）で生成される
- [ ] 建物破壊時、爆心付近は即死・半径35内は逃走パニックに分岐する
- [ ] パニックNPCが両手を挙げ、`help!` フキダシを出し、反対方向へ逃げる
- [ ] 逃走NPCは約8秒後にフェードアウトで消え、頭数が維持される
- [ ] エアストライク連発でも二重パニックせず、負荷が跳ねない
- [ ] 徘徊・即死ラグドール・スコア・ラウンド制御など既存挙動が回帰していない
- [ ] 出力に赤いエラーが出ない（3分プレイ）
