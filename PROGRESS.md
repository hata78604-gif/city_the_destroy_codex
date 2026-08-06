# 実装経過(PROGRESS)

このセッションで行った改修の記録。Rojoでファイル→Studio自動同期している前提。

---

## 実装したもの

- `ReplicatedStorage/Config.lua` — 全ゲームバランス値の集約ファイル
  - `Config.Performance`: パーツ上限 10000→20000、`MaxUnanchoredParts`等
  - `Config.Block`: ブロックサイズ (4,2,2)→(8,4,2)。街の軽量化用
  - `Config.RowsPerStorey`: 5→2(ブロック拡大に連動)
  - `Config.City.Templates` / `Slots`: 建物テンプレート追加・寸法調整、街区スロット13棟ぶん定義
  - `Config.Debris`: 破片のC案ハイブリッド設定(`MaxRealPerExplosion`/`DummyCount`/`DummyLifetime`/`DummySize`)、吹き飛ばし力(`ImpulseSpeed`/`UpwardBias`)
  - `Config.NPC`: 部位別カラー(`SkinColor`/`ShirtColor`/`PantsColor`)、パニック逃走設定(`PanicRadius`/`PanicSpeed`/`PanicDuration`/`FleeFadeTime`/`PanicText`/`BubbleMaxDistance`)

- `ServerScriptService/Modules/CityGenerator.lua` — 街の手続き生成
  - 建物13棟+道路2本(十字路)の従来モード(`USE_GRID_MODE=false`)を維持したまま、N×Nグリッド街モード(`USE_GRID_MODE=true`)を追加(`generateGridSlots`/`buildRoadGrid`/`generateProceduralBuilding`)
  - 道路下のTerrainを掘って段差を無くす`clearTerrainUnder`(ツライチ化)
  - ブロックサイズ変更に伴い`buildWall`/`buildSlab`/`makeSkipFn`の寸法計算をベタ書き数値から`BW`/`BH`/`BD`(Config.Block.Size由来)ベースに汎用化

- `ServerScriptService/Modules/DestructionManager.lua` — 破壊・瓦礫処理
  - 爆発地点からの吹き飛ばし(`applyBlastImpulse`)、本物破片+ダミー破片のハイブリッド処理(`destroyBlockReal`/`destroyBlockExcess`/`spawnDummyDebris`)
  - 瓦礫のFIFOキュー管理・寿命フェード(既存の仕組みを流用)

- `ServerScriptService/Modules/NPCManager.lua` — 軽量NPC(Humanoid不使用)
  - 見た目をR6標準アバター風(部位別カラー・四角い頭)に変更
  - 破壊時パニック挙動: 即死しなかった近隣NPCが両手を挙げて逃走→約8秒後にフェード消滅(`startPanic`/`raiseArm(s)`/`fleeAway`)
  - `help!`フキダシを`BillboardGui`で自作(頭に常設、`Enabled`切替のみで表示制御)

- `ServerScriptService/Modules/WeaponServer.lua` — 武器サーバー処理
  - リモート爆弾の設置位置を「足元」から「マウスクリック位置(`Mouse.Hit.Position`)」に変更(`placeBomb`)

- `SETUP.md` — 動作確認チェックリストを上記変更に合わせて更新

---

## 暫定措置・妥協点

- **グリッド街モード(`GRID_SIZE=4`)は建物平均パーツ数の期待値ベースで概算(約15,000/上限20,000)**。テンプレートはランダム抽選のため、運が悪いと重量級テンプレ(高層ビル等)ばかり当たって上限を超える可能性がある。`overBudget()`による安全な打ち切りはあるが、実機で毎回同じ密度になる保証はない
- **グリッド街モードでは手作りテンプレート(`BuildingTemplates`)・石垣・街灯/車/木を生成しない**。「まず建物と道路だけで動作確認する」方針のため未実装(意図的な後回し)
- **グリッド街の歩道は交差点上を素通りする簡易実装**。見た目の作り込みは後回し
- **ブロック拡大に伴い窓・ドアパターンを簡略化**。`RowsPerStorey`が5→2に減ったため、旧来の「1階だけ広いガラス窓」という店舗特有の演出は無くなり、上階と同じ窓帯に統一(段数が少なすぎて表現できないため)
- **NPCの両手を挙げるポーズは厳密なアニメではなく固定角度(140°)の再溶接**。Motor6D不使用の軽量設計を維持するための割り切り
- **フキダシの尻尾は画像でなく45度回転させた正方形Frame**。「凝った画像は不要」という指示に沿った簡易実装

