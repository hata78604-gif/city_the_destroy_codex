# THREAT_DESIGN_PROPOSAL.md — 敵システム(★1〜★3)+ 武器改修 設計提案

依頼書 §7 に対する回答。**コードは書いていない。既存ファイルは1行も変更していない。**

前提として読んだもの: `CURRENT_SPEC.md` / 既存Lua 9本(実コード)。`archive/` は読んでいない。

---

## 0. 先に結論(3行)

1. **新設は3モジュール**: `RoundClock`(タイム収支)/ `ThreatManager`(段階の政策)/ `EnemyManager`(敵の実体)。既存NPCManagerには手を入れない。
2. **`Explode` はコンテキストオブジェクト1引数に変える**。呼び出し箇所は既存3か所だけなので、後方互換シムなしのクリーンな置き換えが可能。
3. **デススパイラルの本命のガードレールは無敵時間ではなく「直近60秒あたりの最大損失キャップ」**。無敵1.5秒＋-2秒だと理論ドレインが 1.33秒/秒 になり、単体では破綻する(§5 で数値を示す)。

---

## 1. モジュール構成案

### 1-1. 新設モジュール(3本)

| モジュール | 種別 | 責務 | 責務でないもの |
|---|---|---|---|
| **RoundClock** | ModuleScript | バトル残り時間の唯一の持ち主。`Start(base)` / `Remaining()` / `Add(delta, reason, player)` / `Stop()`。上限(300)・下限フロア(15)・損失キャップの適用、変化時のコールバック発火 | クライアントへの送信(GameManagerがやる)、ラウンド遷移 |
| **ThreatManager** | ModuleScript | 段階(★)の政策。スコアを監視して閾値を跨いだら昇格、`Config.Threat.Stages` の編成を `EnemyManager` に渡す、昇格演出の発火、ラウンド境界でのリセット | 敵1体1体の挙動、移動、攻撃判定 |
| **EnemyManager** | ModuleScript | 敵の実体。生成・共有Heartbeatでの移動・攻撃・被弾判定・撃破処理・全消去。`OnExplosion(ctx)` で爆風を受ける | どの敵を何体出すかの判断(ThreatManagerの仕事) |

**なぜ RoundClock を独立させるか(重要な制約)**

`GameManager.server.lua` は **Script であって ModuleScript ではない**。したがって `EnemyManager` から `require(GameManager)` はできない。タイムを GameManager のローカル変数で持つと、増減の経路が全部「依存注入されたコールバック」経由になり、`addTime` を注入されるモジュールが増えるほど GameManager が肥大する。ModuleScript に切り出せば、状態と clamp ロジックが1か所に閉じる。注入自体は既存の `Init(deps)` パターンを踏襲する(モジュール同士が直接 require しない原則は維持)。

**なぜ ThreatManager と EnemyManager を分けるか**

- ThreatManager は「スコア→段階」という**方針**、EnemyManager は「1体の敵をどう動かすか」という**機構**。変更理由が違う(★4 追加は前者、挙動チューニングは後者)。
- ★1 だけ先に作る方針(§6-5)と相性がよい。EnemyManager を先に単体で動かし(デバッグコマンドで手動スポーン)、あとから ThreatManager を被せられる。
- 1本にまとめると 400行超になり、`NPCManager`(399行)と同じ規模のファイルが読みにくい状態で生まれる。

### 1-2. 既存モジュールへの変更点(概要)

| ファイル | 変更の重さ | 内容 |
|---|---|---|
| `Config.lua` | **追加のみ** | `Config.Threat` 新設、`Config.Round` にキャップ/フロア追加、`Config.Weapons` 改修、`Config.Score` にタイム報酬、`Config.Sounds` / `Config.RemoteNames` 追加。**削除は `Airstrike.BombCount` / `Airstrike.Scatter` の2キーのみ**(絨毯爆撃で意味を失うため) |
| `GameManager.server.lua` | 中 | `Hud` リモート追加、3モジュールの require と `Init`、バトルフェーズを RoundClock 駆動に変更、ラウンド境界で `ThreatManager.Start/Stop` `EnemyManager.Clear` |
| `DestructionManager.lua` | 中 | `Explode(ctx)` 化、`scoreScale` 対応、全壊ボーナスの帰属制御、爆風リスナーの配列化、`ctx.maxReal` 対応 |
| `WeaponServer.lua` | 中 | `Explode` 呼び出し3か所の ctx 化、リモート爆弾の距離制限と連鎖倍率、エアストライクの絨毯化、`GetTotalScore()` 追加 |
| `NPCManager.lua` | **極小** | `OnExplosion` の引数が ctx になることへの追随のみ(内部ロジックは1行も変えない)。既存の動いているコードを守る |
| `CityGenerator.lua` | **極小** | `GetRoadLines()` / `GetCityBounds()` の getter を追加するだけ(生成ロジックは不変)。理由は §3-4 |
| `EffectsClient.client.lua` | 中 | エフェクト種別の追加(`enemyAim` / `enemyShot` / `enemyKill` / `tankFire` / `threatUp` / `jet`)、`marker` を矩形の掃射予告に差し替え |
| `UIController.client.lua` | 中 | `Hud` リモートの購読、タイマーの増減演出、フローティング表示、赤フラッシュ、★インジケータ、チェーン表示 |
| `WeaponClient.client.lua` | **変更なし** | 距離制限はサーバー判定。拒否フィードバックも UIController が `Hud` で受けるため触らない |
| `VisualSetup` / `TemplateValidator` | **変更なし** | — |

### 1-3. 依存関係図

```
                        GameManager (Script・司令塔。全 require と全 Init はここだけ)
                              │
   ┌────────────┬─────────────┼─────────────┬──────────────┬───────────────┐
   │            │             │             │              │               │
CityGenerator  WeaponServer  DestructionManager  NPCManager  RoundClock   ThreatManager
   │            │             │             │              │               │
   │            │             │             │              │          EnemyManager
   │            │             │             │              │
   └── 注入される依存(モジュール同士は直接 require しない) ───────────────────┘

WeaponServer.Init(remotes, DestructionManager)              ← 既存のまま

DestructionManager.Init{
    addScore        = WeaponServer.AddScore,                 ← 既存
    addTime         = RoundClock.Add,                        ★新
    blastListeners  = { NPCManager.OnExplosion,
                        EnemyManager.OnExplosion },          ★新(既存 onNpcExplosion を配列化)
    effectRemote    = remotes.Effect,                        ← 既存
    hudRemote       = remotes.Hud,                           ★新
}

RoundClock.Init{
    onChange = function(remaining, delta, reason, player) …end  -- GameManagerが即時ブロードキャスト
}

ThreatManager.Init{
    getScore     = WeaponServer.GetTotalScore,   ★新(WeaponServerに追加)
    enemies      = EnemyManager,                 -- 編成の指示先
    hudRemote    = remotes.Hud,
    effectRemote = remotes.Effect,
}

EnemyManager.Init{
    addScore     = WeaponServer.AddScore,
    addTime      = RoundClock.Add,
    explode      = DestructionManager.Explode,   -- 戦車の砲撃用
    roadLines    = CityGenerator.GetRoadLines(), -- 湧き位置・走行ルート
    effectRemote = remotes.Effect,
    hudRemote    = remotes.Hud,
}
```

**新規 RemoteEvent は `Hud` の1本だけ。** `TimeDelta` / `Threat` / `Notice` を個別に生やさず、既存の `Effect` と同じ「種別文字列 + データテーブル」方式にまとめる。

- `Hud` の種別: `"time"`(タイム増減) / `"hit"`(被弾) / `"threat"`(段階昇格) / `"chain"`(連鎖倍率) / `"notice"`(設置拒否などの短文)
- 受け手は **UIController**(画面表示)。音は従来どおり `Effect` → EffectsClient。

---

## 2. 主要論点への回答(§5-1 〜 §5-6)

### §5-1 段階管理をどこに置くか

| 選択肢 | 利点 | 欠点 |
|---|---|---|
| A. GameManagerに持たせる | 新規ファイルゼロ。ラウンドループと同じ場所で完結 | GameManagerが123行→300行超に肥大。★4追加のたびに司令塔を触ることになる。Scriptなので他モジュールから参照できず、結局コールバック注入が必要 |
| **B. ThreatManager を新設(推奨)** | 責務が閉じる。★4は Config の配列に1行足すだけ。ラウンド制御は既存 `NPCManager.Start/Stop/Clear` と同じ3メソッドで揃う | ファイルが1本増える。GameManagerの `Init` が1ブロック増える |
| C. EnemyManagerに内蔵 | ファイル2本で済む | 「政策」と「機構」が混ざり、★1だけ先に作る運用がしづらい |

**推奨: B。** 根拠は §1-1 のとおり。

**既存の依存注入パターンへの乗せ方**

`NPCManager` と全く同じ形にする。GameManager は `require` → `Init(deps)` → ラウンドループ内で `Start()` / `Stop()` / `Clear()` を呼ぶだけ。新しい作法を持ち込まない。

**ラウンドループとの関係**(GameManagerのwhileループへの差し込み位置)

```
1) LOBBY:
     WeaponServer.SetRoundActive(false)
     WeaponServer.RemoveToolsFromAll()
     NPCManager.Clear()
     ThreatManager.Clear()   ★追加(段階を0に戻す)
     EnemyManager.Clear()    ★追加(NPCManager.Clear() の隣。敵モデル・攻撃タイマー全消去)
     DestructionManager.ClearAllDebris()
     CityGenerator.Clear()
     … 生成 …
     runPhase("LOBBY", Config.Round.LobbyTime)     -- 従来どおり固定長

2) BATTLE:
     WeaponServer.ResetScores()      ← ★必ず ThreatManager.Start() より先。
                                        前ラウンドのスコアが残ったまま開始すると即★3になる
     WeaponServer.SetRoundActive(true)
     WeaponServer.GiveToolsToAll()
     NPCManager.Start()
     RoundClock.Start(Config.Round.BattleTime)     ★追加
     ThreatManager.Start()                          ★追加
     runBattlePhase()                               ★runPhase を RoundClock 駆動版に差し替え

3) RESULT:
     ThreatManager.Stop()   ★追加(昇格判定と敵の攻撃を止める。モデルはLOBBYまで残して見た目の継続性を保つ)
     EnemyManager.SetAggressive(false) ★ Stop() の内部で呼ぶ
     … 従来どおり …
     runPhase("RESULT", Config.Round.ResultTime)   -- 従来どおり固定長
```

