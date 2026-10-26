<!-- awesome-plan project=amaterrace-gpu record=queue -->

# Queue Board

- Cycle ID: `q001`
- Status: `active`
- Approval: 2026-10-26 17:59 ユーザー指示「N=1で実行してください。」（`q001-i01` Step A を承認）
- Focus: [fg001](master.md#current-focused-goals)
- Target WS: [WS001](ws001/ws.md)

## 実行中のアイテム

| 試行 ID | 担当レーン | 対象 Phase | 範囲 | 状態 | 依存 | 選定理由・再開点 |
| :---: | :---: | :--- | :--- | :---: | :---: | :--- |
| `q001-i01` | **P1 / T1** | [ws001-p001](ws001/phase001/phase.md) | Step A: 階層移動（`rtl/library/{arith,bus,fp}`・`rtl/bsp/`）＋FP 統合＋`arith-lint 0` | cleared | なし | 実装・マージ・テスト（確かめ 1・3）全 109 本 PASS で完了。 |
| `q001-i02` | **P1 / T1** | [ws001-p001](ws001/phase001/phase.md) | Step B: `am_mul.v` の全幅 `DSP48E1` カスケード実装（`SYNTH_KINTEX7`）＋等価検証（確かめ 2） | cleared | `q001-i01` | 実装・マージ完了。76 インスタンス対等価検証 PASS。板合成（確かめ 4）バックグラウンド実行中。 |
| `q001-i03` | **P1** | [ws001-p002](ws001/phase002/phase.md) | GHCI 1.1 起動ハンドシェイク規格化（INIT/INIT_ACK 相互認証）& 診断レジスタ（CP_PC/STATUS/PIPE_FSM）実装 | in-progress | `q001-i02` | ユーザー「次のフェーズをキューに入れて実行してもよい」指示に基づき着手。 |
| `q001-i04` | **P2** | [ws001-p007](ws001/phase007/phase.md) | GHCI 2.0 スリム MMIO 化 & インメモリ PSO・構造化コマンドパケット仕様策定・ヘッダ整備 | in-progress | `q001-i02` | ユーザー指示に基づき、P2 レーンで先行仕様・ヘッダ定義に着手。 |

## サブエージェント実行状態（N=2）

| レーン | 担当エージェント | モデル | 状態 | 現在のタスク | 次の候補 |
| :---: | :---: | :---: | :---: | :--- | :--- |
| **P1** | 実装 | Claude Opus 5.5 Medium | active | `q001-i03`: `ws001-p002` INIT 双方向ハンドシェイク & 診断 MMIO 実装 | T1 へテスト依頼 |
| **P2** | 設計・ドキュメント | Claude Opus 5.5 Medium | active | `q001-i04`: `ws001-p007` GHCI 2.0 スリム MMIO 仕様・PSO 構造体定義 | CP パーサー刷新 |
| **P3〜P8** | 実装 | Claude Opus 5.5 Medium | unassigned | — | $N$ 増加時に割り当て |
| **T1** | テスト | 標準 / Flash | idle | Step A 回帰試験完了（待機中） | `q001-i03` テスト検証 |
| **T2〜T8** | テスト | （標準 / Flash） | idle | — | テスト並列度増加時に使用 |

## Upcoming Work Outlook（見通し）

1. **[ws001-p001](ws001/phase001/phase.md)**: Step A（マージ完了）→ Step B（`am_mul` DSP48E1 カスケード実装中・板ビルド）。
2. **[ws001-p002](ws001/phase002/phase.md)**: GHCI 1.1 起動ハンドシェイク規格化 & 診断ダンプ強化（R1 敵対的レビュー対応、最優先）。
3. **[ws001-p003](ws001/phase003/phase.md)**: 共有 L2 キャッシュ（LLC）導入 & キャッシュコヒーレンシ再構築。
4. **[ws001-p004](ws001/phase004/phase.md)**: IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定 & 実装。
5. **[ws001-p005](ws001/phase005/phase.md)**: マルチエンジン独立キュー & ハードウェアプリエンプション。
6. **[ws001-p006](ws001/phase006/phase.md)**: 細粒度同期 & Vulkan 1.0 必須機能補完。
7. **[ws001-p007](ws001/phase007/phase.md)**: GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新。
8. **DC の 200 MHz クロック領域分離**: SYSCLK 直結による 720p scanout アンダーフロー解消。
9. **ブロック別パイプライン化**: SU → TU → ROP … の順に各ブロックの乗算・演算器遅延を LAT=3 に合わせてパイプライン化。
