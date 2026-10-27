<!-- awesome-plan project=amaterrace-gpu record=master -->

# Amaterrace GPU Master

[Queue](queue.md) · [Guardrail](guardrail.md) · [Future Work](future-work.md) · [Bug Board](bugs/index.md) · [Past Log](history/index.md) · [設定](config.md) · [規約](standards/concise/verilog-and-scripts.md)

---

## 運用の約束（ユーザー合意）

1. **勝手に進めない**: 担当エージェントの起動・Vivado ビルド・板の操作・設計の変更は、事前に案を示して承認を得てから行う（2026-10-26 ユーザー「今から勝手に進めず、私と相談しながら進めましょう。」）。
2. **ローカル完結運用**: 本プロジェクトでは GitHub Issues を使わず、ローカルの `plan/master.md`・`plan/ws001/ws.md` などのファイルで Awesome Plan を運用する。
3. **板のクロック規則**:
   - ロジックで分周したクロックを作らない（PLL/MMCM の分周は可）。
   - IP（MIG 等）のクロック入力はベンダーのリファレンスに倣い、SYSCLK ピンから直接 PLL へ入れる。
   - Debug OFF で動作を確認する。Vivado のバージョン（2026.1 build 6511674）とストラテジ（Default）を記録する。
   - ビルドの Warning は全件一覧をユーザーに提示し、無害の判断はユーザーが行う。
4. **DC のクロック**: KC705 の SYSCLK（200 MHz 差動発振器）をそのまま使用する。PLL は不要。
5. **Git コミット**: `git commit` のコミットメッセージは常に `-m WIP` とする（2026-10-26 ユーザー指示）。詳細な記録は `plan/` に残す。
6. **エージェント実行体制**:
   - **Q1（メインエージェント）**: 計画立案、サブエージェント管理、成果物マージ。
   - **P1〜P8（実装担当）**: RTL コーディングは **Claude Opus 5.5 Medium** で起動。同時実行数 $N$（$N=1$ で P1、$N=2$ で P1, P2 等）。テストを Q1 に依頼後、**テスト結果を待たずに依存関係の満たされている別作業に着手する**。
   - **T1〜T8（テスト担当）**: Q1 からディスパッチされ検証を実行し、Q1 へ結果を返す。
   - **R1（レビュー担当）**: 実装完了時に Q1 からディスパッチされ、敵対的コードレビューを実施。不備がある場合は差し戻し修正ループを実行し、APPROVE を得て完了確定とする。
   - **サブエージェント別 Queue**: Queue はサブエージェントごとに持つ。

---

## 目的・利用者・最終成果

- **目的**: 寛容なライセンス（Zlib）で利用可能な、Vulkan 1.0 クラスの RTL GPU 実装（Amaterrace GPU）および標準ホストインターフェース（GHCI 1.0）を提供する。
- **利用者**: FPGA や ASIC で GPU を組み込む開発者、zedBSD / Linux 上で自前 GPU スタックを構築する研究者・企業。
- **最終成果**: Xilinx KC705（XC7K325T）上で 200 MHz で動作する実機 GPU ビットストリーム、および 3nm ASIC プロセスで 1.0〜1.5 GHz を達成可能なクリーンな Verilog-2005 RTL。
- **範囲**: RTL（`rtl/`）、モジュール仕様書（`spec/`）、ヘッダ（`include/`）、ファームウェア（`fw/cp/`）、検証ベンチ（`sim/`）、各種ツール・モデル（`tools/`）、ボード設計（`boards/`）。
- **範囲外**: プロプライエタリな IP 自体の再配布、CTS 認証の公式取得。

## Objectives

- **O1**: Verilog-2005 のクリーンなサブセットによる、ポータブルで可読性の高い GPU コアの実装。
- **O2**: KC705 FPGA 上での 200 MHz 動作と、将来的 3nm ASIC プロセスでの 1.0〜1.5 GHz ターゲット設計。
- **O3**: 演算器の明確な分離（算術演算は `rtl/library/arith/`、FP 演算は `rtl/library/fp/`、ボード固有セルは `rtl/bsp/`）と厳格なリント（`arith-lint` 0）。

## Milestone Goals

