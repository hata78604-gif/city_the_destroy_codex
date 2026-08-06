# 爆破訓練場(仮)セットアップ手順書

Roblox Studio にスクリプトを配置してゲームを動かすまでの手順書です。
プログラミングの知識がなくても、上から順にやれば動きます。

> **現在の本番はグリッド街モード**(`CityGenerator.lua`の`USE_GRID_MODE=true`、`GRID_SIZE=4`)。
> N×Nの街区を格子状に並べた街になっており、石垣・街灯・車・木・手作りテンプレートは
> グリッドモードではまだ組み込んでいない(意図的に保留中)。
> 従来モード(十字路1本+建物13棟+街灯・車・木+石垣。`USE_GRID_MODE=false`)は凍結中だが
> コードは残っており、いつでも切り替えられる。
> **現状の完全な仕様(Configの全キー・生成式・破壊処理・NPCの仕組み)は `CURRENT_SPEC.md` を参照。**
> 古い変更指示書(`roblox_destruction_game_spec.md`等)は `archive/` に移動済み。
> 各ステップ完了時、PROGRESS.md に「実装内容・暫定措置・ハマった点・申し送り・ユーザー手作業」を追記する

---

## 1. 新規プロジェクトを作る

1. Roblox Studio を起動する
2. 「新規作成」タブから **Baseplate** を選ぶ(何もない平らな地面のテンプレート)
3. 開いたら、まず `ファイル → 名前を付けて保存` でローカルに保存しておく

> **Explorer(エクスプローラー)ウィンドウが見えない場合**:
> 上部メニューの「表示」タブ →「エクスプローラー」をクリック。
> 同じく「プロパティ」も表示しておくと作業しやすい。

---

## 2. スクリプトの配置(全体図)

最終的に Explorer がこの形になれば完成です。**カッコ内が「種別」**です。
作るときに Script / LocalScript / ModuleScript を間違えると動かないので注意。

```
ServerScriptService
├─ GameManager          (Script)          ← GameManager.server.lua の中身
└─ Modules              (Folder)
   ├─ CityGenerator     (ModuleScript)    ← CityGenerator.lua の中身
   ├─ DestructionManager(ModuleScript)    ← DestructionManager.lua の中身
   ├─ EnemyManager      (ModuleScript)    ← EnemyManager.lua の中身
   ├─ NPCManager        (ModuleScript)    ← NPCManager.lua の中身
   ├─ RoundClock        (ModuleScript)    ← RoundClock.lua の中身
   ├─ TemplateValidator (ModuleScript)    ← TemplateValidator.lua の中身
   ├─ ThreatManager     (ModuleScript)    ← ThreatManager.lua の中身
   ├─ VisualSetup       (ModuleScript)    ← VisualSetup.lua の中身
   └─ WeaponServer      (ModuleScript)    ← WeaponServer.lua の中身

ReplicatedStorage
├─ Config               (ModuleScript)    ← ReplicatedStorage/Config.lua の中身
└─ BuildingTemplates    (Folder・任意)     ← 自分で作った建物Modelを入れる(7章参照)

StarterPlayer
└─ StarterPlayerScripts
   ├─ WeaponClient      (LocalScript)     ← WeaponClient.client.lua の中身
   ├─ EffectsClient     (LocalScript)     ← EffectsClient.client.lua の中身
   └─ UIController      (LocalScript)     ← UIController.client.lua の中身
```

> **メモ**
> - Studio 上の名前に「.lua」「.server」「.client」は付けません。
>   ファイル名のそれらは「どの種別で作るか」の目印です。
> - 指示書にあった `Config.lua` と `SharedConfig.lua` は、二重管理を避けるため
>   **ReplicatedStorage の Config 1つに統合**しています(サーバー・クライアント両方が参照)。
> - `Remotes` フォルダ(RemoteEvent 置き場)は **GameManager が起動時に自動生成**するので、
>   手作業で作る必要はありません。
> - 道路・街小物は毎ラウンド `workspace/Map` フォルダごと作り直します。削除対象は
>   Map フォルダに一元化してあるので、使い回し管理は不要です(小物には `CityProp` タグ付き)。

### 2-1. オブジェクトの作り方(共通操作)

1. Explorer で親にしたい場所(例: `ServerScriptService`)にマウスを乗せる
2. 名前の右に出る **⊕(プラス)ボタン** をクリック
3. 検索欄に `Script` / `LocalScript` / `ModuleScript` / `Folder` と入れて選ぶ
4. 作られたオブジェクトをクリックして **F2キー(または右クリック→名前の変更)** で名前を変える
5. スクリプトを **ダブルクリック** して開き、最初から入っているコード
   (`print("Hello world!")` など)を **全部消してから**、対応する .lua ファイルの中身を
   全選択(Ctrl+A)→コピー(Ctrl+C)→貼り付け(Ctrl+V)する

### 2-2. 配置の順番(おすすめ)

| 順番 | 親の場所 | 作るもの | 種別 | 貼り付けるファイル |
|---|---|---|---|---|
| 1 | ReplicatedStorage | Config | ModuleScript | ReplicatedStorage/Config.lua |
| 2 | ServerScriptService | Modules | Folder | (フォルダなので貼り付け不要) |
| 3 | Modules | CityGenerator | ModuleScript | ServerScriptService/Modules/CityGenerator.lua |
| 4 | Modules | DestructionManager | ModuleScript | ServerScriptService/Modules/DestructionManager.lua |
| 5 | Modules | NPCManager | ModuleScript | ServerScriptService/Modules/NPCManager.lua |
| 6 | Modules | WeaponServer | ModuleScript | ServerScriptService/Modules/WeaponServer.lua |
| 7 | Modules | VisualSetup | ModuleScript | ServerScriptService/Modules/VisualSetup.lua |
| 8 | Modules | TemplateValidator | ModuleScript | ServerScriptService/Modules/TemplateValidator.lua |
| 9 | Modules | RoundClock | ModuleScript | ServerScriptService/Modules/RoundClock.lua |
| 10 | Modules | EnemyManager | ModuleScript | ServerScriptService/Modules/EnemyManager.lua |
| 11 | Modules | ThreatManager | ModuleScript | ServerScriptService/Modules/ThreatManager.lua |
| 12 | ServerScriptService | GameManager | **Script** | ServerScriptService/GameManager.server.lua |
| 13 | StarterPlayerScripts | WeaponClient | **LocalScript** | StarterPlayer/StarterPlayerScripts/WeaponClient.client.lua |
| 14 | StarterPlayerScripts | EffectsClient | **LocalScript** | StarterPlayer/StarterPlayerScripts/EffectsClient.client.lua |
| 15 | StarterPlayerScripts | UIController | **LocalScript** | StarterPlayer/StarterPlayerScripts/UIController.client.lua |

