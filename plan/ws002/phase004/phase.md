<!-- awesome-plan project=amaterrace-gpu record=ws002-p004 -->

# Phase 004: TU 異方性フィルタリング（Anisotropic Filtering 最大 16x）

- **親**: [WS002](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p021](../../ws001/phase021/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

斜め方向のテクスチャサンプリング時に生じるテクスチャボケを解消し、Vulkan 1.0 仕様で要求される最大 16x の異方性フィルタリング（`samplerAnisotropy` / `maxAnisotropy`）をサポートする。

## 範囲・作業内容

1. **EWA（Elliptical Weighted Average）サンプリングループ**:
   - 偏微分ベクトルから長軸・短軸の比（Anisotropy Ratio）を算出し、最大 16 回のバイリニアサンプリングを行うループ制御を実装。
2. **重み付き平均アキュムレータ**:
   - サンプリングされた各テクセルをガウシアン重みで積算・正規化する演算器を追加。
3. **単体・回帰検証**:
   - 地面・壁面等の斜め視点テストパターンによるレンダリング検証。
   - R1 レビュー。

## 検証基準（受け入れ条件）

- 1x〜16x の Anisotropy 設定で正しく異方性フィルタリングが適用されること。
