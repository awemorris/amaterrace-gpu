<!-- awesome-plan project=amaterrace-gpu record=ws001-p016 -->

# Phase 016: Hazard Tracker（Pixel Lock）導入 & ROP 完全パイプライン化

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p014](../phase014/phase.md), [ws001-p015](../phase015/phase.md)
- **優先度**: Critical (Stop-and-Wait 解体による ROP 実効フィルレート 20〜50 倍向上)
- **出典**: ユーザー諮問（ROP パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rop/atg_rop_wb.v` の「同一座標 RAW ハザードを回避するために 1 クアッドごとにメモリ応答まで全停止する」という直列ストップ＆ウェイト方式（`assign d_ready = (st == S_IDLE);`）を根本的に解体する。
16 エントリの Hazard Tracker（Pixel Lock CAM）を新設し、同一座標がパイプライン内を走行中のみ局所ストールさせ、非衝突クアッドを毎サイクルノーウェイト（1 cycle/quad）で通過させる完全 5 段ストリームパイプラインを構築する。

## 範囲・作業内容

1. **Hazard Tracker（Pixel Lock CAM）の実装**:
   - `rtl/gpu/rop/atg_rop_hazard.v` を新設。
   - 16 エントリの CAM でパイプライン走行中のクアッド座標 `{X[15:1], Y[15:1], RT[1:0]}` を並列比較。
   - 衝突時は `stall` をアサート、非衝突時は即座にイシューし、コミット時にエントリを解放。

2. **ROP パイプラインの 5 段ストリーム化**:
   - **Stage 0 (HAZ)**: Hazard Check & Pixel Lock 登録
   - **Stage 1 (TAG)**: ラインバッファ / キャッシュ タグ照合 & Dest 読み出し
   - **Stage 2 (TEST)**: Depth / Stencil Test（キルされたサンプルは Blend をバイパス）
   - **Stage 3 (BLND)**: 完全パイプライン化ブレンド（Phase 014 / 015 の成果物を統合）
   - **Stage 4 (COMM)**: バッファ / キャッシュ書き込み & Pixel Lock 解放

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_hazard_tb.v` による RAW 競合・連続描画・バックプレッシャーのコーナーケース検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力完全一致。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 座標の異なるクアッドが毎サイクル連続してイシュー（スループット 1 beat/cycle）できること。
- 同一座標に対するオーバーラップ描画において、RAW ハザードが確実に防止され描画結果が崩れないこと。
