# CURRENT_SPEC.md — 現状仕様書

## 0. この文書について

これは**変更指示書ではない**。以下のファイルを読んで書き起こした「今こうなっている」という現状のスナップショットである:

`ReplicatedStorage/Config.lua` / `ServerScriptService/GameManager.server.lua` /
`ServerScriptService/Modules/CityGenerator.lua` / `DestructionManager.lua` / `NPCManager.lua` / `WeaponServer.lua` /
`StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua` / `EffectsClient.client.lua` / `UIController.client.lua`

`archive/` 内の `roblox_destruction_game_spec.md`・`city_expansion_spec.md`・`visual_upgrade_spec.md`・
`npc_panic_spec.md`・`npc_bubble_fix.md`・`building_templates_spec.md` はすべて過去の**変更指示書**であり、
実装済みの内容は本書が上書きする(食い違いがあれば本書が正)。

---

## 1. モジュール構成と責務

```
ReplicatedStorage
├─ Config (ModuleScript)                共有設定。全モジュールがrequire
└─ BuildingTemplates (Folder・任意)      手作り建物Model置き場(現状: 従来モードのみで使用)

ServerScriptService
├─ GameManager (Script)                 ラウンド進行の司令塔
└─ Modules (Folder)
   ├─ CityGenerator (ModuleScript)      街の手続き生成(グリッドモード/従来モード)
   ├─ DestructionManager (ModuleScript) 爆発判定・破壊・瓦礫ライフサイクル
   ├─ EnemyManager (ModuleScript)       敵(★1〜)の実体。生成・移動・攻撃・被弾・撃破
   ├─ NPCManager (ModuleScript)         軽量NPC(徘徊・パニック逃走・即死ラグドール)
   ├─ RoundClock (ModuleScript)         バトル残り時間の管理(deadline方式・増減対応・損失キャップ)
   ├─ ThreatManager (ModuleScript)      段階(★)の政策。スコア監視・昇格・編成指示
   ├─ WeaponServer (ModuleScript)       武器3種のサーバー処理・スコア集計
   ├─ VisualSetup (ModuleScript)        ライティング・Terrain草地の初期設定(起動時1回)
   └─ TemplateValidator (ModuleScript)  手作りBuildingTemplatesの検証(従来モードのみで使用)

StarterPlayer/StarterPlayerScripts
├─ WeaponClient (LocalScript)   入力処理(クリック/タップ発射・武器切替・起爆)。画面は作らない
├─ EffectsClient (LocalScript)  演出再生(爆発・煙・閃光・音・カメラシェイク)
└─ UIController (LocalScript)  HUD/リザルト画面の生成一式。標準ツールバーの無効化も担当
```

### 各モジュールの責務

- **GameManager.server.lua**: `Remotes`フォルダ(RemoteEvent一式)を起動時に自動生成。各モジュールへ依存を注入(`Init`)。ラウンドを `LOBBY → BATTLE → RESULT` の無限ループで回す。LOBBYは`runPhase`(固定長カウントダウン)、BATTLEは`runBattlePhase`(`RoundClock`の残り時間が尽きるまで)で毎秒`RoundState`を全クライアントに通知。**RESULTは手動進行**: `waitForReady()`が`Ready`リモート(誰か1人が「次へ」を押す)または`Config.Round.ResultTimeout`(既定120秒)のどちらか早い方まで待ち、`RoundState`の"RESULT"は1回だけ送信する(毎秒送信はしない)。RESULT突入時にランキングへ撃破数をマージ(`WeaponServer.GetRanking()`の`userId`と`EnemyManager.GetKillCounts()`のPlayerキーを`player.UserId`で突き合わせる。`DisplayName`は一意でないため使わない)、建物の全体破壊率をLOBBYで生成した`buildings`ローカル変数(`DestructionManager`と同じテーブル参照)から集計して`Result`に添える。プレイヤーの入退室・リスポーン時の武器再配布も担当。途中参加者には`onPlayerAdded`内で現在の`roundState`を`RoundState:FireClient`で個別送信する(RESULTが毎秒送信でなくなったための補完)。
- **CityGenerator.lua**: `Generate()`で街を1つ生成し、建物ごとの情報テーブル(`{name, total, destroyed, bonusGiven, center}`)を返す。`USE_GRID_MODE`(ファイル内ローカル定数)で処理を分岐(詳細は3節)。パーツ数上限は`overBudget()`で常時チェックし、超えたら以降の生成を打ち切る。`GetRoadLines()`/`GetCityBounds()`で道路中心線・街の外周座標を取得できる(グリッドモード限定。従来モードでは`nil`を返す)。
- **DestructionManager.lua**: `Explode(ctx)`(`ctx = {position, radius, attacker, source, scoreScale?, maxReal?, bonusPolicy?, silent?}`という単一テーブル引数)が全武器の爆発処理の唯一の入口。破壊対象("Destructible"タグ)の検出・本物/ダミー破片への振り分け・瓦礫キュー管理・スコア加算・建物破壊率集計・全壊ボーナス判定・爆風の影響を受けるモジュール群への委譲(`deps.blastListeners`配列。現状は`NPCManager.OnExplosion`と`EnemyManager.OnExplosion`の2件を登録)を行う。
- **EnemyManager.lua**: 敵(★1〜)の実体。`NPCManager`の軽量設計(Humanoid不使用・全パーツAnchored・共有Heartbeatで補間移動)を手法としてコピーしている(`NPCManager`自体は変更しない)。個体生成は`spawnEnemy(type, position, squadId)`の単一入口(パトカーの降車もここを通る)。道路交点(`CityGenerator.GetRoadLines()`の直積)から`Config.Threat.Spawn.MinDistanceFromPlayer`以上離れた点を選んで湧く。移動は`etype.Movement`で分岐する:`"direct"`(既定)は`AttackRange`を境に`ApproachSpeed`/`MoveSpeed`の2段階で直進。`"road"`(パトカー用。Step3)は道路網の交点だけを経由してプレイヤーへ接近する専用AI(マンハッタン経路構築・車線オフセット・中間ウェイポイントは距離ではなく「通り過ぎたか」を内積で判定・向き補間)。攻撃は赤いビーム予告(`Config.Threat.Damage.BeamDuration`秒だけ画面に残る、見た目専用)を出したうえで、判定タイミング(敵種別の`Telegraph`。既定`Config.Threat.Damage.DefaultTelegraph=0`)が0なら同一フレームで同期的に、正の値ならその秒数後に`task.delay`で、`resolveAttack`が距離・遮蔽を再判定してから命中判定を行う(判定タイミングと見た目の表示時間は別々の値)。撃破時は`NPCManager.killNpc`と同じ手法でラグドール化し(`CollisionGroup="Debris"`を流用)、`Config.Threat.CorpseDespawnTime`後に消える(`DestructionManager`の瓦礫キューには入れない)。`workspace.Enemies`に配置し、`Destructible`タグは付けない。`CityGenerator.GetRoadLines()`が`nil`/空を返した場合(従来モード等)は`warn`を1回出して自身を無効化し、以降は何もしない。撃破数の集計(`GetKillCounts()`。Playerオブジェクトをキーに持つ`{[Player]=number}`をシャローコピーして返す。種類は問わない合計)もここが担当し、リザルトの表示に使われる。`Clear()`で`killCounts`をリセットする(RESULTで読み終えた後のLOBBYで呼ばれるため順序は問題ない)。
  - **降車(`DeployOnArrive`。Step3)**: `etype.DeployOnArrive=true`の敵は目的地到着時に`etype.DeployType`を`DeployCount`体生成する(`deployFromCar`)。生成は`spawnEnemy`を通り、**親の`squadId`をそのまま引き継ぐ**(引き継がないと編成の全滅判定`CountAlive(squadId)`が壊れる)。到着できないまま`DeployFallbackTime`秒経つと強制的に降ろす保険がある(「Step3の設計判断」§9-8参照。**実装済み・未検証**)。
  - **湧き位置の分散(`DeploySquad`。Step3手順6)**: 同一`DeploySquad`呼び出し内で`usedPoints`(閉じたローカル集合)を持ち、`Movement=="road"`の個体だけがそこに書き込んで交差点の重複を避ける。それ以外の個体(警官)は`usedPoints`を避けつつ`Spawn.Jitter`の範囲でランダムにずれる(警官同士の重複は許容。理由は「Step3の設計判断」§9-5参照)。除外の結果候補が尽きた場合は`MinDistanceFromPlayer`は諦めず、重複除外だけを諦めて`warn`を出す。
  - **被弾フラッシュ(Step3手順7)**: `etype.Hits > 1`の敵(現状パトカーのみ)にだけ`Highlight`インスタンスを生成時に1個作っておき(`enemy.hitFlash`)、ダメージが入り生き残ったときだけ`Enabled`を0.12秒だけ`true`にする。撃破された場合や`HitCooldown`で無効化された被弾では発火しない。**リモートは使わない**(サーバー内で完結)。