| Milestone | Objective | 受け入れの核 | 進捗 | Primary WS |
| --- | --- | --- | --- | --- |
| **MG001** 階層整理・FP 演算器統合・DSP48E1 最適化 | O1, O3 | `rtl/common/` 廃止、`rtl/library/{arith,bus,fp}`・`rtl/bsp/` 再編、FP 演算器統合（`am_fpu_core` 含む）、`am_mul` 全幅 DSP48E1 直接インスタンス化（`LAT <= 3` でファブリック 0 個）、arith-lint 0 | 達成・完了（WS001 全 39 Phase 承認完了） | WS001 |
| **MG002** KC705 実機動作・DC 200MHz 独立・端から端統合 | O1, O2 | DC クロック領域の 200 MHz 化による 720p アンダーフロー解消、VF2 PCIe / QEMU VFIO 経由での zedBSD Vulkan 描画 | 前提 Phase 準備中 | WS001 |
| **MG003** パイプライン化と 200 MHz タイミング収束 | O2 | 各ブロック（SU, TU, ROP, RX 等）の LAT=3 パイプライン化、KC705 上での WNS >= 0 ns 達成 | 達成・完了（WS001 パイプライン化完了） | WS001 |
| **MG004** 複数 SU・キャッシュブロッキング・ASIC 展開 | O1, O2 | 複数 SU スケーリング、タイリング/キャッシュブロッキング、3nm ASIC フロー検討 | Future Work | WS001 |
| **MG005** Vulkan 1.0 完全適合・拡張グラフィックス機能 | O1 | Logic Op、Dual Source Blend、MRT 8 アタッチメント、異方性フィルタ等の完全実装 | 達成・完了（WS002 全 10 Phase 承認完了） | WS002 |

## Current Focused Goals

| Goal | 当面の成果 | Milestone | 担当 Phase | 出典 |
| --- | --- | --- | --- | --- |
| **fg001** | RTL 階層再編・FP 重複演算器の統合・`am_mul` の全幅 `DSP48E1` カスケード実装と等価性検証 | MG001 | [ws001-p001](ws001/phase001/phase.md) | 達成・完了 |
| **fg002** | 共有 L2 キャッシュ（LLC: 256 KiB、16-way）導入 & キャッシュコヒーレンシ再構築 | MG001, MG002 | [ws001-p003](ws001/phase003/phase.md) | 達成・完了 |

## Workstream 一覧

| WS | Primary Milestone | 名称・概要 | 状態 | 再開点・次の作業 |
| --- | --- | --- | --- | --- |
| [WS001](ws001/ws.md) | MG001 | Amaterrace GPU IP（階層整理・FP 演算器統合・DSP48E1 最適化・パイプライン化） | completed | 全 39 Phase 実装・検証・R1 承認完了 |
| [WS002](ws002/ws.md) | MG005 | Vulkan 1.0 仕様適合性・グラフィックス機能補完（Logic Op、Dual Source、MRT 8） | completed | 全 10 Phase 実装・検証・R1 承認完了 |
| [WS003](ws003/ws.md) | MG006 | Vulkan 互換 API モジュール別 Capability 化 & config.mk ビルド設定 | completed | 全 7 Phase 実装・検証・R1 承認完了 |
| [WS004](ws004/ws.md) | MG007 | 次世代ジオメトリ（VK_EXT_mesh_shader, VK_EXT_task_shader）SU support for task/mesh shader アーキテクチャ | completed | 全 3 Phase 実装・統合検証・R1 承認完了 |

## 優先順位

