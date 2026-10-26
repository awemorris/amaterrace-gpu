<!-- awesome-plan project=amaterrace-gpu record=ws001-p035 -->

# Phase 035: Full Skid Buffer（am_skid.v）実装と形式検証（0 バブル切断）

- **親**: [WS001](../ws.md)
- **状態**: `completed` (2026-10-26 R1敵対的レビューAPPROVE・単体PASS)
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (長距離ハンドシェイク配線の完全タイミング切断 & 100% スループット保証)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

GPU 内部のブロック間長距離配線において、Forward（`valid` / `data`）と Reverse（`ready`）の両方向のタイミングパスをフリップフロップで完全に切断しつつ、バブルなし（100% スループット）でデータを転送可能な Full Skid Buffer（レジスタスライス）`rtl/library/bus/am_skid.v` を実装・共通化する。

## 範囲・作業内容

1. **`am_skid.v` の設計・実装**:
   - `rtl/library/bus/am_skid.v` を新設。
   - メインレジスタおよびスキッドレジスタ（2 エントリ構造）によるゼロバブル切断。
   - `in_ready` はスキッドレジスタが空のとき即座にアサート（組み合わせループなし）。
   - パラメータ `WIDTH`（データ幅）対応。
2. **単体・形式検証**:
   - `sim/tb/am_skid_tb.v` を作成し、バックプレッシャー、ランダムストール、連続バースト転送でのスループット 100% およびデータ順序保存を完全検証。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/library/bus/am_skid.v`
- 新設: `/home/awe/amaterrace-gpu/spec/library/bus/am_skid.md`
- 新設: `/home/awe/amaterrace-gpu/sim/tb/am_skid_tb.v`
- 更新: `/home/awe/amaterrace-gpu/tools/lint.sh`（RTL_SRCS / LIB_SRCS に追加）
- 更新: `/home/awe/amaterrace-gpu/sim/run.sh`（TB リストに追加）

### 2. モジュールインターフェース（Exact Port List）

```verilog
`timescale 1ns / 1ps
`default_nettype none

module am_skid #(
    parameter WIDTH = 32
)(
    input  wire             clk,
    input  wire             rst_n,

    // 上流側（Slave / Upstream）
    input  wire             in_valid,
    output wire             in_ready,
    input  wire [WIDTH-1:0] in_data,

    // 下流側（Master / Downstream）
    output wire             out_valid,
    input  wire             out_ready,
    output wire [WIDTH-1:0] out_data
);
```

### 3. RTL アーキテクチャと実装詳細
Full Skid Buffer の目的は、**入力側と出力側の間の組み合わせパスを 100% 遮断すること**である。
- **Forward Path 遮断**: `out_valid` および `out_data` は常に内部 FF（`reg_valid`, `reg_data`）から直接出力する。`in_valid` や `in_data` からの組み合わせスルー（バイパス）を行わない。
- **Reverse Path 遮断**: `in_ready` は `!skid_valid`（スキッドレジスタが空かどうか）のみから直接出力する。`out_ready` を組み合わせ論理で参照してはならない。
- **データ順序の保持**: 常に `reg_data` が出力先頭（Head）であり、下流がストール（`out_ready=0`）した状態で上流から 1 ワード入ってきた場合、その 1 ワードを `skid_data` に退避（Skid）させる。

#### 内部レジスタ定義
```verilog
reg [WIDTH-1:0] reg_data;
reg             reg_valid;
reg [WIDTH-1:0] skid_data;
reg             skid_valid;

assign out_valid = reg_valid;
assign out_data  = reg_data;
assign in_ready  = !skid_valid;
```

#### 状態遷移・レジスタ更新ロジック
転送イベントは上流ハンドシェイク（`insert = in_valid && in_ready`）と下流ハンドシェイク（`remove = out_valid && out_ready`）で一意に決定される。
```verilog
wire insert = in_valid && in_ready;
wire remove = out_valid && out_ready;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        reg_valid  <= 1'b0;
        skid_valid <= 1'b0;
        reg_data   <= {WIDTH{1'b0}};
        skid_data  <= {WIDTH{1'b0}};
    end else begin
        case ({insert, remove})
            2'b10: begin // 挿入のみ（下流ストール）
                if (!reg_valid) begin
                    reg_valid <= 1'b1;
                    reg_data  <= in_data;
                end else begin
                    skid_valid <= 1'b1;
                    skid_data  <= in_data;
                end
            end

            2'b01: begin // 退出のみ（上流アイドル）
                if (skid_valid) begin
                    skid_valid <= 1'b0;
                    reg_data   <= skid_data;
                end else begin
                    reg_valid  <= 1'b0;
                end
            end

            2'b11: begin // 挿入・退出が同時発生（100% スループット維持）
                if (skid_valid) begin
                    reg_data  <= skid_data;
                    skid_data <= in_data;
                end else begin
                    reg_data  <= in_data;
                end
            end

            2'b00: begin // アイドルまたは満杯ホールド
                // 状態保持
            end
        endcase
    end
end
```

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 本モジュール内ではポインタやカウンタは不要であるため、`+`, `-`, `*` などの算術演算子は一切記述しないこと（`tools/arith-lint.py` で即座に弾かれる）。
- **Verilog-2005 準拠**: ファイル先頭に `` `timescale 1ns / 1ps `` および `` `default_nettype none `` を置き、末尾に `` `default_nettype wire `` を配置すること。

### 5. テストベンチ設計・検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/am_skid_tb.v`
- **検証項目**:
  1. **Continuous Burst (100% Throughput)**: 100 サイクル連続で `in_valid=1` かつ `out_ready=1` のとき、毎サイクル 1 トランザクションが通過し、合計レイテンシ 1 サイクルでデータが正確に届くこと。
  2. **Single Skid Test**: メインが有効（`reg_valid=1`）な状態で `out_ready=0` に落とし、1 ワード入力して `skid_valid=1` となることを確認。その次のサイクルで `in_ready=0` となること。
  3. **Random Backpressure & Stall**: `in_valid` と `out_ready` を PRBS / 乱数でトグルさせ、10,000 トランザクションにおいてデータの欠落、重複、順序逆転が一切ないことを Scoreboard で確認。
  4. **組み合わせパス検査**: テストベンチから `in_ready` が `out_ready` の変化と同一時刻（#0）に変化しないことをアサーション検証。
- **実行コマンド**:
  ```bash
  ./sim/run.sh am_skid
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- `valid` および `ready` の組み合わせパスが完全に遮断され、かつ毎サイクル 1 トランザクションを遅延なく中継できること。
- `sim/run.sh am_skid` が PASS すること。
- `tools/arith-lint.py` で算術演算子違反 0 件であること。
- R1 レビュー APPROVE 獲得。

---

## 完了記録（2026-10-26）

1. **RTL 実装**:
   - `rtl/library/bus/am_skid.v`: ゼロバブル 2 エントリ（メイン/スキッド）レジスタスライス。Forward/Reverse 双方の FF 絶縁を達成。
   - `spec/library/bus/am_skid.md`: 仕様書作成。
   - `sim/tb/am_skid_tb.v`: 単体テストベンチ作成。
2. **検証結果**:
   - `sim/run.sh am_skid`: **PASS** (0 s)
   - `python3 tools/arith-lint.py`: **0 operators outside rtl/library/arith (PASS)**
   - `verilator --lint-only -Wall`: 警告 0 件。
3. **敵対的レビュー（R1 判定）**:
   - **APPROVE**（`adversarial_review_ws001_p035_skid.md`）。組み合わせパスの完全遮断、ゼロバブルスループット、背圧スキッド保持、Guardrails 完全準拠を承認。