`runBattlePhase()` の中身(擬似):

```
while RoundClock.Remaining() > 0 do
    remotes.RoundState:FireAllClients("BATTLE", math.ceil(RoundClock.Remaining()))
    task.wait(1)
end
```

`RoundClock` は内部で `endsAt = os.clock() + remaining` を持ち、`Add(delta)` は `endsAt` をずらすだけにする。**現行の `for t = duration,1,-1 do … task.wait(1) end` のようなカウンタ方式にしないこと**が肝で、そうしないと「+8秒」を足した瞬間にループカウンタと実残り時間がずれる。deadline 方式なら `Remaining()` は常に真値になり、`task.wait(1)` のドリフトも自動的に吸収される。

### §5-2 敵を NPCManager に統合するか、分離するか

| 選択肢 | 評価 |
|---|---|
| A. NPCManager に統合(`npc.kind` で分岐) | Heartbeatループが1本で済むのは事実。しかしループ内の全分岐に `if not npc.isEnemy` ガードが必要になり、`startPanic` / `fleeAway` / 頭数維持(`RespawnDelay` 後の `spawnNpc`)がすべて敵に誤爆しうる。**動作確認済みの既存コードを壊すリスクが最大**。依頼書の「絶対に壊してはいけないもの」に抵触する |
| **B. EnemyManager を新設し、設計思想だけ流用(推奨)** | Humanoid不使用・全パーツAnchored・`WeldConstraint`・共有Heartbeat・`model:PivotTo(CFrame.lookAt(...))`・撃破時のラグドール(`Anchored=false` + `CollisionGroup="Debris"` + `ApplyImpulse`)という**手法をコピーする**。NPCManagerのファイルは実質無変更 |
| C. 共通基底モジュールを切り出して両者で使う | 設計としては最も美しいが、動いている NPCManager を書き換える必要があり B の利点を失う。将来「敵と市民で挙動が9割同じ」と分かってからでよい |

**推奨: B(分離)。** 根拠:

1. **リスク非対称性**。統合の利益は「Heartbeat接続1本の節約」で、実測上ほぼゼロ(接続1本 + 最大20エンティティのループ)。損失は既存機能の破壊で、こちらは致命的。
2. **ライフサイクルが根本的に違う**。市民は常時10体を維持する(倒しても逃げても必ず再スポーン)。敵は段階に応じて編成ごと湧き、昇格時に撤退し、ラウンド終了で消える。同じテーブルで管理すると `Config.NPC.Count` の頭数維持ロジックが敵にも効いてしまう。
3. **表 §5-2 の4項目のうち3項目(移動・攻撃・湧き位置)が全部違う**。共通なのは「撃破時に加点」だけで、それは `deps.addScore` の呼び出し1行。

**流用する具体的な手法(コピー元 → 用途)**

| NPCManagerの実装 | 敵での用途 |
|---|---|
| `makePart` + `WeldConstraint` で6パーツ結合 (L52-64, L131-139) | 警官・兵士の身体。色だけ Config で変える |
| 共有 `RunService.Heartbeat` で `PivotTo(CFrame.lookAt(newPos, newPos+dir))` (L261-290) | 全敵の移動。target が「ランダム点」から「最寄りプレイヤー / 道路上の次の交差点」に変わるだけ |
| `killNpc` のラグドール化 (L295-345) | 敵の撃破演出。Weldを2〜3本壊す→物理化→`ApplyImpulse`→`DespawnTime` 後 Destroy |
| `createHelpBubble` の「生成時に作って `Enabled` を切り替えるだけ」方式 (L69-113) | 敵の「!」マークや照準テル。**爆発の瞬間にInstance生成を集中させない**という既存の教訓をそのまま踏襲する |
| `Clear()` でフォルダごと Destroy (L387-397) | `EnemyManager.Clear()` |

### §5-3 `DestructionManager.Explode` の引数設計

**現状の確認(実コードを読んだ結果)**

`Explode(position, radius, attacker)` は `DestructionManager.lua:220`。呼び出し箇所は **3か所のみ**:

- `WeaponServer.lua:159` バズーカ
- `WeaponServer.lua:192` エアストライクの `dropBomb`
- `WeaponServer.lua:266` リモート爆弾の `detonateBombs`

今回増える経路は「連鎖倍率つき」「敵の砲撃(加点なし)」「絨毯爆撃(1発あたりの物理化上限を絞りたい)」の3種。位置引数を増やすと `Explode(pos, r, attacker, scale, maxReal, source, bonusPolicy)` になり保守不能。

| 選択肢 | 評価 |
|---|---|
| A. 位置引数を増やす | 却下。呼び出し側が `Explode(p, r, player, nil, nil, "Bazooka")` になる |
| B. `Explode(pos, radius, attacker, opts)` 第4引数にオプション表 | 既存3か所を無変更で通せるのが利点。しかし「必須が位置引数、任意が表」の二重構造が残り、`opts.position` を書きたくなるミスを誘う |
| **C. `Explode(ctx)` 単一テーブル(推奨)** | 呼び出しが自己文書化される。既存3か所は**どのみち今回全部触る**(バズーカ以外は仕様変更、バズーカも1行の機械的置換)ので移行コストは実質ゼロ |

**推奨: C。後方互換シムは入れない。**

根拠: 呼び出しが3か所しかないため、シムを入れる方が「新旧2つの呼び方が存在する」という恒久的な負債になる。かつ、移行漏れがあった場合は `ctx.position` が nil になって**即エラーで落ちる**(サイレント失敗ではない)ので、テスト1周で必ず発覚する。

**ctx の定義案**

```lua
DestructionManager.Explode({
    position   = Vector3,     -- 必須
    radius     = number,      -- 必須
    attacker   = Player?,     -- nil = 加点なし(敵の砲撃)
    scoreScale = number?,     -- 既定1。連鎖ボーナス倍率
    source     = string,      -- "Bazooka" / "Airstrike" / "RemoteBomb" / "EnemyTank"。演出・ログ用
    maxReal    = number?,     -- 既定 Config.Debris.MaxRealPerExplosion。絨毯爆撃だけ絞る
    bonusPolicy= string?,     -- "normal"(既定) / "deny"(全壊ボーナスを誰にも与えない)
    silent     = boolean?,    -- true なら "explosion" エフェクトを送らない(将来の連鎖演出用。今回未使用)
})
```

`deps.blastListeners` へは ctx をそのまま渡す。これで NPCManager も EnemyManager も `ctx.attacker` `ctx.scoreScale` を等しく参照できる(市民の +100点 も連鎖倍率に乗る、など)。

**NPCManager 側の変更は 3行だけ**:
`function NPCManager.OnExplosion(ctx)` に変え、冒頭で `local position, radius, attacker = ctx.position, ctx.radius, ctx.attacker` とほどく。以降の本体は無変更。

### §5-3付録 §4.2 の3つの論点への回答

依頼書 §4.2 で「必ず言及すること」と指定された3点。**実コードを読んで確認した事実から答える。**

**(1) `attacker` に nil を渡す形で実現できるか → できる。ただし現状は"たまたま"動く**

`registerDestruction` (`DestructionManager.lua:114-134`) は:

```lua
if attacker then deps.addScore(attacker, Config.Score.Block) end   -- ← nil なら加点されない ✅
…
building.destroyed += 1                                            -- ← nil でも必ず加算される
if not building.bonusGiven and building.destroyed >= 閾値 then
    building.bonusGiven = true                                     -- ← nil でも true になる
    if attacker then deps.addScore(attacker, BuildingBonus) end    -- ← nil なら加点されない ✅
    deps.effectRemote:FireAllClients("collapse", …)                -- ← nil でも粉塵は出る
end
```

つまり**「敵が壊した分は加点されず、敵がトドメを刺した建物の全壊ボーナスは誰にも入らない」という依頼書の希望動作は、現状のコードでも偶然そうなる**。ただしこれは意図して書かれた分岐ではなく副作用なので、**`bonusPolicy` として明示的に表現し直すことを推奨する**。暗黙の副作用に依存した仕様は、後日 `registerDestruction` を触った誰かが壊す。

**(2) 敵が壊した分を `destroyed` カウントに含めるか → 含める(推奨)**

含めない場合の問題: 戦車が半分削った建物は `destroyed/total` が実態より低く出る。結果、(a) リザルト画面の「破壊率 %」が見た目と食い違う、(b) その建物は**プレイヤーがどれだけ壊しても 90% に到達できない**(ブロックは物理的に消えているので、残りを全部壊しても分子が足りない)。これは「壊しても全壊ボーナスが出ない建物」という理不尽なバグに見える。

**(3) 到達した場合に全壊ボーナスを与えるべきか → 依頼書の見解に同意。与えない。ただし実装は3案ある**

| 案 | 挙動 | 評価 |
|---|---|---|
| 案1: `attacker == nil` なら `bonusGiven` を立てずに素通り | 敵が 89% まで削った建物を、プレイヤーが1ブロック壊すだけで +500点/+10秒 | **却下**。ハイエナ戦法が最適解になる |
| **案2: `bonusPolicy="deny"` で `bonusGiven=true` にし、誰にも与えず「奪われた」演出を出す(★3の最小実装として推奨)** | 戦車にトドメを刺されたら報酬は消滅。プレイヤーに「あの建物を先に落とせ」という明確な動機が生まれる | 実装は3行。ただし**プレイヤーが88%まで削った建物を戦車が仕留めた場合、努力が丸ごと消える**という理不尽が残る |
| **案3: 貢献度クレジット方式(★3実装時の最終形として推奨)** | `building.credit[player] += 1` を `registerDestruction` で記録。閾値到達時、最大貢献者の貢献率が `Config.Score.BonusMinShare`(既定0.5)以上ならその人に +500/+10秒、いなければ誰にも出さない | 案2の理不尽を解消。**かつ既存の潜在バグも直る**(現状は「最後の1ブロックを壊した人」が全壊ボーナス全額を取るため、マルチで99%削った人が横取りされる)。コストは建物ごとに最大 `#players` 要素のテーブル1つ = 実質ゼロ |

**推奨: 案3。ただし ★1 の実装段階では一切不要**(★1の警察は建物を壊さないため)。★3 に着手する時点で案3を入れる。それまでは案2相当の `bonusPolicy` フックだけ用意しておく。

