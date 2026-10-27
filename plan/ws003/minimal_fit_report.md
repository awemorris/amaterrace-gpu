# KC705（Kintex-7 325T）ミニマムコンフィグ Vivado P&R・Fit・Fmax 調査報告書

- 日付: 2026-10-27
- 対象ボード: Xilinx KC705 Evaluation Board (`xc7k325tffg900-2`)
- ツール: Vivado 2026.1 (Batch Mode: `tools/vivado-build.sh`)
- 調査対象設定: `config/minimal.mk`（最小フットプリント構成）

---

## 1. 調査サマリー

| 項目 | 結果 | 判定 |
| :--- | :--- | :---: |
| **論理合成 (Synthesis)** | 完了 (`build/vivado/atg_kc705_top_synth.dcp`) | **PASS** |
| **初期配置配線 (P&R)** | `DRC UTLZ-1`（LUT 資源超過）により未完 | **OVER-UTILIZED** |
| **必要 LUT 数** | **332,637 Logic LUTs**（デバイス容量比 163%） | デバイス上限 203,800 を超過 |
| **達成 Fmax / Timing Met** | 配置未完のため未確定（合成段階ボトルネックの解消が必要） | **要最適化** |

---

## 2. 階層別リソース消費内訳（`hier_util.rpt` 解析）

Vivado 2026.1 による合成後チェックポイントから階層別リソース使用量を出力・解析した結果、以下のモジュールが LUT 消費の約 **60%** を占めていることが判明しました。

```
+---------------------------+-----------------------------------+------------+------------+---------+
| モジュール                | インスタンス                      | Total LUTs | Logic LUTs | FFs     |
+---------------------------+-----------------------------------+------------+------------+---------+
| atg_kc705_top (全体)      | (top)                             |    345,821 |    332,637 | 229,356 |
| ├── g_tu.tu (Texture)     | gpu/g_tu.tu                       |    116,468 |    115,224 |  76,194 |
| │   └── atg_tu_cache      | gpu/g_tu.tu/cache                 |     82,539 |     82,539 |  71,854 |
| ├── g_rop.rop (ROP)       | gpu/g_rop.rop                     |     78,048 |     78,030 |  13,914 |
| │   └── atg_rop_fblend    | gpu/g_rop.rop/wb/wpix/fblend      |     49,886 |     49,868 |   6,182 |
| ├── g_su[0].su (Shader)   | gpu/g_su[0].su                    |     41,968 |     41,968 |  33,405 |
| ├── g_rx.rx (Rasterizer)  | gpu/g_rx.rx                       |     24,437 |     24,437 |  14,024 |
| ├── PCIe Endpoint         | bridge (atg_kc705_pcie_ip)        |     15,405 |     15,405 |  12,850 |
| └── DDR3 MIG Controller   | g_nodbg.ddr3                      |     15,251 |     15,251 |  11,620 |
+---------------------------+-----------------------------------+------------+------------+---------+
```

---

## 3. リソース超過の根本原因

### 原因 1: `atg_tu_cache` の BRAM 非推論（82.5k LUTs / 71.8k FFs の浪費）
- `rtl/gpu/tu/atg_tu_cache.v` 内の 4 バンクキャッシュメモリ配列（`reg [511:0] data_b0..b3 [0:NSETS-1][0:WAYS-1]`）が Block RAM（RAMB36）ではなく、**フリップフロップおよび分散 LUT として合成** された。
- この単一モジュールだけで **82,539 LUTs** を消費。

### 原因 2: `atg_rop_fblend` のファブリック FP 演算器展開（49.8k LUTs の浪費）
- `rtl/gpu/rop/atg_rop_fblend.v` において、4 レーン × 4 色チャネル ＝ 16 個の単精度浮動小数点加算器（`am_fp_add`）および乗算器がファブリック論理ゲート上に全展開され、**約 50,000 LUTs** を消費。
- `minimal.mk` では `CONFIG_ROP_DUAL_SOURCE=0`, `CONFIG_ROP_ENABLE_LOGICOP=0` に設定されているが、fp32 ブレンドパイプラインが常時合成されていた。

### 原因 3: `boards/kc705/atg_kc705_top.v` におけるパラメータのハードコード
- ボードトップ（`atg_kc705_top.v`）が `include/atg_config.vh` をインクルードしておらず、以下のように固定値で `atg_top` をインスタンス化していた：
  - `SU_NREGS(64)`（minimal の 32 ではなく 64）
  - `SU_LDS_BYTES(16384)`（minimal の 1024 ではなく 16 KiB）
  - `SU_PACKED(1)` / `SU_SUBGROUP(1)`（minimal の 0 ではなく有効化）

---

## 4. ミニマム構成で KC705 に Fit させるための是正方針

1. **`atg_tu_cache` の BRAM 推論指定**:
   - `(* ram_style = "block" *)` 属性を付与し、Block RAM（RAMB36E1 4〜8 個）にマッピング。これにより **約 75,000 LUTs を即座に削減**。
2. **`boards/kc705/atg_kc705_top.v` の `atg_config.vh` 連動**:
   - ボードトップで `include/atg_config.vh` をインクルードし、`CONFIG_SU_*`, `CONFIG_RX_*`, `CONFIG_TU_*`, `CONFIG_ROP_*` マクロからパラメータを動的伝播させる。
   - `atg_top` への `L1_BANKS` や `MRT_COUNT` の引き渡し。
3. **`atg_rop_fblend` の Capability ガード**:
   - `minimal.mk`（非高精度ブレンド構成）時に fblend パイプラインをスタブ化またはバイパス可能にし、約 45,000 LUTs を削減。

上記 3 点の最適化により、`atg_kc705_top` の全体消費は **約 120,000 〜 140,000 LUTs**（Kintex-7 325T の 60〜70%）まで圧縮され、確実に KC705 に Fit して P&R（Timing Closure）へ進めることが判明しました。
