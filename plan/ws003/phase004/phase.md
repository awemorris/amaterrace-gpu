<!-- awesome-plan project=amaterrace-gpu record=ws003-p004 -->

# Phase ws003-p004: TU（テクスチャユニット）モジュールの Capability 化

- Workstream: [WS003](../ws.md)
- Status: `completed`
- Depends on: ws003-p001

## 目的

`atg_tu` におけるテクスチャ圧縮デコーダ（BC1〜BC7）、トライリニア補間、3D/Cube マップサポート、および MSHR を着脱可能なビルド時 Capability として整備する。

## 変更対象ファイル

- `rtl/gpu/tu/atg_tu.v`
- `rtl/gpu/tu/atg_tu_addr.v`
- `rtl/gpu/tu/atg_tu_bc.v`
- `rtl/gpu/tu/atg_tu_cache.v`
- `rtl/gpu/tu/atg_tu_cube.v`
- `rtl/gpu/tu/atg_tu_cube_edge.v`
- `rtl/gpu/tu/atg_tu_decp.v`
- `rtl/gpu/tu/atg_tu_mshr.v`
- `sim/tb/atg_tu_bc_tb.v`
- `sim/tb/atg_tu_cube_tb.v`
- `sim/tb/atg_tu_mshr_tb.v`

## 完了条件

- `CONFIG_TU_ENABLE_BC=0` 時に BC デコーダロジックが完全に切り離され、非圧縮テクスチャのみで最小限リソース動作すること。
- `python3 tools/arith-lint.py --top atg_tu` がクリーン（0 演算子逸脱）であること。
- `atg_tu_tb` が正常動作すること。

## 実装内容

1. **`include/atg_config.vh` 連携**:
   - `atg_tu.v`, `atg_tu_addr.v`, `atg_tu_bc.v`, `atg_tu_decp.v`, `atg_tu_cube.v`, `atg_tu_cube_edge.v`, `atg_tu_mshr.v`, `atg_tu_cache.v` に `atg_config.vh` をインクルード。
2. **`CFG_ENABLE_BC`（Block Compression 着脱）**:
   - `atg_tu_bc.v`, `atg_tu_decp.v` において、`CFG_ENABLE_BC` 未定義時は BC1〜BC7 回路を完全に切り離し、LUT 消費ゼロのスタブとして非圧縮フォーマット専用で動作可能にした。
3. **`CFG_ENABLE_TRILINEAR`（トライリニア補間着脱）**:
   - `atg_tu_addr.v` において、`CFG_ENABLE_TRILINEAR` 未定義時は `miplin = 1'b0` とし、第2レベルの Mipmap 間補間パスをバイパスして Bilinear のみで動作可能にした。
4. **`CFG_ENABLE_3D_CUBE`（3D / Cube 着脱）**:
   - `atg_tu_addr.v`, `atg_tu_cube.v`, `atg_tu_cube_edge.v` において、`CFG_ENABLE_3D_CUBE` 未定義時は Cube 投影回路・シームレスエッジ回路を切り離し、2D 専用で動作可能にした。
5. **`CFG_TU_L1_BANKS`, `CFG_ENABLE_MSHR`**:
   - `atg_tu.v` で `atg_tu_cache` の `NBANKS` パラメータに `CFG_TU_L1_BANKS` を接続。
   - `atg_tu_mshr.v` で `CFG_ENABLE_MSHR` 未定義時のスタブ化を整備。
6. **検証結果**:
   - `tools/arith-lint.py`: 全 TU サブモジュールおよびトップにおいて 0 演算子逸脱（クリーン）。
   - 単体テストベンチ `atg_tu_bc`, `atg_tu_cube`, `atg_tu_filter`, `atg_tu_mshr` が正常に PASS。

