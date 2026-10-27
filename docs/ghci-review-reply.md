# GHCI Review Reply - Version 12.0 (2026-10-28) - Commit: bea1ef9 (Final Signoff: N01〜N46 Fully Resolved)

GHCI ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 12 版（`ghci-review.md` 2026-10-28 03:47）を受理しました。

レビュー第 12 版において、すべての疑問点（N01〜N46）の解決が確認され、残存疑問 0 件（Critical: 0, High: 0, Medium: 0, Low: 0）および新矛盾 0 件であることが確定しました。これをもって GHCI 1.0 アーキテクチャ仕様書（`docs/ghci.md`）、C コマンドヘッダ（`include/ghci_cmd.h`）、および ISA 定義ヘッダ（`include/gsi1_isa.h`）のドライバ開発チームとの合意形成が 100% 完了（Final Signoff）したことを記録します。

なお、参考としてご指摘いただいた `include/gsi1_isa.h` 382 行の `GSI1_TEXSZ_SAMPLES` の旧注記（`CAPS[29]`）についても、`CAP_MSAA_4X` (`DEVICE_CAPS[31]`) へ完全更新いたしました（Commit: `bea1ef9`）。

---

## 1. 最終合意概要

- **対象仕様書**: `docs/ghci.md` (Commit `cf8be08`, 2782 行)
- **対象ヘッダ**: `include/ghci_cmd.h` (Commit `1a1fa85`), `include/gsi1_isa.h` (Commit `bea1ef9`)
- **解決総数**: N01〜N46 全 46 件完全解決（未解決 0 件）
- **ドライバ・コンパイラ影響**: 文書疑問によるドライバ実装およびシェーダコンパイラ開発の待ちは一切解消。zedBSD ドライバチームは `ghci.md cf8be08` / `bea1ef9` を正本としてドライバ設計（第 4 版）およびコンパイラバックエンド実装を完了可能。

---

## 2. 解決項目一覧（N01〜N46 総括）

| ID | 種別 | 概要 | 確定仕様・条文反映 |
| --- | --- | --- | --- |
| N01〜N36 | 完了 | GHCI 1.0 コア仕様・コマンド形式・MMU・キャッシュ制御等 | 第 9 版までに全件確定・承認済み |
| N37 | 完了 | シェーダステージ入出力インターフェース体系化 | §12.10.3 新設 (ABI、レジスタ配置、Export 番号、lda 補間) |
| N38 | 完了 | 頂点属性 Compact Consecutive ABI (16 属性スロット) | 有効スロット順の成分累積和配置、format==0無効化、60本超拒絶、CP自律設定 |
| N39 | 完了 | VertexIndex / InstanceIndex 配送ゲーティング | `used_regs_vs >= 62` 条件配送、r62 コンパイラスクラッチ専用化 |
| N40 | 完了 | PT Word 0..3 クリップ座標直接読出 & 64 Varying 完全開放 | lda で POS.w 直接読出、Position.w Varying 重複排除、PointSize 1.0 固定 |
| N41 | 完了 | lda 頂点インデックスと Provoking Vertex 規約 | 重心座標 b0..b2 対応、First Vertex 規約、Line/Point 未定義頂点規定 |
| N42 | 完了 | クリップからウィンドウ空間への変換式・Depth Clamp | Vulkan 標準変換式、CMD_SET_VIEWPORT 写像、Depth Clamp 時のクランプ |
| N43 | 完了 | 8 アタッチメント MRT エクスポート (`0x100 + 16k + c`) | `GHCI_EXP_COLOR(k, c)` & 7u、CAP_ROP_PACK 独立性 (コア機能) |
| N44 | 完了 | Dual-Source Blending SRC1 エクスポートターゲット | `0x108..0x10B` (`GHCI_EXP_COLOR0_SRC1`) への完全整合 |
| N45 | 完了 | 旧 GSI1 レガシー記述整理と機能フラグ正式化 | gsi1_isa.h の pre-1.0 明記、DEVICE_CAPS/EXT_CAP_FEATURE/PSO 名への統一 |
| N46 | 完了 | パイプライン作成拒絶時の表記整理 | Vulkan 戻り値名削除、純粋な仕様規定「reject pipeline creation」 |

---

## 3. 検証ステータス

- C ヘッダ構文検証: `gcc -fsyntax-only -Iinclude include/ghci_cmd.h include/gsi1_isa.h` $\rightarrow$ **PASS**
- 回帰シミュレーション: `./sim/run.sh atg_cp atg_ghci_slim` $\rightarrow$ **PASS** (100%)
- 禁止略語監査: リポジトリ全域 $\rightarrow$ **0 件完全維持**
- セッション分離・MMU 透過性要件: 完全遵守

DONE