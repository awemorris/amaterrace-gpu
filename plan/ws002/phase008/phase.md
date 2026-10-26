<!-- awesome-plan project=amaterrace-gpu record=ws002-p008 -->

# Phase 008: 間接描画 & インスタンシング（MultiDrawIndirect, Vertex Divisor）

- **親**: [WS002](../ws.md)
- **状態**: `planned`
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
3. **単体・回帰検証**:
   - 間接描画および大量インスタンシング（草木、パーティクル等）のシミュレーションテストベンチ検証。
   - R1 レビュー。

## 検証基準（受け入れ条件）

- 間接描画およびインスタンス描画が Vulkan 1.0 仕様通り正確に実行されること。
