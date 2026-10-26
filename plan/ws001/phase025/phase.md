<!-- awesome-plan project=amaterrace-gpu record=ws001-p025 -->

# Phase 025: RX ストリームパイプライン統合 & 全シーン回帰検証

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p022](../phase022/phase.md), [ws001-p023](../phase023/phase.md), [ws001-p024](../phase024/phase.md)
- **優先度**: Critical (RX 全体 6 段ストリームパイプライン統合 & 200MHz タイミング収束)
- **出典**: ユーザー諮問（RX パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

Phase 022（Stream Setup）、Phase 023（MSAA 4x 並列 & Coarse タイルスキップ）、Phase 024（Fast DDA 平面評価）の各コンポーネントを統合し、RX 全体を 6 段の完全ストリームパイプライン（ピークスループット 1 quad/cycle）として完成させる。
SU へのワープパッキング・ディスパッチとのインターフェースを整合し、KC705 200MHz でのタイミングクロージャおよび全シーン回帰検証を達成する。

## 範囲・作業内容

1. **6 段ストリームパイプラインの統合**:
   - **ST0: Prune & Cull**: 裏面カリング & ビューポート包含判定
   - **ST1: Stream Setup**: 固定遅延エッジ・平面係数生成
   - **ST2: Coarse Raster**: $8 \times 8$ タイルスキップ走査
   - **ST3: Fine Raster & Coverage**: $2 \times 2$ クアッド走査 & MSAA 4x 1 サイクル判定
   - **ST4: DDA Plane Interpolator**: 1 サイクル増分平面評価
   - **ST5: Warp Pack & Fire**: 8 クアッドを 32 レーンワープへパッキングし SU へディスパッチ

2. **バックプレッシャー & フロー制御の最適化**:
   - SU からの `fl_gnt` 待ち時にパイプラインが適切にストール・再開する Skid Buffer 機構の整備。

3. **単体・回帰検証**:
   - `sim/run.sh atg_rx`, `sim/verilator/run.sh`（全 7 スイート）での画像完全一致確認。
   - `python3 tools/arith-lint.py` で生演算子 0 件の維持。
   - Vivado 合成・配置配線による WNS >= 0 ns（KC705 200MHz）の確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 通常描画シーンにおいて、RX の実効フィルレートが既存比 20〜50 倍に向上すること。
- 全テストスイートがビット完全一致で PASS すること。