### §5-4 タイムの管理主体

**まず既存コードの確認結果(依頼書「特に重要」への回答)**

`UIController.client.lua:328-348` を読んだ結果:

```lua
remotes:WaitForChild("RoundState").OnClientEvent:Connect(function(state, timeLeft)
    if state == "BATTLE" then
        timerLabel.Text = ("%d:%02d"):format(timeLeft // 60, timeLeft % 60)
```

**クライアントは自前でカウントしていない。サーバーが毎秒送ってくる `timeLeft` をそのまま表示しているだけ。** `GameManager.runPhase` が `for t = duration,1,-1 do FireAllClients(state,t); task.wait(1) end` で送っている。

→ **これは今回にとって最高の前提。** サーバー側の残り時間を可変にするだけで、クライアント側のタイマー計算ロジックは一切変更不要。UIController の変更は「演出の追加」だけで済む。

**設計**

- 残り時間の**唯一の持ち主は RoundClock**。`endsAt` 方式(前述)。
- 増減の入口は `RoundClock.Add(delta, reason, player)` の1本のみ。呼ぶのは:
  - `DestructionManager`(建物90%破壊 → `+Config.Score.BuildingBonusTime`)
  - `EnemyManager`(敵撃破 → `+TimeReward` / 被弾 → `-TimePenalty`)
- clamp は Add の内部で完結させる(呼び出し側にルールを知らせない):
  1. `delta > 0` → `newRemaining = min(remaining + delta, Config.Round.BattleTimeMax)`
  2. `delta < 0` → `newRemaining = max(remaining + delta, min(remaining, Config.Round.BattleTimeFloor))`
     ※ フロアは「これ以下には**下げない**」であって「これ未満なら**引き上げる**」ではない。`min(remaining, Floor)` を挟むのはそのため
  3. `delta < 0` → さらに `MaxLossPerMinute` の残枠でクリップ(§5-6)
  4. 実際に適用された量 `applied` を戻り値で返す(演出に「実際に減った秒数」を出すため。キャップで0になったら「防いだ」演出にできる)
- 変化があったら `deps.onChange(remaining, applied, reason, player)` を発火 → GameManager が **即座に** `RoundState:FireAllClients("BATTLE", ceil(remaining))` を1回追加送信 + `Hud:FireAllClients("time", {...})`。毎秒送信を待たないことで、数字が即座に跳ねる。

**クライアント同期のコスト**: `RoundState` の追加送信は「タイムが動いた瞬間」だけ。最悪ケース(★3で被弾しまくる)でも毎秒2〜3回程度。既存の毎秒1回に対して無視できる。

### §5-5 演出の設計

#### タイム増加時

| 要素 | 実装場所 | 内容 |
|---|---|---|
| 数字が緑に光る + 拡大 | UIController | `timerLabel` に `UIScale` を追加(スコアの `scoreScale` と全く同じ手法。L97-99, L353-356 が既に前例)。`TextColor3` を緑へ即座に変え、`TweenService` で 0.4秒かけて白に戻す |
| 「+8秒!」フローティング | UIController | `timerLabel` の直下に `TextLabel` を生成 → `Position` を上へ、`TextTransparency` を 1 へ 0.8秒 Tween → Destroy。複数同時に出る場合は縦に少しずらす |
| 専用効果音 | EffectsClient | `Effect` の `"timeGain"`。`playSound(Config.Sounds.TimeGain, camera位置, ...)` |

#### タイム減少時

| 要素 | 実装場所 | 内容 |
|---|---|---|
| 数字が赤くフラッシュ | UIController | 上と同じ経路、色が赤。`UIScale` は 1.25 → 1 ではなく 0.85 → 1(縮んで戻る=殴られた感) |
| 画面端の赤いビネット | UIController | HUD直下に全画面 `Frame`(`BackgroundColor3` 赤、`BackgroundTransparency = 1`、`ZIndex` 最背面、`Active=false` で入力を通す)を常設。被弾時に `0.75` へ即座に変え、0.35秒で `1` へ Tween。**注**: 真のビネット(周辺だけ暗い)は `UIGradient` の線形ランプでは作れない。まずは全画面フラッシュで実装し、見栄えが不足するなら放射状テクスチャの `ImageLabel` に差し替える(要アセット作成、今回スコープ外) |
| 被弾音 | EffectsClient | `Effect` の `"enemyShotHit"` |

#### 段階昇格時(★1→★2 など)

| 要素 | 実装場所 | 内容 |
|---|---|---|
| 中央テロップ | UIController | 既存の `showTelop(text, duration)`(L311-324)を**そのまま流用**。`Hud "threat"` を受けて `showTelop(stage.Telop, 3)` を呼ぶだけ |
| サイレン等の専用音 | EffectsClient | `Effect "threatUp"` → `Config.Sounds` の段階別サウンド |
| ★インジケータ(常設) | UIController | タイマーの下に「★☆☆」の小さな `TextLabel` を常設。**これが無いと、テロップを見逃したプレイヤーは自分が今どの段階か永久に分からない**。昇格時に赤くパルスさせる |

#### 連鎖ボーナス

`Hud "chain"` → 中央に「×3 CHAIN!」を 1.2秒。既存 `showTelop` と競合するので、**チェーン表示は専用ラベル(位置を `0.45` にずらす)を用意する**(テロップと同じラベルを使うと昇格テロップを潰す)。

#### 既存クライアントへの影響

`EffectsClient` のディスパッチ(L217-233)は `if / elseif` の連鎖で、**未知の種別は黙って無視される**。したがって種別の追加は完全に後方互換。UIController も `Hud` を新規購読するだけで既存ハンドラに触らない。

### §5-6 デススパイラルの回避

**まず §4.4 のたたき台の数値をそのまま採ると破綻する。数値で示す:**

無敵時間 1.5秒 / 被弾 -2秒 の場合、理論最大ドレインは **2秒 ÷ 1.5秒 = 1.33 秒/秒**。つまり時計が実時間より速く減る。★1(警官4人)でも、`AttackInterval` を 2.2秒とすると 4人で 1.8発/秒 なので無敵時間は常に飽和し、この上限に張り付く。60秒間逃げ回っただけで **-80秒**。★1の全滅報酬(後述 +28秒)ではまったく足りず、**赤字**。

したがって以下を提案する。

| ガードレール | 値(Config) | 効果 |
|---|---|---|
| ① 無敵時間の延長 | `Damage.Invincible = 2.0`(たたき台1.5から) | 理論ドレインを 1.0 秒/秒 へ |
| ② **被弾ペナルティを敵種別ごとに持つ** | 警官 -1 / パトカー体当たり -1 / 兵士 -2 / ヘリ -2 / 戦車砲 -3 | 「★1は痛くない、★3は痛い」を表現。単一の -2 では★1が理不尽で★3が生ぬるい |
| ③ **直近60秒あたりの最大損失キャップ(本命)** | `Damage.MaxLossPerMinute = 20` | **これが実質的なガードレール**。①②だけでは足りない。60秒スライディングウィンドウで累計損失を記録し、枠が尽きたら以降の被弾は 0 秒(演出だけ出す)。最悪ドレインが 0.33 秒/秒 に固定される |
| ④ 下限フロア | `BattleTimeFloor = 15`(たたき台どおり) | 「あと少しで終わる」状態からの追い打ちを止める |
| ⑤ **攻撃の予告(テレグラフ)** | `Damage.Telegraph = 0.5` | 発砲の0.5秒前に敵→プレイヤーの赤いビームを出す。**避けられる被弾は理不尽ではない**。下手なプレイヤーほど、これがあるだけで被弾率が下がる |
| ⑥ **遮蔽判定** | `Damage.RequireLineOfSight = true` | サーバーで敵→プレイヤーへ Raycast し、`Map` に遮られていれば miss。建物の陰に隠れれば安全。**しかも壊すほど遮蔽が減る**という、このゲームならではの緊張が生まれる |
| ⑦ **湧き位置の最低距離** | `Spawn.MinDistanceFromPlayer = 100` | 真横に湧いて即撃たれる事故を防ぐ |
| ⑧ 段階は下がらない・編成は撤退する | `DespawnOnDowngrade = false` / 昇格時に旧編成はフェード撤退 | ★1と★2の敵が累積して手に負えなくなるのを防ぐ。同時存在数の上限も自動的に決まる(パーツ予算の観点でも有利) |

**③の実装メモ**: リングバッファ不要。`lossLog = {}` に `{at, amount}` を積み、`Add` のたびに 60秒より古いエントリを先頭から捨てて合計を出す。1ラウンドで最大数百エントリなので線形走査で十分。

**追加の提案(依頼書の「他に必要なガードレール」への回答)**

- **⑨ 復帰ボーナス**: 残り時間が `BattleTimeFloor + 10` 秒を下回っている間、敵撃破の `TimeReward` を1.5倍にする(`Damage.ComebackMultiplier = 1.5`)。追い詰められたプレイヤーが1体倒せば立て直せる。レースゲームのラバーバンドと同じ発想で、リテンションに効く。
- **⑩ 死亡(キャラクターの Humanoid.Died)中は被弾しない**。`player.Character` が無い/瀕死の間は攻撃対象から外す。現状プレイヤーはHPを持たないが、落下死などで Character が消える瞬間はある。

---

## 3. Config 構造案

キー名・構造は提案であり、実装前に変更可。**今回追加する調整値はすべてここに出す。コードにベタ書きしない。**

### 3-1. `Config.Round`(既存を拡張)

```lua
Config.Round = {
	LobbyTime = 3,
	BattleTime = 120,      -- 基礎ラウンド時間(§6-3 の判断。90 にする場合はここだけ変える)
	BattleTimeMax = 300,   -- ハードキャップ。これ以上は増えない
	BattleTimeFloor = 15,  -- 下限フロア。残りがこれ以下のときは減少しない
	ResultTime = 10,
}
```

### 3-2. `Config.Score`(既存にタイム報酬を追加)

```lua
Config.Score = {
	Block = 10,
	NPC = 100,
	BuildingBonus = 500,
	BuildingBonusTime = 10,  -- ★追加: 全壊時のタイム報酬(秒)
	BonusThreshold = 0.9,
	BonusMinShare = 0.5,     -- ★追加: 全壊ボーナスを受け取るのに必要な最低貢献率(§5-3付録 案3)
}
```