> `StarterPlayerScripts` は `StarterPlayer` の中に最初からあります(新しく作らない)。

### 2-3. Lighting の手動設定(1回だけ・重要)

きれいなライティング(Future)は、**スクリプトから設定できない場合がある**ため手動で設定します:

1. Explorer で **Lighting** をクリック
2. プロパティウィンドウで **Technology** を探し、**Future** に変更
3. `ファイル → 保存` する。**設定はファイルに保存されるので、この作業は1回だけでOK**

> Technology は**スクリプトから変更できない**ため、この手動設定が必須です。
> その他のライティング(明るさ・時刻・霞み)と草地Terrainは VisualSetup が自動で設定します。
> なお「揺れる草」はRobloxのバージョンによってスクリプトから切り替えられないことがあります。
> 草が揺れない場合は、Explorer で **Terrain** を選び、プロパティの **Decoration** をオンにしてください。

---

## 3. テストプレイの方法

- 上部「ホーム」タブか「テスト」タブの **▶ プレイ** ボタンでソロテスト開始
- **F5キー** でも開始できる。終了は **Shift+F5** か ■ 停止ボタン
- **モバイル操作の確認**: 「テスト」タブ → 「デバイス」で
  タブレットやスマホの画面をエミュレートできる
- **複数人テスト**: 「テスト」タブ → 「クライアントとサーバー」で
  プレイヤー数を選んで「開始」

### 遊び方(操作方法)

| 操作 | PC | タブレット/スマホ |
|---|---|---|
| 武器切替 | 数字キー 1 / 2 / 3 | 画面下の武器スロットをタップ |
| 発射・設置(バズーカ) | クリック。**押しっぱなしで連射** | タップ、または「発射」ボタン**長押しで連射** |
| 発射・設置(エアストライク/リモート爆弾) | クリック(クリック地点に向けて撃つ) | 画面タップ、または右下の「発射」ボタン |
| リモート爆弾の起爆 | F キー、または「起爆」ボタン | 「起爆」ボタン |

---

## 4. Phase ごとの動作確認ポイント

スクリプトを全部配置したら、以下を順に確認していくと問題の切り分けがしやすいです。

### Phase 1: 建物を撃って崩せる
- [ ] プレイ開始から数秒で街(道路の十字路+建物+小物)が生成される
- [ ] 出力ウィンドウに `[CityGenerator] 生成完了(グリッド街 4x4): 建物ブロック ○○ / 石垣 ○○ / 道路・小物 ○○ / 合計 ○○` と出る(合計20,000以下。実測は13,500〜15,500程度)
- [ ] 「破壊せよ!」表示後、**1キー(バズーカ)**で建物をクリック → 弾が飛んで爆発し、壁が吹き飛ぶ
- [ ] 吹き飛んだ瓦礫が約8秒後にスーッと消える

### Phase 2: ラウンドが回る・スコアが入る
- [ ] 画面上部に残り時間、右上にスコアが表示される
- [ ] ブロックを壊すと 10点ずつ入り、右上のスコアがポコッと跳ねる
- [ ] 画面右上の Roblox 標準プレイヤーリストにも「スコア」が出る
- [ ] 120秒(タイム増減が無ければ)経つとリザルト画面(順位・建物破壊率)が出る
- [ ] リザルト画面右下の「次へ」ボタンを押すとマップが作り直されてロビーに戻る
      (押さなければ`Config.Round.ResultTimeout`(既定120秒)後に自動で進む)

### Phase 3: NPC
- [ ] ラウンド開始と同時に人形(肌色の頭・腕/青い胴/四角い頭のRoblox標準アバター風)が10体ウロウロしている
- [ ] 爆発に巻き込むと手足がもげて吹き飛び、+100点。10秒後に消える
- [ ] 数秒後に別の場所に新しいNPCが湧いて、常に10体前後いる
- [ ] 建物を壊すと、爆心付近のNPCは即死(従来通り)
- [ ] 即死しなかった半径35stud以内のNPCが、両手を挙げて `help!` の吹き出しを出し、破壊地点と反対方向へ速く逃げる
- [ ] 逃げたNPCは約8秒後にスーッと消え、別地点に新しいNPCが湧いて頭数が保たれる
- [ ] エアストライクで連続爆発させても、パニックが二重に走らずカクつかない

### Phase 4: 全武器 + UI
- [ ] **1キー(バズーカ)**: 街の中央に立って反対側の端の建物をクリックすると、弾が飛んでいって**手前の空中で爆発**する(建物は壊れない)。140stud以内は従来どおり壊せる
- [ ] マウス(タッチ)を**押しっぱなし**にすると、約0.3秒間隔で撃ち続ける。押したまま照準を動かすと爆発がなぞるように移動する。離すと止まる
- [ ] **武器スロットが0.3秒ごとにチカチカ暗転しない**(クールダウン自体は効いている。連射間隔以上の速さでは撃てないことを確認)
- [ ] **2キー(エアストライク/絨毯爆撃)**: 地面クリック → **赤い矩形**が点滅(自分からクリック地点へ向かう向き)→ 3秒後に戦闘機3機が飛来し、線に沿って爆発が走っていく(合計18発)。使用後**20秒**のクールダウン表示(スロットが暗転して秒数カウント)。**押しっぱなしで連射されない**(単発のまま)
- [ ] 戦闘機が爆発の少し先を飛んでいて、最後の爆発が起きる前に画面から消えていない
- [ ] 爆撃後に戦闘機が消える。`workspace`に残骸が残らない
- [ ] 予告矩形の外側で建物が壊れていない(矩形の範囲=実際の被害範囲)
- [ ] **3キー(リモート爆弾)**: クリックした地点に赤い球を設置(最大10個)→ Fキーか「起爆」ボタンで全部同時に大爆発。**押しっぱなしで連射されない**(単発のまま)
- [ ] モバイルエミュレータで、スロットタップでの武器切替と「発射」ボタンが効く。バズーカで**ボタン長押しが連射になる**。ボタンの外に指を滑らせて離しても止まる
- [ ] 押しっぱなしで連射しているとき、揺れが増幅して止まらなくならない
- [ ] 連射中、爆発音が1発ごとにきちんと鳴る(0.1秒デデュープに吸われない)
- [ ] ラウンド終了時、出力ウィンドウに `[Score]` の行が出る(建物/全壊/市民/敵の内訳 + 経過秒数)。次のラウンドでリセットされている

