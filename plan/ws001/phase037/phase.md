<!-- awesome-plan project=amaterrace-gpu record=ws001-p037 -->

# Phase 037: am_axi_master.v の深層 Outstanding 化（16〜32 枠対応）

- **親**: [WS001](../ws.md)
- **状態**: `completed`
- **依存**: [ws001-p001](../phase001/phase.md), [ws001-p035](../phase035/phase.md)
- **優先度**: Major (DDR3/4 高レイテンシ環境下でのメモリ帯域飽和)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/library/bus/am_axi_master.v` において、`OUTSTANDING_LOG2 = 2`（最大 4 リクエスト）と極めて浅く設定されており、さらに AR/AW 送出部にバッファがないためアドレスフェーズが直列化（`!ar_v` の間しか次要求を受けられない）し、DDR3 メモリのラウンドトリップレイテンシ（50〜100 サイクル）下でパイプラインが即座に枯渇してメモリ帯域の 20% 未満しか引き出せない問題を解決する。
Outstanding 管理構造を最大 16〜32 枠（`OUTSTANDING_LOG2 = 4/5`）へ拡張し、AR チャネルに Skid Buffer / キューを統合してバックツーバック連続アドレス発行を可能にし、高レイテンシ環境下でも DDR 物理帯域を 85% 以上飽和させる。

## 範囲・作業内容

1. **Outstanding 管理テーブルの深層化と連続発行パイプライン**:
   - `am_axi_master.v` のインフライトリクエスト追跡バッファ（`am_fifo_key`）の既定枠数を 16〜32 枠（`OUTSTANDING_LOG2 = 4` または `5`）へ拡張。
   - `ar_v` の 1 エントリ直列化トラップを解消: AR 送出部に Phase 035 の `am_skid` を組み込み、前段の `rd_take` が毎サイクル連続で発行できるようにする。
   - `aw_v` / W チャネル側も同様にハンドシェイクを分離し、ライトコマンドの連続受付を可能にする。
2. **単体・回帰検証**:
   - `sim/tb/am_axi_master_tb.v` による 32 枠フルインフライト時のリオーダー、インターリーブ応答検証。
   - `tools/arith-lint.py` 違反 0 件。
   - `sim/run.sh am_axi_master` PASS。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/library/bus/am_axi_master.v`
- 更新: `/home/awe/amaterrace-gpu/spec/library/bus/am_axi_master.md`
- 更新・拡充: `/home/awe/amaterrace-gpu/sim/tb/am_axi_master_tb.v`

### 2. モジュールインターフェース設計
インターフェースの信号名・機能は完全互換を維持する。
```verilog
module am_axi_master #(
    parameter ADDR_W           = 32,
    parameter LINE_BYTES       = 32,
    parameter LINE_SHIFT       = 5,
    parameter DATA_W           = 64,
    parameter UW               = 16,
    parameter OUTSTANDING_LOG2 = 5,   // 既定値を 2 (4枠) から 5 (32枠) へ拡張
    parameter NID              = 1,
    parameter ID_W             = 1,
    parameter KEY_W            = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        halt,
    output wire        idle,

    // クライアント側リクエスト
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [ADDR_W-LINE_SHIFT-1:0] req_line,
    input  wire [LINE_BYTES-1:0]        req_be,
    input  wire [LINE_BYTES*8-1:0]      req_wdata,
    input  wire [UW-1:0]                req_user,
    input  wire [ID_W-1:0]              req_id,
    input  wire [KEY_W-1:0]             req_key,

    // クライアント側レスポンス
    output reg         rsp_valid,
    output reg         rsp_write,
    output reg  [UW-1:0]           rsp_user,
    output reg  [LINE_BYTES*8-1:0] rsp_rdata,
    output reg         rsp_error,

    // AXI4 Master インターフェース（AW, W, B, AR, R）
    ...
);
```

### 3. RTL アーキテクチャとボトルネック解消詳細
#### (1) 直列化ボトルネックの完全排除
旧来の実装では:
`wire rd_can = !halt && !ar_v && rq_rdy[q_id] && !r_other;`
となっており、`ar_v`（ARVALID）がハイの間は `rd_can` がローになるため、AXI バス側が `m_arready` を返すまで次のリードを受け入れられなかった。
**改善策**:
AR チャネルの出力段に Phase 035 の `am_skid` を配置する。
- リクエスト受付部から Skid Buffer へアドレス（`ar_line`, `ar_id`）をプッシュ。
- Skid Buffer が空きを持つ（`skid_ar_ready=1`）限り、`rq_rdy` があれば毎サイクル連続して `rd_take` を受け入れる。
- Skid Buffer の出力がそのまま `m_arvalid`, `m_araddr`, `m_arid` となり、AXI スレーブとハンドシェイクする。

#### (2) インフライト追跡（`am_fifo_key`）の深度拡張
- `OUTSTANDING_LOG2 = 5`（32 枠）により、DDR3 メモリの長いレイテンシ（数十〜百サイクル）の間でも、常に 32 個のラインリード要求をインフライトにしておくことができる。
- `rq`（リード追跡 FIFO）および `wq`（ライト追跡 FIFO）のカウンタ幅が `O + 1` ビット（6 ビット）になるため、ビット幅の切り捨てやワーニングに注意する。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: カウンタ、インデックス計算等は必ず `rtl/library/arith/`（`am_add`, `am_sub` 等）を使用すること。生 `+`, `-` は禁止。
- **ビットシフト**: 定数シフト（`>> DATA_W` 等）は許可されるが、可変シグナルによるシフトは `am_shift` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/am_axi_master_tb.v`
- **検証項目**:
  1. **32 Outstanding In-flight Test**:
     AXI メモリモデルの応答レイテンシを 60 サイクルに設定し、32 個の連続リード要求をバブルなしで投入。
     32 個の要求すべてが ARVALID/ARREADY ハンドシェイクを完了し、順次パイプラインでレスポンスが戻ることを確認。
  2. **Interleaved & Reordered Response**:
     複数 ID（NID > 1）時における AXI ID ごとの応答順序保存と ID 間インターリーブの正当性検証。
  3. **帯域飽和度測定**:
     連続リード時の実効スループットが、旧実装比で 3 倍以上に向上していることを確認。
- **実行コマンド**:
  ```bash
  ./sim/run.sh am_axi_master
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 32 枠の Outstanding リクエストが正常に追跡・完了できること（deep_32: 32 reads in 32 cycles 100% スループット達成）。
- メモリ応答遅延が大きい環境下（60 サイクル）での実効スループット向上および NID=2 リオーダー・インターリーブ応答検証。
- `sim/run.sh am_axi_master`: PASS（5 s、deep_32, reorder, l32, kc705, quiesce 全 PASS）。
- `sim/run.sh atg_mc`: PASS（59 s、全 6 シェープ A〜F 全て完全一致 PASS）。
- `python3 tools/arith-lint.py --top am_axi_master`: 違反 0 件。
- Verilator lint: 警告 0 件。
- コミット: `0cd9ffe`
