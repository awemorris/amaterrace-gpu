<!-- awesome-plan project=amaterrace-gpu record=ws001-p038 -->

# Phase 038: DC 2048 ワード BRAM AFIFO & 32 ライン DMA 統合（2 サイクル制限撤廃）

- **親**: [WS001](../ws.md)
- **状態**: `completed`
- **依存**: [ws001-p036](../phase036/phase.md)
- **優先度**: Critical (720p/1080p スキャンアウトアンダーフロー脆弱性の解消)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/dc/` において、`atg_dc.v` のピクセル AFIFO が 512 ワード（1080p でわずか $3.4\mu\text{s}$ で枯渇）しかなく、`atg_dc_dma.v` が 8 ライン（256B）バッファで「2 サイクルに 1 回しか要求を出せない」直列制限（`!req_valid` 条件によるバブル）によりアンダーフローが発生する病理を解消する。
Phase 036 の `am_afifo_bram.v` を導入してピクセル AFIFO を 2048 ワード（8 KiB、RAMB36E1 2 個）に拡張し、DMA を毎サイクル連続リクエスト発行（1 req/cycle）可能な 32 ラインバッファへ再設計する。

## 範囲・作業内容

1. **`atg_dc.v` ピクセル AFIFO の BRAM 化拡張**:
   - `am_afifo` を Phase 036 の `am_afifo_bram`（`W=32`, `DEPTH_LOG2=11`: 2048 ワード）へ置換。
   - 1080p スキャンアウト時に $13.8\ \mu\text{s}$（100 MHz gclk で約 1380 サイクル）のバッファマージンを確保。
2. **`atg_dc_dma.v` の連続バースト要求化**:
   - ラインバッファを 32 エントリ（`LFIFO_LOG2 = 5`: 1〜2 KiB）へ拡張。
   - `!req_valid` 直列化制限を撤廃し、`take || !req_valid` で毎サイクル連続してリード要求を発行するパイプライン制御へ改修。
3. **単体・回帰検証**:
   - `sim/tb/atg_dc_tb.v` による 1080p スキャンアウトシミュレーション検証。
   - `sim/run.sh atg_dc` PASS。
   - `tools/arith-lint.py` 違反 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc_dma.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/dc/atg_dc.md`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/dc/atg_dc_dma.md`
- 更新・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_dc_tb.v`

### 2. モジュールインターフェース設計

#### `atg_dc.v`
- パラメータ `FIFO_LOG2` を既定値 `9`（512）から `11`（2048）に変更。
- `am_afifo` インスタンス `pixels` を `am_afifo_bram` に置き換える。
```verilog
am_afifo_bram #(.W(32), .DEPTH_LOG2(FIFO_LOG2)) pixels (
    .w_clk(clk),
    .w_rst_n(g_rst_n),
    .w_valid(px_w_valid),
    .w_ready(px_w_ready),
    .w_data(px_w_data),
    .r_clk(pclk),
    .r_rst_n(p_rst_n),
    .r_valid(px_r_valid),
    .r_ready(px_r_ready),
    .r_data(px_r_data),
    .r_count(px_fifo_count)  // Phase 039 用の残量
);
```

#### `atg_dc_dma.v`
- パラメータ `LFIFO_LOG2` を `3`（8 ライン）から `5`（32 ライン）へ拡張。
- インターフェース信号は既存と完全互換。

### 3. RTL アーキテクチャとボトルネック解消詳細
#### (1) `atg_dc_dma.v` の 2 サイクル制約の完全撤廃
旧コード:
```verilog
if (take)
    req_valid <= 1'b0;
...
else if (!abort && enable && rq_active && !req_valid && room) begin
    req_valid <= 1'b1;
    req_line <= rq_cur;
    ...
```
この構造では、`req_valid` が立ったサイクルでは `!req_valid` が偽となるため、受領（`take`）されても次サイクルはアイドル（バブル）になる。

**改善後の発行ロジック**:
```verilog
wire req_fire = req_valid && req_ready;
wire can_issue = !abort && enable && rq_active && room;

always @(posedge clk) begin
    if (!rst_n) begin
        req_valid <= 1'b0;
        ...
    end else begin
        ...
        if (can_issue && (req_fire || !req_valid)) begin
            req_valid <= 1'b1;
            req_line  <= rq_cur;
            tag_q     <= epoch;
            // アドレス・行カウンタの即時更新
            if (rq_k == f_nl_last) begin
                rq_k        <= 16'd0;
                rq_row      <= rq_row_inc;
                rq_row_line <= rq_next_row;
                rq_cur      <= rq_next_row;
                if (rq_row == f_h_last)
                    rq_active <= 1'b0;
            end else begin
                rq_k   <= rq_k_inc;
                rq_cur <= rq_cur_inc;
            end
        end else if (req_fire) begin
            req_valid <= 1'b0;
        end
    end
end
```
この制御により、`req_ready=1` であれば毎サイクル連続（1 req/cycle）して AMB リード要求をストリーム送出できる。

#### (2) インフライトカウンタおよびライン FIFO 幅の調整
- `LFIFO_LOG2 = 5`（32 エントリ）に伴い、`inflight`、`lcount`、`used` のビット幅を `LFIFO_LOG2 + 1 = 6` ビットに変更。
- 加減算器（`a_used`, `a_infl`, `s_infl`）のパラメータ `.W(6)` を追従させる。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: カウンタ計算（`a_row`, `a_k`, `a_cur`, `a_infl` 等）は必ず `am_add` / `am_sub` を使用すること。生 `+`, `-` は禁止。
- **Verilog-2005 準拠**: `timescale` および `default_nettype` 規則の完全遵守。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_dc_tb.v`
- **検証項目**:
  1. **連続バースト発行検証**: DMA が開始された後、`req_ready=1` の条件下で毎サイクル連続して 32 本のリクエストが隙間なく送出されること（0 バブル）。
  2. **1080p フル画面スキャンアウト**: 1920x1080 ピクセルを連続スキャンアウトさせ、ピクセル FIFO が枯渇しないこと。
  3. **アンダーフロー耐性試験**: AMB バス側からのリード応答に 40〜60 サイクルのランダムレイテンシを印加しても、2048 ワード BRAM AFIFO のバッファリングによりアンダーフローが発生しないこと。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_dc
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- ピクセル AFIFO が `am_afifo_bram`（2048 ワード、`FIFO_LOG2=11`）により BRAM（RAMB36E1）に推論され、バッファマージンが 13.8 us へ 4 倍拡張されること。
- `atg_dc_dma.v` 32 ラインバッファ化および 0 バブル毎サイクル連続リクエスト発行（1 req/cycle）。
- `sim/run.sh atg_dc`: PASS（5 s、scanout, afifo_bram アンダーフロー完全フリー検証 PASS）。
- `sim/run.sh atg_dc_dma`: PASS（0 s、burst: 34 連続ライン 0 バブル発行 PASS）。
- `sim/run.sh atg_top`: PASS（33 s、システム統合 PASS）。
- `python3 tools/arith-lint.py --top atg_dc` & `--top atg_dc_dma`: 違反 0 件。
- Verilator lint: 警告 0 件。
- コミット: `6310a94`
