<!-- awesome-plan project=amaterrace-gpu record=queue -->

# Queue Board

- Cycle ID: `q001`
- Status: `active`
- Approval: 2026-10-26 21:05 ユーザー指示「推奨で行きます。」（`q001-i06` ws001-p003 を承認）
- Focus: [fg001](master.md#current-focused-goals)
- Target WS: [WS001](ws001/ws.md)

## 実行中のアイテム

| 試行 ID | 担当レーン | 対象 Phase | 範囲 | 状態 | 依存 | 選定理由・再開点 |
| :---: | :---: | :--- | :--- | :---: | :---: | :--- |
| `q001-i01` | **P1 / T1** | [ws001-p001](ws001/phase001/phase.md) | Step A: 階層移動（`rtl/library/{arith,bus,fp}`・`rtl/bsp/`）＋FP 統合＋`arith-lint 0` | cleared | なし | 実装・マージ・テスト（確かめ 1・3）全 109 本 PASS で完了。 |
| `q001-i02` | **P1 / T1** | [ws001-p001](ws001/phase001/phase.md) | Step B: `am_mul.v` の完全な `DSP48E1` 直接インスタンス化（`*` 完全撤廃、内部レジスタ・カスケード結線） | verifying | `q001-i01` | P1 実装完了・main マージ済。現在 T1 にてテスト検証中。 |
| `q001-i03` | **P1 / T1** | [ws001-p002](ws001/phase002/phase.md) | GHCI 1.1 起動ハンドシェイク規格化（INIT/INIT_ACK 相互認証）& 診断レジスタ（CP_PC/STATUS/PIPE_FSM）実装 | verifying | `q001-i02` | P1 実装完了・main マージ済。現在 T1 にてテスト検証中。 |
| `q001-i04` | **P2** | [ws001-p007](ws001/phase007/phase.md) | GHCI 2.0 スリム MMIO 化 & インメモリ PSO・構造化コマンドパケット仕様策定・ヘッダ整備 | cleared | `q001-i02` | `docs/ghci.md` §3/§7/§8 改定および `include/ghci_*.h` 整備完了（コミット `b9af41a`, `592a70a`）。 |
| `q001-i05` | **P2 / R1** | [ws001-p008](ws001/phase008/phase.md) | FP 演算ライブラリ再編 & 統合 FPU コア（am_fpu_core）実装（Step 1-4 完了、R1 レビュー中） | verifying | `q001-i04` | i2f/f2fix/fdiv ライブラリ化・am_fpu_core 実装・atg_su_fpu 置換完了（コミット `349c8b2`）。現在 R1 審査中。 |
| `q001-i06` | **P1** | [ws001-p003](ws001/phase003/phase.md) | 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築 | in-progress | `q001-i03` | ユーザー承認（「推奨で行きます」）に基づき着手。MC 前段に LLC を導入。 |

## サブエージェント実行状態（N=2）

| レーン | 担当エージェント | モデル | 状態 | 現在のタスク | 次の候補 |
| :---: | :---: | :--- | :--- | :--- | :--- |
| **P1** | 実装 | Claude Opus 5.5 Medium | active | `q001-i06`: `ws001-p003` 共有 L2 キャッシュ（LLC）設計・実装 | 統合テスト |
| **P2** | 設計・ドキュメント | Claude Opus 5.5 Medium | active | `q001-i05`: `ws001-p008` 統合コア am_fpu_core 設計 | SU 置換・テスト |
| **P3〜P8** | 実装 | Claude Opus 5.5 Medium | unassigned | — | $N$ 増加時に割り当て |
| **T1** | テスト | 標準 / Flash | active | `q001-i02`, `q001-i03` 回帰・等価試験実行中 | `q001-i05`, `q001-i06` テスト |
| **T2〜T8** | テスト | （標準 / Flash） | idle | — | テスト並列度増加時に使用 |

## Upcoming Work Outlook（見通し）

1. **[ws001-p001](ws001/phase001/phase.md)**: Step A（マージ完了）→ Step B（`am_mul` DSP48E1 カスケード実装中・板ビルド）。
2. **[ws001-p002](ws001/phase002/phase.md)**: GHCI 1.1 起動ハンドシェイク規格化 & 診断ダンプ強化（R1 敵対的レビュー対応、最優先）。
3. **[ws001-p003](ws001/phase003/phase.md)**: 共有 L2 キャッシュ（LLC）導入 & キャッシュコヒーレンシ再構築。
4. **[ws001-p004](ws001/phase004/phase.md)**: IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定 & 実装。
5. **[ws001-p005](ws001/phase005/phase.md)**: マルチエンジン独立キュー & ハードウェアプリエンプション。
6. **[ws001-p006](ws001/phase006/phase.md)**: 細粒度同期 & Vulkan 1.0 必須機能補完。
7. **[ws001-p007](ws001/phase007/phase.md)**: GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新。
8. **[ws001-p008](ws001/phase008/phase.md)**: FP 演算ライブラリ再編 & 統合 FPU コア（am_fpu_core）実装。
9. **DC の 200 MHz クロック領域分離**: SYSCLK 直結による 720p scanout アンダーフロー解消。
10. **ブロック別パイプライン化**: SU → TU → ROP … の順に各ブロックの乗算・演算器遅延を LAT=3 に合わせてパイプライン化。