---

## ハマった点と対処

- **街を密集させた際の重なり判定で誤検知**: `maxSize`を建物のX/Z両方の半径として扱う粗いチェックでは、実際は重ならない配置が「重なっている」と誤判定された。実際のテンプレート寸法(向き回転を考慮した実寸)で再検証するPythonスクリプトを都度使い、正しく重なりゼロを確認してから採用した
- **グリッド街のスロット配置式(仕様書どおりの`maxSize=blockSpan/P`)だと四隅で必ず重なる**: 2棟×4辺を正方形の街区に敷き詰めると角のスロットが二重取りになる幾何学的な問題。数値シミュレーションで確認し、`blockSpan/(2*P)`に変更して重なりゼロを確認
- **ブロックサイズ拡大でテンプレート寸法とスロットの`maxSize`が噛み合わなくなった**: 「小屋」テンプレートをブロック幅8の倍数に丸める際、切り上げ(20→24)すると`maxSize=20`のスロットの候補がゼロになり`rng:NextInteger`がエラーになる組み合わせが発生。切り捨て(20→16)側に丸めて全スロットに候補が最低1つ残ることを数値確認してから確定した
- **中間フロア・屋根のY位置が旧来のベタ書き値(`+1`)のままだとブロック拡大でズレる**: `BH`(ブロック高)が2→4になったのに配置オフセットが固定値`1`のままだと床が壁にめり込む。`BH/2`ベースの計算に修正して解消
- **`help!`フキダシが表示されない**: `TextChatService:DisplayBubble()`はサーバーから呼んでも複製されず(クライアント実行前提のAPI)、`pcall`で握りつぶされてエラーも出ないまま無反応になっていた。`BillboardGui`をサーバーで生成してHeadに親子付けする自作方式に差し替えて解決(Instanceは通常どおりレプリケートされるため)

---

## 次ステップへの申し送り

- `USE_GRID_MODE=true`のグリッド街を実機(Studio)で1回生成し、出力ログの合計パーツ数が実際に20,000以内に収まっているか確認すること。超える場合は`GRID_SIZE`を3に下げる(コード内にコメントで手順を記載済み)
- グリッド街モードに石垣・街灯/車/木・手作りテンプレートを組み込む場合、`CityGenerator.Generate()`の`USE_GRID_MODE`分岐内に追加実装が必要(現状は建物と道路のみ)
- `clearTerrainUnder`の`marginXZ`/`depth`、`ROAD_TOP`は「たたき台」の数値。Studioで実際に段差・草の突き抜けを目視確認しながら微調整する前提
- NPCのパニック関連の`Config.NPC`の新規キー(`PanicRadius`等)は初期値のまま。プレイ感を見てバランス調整が必要になる可能性あり

---

## ユーザー手作業

- Studioで▶実行し、以下を目視確認:
  - グリッド街(またはUSE_GRID_MODE=falseなら従来の十字路街)が正しく生成されるか
  - 道路がツライチになっているか(段差・草の突き抜けがないか)
  - リモート爆弾がクリック位置に設置されるか
  - 建物破壊時の爆発演出・瓦礫の吹き飛び
  - NPCの見た目(標準アバター風)・パニック逃走・`help!`フキダシ・フェード消滅
- 上記確認後、`clearTerrainUnder`の`marginXZ`/`depth`、`ROAD_TOP`、`GRID_SIZE`、`Config.NPC`のパニック関連数値を好みに応じて微調整
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認

---

# 敵システム Step0〜2 の実装(2026-07-29〜07-31)

`THREAT_DESIGN_PROPOSAL.md`(敵システム設計提案書)に基づく実装。
Step 0(基盤整備)→ Step 1(タイム経済の可視化)→ Step 2(★1警官)の3ステップを
それぞれフェーズA(計画報告)→ユーザー承認→フェーズB(実装)の順で進めた。

---

## 実装したもの

