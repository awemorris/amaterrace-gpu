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
   - **Stage 2 (TEST)**: Z/Stencil Test & Early Kill
   - **Stage 3 (BLEND)**: Phase 015 のストリームブレンダ呼び出し
   - **Stage 4 (COMM)**: キャッシュ書き込み & Pixel Lock 解除

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_hazard.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/rop/atg_rop_hazard.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_wb.v`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_rop_hazard_tb.v`

### 2. モジュールインターフェース設計 (`atg_rop_hazard.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rop_hazard #(
    parameter NUM_ENTRIES = 16,
    parameter TAG_W = 32  // {RT[1:0], Y[15:1], X[15:1]}
)(
    input  wire              clk,
    input  wire              rst_n,

    // クアッド割り当てインターフェース (パイプライン投入段)
    input  wire              alloc_valid,
    output wire              alloc_ready,  // 満杯でないかつハザードなし
    input  wire [TAG_W-1:0]  alloc_tag,
    output wire [3:0]        alloc_id,     // 割り当てられた CAM エントリ ID

    // クアッド解放インターフェース (パイプラインコミット段)
    input  wire              release_valid,
    input  wire [3:0]        release_id
);
```

### 3. RTL アーキテクチャと CAM 比較
- 16 エントリの valid ビットおよびタグレジスタを保持。
- `alloc_tag` に対し、既存の有効エントリのタグとの 16 並列一致比較（`match[i] = entry_valid[i] && (entry_tag[i] == alloc_tag)`）を行う。
- `hazard_hit = |match;`
- 空きエントリの検出（プライオリティエンコーダ）と `alloc_id` の払い出し。
- `alloc_ready = (!hazard_hit) && has_empty_entry;`
- これにより、異なるタイル・座標のクアッドは待ち時間 0 で連続投入され、完全なパイプライン走行が維持される。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: エントリ数カウント等の加算には必ず `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rop_hazard_tb.v`
- **検証項目**:
  1. **RAW ハザード検出**: 同一座標 `{X, Y}` を連続投入した際、2 つ目のクアッドが 1 つ目のコミット（release）まで正確にストールすること。
  2. **非衝突連続スループット**: 異なる座標のクアッド 16 個を毎サイクル連続で投入し、一切ストールせず通過すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rop_hazard
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 連続する異なるピクセルへの書き込みが毎サイクル 1 クアッドで処理されること。
- 同一ピクセルへの連続書き込み時に RAW ハザードが防止され、データ破壊が起きないこと。
- `sim/run.sh atg_rop_hazard` が PASS すること。
- R1 レビュー APPROVE 獲得。
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
