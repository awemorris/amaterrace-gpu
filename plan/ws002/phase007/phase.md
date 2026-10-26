<!-- awesome-plan project=amaterrace-gpu record=ws002-p007 -->

# Phase 007: RX 拡張プリミティブ（Wide Lines, Point Sprites, Multi-Viewport）

- **親**: [WS002](../ws.md)
- **状態**: `planned`
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
4. **単体・回帰検証**:
   - 各拡張機能の専用シミュレーションテストベンチ検証。
   - R1 レビュー。

## 検証基準（受け入れ条件）

- 各拡張プリミティブが仕様通り正確にラスタライズされること。