### Phase 5: 演出
- [ ] 爆発で火花・煙・閃光が出て、近くだと画面が揺れる
- [ ] 建物を90%以上壊すと +500点 と大きな粉塵が上がる
- [ ] バズーカ発射音・爆弾の落下音(ヒュー)が鳴る。絨毯爆撃では**「ヒュー」は1回だけ**鳴る(18回鳴らない)
- [ ] 絨毯爆撃の最中、画面の揺れが不快なレベルまで増幅しない(揺れが積み上がらず、一定の強さで揺れて自然に収まる)
- [ ] 爆発音が団子になって割れたりしない
- [ ] リモート爆弾10個を同時起爆したときも、揺れと音が同様に抑えられている

### Phase 6: タイム経済(敵はまだ出ません。「壊すと時間が延びる」ループの前半)

**まず既存機能が壊れていないことを先に確認する(特に「3武器すべてが撃てる」)。**
このステップは全画面の透明なFrameを追加しているため、設定を誤ると画面全体が
クリックを吸ってしまい「武器が一切撃てない」という分かりにくい壊れ方をする。

- [ ] **3武器すべてが従来どおり撃てる**(建物を壊す前に、まずこれを確認する)
- [ ] 武器スロットのタップ切替・クールダウン暗転・「起爆」ボタンが従来どおり効く
- [ ] モバイルエミュレータでも上記が効く
- [ ] 建物を1棟90%以上壊す → +500点と同時に**残り時間が10秒増える**
- [ ] タイマーの数字が緑に光り、少し拡大してから元に戻る
- [ ] タイマーの下に「+10秒!」が浮かび上がって消える
- [ ] タイム増加音が鳴る
- [ ] 数字の増加が**即座に**反映される(次の毎秒更新を待たない)
- [ ] エアストライクで複数棟を同時に全壊させたとき、フローティングが**合算されて1つだけ**出る(「+20秒!」など)。ラベルが重なって読めない状態にならない
- [ ] 短時間に連続で全壊させても、タイマーの文字色が緑のまま固まらず、最後に必ず元の色へ戻る
- [ ] 残り時間が300秒付近まで増えたとき、それ以上増えない(上限。増えた回のフローティングも実際の秒数だけを表示する)
- [ ] 残り時間が300秒でも `5:00` と正しく表示される
- [ ] **LOBBY中・RESULT中にタイムが動かない**
- [ ] 出力ウィンドウ(サーバー・クライアント両方)に赤いエラーが出ない

### Phase 7: ★1 敵システム(警官)

**敵を出す前に、まず既存機能の非破壊を確認する。**

- [ ] 3武器すべてがクリックで撃てる。爆発・破壊・スコア加算が従来どおり
- [ ] 建物90%破壊で +500点 と +10秒 が従来どおり出る
- [ ] 市民NPCの即死・パニック逃走・help!フキダシ・頭数維持が従来どおり
- [ ] ラウンド開始時、★インジケータ(タイマーの左)は**表示されない**(段階0では非表示)

**★1の昇格と湧き**

- [ ] 1,000点到達でテロップ「警察が出動した!」+ ★インジケータが現れて `★` になる
- [ ] 出力ウィンドウに `[ThreatManager] ★1 警察 に到達 (開始から ○○ 秒 / スコア 1000)` が出る(この秒数を控えておく)
- [ ] 敵が**道路の交差点**に、プレイヤーから100stud以上離れて0.4秒間隔で1体ずつ湧く(編成の内訳はPhase 8参照。パトカーが道中で追加の警官を降ろすため、最初に見える数と最終的な人数は一致しない)
- [ ] 湧いてから5〜10秒程度でこちらに到達して撃ってくる
- [ ] 画面外の敵の方向に▲が出て、振り向くと▲が消えて頭上の「!」に切り替わる
- [ ] タブレットエミュレータで▲と「!」が読めるサイズになっている

**交戦**

- [ ] 遠い間は速く走り、近づくと明らかに遅くなる。走って逃げれば距離が開く
- [ ] 警官の発砲は**赤い線と同時に着弾する**(遅延を感じない)。線は0.2秒ほど残ってから消える
- [ ] **建物の陰に立っていれば当たらない**(はずれ音のみ)。位置取りが唯一の防御手段になっている
- [ ] **無敵時間は無い**。複数の警官から立て続けに撃たれると、その都度必ずタイマーが減り赤くフラッシュする(「当たったのに減らない」瞬間が無い)
- [ ] 複数の警官が同時に発砲せず、ばらけて撃ってくる

**撃破と再出現**

- [ ] バズーカで倒すと +300点(**タイムは増えない**。警官のタイム報酬はStep3で意図的に0にしてあり、
      時間の供給源は建物の全壊とパトカーの撃破のみという設計。詳細は`CURRENT_SPEC.md` §9-2)
- [ ] 死体が6秒後に消え、「!」マークと▲が付かなくなる
- [ ] 編成が全滅してから20秒後に次の部隊が湧く(1回だけ。編成の内訳はPhase 8参照)
- [ ] （参考)警官の撃破ではタイムが増えないため、残り時間僅少時のタイム報酬倍率
      (`ComebackMultiplier`)は警官の撃破では確認できない。倍率を確認したい場合は
      建物全壊(+10秒)やパトカーの撃破(+8秒)で試すこと

**リザルト画面・「次へ」ボタン(2026-07-31追加)**

