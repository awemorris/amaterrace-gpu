<!-- awesome-plan project=amaterrace-gpu record=ws001-p006 -->

# Phase 006: 細粒度同期（Timeline Semaphore / パイプラインバリア）& Vulkan 1.0 必須機能補完

- **親**: [WS001](../ws.md)
- **状態**: `cleared`
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
4. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp_seq_dec.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/vf/atg_vf.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_blend.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_filter.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/cp/atg_cp.md`

### 2. モジュールインターフェース設計と新設パケット
- `BARRIER` パケット: `{16'h0020, srcStageMask[7:0], dstStageMask[7:0], accessMask[15:0]}`。
- `SEMAPHORE_WAIT` / `SEMAPHORE_SIGNAL` パケット: 64-bit メモリアドレスおよび 64-bit 比較値を指定。
- ROP: `dualSrcBlend`（`src1_color` 入力）および `logicOp`（16 種のビット演算）サポート。

### 3. RTL アーキテクチャ詳細
- **ステージ別トラッキング**: パイプライン各ステージ（VF, SU, RX, TU, ROP）のインフライトカウンタを保持。
- **バリア評価**: `srcStageMask` に指定されたステージのカウンタが 0 になるまで、`dstStageMask` のステージへの新規イシューをゲーティング。
- **MDI（MultiDrawIndirect）**: コマンドバッファ内の間接描画引数配列（`VkDrawIndexedIndirectCommand`）を VF の DMA が連続フェッチして自動ドローコール展開。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 64-bit セマフォ比較、インフライトカウンタには `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テスト検証**:
  ```bash
  ./fw/cp/tests/run.sh
  ./sim/run.sh atg_top_barrier
  python3 tools/arith-lint.py
  ```
- ステージ間バリアでパイプライン全体を止めずに必要なステージのみが正しくインターロックされることを確認。

---

## 検証基準（受け入れ条件）

- バリア発行時に必要なステージのみが同期され、パイプライン稼働率が向上すること。
- Vulkan CTS における MDI、DualSrcBlend、LogicOp、Aniso テストケースが PASS すること。
- R1 レビュー APPROVE 獲得。
