<!-- awesome-plan project=amaterrace-gpu record=ws003-p007 -->

# Phase ws003-p007: プロファイル別プリセットビルド検証 & 全体回帰テスト

- Workstream: [WS003](../ws.md)
- Status: `cleared`
- Depends on: ws003-p006

## 目的

`Minimal Profile`（低規模・最小リソース構成）、`Balanced Profile`（KC705 標準構成）、`High-Performance Profile` の 3 種類のプリセットビルドについて、Verilator lint および directed testbench（`sim-quick`）のパスを検証し、リグレッションが発生していないことを確認する。

## 変更対象ファイル

- `Makefile`
- `tools/menuconfig.py`
- `config.mk.template`
- `sim/verilator/run.sh`

## 完了条件

- 3 種類のプロファイルすべてで `tools/lint.sh`（Verilator -Wall）が警告 0 で通過すること。
- `python3 tools/arith-lint.py` がリポジトリ全域で 0 演算子逸脱を維持すること。
- 主要テストベンチ群が PASS すること。

## 実装・検証結果

- **プリセット機能実装**:
  - `tools/menuconfig.py` に `--preset [minimal|balanced|high-perf]` 引数処理および辞書定義を実装。
  - `Makefile` に `preset-minimal`, `preset-balanced`, `preset-high-perf` ターゲットを追加し、プリセット適用後に `include/atg_config.vh` を自動更新可能にした。
- **演算子静的検査（arith-lint）**:
  - `python3 tools/arith-lint.py` をリポジトリ全域に対して実行し、**0 operators outside rtl/library/arith（完全遵守）** を確認。
- **Verilator Lint（tools/lint.sh）**:
  - 全モジュール、全 Top、全 Board Top（KC705含む）において **警告 0（Clean PASS, Exit Code 0）** を達成。
- **プリセット別動作検証**:
  - `minimal`: `atg_cp_tb` PASS, `atg_rx_scan_tb +quick` PASS（3s）, `arith-lint` 0 逸脱。
  - `high-perf`: `atg_cp_tb` PASS, `arith-lint` 0 逸脱。
  - `balanced`: `atg_cp_tb` PASS, `atg_rx_scan_tb +quick` PASS（11s）, `arith-lint` 0 逸脱。
- **回帰テスト**:
  - 主要ユニットテストベンチ（`atg_cp`, `atg_rx_scan`, `atg_su_exp`, `atg_top`, `atg_tu`, `atg_rop_*` 等）が PASS。