- [ ] 順位行に `(警察 N)` が出る。倒していなければ `(警察 0)`。敵を6体倒したら `6` と数が合っている
- [ ] サマリー行の「破壊した建物 N/128」「全体破壊率 N%」が実態と合っている
- [ ] 建物リストが3列で並び、破壊率の高い順になっている
- [ ] 0%の建物が個別に並ばず、最後に `その他 N棟: 0%` としてまとまっている
- [ ] 1棟も壊さずにラウンドを終えると `破壊された建物はありません` が出る
- [ ] タブレットエミュレータで建物リストの文字が読める
- [ ] 右下の「次へ」ボタンを押すと次のラウンド(LOBBY)へ進む
- [ ] 押した後、ボタンが消えて `次のラウンドを準備中…` に変わる。**連打しても二重に進行しない**
- [ ] 押さずに放置すると、`ResultTimeout`(既定120秒)後に自動で進む
- [ ] **ラウンドを3周させても、1回の「次へ」で1回だけ進む**(接続の積み上がりが無い)
- [ ] RESULT中は**武器が撃てない**(順位が変わらない)。RESULT中に敵が動かない・撃ってこない
- [ ] 上部タイマーに「次まで N」のカウントダウンが表示されない(固定で「リザルト」と出る)
- [ ] RESULTの最中に途中参加したプレイヤーにも、正しくリザルト表示(または直後のLOBBY)が伝わる

**損失キャップの検証**

`Config.Threat.Damage.MaxLossPerMinute` は既定`0`(無効)。★1での動作検証は完了済みのため、
通常プレイでは以下は確認不要。ロジックそのものを再検証したい場合のみ、
一時的に`20`程度へ書き換えてテストを再起動してから行う。

- [ ] `MaxLossPerMinute`を正の値にした状態でわざと棒立ちで殴られ続けると、60秒でその秒数分減った
      ところで出力ウィンドウに `[RoundClock] 損失キャップにより減少を抑止` が出る。以後は
      画面が赤く光ってもタイマーは減らない
- [ ] 検証が終わったら**必ず`0`に戻し、Studioのテストを再起動**する(Configの変更はテスト再起動しないと反映されない)
- [ ] `0`の状態(既定)で、被弾すると毎回きちんと-1秒減ることを確認する

**ラウンド境界・切り分け**

- [ ] RESULT中は敵が動かなくなり、撃ってこなくなる(モデルは残る)
- [ ] 次のLOBBYで敵が全部消え、★インジケータが `☆` に戻る。前ラウンドのスコアを持ち越さない
- [ ] `Config.Threat.Enabled = false` にすると敵が一切出ず、Phase 6と同じ挙動に戻る
- [ ] **タブレット実機**で30fpsを維持する(敵4人+爆発時)

### Phase 8: パトカー(Step 3)

- [ ] スコア1,000点で「警察が出動した!」テロップ + ★インジケータが `★` に変わる(現状★1のみ登録のため☆は付かない)
- [ ] パトカー2台と警官2人が湧く。**パトカー2台は必ず別々の交差点**から湧く
- [ ] パトカーが道路の上だけを走り、角で曲がりながらプレイヤーに近づいてくる
- [ ] 到着すると車の**左右のドア横**に警官2人が降り、青いリングが広がって消える
- [ ] 放置すると10秒ごとに警官が追加で降りてくる(**上限なし**)
- [ ] パトカーにバズーカを当てると**オレンジ**に一瞬光る。3発で破壊できる
- [ ] **降ろされた警官を全員倒しても、パトカーが生きている限り次の波が来ない**
- [ ] パトカーも倒すと20秒後に次の波が来る
- [ ] 警官は遠く(80stud)で止まり、100studから撃ってくる
- [ ] 警官を倒してもタイムは増えない(スコア300のみ)
- [ ] ラウンド終了で敵が全部消え、次のラウンドで★が☆に戻る

### Phase 9: 危険度昇格時の旧部隊撤退(Step 5-0)

現時点では★2の本番編成が未実装のため、確認には一時的に仮のStage 2を追加する必要がある。
**この一時設定は確認後に必ず削除し、`Config.lua`にコミットしないこと。**

一時設定の手順:
1. `Config.Threat.Stages[1].Threshold`を`500`へ一時変更(★1を早く出すため)
2. `Config.Threat.Stages`へ、既存の敵タイプだけを使った仮のStage 2を追加する

```lua
{
    Name = "★2 撤退テスト",
    Threshold = 5000,
    Telop = "撤退テスト",
    Sound = "Siren",
    RespawnDelay = 20,
    Squad = {
        { type = "PoliceCar", count = 1 },
    },
},
```

確認手順:
- [ ] 500点まで稼いで★1(パトカー2台+警官2人)を出す
- [ ] パトカーが警官を降ろすまで待ち、パトカーと降車した警官の両方が存在する状態にする
- [ ] Explorerで`workspace.Enemies`内の各敵モデルの`SquadId`属性を確認する
- [ ] 5,000点まで稼いで★2へ昇格させる
- [ ] ★2昇格と同時に★1部隊(パトカー・降車済みの警官の両方)が停止する
- [ ] 旧部隊の頭上「!」が撤退開始時に消える
- [ ] 撤退中の旧部隊に画面端の▲が表示されない
- [ ] 旧部隊が`FadeTime`(既定0.6秒)程度でフェードアウトする
- [ ] フェード中の旧部隊にバズーカ弾が衝突しない(すり抜ける)
- [ ] 撤退中の旧部隊から攻撃を受けない
- [ ] 撤退開始後、パトカーが警官を追加で降ろさない
- [ ] 撤退でスコア・残り時間・撃破数が増えない。撃破音やラグドールも発生しない
- [ ] 出力ウィンドウに`[EnemyManager] squad=... 撤退開始 (対象=...体)`が1行だけ出る(敵1体ごとには出ない)
- [ ] 撤退後、旧段階の敵が遅れて追加生成されない(旧段階の再派遣待ち中に昇格した場合も同様)
- [ ] 新しい`squadId`のパトカー(★2部隊)だけが残る
- [ ] `Config.Threat.Retreat.Enabled = false`にすると、★2へ昇格しても★1部隊が残ったまま★2部隊も派遣される。確認後`true`に戻す
- [ ] ラウンド終了後、次のラウンドで通常どおり★1部隊が生成される
- [ ] 3武器すべて・市民NPC・リザルト画面が従来どおり動く
- [ ] 出力ウィンドウに赤いエラーが出ない

