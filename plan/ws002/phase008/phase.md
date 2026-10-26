<!-- awesome-plan project=amaterrace-gpu record=ws002-p008 -->

# Phase 008: 間接描画 & インスタンシング（MultiDrawIndirect, Vertex Divisor）

- **親**: [WS002](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p033](../../ws001/phase033/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan 1.0 仕様で要求される間接描画（`vkCmdDrawIndirect`, `vkCmdDrawIndexedIndirect`, `multiDrawIndirect`）およびインスタンス描画（`instanceCount`, `firstInstance`, Vertex Attribute Divisor）を実装し、CPU 介在なしでの GPU 駆動レンダリングを可能にする。

## 範囲・作業内容

1. **間接描画引数フェッチャの実装**:
   - GPU メモリ（バッファ）から描画コマンド引数構造体（`VkDrawIndirectCommand`, `VkDrawIndexedIndirectCommand`）を直接読み出し、CP および VF へ展開するロジックを追加。
2. **Vertex Attribute Divisor の実装**:
   - 頂点属性バインディングごとの除数（Divisor）に応じたインスタンスステップ加算器を VF に追加。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` 必須）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp_indirect.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/cp/atg_cp_indirect.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/vf/atg_vf_fetch.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_cp_indirect_tb.v`

### 2. モジュールインターフェース設計 (`atg_cp_indirect.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_cp_indirect (
    input  wire        clk,
    input  wire        rst_n,

    // 間接描画コマンド要求 (CP デコーダから)
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [31:0] arg_buffer_addr,
    input  wire [31:0] draw_count,
    input  wire [31:0] stride,
    input  wire        is_indexed,

    // 引数バッファ DMA リード
    output wire        dma_req_valid,
    input  wire        dma_req_ready,
    output wire [25:0] dma_req_line,
    input  wire        dma_rsp_valid,
    input  wire [255:0] dma_rsp_data,

    // 展開されたドローコール発行 (VF / CP コントローラへ)
    output reg         draw_valid,
    input  wire        draw_ready,
    output reg  [31:0] vertex_count,
    output reg  [31:0] instance_count,
    output reg  [31:0] first_vertex,
    output reg  [31:0] first_instance
);
```

### 3. RTL アーキテクチャと Divisor ステップ
- `atg_cp_indirect.v`: メモリ上の引数バッファから 1 ドローコールあたり 16〜20 バイトの引数を DMA フェッチし、順次パイプラインへディスパッチ。
- `atg_vf_fetch.v`（Vertex Attribute Divisor）:
  - 通常の頂点属性: 頂点インデックスごとにアドレスを進める（`step = vertex_id`）。
  - インスタンス属性（`inputRate = INSTANCE`）: `step = instance_id / divisor`。
  - 除算は `am_div` または事前計算スケール＋シフトで固定レイテンシ化。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 引数アドレスストライド加算（`addr + i * stride`）には必ず `am_add`, `am_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_cp_indirect_tb.v`
- **検証項目**:
  1. メモリ上に配置された 100 個の `VkDrawIndexedIndirectCommand` が、CPU の介在なしに連続して GPU 内部で展開・描画実行されること。
  2. Vertex Divisor（例: Divisor = 4）が設定された属性が、4 インスタンスごとに 1 回だけ進むこと。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_cp_indirect
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- MultiDrawIndirect および Vertex Attribute Divisor が完全動作すること。
- `sim/run.sh atg_cp_indirect` が PASS すること。
- R1 レビュー APPROVE 獲得。