### 3-3. `Config.Threat`(新設。この節がまるごと今回の追加分)

```lua
Config.Threat = {
	Enabled = true,          -- false にすると敵システム全体が無効(切り分け用)
	ScoreSource = "sum",     -- "sum"=全プレイヤーのスコア合計 / "top"=最高スコア
	CheckInterval = 1,       -- 段階判定を行う間隔(秒)
	DebugLog = true,         -- 各段階の到達時刻をサーバーログに出す(閾値チューニング用)

	-- ▼ 被弾・ダメージ(全段階共通)
	Damage = {
		Invincible = 2.0,          -- 被弾後の無敵秒数
		MaxLossPerMinute = 20,     -- 直近60秒で失える時間の上限(デススパイラル防止の本命)
		Telegraph = 0.5,           -- 攻撃予告のビームが出てから着弾するまでの秒数
		RequireLineOfSight = true, -- 建物に遮られていれば命中しない
		ComebackMultiplier = 1.5,  -- 残り時間が少ないときの撃破報酬の倍率
		ComebackThreshold = 25,    -- 残りがこの秒数を下回るとComebackMultiplierが効く
	},

	-- ▼ 湧き
	Spawn = {
		MinDistanceFromPlayer = 100, -- この距離以内には湧かせない
		Interval = 0.4,              -- 1体ずつ間を空けて湧かせる(生成負荷の平準化)
		-- 街の外周・道路中心線は CityGenerator.GetRoadLines() から取得する(値の二重管理を避ける)
	},

	-- ▼ 敵の種類(データ駆動。★4の怪獣もここに1エントリ足すだけで済む形にする)
	EnemyTypes = {
		PoliceOfficer = {
			DisplayName = "警官",
			Body = "human",            -- 見た目の作り分け: "human" / "car" / "heli" / "tank"
			BodyColors = { Shirt = Color3.fromRGB(30, 50, 120), Pants = Color3.fromRGB(25, 30, 45) },
			Hits = 1,                  -- 何回の爆発に耐えるか
			HitCooldown = 0.25,        -- 連続被弾の間隔(絨毯爆撃で一瞬で溶けるのを防ぐ)
			Movement = "direct",       -- "direct"=直進 / "road"=道路網を走行 / "air"=空中
			MoveSpeed = 11,
			StopDistance = 45,         -- この距離まで近づいたら停止して撃つ
			AttackType = "shoot",      -- "shoot" / "ram" / "shell" / "none"
			AttackRange = 60,
			AttackInterval = 2.2,
			TimePenalty = 1,           -- 命中時にプレイヤーが失う秒数
			ScoreReward = 300,         -- 撃破時のスコア
			TimeReward = 3,            -- 撃破時のタイム(秒)
			Parts = 6,                 -- パーツ予算の見積り用(コードは参照しない。ドキュメント目的)
		},
		PoliceCar = {
			DisplayName = "パトカー",
			Body = "car",
			BodyColors = { Main = Color3.fromRGB(240,240,245), Sub = Color3.fromRGB(20,40,110) },
			Hits = 2, HitCooldown = 0.25,
			Movement = "road", MoveSpeed = 26, StopDistance = 15, -- ★変更: 6→15(接触ではなく「到着」の判定距離に意味が変わった)
			AttackType = "none", AttackRange = 0, AttackInterval = 0, -- ★変更: ram→none。パトカーはプレイヤーを攻撃しない
			TimePenalty = 0,           -- ★変更: 攻撃しないので被弾ペナルティも0
			ScoreReward = 500, TimeReward = 8, Parts = 6,
			-- ▼ 警官の輸送(★新設。パトカーの役割変更の核。ユーザー決定 2026-07-29)
			DeployOnArrive = true,     -- 目的地(プレイヤー付近の道路)に到着すると警官を降ろす
			DeployType = "PoliceOfficer",
			DeployCount = 2,           -- 1回の到着で降ろす警官の人数
			DeployRadius = 6,          -- 車の周囲どのくらいの範囲に降ろすか
			DeployInterval = 15,       -- 初回降車後、車が生きていれば次の降車までの秒数(放置への圧力)
			MaxDeployTrips = 2,        -- 1台が生涯で行う降車回数の上限(nil=無制限。無制限にすると放置戦略でパーツ予算が破綻しうる)
		},
		Helicopter = {
			DisplayName = "警察ヘリ",
			Body = "heli", Altitude = 60, OrbitRadius = 45,
			Hits = 2, HitCooldown = 0.25,
			Movement = "air", MoveSpeed = 34, StopDistance = 45,
			AttackType = "shoot", AttackRange = 90, AttackInterval = 1.8,
			TimePenalty = 2, ScoreReward = 1200, TimeReward = 12, Parts = 6,
		},
		Soldier = {
			DisplayName = "兵士",
			Body = "human",
			BodyColors = { Shirt = Color3.fromRGB(72, 82, 55), Pants = Color3.fromRGB(58, 64, 45) },
			Hits = 1, HitCooldown = 0.25,
			Movement = "direct", MoveSpeed = 13, StopDistance = 50,
			AttackType = "shoot", AttackRange = 70, AttackInterval = 1.6,
			TimePenalty = 2, ScoreReward = 400, TimeReward = 4, Parts = 6,
		},
		Tank = {
			DisplayName = "戦車",
			Body = "tank",
			BodyColors = { Main = Color3.fromRGB(78, 86, 62) },
			Hits = 3, HitCooldown = 0.4,
			Movement = "road", MoveSpeed = 14, StopDistance = 60,
			AttackType = "shell", AttackRange = 80, AttackInterval = 3.0,
			TimePenalty = 3, ScoreReward = 2500, TimeReward = 15, Parts = 6,
			-- ▼ 建物破壊(★3固有)
			DestroysBuildings = true,
			ShellRadius = 10,          -- 建物への砲撃の爆発半径
			ShellInterval = 4.0,       -- 建物を撃つ間隔(対プレイヤーとは別枠)
			BuildingScanRadius = 90,   -- この範囲の建物を狙う
		},
		-- ★4 怪獣は今回未実装。ここに1エントリ足し、Stages に段階を1つ足すだけで動く設計にする
	},

	-- ▼ 段階(配列。順序が段階の順序。★4は末尾に1エントリ足すだけ)
	Stages = {
		{
			Name = "★1 警察",
			Threshold = 1000,
			Telop = "警察が出動した!",
			Sound = "Siren",
			RespawnDelay = 20,   -- 編成が全滅してから次の部隊が来るまでの秒数
			Squad = {
				{ type = "PoliceCar", count = 2 },
				{ type = "PoliceOfficer", count = 2 }, -- ★変更: 4→2。残りはパトカーが運ぶ(§3-3末尾の解説を参照)
			},
		},
		{
			Name = "★2 増援",
			Threshold = 4000,
			Telop = "警察が増援を要請した!",
			Sound = "Siren",
			RespawnDelay = 20,
			Squad = {
				{ type = "PoliceCar", count = 4 },
				{ type = "PoliceOfficer", count = 8 },
				{ type = "Helicopter", count = 1 },
			},
		},
		{
			Name = "★3 軍隊",
			Threshold = 10000,
			Telop = "軍が展開した!",
			Sound = "Alarm",
			RespawnDelay = 25,
			Squad = {
				{ type = "Tank", count = 2 },
				{ type = "Soldier", count = 8 },
			},
		},
		-- ★4(怪獣・20000点)は構造だけ空けてある。実装時はここに1エントリ
	},
}
```

**★4 を差し込めることの担保**: ThreatManager は `Config.Threat.Stages` を **index 昇順に走査するだけ**で、`if stage == 1 then` のような分岐を一切持たない。EnemyManager も `Config.Threat.EnemyTypes[name]` を引くだけで、敵種別ごとの `if` は「見た目を組み立てる `Body` の分岐」1か所に閉じる。★4 は `Body = "kaiju"` の分岐を1つ足せば済む(依頼書が言う「Humanoid入りモデル」を使う場合でも、`Body` 分岐の中で別方式のモデル生成に切り替えられる)。

**パトカーの警官輸送と編成(squad)の扱い(★1改訂に伴う追加仕様。ユーザー決定 2026-07-29)**

`PoliceCar` は `DeployOnArrive` によって道中で警官を降ろす。降ろされた警官は、**その車が最初に属していた編成(squadId)にそのまま加算される**。実装上は「編成」を固定リストではなく可変集合として持つ ── `EnemyManager` は各個体に生成時点の `squadId` をタグ付けし、`ThreatManager` は「現在の squadId を持つ生存個体数」を毎ティック数えるだけでよい。固定の頭数リストを保持する必要はない。

この設計から以下が自動的に導かれる:

- **編成の全滅判定は「その squadId の生存者が0になったとき」。** パトカーが `MaxDeployTrips` を使い切っても、車自体が生きている限りその squadId の生存者は0にならない。**つまりパトカーを倒さない限り、次の部隊(RespawnDelay 後の次wave)は来ない。** これが「パトカーを先に潰す優先順位」を強制する仕組みの正体である。
- **すでに降車した警官は、車が後で倒されても消えない。** `MaxDeployTrips` に達した車、あるいは倒された車は、それ以降その squadId に新しい個体を追加しなくなるだけ。既出の警官は独立した個体として通常どおり扱われる。
- **放置した場合の頭数増加に上限があること(`MaxDeployTrips`)は意図的。** 無制限にすると、1ラウンドを通してパトカーを一切攻撃しない戦略で警官が際限なく湧き続け、パーツ予算・難易度の両面で破綻しうる。上限に達した車は「もう警官を運ばないが、倒せば+8秒/+500点は入る」置物になる ── これにより「もう脅威ではないが、倒す理由は残っている」という状態を作り、放置一辺倒を牽制する。
- **実装上の注意**: 個体生成は `spawnEnemy(type, position, squadId)` のような単一関数に集約し、警官の直接スポーンも車からの降車もこの関数だけを通すこと。squadId の付け忘れが構造的に起きないようにする(§7-1 ★9 も参照)。

**★2への波及に関する注記**: `PoliceCar` の輸送挙動は `Config.Threat.EnemyTypes` の共有定義のため、★2(パトカー4台)にも自動的に適用される。★2の編成・報酬の再設計は Step 5(§6)で ★2 に着手する時点で改めて行う。現時点の Stages.★2 の値は**未反映のたたき台のまま**であることに注意。

