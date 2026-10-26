<!-- awesome-plan project=amaterrace-gpu record=queue -->

# Queue Board

- Cycle ID: `q001`
- Status: `active`
- Approval: 2026-10-26 21:39 ユーザー指示「p009として定義して、スケジュールしてください。」
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
| `q001-i08` | **P1 または P3** | [ws001-p009](ws001/phase009/phase.md) | 算術演算ライブラリ（am_shift Bit Reversal 1本化、am_div 非回復法化）の物理最適化 | queued | `q001-i02` | ユーザー承認に基づき登録。P1 (L2完了後) または P3 起動時に着手。 |
| `q001-i09` | **P1〜P8 待機** | [ws001-p014](ws001/phase014/phase.md) | 8-bit unorm 高速ブレンド & div255 1段化（Lerp 変形・乗算器半減、遅延 75% 削減） | queued | `q001-i01` | ユーザー承認（2026-10-26）に基づきスケジュール。即時着手可能。 |
| `q001-i10` | **P1〜P8 待機** | [ws001-p015](ws001/phase015/phase.md) | fp32 / sRGB ブレンド完全ストリームパイプライン化（FSM 撤廃・1 beat/cycle 100倍高速化） | queued | `q001-i09` | ユーザー承認に基づきスケジュール。4段ストリームパイプライン。 |
| `q001-i11` | **P1〜P8 待機** | [ws001-p016](ws001/phase016/phase.md) | Hazard Tracker（Pixel Lock）導入 & ROP 完全パイプライン化（Stop-and-Wait 根絶） | queued | `q001-i10` | ユーザー承認に基づきスケジュール。フィルレート 20〜50 倍向上。 |
| `q001-i12` | **P1〜P8 待機** | [ws001-p017](ws001/phase017/phase.md) | ROP L1 タイルキャッシュ導入 & 外部メモリスラッシング解消（8KB Color/Depth） | queued | `q001-i11`, `q001-i06` | ユーザー承認に基づきスケジュール。DRAM トラフィック 70〜80% 削減。 |
| `q001-i13` | **P1〜P8 待機** | [ws001-p018](ws001/phase018/phase.md) | TU 4 レーン並列ストリームアドレス生成（atg_tu_addr 逐次 FSM 撤廃・1 cycle/quad 化） | queued | `q001-i01` | ユーザー承認（2026-10-26）に基づきスケジュール。即時着手可能。 |
| `q001-i14` | **P1〜P8 待機** | [ws001-p019](ws001/phase019/phase.md) | TU フィルタリングパイプライン統合 & 相互排他ウェイト撤廃（u_idle/f_idle 撤廃） | queued | `q001-i13` | ユーザー承認に基づきスケジュール。完全ストリーム化。 |
| `q001-i15` | **P1〜P8 待機** | [ws001-p020](ws001/phase020/phase.md) | TU マルチバンク・4-way L1 テクスチャキャッシュ（4 バンク同時読み出し） | queued | `q001-i13` | ユーザー承認に基づきスケジュール。16テクセル逐次ルックアップ撤廃。 |
| `q001-i16` | **P1〜P8 待機** | [ws001-p021](ws001/phase021/phase.md) | TU MSHR ノンブロッキングフェッチ & メモリ統合（Hit-Under-Miss、実効スループット 30〜50倍） | queued | `q001-i15`, `q001-i06` | ユーザー承認に基づきスケジュール。1 Outstanding 完全停止解消。 |

## サブエージェント実行状態（N=2）

| レーン | 担当エージェント | モデル | 状態 | 現在のタスク | 次の候補 |
| :---: | :---: | :--- | :--- | :--- | :--- |
| **P1** | 実装 | Claude Opus 5.5 Medium | active | `q001-i06`: `ws001-p003` 共有 L2 キャッシュ（LLC）設計・実装 | `q001-i08`: `ws001-p009` |
| **P2** | 設計・実装 | Claude Opus 5.5 Medium | active | `q001-i07`: `ws001-p004` IOMMU 連携 & CP 自律型 MMU 仕様策定・設計・RTL 実装 | R1 レビュー |
| **P3〜P8** | 実装 | Claude Opus 5.5 Medium | unassigned | — | $N=3$ 拡張時に `q001-i08` を割り当て可能 |
| **T1** | テスト | 標準 / Flash | active | システム回帰テスト（Verilator 7 モード ALL PASS 達成） | L2 キャッシュ検証 |
| **R1** | レビュー | Gemini 4 Argon Medium | active | Phase 001/002/008 APPROVE 承認完了 | 次期実装成果物レビュー |