- **ThreatManager.lua**: 段階(★)の政策。`Config.Threat.CheckInterval`ごとにスコアを監視し、`Config.Threat.Stages`を昇順に走査して閾値を跨いだら`EnemyManager.DeploySquad`で編成を派遣する(段階固定の`if`分岐は持たない)。編成の全滅(`EnemyManager.CountAlive(squadId)==0`)を検出すると`RespawnDelay`秒後に次の編成を派遣する(`waitingRespawn`フラグで二重派遣を防止)。ラウンド境界は`Start()`/`Stop()`/`Clear()`の3メソッドで`NPCManager`と同じ作法。
- **RoundClock.lua**: バトル残り時間の唯一の持ち主。`Start(base)`/`Remaining()`/`Add(delta, reason, player)`/`Stop()`を持つ。内部はdeadline方式(`endsAt = os.clock() + 残り秒数`)で、`task.wait`のドリフトを吸収する。`Add`は`running=false`(LOBBY/RESULT中)なら何もせず0を返す。上限(`Config.Round.BattleTimeMax`)・下限フロア(`Config.Round.BattleTimeFloor`)のクランプに加え、**損失キャップ**(直近60秒の累計損失が`deps.maxLossPerMinute`を超えないようにクリップ。`Config.Threat.Damage.MaxLossPerMinute`を`GameManager`経由で受け取る。0で無効)を行い、実際に反映された秒数を返す。キャップで完全にブロックされた瞬間(残り予算0)だけサーバーログに出す。
- **NPCManager.lua**: Humanoidを使わない軽量NPC。徘徊(共有Heartbeat)・即死ラグドール・パニック逃走・フェード消滅・頭数維持を担当。`OnExplosion(ctx)`で爆風を受ける(内部ロジックは`ctx`化の影響を受けていない)。
- **WeaponServer.lua**: バズーカ(直進弾+レイキャスト)・エアストライク(矩形マーカー予告+編隊による絨毯爆撃)・リモート爆弾(クリック位置設置+起爆)の3武器を実装。エアストライクは`PlaneCount`機がプレイヤー→クリック地点の向きに引いた爆撃線の上を通過しながら`BombsPerPlane`発ずつ投下する(`buildSchedule`/`planeLateral`/`buildPlane`)。**戦闘機の速度・投下地点・飛行時間はすべて投下スケジュールから導出**しており、独立した入力値を持たない(§12-4)。各爆発は`maxReal = MaxRealPerBomb`で`Explode`を呼び、`scoreScale`は渡さない(連鎖ボーナスはリモート爆弾専用)。リモート爆弾は設置時に`MaxPlaceDistance`の**水平距離**判定を行い、超過時は爆弾を作らず・設置数もクールダウンも消費せず`Hud "notice"`を本人にだけ送る(`placeBomb`。判定はサーバー側のみで、クライアントは変更していない)。起爆時は同時起爆数から`chainMultiplier()`で倍率を求め、各`Explode(ctx)`に`scoreScale`として渡したうえで`Hud "chain"`を送る(×1のときは送らない)。ツール配布、`leaderstats`スコア管理、クールダウン管理もここ。`GetTotalScore()`は`ThreatManager`の段階判定用(`Config.Threat.ScoreSource`で合計/最高を切替)。`GetRanking()`の各エントリには`userId`(`player.UserId`)も含む(`name`/`score`は従来どおり。`GameManager`が`EnemyManager.GetKillCounts()`とこの`userId`で突き合わせて撃破数をマージする。`DisplayName`は一意でないため使わない)。
- **VisualSetup.lua**: 起動時1回だけライティング(明るさ・時刻・霞み)とTerrain草地を設定。`Lighting.Technology`だけはスクリプトから変更できないため手動設定が必要(SETUP.md参照)。
- **TemplateValidator.lua**: `ReplicatedStorage/BuildingTemplates`内のModelを検証し、パーツ数・サイズの警告を出す。従来モード(`chooseBuildingSource`)からのみ呼ばれる。**グリッドモードでは呼ばれない**。
- **WeaponClient.client.lua**: `Tool.Activated`でのクリック/タップ発射(`Mouse.Hit.Position`をサーバーへ送信)、数字キー1/2/3での武器切替、Fキー起爆。UIControllerとは`WeaponClientEvents`フォルダ内のBindableEvent(`EquipRequest`/`FireRequest`/`DetonateRequest`/`WeaponSelected`)で連携。
- **EffectsClient.client.lua**: `Effect`リモートを受けて爆発(火花+煙+閃光+音+カメラシェイク)・絨毯爆撃の矩形マーカー(`"marker"`。`length`/`width`/`direction`を受け取り`CFrame.lookAt`で向きを付ける。Instanceは1個だけ)・戦闘機の飛行音(`"jet"`)・建物崩壊の粉塵・NPC撃破エフェクト・各種効果音を再生。**多数の爆発が短時間に連続したときの演出の合流処理**を持つ: カメラシェイクは加算ではなく`math.max`で更新し(§12-5)、爆発音は`playSound`の`dedupeInterval`引数(0.1秒)で間引く。どちらも爆発全般に効くので、絨毯爆撃18発でもリモート爆弾10連鎖でも同じように抑えられる。`"timeGain"`/`"timeLoss"`はタイム増減音で、3D減衰させないためカメラ位置基準で再生する(`data.position`は常にnilで届く)。敵関連: `"enemySpawn"`(湧き演出)・`"enemyAim"`(赤い予告ビーム。`duration`秒でフェード後Destroy)・`"enemyShotHit"`(被弾音+シェイク)・`"enemyShotMiss"`(はずれ音のみ)・`"enemyKill"`(撃破演出)・`"enemyDeploy"`(Step3手順7。パトカーの位置から青いリングが半径2→12まで広がりつつ`Transparency`が1へ、0.4秒でDestroy。生成するInstanceは1個のみ)・`"threatUp"`(段階昇格音。`Config.Sounds[data.sound]`)。**被弾フラッシュ(`Hits>1`の敵が光る演出)はリモートを使わずEnemyManager内で完結する**(EffectsClientの担当ではない)。
- **UIController.client.lua**: HUD(残り時間・スコア・武器スロット・クールダウン暗転・中央テロップ)、モバイル用発射/起爆ボタン、リザルト画面をすべて生成。標準の`Backpack`CoreGuiを無効化(自作スロットとの二重表示防止)。`Hud`リモートを購読し、タイム増減時のタイマー色フラッシュ・「+10秒!」フローティング(合算コアレス対応)・被弾ビネット(`Active=false`の全画面`Frame`)・操作失敗の通知(`"notice"`。画面中央やや下・1.2秒・世代トークンで差し替えるため連打しても重ならない。中央テロップとは別ラベル)・連鎖ボーナス表示(`"chain"`。スコアの下・0.8秒・倍率で色が変わる)を再生する。**HUDに追加するラベルは`Active = false`にする**(クリックを吸って武器が撃てなくなる事故を防ぐため。§12参照)。★インジケータ(`timerLabel`の左。`Hud "threat"`のdata.totalから件数を受け取り、ハードコードしない。段階0では`Visible=false`にして非表示にする)と、画面端の方向インジケータ(▲。`workspace.Enemies`を直接読む読み取り専用のクライアント側計算。サーバー通信は増やさない)も担当。**リザルト画面**: 順位行(撃破数を`(警察 N)`で併記)+サマリー行(破壊した建物数・全体破壊率)+建物リスト(破壊率1%以上のみ・降順・`ScrollingFrame`+`UIGridLayout`3列。`TextScaled`は使わずTextSize固定)+右下の「次へ」ボタン(押すと`Ready`を1回送信し`次のラウンドを準備中…`表示に切替)。画面を閉じるのは`RoundState`の"LOBBY"受信時のみ(自動クローズのタイマーは持たない)。`RoundState`が"RESULT"以外の状態(=BATTLE/LOBBY以外)を受けたときの`timerLabel`は固定文言"リザルト"を表示する(カウントダウン数字は出さない)。

---

## 2. Config の全キーと現在値(`ReplicatedStorage/Config.lua`)

### Config.Performance
| キー | 値 | 備考 |
|---|---|---|
| MaxTotalParts | 20000 | 生成直後の総パーツ数上限 |
| MaxUnanchoredParts | 1000 | 同時に物理挙動する瓦礫の上限 |
| DebrisLifetime | 8 | 瓦礫が透明化を始めるまでの秒数 |

### Config.Visual
| キー | 値 |
|---|---|
| Lighting.Brightness | 3 |
| Lighting.EnvironmentDiffuseScale | 1 |
| Lighting.EnvironmentSpecularScale | 1 |
| Lighting.ClockTime | 14 |
| Lighting.AtmosphereDensity | 0.35 |
| Lighting.AtmosphereHaze | 1.5 |
| TerrainEnabled | true |
| TerrainDecoration | true |
| BuildingPalettes | 3種(砂岩の家/コンクリビル/レンガの店。各material・wallColors×3・frameColor・roofMaterial・roofColor) |
| StoneWall.Enabled | true(**グリッドモードでは未使用**。従来モードのみ) |
| StoneWall.Spacing | 4 |
| StoneWall.Color | (150,148,140) |

### Config.Round
| キー | 値 | 備考 |
|---|---|---|
| LobbyTime | 3 | |
| BattleTime | 120 | 基礎値。`RoundClock`がこれを起点に増減する |
| BattleTimeMax | 300 | ハードキャップ。`RoundClock.Add`で加算してもこれ以上は増えない |
| BattleTimeFloor | 15 | 下限フロア。`RoundClock.Add`で減算してもこれ以下には下がらない |
| ResultTime | 10 | **未使用**(2026-07-31〜)。RESULTが「次へ」ボタンによる手動進行になったため参照されなくなった。削除はせずコメント付きで残している |
| ResultTimeout | 120 | 「次へ」が押されなかった場合に自動でLOBBYへ進むまでの秒数(安全弁) |

