<!-- awesome-plan project=amaterrace-gpu record=ws001-p026 -->

# Phase 026: atg_fmt_pack 2段パイプライン化（200 MHz クリティカルパス解消）

- **親**: [WS001](../ws.md)
- **状態**: `in-progress`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (KC705 200 MHz 最大クリティカルパスの解消・論理深さ 50% 削減)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/fmt/atg_fmt_pack.v` において、全レンダーターゲットフォーマット変換と書き込みマスク、および巨大なコンビネーショナル OR ツリーが単一サイクルに直列接続され、論理段数が 60 段を超えて KC705 200 MHz のタイミングクロージャを阻害している最大ボトルネックを解消する。
フォーマット変換段とマルチプレクス段の間にパイプラインレジスタを挿入し、2 段パイプライン（`LAT=2`）へ分割してクリティカルパス遅延を半減させる。

## 範囲・作業内容

1. **`atg_fmt_pack.v` の 2 段パイプライン化**:
   - **Stage 1 (CVT)**: 各チャンネルの UNORM / FP 変換およびビット位置整列（`f2unorm`, `f2h`, バイトパッキング）。
   - **Stage 2 (MUX)**: フォーマット選択 MUX、書き込みマスク適用、最終ラインデータ組み立て。
2. **ROP / BLT 呼び出し側のレイテンシ整合**:
   - `atg_rop_blend.v` および `atg_blt.v` におけるフォーマットパッキング段のサイクル遅延を整合。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/fmt/atg_fmt_pack.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/fmt/atg_fmt_pack.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_blend.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/blt/atg_blt.v`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_fmt_pack_tb.v`

### 2. モジュールインターフェース設計 (`atg_fmt_pack.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_fmt_pack #(
    parameter LAT = 2  // 2 段パイプライン固定
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // パイプラインクロックイネーブル

    input  wire [3:0]  fmt,         // ターゲットフォーマット (RGBA8888, RGB565, FP16, etc.)
    input  wire [31:0] in_r, in_g, in_b, in_a,
    input  wire [3:0]  in_mask,

    output reg  [31:0] out_pixel,   // パック済みピクセルデータ
    output reg  [3:0]  out_mask
);
```

### 3. RTL アーキテクチャとパイプラインレジスタ分割
- **Stage 1 (CVT)**:
  `in_r`, `in_g`, `in_b`, `in_a` から各フォーマットの量子化表現（UNORM8, UNORM565, FP16）を並列生成し、中間パイプラインレジスタ `cvt_r`, `cvt_g`, `cvt_b`, `cvt_a`, `fmt_q`, `mask_q` に格納。
- **Stage 2 (MUX & Pack)**:
  `fmt_q` に応じたビットフィールド結合とマスク適用を行い、`out_pixel` へ出力。
- 呼び出し元の `atg_rop_blend.v` は、パッキング結果を待つサイクル数を 1 から 2 に合わせる。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: UNORM 丸め加算等には必ず `am_add` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_fmt_pack_tb.v`
- **検証項目**:
  1. 全対応フォーマットについて、入力後正確に 2 サイクル遅延して正確なパックピクセルが出力されること。
  2. `sim/verilator/run.sh`（全シーン）を実行し、レンダリング画像が 1 ビットも狂わず一致すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_fmt_pack
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 巨大コンビネーショナルパスが 2 段に分割され、Vivado タイミング解析でクリティカルパスが大幅に改善すること。
- 全シーンで画像が完全一致すること。
- R1 レビュー APPROVE 獲得。
   - Vivado 合成による WNS 改善確認（クリティカルパス遅延が 5.0ns から 2.5ns 未満へ改善）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- `atg_fmt_pack` の論理段数が半減し、200 MHz で十分なタイミングマージンが確保できること。
- 全フォーマットのパッキング結果が既存実装と 1 bit の差異もなく一致すること。
