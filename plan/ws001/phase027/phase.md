<!-- awesome-plan project=amaterrace-gpu record=ws001-p027 -->

# Phase 027: MC AXI バースト結合キュー（Burst Coalescer: ARLEN=3/7 自動マージ）

- **親**: [WS001](../ws.md)
- **状態**: `completed`
- **依存**: [ws001-p003](../phase003/phase.md)
- **優先度**: Critical (DDR3 バス物理稼働率 25% 未満から 85% 以上へ引き上げ)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/mc/atg_mc.v` において、すべての外部メモリアクセスを `ARLEN=0` / `AWLEN=0`（単発 32 バイトアクセス）で発行しているため、DDR3 メモリの Row Activate（tRCD）や Precharge（tRP）が毎回発生し、バス稼働率が 25% 未満に低迷している致命的病理を解消する。
同一ページ・連続アドレスへのアクセスを自動的に検知して `ARLEN=3`（128B）または `ARLEN=7`（256B）のバーストアクセスに統合する AXI Burst Coalescer を実装する。

## 範囲・作業内容

1. **AXI Burst Coalescer の実装**:
   - `rtl/gpu/mc/atg_mc_coalesce.v` を新設。
   - 4 エントリのライン結合キューにより、隣接するキャッシュラインアクセスを監視。
   - 連続するリード/ライト要求を単一の AXI バーストトランザクション（`ARLEN/AWLEN > 0`）へ自動マージ。
2. **バーストレスポンス分配機構**:
   - 外部メモリから返されるバーストデータストリームを各クライアント（SU, TU, ROP, BLT）の要求タグへ正確に逆多重化（Demux）。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/mc/atg_mc_coalesce.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/mc/atg_mc_coalesce.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/mc/atg_mc.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_mc_coalesce_tb.v`

### 2. モジュールインターフェース設計 (`atg_mc_coalesce.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_mc_coalesce #(
    parameter ADDR_W     = 32,
    parameter LINE_BYTES = 32,
    parameter MAX_BURST  = 8   // 最大 8 ビート (256B)
)(
    input  wire        clk,
    input  wire        rst_n,

    // クライアント側単発ライン要求
    input  wire        in_req_valid,
    output wire        in_req_ready,
    input  wire        in_req_write,
    input  wire [ADDR_W-6:0] in_req_line,
    input  wire [LINE_BYTES*8-1:0] in_req_wdata,
    input  wire [7:0]  in_req_tag,

    // AXI 側バースト要求
    output wire        out_req_valid,
    input  wire        out_req_ready,
    output wire        out_req_write,
    output wire [ADDR_W-6:0] out_req_line,
    output wire [7:0]  out_req_len,   // ARLEN / AWLEN
    output wire [LINE_BYTES*8-1:0] out_req_wdata,
    output wire [7:0]  out_req_tag,

    // AXI 側バースト応答 $\to$ クライアント単発応答への分解
    ...
);
```

### 3. RTL アーキテクチャと結合ロジック
- クライアントから要求が来ると、待機中エントリのアドレス（`last_line + len + 1`）と比較。
- 連続アドレスかつ同一クライアント・同一方向であれば、バースト長 `len` をインクリメント（`am_add` 使用）。
- 連続しない、あるいはバースト最大長（8 ビート）に達した、あるいはタイムアウト（例: 8 サイクルアイドル）した場合に、AXI 側へバースト発行。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: カウンタ、アドレス連続判定等の加減算には必ず `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_mc_coalesce_tb.v`
- **検証項目**:
  1. 8 本の連続したアドレスのリード要求が、単一の `ARLEN=7` バーストとして AXI 側へ出力されること。
  2. 不連続アドレスの要求が到着した瞬間に、先行バーストがフラッシュされ、新規バーストが開始されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_mc_coalesce
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 連続メモリアクセスが自動的に AXI バーストに結合され、DDR バス稼働率が向上すること。
- `sim/run.sh atg_mc_coalesce` が PASS すること。
- R1 レビュー APPROVE 獲得。
- コミット: `28c81ba`
- R1 レビュー: **APPROVE** (2026-10-27, `adversarial_review_ws001_p027_mc_coalesce.md`)
- 完了確定: 2026-10-27 (Phase 027 完了)
   - `sim/verilator/run.sh`（全 7 モード）での全パス確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 連続メモリアクセス時に AXI バーストが自動発行され、DDR バス効率が大幅に向上すること。
- 全クライアントのデータ整合性が完全に維持されること。
