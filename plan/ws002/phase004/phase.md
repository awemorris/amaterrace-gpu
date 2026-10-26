<!-- awesome-plan project=amaterrace-gpu record=ws002-p004 -->

# Phase 004: TU 異方性フィルタリング（Anisotropic Filtering 最大 16x）

- **親**: [WS002](../ws.md)
- **状態**: `cleared` (2026-10-27 R1 敵対的レビュー APPROVE 承認完了)
- **依存**: [ws001-p021](../../ws001/phase021/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

斜め方向のテクスチャサンプリング時に生じるテクスチャボケを解消し、Vulkan 1.0 仕様で要求される最大 16x の異方性フィルタリング（`samplerAnisotropy` / `maxAnisotropy`）をサポートする。

## 範囲・作業内容

1. **EWA（Elliptical Weighted Average）サンプリングループ**:
   - 偏微分ベクトルから長軸・短軸の比（Anisotropy Ratio）を算出し、最大 16 回のバイリニアサンプリングを行うループ制御を実装。
2. **重み付き平均アキュムレータ**:
   - サンプリングされた各テクセルをガウシアン重みで積算・正規化する演算器を追加。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` / `am_fp_mul` のみ）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_aniso.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu_aniso.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_aniso_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu_aniso.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_tu_aniso #(
    parameter MAX_SAMPLES = 16
)(
    input  wire        clk,
    input  wire        rst_n,

    // サンプリング要求
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] dudx, dudy, dvdx, dvdy,
    input  wire [3:0]  max_aniso, // 1..16

    // アドレス生成への個別サンプルリクエスト
    output wire        samp_valid,
    input  wire        samp_ready,
    output wire [31:0] samp_u, samp_v,
    output wire [15:0] samp_weight,

    // フィルタ結果集約
    input  wire        filt_valid,
    input  wire [31:0] filt_texel,
    output wire        res_valid,
    output wire [31:0] res_texel
);
```

### 3. RTL アーキテクチャと EWA サンプリング
- 楕円フットプリントの長軸方向ベクトル $(\Delta u, \Delta v)$ を正規化。
- サンプル数 $N = \min(\lceil \text{Ratio} \rceil, \text{max\_aniso})$。
- 長軸に沿って $N$ 点のバイリニアサンプル位置を等間隔で生成。
- ガウシアン重み $w_i = \exp(-k \cdot d_i^2)$ を LUT から引き出し、積和演算器（`am_mul` + `am_add`）でアキュムレート。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: ベクトル内積、アキュムレーションの積算には必ず `am_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_aniso_tb.v`
- **検証項目**:
  1. 極端な斜め視点（アスペクト比 16:1 のフットプリント）において、16 回のバイリニアサンプルが正確に生成・積算されること。
  2. 出力テクセルがボケずにシャープに復元されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_aniso
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 最大 16x の Anisotropic Filtering が正常に動作すること。
- `sim/run.sh atg_tu_aniso` が PASS すること。
- R1 レビュー APPROVE 獲得。