### Step 0: 基盤整備(RoundClock新設・Explodeのctx化)

- `ServerScriptService/Modules/RoundClock.lua`(**新規**) — バトル残り時間の唯一の持ち主
  - deadline方式(`endsAt = os.clock() + 残り秒数`)。カウンタ方式にしなかったのは、`Add()`で
    時間を足し引きした瞬間にカウンタと実残り時間がずれるのを避けるため
  - `Start`/`Remaining`/`Add(delta, reason, player)`/`Stop`。`Add`は上限(`BattleTimeMax`)・
    下限フロア(`BattleTimeFloor`)をクランプし、実際に反映された秒数(`applied`)を返す
- `ServerScriptService/Modules/DestructionManager.lua`
  - `Explode(position, radius, attacker)` → `Explode(ctx)`(単一テーブル引数)に変更。
    呼び出し箇所はコードを読んで3箇所のみと確認済み(バズーカ/エアストライク/リモート爆弾)。
    後方互換シムは入れていない(移行漏れは即エラーになる方が安全という判断)
  - `deps.onNpcExplosion` → `deps.blastListeners`(配列)に変更。爆風の影響を受けるモジュールが
    複数になっても`GameManager`側の配列に1要素足すだけで済むようにした
  - 全壊ボーナスの帰属判定を`ctx.bonusPolicy`による明示分岐に書き直した(従来は
    `attacker==nil`のとき暗黙に加点されなかっただけの副作用だった)
- `ServerScriptService/Modules/NPCManager.lua` — `OnExplosion(ctx)`への追随のみ(冒頭3行の分解。本体ロジックは無変更)
- `ServerScriptService/Modules/WeaponServer.lua` — `Explode`呼び出し3箇所をctx形式に置換
- `ServerScriptService/Modules/CityGenerator.lua` — `GetRoadLines()`/`GetCityBounds()`を追加(生成ロジックは無変更。従来モードでは`nil`を返す)
- `ServerScriptService/GameManager.server.lua` — `RoundClock`の`require`/`Init`、`runPhase`のBATTLE部分を`runBattlePhase`(RoundClock駆動)に分離。LOBBY/RESULTは既存の`runPhase`のまま

### Step 1: タイム経済の可視化(敵はまだ出さない)

- `ReplicatedStorage/Config.lua` — `Config.Score.BuildingBonusTime`(全壊時のタイム報酬。既定10)、`Config.Sounds.TimeGain`/`TimeLoss`を追加
- `DestructionManager.lua` — 全壊ボーナス分岐に`deps.addTime`を1行追加(スコア加算と同じ`if`の中に置く。別分岐にすると将来`bonusPolicy="deny"`で「スコアは入らないが時間は増える」というズレが生まれるため)
- `GameManager.server.lua` — `RoundClock.Init`の`onChange`で、タイムが動いた瞬間に`RoundState`を即時再送信+`Hud "time"`/`Effect "timeGain"or"timeLoss"`を送信(`applied`が実際に0のときは送らない)
- `StarterPlayer/StarterPlayerScripts/UIController.client.lua`
  - `Hud`リモートの購読、タイマーの色フラッシュ(`flashTimer`。世代トークンで多発時の色戻し競合を防止)、「+10秒!」フローティング(`spawnFloater`/`queueTimeFloater`。0.25秒でコアレスして同時多発時に1つにまとめる)
  - 全画面の赤フラッシュ`Frame`(`DamageVignette`)を常設。**`Active=false`が必須**(でないと入力を吸って武器が撃てなくなる)
- `StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua` — `"timeGain"`/`"timeLoss"`の音を追加。UI由来の音は3D減衰させたくないため`data.position or camera.CFrame.Position`でカメラ基準に鳴らす

### Step 2: ★1(警官)の実装