### 3-4. `Config.Weapons`(改修)

```lua
	Bazooka = {
		-- ★変更なし。Cooldown = 0 を維持する
	},

	Airstrike = {
		DisplayName = "エアストライク",
		SlotKey = 2,
		Radius = 12,          -- 10 → 12
		Cooldown = 20,        -- 3 → 20
		Delay = 3,            -- 予告マーカーから第1弾までの秒数(据え置き)
		DropHeight = 80,      -- 据え置き
		FallTime = 1.1,       -- 据え置き
		-- ▼ 絨毯爆撃
		PlaneCount = 3,       -- 編隊の機数
		BombsPerPlane = 6,    -- 1機あたりの投下数(合計18発)
		BombInterval = 0.15,  -- 爆発の時間差(秒)
		LineLength = 120,     -- 爆撃線の長さ
		LineWidth = 20,       -- 編隊の横幅
		Sequential = true,    -- true=18発を1発ずつ順に(負荷分散+掃射感) / false=3機横並びで同時
		MaxRealPerBomb = 12,  -- 1発あたりの物理化上限(既定30より絞る。ctx.maxReal で渡す)
		PlaneSpeed = 220,     -- 戦闘機の飛行速度(見た目のみ)
		PlaneParts = 5,       -- 1機あたりのパーツ数(自作Part。Toolboxは使わない)
		-- ※ BombCount / Scatter は絨毯爆撃で意味を失うため削除する
	},

	RemoteBomb = {
		DisplayName = "リモート爆弾",
		SlotKey = 3,
		Radius = 15,
		Cooldown = 1,
		MaxBombs = 10,
		MaxPlaceDistance = 50,          -- ★追加: HumanoidRootPart からこの距離を超える設置は拒否
		-- ★追加: 同時起爆数 → スコア倍率(min 以上で mult。昇順に並べる)
		ChainBonus = {
			{ min = 1, mult = 1 },
			{ min = 3, mult = 2 },
			{ min = 5, mult = 3 },
			{ min = 8, mult = 5 },
		},
		ChainAffectsBuildingBonus = false, -- 全壊ボーナス(500点)には倍率をかけない
	},
```

### 3-5. `Config.Sounds` / `Config.RemoteNames`(追加)

```lua
Config.Sounds = {
	… 既存6件 …
	Siren    = "",  -- ★1/★2の昇格音(サイレン)。空文字なら鳴らないだけで落ちない
	Alarm    = "",  -- ★3の昇格音(空襲警報)
	TimeGain = "rbxasset://sounds/electronicpingshort.wav", -- タイム増加
	TimeLoss = "",  -- 被弾音
	EnemyShot= "",  -- 敵の発砲音
	Jet      = "",  -- 戦闘機の飛行音
}
```

**注**: `EffectsClient.playSound` は `id == "" or nil` で早期 return し(L32-34)、さらに全体が `pcall` で包まれている(L36)。**無効なIDでもエラーにならず、鳴らないだけ**。したがって音源が決まるまで空文字で置いておける。

```lua
Config.RemoteNames = {
	"RoundState", "Effect", "Result", "Score", "Cooldown", "BombCount",
	"Hud",   -- ★追加(サーバー→クライアント。UIController が購読)
	"Fire", "Action",
}
```

`GameManager` が `Config.RemoteNames` を走査して自動生成する(L32-37)ので、**配列に1行足すだけでリモートが増える**。追加コード不要。

---

## 4. データフロー

### 4-1. 敵が撃つ → タイムが減る → 画面が赤く光る

```
[サーバー] EnemyManager の共有Heartbeat
  └ enemy.nextAttack <= now かつ 対象プレイヤーが AttackRange 内
      ↓
  ① Effect:FireAllClients("enemyAim", { from=敵の位置, to=標的の位置, duration=Telegraph })
      → [クライアント] EffectsClient: 赤い予告ビーム(Neon の細長い Part を 0.5秒)
      ↓ task.delay(Config.Threat.Damage.Telegraph)
  ② サーバーで命中判定
      ・player.Character.HumanoidRootPart が存在するか
      ・RequireLineOfSight なら workspace:Raycast(敵→プレイヤー) が Map に遮られていないか
      → 外れたら Effect "enemyShotMiss" のみ送って終了(ここで終わる経路が「隠れた」報酬)
      ↓ 命中
  ③ EnemyManager が damagePlayer(player, enemyType.TimePenalty)
      ・playerState[player].invincibleUntil > now なら return(無敵中)
      ・invincibleUntil = now + Config.Threat.Damage.Invincible
      ↓
  ④ RoundClock.Add(-penalty, "hit", player)
      ・MaxLossPerMinute の残枠でクリップ → applied を決定(枠切れなら applied = 0)
      ・フロア: max(remaining - applied, min(remaining, BattleTimeFloor))
      ・endsAt を更新
      ↓ 変化があれば
  ⑤ RoundClock の onChange → GameManager
      ・RoundState:FireAllClients("BATTLE", ceil(remaining))  ← 数字を即座に更新(毎秒送信を待たない)
      ・Hud:FireAllClients("time", { delta = -applied, reason = "hit" })
      ・Hud:FireClient(被弾者, "hit", {})                      ← 赤フラッシュは撃たれた本人だけ
      ・Effect:FireAllClients("enemyShotHit", { position = 標的の位置 })
      ↓
[クライアント]
  ⑥ UIController "time":  timerLabel を赤くフラッシュ + UIScale 0.85→1 + 「-1秒」フローティング
     UIController "hit":   全画面の赤フラッシュ Frame を Transparency 0.75 → 1 へ 0.35秒 Tween
     EffectsClient "enemyShotHit": 被弾音 + 軽いカメラシェイク(既存 addShake を流用)
```

**applied = 0(キャップで防がれた)の場合**: `Hud "time"` は送らず、代わりに `Hud "notice"` で「防御された」相当の控えめな表示にする。減っていないのに「-1秒」と出すのは嘘になる。

### 4-2. 戦車が建物を壊す → スコアは入らない → 全壊ボーナスも出さない

```
[サーバー] EnemyManager の Heartbeat(戦車の建物砲撃タイマー ShellInterval)
  ① BuildingScanRadius 内の "Destructible" タグ付きパーツを1つ選ぶ(GetPartBoundsInRadius)
      ↓
  ② 砲塔をその方向へ向ける(PivotTo)+ Effect:FireAllClients("tankFire", { from, to })
      ↓
  ③ deps.explode({
         position   = 標的の位置,
         radius     = Tank.ShellRadius,   -- 10
         attacker   = nil,                -- ★これで加点経路が全部切れる
         scoreScale = 0,
         source     = "EnemyTank",
         bonusPolicy= "deny",             -- ★全壊ボーナスを誰にも与えない
     })
      ↓
[DestructionManager.Explode]
  ④ 通常どおり "explosion" エフェクトを送り、半径内の Destructible を破壊
      ↓ registerDestruction(part, ctx)
  ⑤ ctx.attacker == nil → deps.addScore は呼ばれない  ← スコアが入らない ✅
  ⑥ building.destroyed += 1                          ← 破壊率には数える(§5-3付録(2))
  ⑦ destroyed/total >= 0.9 に到達した場合:
        building.bonusGiven = true                    ← 二重発火を防ぐため必ず立てる
        ctx.bonusPolicy == "deny" なら:
           ・誰にも加点しない ✅
           ・RoundClock.Add(+BuildingBonusTime) も呼ばない ✅
           ・Effect "collapse" に { stolen = true } を付けて送る
              → EffectsClient: 粉塵の色を灰色に(通常は砂色)
              → Hud "notice": 「軍隊に破壊された」
        ★3実装時の最終形(案3): building.credit の最大貢献者が BonusMinShare 以上なら
           その人に +500点 / +10秒。いなければ上記の "deny" と同じ扱い
      ↓
  ⑧ deps.blastListeners を走査して ctx をそのまま渡す
        NPCManager.OnExplosion(ctx)  → 市民が巻き込まれる。ctx.attacker=nil なので加点なし
        EnemyManager.OnExplosion(ctx)→ 戦車の砲撃で他の敵も巻き込まれる(フレンドリーファイア)
           ※ 敵の撃破報酬も ctx.attacker=nil なら誰にも入らない。自滅では稼げない ✅
```

### 4-3. 爆弾5個同時起爆 → ×3倍率 → スコア加算

```
[クライアント] WeaponClient: F キー / 起爆ボタン
  → Action:FireServer("Detonate")            ← 既存のまま。変更なし
      ↓
[サーバー] WeaponServer.detonateBombs(player, data)
  ① n = #data.bombs  = 5
  ② mult = chainMultiplier(n)
       Config.Weapons.RemoteBomb.ChainBonus を走査し、min <= 5 を満たす最大エントリ
       = { min = 5, mult = 3 } → mult = 3
       ※ if n>=8 then … elseif n>=5 then … のような決め打ちは書かない(配列走査)
  ③ startCooldown(player, data, "RemoteBomb", wc.Cooldown)   ← 既存のまま
  ④ Hud:FireClient(player, "chain", { count = 5, mult = 3 })
       → UIController: 中央に「×3 CHAIN!」を1.2秒(テロップとは別ラベル)
  ⑤ 各爆弾について:
       Destruction.Explode({
           position   = bomb.Position,
           radius     = wc.Radius,      -- 15
           attacker   = player,
           scoreScale = 3,              -- ★連鎖倍率
           source     = "RemoteBomb",
       })
      ↓
[DestructionManager] registerDestruction(part, ctx)
  ⑥ deps.addScore(ctx.attacker, Config.Score.Block * ctx.scoreScale)   -- 10 × 3 = 30点/ブロック
  ⑦ 全壊ボーナス到達時は ChainAffectsBuildingBonus = false なので素の 500点
       (根拠: 全壊ボーナスは「1棟を落とし切った」ことへの実績報酬であって、
        1回の起爆への報酬ではない。倍率を乗せると 8連鎖で 2,500点 になり、
        §4.3 の閾値設計が一撃で壊れる)
  ⑧ blastListeners → NPCManager が市民を撃破。こちらは倍率を乗せる
       (100点 × 3 = 300点。「仕込んで一気に」という体験への報酬として一貫させる)
      ↓
  ⑨ WeaponServer.AddScore → Score:FireClient(player, total, delta)   ← 既存のまま
      → UIController のスコアポップ演出(既存 L351-357)がそのまま効く
```

