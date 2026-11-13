# Request-08 1次回答 (Audit fe6431b1 に対する検証結果)

- 作成日時: 2026-11-13T10:25:00+09:00
- 対象コミット: `fe6431b1`
- 参照仕様書: `/home/awe/amaterrace-gpu/docs/ghci.md` (正本)
- 方針: 実装は行わず、RTL および仕様書を精査して各指摘の妥当性を判定。

---

## 項目別 1 次回答一覧

| 項目 | 判定 | 根拠 (file:line / docs/ghci.md) | 概要・詳細 |
| :--- | :--- | :--- | :--- |
| **X1** (seq halt 回帰) | **正しい** | RTL: `rtl/gpu/cp/atg_cp_seq.v:72, 328, 394-397, 448-449`<br>RTL: `rtl/gpu/cp/atg_cp.v:934, 938`<br>仕様: `ghci.md:363-366, 389, 570` | `atg_cp_seq.v` において `halt` 入力ポートが宣言とコメントのみで論理内で完全に未参照になっており、`hdr_take` や `n_ready`, `fw_ready` から `!halt` が消失している。そのため HALTED / FAULTED / RESETTING 状態でも header および payload を受け付けてしまう。`atg_cp.v:934` の `lc_halting` も定義のみで未参照となっている。指摘通り。 |
| **X2** (HOST_FLUSH 要求取りこぼし & CP_STATE) | **正しい** | RTL: `rtl/gpu/cp/atg_cp_seq.v:599, 611, 1110-1112`<br>RTL: `rtl/gpu/mc/atg_mc_l2.v:397, 465-485`<br>RTL: `rtl/gpu/mc/atg_mc.v:633`<br>RTL: `rtl/gpu/cp/atg_cp_ctl.v:208`<br>仕様: `ghci.md:355, 972` | (a) `atg_cp_seq.v` の `f_flush` は 1 サイクルパルスであり、`atg_mc_l2.v` において DC 等の `s_req_high` アクセスと競合した場合に要求が受け付けられず破棄される。また `ctrl_inv_done` が `atg_mc.v` で未使用のため、フラッシュ完了を待たずに進んでしまう。<br>(b) `atg_cp_ctl.v:208` の `cp_is_wait_mem` に `seq_st == 4'd11` (Q_FLUSH) が含まれておらず、Q_FLUSH 中に CP_STATE 5 (WAIT_MEM) が出力されない。<br>(c) 指摘された試験が未追加であることも事実。指摘通り。 |
| **X3** (local fence_addr 書き込みと L2) | **正しい** | RTL: `rtl/gpu/mc/atg_mc_l2.v:640-646`<br>RTL: `boards/kc705/atg_kc705_top.v:16-18, 234`<br>仕様: `ghci.md:400, 961-972` | 監査側の推測 (1)〜(3) を RTL で精査・確認:<br>(1) `atg_mc_l2.v:640-646` により、L2 はライトミス時にも write-allocate を行い、`dirty_mem[victim][set] <= 1'b1` としてダーティラインをキャッシュ内に保持する（ライトバック方式）。<br>(2) `boards/kc705/atg_kc705_top.v:16-18, 234` により、ホストの PCIe BAR2 (ローカルメモリ窓) は MIG DDR3 コントローラの第2ポートに直結されており、GPU の MC / L2 キャッシュを全く経由しない。<br>(3) したがって、GPU が local memory 上の `fence_addr` に書き込んだシーケンス番号は L2 内に留まり、MIG (DDR3) に書き戻されないため、ホストが BAR2 から読み出しても最新の fence 値が見えない。監査の読みは 100% 正しい。 |
| **X4** (SU STAGE と MC 経路) | **正しい** | RTL: `rtl/gpu/top/atg_top.v:1580-1582`<br>RTL: `rtl/gpu/cp/atg_cp_ctl.v:418, 506`<br>RTL: `rtl/gpu/su/atg_su.v:1277`<br>仕様: `ghci.md:439-444` | `atg_top.v` において `su_fault_stage` は `su_fault_v`（Scoreboard の不正命令フォールト）発生サイクルのみ出力され、それ以外は `4'd0` となる。そのため MC 経路（D$, I$, ATOM）でフォールトが発生したサイクルでは `su_stage` が 0 となり、`FAULT_INFO[19:16]` は常に 0 (VS) が記録されてしまう。また `atg_su.v:1277` で mesh/task warp 時の MS(3) 判定が考慮されていない点、および top の tb が未追加である点も指摘通り。 |
| **X5** (session fault, first-fault latch, slot 0 unchecked) | **一部** | RTL: `rtl/gpu/cp/atg_cp_ctl.v:599-613, 732`<br>RTL: `rtl/gpu/cp/atg_cp_prot.v:27, 146, 309`<br>RTL: `rtl/gpu/top/atg_top.v:1008`<br>RTL: `rtl/gpu/mc/atg_mc_prot.v:224`<br>FW: `fw/cp/cmd.c:455`, `fw/cp/prot.c:204`<br>仕様: `ghci.md:375-381, 415, 447-448` | (a) **正しい**: セッションフォールト時に `can_fault_r` が下がらないため、後続のフォールトで `FAULT_INFO` / `FAULT_ADDR` が上書きされる。<br>(b) **正しい**: §3.3 N05（フォールトしたセッションの後続コマンド NOP 化）が未実装。<br>(c) **正しい（完全的中）**: `map_v[tag] <= 0` 後、`map_u` は `6'd0` を返す。`atg_top.v:1008` で `c_req_chk = PROT && (prot_unit != 0)` となっているため、`prot_unit == 0` のときは `c_req_chk = 0`（チェック無効）となり、MC の `atg_mc_prot.v:224` で `a_direct = !a_chk` によりプロテクション検査が完全にバイパスされ、slot 0 の unchecked で直接メモリへアクセスしてしまう。<br>(d) **正しい**: (c) の unchecked 動作により、フォールト発生後の BLT が `AREA_A` に書き込みを行ってしまい `check(mem.peek32(AREA_A) == DATA_A)` が失敗していた。<br>(e) **一部**: C の bit が 0 なのは、`atg_top_prot_tb.v:235` で `ring_open(TAG_C, 32'd0, 2)` と `flags=0`（非保護セッション）でオープンされており、FW が `PROT_SLOT` を設定しないため。ハードウェアの `SESSION_ACTIVE` レジスタが PROT ユニットの `map_v`（保護セッション）のみを返しているため、非保護セッションが反映されない仕様・実装の不整合がある。 |
| **X6** (DEVICE_CAPS 残り) | **正しい** | RTL: `boards/kc705/atg_kc705_top.v:328`<br>RTL: `rtl/gpu/top/atg_top.v:126-127`<br>RTL: `rtl/gpu/cp/atg_cp_regs.v:59-61, 183-185, 699, 718-719`<br>仕様: `ghci.md:254` | KC705 の board top は minimal でも `HAS_CPU(1)` のため、現行の RTL 式では [4] CAP_SECONDARY_RING が 1 となり、DEVICE_CAPS は `0x40010490` となる（前回の報告で 0x40010480 と書いたのは誤り）。依頼 02 W4（ユーザー承認済み）に合わせるなら [4]=0 に固定するか、CMD_EXECUTE_COMMANDS の実行試験で 1 を立証する必要がある。また `atg_cp_regs.v` の `|| `ATG_DEF_FFILT` および未使用マクロの残存指摘も正しい。 |
| **X7** (IRQ_GLOBAL = 0 の試験) | **正しい** | RTL: `sim/tb/atg_top_tb.v`<br>仕様: `ghci.md:393-394` | 前回のコミットでは既存テストの書き込みに `IRQ_GLOBAL` を付加したのみで、依頼されていた「IRQ_GLOBAL = 0 で IRQ_STATUS & IRQ_ENABLE ≠ 0 でも irq = 0」のアサーションテストが実際には追加されていなかった。指摘通り。 |
| **X8** (include 別名と harness 期待値) | **正しい** | include: `include/ghci_regs.h:259-260`<br>sim: `sim/verilator/harness.cpp:458, 473`<br>規約: ルール 29 (別名の禁止) | `include/ghci_regs.h` に新別名 `GHCI_ST_FAULT`, `GHCI_STATUS_STATE(s)` が追加されている。また `harness.cpp` の期待値がビルド構成マクロ（`CFG_*`）と連動しておらず、minimal 構成で不整合となる。指摘通り。 |
| **X9** (小項目) | **正しい** | sim: `sim/tb/atg_kc705_pcie_tb.v:37`<br>sim: `sim/tb/atg_ghci_top_tb.v` | `atg_kc705_pcie_tb.v` のコメント誤記（[9] -> [3]）および `atg_ghci_top_tb.v` の Case 1 直後のパケット実行による非待機通過の直接検証追加。指摘通り。 |

---

## 補足事項・詳細技術考察

### 1. X3 (local fence_addr 書き込みと L2) の事実確認
- **(1) L2 の write-allocate**: `rtl/gpu/mc/atg_mc_l2.v:640-646` にて、キャッシュミスした書き込みに対してラインをフェッチ後、`dirty_mem[victim][set] <= 1'b1` をセットして `S_WRITE_COMMIT` へ遷移しており、明確に **write-allocate & write-back** を行っています。
- **(2) ホスト BAR2 窓のバイパス**: `boards/kc705/atg_kc705_top.v:16-18, 234` にて、PCIe BAR2 の AXI ポートは `am_axi_gate` を経由して直接 MIG DDR3 コントローラの第2ポートに接続されており、GPU 内部の MC および L2 キャッシュを一切経由しません。
- **(3) 結論**: したがって、GPU が local memory 上の `fence_addr` にシーケンス番号を書き込んだ場合、その値は L2 に留まり、ホストが BAR2 から読み取っても古い値が見えてしまいます。HOST_FLUSH はフェンス書き込みの前に実行されるため、フェンス自体の書き込みは保護されません。
- **直し方**: CP の FENCE 書き込み（および TIMESTAMP 等のホスト可読メモリ書き込み）において、アドレスがローカルメモリ領域であってもキャッシュバイパス（`nc = 1'b1`）として AXI Master へ直接書き込むか、書き込み後に該当ラインを即座にクリーンする機構が必要です。