- `ServerScriptService/Modules/EnemyManager.lua`(**新規**) — 敵の実体
  - `NPCManager`の軽量設計(Humanoid不使用・全パーツAnchored・共有Heartbeat)を手法としてコピー(`NPCManager`自体は無変更)
  - 個体生成は`spawnEnemy(type, position, squadId)`の単一入口に統一(squadIdの付け忘れを構造的に防止)
  - 湧き位置: `CityGenerator.GetRoadLines()`の直積(道路交点)から、プレイヤーに一番近い側で`MinDistanceFromPlayer`以上離れた点を選ぶ(候補ゼロなら最遠点にフォールバックし、湧かないという結果にはしない)
  - 移動: `AttackRange`を境に`ApproachSpeed`(遠距離・駆けつけ)/`MoveSpeed`(交戦中)の2段階
  - 攻撃: テレグラフ(赤い予告ビーム)発火 → `Telegraph`秒後に**着弾時点の状態で**距離・遮蔽を再判定してから命中判定(建物の陰に走り込めば回避できる)
  - 撃破: `NPCManager.killNpc`と同じ手法でラグドール化(`CollisionGroup="Debris"`を流用・新規登録なし)。死体は`CanQuery=false`にする(バズーカのレイキャストを死体が遮る事故の防止)。`DestructionManager`の瓦礫キューには入れず、自前のタイマーで消す
  - `CityGenerator.GetRoadLines()`が`nil`/空を返した場合(従来モード等)は`warn`を1回出して自身を無効化し、以降は静かにno-op
- `ServerScriptService/Modules/ThreatManager.lua`(**新規**) — 段階(★)の政策
  - `Config.Threat.Stages`を**index昇順に走査するだけ**(段階固定の`if`分岐を持たない。★4を配列に足すだけで動く設計)
  - 編成の全滅(`CountAlive(squadId)==0`)を検出したら`RespawnDelay`秒後に次の編成を派遣。`waitingRespawn`フラグで二重派遣(CheckIntervalが1秒のため、無いと20回派遣される)を防止
  - `roundToken`によりラウンド境界をまたいだ`task.delay`コールバックを無効化(待機中にラウンドが終わった場合に次ラウンドのLOBBY中へ派遣されるのを防ぐ)
- `RoundClock.lua` — 損失キャップ(直近60秒あたりの最大損失)を実装。`deps.maxLossPerMinute`(`Config.Threat.Damage.MaxLossPerMinute`を`GameManager`経由で注入)。deadline方式・既存2クランプ・`running`ガードは無変更
- `ReplicatedStorage/Config.lua` — `Config.Threat`新設(`Enabled`/`ScoreSource`/`Damage`/`Spawn`/`Marker`/`Indicator`/`EnemyTypes.PoliceOfficer`/`Stages`(★1のみ1件))。`Config.Sounds`に`Siren`/`EnemyShot`/`EnemyDown`追加
- `GameManager.server.lua` — `EnemyManager`/`ThreatManager`の`require`/`Init`、`blastListeners`に`EnemyManager.OnExplosion`追加、ラウンドループに`ThreatManager.Clear/Start/Stop`・`EnemyManager.Clear`を差し込み(`WeaponServer.ResetScores()`は必ず`ThreatManager.Start()`より先に呼ぶ)
- `WeaponServer.lua` — `GetTotalScore()`を追加(★1昇格判定用。既存の`scoreValue.Value`をそのまま合計/最高で返すだけ)
- `UIController.client.lua` — ★インジケータ(`Hud "threat"`のdata.totalから件数を受け取り、`3`等をハードコードしない)、画面端の方向インジケータ(▲。`workspace.Enemies`をクライアントが直接読む読み取り専用の計算。サーバー通信は増やさない)
- `EffectsClient.client.lua` — 敵関連の演出6種(`enemySpawn`/`enemyAim`/`enemyShotHit`/`enemyShotMiss`/`enemyKill`/`threatUp`)を追加

---

## 暫定措置・妥協点

- **★1の閾値(`Config.Threat.Stages[1].Threshold = 1000`)は仮値**。連鎖ボーナス・絨毯爆撃(Step 4)でスコアの伸び方が変わるため、実測してから見直す方針であえて未調整のまま
- **損失キャップ(`MaxLossPerMinute = 20`)は動作検証のため有効化した状態**。`SETUP.md` Phase 7の受け入れ基準で動作確認したあと`0`(無効)に戻す運用が前提(§次ステップへの申し送り参照)
- **★2・★3の`Config.Threat.Stages`は未登録**。`PoliceCar`/`Helicopter`/`Tank`が未実装のため、登録すると閾値到達時にエラーになる。実装が揃うまで意図的に空けている
- **敵の`Movement`は`"direct"`(直進)のみ実装**。`"road"`(道路網走行。Step 3のパトカー用)・`"air"`(Step 5のヘリ用)は未実装
- **`EnemyManager.MoveSpeed = 13`はプレイヤーの`Humanoid.WalkSpeed`が既定値16である前提の数値**。コードベース上に上書き設定が見当たらないための推定であり、Studio上での実測は未確認
- **`DestructionManager.Init`への`hudRemote`配線は未実施**。Step 6(戦車がボーナスを奪った際の通知)まで不要なため後回し
- **`Hud`の`"chain"`/`"notice"`種別は未実装**。Step 4/Step 6で使用予定

