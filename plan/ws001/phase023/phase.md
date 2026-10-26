<!-- awesome-plan project=amaterrace-gpu record=ws001-p023 -->

# Phase 023: MSAA 4x 並列カバレッジ & Coarse Tile Rasterizer

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p022](../phase022/phase.md)
- **優先度**: Critical (外側空クアッド走査のスキップ & MSAA 4 サイクル直列化の撤廃)
- **出典**: ユーザー諮問（RX パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rx/atg_rx_scan.v` において、三角形の外側の空領域をバウンディングボックス単位で総当たり走査している問題、および MSAA 4x 時に 4 サンプルを 1 サンプルずつ 4 サイクルかけて直列評価（`S_SAMP`）している病理を解決する。
$8 \times 8$ タイル単位の内外判定（Coarse Rasterizer）による外側タイル一撃スキップ、および 16 個の並列加算器・比較器による MSAA 4x 1 サイクル同時カバレッジ判定を実装する。

## 範囲・作業内容

1. **Coarse Tile Rasterizer（$8 \times 8$ タイル内外判定）の実装**:
   - トライアングルバウンディングボックスを $8 \times 8$ ピクセルタイル単位で走査。
   - 3 本のエッジ関数をタイルの 4 頂点（Corner）で評価し、完全に三角形の外側にあるタイルを 1 サイクルで一撃スキップ。
   - タイル全体が完全に内部にある場合（Trivially Accepted）、全クアッドのフルカバレッジマスクを一括生成。

2. **Fine Rasterizer & MSAA 4x 1 サイクル並列カバレッジ**:
   - 境界タイル内の $2 \times 2$ クアッドを走査。
   - クアッド 4 レーン $\times$ 4 サンプル = 16 サンプル位置のエッジ評価を並列加算器で同時に実行し、1 サイクルで 16-bit カバレッジマスク（`fq_scov`）を確定。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_coarse.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/rx/atg_rx_coarse.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_scan.v`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_rx_scan_tb.v`

### 2. モジュールインターフェース設計 (`atg_rx_coarse.v` & `atg_rx_scan.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rx_coarse (
    input  wire        clk,
    input  wire        rst_n,

    // セットアップ済み三角形入力
    input  wire        tri_valid,
    output wire        tri_ready,
    input  wire [15:0] bbox_min_x, bbox_min_y,
    input  wire [15:0] bbox_max_x, bbox_max_y,
    input  wire [31:0] e0_a, e0_b, e0_c,
    input  wire [31:0] e1_a, e1_b, e1_c,
    input  wire [31:0] e2_a, e2_b, e2_c,

    // 有効タイル出力 (Fine Rasterizer へ)
    output wire        tile_valid,
    input  wire        tile_ready,
    output wire [15:0] tile_x,      // 8 ピクセル単位
    output wire [15:0] tile_y,
    output wire        tile_trivial // 完全に内包されているフラグ
);
```

### 3. RTL アーキテクチャと 16 並列サンプル評価
- Coarse 判定: $8 \times 8$ タイルの 4 隅 $(x, y), (x+8, y), (x, y+8), (x+8, y+8)$ における各エッジ関数の符号を評価。3 本のエッジすべてについて「4 隅とも負」であれば三角形の外側 $\to$ スキップ。
- MSAA 4x カバレッジ: 1 クアッド内の 4 ピクセル $\times$ 4 サンプル点（Standard Vulkan Sample Locations）の計 16 点において、エッジ値のオフセット加算（ベースエッジ値 $+ A \cdot dx + B \cdot dy$）を 16 並列の `am_add` で 1 サイクル計算。
- 符号判定（ビット 31）の論理積をとることで、16-bit の `fq_scov` を 1 サイクルで生成。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 16 並列オフセット加算はすべて `am_add` / `am_addsub` をインスタンス化すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rx_scan_tb.v`
- **検証項目**:
  1. 空タイルのスキップが 1 サイクルで行われ、バウンディングボックスの走査時間が劇的に短縮されること。
  2. MSAA 4x モードで 1 クアッドの 16 サンプルカバレッジマスクが 1 サイクルで正しく生成されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rx_scan
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 外側空タイルが 1 サイクルで一撃スキップされること。
- MSAA 4x カバレッジが 1 サイクルで生成されること。
- `sim/run.sh atg_rx_scan` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_rx_scan_tb.v` による斜め三角形、細長三角形、極小三角形の走査・カバレッジ検証。
   - `sim/verilator/run.sh`（特に `msaa.png`）での画像完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 外側タイルのスキップにより、無駄なクアッド走査サイクルが大幅に削減されること。
- MSAA 4x のカバレッジ判定が毎クアッド 1 サイクルで完了すること。
