<!-- awesome-plan project=amaterrace-gpu record=ws001-p036 -->

# Phase 036: BRAM 推論可能非同期 FIFO（am_afifo_bram.v）実装

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p035](../phase035/phase.md)
- **優先度**: Critical (1,000+ LUT の浪費完全排除 & 大容量 CDC FIFO の BRAM 推論化)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/library/bus/am_afifo.v` が非同期読み出し（`assign r_data = mem[...]`）を行っているために FPGA の Block RAM（RAMB36E1: クロック同期リード必須）に推論できず、深い FIFO を作ろうとすると 1,000 個以上の LUT を消費して 200 MHz の配置配線タイミングを破綻させている最大トラップを解消する。
読み出し側に 2 エントリの出力 Skid Buffer を統合し、BRAM の同期リードレイテンシ（1 サイクル）を完全に隠蔽した真の FWFT BRAM 非同期 FIFO `rtl/library/bus/am_afifo_bram.v` を実装する。

## 範囲・作業内容

1. **`am_afifo_bram.v` の設計・実装**:
   - `rtl/library/bus/am_afifo_bram.v` を新設。
   - メモリアレイを Xilinx Vivado で `RAMB18E1` / `RAMB36E1` に確実に推論される同期リード構造で記述（`always @(posedge r_clk) ram_rdata <= mem[r_addr];`）。
   - 読み出しクロックドメインに Phase 035 の Skid Buffer 機構を直結し、ゼロサイクル FWFT（First-Word Fall-Through）出力を実現。
   - グレイコードポインタ同期、`ASYNC_REG="TRUE"` 付与。
2. **単体・ストレステスト**:
   - `sim/tb/am_afifo_bram_tb.v` を作成し、非同期クロック比（高速 $\to$ 低速、低速 $\to$ 高速、ジッター）、オーバーフロー/アンダーフロー境界、連続満杯/空遷移の完全等価性検証。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` 違反 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/library/bus/am_afifo_bram.v`
- 新設: `/home/awe/amaterrace-gpu/spec/library/bus/am_afifo_bram.md`
- 新設: `/home/awe/amaterrace-gpu/sim/tb/am_afifo_bram_tb.v`
- 更新: `/home/awe/amaterrace-gpu/tools/lint.sh`（RTL_SRCS / LIB_SRCS に追加）
- 更新: `/home/awe/amaterrace-gpu/sim/run.sh`（TB リストに追加）

### 2. モジュールインターフェース（Exact Port List）

```verilog
`timescale 1ns / 1ps
`default_nettype none