---

## ハマった点と対処

- **RoundClockの`applied`(実際に反映された秒数)がfloat減算の結果、`9.999999999999998`のような端数を持つことがある**: UIのフローティング表示で`%d`フォーマットするとLuauがエラーを出しうるため、`math.round`で整数化してから表示するよう対処(Step 1で発見)。Step 2の被弾表示(-1秒)も同じ`spawnFloater`経路を通すことで、この保護を自動的に共有している
- **損失キャップのログ発火条件**: 当初案の「`applied`が0になったとき」だと、キャップ由来かフロア到達由来かが曖昧になるケースがあった。「損失予算(`budget`)が0以下になった瞬間」に条件を変更し、キャップが原因であることを確定的に判定できるようにした
- **全画面の赤フラッシュ`Frame`が入力を吸う事故を設計段階で回避**: `Active=false`を付け忘れると、クリックしても武器が一切反応しなくなるという分かりにくい壊れ方をする。実装前から要注意点として認識し、`SETUP.md`のトラブルシューティングにも明記した
- **バズーカの弾(レイキャスト)が敵の死体を素通りしない問題**: 生存中の敵は`CanQuery=true`(直撃判定に必要)だが、ラグドール化後も`true`のままだと死体が6秒間バズーカの弾を受け止めてしまい、建物を狙った弾が死体で爆発する。撃破処理内で`CanQuery=false`に切り替えて解決
- **`ThreatManager`の再派遣で二重・多重派遣が起きかけた**: 監視ループが1秒間隔で「生存者0」を検出し続けるため、ガード無しでは`RespawnDelay`(20秒)の間に最大20回派遣されてしまう。`waitingRespawn`フラグで一度だけの派遣に制限

---

## 次ステップへの申し送り

- **`Config.Threat.Damage.MaxLossPerMinute`を`20`→`0`に戻す**: `SETUP.md` Phase 7の「損失キャップの検証」を確認できたら実施し、Studioのテストを再起動する(Config変更はテスト再起動しないと反映されない)
- **プレイヤーの`Humanoid.WalkSpeed`の実値をStudioで確認**: `StarterPlayer.CharacterWalkSpeed`プロパティを見て、16以外なら`Config.Threat.EnemyTypes.PoliceOfficer.MoveSpeed`(現在13)を実値より2〜3小さい値に再設定する
- **★1の閾値実測**: `SETUP.md` Phase 7で確認した`[ThreatManager] ★1 警察 に到達`ログの秒数を記録しておき、Step 4(連鎖ボーナス・絨毯爆撃)実装後にスコアの伸び方を再測定してから閾値を調整する
- **Step 3(パトカー + 道路走行AI + 警官輸送)**: `EnemyManager`に`Movement="road"`(道路網を走行する経路)と、`Config.Threat.EnemyTypes.PoliceCar`(`DeployOnArrive`等で警官を降ろす)を追加する。パトカーが生きている限り編成が全滅扱いにならない設計(`squadId`の生存判定)が前提になるため、Step 2で作った`CountAlive`の仕組みをそのまま使う

---

## ユーザー手作業

- `SETUP.md` 4章 **Phase 6(タイム経済)・Phase 7(★1敵システム)** のチェックリストをStudioで上から順に確認する。特に「3武器すべてが撃てる」は敵を出す前に必ず確認すること(全画面Frameの設定ミスに気づきやすくするため)
- `StarterPlayer.CharacterWalkSpeed`の実値を確認し、上記「次ステップへの申し送り」のとおり必要なら`MoveSpeed`を調整する
- 損失キャップの動作確認後、`Config.Threat.Damage.MaxLossPerMinute`を`0`に戻してテストを再起動する
- タブレット実機で30fps維持を確認する(敵4人+爆発が重なる場面)
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認

