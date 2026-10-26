<!-- awesome-plan project=amaterrace-gpu record=ws001-p020 -->

# Phase 020: マルチバンク・4-way L1 テクスチャキャッシュ（4 バンク同時読み出し）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p018](../phase018/phase.md)
- **優先度**: Critical (16 サイクル逐次ルックアップの撤廃 & 4 テクセル 1 サイクル同時読み出し)
- **出典**: ユーザー諮問（TU パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/tu/atg_tu_cache.v` において、バイリニアに必要な 16 個のテクセルを「1 サイクルに 1 テクセルずつシリアルに LOOKUP」している致命的ボトルネック（全ヒットでも 16 サイクル浪費）、および Direct Mapped によるキャッシュライン衝突スラッシングを根本解決する。
テクセル座標最下位ビットに応じた 4 バンク・インターリーブ BRAM 構成により、近接 $2 \times 2$ テクセルをバンク衝突ゼロで 1 サイクルで同時読み出し可能な 4-way Set-Associative L1 テクスチャキャッシュを実装する。

## 範囲・作業内容

1. **4 バンク・インターリーブ構造の実装**:
   - テクセル座標最下位ビット $(x[0], y[0])$ に基づき、Bank 0 (even, even), Bank 1 (odd, even), Bank 2 (even, odd), Bank 3 (odd, odd) に分散配置。
   - バイリニア補間の近接 $2 \times 2$ テクセルが常に異なる 4 バンクにマッピングされ、クロスバーを介して 1 サイクルで同時読み出し可能。

2. **4-way Set-Associative 化**:
   - Direct Mapped を廃止し、8 KiB〜16 KiB の 4-way セットアソシアティブキャッシュへ刷新。
   - Tree-PLRU エビクションポリシーを適用。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - BRAM 同期リード推論の徹底。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_cache.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu_cache.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_cache_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu_cache.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cache #(
    parameter NBANKS     = 4,
    parameter WAYS       = 4,
    parameter LINE_BYTES = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    // クアッドテクセル要求 (4 テクセル並列フェッチ)
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [4*32-1:0] req_addr,     // 4 テクセル分のアドレス
    output reg         rsp_valid,
    output reg  [4*32-1:0] rsp_data,     // 4 テクセル分のデータ (各 32-bit)

    // AMB / L2 メモリインターフェース
    output wire        mem_req_valid,
    input  wire        mem_req_ready,
    output wire [25:0] mem_req_line,
    input  wire        mem_rsp_valid,
    input  wire [LINE_BYTES*8-1:0] mem_rsp_rdata
);
```

### 3. RTL アーキテクチャとバンク分配
- テクセル $(X, Y)$ のバンク番号は `bank_id = {Y[0], X[0]}`。
- $2 \times 2$ クアッドの 4 テクセル $(X, Y), (X+1, Y), (X, Y+1), (X+1, Y+1)$ は、数学的に必ず 4 つの異なるバンク `{0, 1, 2, 3}` に 1 対 1 対応する！
- したがって、4 バンクに BRAM を分割すれば、一切のバンク衝突なしで 1 サイクルで 4 つのテクセルを同時リードできる。
- 4 バンクそれぞれのリードデータを、要求元のレーンに届ける $4 \times 4$ クロスバー（マルチプレクサ）を配置。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: バンクアドレス計算、タグ比較、PLRU 更新はすべて `am_add` / `am_sub` または論理演算子を用いること。
- **BRAM 推論構造**: 各バンクのメモリアレイはクロック同期リードとすること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_cache_tb.v`
- **検証項目**:
  1. **衝突フリー 4 テクセル同時リード**: 任意の $2 \times 2$ バイリニアフットプリントに対して、キャッシュヒット時に 1 サイクルで 4 テクセルが完全に出力されること。
  2. **4-way アソシアティブヒット率検証**: 同一セットに属する複数ラインの競合時、PLRU により正しくラインが保持・置換されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_cache
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 4 テクセルが 1 サイクルで同時読み出しできること（全ヒット時 1 cycle/quad）。
- `sim/run.sh atg_tu_cache` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_tu_cache_tb.v` によるマルチバンク同時読み出し、バンクコンフリクトフリー性の検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- クアッド内のバイリニアテクセルが 1 サイクル（最大 4 サイクル）で供給可能になること。
- キャッシュヒット時のレイテンシが 16 サイクルから 1〜2 サイクルへ激減すること。