**距離制限の経路**(参考):

```
[サーバー] WeaponServer.onFire(player, "RemoteBomb", targetPos)
  ・既存の root(HumanoidRootPart)取得と 1000stud チェックはそのまま(L288-296)
  ・その後: if (targetPos - root.Position).Magnitude > wc.MaxPlaceDistance then
                Hud:FireClient(player, "notice", { text = "近づいて設置してください" })
                return
            end
  ※ placeBomb は root を受け取っていないので、判定は onFire 側に置く(引数追加が不要)
```

### 4-4. パトカー到着 → 警官が降りる → 編成に加算される(★1改訂に伴う追加)

```
[サーバー] EnemyManager の共有Heartbeat(PoliceCar 個体)
  ・Movement="road" で目的地(プレイヤーに最も近い道路上の点)へ走行
      ↓ 到着(StopDistance=15 以内)かつ DeployOnArrive
  ① tripsUsed == 0 、または(前回の降車から DeployInterval 秒経過 かつ tripsUsed < MaxDeployTrips)
      ↓
  ② DeployCount(2)体の PoliceOfficer を車の周囲 DeployRadius(6) 内に生成
       ・各個体に car.squadId をそのままコピー(§3-3末尾を参照)
       ・Effect:FireAllClients("enemyDeploy", { position = 車の位置 })
           → EffectsClient: ドアが開く軽い演出(車体を一瞬明るくする程度でも可)
      ↓
  ③ tripsUsed += 1。tripsUsed >= MaxDeployTrips なら以降このループを回さない(車は待機のみ)
      ↓
[車が破壊された場合(いつでも起こりうる)]
  ・破壊時点で deploy ループから抜ける(以降そのcarから警官は増えない)
  ・すでに降ろした警官・他の車には影響しない
  ・squadId の生存者カウントからこの車が1体減る(§3-3 の全滅判定に反映される)
```

---

## 5. タイム収支のシミュレーション

### 5-1. 前提(ユーザー決定を反映・2026-07-29)

§4.4 に無かった警官・兵士・ヘリの撃破報酬は、ユーザー決定により以下の値で確定した。あわせてパトカーの役割変更(§3-3「パトカーの警官輸送」参照)により、パトカーは攻撃しない(`AttackType = "none"`)ため被弾ペナルティは 0 に変わっている。

| 敵 | 撃破報酬 | 被弾ペナルティ | 備考 |
|---|---|---|---|
| 警官 | +3秒 | -1秒 | |
| パトカー | +8秒(依頼書どおり) | **0秒(★変更)** | 攻撃しない輸送車。体当たりダメージも廃止 |
| 警察ヘリ | +12秒 | -2秒 | |
| 兵士 | +4秒 | -2秒 | |
| 戦車 | +15秒(依頼書どおり) | -3秒 | |

### 5-2. 編成1波あたりの収支

★1 はパトカーの役割変更(§3-3)により、**報酬が固定値ではなく戦略で変わる**。「パトカーを先に潰すほど速く安全に済むが報酬は小さい、放置するほど報酬は増えるが被弾機会も増える」という依頼書の狙いどおりのトレードオフになっているか、以下の3シナリオで確認する。

**★1 の内訳(Squad: パトカー2 + 警官2。パトカー1台あたり最大2往復・1往復2人)**

| 戦略 | 内訳 | 報酬 | 想定制圧時間 |
|---|---|---|---|
| 速攻(パトカー優先撃破) | 車2(16s) + 初期警官2(6s)。降車前に両車を撃破 | **+22秒** | 約20秒 |
| 標準(平均1往復で撃破) | 車2(16s) + 初期警官2(6s) + 追加警官4(12s) | **+34秒** | 約40秒 |
| 放置(2往復フルに許す) | 車2(16s) + 初期警官2(6s) + 追加警官8(24s) | **+46秒** | 約65秒 |

以降の §5-4 以降は「標準」(+34秒 / 約40秒)を基準値として使う。

| 段階 | 編成 | 1波の総報酬(基準) | 1波の想定制圧時間 | 報酬レート |
|---|---|---|---|---|
| ★1 | パトカー2 + 警官2(+パトカー輸送分) | **+34秒(標準)** | 約40秒 | +0.85 秒/秒 |
| ★2 | パトカー4 + 警官8 + ヘリ1 | 4×8 + 8×3 + 1×12 = **+68秒** | 約55秒 | +1.24 秒/秒 |
| ★3 | 戦車2 + 兵士8 | 2×15 + 8×4 = **+62秒** | 約60秒 | +1.03 秒/秒 |

**★2への波及に関する注記**: `PoliceCar` の輸送挙動は共有定義のため★2(パトカー4台)にも自動的に適用されるが、上表の★2の値は**未反映のたたき台のまま**(§3-3参照)。Step 5 で★2に着手する時点で改めて試算する。

### 5-3. 損失側(ガードレール適用後)

`MaxLossPerMinute = 20` により、**どの段階でも損失は 0.33 秒/秒 が上限**。これはプレイヤーの腕に関係なく保証される天井である。

| プレイ | ★1(60秒間) | ★2(60秒間) | ★3(60秒間) |
|---|---|---|---|
| 上手い(被弾2回) | -2秒 | -4秒 | -6秒 |
| 普通(被弾6回) | -6秒 | -12秒 | -18秒 |
| 下手(被弾しまくり) | **-20秒(キャップ)** | **-20秒(キャップ)** | **-20秒(キャップ)** |

### 5-4. 純収支(60秒あたり)

★1 は §5-2 の「標準」(+34秒)を基準に計算する。

| 段階 | 敵を全部倒す | 半分倒す | 敵を完全に無視 |
|---|---|---|---|
| ★1 | +34 − 6 = **+28秒** | +17 − 10 = **+7秒** | 0 − 20 = **-20秒** |
| ★2 | +68 − 12 = **+56秒** | +34 − 16 = **+18秒** | 0 − 20 = **-20秒** |
| ★3 | +62 − 18 = **+44秒** | +31 − 20 = **+11秒** | 0 − 20 = **-20秒** |

**結論: 全段階で黒字。** 「半分しか倒せない」下手なプレイヤーでも黒字を維持している(★1で +7秒。旧編成の試算(+4秒)よりむしろ余裕が増えた)。

**★1の「速攻」戦略(パトカー優先撃破・+22秒)でも黒字確認**: +22 − 6(被弾標準) = **+16秒**。報酬が最小になる戦略を選んでも赤字化しない。パトカー優先という判断そのものにペナルティは無く、「速く安全に少なく稼ぐ」か「リスクを取って多く稼ぐ」かの純粋な選択になっている。

### 5-5. 建物破壊による上乗せ

敵とは無関係に、**全壊1棟につき +10秒**。グリッド街の建物は最大128棟。中程度のプレイヤーが 20秒 に1棟落とすとすると **+30秒/分**。これが★1で「半分しか倒せない」プレイヤーの安全マージンになる:

- ★1・半分制圧・建物1棟/20秒 → +4 + 30 = **+34秒/分**

### 5-6. 「敵が来ないよう、あまり壊さない」が最適解にならないことの確認

依頼書が最も警戒している破綻パターン。数字で否定できる:

- **壊さない戦略**: 敵は出ない(損失0)が、建物ボーナスも入らない(+0)。ラウンドは基礎120秒で終わり、スコアも伸びない。純収支 **±0秒**。
- **壊す戦略(★1到達、半分制圧)**: **+34秒/分**。

壊す方が時間もスコアも上回る。**逆に言えば、この設計では「敵を無視して壊し続ける」(-20 + 30 = +10秒/分)も成立してしまう**。これは意図的に許容する — 依頼書 §5-6 のデススパイラル回避を優先した結果であり、「敵と戦う方がもっと得」(+34) という序列は保たれている。

### 5-7. 上限に張り付くケース

★2で全部倒し続けると **+56秒/分**。`BattleTimeMax = 300` に張り付く。これは「上手いプレイヤーは実質時間制限なし」を意味するが、ハードキャップがある以上ラウンドは必ず終わる(最悪 300秒 = 5分)。**キャップに常時張り付くようなら `MaxLossPerMinute` を下げるのではなく `TimeReward` 側を下げること**(損失キャップはデススパイラル防止装置なので触らない)。

### 5-8. 数値の修正案(たたき台からの変更点まとめ)

| 項目 | 依頼書たたき台 | 提案 | 理由 |
|---|---|---|---|
| 被弾ペナルティ | 一律 -2秒 | 敵種別ごと(-1〜-3秒) | ★1が理不尽、★3が生ぬるいのを両方解決 |
| 無敵時間 | 1.5秒 | **2.0秒** | 1.5秒だと理論ドレインが 1.33秒/秒 で破綻 |
| (新規) | — | **MaxLossPerMinute = 20** | 無敵時間だけでは足りない。これが本命のガードレール |
| 下限フロア | 15秒 | 15秒(変更なし) | 妥当 |
| パトカー/戦車 報酬 | +8 / +15秒 | 変更なし | 妥当 |
| 警官/兵士/ヘリ 報酬 | 記載なし | +3 / +4 / +12秒 | **ユーザー決定により確定** |
| パトカーの役割 | (依頼書になし) | **無攻撃 + 警官輸送(ユーザー決定・第3案)** | 「+8秒が無料にならない」「パトカー優先の判断を作る」ため。§3-3参照。被弾ペナルティは1→0に変更 |
| 建物90%破壊 | +10秒 | 変更なし | 妥当 |
| ラウンド上限 | 300秒 | 変更なし | 妥当 |
| 基礎ラウンド時間 | 120秒(90秒案あり) | **120秒を維持(§6参照)** | 下記 |

### 5-9. 基礎ラウンド時間 120秒 vs 90秒(§6-3への回答)

**推奨: 当面 120秒 を維持し、★1の実機確認後に再判断する。**

| | 120秒 | 90秒 |
|---|---|---|
| 狙い(緊張感) | 弱い | 強い。「延ばさないと終わる」が明確 |
| ★1到達(1,000点想定30秒)後の残り | 90秒。★1の1波(35秒)を2回まわせる | 60秒。★1を1.5波しか経験できない |
| **最初にリリースする状態(★1のみ実装)での体験** | 敵を1回全滅させれば +28秒 で 148秒 相当。手応えが出る | 敵に苦戦すると60秒で終わる。**「敵が出てきて何もできないまま終わった」で離脱** |
| ★2/★3の閾値が未調整な初期段階 | 影響小 | ★2(4,000点)に到達する前にラウンドが終わり、★2以降を実機で検証できない |