1. **[ws001-p001](ws001/phase001/phase.md)**: RTL 階層整理（`rtl/library/`・`rtl/bsp/`）、FP 演算器統合、`am_mul` の `DSP48E1` カスケード実装、unisim 単体等価試験、日常回帰・`arith-lint 0`、KC705 板ビルド。
2. **[ws001-p002](ws001/phase002/phase.md)**: GHCI 1.1 起動ハンドシェイク規格化（INIT/INIT_ACK 相互認証）& 診断ダンプ強化（`CP_PC`, `CP_STATUS`, `PIPE_FSM`）。
3. **[ws001-p003](ws001/phase003/phase.md)**: 共有 L2 キャッシュ（LLC）導入、キャッシュコヒーレンシ再構築、DC 優先帯域保証。
4. **[ws001-p004](ws001/phase004/phase.md)**: IOMMU 連携 & CP 自律型 MMU（Hardware Page Walker + 隠蔽 TLB）仕様策定 & 実装（商用独自 OS・Unified Memory 前提、極薄ドライバ、ゼロコピー）。
5. **[ws001-p005](ws001/phase005/phase.md)**: マルチエンジン独立キューイング（Graphics/Compute/DMA 独立リング）& ハードウェアプリエンプション。
6. **[ws001-p006](ws001/phase006/phase.md)**: 細粒度同期（Timeline Semaphore / パイプラインバリア）& Vulkan 1.0 必須機能補完（MultiDrawIndirect、DualSourceBlend、LogicOp、異方性フィルタ）。
7. **[ws001-p007](ws001/phase007/phase.md)**: GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新（19 レジスタスリム MMIO、インメモリ PSO/ディスクリプタ、`CMD_BIND_PIPELINE`/`CMD_DRAW`、UMA セカンダリコマンドフェッチ）。
8. **[ws001-p008](ws001/phase008/phase.md)**: FP 演算ライブラリ再編 & 統合 FPU コア（`am_fpu_core`）実装（4x DSP48E1 共有 FMA/IMUL、`am_fp_div`, `am_fp_f2fix`, `am_fp_i2f` のライブラリ共通化）。
9. **DC の 200 MHz クロック領域分離**: SYSCLK 直結による 720p scanout アンダーフロー解消。
10. **物理最適化 & コアパイプライン化**:
    - **Arith**: [ws001-p009](ws001/phase009/phase.md)（ビット反転右シフタ、Non-restoring 除算器）
    - **SU**: [ws001-p010](ws001/phase010/phase.md)〜[p013](ws001/phase013/phase.md)（実 6段化、フォワーディング、スコアボード、RF 時分割）
    - **ROP**: [ws001-p014](ws001/phase014/phase.md)〜[p017](ws001/phase017/phase.md)（div255 1段化、Lerp 最適化、fp32 ストリーム化、Hazard Tracker、L1 タイルキャッシュ）
    - **TU**: [ws001-p018](ws001/phase018/phase.md)〜[p021](ws001/phase021/phase.md)（4レーン並列アドレス生成、フィルタ統合、マルチバンク L1 T$、MSHR ノンブロッキング）
    - **RX**: [ws001-p022](ws001/phase022/phase.md)〜[p025](ws001/phase025/phase.md)（Stream Setup、MSAA 4x 並列 & Coarse タイルスキップ、Fast DDA 1 cycle 平面評価、6段ストリーム統合）
    - **FMT**: [ws001-p026](ws001/phase026/phase.md)（atg_fmt_pack 2段パイプライン化、200MHz タイミングクロージャ）
    - **MC**: [ws001-p027](ws001/phase027/phase.md)〜[p028](ws001/phase028/phase.md)（AXI バースト結合キュー、2段 QoS フラットクロスバー）
    - **CP**: [ws001-p029](ws001/phase029/phase.md)（64ワード循環コマンドプリフェッチ FIFO、ノーウェイト供給）
    - **BLT**: [ws001-p030](ws001/phase030/phase.md)〜[p031](ws001/phase031/phase.md)（ストリーミングバースト DMA 1.0+ GB/s、MSAA 4x 1 cycle 並列 Resolve）
    - **VF**: [ws001-p032](ws001/phase032/phase.md)〜[p033](ws001/phase033/phase.md)（4ストリーム並列属性 DMA、32エントリ Post-Transform 頂点キャッシュ）
    - **Board / BSP**: [ws001-p034](ws001/phase034/phase.md)（ボードトップ命名刷新 atg_kc705_top & atg_pcie_msi の rtl/bsp/pcie/ 移動）
    - **DC & BUS**: [ws001-p035](ws001/phase035/phase.md)〜[p039](ws001/phase039/phase.md)（完全スキッドバッファ am_skid、BRAM AFIFO am_afifo_bram、深い Outstanding AXI マスタ、DC 2048 ワード BRAM AFIFO & 連続フェッチ、DC Urgent/Panic プレエンプション）
11. **[WS002](ws002/ws.md) Vulkan 1.0 仕様適合性・グラフィックス機能補完**: コアパイプライン化完了後に着手（Logic Op、Dual Source、MRT 8、Aniso 16x、Seamless Cube、BC 圧縮、Wide Lines、Point Sprites、MultiDrawIndirect、非同期 DMA、DC HDMI/DP リンク層等、後回し）。
