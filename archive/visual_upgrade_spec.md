# 追加指示書2: ビジュアル強化（ライティング・地形・建物の質感）

## 0. この指示書について

- これは `roblox_destruction_game_spec.md`（本体）と `city_expansion_spec.md`（街並み拡張）への**追加指示**である。既存の方針（サーバー権威、Config集約、日本語コメント、SETUP.md更新）はすべて維持すること
- 目的: ゲームの見た目を「無機質なブロック置き場」から「明るい屋外の街」に近づける。参考イメージは「Future Lighting + 草原の地形 + 砂色の低層建物」のカジュアルな雰囲気
- **破壊処理・スコア・武器・NPCのロジックは一切変更しない**。変えるのは生成時の見た目と環境設定のみ

---

## 1. ライティング（LightingSetup）

サーバー起動時に一度だけ Lighting を設定するコードを追加する（GameManager 起動処理内 or 専用モジュール）。手作業設定に依存せず、**スクリプトで毎回同じ見た目を保証**する。

設定内容（すべて Config の `Config.Visual.Lighting` に集約）:

| 項目 | 値（デフォルト） |
|---|---|
| Lighting.Technology | Future ※ |
| Lighting.Brightness | 3 |
| Lighting.EnvironmentDiffuseScale | 1 |
| Lighting.EnvironmentSpecularScale | 1 |
| Lighting.ClockTime | 14（昼下がり） |
| Atmosphere.Density | 0.35 |
| Atmosphere.Haze | 1.5 |

- Atmosphere インスタンスが無ければ生成して Lighting 配下に追加する
- ※ **注意**: `Lighting.Technology` はスクリプトから変更できない（読み取り専用）場合がある。その場合はコードでの設定を諦め、**SETUP.md の手順に「Studioで手動設定する項目」として明記**すること（1回設定すれば保存される）

---

## 2. 地形（TerrainSetup）

ベースプレートの上を Roblox **Terrain の草地**に置き換える。

- `Terrain:FillBlock` 等でマップ全域（街区より一回り広い範囲、例: 400x400 stud、厚さ4 stud程度）を `Enum.Material.Grass` で敷く
- `Terrain.Decoration = true` にして**揺れる草**を有効化する
- 既存のベースプレートは Terrain の下に隠れるならそのままでよい（消しても可）
- 道路・歩道は既存のPartのまま Terrain の上に載せる（道路の高さを Terrain 表面に合わせて微調整すること）
- 街の外周に緩やかな起伏（低い丘）を数カ所置くと雰囲気が出る（任意。パーツではなくTerrainで）
- Terrainはラウンドごとに再生成**しない**（初回のみ生成。破壊対象外なので作り直し不要）

---

## 3. 建物の質感向上（CityGenerator の変更）

ブロックの生成ロジックは変えず、**見た目のプロパティだけ**を変える。

### 3.1 マテリアルと色（Config.Visual.BuildingPalettes に集約）
- 建物ごとに「パレット」を1つ選ぶ方式にする。パレット例:
  - 砂岩の家: Material=Sandstone、壁=砂色系2〜3色、窓枠=青系
  - コンクリビル: Material=Concrete、壁=グレー系、窓枠=白
  - レンガの店: Material=Brick、壁=赤茶系、窓枠=木目色
- 同じ建物内でブロックごとに彩度・明度を数%ランダムに振る（既存のバリエーション仕様を維持）

### 3.2 窓枠・アクセント
- 窓開口部の周囲1ブロックを「窓枠色」にする（参考イメージの青い窓枠のような差し色）
- 屋根の最上段は壁と違う色・Materialにする（Slate など）

### 3.3 石垣（区画の縁）
- 各区画の縁（歩道の内側）に高さ2 stud程度の低い石垣を追加する。Material=Cobblestone
- 石垣も小ブロック構成で `Destructible` タグを付ける（壊せる方が楽しい）
- 追加分を含めて**総パーツ数上限6,000は厳守**。超えそうなら石垣の密度を下げる

---

## 4. 街小物の見栄え強化（自作Partのまま）

Toolboxは引き続き使わない（再現性と安全性のため）。Partの組み合わせを増やして見栄えを上げる:

- **木**: 幹1本 + 葉を球3〜4個の重ね合わせにする（1個の球より自然に見える）。Material=Grass(葉)/Wood(幹)。1本あたり5パーツ以内
- **車**: 車体に Material=SmoothPlastic + 少し反射（Reflectance 0.1程度）、窓ガラス風の暗色Part追加。1台あたり10パーツ以内
- **街灯**: 変更なし（現状維持）
- 小物の合計パーツ数は従来どおり**500個以内**

---

## 5. パフォーマンス注意（タブレット実機基準の維持）

Future Lighting と Terrain草は描画負荷が上がる。既存の実機テスト基準に以下を追加:

- 判定基準は従来どおり「**大型ビルへのエアストライク着弾時に30fpsを下回らない**」
- 下回った場合の調整順（Config.Visual に対応するON/OFFフラグを用意すること）:
  1. `Terrain.Decoration = false`（揺れる草を止める。見た目への影響が小さい割に効く）
  2. `Atmosphere.Density` を下げる（0.35 → 0.2）
  3. Lighting.Technology を **ShadowMap** に落とす（SETUP.mdに手動手順を記載）
  4. それでも駄目なら従来の調整順（MaxUnanchoredParts → DebrisLifetime → 棟数減）へ
- SETUP.md にこの調整順を追記すること

---

## 6. Config 追加項目まとめ

```
Config.Visual = {
    Lighting = { Brightness, ClockTime, AtmosphereDensity, AtmosphereHaze, ... },
    TerrainEnabled = true,       -- Terrain生成のON/OFF
    TerrainDecoration = true,    -- 揺れる草のON/OFF
    BuildingPalettes = { ... },  -- 建物パレット定義
}
```

- 既存の `Config.City` / `Config.Performance` の構成は変えない

---

## 7. 受け入れ基準

- [ ] 起動時に草地のTerrainが生成され、揺れる草が表示される
- [ ] 建物がパレット（砂岩/コンクリ/レンガ）ごとの質感で生成され、窓枠に差し色が入る
- [ ] 石垣が生成され、爆発で壊せる（スコアも入る）
- [ ] 総パーツ数6,000以下がログで確認できる
- [ ] Atmosphereによる遠景の霞みが確認できる
- [ ] ラウンド再生成でTerrainが二重生成されない（初回のみ生成）
- [ ] タブレット実機でエアストライク時30fpsを維持（下回る場合はConfig.Visualのフラグで調整可能）

---

## 8. SETUP.md への追記事項

1. Lighting.Technology を Future に手動設定する手順（スクリプトから設定できなかった場合の必須手順として。設定は保存ファイルに残るので1回でよい旨も書く）
2. 見た目調整（Config.Visual）の項目説明
3. 重い場合の調整順（本指示書セクション5）
4. 旧版からの更新手順（貼り替えが必要なスクリプトの一覧）
