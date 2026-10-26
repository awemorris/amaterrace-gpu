<!-- awesome-plan project=amaterrace-gpu record=ws002-p001 -->

# Phase 001: ROP Logic Op（論理演算 16 種）& Independent Blend per RT

- **親**: [WS002](../ws.md)
- **状態**: `planned`
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

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_blend_tb.v` に全 16 種の論理演算テストパターンを追加。
   - `sim/verilator/run.sh` PASS。
   - R1 レビュー。

## 検証基準（受け入れ条件）

- 16 種類の Logic Op がビット完全正確に動作すること。
- アタッチメントごとに異なるブレンド演算が正しく適用されること。