根拠:
1. **90秒案のリスクは、我々が最初に出荷する状態(★1のみ・閾値未調整)で最大化する。** 依頼書 §4.3 自身が「閾値は低すぎる可能性が高い」と認めており、タイムの蛇口が想定どおり開くかは未検証。蛇口が細い状態で基礎時間を削るのは、悪い方向にダブルで賭けることになる。
2. **「延ばさないと終わる」緊張感は基礎時間を削らなくても作れる。** タイマーが被弾で赤く光り、撃破で緑に跳ねる(§5-5)という**可視化そのもの**が緊張感の主要因である。数字が黙って減るだけだった従来と、根本的に体験が変わる。
3. **`Config.Round.BattleTime` を変えるだけの1行変更**なので、実機で「120秒だとダレる」と分かった時点でノーリスクに切り替えられる。逆方向(90で出して不評 → 戻す)より、こちらが安全側。

**再判断の基準(実測して決める)**: ★1実装後に3ラウンド遊び、
- 平均終了時刻が 150秒未満 → 蛇口が細い。**BattleTime は 120 のまま、TimeReward を上げる**
- 平均終了時刻が 200秒以上、かつ中盤に手持ち無沙汰を感じる → **90秒 へ短縮**
- その中間 → **100秒** を試す

### 5-10. タイム経済の調整レバーの優先順位(実機で「無視戦法」が最適になった場合)

§5-6 で示したとおり、現在の設計では「壊す方が壊さないより得」という序列を保っている。しかし §5 の数値はすべて**未計測の仮定**(スコアの伸び方・敵の遭遇頻度など)の上に立っており、実機で「敵を無視して建物だけ壊し続ける」が数値上の最適解になる可能性は残る。その場合の調整は、以下の優先順位で行うこと。

1. **`Config.Score.BuildingBonusTime` を 10 → 5 に下げる**
   建物ボーナスは敵と無関係に得られる報酬であり、「無視戦法」の収益源そのもの。まずここを削るのが最も直接的で、他の値への副作用が無い。
2. **それでも足りなければ `Config.Threat.Damage.MaxLossPerMinute` を 20 → 15 に下げる**
   無視戦法の「損失を気にしなくていい」度合いを下げる。ただし §5-6 の黒字保証にも影響するため、1を先に試してからにする。
3. **`TimePenalty`(被弾ペナルティ)を上げるのは最後の手段**

**3を最後にする理由**: `MaxLossPerMinute` のキャップが存在する限り、被弾ペナルティを上げても**到達する損失の天井(1分あたりの最大ドレイン)は変わらない**。変わるのは「キャップに到達するまでの被弾回数」だけであり、ペナルティを上げるほど**少ない被弾回数でキャップに到達してしまう**。キャップ到達後は追加の被弾が事実上無償になるため、「多少被弾しても気にせず壊し続ける」プレイヤーほど早く「被弾が無料な状態」に入ってしまい、むしろ無視戦法(≒被弾を恐れず建物だけ壊す戦法)を助長する方向に働く。これは狙いと正反対の効果なので、`TimePenalty` を触るのは 1・2 を試した後に限る。

---

## 6. 実装順序の提案

**依頼書 §6-5 の方針(★1だけ先に作る)に沿った7ステップ。各ステップは単独でコミットでき、単独で動作確認できる。**

### Step 0: 基盤整備(ゲーム体験は一切変わらない)

| 内容 | 変更ファイル |
|---|---|
| `Config.Round` にキャップ/フロア追加、`Hud` を `RemoteNames` に追加 | Config |
| `RoundClock` 新設。`runPhase` のバトル部分を RoundClock 駆動に置換 | RoundClock(新) / GameManager |
| `Explode(ctx)` への置換 + `blastListeners` 配列化 + `scoreScale` / `maxReal` / `bonusPolicy` 対応 | DestructionManager / WeaponServer(3か所) / NPCManager(3行) |
| `CityGenerator.GetRoadLines()` / `GetCityBounds()` の getter 追加 | CityGenerator |

**動作確認(厳格化。Step 0 は見た目が変わらないリファクタなので、壊れても気づきにくい。以下を1項目ずつ確認する)**:

- [ ] 3武器(バズーカ/エアストライク/リモート爆弾)すべてで、従来どおり爆発・破壊・スコア加算が発生する
- [ ] 市民NPCの即死・パニック逃走・help!フキダシ・フェード消滅・頭数維持(常時 `Config.NPC.Count` 体)が、すべて従来どおり動く
- [ ] 全壊ボーナス(+500点)が、1棟につき1回だけ入る(連打しても2回目は入らない)
- [ ] ラウンドが LOBBY → BATTLE → RESULT を1周し、次の LOBBY でマップが再生成される
- [ ] タイマーが 120→0 で減り、リザルト画面が正しいランキング・破壊率で表示される
- [ ] 出力ウィンドウ(サーバー・クライアント両方)に赤いエラーが1つも出ない
- [ ] サーバーログに `[RoundClock]` の開始ログが出る(RoundClockが実際に動いていることの確認)

**1項目でも欠けたら以降のステップに進まない。** 最も広範囲に触るステップなので、ここを確実に固める。

### Step 1: タイム経済の可視化(敵はまだ出ない)

| 内容 | 変更ファイル |
|---|---|
| 建物90%破壊で `RoundClock.Add(+10, "building")` | DestructionManager |
| `Hud` リモートの購読、タイマーの増減演出、フローティング「+10秒!」、赤フラッシュ枠(まだ発火しない) | UIController |

**動作確認**: 1棟を90%まで壊す → タイマーが緑に光って +10秒 跳ね、「+10秒!」が浮かぶ。**この時点で「壊すと時間が延びる」というループの半分が完成し、単体で面白いかを判断できる。**

### Step 2: ★1(警官のみ。パトカーはまだ)

| 内容 | 変更ファイル |
|---|---|
| `Config.Threat`(EnemyTypes は PoliceOfficer のみ、Stages は★1相当の暫定squad: PoliceOfficer×4のみ。**最終的な★1編成(パトカー2+警官2。§3-3参照)は Step 3 でパトカーAIと同時に反映する**) | Config |
| `EnemyManager` 新設: 生成 / 直進移動 / テレグラフ / 遮蔽判定 / 被弾 / 無敵 / 撃破 / `OnExplosion` / `Clear` | EnemyManager(新) |
| `ThreatManager` 新設: スコア監視 / 昇格 / 編成指示 / ラウンド境界 | ThreatManager(新) |
| `WeaponServer.GetTotalScore()` 追加 | WeaponServer |
| 敵エフェクト(`enemyAim` / `enemyShot` / `enemyKill` / `threatUp`) | EffectsClient |
| ★インジケータ、昇格テロップ、被弾フラッシュ | UIController |

**動作確認**:
1. 1,000点到達 → テロップ「警察が出動した!」+ ★インジケータが ★☆☆ に + ログに到達時刻
2. 警官4人(Step 2時点の暫定編成。最終編成は Step 3 で パトカー2+警官2 に変わる)が街の外周(±248)から湧く。プレイヤーから100stud以上離れている
3. 近づくと赤い予告ビーム → 0.5秒後に被弾 → タイマー赤フラッシュ + -1秒 + 画面赤フラッシュ
4. **建物の陰に隠れると当たらない**(遮蔽判定)
5. 無敵2秒の間は連続被弾しない
6. バズーカで倒す → +300点 + タイマー緑 +3秒
7. 全滅から20秒後に次の部隊
8. ラウンド終了 → 敵が全部消える。次ラウンドで★0に戻る
9. **残り15秒以下では減らない**(フロア)

### Step 3: ★1完成(パトカー + 道路走行AI + 警官輸送)

| 内容 | 変更ファイル |
|---|---|
| `Body = "car"` のモデル生成(6パーツ)、`Movement = "road"` のマンハッタン経路(道路中心線 -248/-124/0/124/248 に沿って走り、交差点で車線を切り替える) | EnemyManager |
| `DeployOnArrive` による警官の降車(到着判定・`DeployCount`体の PoliceOfficer 生成・squadId継承・`DeployInterval` ごとの再降車・`MaxDeployTrips` での打ち切り) | EnemyManager |
| **`AttackType = "ram"` は実装しない**(パトカーは攻撃しない。§3-3参照) | — |

**動作確認**:
- パトカーが道路の上だけを走る / 建物をすり抜けない / 交差点で曲がる
- 目的地到着で警官2人が降車する(スポーン位置が車の周囲 `DeployRadius` 内)
- 降車前にパトカーを破壊すると、その車からは以降誰も降りてこない
- パトカーを放置すると `DeployInterval` ごとに追加の警官が降り、`MaxDeployTrips` で打ち止めになる
- 降ろされた警官を全員倒してもパトカーが生きていれば次のwaveは来ない(squadId生存判定。§3-3参照)。パトカーも倒すと RespawnDelay 後に次waveが来る
- 破壊で +8秒(パトカー)。プレイヤーへの被弾は警官経由のみで、パトカーへの接触ダメージは発生しない

**★ここで一旦停止し、実機(タブレット)でフレームレートと"面白いか"を確認する。** ★2以降に進むかの判断ポイント。

### Step 4: 武器改修(★2の前に必ずやる)

| 4a | リモート爆弾の距離制限(`MaxPlaceDistance`)+ 拒否時の `Hud "notice"` | WeaponServer / UIController |
| 4b | 連鎖ボーナス(`ChainBonus` 走査 + `scoreScale` + 「×3 CHAIN!」表示) | WeaponServer / UIController |
| 4c | エアストライク絨毯化(戦闘機3機の自作モデル + 18発の時間差投下 + 矩形予告マーカー + Cooldown 20) | WeaponServer / EffectsClient / Config |

**なぜ★2より先か**: 4b と 4c が**スコアの伸び方を根本から変える**ため、これを入れる前に★2/★3の閾値(4,000/10,000点)を調整しても無駄になる。依頼書 §4.3 の懸念そのものへの対処。

