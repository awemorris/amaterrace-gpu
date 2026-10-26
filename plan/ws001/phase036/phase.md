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

## 検証基準（受け入れ条件）

- Vivado 合成において `RAMB18E1` / `RAMB36E1` プリミティブへ推論され、LUTRAM の消費がゼロになること。
- データの順序逆転や化けが一切なく、クロック比によらず安定動作すること。
