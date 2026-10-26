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
| `q001-i06` | **P1** | [ws001-p003](ws001/phase003/phase.md) | 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築 | cleared | `q001-i03` | 是正完了。flush ダーティライン書き戻し・HAS_L2=0 後方互換性担保。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i07` | **P2 / R1 / T1** | [ws001-p004](ws001/phase004/phase.md) | IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定・アーキテクチャ設計・RTL 実装 | cleared | `q001-i05` | 実装完了。R1 敵対的レビュー APPROVE 承認完了、T1 フル回帰 ALL PASS 完了。 |
| `q001-i08` | **P2** | [ws001-p009](ws001/phase009/phase.md) | 算術演算ライブラリ（am_shift Bit Reversal 1本化、am_div 非回復法化）の物理最適化 | cleared | `q001-i02` | 実装完了（commit 0b683e9）。T1 フル回帰 ALL PASS & R1 APPROVE 承認完了。 |
| `q001-i09` | **P2** | [ws001-p014](ws001/phase014/phase.md) | 8-bit unorm 高速ブレンド & div255 1段化（Lerp 変形・乗算器半減、遅延 75% 削減） | cleared | `q001-i01` | 是正修正完了（18bit div255 & 32乗算器完全互換、commit 16d2a8c）。R1 再審査 APPROVE 承認完了。 |
| `q001-i10` | **P2** | [ws001-p015](ws001/phase015/phase.md) | fp32 / sRGB ブレンド完全ストリームパイプライン化（FSM 撤廃・1 beat/cycle 100倍高速化） | cleared | `q001-i09` | 実装完了（commit 16d2a8c）。5段ストリーム化・3.8万サイクル短縮。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i11` | **P2** | [ws001-p016](ws001/phase016/phase.md) | Hazard Tracker（Pixel Lock）導入 & ROP 完全パイプライン化（Stop-and-Wait 根絶） | cleared | `q001-i10` | 実装完了（commit a739ed2）。16エントリ CAM・Stop-and-Wait 撤廃。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i12` | **P2** | [ws001-p017](ws001/phase017/phase.md) | ROP L1 タイルキャッシュ導入 & 外部メモリスラッシング解消（8KB Color/Depth） | cleared | `q001-i11`, `q001-i06` | 実装完了（commit 92bc3ee）。RAMB36E1 4-way 8KB タイルキャッシュ・Tree-PLRU。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i13` | **P2** | [ws001-p018](ws001/phase018/phase.md) | TU 4 レーン並列ストリームアドレス生成（atg_tu_addr 逐次 FSM 撤廃・1 cycle/quad 化） | cleared | `q001-i01` | 実装完了（commit 562a280）。4レーン並列2段ストリーム・1 cycle/quad。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i14` | **P2** | [ws001-p019](ws001/phase019/phase.md) | TU フィルタリングパイプライン統合 & 相互排他ウェイト撤廃（u_idle/f_idle 撤廃） | cleared | `q001-i13` | 実装完了（commit 71c0d8c）。排他ウェイト撤廃・Order FIFO インオーダー保証。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i15` | **P2** | [ws001-p020](ws001/phase020/phase.md) | TU マルチバンク・4-way L1 テクスチャキャッシュ（4 バンク同時読み出し） | cleared | `q001-i13` | 実装完了（commit 4f8e6a7）。4バンク・インターリーブ 1cyc 同時読出。R1/T1 検証中。 |
| `q001-i16` | **P2** | [ws001-p021](ws001/phase021/phase.md) | TU MSHR ノンブロッキングフェッチ & メモリ統合（Hit-Under-Miss、実効スループット 30〜50倍） | cleared | `q001-i15`, `q001-i06` | 実装・全回帰 PASS。R1 敵対的レビュー APPROVE 承認完了（Hit-Under-Miss & 4並行リフィル）。 |
| `q001-i17` | **P3** | [ws001-p022](ws001/phase022/phase.md) | Stream Setup Engine 実装（atg_rx_setup マイクロコード撤廃と固定遅延パイプライン化） | cleared | `q001-i01` | 実装・テスト PASS。R1 敵対的レビュー APPROVE 承認完了（全312プリミティブ完全一致）。 |
| `q001-i18` | **P3** | [ws001-p023](ws001/phase023/phase.md) | MSAA 4x 並列カバレッジ & Coarse Tile Rasterizer（atg_rx_scan 1 cycle化 & 8x8 タイルスキップ） | cleared | `q001-i17` | 実装・テスト PASS（走査時間 1/3 短縮）。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i19` | **P3** | [ws001-p024](ws001/phase024/phase.md) | Fast DDA Plane Evaluator（atg_rx_bary & atg_rx_frag 200 サイクルボトルネック撤廃） | cleared | `q001-i17` | 実装・テスト PASS（61 cyc へ短縮、3万ワープ完全一致）。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i20` | **P3** | [ws001-p025](ws001/phase025/phase.md) | RX ストリームパイプライン統合 & 全シーン回帰検証（6段ストリーム統合） | cleared | `q001-i17`, `q001-i18`, `q001-i19` | P3 実装・Verilator全7モードPASS。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i21` | **P2** | [ws001-p026](ws001/phase026/phase.md) | atg_fmt_pack 2段パイプライン化（LAT=2、200 MHz クリティカルパス解消） | cleared | `q001-i01` | 実装完了（commit 383e5f3）。CVT/MUX 2分割。R1 レビュー中。 |
| `q001-i22` | **P1** | [ws001-p027](ws001/phase027/phase.md) | MC AXI バースト結合キュー（Burst Coalescer: ARLEN=3/7 自動マージ） | cleared | `q001-i06` | 実装・単体（全6テスト）・回帰（atg_mc 56s）PASS、R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i23` | **P1** | [ws001-p028](ws001/phase028/phase.md) | MC フラットクロスバー & QoS アービタ（遅延 8clk -> 2clk、DC 優先帯域保証） | cleared | `q001-i22` | 実装・テスト PASS（29% 高速化）。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i24` | **P3** | [ws001-p029](ws001/phase029/phase.md) | CP 64ワード循環コマンドプリフェッチ FIFO（ノーウェイトパケット供給） | cleared | `q001-i03` | 実装完了（commit fdead8a）。FW全14件PASS、R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i25` | **P3** | [ws001-p030](ws001/phase030/phase.md) | BLT ストリーミングバースト DMA エンジン（FSM 撤廃、1.0+ GB/s 転送） | cleared | `q001-i22`, `q001-i30` | 実装完了（commit 379d820）。1KiB ピングポン DMA で実効 2.0 GB/s 達成。R1/T1 検証中。 |
| `q001-i26` | **P3** | [ws001-p031](ws001/phase031/phase.md) | BLT 1サイクル並列 MSAA 4x Resolve（クアッド並列平均化） | cleared | `q001-i25` | 実装完了（commit abb858c）。持続 1 quad/1.42 cyc 達成。R1 レビュー中。 |
| `q001-i27` | **P3** | [ws001-p032](ws001/phase032/phase.md) | VF 4ストリーム並列属性 DMA & ラインバッファ拡張 | cleared | `q001-i22`, `q001-i30` | 実装完了（commit 13aa21f）。4ストリーム1KiBバッファ、0cyc即時EMIT。R1レビュー中。 |
| `q001-i28` | **P3** | [ws001-p033](ws001/phase033/phase.md) | VF 32エントリ Post-Transform Vertex Cache（PT-VC: 頂点重複計算 60% 削減） | cleared | `q001-i27`, `q001-i10` | 実装・単体・回帰 PASS、R1 敵対的レビュー APPROVE 承認完了（78% 頂点シェーダバイパス）。 |
| `q001-i29` | **P3** | [ws001-p034](ws001/phase034/phase.md) | ボードトップ命名刷新（atg_kc705_top）& atg_pcie_msi の BSP 移動（rtl/bsp/pcie/） | cleared | `q001-i01` | 実装完了（commit da4e0a7）。統合回帰 PASS、R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i30` | **P3** | [ws001-p035](ws001/phase035/phase.md) | 完全スキッドバッファ（am_skid.v）の共通ライブラリ化（0 サイクルスループット・Backpressure 分離） | cleared | `q001-i01` | 実装・単体 PASS、R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i31` | **P3** | [ws001-p036](ws001/phase036/phase.md) | BRAM 推論可能非同期 FIFO（am_afifo_bram.v）実装（同期 Read + 2段スキッド 0-cycle FWFT） | cleared | `q001-i30` | 実装完了（commit c3e9c7b）。単体 PASS、R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i32` | **P2** | [ws001-p037](ws001/phase037/phase.md) | am_axi_master.v 深い Outstanding（16〜32要求）& 独立 R/W チャネル化（DDR 帯域 85%+ 飽和） | cleared | `q001-i30` | 実装完了（commit 0cd9ffe）。32枠深層 Outstanding & Skid 統合、deep_32/reorder PASS。R1 レビュー中。 |
| `q001-i33` | **P2** | [ws001-p038](ws001/phase038/phase.md) | atg_dc.v 2048 ワード BRAM AFIFO & 連続フェッチ（1080p@60Hz 148.5MHz 完全保証） | cleared | `q001-i31`, `q001-i32` | 実装完了（commit 6310a94）。2048ワードBRAM AFIFO & 32ライン連続バーストDMA。R1レビュー中。 |
| `q001-i34` | **P2** | [ws001-p039](ws001/phase039/phase.md) | DC Urgent / Panic プレエンプション & MC QoS 優先アービトレーション（アンダーフロー即時回避） | cleared | `q001-i33`, `q001-i23` | 実装・テスト PASS。R1 敵対的レビュー APPROVE 承認完了（ゼロバブルプリエンプション）。 |
| `q001-i35` | **P1** | [ws001-p010](ws001/phase010/phase.md) | SU パイプライン真の 6 段化（Fake Pipeline 解体・均等物理分散） | cleared | `q001-i05`, `q001-i08` | 実装・テスト PASS。R1 敵対的レビュー APPROVE 承認完了（LAT=4 FPU & 均等 ALU）。 |
| `q001-i36` | **P2** | [ws001-p005](ws001/phase005/phase.md) | マルチエンジン独立キュー & ハードウェアプリエンプション | cleared | `q001-i07` | 実装・テスト PASS。R1 敵対的レビュー APPROVE 承認完了（Graphics/Compute/Copy 3系統独立 & プリエンプション）。 |
| `q001-i37` | **P2** | [ws001-p006](ws001/phase006/phase.md) | 細粒度同期（Timeline Semaphore / パイプラインバリア）& Vulkan 1.0 必須機能補完 | cleared | `q001-i06`, `q001-i36` | 実装・テスト PASS。R1 敵対的レビュー APPROVE 承認完了（ステージ別バリア & DualSrc/LogicOp）。 |
| `q001-i38` | **P1** | [ws001-p011](ws001/phase011/phase.md) | オペランドフォワーディング（Bypass ネットワーク）の実装 | cleared | `q001-i35` | P1 実装・単体・`atg_su:+quick` 全構成 PASS（commit `c15201a`）。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i39` | **P2 / R1** | [ws001-p007](ws001/phase007/phase.md) | GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新 | cleared | `q001-i02`, `q001-i04` | P2 実装・単体・FW・回帰 PASS（commit `5d5f819`）。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i40` | **P3** | [ws001-p013](ws001/phase013/phase.md) | レジスタファイル最適化（BRAM 半減・マルチ SU 面積削減） | cleared | `q001-i35` | P3 実装・True Dual-Port BRAM 統合・`atg_su:+quick`全構成PASS。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i41` | **P1** | [ws001-p012](ws001/phase012/phase.md) | スコアボード主導型ワープスケジューラ（GTO & Replay 根絶） | in-review | `q001-i38` | P1 実装・GTO単体PASS・`atg_su:+quick`全構成PASS（commit `c37e924`）。R1 レビュー待ち。 |
| `q001-i42` | **P2** | [ws002-p004](../ws002/phase004/phase.md) | TU 異方性フィルタリング（Anisotropic Filtering 最大 16x EWA ループ） | cleared | `q001-i16` | P2 実装・全8テスト PASS、`arith-lint` 0件。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i43` | **P2** | [ws002-p005](../ws002/phase005/phase.md) | TU シームレスキューブマップフィルタリング（面境界テクセル補間） | cleared | `q001-i13` | P2 実装・全1266テスト PASS、`arith-lint` 0件。R1 敵対的レビュー APPROVE 承認完了。 |
| `q001-i44` | **P2** | [ws002-p006](../ws002/phase006/phase.md) | TU デスクトップ標準圧縮テクスチャ（BC1〜BC7 ハードウェアデコーダ） | in-review | `q001-i15` | P2 実装・全24テスト PASS、`arith-lint` 0件（commit `18e83e2`）。R1 レビュー待ち。 |
| `q001-i45` | **P3** | [ws002-p001](../ws002/phase001/phase.md) | ROP Logic Op（論理演算 16 種）& Independent Blend per RT | in-review | `q001-i09` | P3 実装・単体・Verilator全7Suite PASS、`arith-lint` 0件（commit `1f11dba`）。R1 レビュー待ち。 |
| `q001-i46` | **P2** | [ws002-p007](../ws002/phase007/phase.md) | RX 拡張プリミティブ（Wide Lines, Point Sprites, Multi-Viewport） | in-progress | `q001-i20` | P2 着手。線幅・ポイントスプライト四角形展開・Multi-Viewport。 |
| `q001-i47` | **P3** | [ws002-p002](../ws002/phase002/phase.md) | SU / ROP Dual Source Blending（フォント描画用 src1 カラー出力） | in-progress | `q001-i45`, `q001-i35` | P3 着手。SU export パス拡張 & ROP 第2ソースブレンドファクタ。 |
| `q001-i48` | **P1** | [ws002-p003](../ws002/phase003/phase.md) | MRT 8 アタッチメント拡張（CAPS[30] 4 -> 8 拡張 & ディスクリプタ対応） | in-progress | `q001-i45` | P1 着手。b_rt [2:0] 8アタッチメント化・Hazardタグ拡張・レジスタ空間。 |

## サブエージェント実行状態（N=3）

| レーン | 担当エージェント | モデル | 状態 | 現在のタスク | 次の候補 |
| :---: | :---: | :--- | :--- | :--- | :--- |
| **P1** | 実装（メモリ・相互結合・コア） | Claude Opus 5.5 Medium | active | `q001-i48`: `ws002-p003`（MRT 8 アタッチメント拡張） | `ws002-p008`（間接描画 & インスタンシング） |
| **P2** | 実装（ROP・ピクセル・テクスチャ・バス・DC・CP） | Claude Opus 5.5 Medium | active | `q001-i46`: `ws002-p007`（RX 拡張プリミティブ） | `ws002-p008`（間接描画 & インスタンシング） |
| **P3** | 実装（インフラ・ジオメトリ・SU・ROP） | Claude Opus 5.5 Medium | active | `q001-i47`: `ws002-p002`（Dual Source Blending） | `ws002-p003`（MRT 8 アタッチメント） |
| **H1** | 実装設計補助（Helper） | Gemini 4 Argon Medium | completed | WS001（31件）& WS002（10件）全 41 Phase 実装設計書作成完了（終了済） | 任務完了 |
| **T1** | テスト | 標準 / Flash | active | 回帰テストスイート常時待機 | 各レーン検証ディスパッチ |
| **R1** | レビュー | Gemini 4 Argon Medium | active | 敵対的 RTL & 仕様レビュー常時待機 | 各レーン成果物レビューディスパッチ |

## Upcoming Work Outlook（見通し）

1. **[ws001-p001](ws001/phase001/phase.md)**: 完了（Step A・Step B ともに完了確定）。
2. **[ws001-p002](ws001/phase002/phase.md)**: 完了（GHCI 1.1 INIT & 診断 MMIO レジスタ実装・R1 承認完了）。
3. **[ws001-p003](ws001/phase003/phase.md)**: 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築（P1 実行中）。
4. **[ws001-p004](ws001/phase004/phase.md)**: 完了（IOMMU 連携 & CP 自律 MMU・R1 承認完了、T1 回帰 ALL PASS）。
5. **[ws001-p009](ws001/phase009/phase.md)**: 完了（算術演算ライブラリ `am_shift` 右シフタ 1 本化、`am_div` 非回復法化・R1 承認 & T1 回帰 ALL PASS 完了）。
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
23. **[ws001-p022](ws001/phase022/phase.md)**: Stream Setup Engine 実装（atg_rx_setup マイクロコード撤廃と固定遅延パイプライン化）。
24. **[ws001-p023](ws001/phase023/phase.md)**: MSAA 4x 並列カバレッジ & Coarse Tile Rasterizer（atg_rx_scan 1 cycle化 & 8x8 タイルスキップ）。
25. **[ws001-p024](ws001/phase024/phase.md)**: Fast DDA Plane Evaluator（atg_rx_bary 200 サイクルボトルネック撤廃、1 クアッド/サイクル化）。
26. **[ws001-p025](ws001/phase025/phase.md)**: RX ストリームパイプライン統合 & 全シーン回帰検証（6段ストリーム化）。
27. **[ws001-p026](ws001/phase026/phase.md)**: atg_fmt_pack 2段パイプライン化（200 MHz クリティカルパス解消）。
28. **[ws001-p027](ws001/phase027/phase.md)**: MC AXI バースト結合キュー（Burst Coalescer）。
29. **[ws001-p028](ws001/phase028/phase.md)**: MC フラットクロスバー & QoS アービタ（遅延 8clk -> 2clk）。
30. **[ws001-p029](ws001/phase029/phase.md)**: CP 64ワード循環コマンドプリフェッチ FIFO。
31. **[ws001-p030](ws001/phase030/phase.md)**: BLT ストリーミングバースト DMA エンジン（1.0+ GB/s）。
32. **[ws001-p031](ws001/phase031/phase.md)**: BLT 1サイクル並列 MSAA 4x Resolve。
33. **[ws001-p032](ws001/phase032/phase.md)**: VF 4ストリーム並列属性 DMA & ラインバッファ拡張。
34. **[ws001-p033](ws001/phase033/phase.md)**: VF 32エントリ Post-Transform Vertex Cache（PT-VC）。
35. **[ws001-p034](ws001/phase034/phase.md)**: ボードトップ命名刷新（atg_kc705_top）& atg_pcie_msi の BSP 移動（rtl/bsp/pcie/）。
36. **[ws001-p035](ws001/phase035/phase.md)**: 完全スキッドバッファ（am_skid.v）の共通ライブラリ化。
37. **[ws001-p036](ws001/phase036/phase.md)**: BRAM 推論可能非同期 FIFO（am_afifo_bram.v）実装（同期 Read + 2段スキッド 0-cycle FWFT）。
38. **[ws001-p037](ws001/phase037/phase.md)**: am_axi_master.v 深い Outstanding（16〜32要求）& 独立 R/W チャネル化。
39. **[ws001-p038](ws001/phase038/phase.md)**: atg_dc.v 2048 ワード BRAM AFIFO & 連続フェッチ（1080p@60Hz 148.5MHz 完全保証）。
40. **[ws001-p039](ws001/phase039/phase.md)**: DC Urgent / Panic プレエンプション & MC QoS 優先アービトレーション。
41. **[WS002](ws002/ws.md)**: Vulkan 1.0 仕様適合性・グラフィックス機能補完（Logic Op、Dual Source、MRT 8、Aniso 16x、Seamless Cube、BC 圧縮、Wide Lines、Point Sprites、MultiDrawIndirect、非同期 DMA、DC HDMI/DP リンク層等、後回し）。
