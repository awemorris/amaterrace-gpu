<!-- awesome-plan project=amaterrace-gpu record=ws001 -->

# WS001 Amaterrace GPU IP（RTL 階層整理・FP 演算器統合・DSP48E1 最適化）

- Master: [plan/master.md](../master.md)（2026-10-26 新設、旧 zedBSD WS288 より移行・再定義）
- Primary Milestone: **MG001**（RTL 階層整理・演算器統合・FPGA 最適化）
- Related Milestones: **MG002**（KC705 実機稼働・GHCI 統合）、**MG003**（タイミング収束）
- Guardrail: [plan/guardrail.md](../guardrail.md)、[docs/style.md](../../docs/style.md)
- Status: `incomplete`（p001 計画中、ユーザー承認待ち）
- 出典・経緯:
  - 2026-10-26 ユーザー: 「ws288は上位プロジェクトから持ってきた計画なんだけど、このプロジェクトのws001として定義しなおしてほしいです。GitHub Issuesの利用はこのプロジェクトでは行いません。ローカルのplan/master.mdとws001/ws.mdのようなファイルで運用します。」
  - 「新しいwsはws001です。p042がws001-p001になります。そのほかのコピーしたphaseは削除してください。」

## 概要

Amaterrace GPU の RTL 階層を整理し（`rtl/common/` 廃止 → `rtl/library/{arith,bus,fp}/` および `rtl/bsp/{xilinx7,generic}/` への再編）、各ブロックに散在していた浮動小数点（FP）演算器を `rtl/library/fp/` に統合・共通化する。あわせて乗算器 `am_mul.v` に `SYNTH_KINTEX7` 時の全幅 `DSP48E1` プリミティブ直打ち＋`PCOUT -> PCIN` カスケード実装を追加し、fabric 加算器や `*` 推論による合成時のタイミング悪化を解消する。

## 運用の約束（ユーザー合意）

