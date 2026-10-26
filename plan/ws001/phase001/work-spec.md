# ws001-p001 作業仕様書：ファイル操作・リファクタリング詳細一覧

- **対象フェーズ**: `ws001-p001` RTL の階層（`bsp`・`library`・`gpu`）と FP の演算器の重複の整理
- **基本原則**:
  1. **機能・サイクル不変**: すべてのモジュールの入出力ビットおよびサイクル遅延（`LAT`）は現状と 1 bit・1 cycle たりとも変えない。
  2. **全幅 `DSP48E1` カスケード (`SYNTH_KINTEX7`)**: [`am_mul.v`](rtl/common/am_mul.v) は `` `ifdef SYNTH_KINTEX7 `` で最小幅（`8×8`）から最大幅（`24×59`, `42×42`）まで全て `DSP48E1` プリミティブ直打ち＋`PCOUT -> PCIN` カスケードで実装し、fabric 加算器や `*` 推論を一切使わない。
  3. **BSP の切替 (`SYNTH_KINTEX7`)**: `rtl/bsp/xilinx7/` と `rtl/bsp/generic/` も `` `ifdef SYNTH_KINTEX7 `` で切り替え、`find rtl -name '*.v'` による一括コンパイル（iverilog / Verilator / Vivado）をそのまま維持する。
  4. **2 段階マイルストーン**:
     - **Step A（階層移動＋FP 統合＋`bus/` 算術整理）**: `SYNTH_KINTEX7` なしで階層移動・`am_fp_*` 統合・`arith-lint 0`・等価検証（確かめ 1）・日常回帰（確かめ 3）を完全 PASS させる。
     - **Step B（`am_mul` の `DSP48E1` カスケード化＋板ビルド）**: `am_mul.v` に `SYNTH_KINTEX7` 分岐を追加し、Unisim 単体等価試験（確かめ 2）と KC705 板ビルド（確かめ 4）を完了する。

---

## 1. ファイル操作一覧（移動・新規作成・削除・コピー）

### 1.1 `rtl/common/` 廃止に伴うファイル移動 (`git mv`) — 20 ファイル