確認後の後片付け(**必須**):
- [ ] `Config.Threat.Stages[1].Threshold`を本番値の`1000`へ戻した
- [ ] 一時追加したStage 2を削除した
- [ ] `Config.Threat.Retreat.Enabled`が`true`に戻っている
- [ ] `git diff -- ReplicatedStorage/Config.lua`に一時テスト値が残っていないことを確認した

### 街並み拡張の確認ポイント(グリッドモード。現在の本番)
- [ ] N×N街区の道路網(車道+歩道)と、各街区の縁に建物が生成される(詳細な計算式はCURRENT_SPEC.md参照)
- [ ] 建物のパレット(砂岩・コンクリ・レンガ)や窓・階数がラウンドごとに少し変わる
- [ ] **道路・歩道は爆発しても壊れない**(吹き飛ばない)
- [ ] 全建物それぞれで全壊ボーナス(+500点)が **1棟につき1回ずつ** 入る
- [ ] ラウンド終了→再生成で、道路も含めて古いマップが残らない
- [ ] (街灯・車・木・石垣・手作りテンプレートはグリッドモードでは未実装のため生成されない。これは既知の仕様)

### 街並み拡張の確認ポイント(従来モード。`USE_GRID_MODE=false`に切り替えた場合のみ)
- [ ] 道路2本(十字路)+ 歩道 + 白線 + 建物13棟 + 街灯・車・木が生成される
- [ ] **道路・歩道・街灯・車・木は爆発しても壊れない**(吹き飛ばない)
- [ ] ラウンド終了→再生成で、小物・道路も含めて古いマップが残らない

### ビジュアル強化の確認ポイント
- [ ] 起動時に草地のTerrainが生成される(揺れる草が出ない場合はTerrainのDecorationを手動オン。2-3節参照)
- [ ] 建物がパレットごとの質感(砂岩/コンクリ/レンガ)で生成され、窓のまわりに差し色の窓枠が入る
- [ ] 屋根が壁と違う色・材質(Slate)になっている
- [ ] (従来モードのみ)区画の縁に石垣があり、**爆発で壊せてスコア(+10点/個)も入る**
- [ ] 遠くの景色がうっすら霞んで見える(Atmosphere)
- [ ] ラウンドが何周してもTerrainが二重生成されない(初回のみ生成)

### 手作り建物の確認ポイント(従来モードのみ。テンプレートを登録した場合)
> **注意**: 現在の本番(グリッドモード)は手作りテンプレートを組み込んでいない(7節参照)。
> 以下は`USE_GRID_MODE=false`に切り替えた場合のみ確認できる。
- [ ] 出力に `[TemplateValidator] ○○: OK (パーツ ○○個)` が出る
- [ ] 自分の建物が街に混ざって生成され、バズーカで壊せて10点/個・全壊ボーナス500点が入る
- [ ] PrimaryPart未設定・スクリプト入りのモデルでもエラーで止まらない(警告+自動補正)
- [ ] `BuildingTemplates` が空(または無い)でも従来どおり動く
- [ ] ラウンド再生成で手作り建物も正しく消えて再配置される

### 受け入れ基準(最終チェック)
- [ ] ソロテストでラウンドが1周する(生成→破壊→リザルト→再生成)
- [ ] 大型ビルにエアストライクを撃ち込んでもカクつかない(瓦礫上限が機能)
- [ ] 3武器すべてPC・モバイル両方で使える
- [ ] 全壊ボーナスが棟ごとに1回だけ入る
- [ ] 出力ウィンドウに赤いエラーが出ない(3分間プレイ)
- [ ] **タブレット実機**でもテストして、下記6章の基準を満たす

---

## 5. うまく動かないときは

### 出力ウィンドウを見る

**「表示」タブ →「出力」** をクリックすると、画面下にログが出ます。
- **赤い文字** = エラー。ここに「どのスクリプトの何行目か」が書いてある
- 赤い行をダブルクリックすると該当スクリプトの該当行に飛べる

### よくある症状と原因

| 症状 | 原因と対処 |
|---|---|
| `Infinite yield possible on 'ReplicatedStorage:WaitForChild("Config")'` と黄色い警告 | Config の**名前か場所が違う**。ReplicatedStorage 直下に、名前が正確に `Config`(ModuleScript)であるか確認 |
| `CityGenerator is not a valid member of Modules` | Modules 内のモジュール名間違い(旧名 BuildingGenerator のままになっていないか確認 → 7章参照) |
| `Modules is not a valid member of ServerScriptService` | Modules フォルダの名前間違い、または GameManager を別の場所に置いている |
| 建物が出ない・何も起きない | GameManager を **Script ではなく LocalScript / ModuleScript で作ってしまった**可能性。種別は作り直さないと変えられないので、新しく Script を作って貼り直す |
| `総パーツ数が上限(20000)に達したため…` と警告が出る | グリッドモードなら`CityGenerator.lua`の`GRID_SIZE`を下げる(4→3→2)。従来モードなら`Config.City.Slots`の行数を減らすか階数を下げる |
| クリックしても撃てない | WeaponClient が LocalScript か確認。また、ロビー中(「まもなく開始…」表示中)は撃てない仕様 |
| クリックしても撃てない(Step1以降) | UIController の全画面赤フラッシュ枠(`DamageVignette`)が `Active = true` になっていないか確認。`false` でないと入力を吸って武器が撃てなくなる |
| UIが出ない | UIController が StarterPlayerScripts にあるか、LocalScript か確認 |
| 爆発音だけ鳴らない | Config の `Sounds.Explosion` の音IDが無効(エラーにはならない仕様)。下記の方法で差し替える |
| 敵の挙動を丸ごと切り離して他の不具合を切り分けたい | `Config.Threat.Enabled` を `false` にしてテストを再起動する。段階監視・湧き・攻撃が一切動かなくなり、Step 1 までと同じ挙動に戻る |
| 敵が全く湧かない(道路交差点にも出ない) | 出力ウィンドウに `[EnemyManager] CityGenerator.GetRoadLines()がnil/空を返しました…` が出ていないか確認。`CityGenerator.lua` の `USE_GRID_MODE` が `false`(従来モード)になっていると出る。グリッドモードに戻すか、湧き位置ロジックの対応を待つ |