---

# 敵システム Step3 の実装(パトカー。2026-08-01〜08-02)

`STEP3_POLICECAR_SPEC.md`を親指示書とし、`STEP3_TEJUN5_DEPLOY_SPEC.md`〜`STEP3_TEJUN8_DOCS_SPEC.md`の
各手順書に基づいて実装。手順ごとに独立してコミット・実機確認できる単位に分割して進めた。

---

## 実装したもの

### 手順1: 事前リネーム(挙動変更ゼロ)

- `EnemyManager.lua` — `enemy.torso`→`enemy.core`、`enemy.head`→`enemy.markerAnchor`にリネームし、未使用だった`leftArm`/`rightArm`フィールドを削除。将来の車両系(車・戦車)には「胴体」「頭」が存在しないため、人型前提の命名のまま拡張すると混乱を招くという判断による、純粋な名称変更のみのコミット

### 手順2: Config追加

- `Config.lua` — `Config.Threat.EnemyTypes.PoliceCar`を新設(この時点では`Body`の分岐が無いため`Stages[1].Squad`は一時的に`PoliceOfficer×4`のまま据え置き。`Body=="car"`が無い状態でパトカーをSquadに入れると`BodyColors.Shirt`参照でエラーになるため、手順3の実装後に改めてSquad構成を変更する2段階の手順にした)

### 手順3: パトカーの見た目 + 静止状態

- `EnemyManager.lua`
  - `spawnEnemy`に`etype.Body=="car"`分岐を追加し、`buildCarBody`(シャシー・キャビン・回転灯・前後アクスル)を新設
  - 接地Y座標をデータ駆動化(`etype.SpawnY`)。`Body`による分岐ではなく種別ごとの値として持たせ、Step5(ヘリ)で3つ目の分岐が増えないようにした
  - `updateDirectEnemy`(既存の直進AI)と`updateRoadEnemy`(道路走行AI。この時点では中身が無いno-opスタブ)に処理を分割

### 手順4: 道路網移動AI(本実装)

- `EnemyManager.lua`
  - `computeTargetPoint`: 追跡中のプレイヤー位置を、縦道路・横道路のうち近い方へ投影して目的地点を決定
  - `buildRoute`: 現在いる道路軸×目的地の軸の組み合わせで最大3レグのマンハッタン経路を構築
  - `computeLegDriveTarget`: レグごとに`LaneOffset`(左側通行)ぶん車線をずらした走行目標点を算出
  - 目的地の再計算に`RetargetThreshold`によるヒステリシスを設け、わずかな位置変化のたびに経路が組み直されるのを防止
  - `TurnDuration`による向きのLerp補間(即時スナップにしない)

### 手順4後の不具合修正(交差点での周回)

- **症状**: パトカーが交差点にたどり着いても停止・旋回を続け、いつまでも先に進まない
- **原因の特定**: ユーザー自身が`LaneOffset`を4→0に変更する切り分けを実施し、周回が止まることを確認。中間ウェイポイントの到着判定が単純な距離判定(2stud未満)だったため、車線オフセットで走行目標点がウェイポイントから常に`LaneOffset`ぶん離れたままになり、原理的に「到着」判定に到達できなかったことが確定
- **修正1**: 中間ウェイポイントの到着判定を、距離ではなく「通り過ぎたか」(`(目的地-現在位置)`と`legDir`の内積が0以下)で行う方式に変更。最終目的地(`targetPoint`)だけは従来どおり`StopDistance`のみの距離判定を維持(移動中のプレイヤーを追う性質上、「通り過ぎ」判定を入れると誤動作するため)
- **修正2**: `pruneShortLegs` — 経路構築直後、直前の点から`WaypointRadius`未満しか離れていないレグを除去。車は交差点に湧くため経路の1本目がほぼゼロ長になるケースがあり、それが方向ベクトルの不定化→周回の引き金になっていたため
- **修正3**: 車体モデルの前後が実際のRoblox仕様(`CFrame.LookVector`はローカル-Z)と逆向きだったのを修正。`AxleFront`をローカル-Z側に配置し直し、`updateRoadEnemy`の最終`CFrame.lookAt`も人型と同じ式(`newPos + facing`)に統一。指示書原文にあった「+Zが正面」という記述はユーザー自身の誤りだったと判明し、以後Step6(戦車)でも同じ道路移動コードを流用する前提でRoblox標準の−Z正面に統一した