#### (A) `rtl/library/arith/` への移動（7 ファイル）
| 操作 | 移動元 (`rtl/common/`) | 移動先 (`rtl/library/arith/`) | 内容・変更有無 |
| :---: | :--- | :--- | :--- |
| `git mv` | [`rtl/common/am_add.v`](rtl/common/am_add.v) | `rtl/library/arith/am_add.v` | ヘッダコメントのパス記述更新のみ |
| `git mv` | [`rtl/common/am_sub.v`](rtl/common/am_sub.v) | `rtl/library/arith/am_sub.v` | ヘッダコメントのパス記述更新のみ |
| `git mv` | [`rtl/common/am_addsub.v`](rtl/common/am_addsub.v) | `rtl/library/arith/am_addsub.v` | ヘッダコメントのパス記述更新のみ |
| `git mv` | [`rtl/common/am_shift.v`](rtl/common/am_shift.v) | `rtl/library/arith/am_shift.v` | ヘッダコメントのパス記述更新のみ |
| `git mv` | [`rtl/common/am_div.v`](rtl/common/am_div.v) | `rtl/library/arith/am_div.v` | ヘッダコメントのパス記述更新のみ |
| `git mv` | [`rtl/common/am_msb.v`](rtl/common/am_msb.v) | `rtl/library/arith/am_msb.v` | ヘッダコメントのパス記述更新のみ |
| `git mv` | [`rtl/common/am_mul.v`](rtl/common/am_mul.v) | `rtl/library/arith/am_mul.v` | **Step B で `` `ifdef SYNTH_KINTEX7 `` の `DSP48E1` カスケード実装を追加**（§3.5） |

#### (B) `rtl/library/bus/` への移動（13 ファイル）
| 操作 | 移動元 (`rtl/common/`) | 移動先 (`rtl/library/bus/`) | 内容・変更有無 |
| :---: | :--- | :--- | :--- |
| `git mv` | [`rtl/common/am_afifo.v`](rtl/common/am_afifo.v) | `rtl/library/bus/am_afifo.v` | **生 `+` 2 箇所を `am_add` に置換**（§3.2） |
| `git mv` | [`rtl/common/am_amb_mux.v`](rtl/common/am_amb_mux.v) | `rtl/library/bus/am_amb_mux.v` | コメント内の `spec/` パス更新のみ |
| `git mv` | [`rtl/common/am_amb_to_rt.v`](rtl/common/am_amb_to_rt.v) | `rtl/library/bus/am_amb_to_rt.v` | コメント内の `spec/` パス更新のみ |
| `git mv` | [`rtl/common/am_arb3.v`](rtl/common/am_arb3.v) | `rtl/library/bus/am_arb3.v` | コメント内の `spec/` パス更新のみ |
| `git mv` | [`rtl/common/am_axi_cdc.v`](rtl/common/am_axi_cdc.v) | `rtl/library/bus/am_axi_cdc.v` | コメント内の `spec/` パス更新のみ |
| `git mv` | [`rtl/common/am_axi_gate.v`](rtl/common/am_axi_gate.v) | `rtl/library/bus/am_axi_gate.v` | コメント内の `spec/` パス更新のみ（既に `am_add` 使用済み） |
| `git mv` | [`rtl/common/am_axi_idtrack.v`](rtl/common/am_axi_idtrack.v) | `rtl/library/bus/am_axi_idtrack.v` | コメント内の `spec/` パス更新のみ（既に `am_addsub` 使用済み） |
| `git mv` | [`rtl/common/am_axi_master.v`](rtl/common/am_axi_master.v) | `rtl/library/bus/am_axi_master.v` | **生 `+` 1 箇所を `am_add` に置換**（§3.2） |
| `git mv` | [`rtl/common/am_axi_regs.v`](rtl/common/am_axi_regs.v) | `rtl/library/bus/am_axi_regs.v` | **生 `-` 1 箇所を `am_sub` に置換**（§3.2） |
| `git mv` | [`rtl/common/am_axi_split.v`](rtl/common/am_axi_split.v) | `rtl/library/bus/am_axi_split.v` | コメント内の `spec/` パス更新のみ（既に `am_sub` 使用済み） |
| `git mv` | [`rtl/common/am_fifo.v`](rtl/common/am_fifo.v) | `rtl/library/bus/am_fifo.v` | **生 `-` 1 箇所・`+` 2 箇所を `am_sub`/`am_add` に置換**（§3.2） |
| `git mv` | [`rtl/common/am_fifo_key.v`](rtl/common/am_fifo_key.v) | `rtl/library/bus/am_fifo_key.v` | **生 `-` 1 箇所・`+` 2 箇所を `am_sub`/`am_add` に置換**（§3.2） |
| `git mv` | [`rtl/common/am_sync.v`](rtl/common/am_sync.v) | `rtl/library/bus/am_sync.v` | 変更なし |

---

### 1.2 `rtl/bsp/`（`xilinx7` / `generic`）の移動・新規作成

| 操作 | 元ファイル | 新パス | 内容 |
| :---: | :--- | :--- | :--- |
| `git mv` | [`rtl/common/am_jtag_regs.v`](rtl/common/am_jtag_regs.v) | `rtl/bsp/generic/am_jtag_regs.v` | JTAG 72-bit USER2 レジスタブリッジ本体（`tck` ↔ `clk` CDC + GHCI マスタ FSM） |
| 新規作成 | （[`boards/kc705/lib/atg_kc705_jtag.v`](boards/kc705/lib/atg_kc705_jtag.v) から抽出） | `rtl/bsp/xilinx7/am_jtag_bscan.v` | `` `ifdef SYNTH_KINTEX7 `` で有効化される `BSCANE2 #(.JTAG_CHAIN(2)) bscan` + `BUFG tck_bufg` の Xilinx 7 シリーズ専用ラッパ（§3.1） |
| 新規作成 | （[`sim/models/xilinx/BSCANE2.v`](sim/models/xilinx/BSCANE2.v) 連携） | `rtl/bsp/generic/am_jtag_bscan.v` | `` `ifndef SYNTH_KINTEX7 `` で有効化される generic / sim 用ラッパ（§3.1） |

---

### 1.3 `rtl/library/fp/` の移動・統合・削除一覧（新設 11 ファイル、削除 14 ファイル）

| 新パス (`rtl/library/fp/`) | ベース（移動・統合元） | 統合されて削除 (`git rm`) される旧ファイル（計 14 個：su 9・rx 2・tu 1・fmt 2） |
| :--- | :--- | :--- |
| `rtl/library/fp/am_fp_add.v` | [`rtl/gpu/rx/atg_rx_fadd.v`](rtl/gpu/rx/atg_rx_fadd.v) (`LAT=4`) + [`rtl/gpu/su/atg_su_fadd.v`](rtl/gpu/su/atg_su_fadd.v) (`LAT=0`) | `rtl/gpu/rx/atg_rx_fadd.v`<br>`rtl/gpu/su/atg_su_fadd.v` |
| `rtl/library/fp/am_fp_mul.v` | [`rtl/gpu/rx/atg_rx_fmul.v`](rtl/gpu/rx/atg_rx_fmul.v) (`LAT=4`, `LAT=0` 追加) | `rtl/gpu/rx/atg_rx_fmul.v` |
| `rtl/library/fp/am_fp_fma_p.v` | [`rtl/gpu/su/atg_su_ffma_p.v`](rtl/gpu/su/atg_su_ffma_p.v) (`LAT=0`) | `rtl/gpu/su/atg_su_ffma_p.v` |
| `rtl/library/fp/am_fp_fma.v` | [`rtl/gpu/tu/atg_tu_fma.v`](rtl/gpu/tu/atg_tu_fma.v) (`LAT=10`) + [`rtl/gpu/su/atg_su_ffma.v`](rtl/gpu/su/atg_su_ffma.v) (`LAT=0`) | `rtl/gpu/tu/atg_tu_fma.v`<br>`rtl/gpu/su/atg_su_ffma.v` |
| `rtl/library/fp/am_fp_rnd.v` | [`rtl/gpu/su/atg_su_rnd.v`](rtl/gpu/su/atg_su_rnd.v) (`LAT=0`) | `rtl/gpu/su/atg_su_rnd.v` |
| `rtl/library/fp/am_fp_rint.v` | [`rtl/gpu/su/atg_su_rint.v`](rtl/gpu/su/atg_su_rint.v) (`LAT=0`) | `rtl/gpu/su/atg_su_rint.v` |
| `rtl/library/fp/am_fp_i2f.v` | [`rtl/gpu/su/atg_su_i2f.v`](rtl/gpu/su/atg_su_i2f.v) (`LAT=0`) | `rtl/gpu/su/atg_su_i2f.v` |
| `rtl/library/fp/am_fp_f2i.v` | [`rtl/gpu/su/atg_su_f2i.v`](rtl/gpu/su/atg_su_f2i.v) (`LAT=0`) | `rtl/gpu/su/atg_su_f2i.v` |
| `rtl/library/fp/am_fp_h2f.v` | [`rtl/gpu/su/atg_su_h2f.v`](rtl/gpu/su/atg_su_h2f.v) (`DENORM=0`) + [`rtl/gpu/fmt/atg_fmt_h2f.v`](rtl/gpu/fmt/atg_fmt_h2f.v) (`DENORM=1`) | `rtl/gpu/su/atg_su_h2f.v`<br>`rtl/gpu/fmt/atg_fmt_h2f.v` |
| `rtl/library/fp/am_fp_f2h.v` | [`rtl/gpu/fmt/atg_fmt_f2h.v`](rtl/gpu/fmt/atg_fmt_f2h.v) (`LAT=0`) | `rtl/gpu/fmt/atg_fmt_f2h.v` |
| `rtl/library/fp/am_fp_hrnd.v` | [`rtl/gpu/su/atg_su_hrnd.v`](rtl/gpu/su/atg_su_hrnd.v) (`LAT=0`) | `rtl/gpu/su/atg_su_hrnd.v` |

---

### 1.4 `spec/` の移動・統合・新規作成・削除一覧

1. **`spec/common/` 廃止と移動 (`git mv`)**:
   - `spec/common/am_{add,sub,addsub,shift,div,msb}.md` → `spec/library/arith/am_{add,sub,addsub,shift,div,msb}.md`
   - `spec/library/arith/am_mul.md`（新規作成：汎用版と `SYNTH_KINTEX7` `DSP48E1` カスケード版の仕様書）
   - `spec/common/am_{afifo,amb_mux,amb_to_rt,arb3,axi_cdc,axi_gate,axi_idtrack,axi_master,axi_regs,axi_split,fifo,fifo_key,sync}.md` → `spec/library/bus/`
   - `spec/common/am_jtag_regs.md` → `spec/bsp/generic/am_jtag_regs.md`
   - `spec/bsp/xilinx7/am_jtag_bscan.md`, `spec/bsp/generic/am_jtag_bscan.md`（新規作成）
2. **`spec/library/fp/` の作成と旧 spec の削除**:
   - `spec/library/fp/am_fp_{add,mul,fma_p,fma,rnd,rint,i2f,f2i,h2f,f2h,hrnd}.md` を作成（旧 `spec/gpu/su/atg_su_{fadd,ffma,ffma_p,rnd,rint,i2f,f2i,h2f,hrnd}.md`, `spec/gpu/rx/atg_rx_{fadd,fmul}.md`, `spec/gpu/tu/atg_tu_fma.md`, `spec/gpu/fmt/atg_fmt_{h2f,f2h}.md` を統合して `git rm`）。

---

## 2. 各ファイルのリファクタリング・実装詳細

### 2.1 BSP（JTAG / `BSCANE2`）のリファクタリング詳細（範囲 1）

- **`rtl/bsp/generic/am_jtag_regs.v`**:
  - 旧 [`rtl/common/am_jtag_regs.v`](rtl/common/am_jtag_regs.v) をそのまま移動。
- **`rtl/bsp/xilinx7/am_jtag_bscan.v`** と **`rtl/bsp/generic/am_jtag_bscan.v`**:
  - `find rtl -name '*.v'` で両方コンパイルされても衝突しないよう、以下のように `` `ifdef SYNTH_KINTEX7 `` でガードする：
    - `rtl/bsp/xilinx7/am_jtag_bscan.v`: `` `ifdef SYNTH_KINTEX7 `` 内で `module am_jtag_bscan #(parameter JTAG_CHAIN = 2) (output wire tck, output wire sel, output wire capture, output wire shift, output wire update, output wire tdi, input wire tdo);` を定義し、`BSCANE2 #(.JTAG_CHAIN(JTAG_CHAIN)) bscan (...)` と `BUFG tck_bufg (.I(tck_raw), .O(tck))` をインスタンス化する。
    - `rtl/bsp/generic/am_jtag_bscan.v`: `` `ifndef SYNTH_KINTEX7 `` 内で同名の `module am_jtag_bscan` を定義。内部に `BSCANE2 #(.JTAG_CHAIN(JTAG_CHAIN)) bscan (...)`（sim 時は [`sim/models/xilinx/BSCANE2.v`](sim/models/xilinx/BSCANE2.v)、lint 時はスタブまたはモデル）を持つ、あるいは `BSCANE2` モデルのシフト・TAP 状態機械を直接内蔵して `bscan.scan` / `bscan.idle` タスクを提供する。
    - ※ [`tools/lint.sh`](tools/lint.sh#L27-L30) の単体モジュール lint ループ（`for f in $srcs; do m=$(basename "$f" .v); run "$m" --top-module "$m"`）はファイル名 = モジュール名を前提としているため、`rtl/bsp/xilinx7/` と `rtl/bsp/generic/` の扱いは以下のいずれかに統一する：
      - **方式 1（推奨・`lint.sh` 完全互換）**: [`tools/lint.sh`](tools/lint.sh#L14)・[`tools/arith-lint.py`](tools/arith-lint.py#L77)・[`sim/run.sh`](sim/run.sh#L59)・[`Makefile`](Makefile#L23) では `SYNTH_KINTEX7` 未定義時は `rtl/bsp/xilinx7/` を除外（または `SYNTH_KINTEX7` 定義時は `rtl/bsp/generic/` を除外）しつつ、各ファイル内にも `` `ifdef SYNTH_KINTEX7 `` / `` `ifndef SYNTH_KINTEX7 `` を入れる。
      - [`boards/kc705/lib/atg_kc705_jtag.v`](boards/kc705/lib/atg_kc705_jtag.v#L21-L52) は `am_jtag_bscan`（または `am_jtag_regs`）を呼び出し、[`sim/tb/atg_kc705_raster_tb.v`](sim/tb/atg_kc705_raster_tb.v#L279) の `dut.jtag.bscan.scan(...)` / `dut.jtag.bscan.idle(...)` 階層パスがそのまま動くようにする。

---

### 2.2 `rtl/library/bus/` 内の生算術演算子（`+` / `-`）のリファクタリング詳細（範囲 1・4）

`rtl/common/` から `rtl/library/bus/` に移動すると、[`tools/arith-lint.py`](tools/arith-lint.py) の検査対象に入ります。以下の **5 ファイル・計 9 箇所** の生 `+` / `-` を [`am_add`](rtl/common/am_add.v) / [`am_sub`](rtl/common/am_sub.v) に置き換えることで、`rtl/library/bus/` の違反を **0** にします。

1. **[`rtl/library/bus/am_fifo.v`](rtl/common/am_fifo.v#L39-L62)（3 箇所）**:
   - L39: `wire [DEPTH_LOG2:0] used = wp - rp;`
     → `am_sub #(.W(DEPTH_LOG2 + 1)) u_used (.a(wp), .b(rp), .bi(1'b0), .d(used), .bo(unused_bo));`
   - L59, L61: `wp <= wp + 1'b1;`, `rp <= rp + 1'b1;`
     → `am_add #(.W(DEPTH_LOG2 + 1)) u_wp (.a(wp), .b({(DEPTH_LOG2 + 1){1'b0}}), .ci(1'b1), .s(wp_next), .co(unused_wp_co));`（`rp_next` も同様）
2. **[`rtl/library/bus/am_fifo_key.v`](rtl/common/am_fifo_key.v#L49-L85)（3 箇所）**:
   - L49: `wire [DEPTH_LOG2:0] used = wp - rp;` → `am_sub #(.W(DEPTH_LOG2 + 1))` に置換
   - L83, L85: `wp <= wp + 1'b1;`, `rp <= rp + 1'b1;` → `am_add #(.W(DEPTH_LOG2 + 1))` に置換
3. **[`rtl/library/bus/am_afifo.v`](rtl/common/am_afifo.v#L61-L90)（2 箇所）**:
   - L61: `wire [P-1:0] w_bin_next = w_bin + {{(P - 1){1'b0}}, w_push};`
     → `am_add #(.W(P)) u_w_bin (.a(w_bin), .b({P{1'b0}}), .ci(w_push), .s(w_bin_next), .co(unused_w_co));`
   - L90: `wire [P-1:0] r_bin_next = r_bin + {{(P - 1){1'b0}}, r_pop};`
     → `am_add #(.W(P)) u_r_bin (.a(r_bin), .b({P{1'b0}}), .ci(r_pop), .s(r_bin_next), .co(unused_r_co));`
4. **[`rtl/library/bus/am_axi_master.v`](rtl/common/am_axi_master.v#L288)（1 箇所）**:
   - L288: `w_beat <= w_beat + 8'd1;`
     → `am_add #(.W(8)) u_w_beat (.a(w_beat), .b(8'd1), .ci(1'b0), .s(w_beat_n), .co(unused_wb_co));` を使い `w_beat <= w_beat_n;` に置換
5. **[`rtl/library/bus/am_axi_regs.v`](rtl/common/am_axi_regs.v#L163)（1 箇所）**:
   - L163: `r_left <= r_left - 1'b1;`
     → `am_sub #(.W(LEN_W)) u_r_left (.a(r_left), .b({LEN_W{1'b0}}), .bi(1'b1), .d(r_left_n), .bo(unused_rl_bo));` を使い `r_left <= r_left_n;` に置換

---

### 2.3 `rtl/library/fp/` 各モジュールのリファクタリング仕様（範囲 2）

すべての `am_fp_*.v` は `parameter LAT = ...` と `localparam LAT_OUT = LAT`（および `localparam LAT`）を持ちます。

#### ① `rtl/library/fp/am_fp_add.v`
- **統合元**: [`rtl/gpu/su/atg_su_fadd.v`](rtl/gpu/su/atg_su_fadd.v) (`LAT=0`) + [`rtl/gpu/rx/atg_rx_fadd.v`](rtl/gpu/rx/atg_rx_fadd.v) (`LAT=4`)
- **シグネチャ**:
  ```verilog
  module am_fp_add #(
      parameter LAT = 4
  ) (
      input wire clk,
      input wire rst_n,
      input wire i_valid,
      input wire [31:0] i_a,
      input wire [31:0] i_b,
      input wire i_sub,
      output wire o_valid,
      output wire [31:0] o_r
  );
  ```
- **内部構造**:
  - Stage 1（入力展開・指数差 `de`・オペランド大小比較・特殊値フラグ）
  - Stage 2（右シフトアライメント `am_shift`・スティッキーマスク・28-bit `am_addsub`・`am_msb`）
  - Stage 3（キャリー時右シフト / キャンセル時左シフト正規化 `am_shift`・指数更新 `am_addsub`）
  - Stage 4（RNE 丸め加算 `am_add`・オーバーフロー/アンダーフロー/特殊値選択）
  - `generate if (LAT == 0)` では Stage 1〜4 間のレジスタをバイパスして直結（`o_valid = i_valid`）、`else`（`LAT == 4`）では [`atg_rx_fadd.v`](rtl/gpu/rx/atg_rx_fadd.v) と同一の 4 段 FF を挿入。

#### ② `rtl/library/fp/am_fp_mul.v`
- **統合元**: [`rtl/gpu/rx/atg_rx_fmul.v`](rtl/gpu/rx/atg_rx_fmul.v) (`LAT=4`)
- **シグネチャ**:
  ```verilog
  module am_fp_mul #(
      parameter LAT = 4
  ) (
      input wire clk,
      input wire rst_n,
      input wire i_valid,
      input wire [31:0] i_a,
      input wire [31:0] i_b,
      output wire o_valid,
      output wire [31:0] o_r
  );
  ```
- **内部構造**:
  - Stage 1（展開・指数和 `ea + eb - 127`）→ Stage 2（`am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(0))`）→ Stage 3（正規化・丸めビット抽出）→ Stage 4（RNE 丸め加算・特殊値選択）。
  - `LAT == 0` 時は段間 FF をバイパス、`LAT == 4` 時は旧 `atg_rx_fmul` と同一の 4 段 FF。

#### ③ `rtl/library/fp/am_fp_fma_p.v`
- **統合元**: [`rtl/gpu/su/atg_su_ffma_p.v`](rtl/gpu/su/atg_su_ffma_p.v) (`LAT=0`)
- **シグネチャ**:
  ```verilog
  module am_fp_fma_p #(
      parameter LAT = 0
  ) (
      input wire [31:0] a0,
      input wire [31:0] b0,
      input wire [31:0] c0,
      input wire [2:0] rm,
      input wire noc,
      input wire [47:0] p,
      output wire [31:0] r
  );
  ```
- **内部構造**: 旧 [`atg_su_ffma_p.v`](rtl/gpu/su/atg_su_ffma_p.v) のロジックそのまま（内部の `atg_su_rnd` 呼び出しを `am_fp_rnd #(.LAT(0))` に変更）。

#### ④ `rtl/library/fp/am_fp_fma.v`
- **統合元**: [`rtl/gpu/tu/atg_tu_fma.v`](rtl/gpu/tu/atg_tu_fma.v) (`LAT=10`) + [`rtl/gpu/su/atg_su_ffma.v`](rtl/gpu/su/atg_su_ffma.v) (`LAT=0`)
- **シグネチャ**:
  ```verilog
  module am_fp_fma #(
      parameter TW = 16,
      parameter LAT = 10
  ) (
      input wire clk,
      input wire rst_n,
      input wire i_vld,
      input wire [TW-1:0] i_tag,
      input wire [31:0] i_a,
      input wire [31:0] i_b,
      output wire c_vld,
      output wire [TW-1:0] c_tag,
      input wire [31:0] c_val,
      input wire [2:0] rm,
      input wire noc,
      output wire r_vld,
      output wire [TW-1:0] r_tag,
      output wire [31:0] r_val,
      output wire o_busy
  );
  ```
- **内部構造**:
  - `generate if (LAT == 0)`: `am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(0))` + `am_fp_fma_p #(.LAT(0))` を直結（`c_vld = i_vld`, `c_tag = i_tag`, `r_vld = i_vld`, `r_tag = i_tag`, `o_busy = 1'b0`）。
  - `else` (`LAT == 10`): 旧 [`atg_tu_fma.v`](rtl/gpu/tu/atg_tu_fma.v) の 10 段パイプライン（`am_mul #(.AW(24), .BW(24), .SIGNED(0), .LAT(3))`、Stage 3 で `c_vld / c_tag` により `c_val` を取得）。

#### ⑤ `am_fp_rnd.v` / `am_fp_rint.v` / `am_fp_i2f.v` / `am_fp_f2i.v` / `am_fp_hrnd.v`
- 各々 `parameter LAT = 0` を追加し、旧 `atg_su_{rnd,rint,i2f,f2i,hrnd}.v` を移動・リネーム。`am_fp_i2f.v` 内の `atg_su_rnd` インスタンスは `am_fp_rnd #(.LAT(0))` に変更。

#### ⑥ `rtl/library/fp/am_fp_h2f.v`
- **統合元**: [`rtl/gpu/su/atg_su_h2f.v`](rtl/gpu/su/atg_su_h2f.v) (`DENORM = 0`) + [`rtl/gpu/fmt/atg_fmt_h2f.v`](rtl/gpu/fmt/atg_fmt_h2f.v) (`DENORM = 1`)
- **シグネチャ**:
  ```verilog
  module am_fp_h2f #(
      parameter DENORM = 0,
      parameter LAT = 0
  ) (
      input wire [15:0] h,
      output wire [31:0] f
  );
  ```
- **内部構造**:
  - `generate if (DENORM == 0)`: 旧 `atg_su_h2f`（`he == 0` は `{hs, 31'd0}` に flush、`am_add #(.W(8))` 1 個で `he + 112`）。
  - `else`: 旧 `atg_fmt_h2f`（`he == 0 && hm != 0` のとき 10-bit leading zero カウント + `am_shift` + `am_sub` で正規化）。

#### ⑦ `rtl/library/fp/am_fp_f2h.v`
- **統合元**: [`rtl/gpu/fmt/atg_fmt_f2h.v`](rtl/gpu/fmt/atg_fmt_f2h.v)
- **シグネチャ**:
  ```verilog
  module am_fp_f2h #(
      parameter LAT = 0
  ) (
      input wire [31:0] f,
      output wire [15:0] h
  );
  ```
- **内部構造**: 旧 `atg_fmt_f2h` と完全同一ロジック（RNE、FP16 denormal 生成、NaN `0x7E00`）。SU 側の denormal flush 付き FP16 丸めは展開済み入力の `am_fp_hrnd` を使うため、`am_fp_f2h` に未使用の `DENORM=0` は持たせない。

---

### 2.4 GPU 各ブロックおよびテストベンチの呼び出し書き換え明細（範囲 2）

| ファイルパス | 行番号 | 旧インスタンス記述 | 新インスタンス記述 |
| :--- | :---: | :--- | :--- |
| [`rtl/gpu/su/atg_su_lane.v`](rtl/gpu/su/atg_su_lane.v#L88-L91) | L88-91 | `atg_su_fadd u_qa (.a(...), .b(... ^ 32'h80000000), .r(qa));` (×2) | `am_fp_add #(.LAT(0)) u_qa (.clk(1'b0), .rst_n(1'b1), .i_valid(1'b1), .i_a(...), .i_b(...), .i_sub(1'b1), .o_valid(unused_qa_v), .o_r(qa));` (×2) |
| [`rtl/gpu/su/atg_su_fpu.v`](rtl/gpu/su/atg_su_fpu.v#L156-L202) | L156,158<br>L198,200 | `atg_su_h2f h2f_a0 (...)` (×4)<br>`atg_su_hrnd u_hr0 (...)` (×2) | `am_fp_h2f #(.DENORM(0), .LAT(0)) h2f_a0 (...)` (×4)<br>`am_fp_hrnd #(.LAT(0)) u_hr0 (...)` (×2) |
| [`rtl/gpu/su/atg_su_fpu_op.v`](rtl/gpu/su/atg_su_fpu_op.v#L98-L112) | L98<br>L99<br>L100<br>L101<br>L106<br>L112 | `atg_su_h2f u_h2f (...)`<br>`atg_su_rint u_rint (...)`<br>`atg_su_f2i u_f2i (...)`<br>`atg_su_i2f u_i2f (...)`<br>`atg_su_ffma_p u_fma (...)`<br>`atg_su_rnd u_f2h_f (...)` | `am_fp_h2f #(.DENORM(0), .LAT(0)) u_h2f (...)`<br>`am_fp_rint #(.LAT(0)) u_rint (...)`<br>`am_fp_f2i #(.LAT(0)) u_f2i (...)`<br>`am_fp_i2f #(.LAT(0)) u_i2f (...)`<br>`am_fp_fma_p #(.LAT(0)) u_fma (...)`<br>`am_fp_rnd #(.LAT(0)) u_f2h_f (...)` |
| [`rtl/gpu/su/atg_su_div.v`](rtl/gpu/su/atg_su_div.v#L211) | L211 | `atg_su_rnd u_rnd (...)` | `am_fp_rnd #(.LAT(0)) u_rnd (...)` |
| [`rtl/gpu/su/atg_su_pk.v`](rtl/gpu/su/atg_su_pk.v#L81-L82) | L81-82 | `atg_su_h2f u_up_lo (...)`, `u_up_hi (...)` | `am_fp_h2f #(.DENORM(0), .LAT(0)) u_up_lo (...)`, `u_up_hi (...)` |
| [`rtl/gpu/su/atg_su_pk_half.v`](rtl/gpu/su/atg_su_pk_half.v#L118-L180) | L118-120<br>L179 | `atg_su_h2f u_fa (...)`, `u_fb`, `u_fc`<br>`atg_su_hrnd u_rnd (...)` | `am_fp_h2f #(.DENORM(0), .LAT(0)) u_fa (...)`, `u_fb`, `u_fc`<br>`am_fp_hrnd #(.LAT(0)) u_rnd (...)` |
| [`rtl/gpu/rx/atg_rx_setup.v`](rtl/gpu/rx/atg_rx_setup.v#L163-L166) | L163<br>L165 | `atg_rx_fadd fadd (...)`<br>`atg_rx_fmul fmul (...)` | `am_fp_add #(.LAT(4)) fadd (...)`<br>`am_fp_mul #(.LAT(4)) fmul (...)` |
| [`rtl/gpu/rx/atg_rx_cpoly.v`](rtl/gpu/rx/atg_rx_cpoly.v#L239-L242) | L239<br>L241 | `atg_rx_fadd fadd (...)`<br>`atg_rx_fmul fmul (...)` | `am_fp_add #(.LAT(4)) fadd (...)`<br>`am_fp_mul #(.LAT(4)) fmul (...)` |
| [`rtl/gpu/rx/atg_rx_scan.v`](rtl/gpu/rx/atg_rx_scan.v#L219-L222) | L219<br>L221 | `atg_rx_fmul fmul (...)`<br>`atg_rx_fadd fadd (...)` | `am_fp_mul #(.LAT(4)) fmul (...)`<br>`am_fp_add #(.LAT(4)) fadd (...)` |
| [`rtl/gpu/rx/atg_rx_bary.v`](rtl/gpu/rx/atg_rx_bary.v#L135-L142) | L135<br>L141 | `atg_rx_fmul fmul (...)`<br>`atg_rx_fadd fadd (...)` | `am_fp_mul #(.LAT(4)) fmul (...)`<br>`am_fp_add #(.LAT(4)) fadd (...)` |
| [`rtl/gpu/rop/atg_rop_ms.v`](rtl/gpu/rop/atg_rop_ms.v#L186) | L186 | `atg_rx_fadd fadd (...)` | `am_fp_add #(.LAT(4)) fadd (...)` |
| [`rtl/gpu/rop/atg_rop_fblend.v`](rtl/gpu/rop/atg_rop_fblend.v#L197-L220) | L197<br>L199<br>L219 | `atg_rx_fadd fadd (...)`<br>`atg_rx_fmul fmul (...)`<br>`atg_fmt_f2h u_hf (...)` | `am_fp_add #(.LAT(4)) fadd (...)`<br>`am_fp_mul #(.LAT(4)) fmul (...)`<br>`am_fp_f2h #(.LAT(0)) u_hf (...)` |
| [`rtl/gpu/blt/atg_blt_favg.v`](rtl/gpu/blt/atg_blt_favg.v#L115-L145) | L115-116<br>L142<br>L145 | `atg_fmt_h2f u_ha (...)`, `u_hc`<br>`atg_su_ffma_p u_fma (...)`<br>`atg_fmt_f2h u_fh (...)` | `am_fp_h2f #(.DENORM(1), .LAT(0)) u_ha (...)`, `u_hc`<br>`am_fp_fma_p #(.LAT(0)) u_fma (...)`<br>`am_fp_f2h #(.LAT(0)) u_fh (...)` |
| [`rtl/gpu/tu/atg_tu_fword.v`](rtl/gpu/tu/atg_tu_fword.v#L80) | L80 | `atg_fmt_h2f u_h2f (...)` | `am_fp_h2f #(.DENORM(1), .LAT(0)) u_h2f (...)` |
| [`rtl/gpu/tu/atg_tu_ffilt.v`](rtl/gpu/tu/atg_tu_ffilt.v#L186-L210) | L186<br>L208 | `atg_fmt_h2f u_h2f (...)`<br>`atg_tu_fma #(.TW(9)) u_fma (...)` | `am_fp_h2f #(.DENORM(1), .LAT(0)) u_h2f (...)`<br>`am_fp_fma #(.TW(9), .LAT(10)) u_fma (..., .rm(3'd0), .noc(1'b0), ...)` |
| [`sim/tb/atg_rx_fp_tb.v`](sim/tb/atg_rx_fp_tb.v#L36-L39) | L36, 38 | `atg_rx_fadd add (...)`<br>`atg_rx_fmul mul (...)` | `am_fp_add #(.LAT(4)) add (...)`<br>`am_fp_mul #(.LAT(4)) mul (...)` |
| [`sim/tb/atg_tu_fma_tb.v`](sim/tb/atg_tu_fma_tb.v#L37-L39) | L37 | `atg_tu_fma #(.TW(16)) dut (...)` | `am_fp_fma #(.TW(16), .LAT(10)) dut (..., .rm(3'd0), .noc(1'b0), ...)` |
| [`sim/tb/atg_fmt_tb.v`](sim/tb/atg_fmt_tb.v#L79-L84) | L79<br>L84 | `atg_fmt_f2h u_hf (...)`<br>`atg_fmt_h2f u_h2f (...)` | `am_fp_f2h #(.LAT(0)) u_hf (...)`<br>`am_fp_h2f #(.DENORM(1), .LAT(0)) u_h2f (...)` |

---

### 2.5 `rtl/library/arith/am_mul.v` の全幅 `DSP48E1` カスケード実装詳細（範囲 3）

#### (1) オペランド正規化（符号拡張と A/B 入れ替え）
- `DSP48E1` 1 スライスの乗算器は **A ポート: 25-bit signed (`A[29:0]` に符号拡張)、B ポート: 18-bit signed (`B[17:0]`)** です。
- 入力 `a[AW-1:0]`, `b[BW-1:0]` をまず符号付き信号 `sa[SAW-1:0]`, `sb[SBW-1:0]` に正規化します：
  - `SIGNED != 0`: `SAW = AW`, `SBW = BW`, `sa = a`, `sb = b`
  - `SIGNED == 0`: `SAW = AW + 1`, `SBW = BW + 1`, `sa = {1'b0, a}`, `sb = {1'b0, b}`
- **A/B 自動スワップ（DSP 数最小化）**:
  - 例：`17×32` unsigned (`SAW=18, SBW=33`) や `8×17` unsigned (`SAW=9, SBW=18`) のように、`SAW <= 18 && SBW > 18`（または `SBW <= 25 && SAW > 25`）のとき、内部で `X`（A 側）と `Y`（B 側）を入れ替えることで、`24×17` は **1 DSP**、`17×32` や `32×16` は **2 DSP** に最小化します。

#### (2) カスケード・タイル分割（全 5 ケースで GPU 内の全幅を完全網羅）
正規化・スワップ後の幅を `XW`（signed）、`YW`（signed）とします（下位タイルはすべて 17-bit unsigned = `{1'b0, bits[16:0]}` の 18-bit signed として投入）：

| ケース | 条件 (`XW`, `YW` は signed 幅) | 該当する GPU 内の全インスタンス (`AW × BW`, `SIGNED`) | `DSP48E1` 数 | カスケード構成（すべて `ALUMODE=4'b0000`, `INMODE=5'b00000`） |
| :---: | :--- | :--- | :---: | :--- |
| **Case 1**<br>(1×1) | `XW <= 25 && YW <= 18` | `8×8` u, `AW(6..9)×8` u, `9×9` u, `16×8` u, `8×17` u, `16×16` u, `17×16` u, `16×17` u, `24×17` u, `17×13` u/s | **1 個** | ・**DSP0**: `X * Y` (`OPMODE = 7'b0000101`) → `P0[AW+BW-1:0]` |
| **Case 2**<br>(1×2) | `XW <= 25 && 18 < YW <= 35` | `18×18` u, `24×24` u, `32×3` u, `32×16` u, `17×32` u, `25×25` s, `27×17` s, `30×17` s | **2 個** | `Y` を `Y0 = {1'b0, y[16:0]}` と `Y1 = y[YW-1:17]` に分割。<br>・**DSP0** ($2^0$): `X * Y0` (`OPMODE=7'b0000101`) → `p[16:0] = P0[16:0]`, `PCOUT0 -> PCIN1`<br>・**DSP1** ($2^{17}$): `(PCIN1 >> 17) + X * Y1` (`OPMODE=7'b1010101`) → `p[AW+BW-1:17]` |
| **Case 3**<br>(1×4) | `XW <= 25 && 52 < YW <= 69` | **`24×59` u** ([`atg_su_xu.v`](rtl/gpu/su/atg_su_xu.v#L157) `u_tp`) | **4 個** | `Y` を 17-bit × 3 (`Y0, Y1, Y2`) + 上位 (`Y3`) に 4 分割。<br>・**DSP0** ($2^0$): `X * Y0` (`OPMODE=7'b0000101`) → `p[16:0]`<br>・**DSP1** ($2^{17}$): `(PCIN1 >> 17) + X * Y1` (`OPMODE=7'b1010101`) → `p[33:17]`<br>・**DSP2** ($2^{34}$): `(PCIN2 >> 17) + X * Y2` (`OPMODE=7'b1010101`) → `p[50:34]`<br>・**DSP3** ($2^{51}$): `(PCIN3 >> 17) + X * Y3` (`OPMODE=7'b1010101`) → `p[82:51]` |
| **Case 4**<br>(2×2) | `25 < XW <= 35 && 18 < YW <= 35` | **`33×33` s** ([`atg_su_fpu.v`](rtl/gpu/su/atg_su_fpu.v#L169), [`atg_cpu_muldiv.v`](rtl/gpu/cp/atg_cpu_muldiv.v#L88)) | **4 個** | `X = {X1, X0(17u)}`, `Y = {Y1, Y0(17u)}` に 2×2 分割。<br>・**DSP0** ($2^0$): `X0 * Y0` (`OPMODE=7'b0000101`) → `p[16:0]`<br>・**DSP1** ($2^{17}$): `(PCIN1 >> 17) + X0 * Y1` (`OPMODE=7'b1010101`)<br>・**DSP2** ($2^{17}$): `PCIN2 + X1 * Y0` (`OPMODE=7'b0010101`) → `p[33:17]`<br>・**DSP3** ($2^{34}$): `(PCIN3 >> 17) + X1 * Y1` (`OPMODE=7'b1010101`) → `p[65:34]` |
| **Case 5**<br>(3×3) | `35 < XW <= 59 && 35 < YW <= 52` | **`42×42` u** ([`atg_su_xu.v`](rtl/gpu/su/atg_su_xu.v#L171) `u_prod`) | **9 個** | `X = {X2(8u), X1(17u), X0(17u)}`, `Y = {Y2(8u), Y1(17u), Y0(17u)}` に 3×3 分割。<br>重み $2^{17k}$ ($k=0..4$) ごとに `PCOUT -> PCIN` で直列カスケード（重み境界で `OPMODE=7'b1010101`、同一重み内で `OPMODE=7'b0010101`）、各重みの最終 DSP から 17 bit ずつ `p[67:0]`、DSP8 から `p[83:68]` を出力。 |

> [!IMPORTANT]
> **`42×42` unsigned の `A` ポート幅に関する精密チェック**:
> `DSP48E1` の `A` ポートは **25-bit 2の補数（signed）** なので、符号ビット `A[24]` を `0` にすると **1 つの unsigned タイルに入れられる最大幅は 24 bit** です！
> - `42 - 17 = 25` bit unsigned は `A[24] = 1` のとき負数として扱われてしまいます！
> - ここで `B` 軸ではなく **`A` 軸と `B` 軸の分割** を見ると：
>   - `PCOUT -> PCIN` の右シフトは 17 bit 固定なので、重みを $2^{17k}$ に揃えるには下位タイルはすべて **17 bit unsigned** にする必要があります。
>   - `42 = 17 + 17 + 8`（17-bit × 2 + 8-bit = 3 タイル）に分割すれば、各タイルは `17u` (18s), `17u` (18s), `8u` (9s) となり、すべて `DSP48E1` の 25×18 signed に余裕で収まり、重みは $2^0, 2^{17}, 2^{34}, 2^{51}, 2^{68}$ の完全な 17-bit グリッドになります（3×3 = **9 DSP**、全段 `OPMODE` 7'b1010101 / 7'b0010101 の純粋な `PCOUT -> PCIN` 直列カスケード、fabric 加算器 0 個）。
>   - もしくは `A` を `17 + 24 + 1` にするより、**17-bit グリッド（`NX = ceil(AW/17)`, `NY = ceil(BW/17)`、ただし最上位タイルが `A` 側 $\le 24$u / 25s ならそのまま）** という単一の一般化ループ（2 重 `generate for` ループ）で書けば、1×1 (1 DSP), 1×2 (2 DSP), 1×4 (`24×59` = 4 DSP, `A` は 24u $\le 24$ なので `NX=1, NY=4`), 2×2 (`33×33` = 4 DSP), 3×3 (`42×42` = 9 DSP) の**全ケースがたった 1 つの統一アルゴリズム（`NX × NY` グリッドカスケード）で記述可能**になります！

#### (3) 統一 `NX × NY` カスケード・アルゴリズム（`am_mul.v` 内部）
1. 入力を `X`（A ポート側）と `Y`（B ポート側）に割り当てる（`X` 側の最上位タイルは **signed 25 bit（unsigned 24 bit）** まで、`Y` 側の最上位タイルは **signed 18 bit（unsigned 17 bit）** まで 1 タイルに収容可能。下位タイルはすべて 17-bit unsigned）。
   - これにより：
     - `24×24` u: `NX = 1` (24u), `NY = 2` (17u + 7u) → **2 DSP**
     - `24×59` u: `NX = 1` (24u), `NY = 4` (17u×3 + 8u) → **4 DSP**
     - `33×33` s: `NX = 2` (17u + 16s), `NY = 2` (17u + 16s) → **4 DSP**
     - `42×42` u: `NX = 2` (17u + 24u = 41 bit) では 1 bit 足りないため `NX = 3` (17u + 17u + 8u), `NY = 3` (17u + 17u + 8u) → **9 DSP**
2. 重みインデックス $k = 0 \dots (NX + NY - 2)$ ごとに、$i + j = k$ となるタイル対 $(X_i, Y_j)$ を `PCOUT -> PCIN` で直列につなぐ：
   - チェーン先頭 ($k=0$ の最初の DSP): `OPMODE = 7'b0000101` (`P = M`)
   - 新しい重み $k$ の最初の DSP: `OPMODE = 7'b1010101` (`P = (PCIN >> 17) + M`)
   - 同じ重み $k$ の 2 個目以降の DSP: `OPMODE = 7'b0010101` (`P = PCIN + M`)
   - 重み $k < NX + NY - 2$ の最後の DSP の `P[16:0]` が積のビット `p[17*k +: 17]` を確定出力し、最上位重み $k = NX + NY - 2$ の最後の DSP の `P` が上位ビット `p[AW+BW-1 : 17*(NX+NY-2)]` を出力する。
3. **`LAT = 0..3` のレジスタ設定**:
   - `LAT == 0`: 全 DSP の `AREG=0, BREG=0, MREG=0, PREG=0`。
   - `LAT == 1`: 全 DSP の `AREG=0, BREG=0, MREG=0`、カスケード最終出力（および途中重みから引き出す `P[16:0]`）に 1 段レジスタ（1 DSP 時は `PREG=1`、複数 DSP カスケード時は最終 DSP の `PREG=1` + 下位スライス整列 FF 1 段）。
   - `LAT == 2`: 全 DSP の `MREG=1`、最終段 `PREG=1`（複数 DSP カスケード時は途中 DSP の `PREG=0`・最終 DSP の `PREG=1`、または `AREG=1, BREG=1, MREG=1` 構成）。
   - `LAT == 3`:
     - 1 DSP 時: `AREG=1, BREG=1, MREG=1, PREG=1`。
     - 2 DSP 時（`atg_tu_fma` の `24×24` `LAT=3` 等）: DSP0 は `AREG=0, BREG=0, MREG=1, PREG=1`（2 サイクルで `PCOUT0` 確定、下位 `P0[16:0]` は FF 1 段で 3 サイクル目に整列）、DSP1 は `AREG=1, BREG=1, MREG=1, PREG=1`（2 サイクル目で `M` 確定、DSP0 の `PCOUT0` と足して 3 サイクル目に `P1` 出力）。これにより **2 個の DSP とも `MREG=1, PREG=1` を使いつつ、全体レイテンシがきっかり 3 サイクル**になります。

---

### 2.6 スクリプト・ドキュメントの書き換え詳細（範囲 4）

| ファイルパス | 書き換え内容 |
| :--- | :--- |
| [`tools/arith-lint.py`](tools/arith-lint.py#L222-L267) | ・L222: `fname.startswith('rtl/common/')` → `fname.startswith('rtl/library/arith/')` に変更。<br>・L267: 出力メッセージを `'arith-lint: %d operators outside rtl/library/arith'` に変更。 |
| [`tools/vivado-build.tcl`](tools/vivado-build.tcl#L50-L75) | ・`synth_design` に `-verilog_define SYNTH_KINTEX7` を追加。<br>・`synth_design` 後および `route_design` 後に、全 `DSP48E1` セルの総数と各セルの `NAME, AREG, BREG, MREG, PREG, USE_MULT` を `dsp_cells.rpt` に出力する処理を追加。 |
| [`tools/vivado-ooc.tcl`](tools/vivado-ooc.tcl#L45-L56) | ・`synth_design` に `-verilog_define SYNTH_KINTEX7` を追加。 |
| [`tools/lint.sh`](tools/lint.sh#L14-L30) | ・`rtl/bsp/xilinx7/` の単体モジュール lint 時は `-DSYNTH_KINTEX7 sim/lint/xilinx_stubs.v` を渡し、通常コア lint 時は `rtl/bsp/xilinx7/` を除外（`SYNTH_KINTEX7` 未定義のため）。 |
| [`docs/style.md`](docs/style.md#L31-L82) | ・`rtl/common/` の記述を `rtl/library/arith/`, `rtl/library/fp/`, `rtl/library/bus/`, `rtl/bsp/` に更新。<br>・Arithmetic 節に「`*` は `am_mul` の汎用版（`ifndef SYNTH_KINTEX7`）の中だけ、板（`SYNTH_KINTEX7`）は `DSP48E1` プリミティブ直打ち＋`PCOUT -> PCIN` カスケード」「加算・シフタは fabric（`CARRY4`・LUT）のまま」「FP 演算器の統合と例外一覧」を記載。 |
| [`README.md`](README.md) / [`spec/README.md`](spec/README.md) | ・ディレクトリ構成の説明を `rtl/bsp/`, `rtl/library/{arith,bus,fp}/`, `rtl/gpu/` および `spec/bsp/`, `spec/library/{arith,bus,fp}/`, `spec/gpu/` に更新。 |

---

## 3. 検証（確かめ 1〜4）の実施ファイル・手順

1. **確かめ 1（FP モジュール等価試験）**:
   - `build/tmp/equiv/` に各統合モジュール（`am_fp_add` `LAT=0/4`, `am_fp_mul` `LAT=4`, `am_fp_fma_p`, `am_fp_fma` `LAT=0/10`, `am_fp_rnd`, `am_fp_rint`, `am_fp_i2f`, `am_fp_f2i`, `am_fp_h2f` `DENORM=0/1`, `am_fp_f2h`, `am_fp_hrnd`）と旧モジュールを並べて 1,000,000 乱数＋特殊値・キャンセル入力で毎サイクル比較するハーネスを作成し、全件 0 error を確認。
2. **確かめ 2（`am_mul` 汎用版 vs `DSP48E1` カスケード版の単体等価試験）**:
   - `sim/tb/am_mul_dsp_tb.v`（または `tools/mul-dsp-test.sh`）を作成。
   - `$XILINX_VIVADO/data/verilog/src/glbl.v` と `$XILINX_VIVADO/data/verilog/src/unisims/DSP48E1.v` を読み込ませ（`-s am_mul_dsp_tb -s glbl`、開始後 `150 ns` 待って `glbl.GSR` 解除後に駆動）、GPU 内で使われている**全 19 種の `(AW, BW, SIGNED)` × `LAT = 0, 1, 2, 3`** の計 76 インスタンス対について、乱数入力＋ランダム `en` で毎サイクル `p_generic === p_dsp` を assertion チェック。
3. **確かめ 3（日常試験一式）**:
   - `tools/arith-lint.py` → `0 operators outside rtl/library/arith`
   - `make lint` → 全モジュール・全トップ clean
   - `make sim` / `make verilator` / `fw-run` / `ghci-e2e` → 全 PASS
4. **確かめ 4（KC705 板ビルド）**:
   - `tools/vivado-build.sh kc705 atg_kc705_raster`（`SYNTH_KINTEX7` 有効、Vivado 2026.1 build 6511674、Default、`MIG_DEBUG=0`）を実行。
   - LUT・DSP48E1 数（p037 との比較）、各 DSP48E1 の `AREG/BREG/MREG/PREG` 設定一覧、およびビルド時の **全 Warning 一覧** を抽出して報告。
