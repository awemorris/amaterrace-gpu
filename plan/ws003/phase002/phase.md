<!-- awesome-plan project=amaterrace-gpu record=ws003-p002 -->

# Phase ws003-p002: SU 物理レーンスケーリング（4, 8, 16, 32）および演算オプションのパラメータ化

- Workstream: [WS003](../ws.md)
- Status: `review`
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
- `atg_su_tb` が `NPHYS = 4, 8, 32` および `nosubgroup` の各構成で正常に PASS すること。

## 実装・検証結果

- **物理レーンスケーリング**:
  - `atg_su_sched.v` にて `GAP_W = 3` に拡張し、`NPHYS = 4`（`gap = 8`）での 2-bit ラップアラウンド障害を完全解消。
  - `atg_su.v` にて `CFG_SU_NPHYS`, `CFG_SU_GRP_W`, `CFG_SU_NWARPS`, `CFG_SU_NREGS`, `CFG_ENABLE_FP16`, `CFG_ENABLE_SUBGROUP`, `CFG_ENABLE_SFU`, `CFG_SU_LDS_KB` マクロと parameter を完全結合。
- **Lint & 静的解析**:
  - `verilator --lint-only -Wall -Iinclude` で `atg_su` が警告 0 件で通過。
  - `python3 tools/arith-lint.py --top atg_su` で逸脱 0 件（完全遵守）。
- **シミュレーション**:
  - `atg_su:+quick` にて全 4 構成（`nphys4`, `nphys8`, `nphys32`, `nosubgroup`）がオール PASS（全テストプログラム一致）。
