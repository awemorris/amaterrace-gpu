<!-- awesome-plan project=amaterrace-gpu record=ws001-p034 -->

# Phase 034: ボードトップ命名刷新（atg_kc705_top）& atg_pcie_msi の BSP 移動

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Major (ボードトップ構造の明確化 & PCIe MSI ブリッジの共通 BSP 配置)
- **出典**: ユーザー諮問（atg_pcie_msi 配置 & boards 命名）および R1 アーキテクチャ分析レポート

## 目的

1. `rtl/gpu/top/atg_pcie_msi.v` が GPU コア本体（`atg_top`）ではなく FPGA ボードの PCIe ホストバインディング層である実態に合わせ、マルチボード展開可能な共通 BSP 層 `rtl/bsp/pcie/atg_pcie_msi.v` へ移動・パラメータ化する。
2. `boards/kc705/atg_kc705_raster.v` という初期プロトタイプの名残である名称を、完全な FPGA SoC トップであることを明示する業界標準の `boards/kc705/atg_kc705_top.v`（`module atg_kc705_top`）および `atg_kc705_top.xdc` へ改名し、構造を刷新する。

## 範囲・作業内容

1. **`atg_pcie_msi.v` の移動とパラメータ化**:
   - `rtl/gpu/top/atg_pcie_msi.v` $\to$ `rtl/bsp/pcie/atg_pcie_msi.v` へ移動。
   - `spec/gpu/top/atg_pcie_msi.md` $\to$ `spec/bsp/pcie/atg_pcie_msi.md` へ移動。
   - `IRQ_STATUS_ADDR`（既定値: `GHCI_IRQ_STATUS` 0x008）、`IRQ_ENABLE_ADDR`（既定値: `GHCI_IRQ_ENABLE` 0x00C）をモジュールパラメータ化。

2. **KC705 ボードトップ命名のリファクタリング**:
   - `boards/kc705/atg_kc705_raster.v` $\to$ `boards/kc705/atg_kc705_top.v` へ改名、モジュール名を `atg_kc705_top` に変更。
   - `boards/kc705/atg_kc705_raster.xdc` $\to$ `boards/kc705/atg_kc705_top.xdc` へ改名。
   - `sim/tb/atg_kc705_raster_tb.v` $\to$ `sim/tb/atg_kc705_top_tb.v` へ改名・参照更新。
   - `spec/boards/kc705/atg_kc705_raster.md` $\to$ `spec/boards/kc705/atg_kc705_top.md` へ改名。

3. **ビルドスクリプト・ツールの整合**:
   - `Makefile`（`TOP ?= atg_kc705_top`）。
   - `tools/vivado-build.sh`、`tools/vivado-build.tcl`、`tools/lint.sh`、`boards/kc705/README.md` 内の参照を更新。

4. **単体・回帰検証**:
   - `tools/lint.sh`（make lint）による構文・階層チェック CLEAN。
   - `sim/run.sh atg_kc705_top`（または `atg_top`）の実行確認。
   - `sim/verilator/run.sh`（全 7 モード）での画像完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 移動・新設: `/home/awe/amaterrace-gpu/rtl/bsp/pcie/atg_pcie_msi.v`
- 削除: `/home/awe/amaterrace-gpu/rtl/gpu/top/atg_pcie_msi.v`
- 移動・新設: `/home/awe/amaterrace-gpu/spec/bsp/pcie/atg_pcie_msi.md`
- 削除: `/home/awe/amaterrace-gpu/spec/gpu/top/atg_pcie_msi.md`
- 移動・新設: `/home/awe/amaterrace-gpu/boards/kc705/atg_kc705_top.v`
- 削除: `/home/awe/amaterrace-gpu/boards/kc705/atg_kc705_raster.v`
- 移動・新設: `/home/awe/amaterrace-gpu/boards/kc705/atg_kc705_top.xdc`
- 削除: `/home/awe/amaterrace-gpu/boards/kc705/atg_kc705_raster.xdc`
- 移動・新設: `/home/awe/amaterrace-gpu/sim/tb/atg_kc705_top_tb.v`
- 削除: `/home/awe/amaterrace-gpu/sim/tb/atg_kc705_raster_tb.v`
- 移動・新設: `/home/awe/amaterrace-gpu/spec/boards/kc705/atg_kc705_top.md`
- 削除: `/home/awe/amaterrace-gpu/spec/boards/kc705/atg_kc705_raster.md`
- 更新: `/home/awe/amaterrace-gpu/Makefile`
- 更新: `/home/awe/amaterrace-gpu/tools/lint.sh`
- 更新: `/home/awe/amaterrace-gpu/tools/vivado-build.tcl`
- 更新: `/home/awe/amaterrace-gpu/tools/vivado-build.sh`
- 更新: `/home/awe/amaterrace-gpu/sim/run.sh`

### 2. モジュールインターフェース設計 (`atg_pcie_msi.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_pcie_msi #(
    parameter [16:0] IRQ_STATUS_ADDR = 17'h00008, // GHCI_IRQ_STATUS
    parameter [16:0] IRQ_ENABLE_ADDR = 17'h0000C  // GHCI_IRQ_ENABLE
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        irq,
    input  wire        aw_take,
    input  wire [16:0] aw_addr,
    input  wire        b_take,
    input  wire        uclk,
    input  wire        urst_n,
    output reg         msi_req,
    input  wire        msi_ack
);
```

### 3. 注意点とリファクタリング手順
- `atg_pcie_msi.v` 内でのアドレス比較をパラメータ参照に変更:
  ```verilog
  wire hit = (aw_addr == IRQ_STATUS_ADDR) || (aw_addr == IRQ_ENABLE_ADDR);
  ```
- `git mv` を用いて履歴を保持しながらリネームすること。
- `boards/kc705/atg_kc705_top.v` 内部のモジュール宣言を `module atg_kc705_top` に書き換えること。
- `boards/kc705/lib/atg_kc705_jtag.v` やテストベンチ内の階層パス（`dut.jtag.bscan...` 等）に影響を与えないよう注意。
- `tools/arith-lint.py` を実行し、移動先ファイルも含めて算術演算子違反 0 件を維持すること。

### 4. 検証手順（T1/P1 共通）
- **テストコマンド**:
  ```bash
  ./tools/lint.sh
  python3 tools/arith-lint.py
  ./sim/run.sh atg_kc705_top
  ./sim/verilator/run.sh
  ```
- 既存のすべてのリグレッションテストがエラーなく完走すること。

---

## 検証基準（受け入れ条件）

- `rtl/gpu/top/` からホスト固有モジュールが排除され、`rtl/bsp/pcie/` に適切に配置されること。
- ボードトップが `atg_kc705_top` としてクリーンにビルド・シミュレーションできること。
- 既存のテストスイートおよび画像出力が 1 bit の差異もなく一致すること。
- R1 レビュー APPROVE 獲得。