### 2. X5 (c) (障害セッションの slot 0 unchecked 実行) の事実確認
- `atg_cp_prot.v:146` で `map_v[tag] == 0` のとき `map_u` は `6'd0` を返します。
- `atg_top.v:1008` では `assign c_req_chk[pc] = PROT && (prot_unit != 6'd0);` と定義されており、スロット 0（`prot_unit == 0`）でのアクセス時は `c_req_chk` が `0` になります。
- `atg_mc_prot.v:224` では `wire a_direct = !a_chk || !a_inside || a_tw;` と定義されており、`a_chk == 0` のリクエストは **プロテクション評価を完全にバイパスしてメモリへの直接アクセス（`a_axi`）が許可** されます。
- したがって、セッションフォールト後に後続の描画・BLT コマンドが飛んできた場合、保護テーブルによるアクセス拒否が行われず、全メモリ領域に対する無制限の読み書きが発生します。監査の指摘は完全なハードウェアバグを射抜いています。
- **直し方**: §3.3 N05 に従い、フォールトしたセッション（`SESSION_ACTIVE[tag] == 0`）の後続コマンド（FENCE / SESSION_CLOSE を除く）を CP / seq 側で NOP 化して実行ユニットを一切起動しないように修正する必要があります。

### 3. X5 (e) (SESSION_ACTIVE で C の bit が 0 である理由)
- `atg_top_prot_tb.v:235` の `ring_open(TAG_C, 32'd0, 2)` では、第2引数（flags）に `32'd0` が渡されています。
- ファームウェア（`fw/cp/cmd.c:455`）は、flags に `GHCI_SESSION_PROTECTED`（bit 0）が立っていない場合、非保護（public）セッションとして扱い、`fw_prot_session_open`（`HW_PROT_SLOT` への書き込み）を呼び出しません。
- ハードウェアの `GHCI_REG_SESSION_ACTIVE` レジスタは `atg_cp_prot.v:382` で `{16'd0, map_v[15:1], 1'b1}` を返しており、`PROT_SLOT` に登録された保護セッションのみが反映される実装になっています。
- そのため、非保護セッションである TAG_C は最初から `SESSION_ACTIVE` に反映されず 0 となっていました。

