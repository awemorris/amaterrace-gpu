<!-- awesome-plan project=amaterrace-gpu record=past-log -->

# Past Log Board（Queue 実行履歴）

## 最新の Queue 状態（q001: 提案中）

- **Queue ID**: `q001`
- **対象**: [ws001-p001](ws001/phase001/phase.md)（RTL 階層整理・FP 演算器統合・DSP48E1 最適化）
- **状態**: 提案中（ユーザー承認待ち）

---

## 移管前の履歴サマリ（親プロジェクト zedBSD WS288）

Amaterrace GPU は親プロジェクト `zedBSD` の `WS288`（全 45 フェーズ）において以下の成果を達成し、2026-10-26 に単独の `WS001` として移管・再定義されました。

1. **骨組み・基盤（p001〜p005, p017, p023）**:
   - GHCI 1.0 仕様策定、`atg_top` / `atg_cp` / `atg_blt` / `atg_mc` 実装。
   - CP 内蔵 RV32IM コア（`atg_cpu`）およびファームウェア基盤。
   - トップダウンモジュール分割と `spec/` 仕様書の体系化。
2. **グラフィックスパイプライン & ISA（p007〜p011, p018, p027, p030）**:
   - RX（ラスタライザ）、ROP（ブレンド・デプス・ステンシル）、SU（シェーダーユニット、GSI1 ISA）。
   - TU（テクスチャユニット、バイリニア/トライリニア/キューブ/ETC2+EAC）。
   - MSAA 4x、Vulkan 1.0 core 必須描画・コンピュートパイプラインの Verilator 完全一致。
3. **セキュリティ & メモリ（p034, p035, p039, p040）**:
   - GHCI §11.6 セッション保護（PROT）、DC の GPU 統合（DISP2）。
   - MC AXI ID 振り分け（`am_axi_split`）、ホストメモリ配置と BAR2 窓制御。
4. **演算器統一（p037）**:
   - シグナル算術演算子の共通モジュール化（`am_add`, `am_sub`, `am_mul` 等）と `arith-lint.py` による自動検査。
5. **KC705 実機検証（p012, p024, p043, p044）**:
   - KC705 ボードトップ・MIG DDR3 PHY・JTAG ブリッジ。
   - SYSCLK 直接供給による MIG キャリブレーション安定化。
   - VisionFive 2 M.2 PCIe 接続でのドライバ attach、INIT・DIAG コマンド疎通。