module am_afifo_bram #(
    parameter W = 32,
    parameter DEPTH_LOG2 = 11  // 既定値 2048 ワード (8 KiB, RAMB36E1 x 2 推論)
)(
    // 書き込みドメイン（wclk）
    input  wire         w_clk,
    input  wire         w_rst_n,
    input  wire         w_valid,
    output wire         w_ready,
    input  wire [W-1:0] w_data,

    // 読み出しドメイン（rclk）
    input  wire         r_clk,
    input  wire         r_rst_n,
    output wire         r_valid,
    input  wire         r_ready,
    output wire [W-1:0] r_data,

    // ウォーターマーク監視（rclk ドメイン：Phase 039 Urgent/Panic 用）
    output wire [DEPTH_LOG2:0] r_count
);
```

### 3. RTL アーキテクチャと BRAM 推論構造
BRAM（RAMB18E1 / RAMB36E1）を Vivado に確実に推論させるための黄金律:
1. **メモリアレイ定義**:
   ```verilog
   (* ram_style = "block" *) reg [W-1:0] mem [0:(1 << DEPTH_LOG2) - 1];
   ```
2. **同期リード（クロックエッジでの読み出し）**:
   非同期リード `assign r_data = mem[...]` は **厳禁**。必ず以下のように同期レジスタを介す。
   ```verilog
   reg [W-1:0] ram_rdata;
   always @(posedge r_clk) begin
       if (ram_ren) begin
           ram_rdata <= mem[r_bin[DEPTH_LOG2-1:0]];
       end
   end
   ```
3. **BRAM リードレイテンシ（1 cycle）の FWFT 隠蔽（スキッドバッファ統合）**:
   BRAM はアドレスを与えてからデータが出るまでに 1 サイクルを要する。
   下流インターフェース（`r_valid`, `r_ready`, `r_data`）が FWFT（First-Word Fall-Through）動作するために、読み出し側に Skid Buffer（または 2 段 FIFO）を置く。
   - BRAM 側から見てスキッドバッファに空きがあり、かつ BRAM 内に未読データが存在する場合、`ram_ren = 1` として BRAM から先読みフェッチする。
   - `ram_rvalid` を 1 サイクル遅延させてスキッドバッファの `in_valid` に供給し、`ram_rdata` を `in_data` に供給する。
   - スキッドバッファの出力が外部の `r_valid`, `r_data` となり、外部から `r_ready` で消費される。

#### ポインタ管理と演算子制約
- ポインタ幅: `localparam P = DEPTH_LOG2 + 1;`
- ポインタ加算は必ず `am_add` を使用する（`+ 1` や `+ ci` は厳禁）:
  ```verilog
  wire [P-1:0] w_bin_next;
  wire unused_w_co;
  am_add #(.W(P)) u_w_bin (
      .a(w_bin), .b({P{1'b0}}), .ci(w_push), .s(w_bin_next), .co(unused_w_co)
  );

  wire [P-1:0] r_bin_next;
  wire unused_r_co;
  am_add #(.W(P)) u_r_bin (
      .a(r_bin), .b({P{1'b0}}), .ci(ram_ren), .s(r_bin_next), .co(unused_r_co)
  );
  ```
- グレイコード変換および 2 段 FF 同期 (`ASYNC_REG = "TRUE"`) は `am_afifo.v` の実績ある実装を継承。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: `w_bin` や `r_bin` の更新、ウォーターマーク計算（残量減算）はすべて `rtl/library/arith/`（`am_add`, `am_sub`）を用いること。
- **リセット規約**: `w_rst_n` と `r_rst_n` は非同期クロックドメインごとに独立。両ドメインのリセット同期化を正しく処理すること。
- **BRAM リセット時の注意**: Xilinx BRAM の内部メモリ配列自体はリセットでクリアされない（ポインタクリアのみ）。

### 5. テストベンチ設計・検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/am_afifo_bram_tb.v`
- **検証項目**:
  1. **Clock Ratio Sweep**:
     - w_clk: 200 MHz, r_clk: 148.5 MHz（Display Controller 実動作比）
     - w_clk: 50 MHz, r_clk: 200 MHz
     - w_clk: 200 MHz, r_clk: 50 MHz
     - 乱数ジッター付きクロック
  2. **10,000 ワード連続バースト**:
     書き込み側から PRBS 乱数データを連続投入し、読み出し側で間欠/連続/ランダムストールさせながら受信データが 100% 一致・順序保持されることをアサーション検証。
  3. **Full / Empty フラグ反復検証**:
     境界値（空 $\to$ 1 ワード $\to$ 空、満杯 $\to$ 1 ワード抜け $\to$ 満杯）でデータ落ちや二重読みが発生しないこと。
- **実行コマンド**:
  ```bash
  ./sim/run.sh am_afifo_bram
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- Vivado 合成において `RAMB18E1` / `RAMB36E1` プリミティブへ推論され、LUTRAM の消費がゼロになること。
- データの順序逆転や化けが一切なく、クロック比によらず安定動作すること。
- `sim/run.sh am_afifo_bram` が PASS すること。
- `tools/arith-lint.py` で違反 0 件。
- R1 レビュー APPROVE 獲得。
