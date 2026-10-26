<!-- awesome-plan project=amaterrace-gpu record=ws001-p007 -->

# Phase 007: GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新

- **親**: [WS001](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p002](../phase002/phase.md), [ws001-p004](../phase004/phase.md)
- **優先度**: Critical (根本設計刷新)
- **完了日**: 2026-10-27
- **レビュー結果**: R1 APPROVE (2026-10-27)
- **出典**: ユーザー諮問（GHCI レジスタ多すぎ問題の解消、最小限レジスタセット、コマンド/ディスクリプタ移行）および R1 設計提案

## 目的

現行 GHCI の MMIO 空間の 95% 以上を占有している 512 ワード以上の固定機能 `STATE` レジスタ群（0x1000〜0x1BFC）および `SET_REG` 連打プロトコルをホスト MMIO から完全撤廃する。
NVMe や Virtio-GPU のように、真に最小限のホスト MMIO レジスタセット（全 19 レジスタ／約 76 バイト）へスリム化し、Vulkan / Metal 等のモダン API と完全に整合する「インメモリ不変パイプライン状態（Immutable PSO）」、「ディスクリプタテーブル」、および「構造化グラフィックス・コマンドパケット体系」へ全面刷新する。

## 範囲・作業内容

1. **最小限ホスト MMIO レジスタセット（全 19 レジスタ / 76 バイト）への再編**:
   - `STATE[0..511]` (0x1000〜0x1BFC)、`KICK`、`DBG_*`、`APERTURE_*`、`FENCE_LAST` をホスト MMIO から完全撤廃（BAR0 は 4KB/1ページで完結）。
   - 残すレジスタ:
     - 識別・能力: `GHCI_MAGIC` (0x00), `GHCI_VERSION` (0x04), `DEVICE_CAPS` (0x08), `EXTCAP_PTR` (0x0C)
     - 制御・状態: `CTRL` (0x10), `STATUS` (0x14), `IRQ_STATUS` (0x18), `IRQ_ENABLE` (0x1C)
     - コマンドリング: `RING_BASE_LO/HI` (0x20/0x24), `RING_SIZE` (0x28), `RING_RPTR` (0x2C), `RING_WPTR` (0x30 / Doorbell)
     - 障害・診断: `FAULT_INFO` (0x34), `FAULT_ADDR_LO/HI` (0x38/0x3C), `DIAG_CP_PC` (0x40), `DIAG_CP_STATUS` (0x44), `SCRATCH` (0x48)

2. **インメモリ・ディスクリプタ体系の導入**:
   - **不変パイプライン状態（`GhciPipelineState: PSO`）**: 頂点レイアウト、シェーダー基底、ラスタライザ、ブレンド、深度ステンシル等の不変設定を 64〜128 バイトのメモリ構造体に事前ビルド。
   - **リソース・ディスクリプタテーブル（`DescriptorTable`）**: テクスチャ、サンプラ、バッファの設定配列をメモリ上に配置。
   - **動的状態（Dynamic State）**: ビューポート、シザー、デプスバイアス等をコマンドリング上のインライン可変長パケットとして送信。

3. **構造化コマンドパケット体系の新設（旧 `SET_REG` 連打の全廃）**:
   - `CMD_BIND_PIPELINE` (0x20): `[u64 pso_gpu_va]`
   - `CMD_BIND_VERTEX_BUFFERS` (0x21): 頂点バッファ配列
   - `CMD_BIND_INDEX_BUFFER` (0x22): インデックスバッファ
   - `CMD_BIND_DESCRIPTOR_TABLE` (0x23): ディスクリプタテーブル
   - `CMD_SET_VIEWPORT` (0x24), `CMD_SET_SCISSOR` (0x25), `CMD_SET_DYNAMIC_STATE` (0x26)
   - `CMD_DRAW` (0x27), `CMD_DRAW_INDEXED` (0x28)
   - `CMD_DRAW_INDIRECT` (0x29): MultiDrawIndirect ネイティブ対応
   - `CMD_DISPATCH` (0x30): コンピュートディスパッチ
   - `CMD_BARRIER` (0x31): ステージマスク付き細粒度バリア
   - `CMD_EXECUTE_COMMANDS` (0x32): ★UMA 最適化！CPU がメモリ上に直接構築したセカンダリコマンド列を GPU がゼロコピー・直接フェッチ実行

4. **CP ファームウェア（RV32IM）のパーサー全面刷新**:
   - `fw/cp/` 内の `SET_REG` デコーダを全廃し、構造化コマンドパーサーを実装。
   - `CMD_BIND_PIPELINE` 受信時に PSO 構造体を DMA フェッチし、内部ハードウェアへ一括ディスパッチ。

5. **RTL ハードウェア（`rtl/gpu/cp/`）の軽量化**:
   - 巨大なホスト MMIO デコーダから STATE アレイロジック（BRAM/LUT）を削除し、回路規模を節約。

## 検証基準（受け入れ条件）

- ホスト MMIO 空間が 19 レジスタ（76 バイト）のみで動作し、STATE レジスタが皆無であること。
- 新しい構造化コマンド（`CMD_BIND_PIPELINE`、`CMD_DRAW`、`CMD_EXECUTE_COMMANDS` 等）を用いて三角形描画・テクスチャマッピングが正常に動作すること。
- CPU 側の MMIO アクセス回数が大幅に削減され、ドローコール発行スループットが劇的に向上すること。

---

## 実施記録

- **担当**: P2 (Claude Opus 5.5)
- **コミット**: `5d5f819` (`WIP`)
- **実装内容**:
  1. `rtl/gpu/cp/atg_cp_regs.v`: パラメータ `SLIM_MMIO` 追加。19 レジスタ（0x000〜0x048）の厳格デコード、ホスト STATE アクセス完全遮断（`alias_we = 0`, リード値 0）。
  2. `rtl/gpu/cp/atg_cp_seq_dec.v`, `atg_cp_seq.v`, `atg_cp_seq_wait.v`: GHCI 2.0 構造化コマンドパケット（`CMD_BIND_PIPELINE` 0x20 〜 `CMD_FENCE` 0x33）デコードおよびステージ別ビジー待機、キック・フェンス発行。
  3. `fw/cp/ghci2_cmd.c`, `fw/cp/cmd.c`, `fw/cp/fw.h`: 不変 PSO DMA フェッチ & 内部レジスタディスパッチ、ビューポート/シザー動的状態、セカンダリコマンドバッファ直接実行。
  4. `sim/tb/atg_ghci2_slim_tb.v`: 全 19 MMIO レジスタ、STATE アクセス遮断、全構造化コマンドデコードの総合単体テストベンチ。
- **検証結果**:
  - `sim/run.sh atg_ghci2_slim`: PASS (1 s)
  - `fw/cp/tests/run.sh`: 全 14 テスト PASS
  - `tools/arith-lint.py`: 全域で 0 operators outside rtl/library/arith
  - 回帰: `atg_cp_regs` PASS, `atg_top_barrier` PASS, `atg_cp_multi_queue` PASS, `atg_top` PASS (22 s)
