<!-- awesome-plan project=amaterrace-gpu record=ws003-p006 -->

# Phase ws003-p006: CP & GHCI レジスタ連携（動的 Capability 反映）

- Workstream: [WS003](../ws.md)
- Status: `completed`
- Depends on: ws003-p002, ws003-p003, ws003-p004, ws003-p005

## 目的

`atg_cp_regs.v` および GHCI MMIO レジスタインターフェースにおいて、ビルド時に決定された各種ハードウェア Capability（`PHYS_LANES`, `CAP_FP16`, `CAP_MSAA`, `CAP_DUAL_SOURCE`, テクスチャ圧縮フォーマットビットマップ等）を `DEVICE_CAPS`, `CAPS`, `EXT_CAP_*` レジスタへ動的にマッピングする。

## 変更対象ファイル

- `rtl/gpu/cp/atg_cp_regs.v`
- `include/ghci_regs.h`
- `include/ghci_regs.vh`
- `sim/tb/atg_cp_tb.v`

## 完了条件

- ホストからの MMIO レジスタ読み出しで、`config.mk` の設定通りの Capability ビットが返却されること。
- `python3 tools/arith-lint.py --top atg_cp` がクリーンであること。
- `atg_cp_tb` が正常動作すること。
