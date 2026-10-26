<!-- awesome-plan project=amaterrace-gpu record=ws001-p004 -->

# Phase 004: IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定 & 実装

- **親**: [WS001](../ws.md)
- **状態**: `in-progress`
- **担当**: P2 (Architecture & Implementation) / R1 (Review)
- **依存**: [ws001-p002](../phase002/phase.md)
- **優先度**: Critical
- **出典**: ユーザー設計方針（独自商用OS、Unified Memory前提、IOMMU＋CP管理MMU、TLB隠蔽）および R1 再評価レポート

## 目的

Linux DRM/TTM/dma-buf 等の過剰なレガシー抽象化を完全に排除し、Apple Silicon（DART IOMMU + AGX ファームウェア管理 MMU）や最新ゲーム専用機（PS5/Switch）と同等の**「極薄ホストドライバ ＋ 統合メモリ（Unified Memory）直結 ＋ CP 自律型 MMU」**アーキテクチャを確立する。ホストドライバにはページテーブル構造や TLB 操作を一切露出させず、CP（RV32IM）が内部ヒープ上でページテーブルと TLB 無効化を自律完結する。

## 範囲・作業内容

1. **GHCI 仕様改定（極薄インターフェース）**:
   - ホスト管理 GTT / 多段ページテーブル、およびホスト向け `TLB_INVALIDATE` 命令・レジスタの記述を完全削除。
   - コマンドリング上のシンプルな gpu-op を策定:
     - `VM_MAP` (0x10110): `session_id`, `flags (READ, WRITE, EXEC, COHERENT, WC)`, `gpu_va`, `iova_or_phys`, `size_bytes`
     - `VM_UNMAP` (0x10111): `session_id`, `flags`, `gpu_va`, `size_bytes`
   - `FAULT_INFO` に `FAULT_GPU_PAGE_FAULT` / `FAULT_GPU_PERM_VIOLATION`、`session_id`、`FAULT_ADDR (GPU VA)` を追加（アプリ違反を内部トラップし、システム IOMMU パニックを防止）。

2. **ハードウェア RTL（MMU モジュール `atg_mmu`）**:
   - **L1 TLB**: 各ユニット直近（VF, SU, TU, ROP, BLT）での 1 サイクル変換。
   - **L2 TLB**: メモリコントローラ（MC）前段の共有 TLB。
   - **Hardware Page Table Walker**: TLB ミス時にメモリ（UMA/VRAM）上のページテーブルを自律探索して TLB に自動装填するハードウェアステートマシン。
   - **In-Flight カウンタ & 内部 MMIO**: 発行中メモリアクセス監視と、CP から叩く内部レジスタ（`MMU_PT_ROOT`, `MMU_TLB_FLUSH`）。

3. **CP ファームウェア（`fw/cp/mmu.c`）**:
   - 内部ヒープからの 2 段ページテーブル（4KB ページ）動的確保・更新。
   - `VM_MAP` / `VM_UNMAP` ハンドラの実装（PTE 作成・更新、In-Flight ドレイン後の自律 TLB フラッシュ発行）。
   - クライアントセッション終了時の自律的ページテーブル解放（メモリリーク防止）。

4. **商用独自 OS 向け薄型ドライバ仕様 & ガイド**:
   - システム / PCIe IOMMU と連携した UMA 物理オフセット / IOVA 直渡しによるゼロコピーバッファ共有ガイドの策定。

## 検証基準（受け入れ条件）

- ホストが `VM_MAP` を 1 回発行するだけで、CP が自律的にページテーブルを構築し、Hardware Page Table Walker により GPU から正しくアクセスできること。
- `VM_UNMAP` 発行時に、CP 内部で実行中メモリアクセスがドレインされた後に TLB フラッシュが自律実行され、レースコンディションが発生しないこと。
- 不正メモリアクセス発生時に外部バスへ異常アクセスを出さず、`FAULT_INFO` に該当 `session_id` と `GPU VA` が記録され、OS 側で該当プロセスのみを特定・終了できること。
