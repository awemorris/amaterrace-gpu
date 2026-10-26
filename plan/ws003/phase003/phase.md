<!-- awesome-plan project=amaterrace-gpu record=ws003-p003 -->

# Phase ws003-p003: RX（ラスタライザ）モジュールの Capability 化

- Workstream: [WS003](../ws.md)
- Status: `completed`
- Depends on: ws003-p001

## 目的

`atg_rx` における MSAA（有効/無効、サンプル数 1x/2x/4x）、Hi-Z RAM による Early-Z カリング、粗タイリング走査（Coarse Scan）を着脱可能なパラメータおよび条件コンパイルマクロとして整備する。

## 変更対象ファイル

- `rtl/gpu/rx/atg_rx.v`
- `rtl/gpu/rx/atg_rx_scan.v`
- `rtl/gpu/rx/atg_rx_coarse.v`
- `sim/tb/atg_rx_scan_tb.v`

## 完了条件

- `CONFIG_RX_ENABLE_MSAA=0`（1x サンプル固定）時および `CONFIG_RX_ENABLE_EARLY_Z=0` 時に不要なロジック・RAM が排除され、クリーンにコンパイル・シミュレーションが通ること。
- `python3 tools/arith-lint.py --top atg_rx` がクリーンであること。
- `atg_rx_scan_tb` が PASS すること。