---

## 実装進捗ログ

### 2026-11-13T11:12:00+09:00: X1 実装・検証完了 (commit `cf91c102`)
- **した事**:
  - `rtl/gpu/cp/atg_cp_seq.v`:
    - `seq_abort` ポート追加。コメント（:47）を `halt` / `seq_abort` の仕様に合わせて更新。
    - `hdr_take`: `(st == Q_IDLE) && !halt && !seq_abort && hdr_valid`
    - `pay_take`: `(st == Q_PAY) && in_valid && !pay_hold && !seq_abort`
    - Kintex-7 `pay_take_b`: LUT5 から LUT6（`.INIT(64'h0000000000000008)`, `.I5(seq_abort)`）へ拡張（段数増加なし）。
    - Ready 信号: `n_rdy_idle`/`fw_rdy_idle` は `!halt && !seq_abort`、`n_rdy_pay`/`fw_rdy_pay` は `!seq_abort`。Generic 分岐も `!seq_abort && ((st == Q_IDLE && !halt ...) || (st == Q_PAY ...))` に統一。
    - `u_req`: `seq_abort ? 2'b00 : ...` により abort サイクルでユニットキックを即座に破棄。
    - `kick`: `!seq_abort` でゲート。
  - `rtl/gpu/cp/atg_cp.v`:
    - `s_seq_abort = lc_faulted || lc_resetting;`
    - `step_active` レジスタ追加（`s_step` でセット、ヘッダ受理 `s_n_valid && s_n_ready && (s_seq_st == 4'd0)` でクリア）。
    - `step_en = step_active || s_step;`
    - `s_seq_halt = lc_halting || (lc_halted && !step_en) || s_seq_abort;`
    - `u_seq` に `.halt(s_seq_halt)`, `.seq_abort(s_seq_abort)` を接続。
  - `sim/tb/atg_cp_seq_tb.v`, `sim/tb/atg_ghci_tb.v`, `sim/tb/atg_cp_mesh_tb.v`:
    - `atg_cp_seq` インスタンスへ `.seq_abort` 接続。`atg_cp_ctl` の未接続 `su_stage` 警告を解消。
  - テスト追加・照合:
    - `sim/tb/atg_ghci_top_tb.v`:
      1. インフライト CMD_FENCE 実行中に `CTRL.HALT=1` を投入し、`STATUS.HALTED == 0` のまま残りのペイロードを受理してメモリ書き込み完了後に `STATUS.HALTED == 1` へ遷移すること、および後続パケットが HALT 中に実行されず RPTR が停止すること、HALT 解除後に後続パケットが実行されることを検証（全 PASS）。
      2. `FAULTED` 状態後にリングへ積んだ CMD_FENCE が実行されず、メモリに書き込まれず、RPTR が進まないことを検証（全 PASS）。
    - `sim/tb/atg_top_fw_tb.v`:
      3. ファームウェア構成（`atg_top_fw`）において、`STATUS.HALTED == 1` の間にファームウェア µop が実行されず、HALT 解除後に正常実行されることを検証（全 PASS）。