### 手順5: 降車ロジック

- `Config.lua` — `DeployFallbackTime`/`DeploySideOffset`/`DeployLongOffset`を追加。`DeployRadius`は降車位置の計算に使わなくなったため、コメントを「降車エフェクト用」に書き換え(手順7向けに温存)
- `EnemyManager.lua`
  - `enemy`テーブルに`spawnedAt`/`tripsUsed`/`lastDeployAt`を全種別共通で追加(`Body`/`Movement`による分岐を増やさない)
  - `deployFromCar(enemy, isFallback)` — 車の左右ドア横(`DeploySideOffset`+前後ランダム`DeployLongOffset`)に警官を生成。**`squadId`を必ず引き継ぐ**(編成の全滅判定`CountAlive`が壊れないようにするための最重要ポイント)
  - `checkDeploy(enemy)` — 到着していれば即座に、到着できていなくても`DeployFallbackTime`秒経てば強制的に降車させる保険つきの判定。`updateRoadEnemy`の先頭(他の早期returnより前)で毎フレーム評価
  - 実装前に「編成の全滅判定が生存数の毎回カウント方式(A案)であること」を専用に調査してから着手(B案だった場合は実装しない、という事前ゲート付き)

### 手順6: 湧き位置の分散

- `Config.lua` — `Config.Threat.Spawn.Jitter = 6`を追加
- `EnemyManager.lua`
  - `pickSpawnPoint`に除外集合(`usedPoints`)を渡せるように変更。除外後に候補が尽きた場合は`MinDistanceFromPlayer`の方は諦めず、除外だけを諦めて`warn`を出す
  - `DeploySquad`内に**その1回の派遣に閉じた**`usedPoints`を持たせ、`Movement=="road"`の個体(パトカー)だけが書き込み・全種別が参照する形にした。パトカー同士は必ず別交差点、警官はパトカーの交差点を避けるが警官同士の重複は許容(★3で全個体に重複禁止を適用すると、残りの交差点が遠くにしか無くなり「部隊がまとまった波に見えない」問題が起きるため意図的)
  - 警官(`Movement != "road"`)には交差点中心から水平ジッター(角度一様・距離0.5〜1.0倍)を適用。パトカーにはジッターを一切かけない(車は道路線に正確に乗っている前提でAIが組まれているため)

### 手順7: 演出2種

- `EnemyManager.lua`
  - `deployFromCar`内で`enemyDeploy`エフェクトを送信(強制降車でも区別しない)
  - `spawnEnemy`で`etype.Hits > 1`の敵にのみ`Highlight`インスタンスを生成時に1個作成(`enemy.hitFlash`)。被弾して生き残ったときだけ0.12秒`Enabled=true`にする。撃破時・`HitCooldown`で無効化された被弾では発火しない
  - 被弾フラッシュの色は当初白で実装したが、パトカー車体がほぼ白(240,240,245)でコントラストが出ないというユーザー指摘によりオレンジ(255,90,40)に変更
- `EffectsClient.client.lua` — `onEnemyDeploy`を新設。青いリング(半径2→12、0.4秒でTransparency 1へ)を1個だけ生成して確実に`Destroy`。カメラシェイク・大きな効果音は追加していない(`MaxDeployTrips`無制限化により平均5秒に1回出る演出のため、既存の爆発演出を埋もれさせないように抑制)

### 手順8: ドキュメント更新 + Hits調整

- `Config.lua` — `PoliceCar.Hits`を`3`に変更(唯一のコード変更、のはずだった。詳細は下記「ハマった点」参照)
- `CURRENT_SPEC.md` — §2(Config全キー)を実際に`Config.lua`を読んで転記、§9(Step3の設計判断・8項目)/§10(Step4前に無効化されている測定値)/§11(Step3で判明した未解決の課題)を新設
- `SETUP.md` — パトカーの動作確認チェックリストを追加

---

