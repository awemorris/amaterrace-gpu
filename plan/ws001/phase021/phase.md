<!-- awesome-plan project=amaterrace-gpu record=ws001-p021 -->

# Phase 021: MSHR ノンブロッキングフェッチ & メモリ統合（実効スループット 30〜50 倍向上）

- **親**: [WS001](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p020](../phase020/phase.md), [ws001-p003](../phase003/phase.md)
- **優先度**: Critical (1 Outstanding ブロッキング停止の解体 & Hit-Under-Miss 実現)
- **出典**: ユーザー諮問（TU パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 実施結果

1. **MSHR 実装 (`rtl/gpu/tu/atg_tu_mshr.v`)**:
   - 4エントリ MSHR を新規実装。CAM 検索による重複ライン要求の結合（Secondary Miss / Merge）、Primary Miss 割り当て、最大4本の独立フェッチ並行追跡、メモリリフィル時のキャッシュ更新通知・即時エントリ再利用を完全サポート。
   - 純粋ブール論理マルチプレクサおよび `am_shift` を採用し、演算子 0 件を達成。
2. **キャッシュ統合 (`rtl/gpu/tu/atg_tu_cache.v`)**:
   - ブロッキング単一待機ステート（`MWAIT`）を完全撤廃し、MSHR 連携によるノンブロッキング・Hit-Under-Miss パイプラインを構築。
   - リフィル完了と同時に 4 バンク BRAM へのライン書き込みとタグ更新を実施。
3. **仕様書・テストベンチ**:
   - `spec/gpu/tu/atg_tu_mshr.md` 作成。
   - `spec/gpu/tu/atg_tu_cache.md` 改訂。
   - `sim/tb/atg_tu_mshr_tb.v` 作成：エントリ確保、満杯バックプレッシャー、セカンダリミスマージ、アウトオブオーダーリフィル、即時再利用、80サイクルレイテンシ Hit-Under-Miss 全項目検証。
4. **検証結果**:
   - `sim/run.sh atg_tu_mshr` PASS (0s)
   - `sim/run.sh atg_tu_cache` PASS (2s)
   - `sim/run.sh atg_tu` PASS (128s, 21,358 テストベクタ全パス)
   - `sim/run.sh atg_top` PASS (19s)
   - `tools/lint.sh atg_top` 全項目 clean (0 warnings)
   - `python3 tools/arith-lint.py` 0 operators outside `rtl/library/arith/`

## 目的

`rtl/gpu/tu/atg_tu_cache.v` において、1 テクセルでもキャッシュミスすると外部メモリ応答まで（50〜100 サイクル）キャッシュ全体が `MWAIT` 状態で完全停止する 1 Outstanding ブロッキング構造を解体する。
4 エントリの MSHR（Miss Status Holding Register）を導入し、Hit-Under-Miss（ミス発生中もヒットするテクセル／クアッドを先行実行）を可能にして実効スループットを 30〜50 倍に引き上げる。

## 範囲・作業内容

1. **MSHR（Miss Status Holding Register）の実装**:
   - 最大 4 本の未解決キャッシュラインミスを追跡可能な MSHR テーブルを実装。
   - ミスしたリクエストを MSHR に登録し、AMB / L2 キャッシュ（Phase 003）へ複数未解決バースト要求を発行。
   - 外部メモリ応答待ちの間も、キャッシュヒットする後続テクセルの処理を止めずに実行（Hit-Under-Miss）。

2. **パイプライン・リオーダー完了制御**:
   - メモリデータ到着時に該当 MSHR エントリをアンロックし、停止していたクアッドのパイプライン処理を再開。
   - インオーダー完了を保証するリオーダリング機構の整備。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_mshr.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu_mshr.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_cache.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_mshr_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu_mshr.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_tu_mshr #(
    parameter NENTRIES   = 4,
    parameter LINE_BYTES = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    // ミス登録インターフェース (キャッシュミス発生時)
    input  wire        alloc_valid,
    output wire        alloc_ready,     // MSHR に空きがあるか
    input  wire [25:0] alloc_line_addr,
    input  wire [5:0]  alloc_quad_id,
    output wire [1:0]  alloc_mshr_idx,

    // メモリリフィル応答インターフェース
    input  wire        refill_valid,
    input  wire [1:0]  refill_mshr_idx,
    input  wire [LINE_BYTES*8-1:0] refill_data,

    // キャッシュ更新 & 完了通知
    output reg         mshr_ready_valid,
    output reg  [5:0]  mshr_ready_quad_id,
    output reg  [LINE_BYTES*8-1:0] mshr_ready_data
);
```

### 3. RTL アーキテクチャと Hit-Under-Miss
- キャッシュミスが発生した際、MSHR に同一ラインアドレスの先行リクエストが存在するかチェック（Merge）。
- 存在する場合はそのエントリに相乗り（Secondary Miss）。
- 存在しない場合は新規 MSHR エントリを確保し、外部 AMB へフェッチ要求を送出（Primary Miss）。
- 後続のクアッドが既存キャッシュラインにヒットする場合は、MSHR のフェッチ待ちに関わらずパイプラインを即座に通過（Hit-Under-Miss）。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: MSHR 空きエントリカウント等は必ず `am_add` / `am_sub` を用いること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_mshr_tb.v`
- **検証項目**:
  1. **Hit-Under-Miss 動作確認**: 1 本目のミス（遅延 80 サイクル）が発生している最中に、後続のヒット要求が 1 サイクルで応答を返し続けること。
  2. **4 枠フルインフライト並行リフィル**: 4 本の独立したキャッシュラインミスが同時にインフライトとなり、メモリからの戻りに応じて正確にキャッシュへ書き戻されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_mshr
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- キャッシュミス発生中もヒット要求がストールせず実行されること（Hit-Under-Miss）。
- 4 本のミスが並行して解決できること。
- `sim/run.sh atg_tu_mshr` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_tu_mshr_tb.v` による連続キャッシュミス、Hit-Under-Miss、Miss-Under-Miss のストレステスト。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 外部メモリ待ち中も後続のヒットクアッドがストールせず実行されること。
- 実効テクスチャフェッチフィルレートが大幅に向上すること。