## Upcoming Work Outlook（見通し）

1. **[ws001-p001](ws001/phase001/phase.md)**: 完了（Step A・Step B ともに完了確定）。
2. **[ws001-p002](ws001/phase002/phase.md)**: 完了（GHCI 1.1 INIT & 診断 MMIO レジスタ実装・R1 承認完了）。
3. **[ws001-p003](ws001/phase003/phase.md)**: 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築（P1 実行中）。
4. **[ws001-p004](ws001/phase004/phase.md)**: IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定 & 実装（P2 実行中）。
5. **[ws001-p009](ws001/phase009/phase.md)**: 算術演算ライブラリ（`am_shift` 右シフタ 1 本化、`am_div` 非回復法化）の物理最適化（キュー登録済）。
6. **[ws001-p005](ws001/phase005/phase.md)**: マルチエンジン独立キュー & ハードウェアプリエンプション。
7. **[ws001-p006](ws001/phase006/phase.md)**: 細粒度同期 & Vulkan 1.0 必須機能補完。
8. **[ws001-p007](ws001/phase007/phase.md)**: GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新（ヘッダ・仕様完了）。
9. **[ws001-p008](ws001/phase008/phase.md)**: 完了（FP 演算ライブラリ再編 & 統合 FPU コア am_fpu_core 実装・R1 承認完了）。
10. **DC の 200 MHz クロック領域分離**: SYSCLK 直結による 720p scanout アンダーフロー解消。
11. **[ws001-p010](ws001/phase010/phase.md)**: SU パイプライン真の 6 段化（Real Pipelining: 演算負荷の均等分散）。
12. **[ws001-p011](ws001/phase011/phase.md)**: オペランドフォワーディング（Bypass ネットワーク）の実装（RAW ストール根絶）。
13. **[ws001-p012](ws001/phase012/phase.md)**: スコアボード主導型ワープスケジューラ（GTO & Replay 根絶）。
14. **[ws001-p013](ws001/phase013/phase.md)**: レジスタファイル最適化（時間差読み出しによる BRAM 半減・マルチ SU 面積削減）。
15. **[ws001-p014](ws001/phase014/phase.md)**: 8-bit unorm 高速ブレンド & div255 1段化（Lerp 最適化・乗算器半減）。
16. **[ws001-p015](ws001/phase015/phase.md)**: fp32 / sRGB ブレンド完全ストリームパイプライン化（FSM 撤廃・1 beat/cycle）。
17. **[ws001-p016](ws001/phase016/phase.md)**: Hazard Tracker（Pixel Lock）導入 & ROP 完全パイプライン化（Stop-and-Wait 根絶）。
18. **[ws001-p017](ws001/phase017/phase.md)**: ROP L1 タイルキャッシュ導入 & 外部メモリスラッシング解消。
19. **[ws001-p018](ws001/phase018/phase.md)**: TU 4 レーン並列ストリームアドレス生成（atg_tu_addr 逐次 FSM 撤廃・1 cycle/quad 化）。
20. **[ws001-p019](ws001/phase019/phase.md)**: TU フィルタリングパイプライン統合 & 相互排他ウェイト撤廃。
21. **[ws001-p020](ws001/phase020/phase.md)**: TU マルチバンク・4-way L1 テクスチャキャッシュ（4 バンク同時読み出し）。
22. **[ws001-p021](ws001/phase021/phase.md)**: TU MSHR ノンブロッキングフェッチ & メモリ統合（Hit-Under-Miss）。
23. **[WS002](ws002/ws.md)**: Vulkan 1.0 仕様適合性・グラフィックス機能補完（Logic Op、Dual Source、MRT 8、Aniso 16x、Seamless Cube、BC 圧縮等、後回し）。
24. **RX パイプライン化**: 各ブロックの乗算・演算器遅延を LAT=3 に合わせてパイプライン化。
