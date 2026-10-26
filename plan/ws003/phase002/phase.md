<!-- awesome-plan project=amaterrace-gpu record=ws003-p002 -->

# Phase ws003-p002: SU 物理レーンスケーリング（4, 8, 16, 32）および演算オプションのパラメータ化

- Workstream: [WS003](../ws.md)
- Status: `queued`
- Depends on: ws003-p001

## 目的

`atg_su` における物理レーン数 `NPHYS` を `4, 8, 16, 32` の範囲で自在に設定可能とし、演算オプション（FP16 パックド、サブグループ、ハードウェア SFU、LDS バイト数）をビルド設定と完全連動させる。

## 変更対象ファイル

- `rtl/gpu/su/atg_su.v`
- `rtl/gpu/su/atg_su_lane.v`
- `rtl/gpu/su/atg_su_sched.v`
- `include/atg_su_uop.vh`
- `sim/tb/atg_su_tb.v`

## 完了条件

- `NPHYS = 4, 8, 16, 32` の各構成で Verilator lint が warning 0 で通過すること。
- `python3 tools/arith-lint.py --top atg_su` で演算子逸脱が 0 であること。
- `atg_su_tb` が `NPHYS = 4, 8, 16` の各構成で正常に PASS すること。
