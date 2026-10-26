<!-- awesome-plan project=amaterrace-gpu record=ws001-p024 -->

# Phase 024: Fast DDA Plane Evaluator（200 サイクルボトルネック撤廃・1 クアッド/サイクル化）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p022](../phase022/phase.md)
- **優先度**: Critical (RX 最大病理の解体: 200 サイクル/クアッドを 1 サイクルへ短縮)
- **出典**: ユーザー諮問（RX パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rx/atg_rx_bary.v` および `atg_rx_frag.v` において、1 クアッドの重心座標・Z・透視除算（$1/w$ のシリアル `fdiv` 等）に毎クアッド約 200 サイクル（1 ワープ 1,600 サイクル）も浪費し、上流ラスタライザ全体をストールさせている最大病理を根本解体する。
スクリーン空間における線形平面特性を活かした増分加算（DDA: $P + 2 \cdot \partial P/\partial x$）により、重心座標・Z・透視補間係数を 1 サイクル/クアッドでストリーム評価する。

## 範囲・作業内容

1. **DDA（Digital Differential Analyzer）増分平面評価回路の実装**:
   - スクリーン空間 $(x, y)$ における $1/w, z/w, \lambda/w$ の線形平面に対し、クアッド移動（$\Delta x = 2, \Delta y = 2$）に伴う増分を加算器 1 段で計算。
   - 重い直列 `fdiv` ループ（34 サイクル $\times$ 4 レーン）を完全撤廃。
   - 透視除算が必要な場合、パイプライン化された逆数テーブル（または SU 側の補間命令 IPA）と連携。

2. **セントロイド補間オフセットの 1 サイクル確定**:
   - カバレッジマスクからセントロイドサンプル位置を 1 サイクルで選択し、DDA 勾配による補正をパイプライン内で適用。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_bary.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rx/atg_rx_bary.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_rx_bary_tb.v`

### 2. モジュールインターフェース設計 (`atg_rx_bary.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rx_bary #(
    parameter NLANES = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // クアッド走査入力 (Ready/Valid)
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [15:0] in_quad_x, in_quad_y,
    input  wire [15:0] in_cov_mask,
    // 平面勾配パラメータ
    input  wire [31:0] plane_z_base, plane_z_dx, plane_z_dy,
    input  wire [31:0] plane_w_base, plane_w_dx, plane_w_dy,

    // 評価済み属性出力 (Ready/Valid)
    output wire        out_valid,
    input  wire        out_ready,
    output wire [NLANES*32-1:0] out_z,      // 4 レーン補間 Z
    output wire [NLANES*32-1:0] out_w_inv,  // 4 レーン 1/w
    output wire [15:0]         out_cov_mask
);
```

### 3. RTL アーキテクチャと DDA 増分評価
- 従来の `fdiv` ステートマシン（34 サイクル直列ループ）を **完全撤廃** する。
- クアッド基準点 $(x_0, y_0)$ での初期値を、タイルの走査開始時に 1 回設定。
- クアッドが $\Delta x = 2$ 進むたびに、ベース値に $2 \cdot \partial P/\partial x$ を加算（`am_add`）。
- クアッド内 4 ピクセル（$(0,0), (1,0), (0,1), (1,1)$）の値は、基準値に $\partial P/\partial x, \partial P/\partial y$ を足し込むことで 1 サイクルで 4 レーン同時に求まる。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: すべての増分加算には `am_add` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rx_bary_tb.v`
- **検証項目**:
  1. 毎サイクル 1 クアッドを連続投入し、固定レイテンシ後に 4 レーン分の Z および $1/w$ が毎サイクル 1 クアッド連続出力されること。
  2. DDA 増分累積による計算結果が、直接乗算した幾何学的真値と高精度で一致すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rx_bary
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 1 クアッドの評価が 1 サイクルスループットで完了すること（200 サイクルの撤廃）。
- `sim/run.sh atg_rx_bary` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_rx_bary_tb.v` による全ピクセル位置での重心座標・Z 精度検証（旧実装との完全一致）。
   - `sim/verilator/run.sh`（`shade.png`, `core.png`）での画像出力完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 平面評価および重心座標生成が 1 クアッド/サイクルで連続出力できること。
- 補間精度および Z 値が既存シミュレーション結果と 1 bit の差異もなく一致すること。
