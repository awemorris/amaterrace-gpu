<!-- awesome-plan project=amaterrace-gpu record=ws002-p007 -->

# Phase 007: RX 拡張プリミティブ（Wide Lines, Point Sprites, Multi-Viewport）

- **親**: [WS002](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p025](../../ws001/phase025/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan 1.0 仕様で定義される拡張プリミティブラスタライゼーション（線幅 > 1.0 の Wide Lines、ダイヤモンドエグジット規則、Point Sprites の点サイズ・クリッピング、最大 16 個の Multi-Viewport / Scissor 配列、Depth Clamping）を実装し、完全な仕様適合性を達成する。

## 範囲・作業内容

1. **Wide Lines & Point Sprites ラスタライザ**:
   - 線幅指定に応じた長方形ポリゴン展開、ダイヤモンドエグジット規則の適用。
   - `pointSize` に基づくスプライト四角形展開と座標生成。
2. **Multi-Viewport & Scissor Arrays**:
   - 最大 16 個のビューポート・シザー矩形配列のステート管理とクリッピング。
3. **Complete Depth Clamping**:
   - ニア/ファークリッピングを無効化し、Z 境界での飽和クランプを行うパイプライン制御。
4. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` 必須）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_setup.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_clip.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rx/atg_rx.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_rx_ext_prim_tb.v`

### 2. モジュールインターフェース設計 (`atg_rx_setup.v` 拡張)
- プリミティブ種別 `prim_type[2:0]`（Triangle, Line, Point）。
- 線幅 `line_width[15:0]`、ポイントサイズ `point_size[15:0]`。
- ビューポートインデックス `viewport_idx[3:0]`（0..15）。

### 3. RTL アーキテクチャと展開ロジック
- **Wide Lines**: 頂点 $V_0, V_1$ から法線方向ベクトル $(\Delta x_\perp, \Delta y_\perp)$ を計算し、幅 $W$ の 2 つのトライアングル（四角形）へプリミティブ展開。
- **Point Sprites**: 頂点 $V_0$ を中心に、一辺 $S$ の四角形（2 つのトライアングル）へ展開。テクスチャ座標 $(0,0)$〜$(1,1)$ を自動生成。
- **Depth Clamping**: Z クリッピング面（$0 \le z \le w$）によるカリングをバイパスし、ラスタライザ出力段で Z 値を $[0, 1]$ に飽和クランプ。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: ベクトル直交計算、線幅スケーリングには必ず `am_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rx_ext_prim_tb.v`
- **検証項目**:
  1. 線幅 1.0〜16.0 のラインが均一な太さでラスタライズされること。
  2. ポイントスプライトが指定サイズで正しく描画されること。
  3. Depth Clamping 有効時に、視点直近のポリゴンが欠けずに描画されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rx_ext_prim
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- Wide Lines, Point Sprites, Multi-Viewport, Depth Clamping が完全動作すること。
- `sim/run.sh atg_rx_ext_prim` が PASS すること。
- R1 レビュー APPROVE 獲得。
