<!-- awesome-plan project=amaterrace-gpu record=ws002-p002 -->

# Phase 002: SU / ROP Dual Source Blending（フォント描画用 src1 カラー出力）

- **親**: [WS002](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p010](../../ws001/phase010/phase.md), [ws002-p001](../phase001/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

サブピクセルフォントレンダリング等で必須となる Dual Source Blending（`SRC1_COLOR`, `ONE_MINUS_SRC1_COLOR`, `SRC1_ALPHA`, `ONE_MINUS_SRC1_ALPHA`）をサポートするため、SU のフラグメントエクスポートパスおよび ROP ブレンド入力パスを拡張する。

## 範囲・作業内容

1. **SU エクスポートパス拡張**:
   - `atg_su_exp.v` において、フラグメントシェーダのロケーション 0 (`src0`) およびロケーション 1 (`src1`) のカラー出力を ROP へ転送するバス拡張。

2. **ROP ブレンドファクタ拡張**:
   - `atg_rop_blend.v` に `src1` を第 2 ソースとして選択可能なファクタ生成ロジックを追加。

3. **単体・回帰検証**:
   - フォントレンダリングを模擬したシミュレーションテストベンチ新設。
   - `sim/verilator/run.sh` PASS。
   - R1 レビュー。

## 検証基準（受け入れ条件）

- Dual Source Blending の全ファクタが仕様通り正確に計算されること。