- **試験実行結果**:
  - `./sim/run.sh atg_cp_seq`: PASS (17 subtests 全通過, `source: header taken while halted` 解消)
  - `./sim/run.sh atg_ghci_top`: PASS (37s)
  - `./sim/run.sh atg_top_fw`: PASS (442s, `PASS atg_top_fw(kc705).halt`)
  - `tools/lint.sh`: clean (全 RTL モジュール, top, board 0 warnings)
  - `python3 tools/arith-lint.py --top atg_cp`: 0 operators
- **残り**: X5, X4, X6, X7, X8, X9, X3 (docs)

### 2026-11-13T14:55:00+09:00: X5 実装・検証完了 (commit `e2f2d0e3`)
- **した事**:
  - `rtl/gpu/cp/atg_cp_ctl.v`:
    - (a) first-fault latch 実装:
      `wire fault_info_uncleared = |fault_info;`
      `wire take_fault_info = any && can_fault_r[2] && !fault_info_uncleared;`
      `wire take_fault_addr = any && can_fault_r[3] && !fault_info_uncleared;`
      初回フォールトで `FAULT_INFO` / `FAULT_ADDR` をラッチし、クリアされるまでの後続フォールトによる上書きを阻止。台帳 B34 推奨に従い、whole-device フォールト時の `take_fault_st`（FAULTED 遷移）および IRQ_FAULT、`fault_session_clear` は維持。W1C によるクリアに対応。
  - `rtl/gpu/cp/atg_cp_prot.v`:
    - (b) N05 判定およびフォールト履歴管理:
      `map_faulted` レジスタ配列を追加（`fault_clear_en && fault_clear_tag != 0` で 1 をラッチ、新規 `slot_wr` で 0 クリア）。
      `output wire u_active` を出力。フォールトしたセッション（`map_faulted[tag] == 1`）のみ非アクティブ（0）とし、非保護（public）セッション（`flags == 0`）はアクティブ（1）を維持。
  - `rtl/gpu/top/atg_top.v`:
    - `atg_cp_prot` と `atg_cp` の間に `u_active` を配線（`g_no_prot` では `1'b1`）。
  - `rtl/gpu/cp/atg_cp.v`:
    - `input wire u_active` を追加し、`u_seq.u_active` へ接続。
    - BLT のエラー報告タグを `8'd0` から `s_seq_fault_tag` へ修正し、セッション実行中の BLT エラーが正しくセッションタグを帯有するように修正。
  - `rtl/gpu/cp/atg_cp_seq.v`:
    - `input wire u_active` を追加。
    - `Q_DEC` で `is_allowed_op_r`（`CMD_FENCE`, `CMD_WAIT_FENCE`, `OP_FENCE`, `OP_WAIT_FENCE`, `CMD_SESSION_CLOSE`）をデコード。
    - `Q_DEC2` で `nop_r <= !u_active && !is_allowed_op_r;` をラッチ。
    - `Q_PAY`: `nop_r` の場合 `uop_we` を抑止、bad index 検査を無視し、ペイロード終了時に待機せず直接 `Q_IDLE` へ復帰（stall なし、起動なし）。
    - `Q_EXEC`: `nop_r` の場合 `u_req` / `kick` を出さず直接 `Q_IDLE` へ復帰。
  - `rtl/gpu/blt/atg_blt_2d.v`:
    - (d) MC によるリード拒否時（`m_burst && rsp_rd_bst && rsp_error`）に `bst_rd_err <= 1'b1;` をラッチ。
    - `bst_rd_err` アサート時はバースト書き込みパイプライン（`s1_valid`, `s2_valid`, `s3_valid`）を 0 にクリアし、リード発行（`bst_rd_valid`）を抑止してメモリへの書き込みを完全に防ぎ、安全に `S_IDLE` へドレイン。
  - `sim/tb/atg_top_prot_tb.v`:
    - (d) `check(mem.peek32(AREA_A) == DATA_A, "a is not written");` を復元。
    - (a), (b) N05 テストを追加: フォールトした Session A への後続 CMD_COPY_BUFFER がメモリを変更せず、後続 CMD_FENCE が正常完了し `FENCE_LAST` が更新されること、`FAULT_INFO` が初回値のまま変化しないこと（first-fault latch）、W1C で `FAULT_INFO` が 0 にクリアされることを検証。
    - (e) open(A=3)・open(B=6)・open(C=7) 後の `SESSION_ACTIVE`（`0x00000049`）を照合。
  - 既存テストベンチ更新:
    - `sim/tb/atg_cp_mesh_tb.v`, `sim/tb/atg_cp_seq_synth_tb.v`, `sim/tb/atg_cp_seq_tb.v`, `sim/tb/atg_ghci_tb.v` に `.u_active(1'b1)` を接続。
