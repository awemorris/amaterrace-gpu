<!-- awesome-plan project=amaterrace-gpu record=ws002-p003 -->

# Phase 003: MRT 8 アタッチメント拡張（CAPS[30] 4 -> 8 拡張）

- **親**: [WS002](../ws.md)
- **状態**: `cleared`
- **依存**: [ws002-p001](../phase001/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan 1.0 仕様で定められるマルチレンダーターゲット（MRT）の上限値 8 アタッチメント（現状は最大 4 アタッチメント）に対応し、ディファードレンダリング（G-Buffer）等の高度なグラフィックスパイプラインを完全サポートする。

## 範囲・作業内容

1. **ROP アタッチメント制御拡張**:
   - `atg_rop_wb.v`, `atg_rop_wpix.v`, `atg_rop_blend.v` におけるレンダーターゲット選択信号 `b_rt` を 2-bit（4 RT）から 3-bit（8 RT）へ拡張。
   - `RT_FORMATS`, `BLEND1-7`, `WRITE_MASK` のディスクリプタ・ステートレジスタ空間拡張。

2. **パイプライン・アタッチメント調停**:
   - 8 つのアタッチメントへの逐次またはインターリーブ書き込みを Hazard Tracker（Phase 016）と連携して制御。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_wb.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_wpix.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_regs.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rop/atg_rop.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_rop_mrt8_tb.v`

### 2. モジュールインターフェース設計 (`atg_rop_wb.v` 拡張)
- レンダーターゲットインデックス幅: `[1:0]` $\to$ `[2:0]`（0..7）。
- ベースアドレスアレイ: `rt_base[8*32-1:0]`。
- ストライド・フォーマットアレイ: 各 8 エントリ分保持。

### 3. RTL アーキテクチャとアタッチメント管理
- SU からのフラグメントエクスポートで最大 8 個のカラーターゲット（`COLOR0`〜`COLOR7`）がイシューされる。
- ROP は `b_rt` に応じて該当アタッチメントのベースアドレスおよびフォーマットを選択。
- Hazard Tracker（`atg_rop_hazard.v`）のタグ比較にも `RT[2:0]` の 3 ビットを反映。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: RT 番号インクリメント等には必ず `am_add` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rop_mrt8_tb.v`
- **検証項目**:
  1. 8 つのカラーバッファ（G-Buffer: Albedo, Normal, Position, Specular, Roughness, Metalness, Emissive, Custom）への同時出力が正常にメモリへ書き込まれること。
  2. アタッチメントごとの異なるピクセルフォーマット（RGBA8, R11G11B10F, RGBA16F 等）が正しくパッキングされること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rop_mrt8
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 8 つのマルチレンダーターゲットへの描画が完走すること。
- `sim/run.sh atg_rop_mrt8` が PASS すること。
- R1 レビュー APPROVE 獲得。