### Config.Block / Config.RowsPerStorey
| キー | 値 | 備考 |
|---|---|---|
| Block.Size | Vector3(8, 4, 2) | 街の軽量化のためX/Yを旧値の2倍に拡大済み |
| Block.ColorJitter | 16 | |
| RowsPerStorey | 2 | Block.Y拡大に連動して旧値5から半減 |

### Config.City
| キー | 値 | 備考 |
|---|---|---|
| RoadWidth | 16 | グリッドモードでも共用 |
| RoadLength | 240 | **従来モードの`buildRoads`専用**。グリッドモードは`GRID_TILESIZE`から自前で長さを計算するため未使用 |
| SidewalkWidth | 4 | |
| SidewalkHeight | 0.5 | |
| Templates | 8種(下表) | 両モード共通で使用 |
| Slots | 13エントリ | **従来モード専用**(`USE_GRID_MODE=false`のときのみ参照)。グリッドモードでは`generateGridSlots()`が別途スロットを算出するため無関係 |
| StoreyJitterChance | 0.35 | |
| MaxStoreys | 8 | |

**Config.City.Templates(建物テンプレート8種)**

| name | sizeX | sizeZ | storeys | pattern |
|---|---|---|---|---|
| 小屋 | 16 | 20 | 1 | standard |
| 店舗 | 24 | 12 | 1 | storefront |
| 中型ビル | 32 | 28 | 2 | standard |
| 大型ビル | 40 | 36 | 3 | wide |
| 高層ビル | 24 | 20 | 8 | wide |
| 学校 | 48 | 20 | 3 | storefront |
| タワーマンション | 32 | 28 | 6 | standard |
| 大型商業施設 | 48 | 28 | 4 | storefront |

寸法規約: `sizeX`はブロック幅(8)の倍数、`sizeZ`は`(sizeZ-4)`が8の倍数になる値。ズレると壁が区画いっぱいまで届かず隙間ができる。

### Config.Handmade
| キー | 値 |
|---|---|
| FolderName | "BuildingTemplates" |
| MinParts | 10 |
| MaxPartSize | 8 |

### Config.Weapons
| 武器 | DisplayName | SlotKey | Radius | Cooldown | その他 |
|---|---|---|---|---|---|
| Bazooka | バズーカ | 1 | 12 | 0.3 | Speed=100, MaxDistance=140, AutoFire=true |
| Airstrike | エアストライク | 2 | 12 | 20 | Delay=3, DropHeight=80, FallTime=1.1, 絨毯爆撃の各キー(下表) |
| RemoteBomb | リモート爆弾 | 3 | 15 | 1 | MaxBombs=10, MaxPlaceDistance=50, ChainBonus(下表) |

`Config.WeaponOrder = { "Bazooka", "Airstrike", "RemoteBomb" }`

**Config.Weapons.Bazooka(Step4dで射程制限・連射に作り替え)**

| キー | 値 | 意味 |
|---|---|---|
| MaxDistance | 140 | 最大飛距離。旧400。根拠は§12-7 |
| Cooldown | 0.3 | 連射間隔(秒)。旧0(実質無制限連打) |
| AutoFire | true | 押しっぱなしで連射するか。Airstrike/RemoteBombには付けない(単発のまま) |
| Speed | 100 | 弾速(stud/s)。**変更なし** |
| Radius | 12 | 爆発半径(stud)。**変更なし** |

`AutoFire`は「真の武器だけ連射する」という汎用の分岐として`WeaponClient`に実装されている
(武器固有の分岐ではない)。射程端(`MaxDistance`到達)で弾はその場で通常どおり爆発する
(`Explode`呼び出しがループの外にあるため、命中でも射程到達でも同じ1行を必ず通る)。

**Config.Weapons.Airstrike(Step4cで絨毯爆撃に作り替え)**

編隊が1本の爆撃線の上を通過しながら順に投下する。`Cooldown`が20秒と長い代わりに
1回の破壊量が大きい(1入力あたりの破壊量を上げてクリック疲れを減らすのが狙い)。
**旧`BombCount`(5)・`Scatter`(15)は削除**(散布方式ではなくなったため意味を失った)。

| キー | 値 | 意味 |
|---|---|---|
| Radius | 12 | 爆弾1発の爆発半径 |
| Cooldown | 20 | 1ラウンド120秒なので約6回使える |
| Delay | 3 | マーカー表示から第1弾の投下までの秒数 |
| DropHeight | 80 | 爆弾の落下開始高度(戦闘機の飛行高度でもある) |
| FallTime | 1.1 | 落下にかかる秒数 |
| PlaneCount | 3 | 編隊の機数 |
| BombsPerPlane | 6 | 1機あたりの投下数(合計18発) |
| BombInterval | 0.08 | 投下の時間差(秒)。**戦闘機の速度はここから導出される**(§12-4) |
| LineLength | 120 | 爆撃線の長さ |
| LineWidth | 20 | 編隊の横幅(機の間隔 × 2) |
| Sequential | true | true=1発ずつ順に掃射 / false=PlaneCount機が横並びで同時 |
| MaxRealPerBomb | 30 | 1発あたりの物理化上限。既定(`Config.Debris.MaxRealPerExplosion`)と同値=絞らない |
| PlaneLead | 60 | 線の始点手前/終点先へ延長する助走・余韻の距離 |
| PlaneParts | 5 | 1機あたりのパーツ数(見積り用。コードは参照しない) |

**`PlaneSpeed`というキーは持たない。** 速度は`LineLength / ((投下数-1) * BombInterval)`で
導出する(理由は§12-4)。

**Config.Weapons.RemoteBomb.ChainBonus(Step4bで追加)**

同時起爆した個数に応じたスコア倍率。`min`が「その倍率になる最低個数」。
`WeaponServer.chainMultiplier(count)`が**全件走査**して`min <= count`のうち最大の`min`のエントリを採用するため、
配列の並び順に依存しない(将来の編集で壊れない)。

| min(最低個数) | mult(倍率) |
|---|---|
| 1 | ×1(表示なし) |
| 3 | ×2 |
| 5 | ×3 |
| 8 | ×5 |

倍率が掛かる先は§12の`ctx.scoreScale`の契約に従う(ブロック破壊と市民NPC撃破のみ)。

`MaxPlaceDistance = 50`は設置可能な最大距離。**水平距離(XZ)のみで判定**し、Yは見ない
(3D距離にすると地上から高層ビルの壁面をクリックしたとき高さぶんで弾かれて理不尽になるため)。

### Config.Debris
| キー | 値 | 備考 |
|---|---|---|
| FadeTime | 1 | 瓦礫の透明化フェード秒数 |
| ImpulseSpeed | 120 | 吹き飛ばし速度の基準 |
| UpwardBias | 0.6 | 上方向への補正 |
| MinFalloff | 0.25 | 爆発端でも最低これだけの力 |
| MaxRealPerExplosion | 30 | 1爆発あたり物理化する本物パーツの上限 |
| DummyCount | 10 | 上限超過分を代替するダミー破片数 |
| DummyLifetime | 2 | ダミー破片の寿命(秒) |
| DummySize | Vector3(1.4,1.4,1.4) | |

### Config.NPC
| キー | 値 |
|---|---|
| Count | 10 |
| WalkSpeed | 5 |
| RespawnDelay | 4 |
| DespawnTime | 10 |
| WanderRange | 100 |
| Color | (85,200,100) ※後方互換フォールバック用 |
| SkinColor | (255,204,153)(頭・腕) |
| ShirtColor | (0,162,255)(胴体) |
| PantsColor | (60,60,70)(脚) |
| PanicRadius | 35 |
| PanicSpeed | 24 |
| PanicDuration | 8 |
| FleeFadeTime | 1 |
| PanicText | "help!" |
| BubbleMaxDistance | 150 |

### Config.Score
| キー | 値 | 備考 |
|---|---|---|
| Block | 10 | |
| NPC | 100 | |
| BuildingBonus | 500 | |
| BuildingBonusTime | 10 | 全壊時のタイム報酬(秒)。`RoundClock.Add`で共有タイムに加算。調整レバー優先順位1(THREAT_DESIGN_PROPOSAL.md §5-10) |
| BonusThreshold | 0.9 | |