- **試験実行結果**:
  - `./sim/run.sh atg_top_prot`: **PASS** (553 s: regs, own, refuse, grant, revoke 全5グループ PASS、エラー 0 件)
  - `./sim/run.sh atg_cp_seq`: **PASS** (1 s)
  - `./sim/run.sh atg_cp_seq_synth`: **PASS** (0 s)
  - `./sim/run.sh atg_ghci`: **PASS** (1 s)
  - `./sim/run.sh atg_ghci_top`: **PASS** (52 s)
  - `tools/lint.sh`: clean (全 RTL モジュール, top, board 0 warnings)
  - `python3 tools/arith-lint.py --top atg_top`: 0 operators
  - `python3 tools/arith-lint.py --top atg_blt`: 0 operators
  - `python3 tools/arith-lint.py --top atg_cp`: 0 operators


- **した事**:
  - `rtl/gpu/mc/atg_mc_l2.v`:
    - `inv_active_r` レジスタを追加。`ctrl_inv_valid` が 0 の時にクリア、`S_FLUSH_STEP` への遷移サイクルで 1 をラッチ。
    - `S_IDLE` において `((ctrl_inv_valid && !inv_active_r) || flush)` でフラッシュを開始するように修正し、`ctrl_inv_valid` が保持されている間の重複フラッシュ再起動を防止。
  - `rtl/gpu/mc/atg_mc.v`:
    - `output wire l2_flush_done` ポートを追加。
    - `g_l2` 構成では `assign l2_flush_done = l2_ctrl_inv_done;`、`g_no_l2` 構成では `assign l2_flush_done = 1'b1;` を出力。
  - `rtl/gpu/top/atg_top.v`:
    - `u_mc` と `u_cp` 間に `wire l2_flush_done` を配線。
  - `rtl/gpu/cp/atg_cp.v`:
    - `input wire l2_flush_done` ポートを追加し、`u_seq.l2_flush_done` へ接続。
  - `rtl/gpu/cp/atg_cp_seq.v`:
    - `input wire l2_flush_done` ポートを追加。
    - `f_flush` を 1 サイクルパルスから `(st == Q_FLUSH)` の連続アサート（ホールド）へ変更。
    - `Q_FLUSH` 状態において `l2_flush_done` を待ってから `Q_FREQ` へ遷移するように修正。
  - `rtl/gpu/cp/atg_cp_ctl.v`:
    - `cp_is_wait_mem` の判定式に `|| (seq_st == 4'd11)` (Q_FLUSH) を追加（§3.3 CP_STATE 5: WAIT_MEM）。
  - `sim/models/xilinx/LUT.v`:
    - Xilinx 7-series `LUT1`..`LUT6` シミュレーションモデルを追加。
  - `sim/tb/atg_cp_seq_synth_tb.v`:
    - 新規単体テストベンチを追加。`SYNTH_KINTEX7` 構成で flags 0x4 (HOST_FLUSH) 投入時に `f_flush` (st=11) がアサートされ 1 回のフラッシュが走り、直後の flags 0x3 投入時には `f_flush` がアサートされず、フラッシュが 1 回のみ発生することを照合・検証（全 PASS）。
  - `sim/tb/atg_ghci_top_tb.v`:
    - L2 dirty データ検証: flags=0x2 でローカルメモリ（`0x80010000`）へ書き込んだフェンス値が DRAM（`axi_mem`）には未反映（L2 内に dirty 保持）であることを確認。
    - STATUS[19:16] 検証: flags=0x7 (HOST_FLUSH) のフェンス実行中の `Q_FLUSH` (st=11) において `STATUS[19:16] == 5` (WAIT_MEM) を確認。
    - フラッシュ完了検証: flags=0x7 フェンス完了後に、先ほどの dirty なローカルデータ（`0x80010000`）が DRAM にライトバックされて書き込まれていることを確認。
    - flags=0x3 非フラッシュ検証: flags=0x7 の直後に投入した flags=0x3 のローカルメモリ書き込み（`0x80010040`）は DRAM に反映されず L2 に保持されることを確認。
    - DC 走査並行検証: ADV7511/DC を小型モード（32x4）で起動してフレームバッファ（`0x80020000`）からの実スキャンアウト（MC への高優先リクエスト連続発行）を実行中に、flags=0x7 のフェンスを 20 回連続で流し、全 20 回のフェンスが完了して各フェンス値がメモリに書き込まれ、`ctrl_inv_done` が正確に 20 回発生することを確認。
  - 既存テストベンチ更新:
    - `sim/tb/atg_cp_mesh_tb.v`, `sim/tb/atg_cp_seq_tb.v`, `sim/tb/atg_ghci_tb.v` に `.l2_flush_done(1'b1)` を接続。
- **試験実行結果**:
  - `./sim/run.sh atg_cp_seq`: PASS (1 s)
  - `./sim/run.sh atg_ghci_top`: PASS (53 s)
  - `./sim/run.sh atg_cp_seq_synth`: PASS (0 s)
  - `./sim/run.sh atg_top_disp`: PASS (17 s)
  - `tools/lint.sh`: clean (全 RTL モジュール, top, board 0 warnings)
  - `python3 tools/arith-lint.py --top atg_cp`: 0 operators
  - `python3 tools/arith-lint.py --top atg_mc`: 0 operators


