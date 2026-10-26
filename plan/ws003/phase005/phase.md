<!-- awesome-plan project=amaterrace-gpu record=ws003-p005 -->

# Phase ws003-p005: ROP（レンダーバックエンド）モジュールの Capability 化

- Workstream: [WS003](../ws.md)
- Status: `completed`
- Depends on: ws003-p001

## 目的

`atg_rop` におけるデュアルソースブレンディング、16 種類 LogicOp、Fast Clear タイルステート、MRT（複数レンダーターゲット）数を着脱・縮小可能なビルド時 Capability として整備する。

## 変更対象ファイル

- `rtl/gpu/rop/atg_rop.v`
- `rtl/gpu/rop/atg_rop_blend.v`
- `rtl/gpu/rop/atg_rop_wb.v`
- `rtl/gpu/rop/atg_rop_cache.v`
- `sim/tb/atg_rop_blend_tb.v`
- `sim/tb/atg_rop_dualsrc_tb.v`
- `sim/tb/atg_rop_logicop_tb.v`

## 完了条件

- `CONFIG_ROP_DUAL_SOURCE=0`, `CONFIG_ROP_ENABLE_LOGICOP=0`, `CONFIG_ROP_MRT_COUNT=1` で最小限リソース構成がビルド可能であること。
- `python3 tools/arith-lint.py --top atg_rop` がクリーン（0 演算子逸脱）であること。
- ROP 関連テストスイートが正常動作すること。

## 実装内容

1. **`include/atg_config.vh` 連携**:
   - `atg_rop.v`, `atg_rop_blend.v`, `atg_rop_wb.v`, `atg_rop_cache.v` に `atg_config.vh` をインクルード。
2. **`CFG_ROP_DUAL_SOURCE`（デュアルソースブレンディング着脱）**:
   - `atg_rop_blend.v` において、`CFG_ROP_DUAL_SOURCE` 未定義時は 16 個の `atg_rop_f2u8` 変換インスタンスおよび `s1c`/`s1a` ブレンドファクタ計算を完全に切り離し、単一カラーソース（128-bit）のみの最小構成にした。
3. **`CFG_ROP_ENABLE_LOGICOP`（16 種類 Vulkan LogicOp 着脱）**:
   - `atg_rop_blend.v` において、`CFG_ROP_ENABLE_LOGICOP` 未定義時は `calc_logic_op` 関数、`lop_en` / `lop_op` レジスタ群を切り離し、通常のブレンディングのみで動作可能にした。
4. **`CFG_ROP_FAST_CLEAR`（Fast Clear タイルステートメタデータ着脱）**:
   - `atg_rop_cache.v` において、`CFG_ROP_FAST_CLEAR` 未定義時はタイルステートメタデータ RAM をバイパス・縮小可能にした。
5. **`CFG_ROP_MRT_COUNT`（複数レンダーターゲット数設定）**:
   - `atg_rop.v`, `atg_rop_blend.v`, `atg_rop_wb.v` に `parameter MRT_COUNT = CFG_ROP_MRT_COUNT` を配線。
6. **テストベンチ修正**:
   - `sim/tb/atg_rop_blend_tb.v`, `sim/tb/atg_rop_logicop_tb.v` のダングリング入力ポート警告を修正。
   - `sim/tb/atg_rop_dualsrc_tb.v` の `b_rt` ビット幅（3-bit）を適合修正。
7. **検証結果**:
   - `tools/arith-lint.py`: 全モジュール対象で `0 operators outside rtl/library/arith`（完全クリーン）。
   - Verilator lint: `verilator --lint-only -Wall -Iinclude ... --top-module atg_rop` で警告 0（Clean）。
   - 単体テストベンチ: `atg_rop_blend`, `atg_rop_wb`, `atg_rop_logicop`, `atg_rop_dualsrc`, `atg_rop_cache`, `atg_rop_mrt8` 全て PASS。
8. **R1 レビュー指摘是正**:
   - `atg_rop_blend.v`: 非 `CFG_ROP_DUAL_SOURCE` 時の `factor` 内で `(s1c ^ s1a) & 8'd0` を使用し、全ビットを適切に消費。また `unused_ok` で `(MRT_COUNT != 0)` を参照。
   - `atg_rop_wb.v`: `unused_ok` に `(MRT_COUNT != 0)` を追加し、パラメータ未使用警告を解消。
   - `atg_rop_wpix.v`: `unused_ok` に `s_ext[8:3]`, `s_ext_bo_unused` を追加し、未使用ビット警告を解消。


