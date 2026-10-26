<!-- awesome-plan project=amaterrace-gpu record=ws001-p006 -->

# Phase 006: 細粒度同期（Timeline Semaphore / パイプラインバリア）& Vulkan 1.0 必須機能補完

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p003](../phase003/phase.md), [ws001-p005](../phase005/phase.md)
- **優先度**: Major
- **出典**: R1 敵対的仕様レビュー（観点2 & 4: Complete Fence による性能低下、Vulkan 1.0 必須機能欠落）

## 目的

「全パイプライン停止」しかできない粗野な同期機構（FENCE / WAIT_IDLE）から、ステージ間細粒度バリアおよび 64-bit タイムラインセマフォへ移行する。あわせて、Vulkan 1.0 コア仕様で欠落していた必須グラフィックス機能（MultiDrawIndirect、DualSourceBlend、LogicOp、異方性フィルタリング）を補完する。

## 範囲・作業内容

1. **細粒度パイプラインバリア（`BARRIER` マイクロオプ）の導入**:
   - `srcStageMask` / `dstStageMask`、およびキャッシュフラッシュ範囲の指定。
2. **64-bit タイムラインセマフォ（`TIMELINE_SEMAPHORE`）の実装**:
   - 単調増加カウンタによる多対多の非同期同期サポート。
3. **欠落グラフィックス機能の補完**:
   - **VF**: MultiDrawIndirect (MDI) ハードウェアアクセラレータ。
   - **ROP**: デュアルソースブレンディング（`dualSrcBlend`）および論理演算（Logic Op）。
   - **TU**: 異方性フィルタリング（最大 16x Anisotropic Filtering）。

## 検証基準（受け入れ条件）

- バリア発行時に必要なステージのみが同期され、パイプライン稼働率が向上すること。
- Vulkan CTS における MDI、DualSrcBlend、LogicOp、Aniso テストケースが PASS すること。