### Config.Threat(★1〜)
| キー | 値 | 備考 |
|---|---|---|
| Enabled | true | falseで敵システム全体を無効化(切り分け用)。ThreatManagerの監視ループが即returnする |
| ScoreSource | "sum" | "sum"=全プレイヤーのスコア合計 / "top"=最高スコア。`WeaponServer.GetTotalScore()`が参照 |
| CheckInterval | 1 | 段階判定を行う間隔(秒) |
| DebugLog | true | 段階到達時刻・湧き・撃破をサーバーログに出す |
| CorpseDespawnTime | 6 | 撃破した敵の死体が消えるまでの秒数 |
| Retreat.Enabled | true | falseで昇格時の旧部隊撤退を行わない(切り分け用。Step5-0) |
| Retreat.FadeTime | 0.6 | 撤退開始から完全に消えるまでの秒数(Step5-0。§13-4参照) |
| Damage.Invincible | 0 | 被弾後の無敵秒数(プレイヤーごと)。**2026-07-31 実機フィードバックで2.0→0に変更**。体力表示が無いゲームで無敵中の被弾を無視すると「当たっているのに減らないバグ」に見えるため。理論ドレインは警官4人で-1.8秒/秒、★3の兵士8人では-10秒/秒になる。★3(Step6)で無敵時間の復活か`MaxLossPerMinute`のどちらかの再検討が必要 |
| Damage.DefaultTelegraph | 0 | 敵種別に`Telegraph`が無い場合の既定値(秒)。判定タイミングそのもの |
| Damage.BeamDuration | 0.2 | 赤い予告ビームが画面に残る秒数。判定とは無関係の見た目のみ |
| Damage.RequireLineOfSight | true | 建物に遮られていれば命中しない |
| Damage.RangeGrace | 1.1 | 着弾時の距離再判定でAttackRangeに掛ける猶予倍率 |
| Damage.MaxLossPerMinute | 0 | 直近60秒あたりの最大損失キャップ。★1検証完了により0(無効)に戻し済み(2026-07-31)。★3で再検討 |
| Damage.ComebackMultiplier | 1.5 | 残り時間僅少時の撃破報酬倍率 |
| Damage.ComebackThreshold | 25 | 残りがこの秒数を下回るとComebackMultiplierが効く |
| Spawn.MinDistanceFromPlayer | 100 | この距離以内には湧かせない |
| Spawn.Interval | 0.4 | 編成内で1体ずつ湧かせる間隔(秒) |
| Spawn.Jitter | 6 | 交差点中心から警官を散らす最大距離(stud)。上限8(道路幅16の半分)。大きくしすぎるとバズーカ1発でまとめて倒せなくなる(Step3手順6) |
| Marker.Enabled / MaxDistance / Text / Color | true / 300 / "!" / 赤 | 頭上マーカー(BillboardGui) |
| Indicator.Enabled / MaxDistance / PoolSize / UpdateInterval / Margin | true / 400 / 8 / 0.1 / 40 | 画面端の方向インジケータ(クライアント側) |
| EnemyTypes.PoliceOfficer / PoliceCar | (§末尾参照) | Step3完了により両方実装済み。Helicopter(Step5)/Tank(Step6)は未実装 |
| Stages[1] | ★1警察・Threshold=1000・Squad={PoliceCar×2, PoliceOfficer×2}・RespawnDelay=20 | 現状1件のみ。残りの警官はパトカーが道中で降車させる(§末尾参照)。★2/★3は未実装の敵種別を参照するため未登録(登録するとエラーになる) |

**Config.Threat.EnemyTypes.PoliceOfficer の内訳**

| キー | 値 |
|---|---|
| DisplayName | "警官" |
| Hits | 1 |
| HitCooldown | 0.25 |
| ApproachSpeed(AttackRange超) | 20 |
| MoveSpeed(AttackRange以内) | 13 |
| StopDistance | 80(Step3手順8で45から変更) |
| AttackRange | 100(Step3手順8で60から変更) |
| AttackInterval | 2.2 |
| Telegraph | 0(発砲と同時に着弾。★3の戦車等、重い攻撃には正の値を持たせる想定) |
| TimePenalty | 1 |
| ScoreReward | 300 |
| TimeReward | 0(Step3手順8で3から変更。理由は「Step3の設計判断」§9-2参照) |

**Config.Threat.EnemyTypes.PoliceCar の内訳(Step3で新設)**

輸送専用車両。プレイヤーを直接攻撃せず(`AttackType="none"`)、道路網(`Movement="road"`)を走行して警官を降車させる。

| キー | 値 | 備考 |
|---|---|---|
| DisplayName | "パトカー" | |
| Body | "car" | 見た目の作り分け用。人型とはパーツ構成が異なる |
| Hits | 3 | Step3手順8で2→(実機で5を試行)→3に確定。理由は「Step3の設計判断」§9-4参照 |
| HitCooldown | 0.25 | |
| Movement | "road" | 道路交点を経由してプレイヤーへ接近する専用AI |
| MoveSpeed / ApproachSpeed | 26 | 攻撃しないため2段速度は使わず同値 |
| StopDistance | 15 | 目的地(道路上の点)への到着判定距離。プレイヤーとの距離ではない |
| AttackType | "none" | 攻撃しない |
| TimePenalty | 0 | 接触ダメージ無し |
| ScoreReward / TimeReward | 500 / 8 | 撃破時の報酬 |
| SpawnY | 2.6 | 接地Y座標(車体半分の高さ。人型のSpawnY=3とは別体系) |
| DeployOnArrive | true | 目的地到着で警官を降ろす |
| DeployType | "PoliceOfficer" | 降ろす敵の種別 |
| DeployCount | 2 | 1回の降車で降ろす人数 |
| DeployRadius | 6 | 降車エフェクトの半径(Step3手順7)。降車位置の計算には使わない(ドア横固定のため) |
| DeployInterval | 10 | 次の降車までの最短間隔(秒) |
| MaxDeployTrips | nil(無制限) | 理由は「Step3の設計判断」§9-1参照 |
| DeployFallbackTime | 10 | 到着できないまま降車が解禁されてからこの秒数が経つと強制的に降ろす保険。**実装済み・未検証**(「Step3の設計判断」§9-8参照) |
| DeploySideOffset | 4.5 | 車の中心から左右へのオフセット(車体半幅3+余裕1.5) |
| DeployLongOffset | 2 | 車の前後方向のランダム幅(±この値) |
| LaneOffset | 4 | 道路中心線から進行方向左側へずらす距離(左側通行) |
| RetargetThreshold | 30 | 目的地を切り替えるヒステリシス(stud) |
| RetargetInterval | 1.0 | 目的地の再計算を行う間隔(秒) |
| TurnDuration | 0.25 | 曲がるときの向き補間にかける秒数 |
| WaypointRadius | 10 | 中間ウェイポイントの到着判定半径(「通り過ぎたか」を内積で判定する方式と併用。MoveSpeed*TurnDurationより大きくないと交差点を周回し続ける) |

### Config.Sounds
| キー | 値 | 備考 |
|---|---|---|
| Explosion | rbxassetid://165969964 | |
| Shot | rbxasset://sounds/Rocket shot.wav | |
| Whistle | rbxasset://sounds/Rocket whistle.wav | |
| Beep | rbxasset://sounds/electronicpingshort.wav | |
| NpcPop | rbxasset://sounds/snap.mp3 | |
| TimeGain | rbxasset://sounds/electronicpingshort.wav | タイム増加音(Beepと同じ内蔵音) |
| TimeLoss | ""(空文字) | 被弾音。Step2で使用開始。空文字は鳴らないだけでエラーにならない |
| Siren | ""(空文字) | 段階昇格音 |
| EnemyShot | ""(空文字) | 敵の発砲(はずれ)音 |
| EnemyDown | ""(空文字) | 敵の撃破音 |
| EnemyDeploy | ""(空文字) | パトカーの降車演出音(Step3手順7) |
| Jet | ""(空文字) | 戦闘機の飛行音(Step4c) |

### Config.RemoteNames
サーバー→クライアント: `RoundState` / `Effect` / `Result` / `Score` / `Cooldown` / `BombCount` / `Hud`(HUD演出指示。種別`"time"`はStep1、`"hit"`/`"threat"`はStep2、`"chain"`/`"notice"`はStep4aで使用開始。`"notice"`と`"chain"`は当事者だけに出す通知なので`FireAllClients`ではなく**`FireClient`**で送る)
クライアント→サーバー: `Fire` / `Action` / `Ready`(リザルト画面の「次へ」ボタン。2026-07-31追加)

(すべて`GameManager`が起動時に`ReplicatedStorage/Remotes`フォルダへ自動生成する。手作業配置は不要)

---

## 3. 街生成の仕組み(`CityGenerator.lua`)

### モード切替(ファイル冒頭のローカル定数。Configには出ていない)

```lua
local USE_GRID_MODE = true          -- ★本番。false=従来の十字路街(凍結中)
local GRID_SIZE = 4                 -- N×N街区
local TILE_BUILDINGS_PER_EDGE = 2   -- 1街区の1辺あたりの建物数(P)
local GRID_GAP = 12
```

### グリッドモードの計算式

```
maxTemplateDim()  = Config.City.Templates の sizeX/sizeZ の最大値 = 48(学校/大型商業施設)
GRID_BLOCKSPAN    = maxTemplateDim() * P + GRID_GAP  = 48*2+12 = 108
GRID_MAXSIZE      = floor(GRID_BLOCKSPAN / (2*P))    = floor(108/4) = 27
GRID_TILESIZE     = Config.City.RoadWidth + GRID_BLOCKSPAN = 16+108 = 124
```

`GRID_MAXSIZE`は「仕様どおりの`blockSpan/P`」ではなく`blockSpan/(2*P)`を採用している。
理由: 2棟×4辺を正方形の街区にそのまま詰めると、隣り合う辺の建物が街区の角で必ず重なる
(角の二重取り問題)。`blockSpan/(2*P)`にすることで角にクリアランスができ、重なりゼロを数値検証済み。

- スロット総数: `GRID_SIZE² × 4辺 × P = 4×4×4×2 = 128`
- 各街区の4辺それぞれに、辺の中央を基準にP棟を等間隔配置(`generateGridSlots()`)。建物の正面(rotationY)は辺ごとに道路側を向く(南辺=0°, 北辺=180°, 西辺=90°, 東辺=-90°)
- 各スロットの`maxSize`は一律`GRID_MAXSIZE`(=27)。この範囲に収まるテンプレートは「小屋」「店舗」「高層ビル」の3種のみ(他は27を超えるため選ばれない)
- 街全体は原点(0,0)中心。タイル(i,j)の中心 = `((i-(N-1)/2)*GRID_TILESIZE, (j-(N-1)/2)*GRID_TILESIZE)`

### 道路の作られ方(`buildRoadGrid`)