1. **勝手に進めない**: 担当エージェントの起動・Vivado ビルド・板の操作・設計の変更は、事前に案を示して承認を得てから行う。
2. **機能・サイクル不変**: すべてのモジュールの入出力ビットおよびサイクル遅延（`LAT`）は現状と 1 bit・1 cycle たりとも変えない。
3. **全幅 `DSP48E1` カスケード (`SYNTH_KINTEX7`)**: `am_mul.v` は `SYNTH_KINTEX7` で最小幅（8×8）から最大幅（24×59, 42×42）まで全て `DSP48E1` プリミティブ直打ち＋`PCOUT -> PCIN` カスケードで実装し、fabric 加算器や `*` 推論を一切使わない。
4. **BSP の切替 (`SYNTH_KINTEX7`)**: `rtl/bsp/xilinx7/` と `rtl/bsp/generic/` も `` `ifdef SYNTH_KINTEX7 `` で切り替え、`find rtl -name '*.v'` による一括コンパイルを維持する。
5. **板のビルド警告は全件報告**: ビルドの Warning は全件一覧をユーザーに提示し、無害の判断はユーザーが行う。

## Phase

| Phase | 内容 | 依存 | 状態 |
| --- | --- | --- | --- |
| [p001](phase001/phase.md) | RTL の階層（bsp・library・gpu）と FP の演算器の重複の整理（旧 ws288-p042） | なし | completed |
| [p002](phase002/phase.md) | GHCI 1.1 起動ハンドシェイク規格化 & 診断ダンプ強化（R1 敵対的レビュー対応） | p001 | completed |
| [p003](phase003/phase.md) | 共有 L2 キャッシュ（LLC）導入 & キャッシュコヒーレンシ再構築（R1 敵対的レビュー対応） | p002 | in-progress |
| [p004](phase004/phase.md) | IOMMU 連携 & CP 自律型 MMU（Hardware Walker + 隠蔽 TLB）仕様策定 & 実装 | p002 | completed |
| [p005](phase005/phase.md) | マルチエンジン独立キューイング & ハードウェアプリエンプション（R1 敵対的レビュー対応） | p004 | planned |
| [p006](phase006/phase.md) | 細粒度同期（Timeline Semaphore / パイプラインバリア）& 描画同期基盤 | p003, p005 | planned |
| [p007](phase007/phase.md) | GHCI 2.0 スリム MMIO 化 & 構造化ディスクリプタ・コマンドアーキテクチャの刷新 | p002, p004 | completed |
| [p008](phase008/phase.md) | FP 演算ライブラリ再編 & 統合 FPU コア（am_fpu_core）実装 | p001 | completed |
| [p009](phase009/phase.md) | `rtl/library/arith/` 物理最適化（ビット反転右シフト & Non-restoring 除算器） | p001 | in-progress |
| [p010](phase010/phase.md) | SU 実 6段パイプライン化（偽遅延FF排除・`am_fpu_core` 4段分割・遅延均等化） | p008, p009 | planned |
| [p011](phase011/phase.md) | SU オペランド・フォワーディング / バイパスネットワーク（RAW ストール解消） | p010 | planned |
| [p012](phase012/phase.md) | SU スコアボード連動ワープスケジューラ（`warp_ready`・リプレイゼロ） | p010, p011 | planned |
| [p013](phase013/phase.md) | SU レジスタファイル最適化（BRAM 半減・マルチ SU 面積削減） | p010 | planned |
| [p014](phase014/phase.md) | 8-bit unorm 高速ブレンド & div255 1段化（Lerp 変形・乗算器半減） | p001 | planned |
| [p015](phase015/phase.md) | fp32 / sRGB ブレンド完全ストリームパイプライン化（FSM 撤廃・1 beat/cycle） | p014 | planned |
| [p016](phase016/phase.md) | Hazard Tracker（Pixel Lock）導入 & ROP 完全パイプライン化（Stop-and-Wait 根絶） | p014, p015 | planned |
| [p017](phase017/phase.md) | ROP L1 タイルキャッシュ導入 & 外部メモリスラッシング解消（8KB Color/Depth） | p016, p003 | planned |
| [p018](phase018/phase.md) | TU 4 レーン並列ストリームアドレス生成（`atg_tu_addr` 逐次 FSM 撤廃・1 cycle/quad 化） | p001 | planned |
| [p019](phase019/phase.md) | フィルタリングパイプライン統合 & 相互排他ウェイト撤廃（`u_idle`/`f_idle` 撤廃） | p018 | planned |
| [p020](phase020/phase.md) | マルチバンク・4-way L1 テクスチャキャッシュ（4 バンク同時読み出し） | p018 | planned |
| [p021](phase021/phase.md) | MSHR ノンブロッキングフェッチ & メモリ統合（Hit-Under-Miss、実効スループット 30〜50 倍向上） | p020, p003 | planned |
| [p022](phase022/phase.md) | Stream Setup Engine 実装（`atg_rx_setup` マイクロコード撤廃と完全パイプライン化） | p001 | planned |
| [p023](phase023/phase.md) | MSAA 4x 並列カバレッジ & Coarse Tile Rasterizer（`atg_rx_scan` 1 サイクル化と $8 \times 8$ タイルスキップ） | p022 | planned |
| [p024](phase024/phase.md) | Fast DDA Plane Evaluator（`atg_rx_bary` & `atg_rx_frag` 200 サイクルボトルネック撤廃） | p022 | planned |
| [p025](phase025/phase.md) | RX ストリームパイプライン統合 & 全シーン回帰検証（6段ストリーム化） | p022, p023, p024 | planned |
| [p026](phase026/phase.md) | `atg_fmt_pack` 2段パイプライン化（LAT=2、200 MHz クリティカルパス解消） | p001 | planned |
| [p027](phase027/phase.md) | MC AXI バースト結合キュー（Burst Coalescer: ARLEN=3/7 自動マージ） | p003 | planned |
| [p028](phase028/phase.md) | MC フラットクロスバー & QoS アービタ（遅延 8clk $\to$ 2clk、DC 優先帯域保証） | p027 | planned |
| [p029](phase029/phase.md) | CP 64ワード循環コマンドプリフェッチ FIFO（ノーウェイトパケット供給） | p002 | planned |
| [p030](phase030/phase.md) | BLT ストリーミングバースト DMA エンジン（FSM 撤廃、1.0+ GB/s 転送） | p027 | planned |
| [p031](phase031/phase.md) | BLT 1サイクル並列 MSAA 4x Resolve（クアッド並列平均化） | p030 | planned |
| [p032](phase032/phase.md) | VF 4ストリーム並列属性 DMA & ラインバッファ拡張 | p027 | planned |
| [p033](phase033/phase.md) | VF 32エントリ Post-Transform Vertex Cache（PT-VC: 頂点重複計算 60% 削減） | p032, p010 | planned |
| [p034](phase034/phase.md) | ボードトップ命名刷新（atg_kc705_top）& atg_pcie_msi の BSP 移動 | p001 | planned |

---

### [ws001-p001](phase001/phase.md) 詳細

- **親**: WS001。設計: [design.md](design.md) §19.5.5。作業仕様書: [work-spec.md](phase001/work-spec.md)。
- **状態**: planned（2026-10-26 新設、ユーザー承認待ち）
- **依存・順**: 今すぐ。p001 → SU の下位の部品の pipeline 化（SU → TU → ROP … の順に block ごと）。DC の 200 MHz は並行して進める。名前の移動は多くのファイルに触れるため、p001 の担当以外は amaterrace の `rtl/common`・FP の module を触らない。
- **進め方（2 段階のマイルストーン）**:
  - **Step A（階層整理と FP 統合）**: 範囲 1・2・4（`SYNTH_KINTEX7` 以外）を実施し、確かめ 1・3（等価検証・日常 sim/lint・arith-lint 0）がすべて PASS することを確認して中間記録・コミット境界とする。
  - **Step B（am_mul の DSP48E1 カスケード化と板ビルド）**: 範囲 3 と Vivado スクリプトの `SYNTH_KINTEX7` 追加を実施し、確かめ 2・3・4 を完了する。

#### 範囲（amaterrace-gpu。機能・cycle は変えない）
1. **階層**: `rtl/common/` を廃止して分ける。
   - `rtl/library/arith/`（7 ファイル）: `am_add`・`am_sub`・`am_addsub`・`am_shift`・`am_mul`・`am_div`・`am_msb`。
   - `rtl/library/bus/`（13 ファイル）: `am_axi_{cdc,gate,idtrack,master,regs,split}`・`am_amb_{mux,to_rt}`・`am_arb3`・`am_fifo`・`am_fifo_key`・`am_afifo`・`am_sync`。
     ※ `am_axi_master.v` 等の内部に残っていたカウンタの生 `+`/`-` も `am_add`/`am_sub` に置き換え、arith の外の生演算子を 0 にする。
   - `rtl/bsp/xilinx7/` と `rtl/bsp/generic/`:
     - JTAG レジスタブリッジ本体 `am_jtag_regs` と、`BSCANE2` + `BUFG` の TAP ラッパ（Xilinx 7 シリーズ primitive 版と sim/generic 版）。
     - `boards/kc705/lib/atg_kc705_jtag.v` の階層名（`dut.jtag.bscan.scan` / `idle`）は維持し、`atg_kc705_raster_tb.v` の階層参照を壊さない。
   - `boards/kc705/` は今のまま。`spec/common/` も同じ形に（`spec/library/arith/`・`spec/library/bus/`・`spec/library/fp/`・`spec/bsp/`）。

2. **FP の演算器の重複を `rtl/library/fp/` に 1 つずつ**（名前は `am_fp_*`、新設 11 ファイル、削除 14 ファイル）。
   - 段数は parameter `LAT`（既定値は主用途の段数）。各 module が localparam `LAT_OUT = LAT` を公開し、呼び出し側は今と同じ cycle になる値で使う（この Phase では段数を変えない）。
   - fp32 の加算 `am_fp_add #(.LAT(0 or 4))`:
     - 統合元: `atg_su_fadd`（`LAT=0`、組合せ）と `atg_rx_fadd`（`LAT=4`、4 段）。どちらも RNE・入出力 denormal flush・canonical NaN `0x7FC00000` でビット完全一致。
     - 置換先: `LAT=0` は `atg_su_lane`（qdx/qdy の 2 個/quad）、`LAT=4` は `atg_rx_{setup,cpoly,scan,bary}`・`atg_rop_{ms,fblend}`・`atg_rx_fp_tb`。
   - fp32 の乗算 `am_fp_mul #(.LAT(0 or 4))`:
     - 統合元: `atg_rx_fmul`（`LAT=4`、内部で 24×24 `am_mul` を使用）。`LAT=0` も generate で対応。
     - 置換先: `LAT=4` で `atg_rx_{setup,cpoly,scan,bary}`・`atg_rop_fblend`・`atg_rx_fp_tb`。
   - fp32 の FMA `am_fp_fma_p #(.LAT(0))` と `am_fp_fma #(.LAT(0 or 10), .TW(16))`:
     - `am_fp_fma_p`: 統合元は `atg_su_ffma_p`（`LAT=0`、48-bit 仮数積 p を外部から入力、rm 0..6・noc 対応）。置換先は `atg_su_fpu_op`（レーン共有の 33×33 `am_mul` の積を入力）および `atg_blt_favg`（fb = 1.0 / 0.25 のため乗算器なしで `p = {1'b0, ma, 23'd0}` を直結）。
     - `am_fp_fma`: 統合元は `atg_su_ffma`（`LAT=0`、24×24 `am_mul` + `am_fp_fma_p`）と `atg_tu_fma`（`LAT=10`、24×24 `am_mul` `LAT=3` + cycle 3 での `c_val` 遅延読み出し `c_vld/c_tag` + RNE 丸め）。置換先は `atg_tu_ffilt`（`LAT=10`）と `atg_tu_fma_tb`。
   - 丸めと変換:
     - `am_fp_rnd #(.LAT(0))`: 旧 `atg_su_rnd`（正規化済み s, e, m, g, st, rm → fp32、rm 5/6 の RNO 含む）。置換先は `atg_su_fpu_op`・`am_fp_i2f`・`atg_su_div`。
     - `am_fp_rint #(.LAT(0))`: 旧 `atg_su_rint`（fround/ffloor/fceil/ftrunc）。置換先は `atg_su_fpu_op`。
     - `am_fp_i2f #(.LAT(0))`: 旧 `atg_su_i2f`（32-bit 絶対値 + 符号 + rm → fp32）。置換先は `atg_su_fpu_op`。
     - `am_fp_f2i #(.LAT(0))`: 旧 `atg_su_f2i`（fp32 → 32-bit signed/unsigned 整数）。置換先は `atg_su_fpu_op`。
     - `am_fp_h2f #(.DENORM(0 or 1), .LAT(0))`:
       - DENORM=0（旧 `atg_su_h2f`、fp16 denormal を ±0 に flush、design §3.1）: 置換先は `atg_su_{fpu,fpu_op,pk,pk_half}`。
       - DENORM=1（旧 `atg_fmt_h2f`、fp16 denormal を正規化して保持、ghci §8.5）: 置換先は `atg_blt_favg`・`atg_tu_{fword,ffilt}`。
     - `am_fp_f2h #(.LAT(0))` と `am_fp_hrnd #(.LAT(0))`:
       - `am_fp_f2h`（旧 `atg_fmt_f2h`、RNE・fp16 denormal 生成、NaN `0x7E00`）: 置換先は `atg_fmt_pack`・`atg_blt_favg`・`atg_rop_fblend`。
       - `am_fp_hrnd`（旧 `atg_su_hrnd`、展開済み s, e, m, g, st, rm → fp16・denormal flush）: 置換先は `atg_su_{fpu,pk_half}`。
   - 例外（統合せず各ブロックに残す module、理由付き）:
     - `atg_su_div` / `atg_rx_fdiv`（SU は NPHYS レーン直列 + 整数/FP 除算で `am_div` 共有 + 全 rm 対応、RX は 26-bit 固定回復ステップ・RNE 専用で構造が異なる）
     - `atg_su_xu`（超越関数 FSM・多項式テーブルで SU 固有）
     - `atg_su_pk_half`（FP16 FMA と INT16 演算で 16×16 `am_mul`・36-bit 加減算を共有）
     - `atg_rx_i2f`（W<=23 固定小数点 → 丸めなし exact fp32 の軽量変換）
     - `atg_rx_f2fix` / `atg_tu_{coord,unnorm,fx32,layer}`（各ステージ固有の固定小数点幅・飽和シフト）
     - `atg_fmt_{comp,cvt}`（SFLOAT16 / UFLOAT / E5B9G9R9 / UNORM で 10-bit 正規化器を共有）
     - `atg_fmt_f2unorm` / `atg_rop_f2u8` / `atg_fmt_depth_u24`（UNORM 変換群）