### 音の差し替え方法

1. 「表示」タブ →「ツールボックス」を開く
2. カテゴリを「音声」にして「explosion」などで検索
3. 良さそうな音を右クリック →「アセットIDをコピー」
4. ReplicatedStorage の Config を開き、`Config.Sounds` の該当行を
   `Explosion = "rbxassetid://コピーした数字"` に書き換える

### ゲームバランスの調整

制限時間・爆発半径・スコア・街のレイアウトなどの数値は **すべて Config に集まっています**。
例えばラウンドを長くしたいなら `BattleTime = 120` を `180` に変えるだけ。
建物の場所・棟数は `Config.City.Slots`、パーツ上限などは `Config.Performance` にあります。

`Config.Score.BuildingBonusTime`(既定10): 建物を全壊させたときに増える秒数。
長すぎる/短すぎると感じたらここを変える。

バズーカの調整値は `Config.Weapons.Bazooka` にあります。
- `MaxDistance`(既定140): バズーカの射程。**警官の`AttackRange`(既定100)より短くすると
  一方的に撃たれるので、下げるときは対で見ること**。短くするほどプレイヤーが移動する
- `Cooldown`(既定0.3): 連射間隔。小さくすると速いが瓦礫が増えて重くなる
- `AutoFire`(既定true): falseにすると1クリック1発に戻る

`Config.Round.ResultTimeout`(既定120): リザルト画面で誰も「次へ」を押さなかった場合に
自動で次のラウンドへ進むまでの秒数。放置プレイが多い環境では短くしてもよい。

エアストライク(絨毯爆撃)の調整値は `Config.Weapons.Airstrike` にあります。
- `Cooldown`(既定20): 次に使えるまでの秒数。1ラウンド120秒なので、20なら約6回使える
- `LineLength` / `LineWidth`(既定120 / 20): 爆撃線の長さと編隊の幅。広げるほど1回で壊せる範囲が増える
- `BombsPerPlane`(既定6): 1機あたりの投下数。`PlaneCount`(3)を掛けたものが合計発数(18発)
- `BombInterval`(既定0.08): 投下間隔(秒)。**戦闘機の速度はここから自動で決まる**ので、
  機影が遅すぎる/速すぎると感じたらこの値を動かす(速度を直接指定するキーは無い)。
  発射時に出力ウィンドウへ `[Airstrike] 編隊速度 88.2 stud/s (掃射 1.36秒 / 18発)` と出るので、
  それを見ながら調整する。60〜260の範囲を外れると警告が出る
- `MaxRealPerBomb`(既定30): 1発あたりに物理で飛ばす瓦礫の上限。
  **タブレットで重いときは最初にここを12へ下げる**
- `Sequential`(既定true): trueで1発ずつ順に掃射、falseで3機同時。
  falseは掃射時間が短くなるぶん編隊速度が上がるので、警告が出たら`BombInterval`を大きくする

リモート爆弾の調整値は `Config.Weapons.RemoteBomb` にあります。
- `MaxPlaceDistance`(既定50): この距離より遠くには爆弾を置けない(プレイヤーからの**水平距離**で
  判定するため、高いビルの壁面でも水平に近ければ置ける)。小さくするほど「近づいて仕掛ける」
  武器になり、プレイヤーが移動するようになる
- `ChainBonus`: 同時に起爆した個数に応じたスコア倍率。`min` が「その倍率になる最低個数」。
  既定では3個で×2、5個で×3、8個で×5。倍率が掛かるのは**ブロック破壊と市民NPC撃破のスコアだけ**で、
  全壊ボーナス・タイム・敵の撃破報酬には掛からない(理由は `CURRENT_SPEC.md` §12-1)

敵システムの調整値は `Config.Threat` にまとまっています。
- `Stages[n].Threshold`(★1は既定1000): この点数に到達すると段階が上がる。仮値なので、
  実プレイでの到達秒数(出力ウィンドウの `[ThreatManager] ... に到達` ログ)を見ながら調整する
- `EnemyTypes.PoliceOfficer.TimePenalty`(既定1): 被弾時に減る秒数
- `EnemyTypes.PoliceOfficer.TimeReward`: 撃破時に増える秒数。既定**0**(Step3で意図的に撤廃済み。
  警官の撃破では時間は増えない。時間の供給源は建物の全壊とパトカーの撃破に限定する、という設計判断。
  `CURRENT_SPEC.md` §9-2参照)
- `EnemyTypes.PoliceOfficer.ApproachSpeed`(既定20)/`MoveSpeed`(既定13): 敵の移動速度。
  `MoveSpeed` はプレイヤーの `WalkSpeed` より小さくしないと「逃げても追いつかれる」になる
- `Damage.MaxLossPerMinute`: 1分あたりに失える時間の上限(下手なプレイヤーでも赤字にならないように
  する安全弁)。既定**0**(無効)。★1での動作検証は完了済みのため不要と判断し0に戻してある。
  ロジックそのものを再検証したいときだけ、一時的に20程度へ書き換えてテストを再起動する

NPCのパニック逃走の強さは `Config.NPC` にあります。
- `PanicRadius`(既定35): この半径内にいる、即死しなかったNPCが逃走を始める距離
- `PanicSpeed`(既定24): 逃走中の移動速度(通常の`WalkSpeed`より速い)
- `PanicDuration`(既定8): 逃走を続ける秒数。過ぎるとフェードアウトして消える
- `SkinColor` / `ShirtColor` / `PantsColor`: 部位別カラー(頭・腕/胴体/脚)

### 見た目の調整(Config.Visual)

| 項目 | 内容 |
|---|---|
| `Lighting` | 明るさ・時刻(ClockTime=14で昼下がり)・霞み(AtmosphereDensity/Haze) |
| `TerrainEnabled` | 草地Terrainの生成ON/OFF(falseで従来のベースプレートに戻る) |
| `TerrainDecoration` | 揺れる草のON/OFF(重いときに切ると効果大) |
| `BuildingPalettes` | 建物の質感パレット(材質・壁色・窓枠色・屋根)。追加すれば種類が増える |
| `StoneWall` | 石垣のON/OFF・密度(Spacing=4で隙間なし、8で半分)・色 |