## 暫定措置・妥協点

- **`PoliceCar.StopDistance = 15`は据え置き**。警官は`80`/`100`に引き上げてプレイヤーとの遭遇を分散させたが、車は依然としてプレイヤーの至近まで来る。Step4での射程調整とセットで再検討する未解決課題として`CURRENT_SPEC.md §11-1`に明記済み
- **`DeployFallbackTime`(強制降車の保険)は実装済みだが実機で発火未確認**。パトカーの`MoveSpeed`(26)がプレイヤーより速いため通常プレイでは発火条件に到達しない。`CURRENT_SPEC.md`には「動作確認済み」ではなく「実装済み・未検証」と明記
- **`MaxDeployTrips = nil`(無制限)により、警官の湧きは理論上無限**。★の閾値判定が「街の破壊」ではなく「警官狩り」のスコアで進んでしまう状態になっており、Step4完了後に測り直しが必要(`CURRENT_SPEC.md §10`)

---

## ハマった点と対処

- **交差点での周回バグ**: 上記「手順4後の不具合修正」参照。原因はレーンオフセットと到着判定方式の組み合わせによる幾何学的な必然で、`LaneOffset`を0にする切り分けをユーザーが自ら実施したことで確定した
- **車体モデルの前後が逆**: `CFrame.LookVector`はローカル-Z軸という仕様の誤認識(元の指示書に「+Zが正面」という誤記があった)。修正3で解消
- **手順8着手時、`Config.lua`の実際の値が指示書の前提と大きく食い違っていた**: 指示書は`PoliceCar.Hits`が「5」である前提だったが実際は「2」のままだった。さらに§2の転記作業中に、`PoliceOfficer.StopDistance`(想定80、実際45)/`AttackRange`(想定100、実際60)/`TimeReward`(想定0、実際3)、`PoliceCar.DeployInterval`(想定10、実際15)/`MaxDeployTrips`(想定nil、実際2)の**5箇所**も、指示書の設計判断の文章(§3)が前提としている値と食い違っていることが判明。これらはおそらくStudio上で試された変更が`Config.lua`にコミットされていなかったもの。ユーザーに確認のうえ、指示書の意図どおりの値に`Config.lua`を更新してから文書化した(「唯一のコード変更はHits」という当初の指示書の範囲を明示的に拡張する承認を得たうえでの対応)
- **`SETUP.md`のPhase番号・`CURRENT_SPEC.md`の章番号が指示書の前提とずれていた**: 指示書は「Phase 7を追加」「§3/§4/§5を新設」としていたが、実際には`SETUP.md`のPhase 7(★1敵システム)・`CURRENT_SPEC.md`の§3〜§8が既に埋まっていた。衝突を避けて実際の続き番号(Phase 8、§9/§10/§11)を採用した

---

## 次ステップへの申し送り

- **Step 4(武器改修)**: 絨毯爆撃・リモート爆弾の連鎖・バズーカの射程制限を実装する。バズーカの射程制限は`CURRENT_SPEC.md §11-1`の「プレイヤーが移動しない」問題への最優先の対策として位置づけられている(警官の`AttackRange=100`より短くしすぎないよう対で調整すること)
- **Step4完了後に測り直しが必要な項目一覧**は`CURRENT_SPEC.md §10`にまとめてある(★の閾値・タイム収支・クリック回数・`Damage.Invincible`等)
- **アイテムドロップ構想**はStep4完了まで設計しない(`CURRENT_SPEC.md §11-2`)。「時間」をドロップ対象にしない方針だけ先に決まっている

---

## ユーザー手作業

- `SETUP.md` 4章 **Phase 8(パトカー)** のチェックリストをStudioで上から順に確認する
- 特に「パトカー2台が必ず別々の交差点から湧く」「降車が車の左右ドア横に見える」「被弾フラッシュがオレンジで見やすいか」は実機の見た目でしか判断できないため重点的に確認する
- `DeployFallbackTime`の保険が実機でどうしても発火しない場合は仕様どおりなので問題なし。発火した場合はログの`dist`の値を見て`CURRENT_SPEC.md §9-8`の対応表に従う
- Rojoでの同期(`rojo serve`)を継続し、Studio側のRojoプラグインが接続されていることを確認