**動作確認**:
- 4a: 50stud以上離れた場所をクリック → 設置されず「近づいて設置してください」
- 4b: 1個起爆(×1)/ 5個起爆(×3・スコアが3倍で入る)/ 8個起爆(×5)。UIに倍率が出る
- 4c: 予告矩形が出る → 3機が飛来 → 爆発が線上を走っていく → 20秒クールダウン。**タブレットでfps測定**
- ★1到達時刻を再測定する。連鎖ボーナスと絨毯爆撃でスコアの伸び方が変わるため、Step 2〜3 で測った到達時刻は無効になる。`Config.Threat.Stages` の閾値(1000/4000/10000点)を、この再測定値をもとに見直す

### Step 5: ★2(ヘリ + 増援)

Config に `Helicopter` と★2の Stage を足し、`Movement = "air"` の分岐(高度固定 + 周回)を EnemyManager に追加する。**ThreatManager は無変更**(データ駆動が効いていることの検証になる)。

### Step 6: ★3(戦車 + 建物破壊)

| 内容 |
|---|
| `Tank` の `Movement = "road"`(Step 3 の経路コードを再利用) |
| `AttackType = "shell"` + `DestroysBuildings` → `deps.explode({ attacker = nil, bonusPolicy = "deny" })` |
| **貢献度クレジット方式(§5-3付録 案3)** の実装 |

**動作確認**: 戦車の砲撃で建物が壊れる / **スコアが1点も入らない** / 戦車が90%到達させた建物では全壊ボーナスが出ず「軍隊に破壊された」と表示 / プレイヤーが50%以上壊していた建物なら戦車がトドメでもプレイヤーに +500/+10秒。

### Step 7: ★4 の口を確認するだけ

Config の `Stages` に★4のダミーエントリ(既存の `Tank` を1体だけ)を一時的に足し、**コードを1行も変えずに4段階目が動く**ことを確認する → 確認したら消す。データ駆動が本当に効いているかの検証。

---

## 7. 懸念点・リスク

### 7-1. 既存機能を壊しかねない箇所

| # | 箇所 | リスク | 対策 |
|---|---|---|---|
| 1 | **`registerDestruction` の暗黙の副作用** | 現状 `attacker=nil` でも `bonusGiven=true` が立ち、ボーナスが誰にも渡らず"消費"される。依頼書の希望動作と偶然一致しているが、意図された分岐ではない。ここを触る誰かが将来壊す | `bonusPolicy` として明示化し、コメントで理由を書く(§5-3付録) |
| 2 | **`Explode` のシグネチャ変更** | 呼び出し3か所のいずれかを直し忘れると `ctx.position` が nil | サイレント失敗ではなく即エラーで落ちるので Step 0 のテスト1周で必ず発覚する。シムは入れない判断の根拠でもある |
| 3 | **`NPCManager.OnExplosion`** | 唯一の外部インターフェース。ここの ctx 化を誤ると市民が死ななくなる/パニックしなくなる | 変更は冒頭3行の分解のみ。本体は1行も触らない |
| 4 | **`runPhase` の書き換え** | LOBBY/RESULT まで RoundClock 駆動にすると、ロビー中に敵撃破のタイムが入るなどの事故が起きる | **BATTLE フェーズだけ**を RoundClock 駆動にし、LOBBY/RESULT は既存の `runPhase` をそのまま使う |
| 5 | **`WeaponServer.ResetScores()` と `ThreatManager.Start()` の順序** | 逆順にすると前ラウンドのスコアで即★3になる | GameManager のループにコメントで明記 |
| 6 | **`SetRoundActive(false)` は敵を止めない** | 既存のフラグは武器の発射しか見ていない。RESULT中に敵が撃ち続けるとタイムが減り続ける | `ThreatManager.Stop()` で `EnemyManager.SetAggressive(false)` を必ず呼ぶ |
| 7 | **敵パーツが `Destructible` タグを持たないこと** | 誤って付けると自分の砲撃で自分が瓦礫になる | 敵は `workspace.Enemies` フォルダに置く。`Explode` の `OverlapParams` は `Include { workspace.Map }` なので構造的に混ざらない(既存 L228-230) |
| 8 | **CityGenerator の座標定数の二重管理** | `GRID_TILESIZE`/`GRID_SIZE` はファイル内ローカル。±248 を Config にコピーすると、将来 `GRID_SIZE` を変えたとき敵が街の外に湧く | `CityGenerator.GetRoadLines()` を追加して単一情報源にする(Config にはコピーしない)。**この getter 追加は必須** |
| 9 | **降車警官の squadId 継承漏れ(★1改訂に伴う新規リスク)** | 生成時に親車の squadId をコピーし忘れると、編成の全滅判定が「パトカーを倒しても永遠に次waveが来ない」または「警官を倒しただけで次waveが来てしまう」のどちらかに壊れる | 個体生成を `spawnEnemy(type, position, squadId)` のような単一関数に集約し、警官の直接スポーンも車からの降車もこの関数だけを通す。squadId の省略が構造的に起きないようにする(§3-3末尾参照) |

### 7-2. パフォーマンス上の懸念

| # | 懸念 | 見積り | 対策・調整レバー |
|---|---|---|---|
| 1 | **絨毯爆撃18発(最重要)** | 現行の5発同時(半径10)に対し、破壊体積は1回あたり約31倍。ただし `Sequential = true` なら 0.15秒に1回の Explode(6.7回/秒)に分散され、**瞬間負荷は現行の5発同時より軽い**。持続負荷は 2.7秒間続く | `BombInterval`↑ / `MaxRealPerBomb`↓(既定12。既存の30より絞ってある) / `Radius`↓ / `BombsPerPlane`↓。**すべてConfigで即変更可能** |
| 2 | **瓦礫キューの追い出し(evict)が常時発生** | 18発 × 最大12個 = 216個の本物瓦礫が2.7秒で積まれる。寿命8秒なので `MaxUnanchoredParts = 1000` に対しては単発では収まるが、他武器と重なると `evictOldest` が回り続ける | 既存の追い出し機構は**まさにこのために設計されている**ので破綻はしない。見た目に瓦礫が早く消えるようなら `DebrisLifetime` を 8→5 |
| 3 | 敵のパーツ数 | 最大同時 = 最大の1編成のみ(昇格時に旧編成は撤退)。★2 = 4×6 + 8×6 + 6 = **78パーツ**。戦闘機3機 = 15パーツ(一時的) | 予算4,500に対して2%未満。**パーツ数を理由に設計を歪める必要はない**(依頼書の指摘どおり) |
| 4 | 敵の Heartbeat ループ | 最大20体 × 数回の Vector 演算。既存 NPCManager が10体で問題ないので同等 | 問題になれば更新頻度を落とす(移動は毎フレーム、AI判断は0.2秒ごと) |
| 5 | 攻撃判定の Raycast | 最大 8体 ÷ 1.6秒 = 5回/秒 | 無視できる |
| 6 | 戦車の建物スキャン | `GetPartBoundsInRadius(90)` を 4秒に1回 × 2台。半径90は広く、返るパーツ数が多い | `MaxParts` を明示的に小さく(例: 50)設定する。既存 Explode は 2000 を指定している(L231)が、戦車の標的探しは1個見つかれば十分 |

### 7-3. 仕様が曖昧でユーザーの判断が必要な箇所

**2026-07-29 追記: 下表の1〜4はユーザー決定により確定した。決定内容と、それに伴う設計への反映箇所を記す。5〜13は初版の提案どおり確定(変更なし)。**

| # | 論点 | 決定 | 決定の理由・反映箇所 |
|---|---|---|---|
| 1 | 警官・兵士・ヘリの撃破報酬 | **+3 / +4 / +12秒(提案どおり採用)** | §5-1 に反映済み |
| 2 | パトカーは攻撃するか | **攻撃しない。警官を運ぶ輸送車にする(第3案・新規)** | `AttackType="none"`、`DeployOnArrive` 等を新設。詳細は §3-3「パトカーの警官輸送」、編成の全滅判定は同節末尾を参照。★1編成・§5シミュレーションを全面改訂(§3-3・§4-4・§5-2・§5-4) |
| 3 | タイムは全プレイヤー共有か | **共有(提案どおり採用)** | 変更なし |
| 4 | 段階判定のスコアは合計か最高か | **合計・`ScoreSource="sum"`(提案どおり採用)** | 変更なし |
| 5 | 編成が全滅したら再出現するか | する(`RespawnDelay` 20〜25秒) | 再出現しないと、制圧後に世界がまた静かになりループが切れる。ただしタイムの蛇口が開きっぱなしになる(300秒キャップで抑制) |
| 6 | 昇格時に旧編成はどうするか | フェード撤退(`fleeAway` と同手法) | 累積させると★3で20体超になり、パーツ・負荷・理不尽さがすべて増える |
| 7 | 連鎖倍率を全壊ボーナスに乗せるか | 乗せない | §4-3 ⑦の根拠のとおり。乗せると8連鎖で2,500点になり閾値設計が壊れる |
| 8 | 連鎖倍率を市民(NPC)撃破に乗せるか | 乗せる | 「仕込んで一気に」への報酬の一貫性 |
| 9 | 予告ビームで**敵の位置がプレイヤーに露出する**ことの是非 | 露出させる(それが狙い) | ミニマップが無いので、ビームが「敵がどこにいるか」の唯一の手がかりになる |
| 10 | ★1到達の「開始30秒程度」が実際に成立するか | **未検証**。現行のスコアレートを実測していない | `DebugLog = true` で到達時刻をログに出し、実測してから Config で調整する。Step 2 の動作確認項目に含めた |
| 11 | 徒歩の敵が建物をすり抜ける | 許容(既存の市民NPCと同じ挙動) | 車両は道路限定で回避。徒歩まで経路探索を入れるのは今回のスコープを超える |
| 12 | ビネットの見た目 | まず全画面赤フラッシュで実装 | 真の放射状ビネットは `UIGradient` では作れず、画像アセットの作成が必要(スコープ外)。フラッシュで不足なら別途相談 |
| 13 | 昇格音・サイレンの音源 | 空文字で置く | `playSound` が空文字を安全に無視するため、音源が決まるまで実装をブロックしない |

---

## 8. 次のアクション

1. 本提案書のレビュー(特に §7-3 の ★ 印4件)
2. 承認後、**別タスクとして Step 0 から着手**する
3. Step 3 完了時点で実機確認 → ★2以降に進むかを判断

**本タスクではここで停止する。既存ファイルへの変更は行っていない。**
