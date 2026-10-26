<!-- awesome-plan project=amaterrace-gpu record=ws003-p007 -->

# Phase ws003-p007: プロファイル別プリセットビルド検証 & 全体回帰テスト

- Workstream: [WS003](../ws.md)
- Status: `in-progress`
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

## 実装・検証状況

- `tools/menuconfig.py`: `--preset [minimal|balanced|high-perf]` プリセット適用機能を追加。
- `Makefile`: `preset-minimal`, `preset-balanced`, `preset-high-perf` ターゲットを追加し、プリセット適用後に `include/atg_config.vh` を自動更新可能にした。
- 回帰テストおよび各プリセットのビルド・Lint検証を実行中。