3. **`am_mul` の `DSP48E1` の版（`ifdef SYNTH_KINTEX7`）**
   - `DSP48E1` の primitive を直に使う。DSP 1 個（25×18 signed）に入らない幅は `PCOUT -> PCIN` の cascade（17 bit unsigned タイル分割、`OPMODE[6:4]=3'b101` の 17-bit 右シフト加算および `3'b001` の同重み加算、`ALUMODE=4'b0000`）で部分積を DSP の中で足す。fabric の加算で足さない。
   - RTL 内の全インスタンス幅をカバーするタイル構成:
     - **1 DSP**（A_S <= 25 && B_S <= 18）: 8×8, AW(6..9)×8, 9×9, 16×8, 8×17, 16×16, 17×16, 16×17, 24×17 unsigned、および `am_arith_tb` の 17×13 unsigned/signed。
     - **2 DSP 1×2 カスケード**（片軸 <= 25 signed、他軸 19..35 signed → 17-bit unsigned + 上位）: 18×18, 24×24, 32×3, 32×16, 17×32 unsigned、および 25×25, 27×17, 30×17 signed。
     - **4 DSP 1×4 カスケード**（24×59 unsigned、`atg_su_xu` `u_tp`）: A=24 unsigned、B=17×3+8 の 4 段カスケード。
     - **4 DSP 2×2 カスケード**（33×33 signed、`atg_su_fpu`・`atg_cpu_muldiv`）: A=17+16 signed、B=17+16 signed の 4 段カスケード（UG479）。
     - **9 DSP 3×3 カスケード**（42×42 unsigned、`atg_su_xu` `u_prod`）: A=17+17+8 unsigned、B=17+17+8 unsigned の 9 段直列カスケード（重み $2^{17k}$ ごとに結合、fabric 加算器 0）。
   - `LAT` で 0（`AREG・BREG・MREG・PREG` を全部 0、組合せ）〜 3（入力段・MREG・PREG を配分し、カスケードの最終出力と途中タイルからの下位 17-bit 引き出しの双方がきっかり `LAT` cycle になる構成）を切り替える。en は全レジスタ段の CE に接続。
   - 汎用の版（`ifndef SYNTH_KINTEX7`、`*` の記述）も同じ `LAT` 段の register を持ち、cycle・en 挙動まで完全一致。
   - 呼び出し側の `LAT` は今の値のまま（`LAT=0`: SU/RX/ROP/BLT/DC/TU アドレス系、`LAT=1`: `atg_cpu_muldiv`・`atg_tu_{ffront,fpre}`、`LAT=2`: `atg_tu_fsum`、`LAT=3`: `atg_tu_fma`）。LAT 3 化は後の Phase。