- 縦`GRID_SIZE+1`本・横`GRID_SIZE+1`本の車道を敷く(`k=0..N`、位置`(k-N/2)*GRID_TILESIZE`)
- 各道路の長さ = `N * GRID_TILESIZE + RoadWidth`(グリッド全体をカバー)
- 各道路の両脇に歩道(`swOff = RoadWidth/2 + SidewalkWidth/2`だけ中心からオフセット)
- 車道・歩道とも設置直後に`clearTerrainUnder`でTerrainの草を掘り、段差(崖)なくツライチにする。車道は`margin=2`、歩道は`margin=1`、共通`depth=6`
- **既知の簡易実装**: 歩道は全長ストレートなので交差点の上を素通りする(コーナー処理は未実装)

### 敵を沸かせる場所
- 街の外周座標 = ±(GRID_SIZE/2) * GRID_TILESIZE = ±248
- 道路の中心線 = (k - GRID_SIZE/2) * GRID_TILESIZE  (k=0..4)
           = -248, -124, 0, 124, 248

### グリッドモードの生成順序(`CityGenerator.Generate()`内)

1. `buildRoadGrid(map)` を**先に**実行(道路網を必ず完成させる)
2. `generateGridSlots()`で128スロットを計算し、`overBudget()`で打ち切られるまで`generateProceduralBuilding`を順に実行
3. 石垣(`buildStoneWalls`)・街小物(`buildProps`)・手作りテンプレート(`chooseBuildingSource`)は**呼ばれない**(7節参照)

### 従来モード(`USE_GRID_MODE=false`。凍結中・コードは温存)

`Config.City.Slots`(13棟)に沿って`buildRoads`(十字路1本)・`buildStoneWalls`(石垣)・`buildProps`(街灯12本/車6台/木9本/ベンチ2脚)・手作りテンプレート混在(`chooseBuildingSource`/`TemplateValidator`)まで一式実行する。コードは変更していないため、`USE_GRID_MODE`を`false`に戻せばそのまま動作する。

---

## 4. 破壊処理の流れ・瓦礫のハイブリッド方式(`DestructionManager.lua`)

全武器は`DestructionManager.Explode(ctx)`を呼ぶ以外の破壊経路を持たない。
`ctx`は`{position, radius, attacker, source, scoreScale?, maxReal?, bonusPolicy?, silent?}`の単一テーブル(必須は`position`/`radius`のみ)。

1. `Effect`リモートで`"explosion"`を全クライアントに送信(見た目の演出はEffectsClient側。この送信自体はダメージと無関係)
2. `workspace.Map`から`GetPartBoundsInRadius`(`OverlapParams`, `Include Map`, `MaxParts=2000`)で半径内のパーツを取得し、`"Destructible"`タグを持つものだけ`hits`に集める
3. `hits`を爆心からの距離で昇順ソート
4. **C案ハイブリッドの本体**: `realCap = clamp(min(ctx.maxReal or MaxRealPerExplosion, MAX_UNANCHORED - debrisCount), 0, #hits)`
   - `MaxRealPerExplosion`(30) = 1爆発あたりの本物瓦礫の上限。`ctx.maxReal`で武器ごとに上書き可(現状どの呼び出し元も指定しないため既定値のまま)
   - `MAX_UNANCHORED - debrisCount` = 瓦礫総数(全体で1000)の残り枠。枠が無ければ`realCap=0`になり自動的にダミーのみのフォールバックになる
5. 距離昇順で`i<=realCap`は`destroyBlockReal`(Anchored=false・CollisionGroup="Debris"・`SetNetworkOwner(nil)`・`applyBlastImpulse`で外向き+上向きの力・`enqueueDebris(DEBRIS_LIFETIME=8s)`)。それ以外(`excess`)は`destroyBlockExcess`(物理化せず`registerDestruction`のみ行って即`Destroy`)
6. `excessCount>0`なら`spawnDummyDebris(map, position, radius, min(DummyCount=10, excessCount))`——爆心付近にランダム散布した軽量パーツ(`CanCollide=false`)を固定数だけ生成し、本物と同じ`applyBlastImpulse`(速度スケール0.6)をかけて`enqueueDebris(DUMMY_LIFETIME=2s)`
7. `registerDestruction(part, ctx)`: `ctx.attacker`がいればスコア加算(`Config.Score.Block * (ctx.scoreScale or 1)`)。建物の`destroyed`は`ctx.attacker`の有無に関わらず必ずインクリメント(敵が壊した分も破壊率に含めるため)。`destroyed/total >= math.ceil(total * BonusThreshold(0.9))`かつ未受領なら、`ctx.bonusPolicy`(既定`"normal"`)が`"normal"`かつ`ctx.attacker`がいる場合のみ`BuildingBonus`加算 + `deps.addTime`があれば`RoundClock.Add(Config.Score.BuildingBonusTime, "building", ctx.attacker)`も同じ分岐内で呼ぶ(スコアとタイムを別分岐にしない。将来`bonusPolicy="deny"`を追加した際にズレが出ないようにするため)。`"collapse"`エフェクトは条件に関わらず発火(全壊は1棟につき1回)
8. 最後に`deps.blastListeners`配列の各関数へ`ctx`をそのまま渡して爆風を委譲(現状は`NPCManager.OnExplosion`のみ登録)

**瓦礫キュー**: 全瓦礫(本物+ダミー)は共通のFIFOキュー(`head`/`tail`インデックス)で`debrisCount`を管理。`debrisCount > MAX_UNANCHORED`(1000)になった瞬間、寿命に関係なく最古の瓦礫を`evictOldest`で即削除する。寿命が来た瓦礫は`TweenService`で`FadeTime`(1秒)かけて透明化してから削除(`fadeAndRemove`)。

**一括処理**: 1回の爆発でヒットした全パーツを1ループでまとめて処理する(順次崩落ではない)。

---

## 5. NPCの仕組み(`NPCManager.lua`)

- **構造**: Humanoid/Motor6D不使用。Torso/Head/LeftArm/RightArm/LeftLeg/RightLegの6 BasePartを`WeldConstraint`でTorsoに結合。徘徊中は全パーツ`Anchored=true`(物理コストゼロ)
- **見た目**: 部位別カラー(Head/Arms=SkinColor, Torso=ShirtColor, Legs=PantsColor)、四角い頭(Ball形状は使わない)
- **徘徊**: 全NPC共有の`RunService.Heartbeat`ループが`CFrame.lookAt`補間で`npc.target`(WanderRange内のランダム点)へ移動。到着(2stud未満)で次のランダム点へ
- **即死(`killNpc`)**: 爆心から`radius+2`以内で発生。Weldを2〜3個ランダム破壊(手足がもげる)→全パーツ`Anchored=false`・`CollisionGroup="Debris"`にして`ApplyImpulse`(固定式: 爆心逆方向+上向き0.6バイアス、力量`mass*60`。**`Config.Debris`とは独立した専用の固定値**)→`Config.Score.NPC`加算→`"npcKill"`エフェクト→`DespawnTime`(10秒)後にDestroy→`RespawnDelay`(4秒)後に別地点へ再スポーン
- **パニック(`startPanic`)**: 即死しなかったが`PanicRadius`(35)以内のNPCが対象。`panicUntil = os.clock()+PanicDuration(8s)`、`fleeing=true`をセットし、爆心と反対方向(水平)へ120stud先の目的地を設定(`WanderRange`でクランプ)。`raiseArms`(両腕を肩支点でARM_RAISE_ANGLE=140°回転させ再溶接)と`showHelpBubble`(あらかじめ用意済みの`BillboardGui`を`Enabled=true`にするだけ)を1回だけ実行。**既に逃走中なら`panicUntil`延長のみ**(二重処理・二重演出を防止。エアストライク連発対策)
- **パニック中の移動**: `Heartbeat`で`PanicSpeed`(24、通常`WalkSpeed`5の約5倍)を使用。目的地到着後も通常徘徊に戻さず、同じ`fleeDir`方向へさらに延長
- **フェード消滅(`fleeAway`)**: `panicUntil`経過で発火。`killNpc`とは別経路(スコア加算・ラグドール化・`npcKill`エフェクトなし)。`bubbleGui.Enabled=false`にしてから全パーツを`TweenService`で並行フェード(`FleeFadeTime`=1秒、1パーツずつ待たない)→`Destroy`→`RespawnDelay`後に再スポーン
- **help!フキダシ**: `BillboardGui`は**NPC生成時にあらかじめ1個作成済み**(`Enabled=false`)で`Head`に常設。パニック時は`Enabled`切替のみ(爆発の瞬間に複数NPC分のInstance生成が集中するのを回避)。`MaxDistance=BubbleMaxDistance`(150)で遠距離描画を抑制。中身は白い角丸Frame+`TextLabel`(`PanicText`="help!")+45度回転させた正方形Frame(尻尾)
- **頭数維持**: 即死経由・逃走消滅経由のどちらでも`RespawnDelay`後に`spawnNpc`が呼ばれ、常時`Count`(10)体を保つ
- **ラウンド制御**: `Init(deps)` / `Start()`(`Count`体スポーンし`active=true`) / `Stop()`(新規スポーン停止) / `Clear()`(パニック中・逃走中も含め全NPC即時Destroy)

---

## 6. 確定事項

