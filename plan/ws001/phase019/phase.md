<!-- awesome-plan project=amaterrace-gpu record=ws001-p019 -->

# Phase 019: フィルタリングパイプライン統合 & 相互排他ウェイト撤廃

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p018](../phase018/phase.md)
- **優先度**: Major (パイプライン相互排他空転の根絶)
- **出典**: ユーザー諮問（TU パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/tu/atg_tu.v` において、固定小数点フィルタ（`atg_tu_filter`）と浮動小数点フィルタ（`atg_tu_ffilt`）が互いに相手のアイドルを待つ相互排他制御（`assign tc_ready = f32 ? f_ready && u_idle : u_ready && f_idle;`）によりパイプラインが空転している問題を解消する。
フィルタリング処理を固定レイテンシの完全ストリームパイプラインとして統合し、異なるフォーマットのクアッドが連続してもストールゼロで通過できるようにする。

## 範囲・作業内容

1. **相互排他ウェイトの撤廃**:
   - `atg_tu.v` の `u_idle` / `f_idle` による相互ブロッキングを排除。
   - 補間ステージ（水平・垂直バイリニア Lerp、ミップ間トリリニア Lerp）を固定レイテンシパイプラインとしてストリーム化。

2. **フォーマット統合補間器の整備**:
   - 8-bit unorm および fp32/fp16 パスを統一されたパイプライン段数（Stage 5: Bilinear Lerp、Stage 6: Trilinear Lerp）に揃え、インオーダー出力を保証。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 禁止（`am_mul` / `am_fp_mul` のみ使用）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_filter.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_ffilt.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_pipeline_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu.v` 内部統合)
- 各サブフィルタの `tc_ready` 条件から相手モジュールの `idle` フラグを完全削除。
- 共通のパイプラインディスパッチ・リオーダリング機構により、UNORM8 処理と FP16/FP32 処理がインターリーブされても、出力順序が保証されるよう FIFO バッファリングを行う。

### 3. RTL アーキテクチャとパイプライン同期
- パイプライン段数を両パスともに固定段数（例: 6 サイクル）に揃える、あるいは完了タグ FIFO を用いて出力側でインオーダー合流させる。
- 演算器には `am_mul` / `am_fp_fma` を用い、スライスを共有化。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: Lerp 演算における加重平均の積はすべて `am_mul` / `am_fp_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_pipeline_tb.v`
- **検証項目**:
  1. UNORM8 テクスチャサンプリング要求と FP16 テクスチャサンプリング要求を 1 サイクルおきに交互に連続投入した際、ストールすることなく両方のパイプラインが並行動作すること。
  2. 出力結果が投入順序どおりに 1 サイクル 1 クアッドで返ること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_pipeline
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 異なるフォーマット間での相互排他ウェイトが撤廃され、連続サンプリングがストールフリーで実行できること。
- `sim/run.sh atg_tu_pipeline` が PASS すること。
- R1 レビュー APPROVE 獲得。
   - 8-bit テクスチャと fp32/sRGB テクスチャが交互に入力されるインターリーブ検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 異なるフォーマットのクアッドが連続しても相互排他ストールが発生しないこと。
- 補間精度および画像出力が既存仕様と完全一致すること。
