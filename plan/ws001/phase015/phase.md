<!-- awesome-plan project=amaterrace-gpu record=ws001-p015 -->

# Phase 015: fp32 / sRGB ブレンド完全ストリームパイプライン化（FSM 撤廃・1 beat/cycle）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p014](../phase014/phase.md)
- **優先度**: Critical (sRGB / HDR レンダリングスループット 100 倍向上)
- **出典**: ユーザー諮問（ROP ブレンド高速化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rop/atg_rop_fblend.v` において、単一の加算器・乗算器を 12 ステートの FSM で使い回して 1 演算ずつシリアル実行し、1 クアッドに 60〜100 サイクルを浪費している構造を完全撤廃する。
毎サイクル 1 クアッド（4 ピクセル）を受け入れ可能な 4 段ストリームパイプライン（スループット 1 beat/cycle）へ再設計する。

## 範囲・作業内容

1. **4 段完全ストリームパイプラインの設計**:
   - **Stage 1 (DEC)**: Unpack & sRGB Decode（16 並列 Linear LUT、Latency: 1 cycle）
   - **Stage 2 (FAC)**: Factor 生成（Clamp [0, 1]、1 - x、Min/Max、Latency: 1 cycle）
   - **Stage 3 (ALU)**: 16 並列 FMA / Lerp 演算パイプライン（Latency: 2 cycles）
   - **Stage 4 (ENC)**: sRGB Encode & Pack（16 並列 Enc LUT、Write Mask 適用、Latency: 1 cycle）

2. **制御・インターフェースの更新**:
   - FSM ベースのハンドシェイクから、ストリーミング有効信号（`valid` / `ready`）および FIFO バッファリングによるバックプレッシャー制御へ刷新。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` は使用厳禁（`am_mul` / `am_fp_mul` のみ使用）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_fblend.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rop/atg_rop_fblend.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_rop_fblend_tb.v`

### 2. モジュールインターフェース設計 (`atg_rop_fblend.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rop_fblend #(
    parameter NPIX = 4  // 1 クアッド = 4 ピクセル
)(
    input  wire        clk,
    input  wire        rst_n,

    // 入力インターフェース (Ready/Valid)
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [NPIX*32-1:0] in_src,   // 4 ピクセルの Src RGBA8888 / FP16
    input  wire [NPIX*32-1:0] in_dst,   // 4 ピクセルの Dst RGBA8888 / FP16
    input  wire [31:0]        in_const, // Blend Color 定数
    input  wire [15:0]        in_mode,  // ブレンドファクター・方程式設定
    input  wire [NPIX-1:0]    in_mask,  // ピクセルイネーブルマスク

    // 出力インターフェース (Ready/Valid)
    output wire        out_valid,
    input  wire        out_ready,
    output wire [NPIX*32-1:0] out_res,  // ブレンド結果
    output wire [NPIX-1:0]    out_mask
);
```

### 3. RTL アーキテクチャとパイプライン設計
- 従来の 12 状態 FSM (`st == S_SRC_DECODE`, `st == S_MUL`, `st == S_ADD` ...) を **完全撤廃** する。
- 各ステージはパイプラインストール信号（`pipe_stall = !out_ready && out_valid`）に基づき同期更新されるストリームレジスタ段とする。
- 演算器の共有インスタンス化:
  - 乗算は必ず `am_mul`（FP16/UNORM8 の場合は 16x16 / 9x9）を使用し、`*` を直接記述しないこと！
  - 加減算は必ず `am_add` / `am_sub` を使用すること。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: すべての乗算は `am_mul` を通し、`SYNTH_KINTEX7` で DSP48E1 に正しくバインドされること。
- **生演算子 0 件**: `tools/arith-lint.py` をパスすること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rop_fblend_tb.v`
- **検証項目**:
  1. **連続バースト転送**: 毎サイクル 1 クアッドを入力し、パイプラインレイテンシ（合計 5 サイクル）後に毎サイクル 1 クアッドが連続出力されること（スループット 100%）。
  2. **各種 Blend Mode 検証**: `ADD`, `SUB`, `REVSUB`, `MIN`, `MAX`、および `SRC_ALPHA`, `ONE_MINUS_SRC_ALPHA` 等の全ブレンドファクターでのビット完全一致検証。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rop_fblend
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 毎サイクル 1 クアッドの連続処理が可能であること。
- `sim/run.sh atg_rop_fblend` が PASS すること。
- `tools/arith-lint.py` 違反 0 件。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_fblend_tb.v` による全ブレンドモード・全フォーマットのベクトル検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- `atg_rop_fblend` が 1 beat/cycle のスループットで連続入力可能であること。
- sRGB / SFLOAT / UNORM10 フォーマットのブレンド結果が仕様と完全一致すること。