- パーツ数上限: **`Config.Performance.MaxTotalParts = 20000`**
- グリッドモード(`GRID_SIZE=4`)の実測総パーツ数: **13,500〜15,500**(上限20,000に対して余裕あり)
- ブロックサイズ: **`Config.Block.Size = Vector3(8, 4, 2)`**
- グリッドサイズ: **`GRID_SIZE = 4`**(`CityGenerator.lua`内のローカル定数)
- タブレット実機での動作確認: **30fps維持を確認済み**(SETUP.md 6章の判定基準を満たす)

## 6-1. モード方針

**グリッドモード(`USE_GRID_MODE=true`)が本番。**
従来モード(`USE_GRID_MODE=false`、十字路1本+`Config.City.Slots`13棟)は**凍結**——コードは削除せず温存しているが、現在は使われていない。切り替えたい場合は`CityGenerator.lua`冒頭の`USE_GRID_MODE`を`false`にするだけで従来動作に戻る。

## 7. 未実装のまま保留(グリッドモード側)

グリッドモードでは以下を**意図的に未実装のまま保留**している(「まず建物と道路だけで動作確認する」方針のため):

- **石垣**(`buildStoneWalls`。関数自体は存在するが呼ばれない)
- **街灯・車・木**(`buildProps`。関数自体は存在するが呼ばれない。ベンチも含む)
- **手作りテンプレート**(`BuildingTemplates`。`chooseBuildingSource`/`placeTemplateBuilding`/`TemplateValidator`は従来モードのみで使われ、グリッドモードの建物選定は`generateProceduralBuilding`のみでプロシージャル生成に限定)

これらを組み込む場合は`CityGenerator.Generate()`のグリッド分岐(`if USE_GRID_MODE then ... end`)内に追加実装が必要。

## 8. 未実装のまま保留(敵システム側)

`THREAT_DESIGN_PROPOSAL.md`の段階的実装順序(§6)に沿って、以下を意図的に未実装のまま保留している:

- **警察ヘリ**(`Helicopter`。Step 5)
- **戦車**(`Tank`。Step 6。建物破壊・`bonusPolicy="deny"`・貢献度クレジット方式もここで実装)
- **★2・★3の`Config.Threat.Stages`エントリ**(未実装の敵種別を参照するため、実装が揃うまで登録しない)
- **`DestructionManager.Init`への`hudRemote`配線**(Step 6で戦車のボーナス奪取通知に使用)
- **敵の`Movement`種別**: `"direct"`(直進。警官)・`"road"`(道路網走行。Step3のパトカーで実装済み)は実装済み。`"air"`(Step 5のヘリ用)は未実装
- **レーダー(ミニマップ)**: 実装しない方針(頭上マーカー+画面端の方向インジケータの2本立てで代替)

---

## 9. Step 3 の設計判断

パトカー実装(Step 3)を通して、当初の設計値から実機フィードバックで変更した項目とその理由。
**数値だけでなく理由を残す**: 理由を伴わない数値は、後から見た人に「適当に決めた値」と誤解され、
根拠なく変更されることがあるため。

### 9-1. `PoliceCar.MaxDeployTrips = nil`(無制限。当初は`2`)

降車回数を使い切ったパトカーは攻撃してこないが、編成の全滅判定(`CountAlive(squadId)==0`)には
数えられ続けるため、**「無害な門番」**になっていた。結果、「使い切ったパトカーをわざと1台残せば
次の波が永久に来ない」という抜け道が成立していた。

無制限にすると、放置したパトカーは警官を延々と生み続ける。**放置コストがゼロから無限になり、
抜け道が塞がる。**

**この値を有限に戻す場合は、必ず上記の抜け道への対策(離脱して消滅する等)を同時に入れること。**

### 9-2. `PoliceOfficer.TimeReward = 0`(当初`3`)

**スコアは「進行度」、タイムは「生存」で意味が違う。** 敵がタイムを配ると、敵が脅威ではなく
「生存資源の配達人」になる。実機で「敵を待っていれば時間が増える」状態になっていたため、
タイム報酬のみを外した。

スコア(300)は残している。スコアが増えると★が上がって危険が増すため、**スコアを配ることは
「危険と引き換えの取引」として正しく機能する。**

### 9-3. `PoliceOfficer`の`StopDistance=80`/`AttackRange=100`(当初`45`/`60`)

車も警官もプレイヤーの至近距離に集まり、**遭遇の全体が1点に潰れていた。** 爆発1発で全部片付き、
プレイヤーが動く理由が無かった。警官を遠くに配置して面積を持たせた。

**注意: パトカーの`StopDistance`は`15`のまま**であり、車は依然としてプレイヤーの至近まで来る。
これは§11に未解決の課題として残している。

### 9-4. `PoliceCar.Hits = 3`(当初`2` → 実機で`5`を試行 → `3`で確定)

`MaxDeployTrips = nil`との組み合わせで考える必要がある。**車は警官の湧きを止める「スイッチ」である。**
スイッチが遠い(Hitsが大きい)ほど、止めるまでの間に警官が増え続け、クリック回数が加速度的に増える。

5は「敵が強い」ではなく「クリックが疲れる」という結果になったため3に下げた。**敵のHPを上げることは、
プレイヤーの腕力を通貨にして難易度を買うことに等しい。** 今後HPでバランスを取りたくなった場合は、
まずこの記述を読むこと。

### 9-5. `Spawn.Jitter = 6`(上限8)

**大きくしないこと。** 目的は「敵が2人いると目で分かる」ことだけであり、**同じ交差点に湧いた2人が
バズーカ1発でまとめて倒せる状態は維持すべき利点**である(クリック回数の削減につながる)。
散らしすぎると手数が増えて改悪になる。道路幅16(中心から±8)なので、8を超えると道路外・建物内に湧く。

### 9-6. 被弾フラッシュを`Hits > 1`の敵だけに付ける理由

`Hits = 1`の敵は1発で死ぬため、フラッシュが出る状況が存在しない。また`Highlight`には
同時描画数の上限(概ね31)があるため、無駄に消費しない。

**全敵に付けたくなった場合は、`Highlight`ではなくパーツの`Color`書き換え方式に切り替えること。**

### 9-7. 降車エフェクトを地味に保つ理由

`MaxDeployTrips = nil`かつ`DeployInterval = 10`でパトカーは2台。**平均5秒に1回**この演出が出る。
カメラシェイクや大きな効果音を付けると、爆発・全壊・タイム増減といった既存の演出が埋もれる。

### 9-8. `DeployFallbackTime = 10`は「実装済み・未検証」

「到着できないまま10秒経ったら強制的に降車する」保険。

**通常のプレイでは発火しない。** パトカーの`MoveSpeed`(26)はプレイヤー(16)より速く、`StopDistance`も
15と短いため、車は必ず到着する。実機テストでもログは観測されていない。したがって
**「動作確認済み」ではなく「実装済み・未検証」として扱うこと。** この保険の本来の出番は
「車が瓦礫や地形に引っかかって到着できない」といった異常系であり、狙って再現できない。

**発火した場合の読み方**(ログ: `[EnemyManager] PoliceCar 強制降車(未到着) trip=N dist=NN`):

| dist | 意味 | 対応 |
|---|---|---|
| 50以下 | 実害なし | 放置してよい |
| 150以上 | 車がプレイヤーに追いつけていない | `MoveSpeed`を見直す |

---

## 10. Step 4 前に無効化されている測定値

Step 4(武器改修)は絨毯爆撃・リモート爆弾の連鎖・バズーカの射程を変更するため、**Step 3時点の
バランス測定はすべて無効になる。** Step 4完了前にこれらを調整しないこと。

| # | 項目 | 現状 | Step 4後に何をするか |
|---|---|---|---|
| 1 | `Stages[].Threshold`(★の閾値) | ★1=1000のみ登録 | 到達時刻を再測定。現在、警官が無制限に湧くため撃破スコアが無限で、★の上昇が「街の破壊」ではなく「警官狩り」で決まる状態になっている。設計意図(破壊が進行度の主役)と逆転している |
| 2 | タイム収支 | 建物を壊しながら警官を捌いてトントン | 武器の出力が変わると全部ずれる。1ラウンドの平均終了時刻を再測定 |
| 3 | 1ラウンドあたりのクリック回数 | 「腕が疲れる」水準 | Step 4の絨毯爆撃・連鎖は「1入力で大量処理」の武器であり、クリック疲れの本命の対策。改善したか必ず確認する |
| 4 | `Damage.Invincible` / `MaxLossPerMinute` | どちらも0(無効) | ★3(Step 6)で再検討。★1では不要と判断済み |
| 5 | `Config.Round.BattleTime = 120` | 未再判断 | `THREAT_DESIGN_PROPOSAL.md` §5-9の基準(平均終了時刻150秒未満なら据え置き等)で判断 |

---

## 11. Step 3 で判明した未解決の課題

**どれもStep 3では対応しないと決めたものであり、忘れると同じ議論を繰り返すことになる。**

### 11-1. プレイヤーが移動しない(最優先。**Step 4dで対応済み**)

現状、プレイヤーはほぼ立ったまま1ラウンドを終えられる。原因は2つ。

1. ~~**バズーカに射程制限が無い。** 街は496stud四方で、中央に立てば全域に届きうる~~
   → **Step 4dで`MaxDistance`を400→140に変更。対応済み**(§12-7)
2. **パトカーの`StopDistance = 15`。** 標的の方からプレイヤーの至近まで来るため、車も警官も
   まとめて1発で処理でき、動く理由が生まれない。**これは未対応のまま残っている**

Step 4dでバズーカの射程制限と同時に連射(押しっぱなし)も入れた。射程だけ入れて連射を
入れないと「同じクリック回数に歩く手間が上乗せされる」だけで体験が悪化するため、
必ず同じコミットで対応した(§12-7)。

