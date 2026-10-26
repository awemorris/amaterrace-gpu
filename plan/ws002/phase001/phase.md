<!-- awesome-plan project=amaterrace-gpu record=ws002-p001 -->

# Phase 001: ROP Logic Op（論理演算 16 種）& Independent Blend per RT

- **親**: [WS002](../ws.md)
- **状態**: `in-review`
- **依存**: [ws001-p014](../../ws001/phase014/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan 1.0 コア仕様で定義される 16 種類の論理演算（`VkLogicOp`: CLEAR, AND, AND_REVERSE, COPY, AND_INVERTED, NO_OP, XOR, OR, NOR, EQUIV, INVERT, OR_REVERSE, COPY_INVERTED, OR_INVERTED, NAND, SET）を ROP ブレンドパイプライン出力段に実装する。
また、カラーアタッチメント 0〜3 に対し、独立した `BlendOp` / `BlendFactor` 設定を可能にする（Independent Blend）。

## 範囲・作業内容

1. **ROP 出力段への Logic Op MUX 実装**:
   - `rtl/gpu/rop/atg_rop_blend.v` のブレンド後データと Destination データのビット単位論理演算 MUX を追加。
   - `logicOpEnable` および `logicOp` の STATE デコードを追加。

2. **Independent Blend per RT のサポート**:
   - 各アタッチメント個別の `VkPipelineColorBlendAttachmentState` を反映可能なレジスタ拡張。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` 必須）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_blend.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_regs.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rop/atg_rop_blend.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_rop_logicop_tb.v`

### 2. モジュールインターフェース設計 (`atg_rop_blend.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rop_blend #(
    parameter NPIX = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // クアッド入力
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [1:0]  in_rt_idx,    // レンダーターゲット番号 (0..3)
    input  wire [NPIX*32-1:0] in_src,
    input  wire [NPIX*32-1:0] in_dst,

    // ステート設定
    input  wire        logic_op_en,
    input  wire [3:0]  logic_op,     // VkLogicOp (0..15)
    input  wire [4*16-1:0] blend_modes, // RT ごとの独立ブレンド設定

    // クアッド出力
    output wire        out_valid,
    input  wire        out_ready,
    output wire [NPIX*32-1:0] out_pixel
);
```

### 3. RTL アーキテクチャと Logic Op 演算定義
- 16 種類の `VkLogicOp`（ビット単位論理演算）:
  - 0 (CLEAR): `0`
  - 1 (AND): `s & d`
  - 2 (AND_REVERSE): `s & ~d`
  - 3 (COPY): `s`
  - 4 (AND_INVERTED): `~s & d`
  - 5 (NO_OP): `d`
  - 6 (XOR): `s ^ d`
  - 7 (OR): `s | d`
  - 8 (NOR): `~(s | d)`
  - 9 (EQUIV): `~(s ^ d)`
  - 10 (INVERT): `~d`
  - 11 (OR_REVERSE): `s | ~d`
  - 12 (COPY_INVERTED): `~s`
  - 13 (OR_INVERTED): `~s | d`
  - 14 (NAND): `~(s & d)`
  - 15 (SET): `~0`
- `logic_op_en` がアサートされている場合はブレンド演算をバイパスし、ビット単位論理演算の結果を出力段へ送る。
- `in_rt_idx` に応じて RT 個別のブレンド方程式（`blend_modes[in_rt_idx*16 +: 16]`）を選択適用。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: すべてのビット演算は論理演算子（`&`, `|`, `^`, `~`）のみで記述すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rop_logicop_tb.v`
- **検証項目**:
  1. 16 種類すべての `VkLogicOp` について、ランダムな `src` と `dst` に対しビット単位で完全一致すること。
  2. 各 RT（0〜3）で異なるブレンドモードが正確に個別適用されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rop_logicop
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 16 種類の Logic Op が正確に動作すること。
- RT 個別の Independent Blend が正常に機能すること。
- `sim/run.sh atg_rop_logicop` が PASS すること。
- R1 レビュー APPROVE 獲得。
