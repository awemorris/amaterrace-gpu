<!-- awesome-plan project=amaterrace-gpu record=ws001-p022 -->

# Phase 022: Stream Setup Engine 実装（atg_rx_setup マイクロコード撤廃と完全パイプライン化）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (トライアングルセットアップを 50〜100+ サイクルから 1〜2 サイクルへ短縮)
- **出典**: ユーザー諮問（RX パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rx/atg_rx_setup.v` において、単一の fadd, fmul, fdiv と 128 ワード分散 RAM をマイクロコード FSM でシーケンス制御し、1 トライアングルに 50〜100+ サイクルを浪費している構造を完全撤廃する。
エッジ方程式、バウンディングボックス、逆数面積、および平面勾配（$\partial P / \partial x, \partial P / \partial y$）を固定遅延フィードフォワードパイプライン化し、スループット 1〜2 サイクル/トライアングルを達成する。

## 範囲・作業内容

1. **マイクロコード FSM の撤廃と固定遅延パイプライン化**:
   - `atg_rx_setup_uc.vh` によるマイクロコード制御を廃止。
   - 頂点座標入力 $\to$ 2D 投影 $\to$ エッジベクトル算出 $\to$ 平面方程式係数算出をストリーム化。
   - 面積逆数算出（$1/\text{Area}$）は、専用のパイプライン化された逆数器または高精度 LUT 初期値＋Newton-Raphson 1 段で固定レイテンシ化。

2. **裏面カリング & ビューポート判定の統合**:
   - 面積符号判定による裏面カリング、およびシザー/ビューポート包含判定をパイプライン先頭段（Stage 0）で即座に実行し、不要プリミティブをゼロ遅延で破棄。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算器 `*` 厳禁（`am_mul` / `am_fp_mul` のみ）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_setup.v`
- 削除/整理: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_setup_uc.vh`（マイクロコード不要化に伴う）
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rx/atg_rx_setup.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_rx_setup_tb.v`

### 2. モジュールインターフェース設計 (`atg_rx_setup.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rx_setup #(
    parameter LAT = 8  // パイプライン固定段数
)(
    input  wire        clk,
    input  wire        rst_n,

    // プリミティブ（三角形頂点）入力
    input  wire        tri_valid,
    output wire        tri_ready,
    input  wire [31:0] v0_x, v0_y, v0_z, v0_w,
    input  wire [31:0] v1_x, v1_y, v1_z, v1_w,
    input  wire [31:0] v2_x, v2_y, v2_z, v2_w,
    input  wire [31:0] cull_mode,

    // セットアップ済み三角形パラメータ出力 (ラスタライザへ)
    output wire        setup_valid,
    input  wire        setup_ready,
    output wire [31:0] tri_area_inv,
    output wire [31:0] e0_a, e0_b, e0_c, // エッジ方程式 Ax + By + C
    output wire [31:0] e1_a, e1_b, e1_c,
    output wire [31:0] e2_a, e2_b, e2_c,
    output wire [15:0] bbox_min_x, bbox_min_y,
    output wire [15:0] bbox_max_x, bbox_max_y
);
```

### 3. RTL アーキテクチャとパイプライン設計
- 頂点減算・外積（$2 \times \text{Area} = (x_1 - x_0)(y_2 - y_0) - (x_2 - x_0)(y_1 - y_0)$）を 4 段のパイプラインで計算。
- 符号が負（時計回り/反時計回り）かつカリング指定一致なら、その場で `valid` を落として破棄（0 サイクルキル）。
- 面積逆数 $1/\text{Area}$ は、指数調整＋LUT (1024 エントリ) ＋ Newton-Raphson 1 段（`am_mul` 利用）で 3 サイクルで確定。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: 外積計算および逆数ステップの乗算には必ず `am_mul` / `am_fp_mul` を使用すること。
- **生演算子 0 件**: `tools/arith-lint.py` 遵守。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rx_setup_tb.v`
- **検証項目**:
  1. トライアングル連続投入時、毎サイクル 1 トライアングルがスループット 100% でセットアップされること。
  2. カリング対象の縮退三角形および裏面三角形が正確に破棄されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rx_setup
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- マイクロコードが撤廃され、固定遅延ストリームパイプラインとして動作すること。
- `sim/run.sh atg_rx_setup` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_rx_setup_tb.v` による各種三角形（正順、逆順、縮退、クリップ境界）のセットアップパラメータ完全一致検証。
   - `sim/run.sh atg_rx`, `sim/verilator/run.sh` での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- セットアップスループットが 1〜2 サイクル/トライアングルに向上すること。
- エッジ係数および平面勾配の計算精度が既存実装と完全一致すること。