---

## 6. パフォーマンス計測と調整(実機基準)

スペックの想定ではなく、**実際に遊ぶ機械で計測して**調整します。

### FPS(フレームレート)の表示方法

| 環境 | 手順 |
|---|---|
| Studio でのテスト中 | 「表示」タブ → **「統計」→「概要(Summary)」** をオン。画面右に FPS が出る(※プレイ中の Shift+F5 は「テスト停止」なので注意) |
| PC の Roblox クライアント(公開後) | ゲーム中に **Shift+F5** でパフォーマンス統計の表示/非表示を切り替え |
| タブレット/スマホ(公開後) | 画面左上の Roblox アイコン → 設定(歯車)→ 「パフォーマンス統計を表示」系の項目をオン(クライアントのバージョンで名称が多少変わる) |

### 判定基準

**大型ビルにエアストライクを着弾させた瞬間に 30fps を下回らないこと。**
(瓦礫が一番多く動く、いちばん重い瞬間がこれ)

### 30fps を下回った場合の調整順

ReplicatedStorage の Config を開き、上から順に変更して再テスト:

1. `Config.Visual.TerrainDecoration = true` → **false**(揺れる草を止める。見た目への影響が小さい割に効く)
2. `Config.Visual.Lighting.AtmosphereDensity = 0.35` → **0.2**(霞みを軽く)
3. Studio で Lighting の **Technology を ShadowMap に落とす**(2-3節と同じ手順でFutureの代わりにShadowMapを選ぶ。手動・1回だけ)
4. `Config.Performance.MaxUnanchoredParts = 1000` → **600**(同時に動く瓦礫を減らす)
5. `Config.Performance.DebrisLifetime = 8` → **5**(瓦礫が早く消える)
6. それでもダメなら**建物の棟数を減らす**: グリッドモードは`CityGenerator.lua`の`GRID_SIZE`を4→3→2に下げる。従来モードは`Config.City.Slots`の行を消す(13棟→10棟→8棟)

> タブレット実機でのテストは必須項目です。Studio のデバイスエミュレータは
> 画面サイズの確認にはなりますが、**性能の確認にはなりません**。

---

## 7. 自分で作った建物をゲームに登場させる(手作りテンプレート)

自分(や子ども)が Studio で組み立てた建物を、街の生成に混ぜることができます。
壊したときの点数や全壊ボーナスは、自動生成の建物とまったく同じです。

### 7-1. 建物の作り方のルール

- **小さいパーツを積み上げて作る**こと。目安は 4x2x2、大きくても一辺 8 stud 以下
- 大きな1枚壁で作ると、爆発したとき「壁ごとドン」と1個飛ぶだけで崩れる楽しさがない。
  小さいブロックの集合なら、爆発でバラバラに吹き飛んで気持ちいい(このゲームの肝!)
- 色・材質は自由。タグや設定は**ゲーム側が自動で付ける**ので気にしなくてよい
- 完成したら:
  1. 建物のパーツを**全部選択**(ドラッグで囲むか、Ctrl+クリック)
  2. 右クリック →「**グループ化(Model)**」(Ctrl+G)
  3. できた Model を選び、プロパティの **PrimaryPart** をクリック → 建物の**土台のパーツ**をクリックして設定
     (忘れてもゲーム側が自動補正するが、設定しておくと接地が正確になる)

### 7-2. 登録手順

1. Explorer で **ReplicatedStorage** に Folder を作り、名前を **`BuildingTemplates`** にする(1回だけ)
2. 作った Model を BuildingTemplates の中へドラッグして移動する
3. Model に分かりやすい名前を付ける(例: `House1`、`タワー` など)

これだけで、次のラウンドから自動的に街に混ざって生成されます
(標準では各スロットが「自動生成 or 手作り」をランダムに選ぶ設定になっています)。

### 7-3. 確認方法

- テストプレイして、出力ウィンドウに `[TemplateValidator] House1: OK (パーツ ○○個)` と出ること
- 何ラウンドか回して、自分の建物が街に混ざって生成されること(ランダムなので毎回とは限らない)
- 必ず出したい場合は、Config の `Config.City.Slots` のどれかを
  `building = "template:House1"` に書き換えると、そのスロットに固定で建つ

### 7-4. よくある失敗と対処

| 症状・警告 | 意味と対処 |
|---|---|
| `PrimaryPart が未設定のため…自動設定しました` | そのままでも動く。正確に接地させたいなら 7-1 の手順3で土台を設定 |
| `大きなパーツが ○個あります` | 動くが、大きいパーツは崩れ方が大味になる。小さいブロックに分けるのがおすすめ |
| `パーツが ○個しかありません` | 動くが、壊しごたえがない。もっと積もう |
| `スクリプト「…」を削除しました` | Toolbox由来のモデルに入っていた不正スクリプト対策。ゲーム側が自動で消すので安心してよい(そもそも自作パーツで作るのが安全) |
| 建物が区画からはみ出す | `Config.City.Slots` の `maxSize` を大きくするか、建物を小さく作り直す(自動縮小はしない仕様) |
| `Model ではないためスキップします` | グループ化を忘れている。7-1 の手順1〜2でModelにする |

> **遊び方の提案**: 子どもがStudioで建物を作り、親が登録してあげれば
> 「自分の作った建物を自分で爆破する」遊びができます。作る→壊すのループは最高です。

---

## 8. 旧版からの更新手順(すでに旧版を Studio に配置済みの人向け)

### 敵システム Step2(★1警官)版への更新(Step1版 → 今回)

★1(警官)が実際に出るようになります。パトカーはまだ出ません(Step3)。

1. **新規作成**: `ServerScriptService/Modules` に ModuleScript **`EnemyManager`** と
   **`ThreatManager`** を作り、それぞれ同名の .lua の中身を貼り付け
