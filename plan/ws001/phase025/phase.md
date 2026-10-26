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

2. **バックプレッシャー & キューイング整備**:
   - ステージ間に Phase 035 の `am_skid` を挿入し、長距離タイミングパスを完全切断。
   - SU のディスパッチ FIFO が満杯になった場合のバックプレッシャー伝搬。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rx/atg_rx_frag.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rx/atg_rx.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_rx_pipeline_tb.v`

### 2. モジュールインターフェース設計 (`atg_rx.v` トップ)
- 外部入出力ポートは完全互換。
- 内部の各サブモジュール間接続に Skid Buffer（`am_skid`）を用いてステージ間のタイミングパスを完全にフリップフロップで絶縁。

### 3. RTL アーキテクチャと検証方針
- 6 段パイプライン各段のレイテンシとハンドシェイク（`valid`/`ready`）を統合。
- 8 個の有効クアッドが集まった時点で 32 レーンワープとして SU へイシュー。
- トライアングル末尾のパディング（フラッシュ）制御。

### 4. テストベンチ検証シナリオ（T1/P1 共通）
- **テストコマンド**:
  ```bash
  ./sim/run.sh atg_rx_pipeline
  ./sim/verilator/run.sh
  python3 tools/arith-lint.py
  ```
- 既存の Verilator 画像出力（triangle, cube, tex_cube 等）が 1 ピクセルも崩れずに完全一致すること。

---

## 検証基準（受け入れ条件）

- 6 段ストリームパイプラインが 1 quad/cycle スループットで完走すること。
- 全 7 種の Verilator E2E レンダリングテストで画像が完全一致すること。
- `tools/arith-lint.py` 違反 0 件。
- R1 レビュー APPROVE 獲得。

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
