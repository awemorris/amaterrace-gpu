<!-- awesome-plan project=amaterrace-gpu record=ws001-p031 -->

# Phase 031: BLT 1サイクル並列 MSAA 4x Resolve（クアッド並列平均化）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p030](../phase030/phase.md)
- **優先度**: Major (MSAA Resolve スループットの大幅引き上げ)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/blt/atg_blt_rsv.v` において、MSAA 4x Resolve 処理がサンプル逐次読み出し・シリアル平均化によってボトルネックになっている問題を解消する。
$2 \times 2$ クアッド単位（16 テクセル）を並列にアンパックし、16 チャンネルの 4 サンプル平均化加算器により、毎サイクル 1 クアッド（4 ピクセル）の Resolve スループットを達成する。

## 範囲・作業内容

1. **クアッド並列 Resolve パイプラインの実装**:
   - 1 クアッド（4 ピクセル $\times$ 4 サンプル = 16 テクセル）のマルチサンプルデータをバーストバッファから 1 サイクルでアンパック。
   - 4 ピクセル分の 4 サンプル加算・除算（$(s_0 + s_1 + s_2 + s_3)/4$）を 1 サイクル並列加算器ツリーで実行。
2. **フォーマット出力統合**:
   - Phase 026 の 2 段化 `atg_fmt_pack` と直結し、Resolve 後のピクセルを即座に宛先ラインへ書き戻す。
3. **単体・回帰検証**:
   - `sim/tb/atg_blt_rsv_tb.v` による MSAA 4x Resolve の数値精度・画像一致検証。
   - `sim/verilator/run.sh`（`msaa.png`）での検証。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- MSAA Resolve のスループットが 1 quad/cycle（ピーク 4 pixels/cycle）に到達すること。
- Resolve 出力画像が既存リファレンスと完全一致すること。
