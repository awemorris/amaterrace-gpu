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

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_fblend_tb.v` による全ブレンドモード・全フォーマットのベクトル検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- `atg_rop_fblend` が 1 beat/cycle のスループットで連続入力可能であること。
- sRGB / SFLOAT / UNORM10 フォーマットのブレンド結果が仕様と完全一致すること。