4. **一緒に直す物**:
   - `tools/lint.sh`・`sim/run.sh`・`Makefile` の file list。
   - `tools/vivado-build.tcl`・`tools/vivado-ooc.tcl`（`synth_design` に `-verilog_define SYNTH_KINTEX7` を追加、`DSP48E1` の個数と各 DSP の AREG/BREG/MREG/PREG レポート出力を追加）。
   - `tools/arith-lint.py` の規則（`rtl/library/arith` の外は算術演算子 0）。
   - `docs/style.md` の Arithmetic の節（`*` は `am_mul` の汎用の版の中だけ、板は `DSP48E1` の版）、`README.md`・`spec/README.md` の階層の説明。加算・shifter は fabric のまま（CARRY4・LUT、DSP に寄せない）。

#### 確かめ
1. まとめた各 FP の module と元の各 module を、毎 cycle の等価の harness で比べる（p037 の `build/tmp/equiv/gen.py` と fvm2 の形、1,000,000 乱数 + 特殊値・桁落ち）。
2. `am_mul` の汎用の版と `DSP48E1` の版を、unisim（`$XILINX_VIVADO/data/verilog/src/unisims/DSP48E1.v` と `$XILINX_VIVADO/data/verilog/src/glbl.v`、トップに glbl を並立し GSR 解除の 100 ns 経過後に駆動；必要に応じ xsim バッチも併用）を読ませた iverilog（か xsim）で、乱数の入力とランダムな en で同じ cycle で bit 単位で一致するか assertion で比べる単体試験を 1 本（使っている全部の幅・SIGNED・LAT 0〜3）。
3. iverilog・Verilator の日常の試験は汎用の版のまま: `make sim`・`verilator`・`lint`・`fw-run`・`ghci-e2e` が PASS（T）、`arith-lint 0`（新しい規則）。
4. KC705 の板の build（`SYNTH_KINTEX7`、Vivado 2026.1 build 6511674、Default、`MIG_DEBUG 0`）: LUT・DSP を p037 の後と比べ、DSP48E1 の数と各 DSP の register の設定（`report_utilization`・DSP の property）を記録。build の warning は全部の一覧をユーザーに見せる。
   ※ p001 では `LAT=0` の DSP カスケードが残るため、該当パスの負の WNS（タイミング違反）は許容し、タイミング収束は後続の block 別パイプライン化 Phase の責務とする。

#### 受け入れ
- 新しい階層、`rtl/common/` は無い。FP の重複の各組が 1 つの module に（例外は理由付きの表）。
- `am_mul` の 2 つの版が全部の形で bit・cycle で一致（試験 2）。
- 確かめ 1・3 が PASS、板の build の完走結果（LUT・DSP・レジスタ設定）と warning の全件一覧を記録。