### 11-2. アイテムドロップ構想(未着手)

建物破壊時にアイテムを落とし、移動を促す案。**Step 4完了までは設計しないこと**(ドロップの中身は
武器と直結するため、武器が変わる前に決めると作り直しになる)。

**落とすものに「時間」を選んではいけない。** §9-2で警官のタイム報酬を外して「敵は時間の供給源では
ない」と整理した直後に、供給源が瓦礫に移るだけになる。

有力案は**武器の出力**(絨毯爆撃1回分など)。拾いに行くので移動が生まれ、拾えば1タップで大量処理
できるのでクリック疲れも同時に緩和される。

### 11-3. 構造崩落(判断保留)

引き継ぎ済みの課題。B+C案(閾値ベースの崩落+崩落分の減点)が推奨だが、A案(微小崩落)を実機で
試して、浮いた構造物の見た目がどれだけ気になるかを先に判断する。

### 11-4. `Helicopter` / `Tank`が未実装

`Config.lua`にはまだエントリが無い(`EnemyTypes`内にコメントで「Step5/Step6で追加する」と
記載があるのみ)。**未実装の種別名を`Stages`に登録するとエラーになる。** ★2以降を有効化する際に、
`Config.Threat.EnemyTypes`への追加と`EnemyManager`側の対応実装(`Body`の妥当性チェック含む)が必要。

---

## 12. Step 4 の設計判断

### 12-1. `ctx.scoreScale` の適用範囲は「契約」であり、Configキーではない

連鎖ボーナスの倍率(`ctx.scoreScale`)をどの加点に掛けるかは、**コード上の約束事として固定されている。**
`Config`に`ChainAffectsBuildingBonus`のような切り替えキーは**置かない**。

| 加点 | 倍率 | 理由 |
|---|---|---|
| ブロック破壊(`Config.Score.Block` = 10点) | **掛ける** | 連鎖ボーナスの本体。1入力で大量処理できるようにしてクリック疲れを減らすのが目的 |
| 市民NPC撃破(`Config.Score.NPC` = 100点) | **掛ける** | 決定済み(`THREAT_DESIGN_PROPOSAL.md` §7-8) |
| 全壊ボーナス(`Config.Score.BuildingBonus` = 500点) | **掛けない** | 8連鎖で2,500点になり、★の閾値の設計が壊れる |
| 敵の撃破報酬(警官300点 / パトカー500点) | **掛けない** | 敵撃破スコアが無制限に伸びる既知の問題(§10-1)が悪化する |
| 撃破・全壊のタイム報酬(+8秒 / +10秒 など) | **掛けない** | 秒数に倍率を掛けるとタイム経済そのものが壊れる。**倍率の対象はスコアのみ** |

**実装上、「掛けない」は分岐ではなく「その加点箇所で`scoreScale`を参照していないこと」で実現している。**
したがって`DestructionManager`の全壊ボーナス行・`EnemyManager.killEnemy`のスコア行は、
`scoreScale`という変数を一切見ない。この契約は`DestructionManager.Explode`の定義位置のコメントにも
同じ内容が書いてある。

**Configキーにしなかった理由**: 読む場所のないキーは「`true`にすれば挙動が変わる」と誤読される
動かないスイッチになる。`Config`は実機で振る値を置く場所であり、**振らないと決めた設計判断は
仕様書とコメントに書く**、という方針による。

### 12-2. 設置距離の判定を水平距離(XZ)にした理由

`MaxPlaceDistance`の判定で`Y`を見ない。3D距離にすると、地上に立ったまま高層ビルの上の方の壁面を
クリックしたとき、**高さぶんが距離に加算されて弾かれる**。プレイヤーから見れば「目の前のビルなのに
置けない」という理不尽な挙動になるため、水平距離のみで判定する。

### 12-3. HUDに追加するラベルは必ず `Active = false` にする

`noticeLabel`は画面中央やや下(`0.62`)に出るため、**発射のためのクリック位置と重なる。**
`Active`が`true`のGuiObjectはクリックを吸うため、これを怠ると「表示中だけ武器が撃てない」という
極めて分かりにくい壊れ方をする。

過去に`DamageVignette`(全画面`Frame`)で同じ事故を一度踏んでおり、そのとき得た教訓を
HUD要素全般のルールに広げたもの。**新しいラベル・`Frame`を足すときは毎回`Active = false`を確認すること。**

### 12-4. 戦闘機の速度は「入力値」ではなく「導出値」

`Config.Weapons.Airstrike`に`PlaneSpeed`というキーは**置かない。**

```
runDuration = (総投下数 - 1) * BombInterval        -- Sequential=true
runDuration = (BombsPerPlane - 1) * BombInterval   -- Sequential=false
planeSpeed  = LineLength / runDuration
```

**理由**: 速度を独立した入力値として持つと、機影の動きと爆撃の進行がずれる。
実際、当初案(`PlaneSpeed = 220`)では飛行が0.82秒で終わるのに爆撃が約3.65秒続き、
**爆撃時間の8割で空に機影が無い**状態になっていた。絨毯爆撃に作り替えた意味が失われる。

導出方式なら、「先頭弾の投下時刻に線の始点上空」「最終弾の投下時刻に線の終点上空」を
通過することが構造的に保証され、戦闘機は常に爆発の`FallTime`秒ぶん先を飛ぶ。

同じ理由で、**投下地点も事前の等間隔グリッドではなく、飛行と同じ式
(`-half + planeSpeed * 投下時刻`)から逆算している。** グリッドを別に持つと、
機の実位置と投下点が一致しなくなる。

**余韻(機が飛び去る側)の距離は`PlaneLead + planeSpeed * FallTime`**。
機は爆発より`FallTime`秒先を飛ぶため、余韻を`PlaneLead`だけにすると
最終弾が着弾する前に機影が消える。

導出された速度が60未満または260超のときは`warn`を出す。特に`Sequential = false`は
`runDuration`が短くなって速度が上がりやすいため、この警告がチューニングの手がかりになる。

### 12-5. カメラシェイクは加算ではなく `math.max`

`addShake`は`trauma = math.max(trauma, amount)`であり、`trauma += amount`ではない。

**理由**: 絨毯爆撃(18発)やリモート爆弾の10連鎖では短時間に何度もここへ来る。
加算方式だと上限(1.2)に張り付いたまま減衰(`dt * 1.6`)が追いつかず、
**「ずっと最大強度で揺れ続ける」**ことになり酔う。

`max`なら「いちばん強い爆発の強度で揺れて、あとは自然に収まる」という意図した挙動になり、
**開始時刻を保持する条件分岐も要らない**(時間窓方式より状態が減るぶん壊れにくい)。

爆発音の間引き(`playSound`の`dedupeInterval = 0.1`)も同じ目的だが、こちらは
`Sound`インスタンスが大量に同時存在するのを防ぐためのもの。0.1秒という値は、
Step4dでバズーカが0.3秒間隔の連射になっても1発ごとに必ず鳴る余裕を持たせてある。

**どちらも爆発エフェクト全般に効かせている**(エアストライク専用にしていない)。
リモート爆弾の連鎖でも同じ問題が起きるため。

### 12-6. `MaxRealPerBomb = 30`(絞らない)

初期設計では12に絞る想定だったが、実機計測で「半径100 × 50発でもfpsが落ちない」ことが
確認されたため、絞らない方針にした。`Config.Debris.MaxRealPerExplosion`(30)と
`Config.Performance.MaxUnanchoredParts`(1000)がすでに全体を頭打ちにしているため、
武器側で追加の上限を設ける必要が無い。

**タブレット実機で30fpsを割った場合の対処順**: ①`MaxRealPerBomb`を30→12 →
②`Config.Performance.MaxUnanchoredParts`を1000→600。

### 12-7. バズーカの射程140とAとBを同じコミットに入れる理由(Step 4d)

`MaxDistance`を400→140にした根拠(変更しないこと):

- 警官の`AttackRange = 100`より短いと、一方的に撃たれる時間ができる
- 街のタイルは124stud刻み(道路中心線 -248 / -124 / 0 / 124 / 248)。1区画を道路際から
  片付けるのに必要な長さがおおよそ124〜140
- 140なら「1か所に立つ → 1区画を片付ける → 次の交差点へ移る」というリズムになり、
  街全体を回るのに6〜9か所の立ち位置が必要になる

**射程制限(A)と連射(B)は必ず同じコミットに入れる。** Aだけを入れると「同じクリック回数に
歩く手間が上乗せされる」だけになり、体験が今より悪化する(§11-1参照)。

射程端で弾がその場で爆発する挙動は元々実装済みだった(`Destruction.Explode`呼び出しが
`fireBazooka`のwhileループの外にあり、命中で`break`しても飛距離を使い切ってループを
抜けても同じ1行を必ず通る)。**Step 4dでは`Config`の数値変更のみで、この部分にコード変更は
無い。**

### 12-8. `COOLDOWN_UI_MIN = 0.5`をConfigに置かない理由(Step 4d)

0.3秒のクールダウンをそのまま表示すると、武器スロットが毎秒3回チカチカして目障りになる。
`Cooldown`が`COOLDOWN_UI_MIN`(0.5)未満の武器は、`WeaponServer.startCooldown`が
`Cooldown`リモートの送信自体を省略する(クールダウンの強制自体は必ず行う。抑制するのは
表示だけ)。

