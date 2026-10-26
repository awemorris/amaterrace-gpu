<!-- awesome-plan project=amaterrace-gpu record=queue -->

# Queue Board

- Cycle ID: `q001`
- Status: `active`
- Approval: 2026-10-26 21:05 ユーザー指示「推奨で行きます。」（`q001-i06` ws001-p003 を承認）
- Focus: [fg001](master.md#current-focused-goals)
- Target WS: [WS001](ws001/ws.md)

## 実行中のアイテム

| 試行 ID | 担当レーン | 対象 Phase | 範囲 | 状態 | 依存 | 選定理由・再開点 |
| :---: | :---: | :--- | :--- | :--- | :---: | :--- |
| `q001-i01` | **P1 / T1** | [ws001-p001](ws001/phase001/phase.md) | Step A: 階層移動（`rtl/library/{arith,bus,fp}`・`rtl/bsp/`）＋FP 統合＋`arith-lint 0` | cleared | なし | 実装・マージ・テスト（確かめ 1・3）全 109 本 PASS で完了。 |
| `q001-i02` | **P1 / R1** | [ws001-p001](ws001/phase001/phase.md) | Step B: `am_mul.v` の完全な `DSP48E1` 直接インスタンス化（`*` 完全撤廃、内部レジスタ・カスケード結線） | cleared | `q001-i01` | 再実装完了。unisim 76 構成全 PASS。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i03` | **P1 / R1** | [ws001-p002](ws001/phase002/phase.md) | GHCI 1.1 起動ハンドシェイク規格化（INIT/INIT_ACK 相互認証）& 診断レジスタ（CP_PC/STATUS/PIPE_FSM）実装 | cleared | `q001-i02` | 実装完了。ヘッダ競合・バージョン是正後、R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i04` | **P2** | [ws001-p007](ws001/phase007/phase.md) | GHCI 2.0 スリム MMIO 化 & インメモリ PSO・構造化コマンドパケット仕様策定・ヘッダ整備 | cleared | `q001-i02` | `docs/ghci.md` §3/§7/§8 改定および `include/ghci2_regs.h` 整備完了（コミット `bb80789`）。 |
| `q001-i05` | **P2 / R1** | [ws001-p008](ws001/phase008/phase.md) | FP 演算ライブラリ再編 & 統合 FPU コア（am_fpu_core）実装（Step 1-4 完了、R1 承認済） | cleared | `q001-i04` | i2f/f2fix/fdiv ライブラリ化・am_fpu_core 実装・atg_su_fpu 置換完了。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i06` | **P1** | [ws001-p003](ws001/phase003/phase.md) | 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築 | in-progress | `q001-i03` | ユーザー承認（「推奨で行きます」）に基づき着手。MC 前段に LLC を導入中。 |
| `q001-i07` | **P2** | [ws001-p004](ws001/phase004/phase.md) | IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定・アーキテクチャ設計・RTL 実装 | in-progress | `q001-i05` | ユーザー承認（「P2を起動してOKです」）に基づき着手。極薄ドライバ・自律 MMU 確立。 |

## サブエージェント実行状態（N=2）

| レーン | 担当エージェント | モデル | 状態 | 現在のタスク | 次の候補 |
| :---: | :---: | :--- | :--- | :--- | :--- |
| **P1** | 実装 | Claude Opus 5.5 Medium | active | `q001-i06`: `ws001-p003` 共有 L2 キャッシュ（LLC）設計・実装 | R1 レビュー |
| **P2** | 設計・実装 | Claude Opus 5.5 Medium | active | `q001-i07`: `ws001-p004` IOMMU 連携 & CP 自律型 MMU 仕様策定・設計・RTL 実装 | R1 レビュー |
| **P3〜P8** | 実装 | Claude Opus 5.5 Medium | unassigned | — | $N$ 増加時に割り当て |
| **T1** | テスト | 標準 / Flash | active | システム回帰テスト（Verilator 7 モード ALL PASS 達成） | L2 キャッシュ検証 |
| **R1** | レビュー | Gemini 4 Argon Medium | active | Phase 001/002/008 APPROVE 承認完了 | 次期実装成果物レビュー |

## Upcoming Work Outlook（見通し）

1. **[ws001-p001](ws001/phase001/phase.md)**: 完了（Step A・Step B ともに完了確定）。
2. **[ws001-p002](ws001/phase002/phase.md)**: 完了（GHCI 1.1 INIT & 診断 MMIO レジスタ実装・R1 承認完了）。
3. **[ws001-p003](ws001/phase003/phase.md)**: 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築（P1 実行中）。
4. **[ws001-p004](ws001/phase004/phase.md)**: IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定 & 実装。
5. **[ws001-p005](ws001/phase005/phase.md)**: マルチエンジン独立キュー & ハードウェアプリエンプション。
6. **[ws001-p006](ws001/phase006/phase.md)**: 細粒度同期 & Vulkan 1.0 必須機能補完。
7. **[ws001-p007](ws001/phase007/phase.md)**: GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新（ヘッダ・仕様完了）。
8. **[ws001-p008](ws001/phase008/phase.md)**: 完了（FP 演算ライブラリ再編 & 統合 FPU コア am_fpu_core 実装・R1 承認完了）。
9. **DC の 200 MHz クロック領域分離**: SYSCLK 直結による 720p scanout アンダーフロー解消。
10. **ブロック別パイプライン化**: SU → TU → ROP … の順に各ブロックの乗算・演算器遅延を LAT=3 に合わせてパイプライン化。