2. **貼り替え**: 以下6つの中身を全置き換え(Ctrl+A → 貼り付け)
   - `ReplicatedStorage/Config` ← Config.lua(`Config.Threat` が新設され、`Config.Sounds` に
     `Siren`/`EnemyShot`/`EnemyDown` が増えた)
   - `Modules/RoundClock` ← RoundClock.lua(損失キャップのロジックが増えた。deadline方式・
     既存2クランプ・runningガードは無変更)
   - `Modules/WeaponServer` ← WeaponServer.lua(`GetTotalScore()` が増えただけ。
     バズーカのCooldown=0などは無変更)
   - `ServerScriptService/GameManager` ← GameManager.server.lua(EnemyManager/ThreatManagerの
     require・Init、ラウンド境界での呼び出しが増えた)
   - `StarterPlayerScripts/EffectsClient` ← EffectsClient.client.lua(敵関連の演出6種が増えた)
   - `StarterPlayerScripts/UIController` ← UIController.client.lua(★インジケータ・
     画面端の方向インジケータが増えた。Step1のタイム経済演出は無変更)
3. 動作確認は本書 4章の **Phase 7: ★1 敵システム** を使う。**「3武器すべてが撃てる」「市民NPCが
   従来どおり」を敵を出す前に必ず確認する**

DestructionManager / NPCManager / CityGenerator / WeaponClient / VisualSetup /
TemplateValidator は変更なしです。

### 敵システム Step1(タイム経済の可視化)版への更新(Step0版 → 今回)

敵はまだ1体も出ません。「建物を全壊させると残り時間が延びる」演出だけが増えます。

1. **貼り替え**: 以下5つの中身を全置き換え(Ctrl+A → 貼り付け)
   - `ReplicatedStorage/Config` ← Config.lua(`Config.Score` に `BuildingBonusTime` が、
     `Config.Sounds` に `TimeGain`/`TimeLoss` が増えた)
   - `Modules/DestructionManager` ← DestructionManager.lua(全壊ボーナス時に
     `RoundClock.Add` を呼ぶ1行が増えた)
   - `ServerScriptService/GameManager` ← GameManager.server.lua(`DestructionManager.Init`
     に `addTime` を渡し、`RoundClock` のタイム変化時に `Hud`/`Effect` を送るようになった)
   - `StarterPlayerScripts/UIController` ← UIController.client.lua(タイマーの色フラッシュ・
     「+10秒!」フローティング・全画面赤フラッシュ枠(まだ発火しない)が増えた)
   - `StarterPlayerScripts/EffectsClient` ← EffectsClient.client.lua(`timeGain`/`timeLoss`
     の音が増えた)
2. 動作確認は本書 4章の **Phase 6: タイム経済** を使う。**「3武器すべてが撃てる」を
   建物を壊す前に必ず確認する**(全画面Frameの設定ミスで武器が撃てなくなる事故対策)

RoundClock / WeaponServer / NPCManager / CityGenerator / VisualSetup / TemplateValidator /
WeaponClient は変更なしです。

### 敵システム Step0(基盤整備)版への更新(手作りテンプレート対応版 → 今回)

敵はまだ1体も出ません。このステップは「ラウンド時間を動的に増減できる土台」だけを作る
リファクタで、**プレイして見た目・挙動が変わらないことが正解**です。

1. **新規作成**: `ServerScriptService/Modules` に ModuleScript **`RoundClock`** を作り、
   **RoundClock.lua** の中身を貼り付け
2. **貼り替え**: 以下4つの中身を全置き換え(Ctrl+A → 貼り付け)
   - `ReplicatedStorage/Config` ← Config.lua(`Config.Round` に `BattleTimeMax`/`BattleTimeFloor`
     が増え、`Config.RemoteNames` に `"Hud"` が増えた)
   - `Modules/DestructionManager` ← DestructionManager.lua(`Explode` の引数が単一テーブル
     `ctx` に変わった。他モジュールから直接呼んでいなければ影響なし)
   - `Modules/NPCManager` ← NPCManager.lua(`OnExplosion` の引数が `ctx` に変わったが、
     中身の動作は従来どおり)
   - `Modules/WeaponServer` ← WeaponServer.lua(`Explode` の呼び出し方が変わっただけ)
   - `Modules/CityGenerator` ← CityGenerator.lua(`GetRoadLines`/`GetCityBounds` が増えたが、
     街の生成ロジック自体は無変更)
   - `ServerScriptService/GameManager` ← GameManager.server.lua(バトルフェーズの時間管理を
     RoundClock 経由に変更)
3. 動作確認は本書 4章の Phase 1〜5・街並み拡張の確認ポイントがそのまま使える。
   加えて「出力ウィンドウに `[RoundClock] 開始(基礎 120秒)` が出ること」を確認する

VisualSetup / TemplateValidator / クライアント3本は変更なしです。

### 手作りテンプレート対応版への更新(ビジュアル強化版 → 今回)

1. **新規作成**: `ServerScriptService/Modules` に ModuleScript **`TemplateValidator`** を作り、
   **TemplateValidator.lua** の中身を貼り付け
2. **貼り替え**: 以下2つの中身を全置き換え(Ctrl+A → 貼り付け)
   - `ReplicatedStorage/Config` ← Config.lua(Slots の `building` 指定と `Config.Handmade` が増えた)
   - `Modules/CityGenerator` ← CityGenerator.lua(テンプレート配置機能)
3. (任意)7章の手順で `BuildingTemplates` フォルダを作って自作の建物を登録

GameManager / DestructionManager / NPCManager / WeaponServer / VisualSetup / クライアント3本は変更なしです。

### ビジュアル強化版への更新(street版から)

1. **新規作成**: `ServerScriptService/Modules` に ModuleScript **`VisualSetup`** を作り、
   **VisualSetup.lua** の中身を貼り付け
2. **貼り替え**: `ServerScriptService/GameManager` ← GameManager.server.lua(VisualSetup呼び出しが増えた)
3. **手動設定**: 2-3節の手順で Lighting の Technology を **Future** に(1回だけ)

### 街並み拡張前(初版)からの更新

上記に加えて:
- `Modules/BuildingGenerator` を右クリック →「名前の変更」で **`CityGenerator`** にしてから中身を貼り替え
- `Modules/DestructionManager` も最新の **DestructionManager.lua** に貼り替え
- クライアント3本(WeaponClient・EffectsClient・UIController)も最新版に貼り替え

---

## 9. 公開するとき(おまけ)

`ファイル → Roblox に公開` でアップロードできます。
息子さんのタブレットで遊ぶ場合は、公開後に
`ゲーム設定 → 権限 → プライベート(フレンドのみ)` などを設定してください。
