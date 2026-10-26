<!-- awesome-plan project=amaterrace-gpu record=ws001-p018 -->

# Phase 018: TU 4 レーン並列ストリームアドレス生成（atg_tu_addr 逐次 FSM 撤廃・1 cycle/quad 化）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (アドレス生成レイテンシ 8〜16 サイクルから 1 サイクルへ短縮)
- **出典**: ユーザー諮問（TU パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/tu/atg_tu_addr.v` において、クアッド（4 レーン）のアドレス計算を 1 レーンずつ 2 サイクルかけて FSM で逐次計算している構造（LA $\to$ LB $\to$ LA $\to$ LB、計 8〜16 サイクル浪費）を完全撤廃する。
クアッド共有の LOD $\lambda$ 計算、および 4 レーン並列 Wrap & Footprint アドレス生成を 1 サイクルで完了し、毎サイクル 1 クアッドを処理可能なストリームパイプラインを構築する。

## 範囲・作業内容

1. **4 レーン並列アドレス生成回路の実装**:
   - `atg_tu_addr.v` の逐次ステートマシン（LA/LB）を撤廃。
   - クアッド間偏微分から共通 LOD $\lambda$ を 1 サイクルで決定（Stage 1）。
   - クアッド 4 レーンの Wrap（Repeat, ClampToEdge, ClampToBorder 等）およびバイリニア用 $2 \times 2$ テクセルオフセット計算を 4 レーン並列展開（Stage 2）。

2. **ストリーミングインターフェースの整備**:
   - 入力 `tx_valid` / `tx_ready` から出力 `ta_valid` / `ta_ready` までの固定 2 サイクルパイプライン化。
   - スループット 1 cycle/quad の連続受け入れ対応。

3. **単体・回帰検証**:
   - `sim/tb/atg_tu_addr_tb.v` による全 Wrap モード・全テクスチャサイズの並列計算ベクトル検証。
   - `sim/run.sh atg_tu`, `sim/verilator/run.sh`（`tex.png`, `core.png`）でのビット完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- アドレス生成が 1 cycle/quad のスループットで連続処理できること。
- 既存テストにおいて画像出力が 1 bit の差異もなく一致すること。