`COOLDOWN_UI_MIN`は`WeaponServer.lua`冒頭のローカル定数として定義してあり、**Configには
置かない**。§12-1で`ChainAffectsX`をConfigに置かなかったのと同じ方針で、実機で振る値では
なく「表示するかどうか」という表示上の判断だからである。

### 12-9. スコア内訳ログ(§6)は倍率ぶんを分けない(Step 4d)

リモート爆弾の連鎖ボーナス(`ctx.scoreScale`)は§12-1の契約どおりブロック破壊・市民NPC撃破の
スコアに掛かる。スコア内訳ログの`category`は、この**倍率が掛かった後の点数をそのまま**
`"block"` / `"npc"`に合算する(倍率ぶんを別枠に分けない)。このログは★閾値を再設定するための
測定用であり、実際にプレイヤーへ入ったスコアの内訳を見るのが目的のため、倍率を分離する必要が
無い。

内訳の合計(建物+全壊+市民+敵+その他)が`scoreValue.Value`(実際のスコア)と一致しない場合、
`WeaponServer.LogScoreBreakdown`は`warn`を1行出す。新しい加点箇所を追加した際に`category`を
渡し忘れると気づけるようにするための整合チェックであり、`"other"`バケットの可視化だけでは
拾えない(拾い漏れではなく引数自体を渡していないケースを検出する)。

---

## 13. Step 5-0 の設計判断

危険度昇格時に前段階の敵部隊をその場で行動停止させ、`Config.Threat.Retreat.FadeTime`秒で
フェードアウトさせる「撤退」処理を導入した(`ThreatManager.promote()` / `EnemyManager.RetreatSquad()`)。
敵種別・編成そのものは今回変更していない(★2・★3はまだ`Config.Threat.Stages`に登録されない)。

### 13-1. `ThreatManager`は昇格時に旧`currentSquadId`を撤退させる

`promote(n)`は`currentSquadId`を新しい値へ上書きする**前**に、上書き前の値を`previousSquadId`として
保存する。新段階への昇格処理(HUD通知・演出・新部隊派遣)を行ったうえで、`previousSquadId`が
存在し(★0からの初回昇格ではない)、かつ`Config.Threat.Retreat.Enabled`が真のときだけ、
`EnemyManager.RetreatSquad(previousSquadId)`を呼ぶ。段階番号を直接判定する`if n == 2 then`の
ような分岐は持たない。★2・★3でも同じ仕組みがそのまま動く。

### 13-2. `EnemyManager.RetreatSquad(squadId)`の責務

指定した`squadId`に属し、まだ生存している敵を対象に、次を行う(戻り値は撤退させた敵の数)。

1. `retiredSquads[squadId] = true`を最初に設定する(以降このsquadIdからの新規生成を防ぐ)
2. `enemies`を反復しながら削除せず、対象を一度配列へ集めてから処理する(取りこぼし防止)
3. 各敵について: `enemy.alive = false` → `Retreating`/`Dead`属性を`true`に → 頭上マーカーと
   被弾フラッシュを無効化 → 全`BasePart`の`CanQuery`/`CanCollide`を`false`に → `Transparency`を
   `FadeTime`秒かけて`1`へTween → `enemies`テーブルから除去 → `FadeTime`秒後に`Destroy()`を
   1モデルにつき1本の`task.delay`で予約

**撤退は撃破ではない。** `killEnemy()`は呼ばない。スコア・タイム・撃破数・撃破演出・撃破音・
死体は一切発生しない。

### 13-3. 撤退時は即座に非攻撃・非ターゲット化する

`enemy.alive = false`を撤退処理の最初に設定するため、既に予約済みのテレグラフ攻撃
(`task.delay(tg, function() resolveAttack(...) end)`)も、既存の`resolveAttack`内の
`if not enemy.alive or not aggressive then return end`チェックでそのまま無効になる。
この既存チェックへの変更は無い。パトカーも`enemies`テーブルから除去されるため、共有Heartbeat
ループ(`checkDeploy`経由の降車判定を含む)の対象外になり、撤退開始後は警官を追加で降ろさない。
撤退前に既に降ろされていた警官は親パトカーと同じ`squadId`を持つため、同じ`RetreatSquad()`呼び出しで
まとめて撤退する。

### 13-4. 撤退した敵は`Config.Threat.Retreat.FadeTime`秒で消える

初期値は`0.6`秒。撤退開始と同時に`CanQuery = false`になるため、フェード中の敵にバズーカを
撃つと弾はすり抜ける(意図した挙動)。長くするほど「見えているのに当たらない」違和感が増し、
短くするほど「突然消えた」ように見える。実機での採用値と理由は`PROGRESS.md`に記録する。

### 13-5. 撤退済み部隊からの遅延スポーンを防止する

`retiredSquads[squadId]`という集合を`EnemyManager`のモジュール状態として持つ。判定箇所は2つ:

- `spawnEnemy(typeName, position, squadId)`の冒頭(`systemDisabled`チェックの直後)。
  `DeploySquad`・`deployFromCar`のどちらの経路から呼ばれても、ここが最終防衛線になる
- `EnemyManager.DeploySquad()`の非同期生成ループ内3箇所(`task.spawn`開始直後・各個体を
  生成する直前・`task.wait`から戻った直後)。派遣の途中で昇格しても、残りの旧部隊を
  生成しなくなる

`retiredSquads`は`EnemyManager.Clear()`で`table.clear()`される。ラウンド境界で`squadId`が
1から再利用されるため、これを消し忘れると次ラウンドの新しい部隊が誤って撤退済み扱いになり、
一体も湧かなくなる。

### 13-6. 再派遣予約は段階昇格でも無効化される

`ThreatManager`に`roundToken`とは別の`respawnToken`を新設した。役割の違い:

| トークン | 無効化するもの |
|---|---|
| `roundToken` | ラウンドをまたぐ非同期処理(既存。変更なし) |
| `respawnToken` | 同じラウンド内で、段階変更前に予約された再派遣(`task.delay(RespawnDelay, ...)`) |

`cancelPendingRespawn()`(`respawnToken += 1; waitingRespawn = false`)を`promote()`の先頭・
`Start()`・`Stop()`・`Clear()`で呼ぶ。再派遣の`task.delay`コールバックは、発火時に
`roundToken`・`respawnToken`・`running`・`currentSquadId`・`stage`のすべてが予約時点と一致する
場合のみ実行する。**古いコールバックが無効化された場合、そのコールバック自身は`waitingRespawn`を
書き戻さない**(昇格側の`cancelPendingRespawn()`が既に新しい状態へ更新しているため、古い
コールバックが新しい状態を上書きしてはならない)。

### 13-7. 昇格直後の`CountAlive==0`誤判定窓について

`ThreatManager.monitorLoop()`は`promote()`の呼び出し直後、同じ反復内で
`CountAlive(currentSquadId) == 0`を判定する。`EnemyManager.DeploySquad()`は`task.spawn`で
非同期化されているが、**Robloxの`task.spawn`は最初のyield(`task.wait`)まで呼び出し元へ制御を
返さず同期的に実行する**ため、`squadList`の合計数が1以上であれば、`DeploySquad`の呼び出しが
返ってくる時点で最初の1体は既に`enemies`テーブルへ登録済みになる。したがって`promote()`直後の
`CountAlive`判定が0を観測することはなく、誤って再派遣が予約されることもない。この性質は
現行の全`Stage`定義(常に1体以上)で成立しており、追加の「派遣中フラグ」等の状態は導入していない。

`RetreatSquad()`自体は`TweenService:Create`(yieldしない)と`task.delay`(スケジュールのみ)
だけで構成されており、`promote()`内で他のコルーチンへ制御が渡ることはない。

### 13-8. `Config.Threat.Retreat.Enabled = false`の場合

`ThreatManager.promote()`側で`RetreatSquad()`の呼び出し自体を分岐でスキップする
(`EnemyManager.RetreatSquad()`の内部で`Enabled`を見て早期returnする方式にはしていない)。
理由は§12-1の`ChainAffectsX`と同じ方針: 呼び出し元で有効・無効を判断したほうが処理順を
追いやすく、「撤退処理を呼んだが内部で無視された」のか「そもそも呼んでいない」のかをログで
区別しやすい。`Enabled = false`のときは旧部隊の`squadId`・`enemies`登録がそのまま残るため、
旧部隊は移動・攻撃を続けたまま新部隊が追加で派遣される。

### 13-9. 画面端▲と頭上「!」を除外する条件

画面端▲(`UIController.client.lua`の方向インジケータ)は、既存の
`model:GetAttribute("Dead") ~= true`という条件のみで対象を絞っている。`RetreatSquad`は
撤退開始時に`Dead`属性を`true`にするため、**この既存条件だけで撤退中の敵は自動的に除外される。**
`UIController.client.lua`への変更は行っていない。`Retreating`属性はデバッグ・Explorerでの
目視識別・将来のクライアント拡張用のメタデータとして持たせているだけで、現状どのクライアント
コードからも読まれていない。

頭上「!」は、サーバー側で既存の`enemy.marker.Enabled = false`(`killEnemy()`と同じ手法)を
行うだけで消える。新しいRemoteEventは追加していない。

### 13-10. `spawnEnemy()`が撤退済み部隊に対して`nil`を返すこと

既存の呼び出し側2か所(`DeploySquad`内・`deployFromCar`内)はどちらも`spawnEnemy()`の戻り値を
使用していないため、`nil`が返っても後続処理に影響しない。呼び出し側へのガード追加は行っていない。
