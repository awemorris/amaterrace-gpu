# Amaterrace GPU スケーラブル NoC・MMU・マルチ SU アーキテクチャ仕様書

- **ステータス**: 設計合意済み・実装仕様（Proposed & Approved Architecture Specification）
- **対象モジュール**: `atg_top`, `atg_mmu`, `atg_mc`, `atg_cp`, `atg_su`, `atg_vf`, `atg_rx`, `atg_tu`, `atg_rop`, `atg_blt`, `atg_rt2/3/4`, `atg_rep`, `atg_su_fabric_n*`
- **関連仕様**: [`docs/addressing_architecture.md`](addressing_architecture.md), [`docs/style.md`](style.md), [`ghci.md`](../ghci.md), [`spec/gpu/mmu/atg_mmu.md`](../spec/gpu/mmu/atg_mmu.md)

---

## 1. 背景と設計方針のサマリ

Amaterrace GPU を **FPGA 軽量検証（KC705 等）** から **ASIC 5nm 1.5 GHz・最大 128 SU（Shader Unit）スケール** まで破綻なく一貫して展開するため、以下 6 本柱のアーキテクチャを導入する：

1. **アドレス空間パラメータの完全伝搬**: `atg_top` における `.ADDR_W(32)` 固定を全廃し、仮想アドレス側（`VA_BITS`: 30..40 bit）と物理アドレス側（`PA_BITS`: 40..48 bit）を明確に分離・伝搬する（MMU 無効のフラット物理構成では `>= 32` bit 下限を保護）。
2. **`atg_mmu` の完全統合**: `atg_cpu_win` (`0x38..0x3D`)・`atg_cp`・`atg_cp_ctl`・`atg_mc` を接続し、L1/L2 TLB およびハードウェアページテーブルウォーカーを `atg_top` 上で実動作させる。
3. **クロスバー vs 統一ファットツリー NoC の棲み分け**:
   - `*-fpga-test-minimal`（FPGA 最小リソース・低遅延試験用）のみ、現行のフラットクロスバー（`atg_mc_tree`）を使用する。
   - **それ以外の全構成（`gfx-vulkan10-su*`, `gfx-all-su*`, `compute-su*`）は `NSU = 1, 2` を含め、`atg_rt2 / atg_rt3 / atg_rt4` ＋ `atg_rep` による統一ファットツリー NoC を採用する。** `DC` と `CP` をルート直近（高優先 QoS）へ配置する。
4. **明示的 2D フロアプラン・ファブリック（`N = 1, 2, 4, 8, 16, 32, 64, 128`）**: 再帰的な汎用 `generate` で配線トポロジを隠蔽せず、`N` ごとに 2D 座標配置とリピータ（`atg_rep`）段数を明記した専用ファブリックモジュール `atg_su_fabric_n<N>` を構成する。
5. **全 SU での Graphics ＋ Compute 両用化 ＋ Compute-Only 構成対応**: 共有プリミティブテーブル（`atg_su_pt`）をスパイン側（`VF`/`RX` 近傍）へ配置（案 I）して全 `N` 基の SU で描画を実行可能にしつつ、Vulkan Compute-Only（`HAS_VF=HAS_RX=HAS_ROP=HAS_TU=HAS_DISP=0`）を正式プリセットとして提供する。将来の `SA`（Systolic Array）は SU と 1:1 ではなく NoC ツリー内の独立ノードとして配置する枠を予約する。
6. **ASIC 5nm 1.5 GHz ルール遵守**: 全ルーター・リピータ・ブリッジ境界に `am_skid` を挿入し、`valid` のみならず **`ready` の組み合わせ貫通を完全に遮断** する（[`docs/style.md`](style.md) Rules 1–5 準拠）。

---

## 2. 可変アドレス幅（`VA_BITS` / `PA_BITS`）の全面適用

### 2.1 `atg_top` における仮想幅・物理幅の定義

現在の [`rtl/gpu/top/atg_top.v`](../rtl/gpu/top/atg_top.v) では `VA_BITS`, `PA_BITS` が `unused_addr_params` 扱いとなり、内部サブモジュールすべてに `.ADDR_W(32)` が固定渡しされている。これを次のように改める：

```verilog
/* クライアント / SU ファブリック側実効アドレス幅 */
localparam UNIT_ADDR_W = (HAS_HW_WALKER != 0) ? VA_BITS : ((VA_BITS < 32) ? 32 : VA_BITS);
localparam UNIT_LA_W   = UNIT_ADDR_W - LINE_SHIFT;

/* MC / AXI / 物理ホストDMA 側実効アドレス幅 */
localparam MC_ADDR_W   = (PA_BITS < 32) ? 32 : PA_BITS;
localparam MC_LA_W     = MC_ADDR_W - LINE_SHIFT;
```

* **`HAS_HW_WALKER != 0`（MMU 有効）**:
  * GPU ユニット（`VF`, `TU`, `ROP`, `BLT`, `SU`, `ATOM`, `SA`）および SU ファブリック内のメモリ要求は **`UNIT_ADDR_W = VA_BITS`**（30..40 bit、Line 幅 `VA_BITS - LINE_SHIFT`）で動作する。
  * MMU の出力以降（`atg_mc`, `atg_cp_ring` 物理リングアクセス, `atg_cp_fence` 物理フェンス書込み, `atg_cpu_dma`, MMU Walker, `atg_dc`）および `m_awaddr` / `m_araddr` は **`MC_ADDR_W = PA_BITS`**（40..48 bit）で動作する。
* **`HAS_HW_WALKER == 0`（フラット物理モード / FPGA 最小テスト）**:
  * KC705 等の `LOCAL_BASE = 32'h8000_0000` 互換性を損なわないよう、`VA_BITS = 30` 設定時でも `UNIT_ADDR_W` を 32 bit 以上に保つ。
* **外部 AXI4 マスタ出力（`m_awaddr[63:0]`, `m_araddr[63:0]`）**:
  * `mc_awaddr[MC_ADDR_W-1:0]` を上位ゼロ拡張 `{ {(64-MC_ADDR_W){1'b0}}, mc_awaddr }` として出力する。

### 2.2 内部 `[31:0]` ハードコード解消対象モジュール

`ADDR_W` パラメータを持ちながら内部で `[31:0]`（または `30` bit）に固定されている箇所を `ADDR_W` 追従へ統一する：

| モジュール | 現状の固定箇所 | 是正内容 |
| :--- | :--- | :--- |
| `atg_cp_ring` | `base[0][31:0]`, `ctx_base[31:LINE_SHIFT]`, `RING_BASE_HI` 未反映 (`atg_cp_regs` で 0 返し) | `PA_BITS` 対応の 64-bit `RING_BASE_HI:LO` ラッチと `ADDR_W` 加算・出力 |
| `atg_cp_fence` | `fault_addr[31:0]`・アドレス上位切捨て | `ADDR_W`（`PA_BITS`）追従（32b/64b フェンス先 PA 書戻し） |
| `atg_cp_ctl` / `atg_cp_seq` | `mc_fault_addr[31:0]`, `fault_addr[31:0]` | `ADDR_W` 保持（BAR0 `FAULT_ADDR_LO/HI` 連動） |
| `atg_su_icache` | `input wire [31:0] ic_addr` 等 | `[ADDR_W-1:0]` 追従 |
| `atg_su_sched` / `atg_su_fetch` | `vs_base/fs_base/cs_base[31:0]`, `q_addr[31:0]` | `[ADDR_W-1:0]` 追従（上位ワードレジスタまたは 64b プログラムベース対応） |
| `atg_su_cbank` / `atg_su_lsu` | `s_addr[31:0]`, `at_addr[29:0]` | `[ADDR_W-1:0]` / `[ADDR_W-1:2]` 追従（偶数レジスタペア 64b ポインタ下位 `VA_BITS` ビット受け渡し） |
| `atg_mc_atom` | `wire [31:0] badr = {pick_addr, 2'b00};` | `[ADDR_W-1:0]` 追従 |
| `atg_dc` | `atg_top` で `.ADDR_W` 未指定 | `.ADDR_W(MC_ADDR_W)`（または `UNIT_ADDR_W`）を明示接続 |

---

## 3. `atg_mmu` 統合アーキテクチャ

### 3.1 `atg_mmu` 本体の一般化改修

現在の [`rtl/gpu/mmu/atg_mmu.v`](../rtl/gpu/mmu/atg_mmu.v) は単体検証用に `NUM_CLIENTS = 5`・`VA_BITS = 32`・`PA_BITS = 32` の一部が固定記述になっているため、統合前に以下を一般化する：

1. **任意 `NUM_CLIENTS` 対応**: `case (active_client) 3'd0..3'd4` と優先選択ロジック、および `fault_client` 幅（`NUM_CLIENTS <= 8` なら 3 bit、超える場合は 4 bit 化しトップで単位エンコード）をジェネリック並列選択ループへ書き換える。
2. **`VA_BITS` (30..40) / `PA_BITS` (32..48) スライス対応**:
   - `r_l1_pa_w0_hi`・`r_ref_pa_hi`・`r_client_pa` 内の `+ 4 +: 16` / `[19:4]` を `PPN_BITS - 4` / `PA_BITS - 16` 基準へ変更。
   - L2 タグ / ページインデックスの `sel_vpn_lo` / `sel_vpn_hi`（現状 `[9:0]` 固定）を `VPN_BITS = VA_BITS - 12`（18..28 bit）に合わせて可変化（`atg_tlb_l1`, `atg_tlb_l2`, `atg_mmu_walker` と整合）。
3. **2-Level ページテーブル形式の統一 (`fw/cp/mmu.c` 整合)**:
   - [`atg_mmu_walker.v`](../rtl/gpu/mmu/atg_mmu_walker.v) は `PA_BITS > 32` 時に 64-bit エントリ（`ENTRY_SHIFT = 3`、`pte_ppn = [PA_BITS-1:12]`）を使用する。[`fw/cp/mmu.c`](../fw/cp/mmu.c) も `PA_BITS > 32` 時（4 KiB ページ = 512 個の 8-byte PDE/PTE、9 bit インデックス、または 10 bit 相当 2-page PDE/PTE 規約）に合わせて 64-bit PTE 書込みへ整合させる。

### 3.2 CP ↔ MMU レジスタ・割り込み・トラップ経路

```
+-----------------------+     0x38..0x3D (atg_cpu_win)      +-------------------+
|  atg_cpu (RV32IM FW)  | <===============================> |  atg_mmu          |
|  - HW_MMU_SESSION     |  cp_pt_root_we / session / base   |  - L1 TLB / port  |
|  - HW_MMU_ROOT_PT     |  cp_flush_trigger / all / sess    |  - Shared L2 TLB  |
|  - HW_MMU_FLUSH       |  inflight_count[15:0]             |  - HW PT Walker   |
|  - HW_MMU_INFLIGHT    |  fault_valid/kind/sess/cl/addr    +---------+---------+
|  - HW_MMU_STATUS/VA   |                                             |
+-----------+-----------+                                             |
            |                                                         v
            +----------> [ atg_cp_ctl FAULT_INFO / FAULT_ADDR ] <-----+
                         - セッション単位隔離 (SESSION_ACTIVE[s] <= 0)
                         - 外部 AXI バスへの不正アクセス完全抑止
```

* **`atg_cpu_win.v` 拡張**: [`fw/cp/hw.h`](../fw/cp/hw.h#L55-L61) の `0x38..0x3D` をサブバスとしてデコードし、`atg_cp` ポート経由で `atg_mmu` へ直結する（`PA_BITS > 32` 時に備え、`HW_MMU_ROOT_PT_HI` もしくはシフトベース表現 `[31:0] -> PA[43:12]` のマッピング仕様を明文化：例 `root_pt[31:0] == PPN[31:0]` で `PA 44-bit` まで 1 レジスタ表現、または `ROOT_PT_HI` 追加）。
* **アクティブ `session_id[3:0]` の伝搬**: `atg_cp` の `CMD_BIND_SESSION` / `CMD_SESSION_*`（`HAS_CPU=1` のファームウェアまたは `atg_cp_seq`）から現在の実行コンテキストの `session_id[3:0]` を保持し、描画・コンピュートディスパッチ単位とともに各クライアント／NoC ヘッダへ添付する（`0`＝カーネル物理/セッション0、`1..15`＝ユーザプロセス）。

### 3.3 MMU の配置境界（スパイン変換 ＋ 物理バイパス）

* **MMU 変換を通過するクライアント（VA → PA）**:
  * `VF`, `TU`, `ROP`, `BLT`, `ATOM`, （将来 `SA`）, および `SU` ファブリックの上りトランク群（`1..8` 本）。
  * SU ファブリック内部は `VA_BITS` でルーティングし、**スパイン出口（MMU 境界）で一括変換** する（`1` トランク＝毎サイクル最大 1 要求のため、L1 TLB 1 ポート/トランクでスループット低下ゼロ、かつ散在 TLB の同期コスト不要）。
* **MMU をバイパスする物理クライアント（直接 PA）**:
  * `CP`（コマンドリングフェッチ、フェンス DMA）、`CPU`（CPFW DMEM/IMEM DMA）、`MMU Walker` 自身（PDE/PTE 64-bit リード）、`DC`（スキャンアウトフレームバッファ）。
* **ブリッジ `am_mmu_bridge`**:
  * クライアントからの AMB 要求（`req_valid`, `req_line[UNIT_LA_W-1:0]`, `req_write`, `req_exec`, `req_session[3:0]`）を受け、`atg_mmu` に投入する。
  * L1 ヒット時（1 cycle）またはウォーク完了時（`client_ack = 1`）に、変換後の `client_pa[PA_BITS-1:LINE_SHIFT]` を付けて後段 NoC/MC へ流す（ミス中は `req_ready = 0` でストール）。
  * `client_fault = 1` 時は **後段 MC への要求発行を完全に抑止** し、`atg_cp_ctl` へフォルトパルスを上げると同時に、発行元クライアントへ `rsp_valid = 1, rsp_error = 1` を返してハングを防ぐ。

---

## 4. 統一ファットツリー NoC アーキテクチャ

### 4.1 `CLIENT` ID の仕様明確化と拡張フリット設計

* 外部 AXI4 ポート（`m_awid`, `m_arid`）は 1 bit（ローカル DDR / ホスト切替）であり、従来の 8 bit `CLIENT` 制限は純粋に GPU 内部フリットプロトコル上の制約である。
* 外部 AXI4 を引き回すのではなく、現行の単一ペイロード幅フリット（[`am_amb_to_rt.v`](../rtl/library/bus/am_amb_to_rt.v)）を拡張して用いる（`FW = LINE_BYTES * 8`: 64B 時 512 bit / 32B 時 256 bit）。

| ヘッダフィールド | ビット幅 | 内容 |
| :--- | :--- | :--- |
| `PRIO` | 1 bit (`[0]`) | 厳格優先フラグ（`CP`, `DC` 系＝1、描画/計算＝0） |
| `WRITE` | 1 bit (`[1]`) | Write=1 / Read=0（Write時は次フリットがデータ） |
| `OUTSIDE` | 1 bit (`[2]`) | Aperture / VRAM 境界判定補助 |
| `CHK` | 1 bit (`[3]`) | Session Protection チェック有効フラグ |
| `TAG` | 8 bit (`[11:4]`) | クライアントトランザクションタグ |
| `SRC_ID` | **12 bit**（従来 8 bit から拡張） | 発信元クライアント / SU ID（最大 4096 ノード識別可能、`12'hFFF`＝MC 内部ウォーク予約） |
| `ROUTE` | `RW` bit（最大 12〜16 bit） | ファットツリー各段のダウンストリーム応答経路（2/3/4-way の各ホップ 1〜2 bit 選択） |
| `LINE_ADDR` | `LA_W` bit（最大 42 bit @ PA=48） | キャッシュラインアドレス `[ADDR_W-1:LINE_SHIFT]` |
| `BE` | `LINE_BYTES` bit（32 or 64） | バイトイネーブル |
| `SESSION_ID` | 4 bit | MMU 用セッション ID（`0..15`） |
| `EXEC_TYPE` | 2 bit | アクセス種別（`00`=Read, `01`=Write, `10`=I$ Exec） |
| `PROT_META` | 7 bit | `{req_tbl, req_slot[5:0]}` |

* 64B ライン（512 bit フリット）・`PA_BITS = 48`（`LA_W = 42`）の最大構成でも合計約 **150 bit** であり、512 bit ヘッダフリット内に余裕で収まる（32B ライン 256 bit でも合計 ~115 bit で十分収容可能）。
* **応答フリット (`RFW`)**: `{rdata[LINE_BITS], route[RW], tag[7:0], error, write}`（`RFW` の `RBIT` は各ルータの分岐数に応じ 1 bit (`rt2`) または 2 bit (`rt3/rt4`) を参照して下り配送する）。

### 4.2 ルータ群 (`atg_rt2`, `atg_rt3`, `atg_rt4`) とリピータ (`atg_rep`)

```
[ SU / Child ] ===(am_skid)===> [ atg_rt2 / rt3 / rt4 ] ===(am_skid)===> [ Parent / Trunk ]
                                   - PRIO (bit 0) 優先
                                   - Fair Round-Robin
                                   - multi-flit lock (until last)
                                   - 応答: 1-cycle registered demux
```

1. **`atg_rt2`, `atg_rt3`, `atg_rt4`**（2 / 3 / 4 子ポート・1 親ポート）:
   - 従来の [atg_rt.v](../rtl/gpu/mc/atg_rt.v) にあった `p_req_ready -> c*_req_ready` の組み合わせ貫通を撤廃し、入力/出力いずれにも `am_skid` を置いて **完全 Flop-to-Flop 境界** とする（1.5 GHz で論理段数 $\le 6\text{ cmos3}$ を厳守）。
   - `atg_rt4` により `2×2` クアッドおよび `4×4` クラスタを **1 ホップ** で集約し、`N = 128` でもホップ数を 3〜4 段に抑制する。
   - **Fat-Tree 帯域維持**: ルートへ近づく上位レベルでは単純 4→1 に潰さず、**並列トランク（2本〜4本〜8本）** を束ねて上位ルータまたは `atg_mc` 前の集中ノードへ届ける。
2. **`atg_rep`（統合パイプライン・リピータ）**:
   - 長距離の水平（X）・垂直（Y）配線区間に挟む双方向スキッド＋制御スライスモジュール。
   - **内蔵 4 チャネル**:
     1. 上り NoC 要求フリット（`am_skid`）
     2. 下り NoC 応答フリット（`am_skid`）
     3. 下り制御ブロードキャスト FF スライス（`st_we`, `st_idx`, `st_wdata`, `cs_kick`, `cs_mesh`, `lc_kick`, `inv`, `scrub`, `session_id`）
     4. 上りステータス集約 FF スライス（`busy` OR、`scrub` OR、`fault` 優先調停、`fault_addr/stage`）

### 4.3 `atg_mc` 接続トポロジ（クロスバー vs 統一ファットツリー）

* **`USE_NOC_FABRIC = 0`（`*-fpga-test-minimal` 専用）**:
  * 従来通り [`atg_mc_tree.v`](../rtl/gpu/mc/atg_mc_tree.v) の 2 サイクルフラットクロスバーを使用（`NSU=1,2` の KC705 向け最小 LUT 構成）。
* **`USE_NOC_FABRIC = 1`（`gfx-vulkan10-su*`, `gfx-all-su*`, `compute-su*` 全般）**:
  * クロスバーを使わず、チップ全体（固定機能＋SU）を **`atg_rt2/3/4` ファットツリー** で構成し、根元に `DC` と `CP` を置く：

```
                       [ External AXI4 Master (m_aw/m_ar, PA_BITS) ]
                                            ^
                                    [ atg_mc (L2 + PROT) ]
                                      ^                ^
                         (s_*: DC優先) |                | (t_*: Root Arbiter)
                            [ DC ]----+                +---- [ Root atg_rt3/4 ]
                                                               ^      ^       ^
                                           (Prio 1) [ CP/CPU/Walk ]   |       |
                                                                      |       +---> [ SU Fat-Tree Trunks ]
                                                 (Fixed-Func Subtree) v               (1, 2, 4, or 8本 -> MMU)
                                                            [ atg_rt4_fixed ]
                                                             ^   ^   ^   ^
                                                            VF  TU  ROP  BLT (, 将来SA)
```

---

## 5. `N = 1, 2, 4, 8, 16, 32, 64, 128` 2D 個別ファブリック仕様

ジェネリック再帰 `generate` を避け、`rtl/gpu/fabric/atg_su_fabric_n<N>.v` として **8 通りの物理配置・リピータ段数を個別に明示実装** する。全 `N` で共通のスパイン側ポート（上り NoC トランク、制御ブロードキャスト入力、ステータス出力、アトミック集約出力、共有 PT ストリーム出力、Warp 分配ポート）を持つため、`atg_top` の残余ロジックを一切重複させない。

### 5.1 単位リーフ（1 SU タイル）

各 SU はローカルに **`SU内 2-way atg_rt2`（`D$`＋`I$` を統合、`I$` 側には `EXEC=1` 付与）** を持ち、外部へは **1 本の統合 NoC ポート** として出る。これにより 128 SU 時でも配線本数が半減する。

### 5.2 各 `N` の 2D 配置と `atg_rep` / Fat-Tree トランク構成

| `N` | 2D 配列 | ルータ階層構成 | `atg_rep`（ホップ）設計 | MMU/Root への上りトランク数 |
| :--- | :--- | :--- | :--- | :--- |
| **`1`** | `1×1` | `SU0` (D$/I$ `rt2` 統合) | `0` 段（直結） | **1** 本 |
| **`2`** | `2×1` (W, E) | `SU0(W)`, `SU1(E)` → `rt2_top` | 任意 1 段（W/E 対称） | **1** 本（または 2 本独立） |
| **`4`** | `2×2` Quad | 4 SU → `rt4_quad`（1 ホップ構成） | North 側 2 SU 縦スパンに `rep_v` 1 段 | **1** 本（または W/E 2 本） |
| **`8`** | `4×2` (W_Q, E_Q) | West `2×2` (`rt4`) ＋ East `2×2` (`rt4`) | 各 Quad 出口に水平 `rep_h` 1 段 → `rt2` 経由 | **2** 本 (W, E) |
| **`16`** | `4×4` (4 Quads) | `NW, NE, SW, SE` の 4 Quad（各 `rt4`） | `NW/NE` に垂直 `rep_v` 2 段、`SW/SE` に 1 段 → 南北 `rt2` 合流 | **2** 本 (W, E) または **4** 本 |
| **`32`** | `8×4` (W16, E16) | 左右各 `4×4`（計 8 Quad） | 外側列（Col 0,3）は内側より水平 `rep_h` +1 段、北側は垂直 `rep_v` +1 段 | **4** 本 (W_N/S, E_N/S or Quadペア) |
| **`64`** | `8×8` (4 象限×16 SU) | 4 象限（各 `4×4`: 4 Quad → `rt4_q16`） | 北象限 (`NW, NE`) 幹線は垂直 `rep_v` 2〜3 段、外周 Quad は水平 `rep_h` 2 段 | **4** 本 (NW, NE, SW, SE 象限トランク) |
| **`128`** | `16×8` (W64, E64) | 左右 2 個の `8×8`（計 32 Quad） | 最外周 (`Far-W`, `Far-E` 北側) に水平 `rep_h` 2〜3 段＋垂直 `rep_v` 2〜3 段。内側南象限は 1 段 | **8** 本（左右各 4 象限トランク → `rt2` で 4 本または直接 8 本接続） |

*(注: 上記の `atg_rep` 段数は各 `atg_su_fabric_n*.v` ファイル冒頭の 2D ASCII マップに座標ごとに固定記載し、ASIC Stage 1 合成（Yosys `cmos3` / 将来 OOC P&R）の配線負荷に応じてピンポイント増減できる設計とする。)*

---

## 6. 全 SU グラフィックス両用化・Compute-Only・`SA` 予約枠

### 6.1 共有 `PT`（案 I）による全 `N` 基 SU での 3D Graphics 対応

1. **共有 `atg_su_pt` のスパイン側移動**:
   - `atg_su_pt` を `atg_su` 内部から **スパイン側（`atg_vf` / `atg_rx` の直近）** へ配置する。
   - `atg_vf` の `pt_ok` / `pt_take` / `pt_base` / `vl_go`、および `atg_rx` の `pt_rd -> pt_rdata`（**従来の 3 サイクル固定読出しを維持**）・`pt_free` はスパイン内で完結させる。
   - VS を実行する任意の SU は `exp`（頂点位置・Varying 書込み）を **`pt_exp_valid/ready` 軽量ストリーム木** 経由でスパイン側 `atg_su_pt` へ流し、ワープ完了マーカ `wc_end` も同一ストリームに直列化して送ることで、`exp` 書込み完了と `pt_done` の順序逆転を構造的に防ぐ。
2. **`vl_*` / `fl_*` ワープ分配木 (`atg_warp_dist`)**:
   - `VF`（Vertex）および `RX`（Fragment）の起動要求を、空きスロットを持つ SU へ 2/4-way 木経由で割り振る（ロック機構により `vl_we` / `fl_we` / `fl_pw_we`〜`go` まで同 SU へ送出）。
3. **`SU -> TU` (`tx_*`/`tr_*`)・`SU -> ROP` (`ex_*`) 集約木 (`atg_gfx_rt`)**:
   - `tx_tag` 上位ビットへ `su_id` を積んで 2/4-way スキッド木で `TU` を共有・応答返却する。
   - `ex_*` は既に `ex_seq[15:0]` を持っているため、2/4-way アービタ木で `ROP` へ合流させるだけでマルチ SU 非順序完了下でも画素順序が保証される。
4. **`atg_mc_atom` ツリー集約 (`atg_atom_rt`)**:
   - `at_*` バスを 2/4-way パイプライン木で集約し、スパインの単一 `atg_mc_atom` (`NATOM = 1`) へ渡す。

*(※ `atg_su` 単体テスト `sim/run.sh atg_su` の既存互換を保つため、`atg_su` に `SHARED_PT = 0/1` パラメータを用意し、トップ統合時は `SHARED_PT = 1` を用いる。)*

### 6.2 Compute-Only 構成と将来 `SA` ノードの扱い

* **Compute-Only (`HAS_VF=0, HAS_RX=0, HAS_ROP=0, HAS_TU=0, HAS_DISP=0, HAS_BLT=0`)**:
  * `atg_top` 内で全グラフィックス固定機能と共有 `atg_su_pt`・グラフィックス分配/集約木を完全に生成抑止する（`atg_su` 内にも `HAS_GFX = 0/1` を設けて不要論理を削減可能）。
  * `atg_cp_caps` は `CORE1 = 0` を報告し、`CMD_DRAW*` 受信時は `atg_cp_seq` が `GHCI_FAULT_KIND_KICK_ABSENT` を返して Compute-Only Vulkan デバイスとして振る舞う。
* **将来の `SA`（Systolic Array / GEMM 専用加速機）**:
  * SU と 1:1 接続せず、**NoC 固定機能サブツリー内の独立クライアントノード** として `atg_rt` ポート枠を予約する（`HAS_SA = 0` の現状はスタブ、将来 CP が GEMM シェーダー／専用コマンドを検知した際に `SA` へディスパッチしてメモリ共有実行する設計と整合）。

---

## 7. コンフィグ・プリセット体系

設定重複を防ぐため、共通ベース定義 `config/base/*.mk` と薄いプリセット定義 `config/<name>.mk` の 2 層で構成する：

| 系列・プリセット名 | 用途 | インターコネクト | `MMU` / `CPU` / `PROT` | `VA / PA` | 主な機能ブロック |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`gfx-vulkan10-su{1,2,4,8,16,32,64,128}`** | Vulkan 1.0 Core + Compute 基準 | **統一ファットツリー** | ON (`1, 1, 1`) | `32 / 40`（可変） | `VF, RX(MSAA4x,EarlyZ), TU(Bilinear,3D/Array,FFILT), ROP(D24S8,FP16,sRGB,FBlend), BLT, DISP`, LDS=16KB |
| **`gfx-all-su{1,2,4,8,16,32,64,128}`** | 全拡張フル機能 | **統一ファットツリー** | ON (`1, 1, 1`) | `40 / 48` | `gfx-vulkan10` ＋ `MESH, BC, ETC2, ANISO, TRILINEAR, SEAMLESS_CUBE, ROP_PACK, D32F, LOGICOP` 等全有効（`SA=0` v1） |
| **`compute-su{1,2,4,8,16,32,64,128}`** | Compute 専用 Vulkan 構成 | **統一ファットツリー** | ON (`1, 1, 1`) | `40 / 48` | `VF=0, RX=0, TU=0, ROP=0, BLT=0, DISP=0, SA=0`, `SU` (FP16/Subgroup/SFU, LDS=16KB) |
| **`compute-fpga-test-minimal`** | FPGA 最小 Compute テスト | **クロスバー (`atg_mc_tree`)** | OFF (`0, 0, 0`) | `30(実効32) / 40` | `NSU=1`, `VF=RX=TU=ROP=BLT=DISP=0`, 最小キャッシュ |
| **`gfx-fpga-test-minimal`** | FPGA 最小 Graphics テスト | **クロスバー (`atg_mc_tree`)** | OFF (`0, 0, 0`) | `30(実効32) / 40` | `NSU=1`, 現行 `minimal.mk` 相当（最小 `VF, RX, TU, ROP, DISP=1`） |

`Makefile` および `include/atg_config.vh` へ `CFG_HAS_VF`, `CFG_HAS_RX`, `CFG_HAS_TU`, `CFG_HAS_ROP`, `CFG_HAS_DISP`, `CFG_USE_NOC_FABRIC`, `CFG_NSU` を追加し、`make CFG=<preset>` または `make preset-<name>` で切り替え可能にする。

---

## 8. 段階的実装ロードマップと検証ゲート

各フェーズごとに単体・結合シミュレーション、`arith-lint`（0 件）、Yosys `SYNTH_ASIC` (`cmos3` ルール) を確認しながら進める：

1. **Phase 1: アドレス幅可変 ＋ `atg_mmu` 統合（既存クロスバー構成上で検証）**
   - `VA_BITS`/`PA_BITS` 全モジュール展開（`atg_cp_ring` `RING_BASE_HI` 含む）。
   - `atg_mmu` 一般化、`atg_cpu_win` `0x38..0x3D` 実装、`am_mmu_bridge` 構築、`fw/cp/mmu.c` 64-bit PTE 整合。
   - 検証: `atg_mmu`, `atg_top_*` 既存回帰 ＋ 新規 `atg_top_mmu` TB PASS。
2. **Phase 2: 統一ファットツリー NoC 基盤 (`atg_rt2/3/4`, `atg_rep`, `atg_atom_rt`)**
   - 拡張フリット定義、`am_amb_to_rt` 更新、`am_skid` 内蔵 `atg_rt2/3/4`、`atg_rep`、`atg_mc` の `USE_NOC_FABRIC` 切替、`CP`/`DC` 根元接続。
   - 検証: `atg_rt*`, `atg_rep`, `atg_mc` 単体 TB ＋ `NSU=1,2` ファットツリー版 `atg_top` 回帰。
3. **Phase 3: 全 SU グラフィックス両用化（共有 Spine `PT` ＋ 分配/集約木）**
   - `SHARED_PT = 1` 対応の `atg_su` / 共有 `atg_su_pt`、`atg_warp_dist`、`atg_gfx_rt`。
   - 検証: `atg_su` 既存 TB（`SHARED_PT=0`）＋ マルチ SU 描画結合 TB（`NSU=2,4` で `atg_top_raster`/`atg_top_tex` 相当 PASS）。
4. **Phase 4: `atg_su_fabric_n1..n128` 実装 ＋ 26 プリセット構成整備**
   - 8 個の個別ファブリックファイル、26 個の `config/*.mk`、`Makefile` / `menuconfig.py` 対応。
   - 検証: Compute-Only TB、`NSU=1,2,4,8` 動作 sim、全 `N=1..128` Verilator Lint / Yosys Elaboration PASS。
5. **Phase 5: Stage 1（ASIC 5nm 1.5 GHz `cmos3` 是正）完了サインオフ**
   - 残余モジュール（`atg_su_opd`, `am_fpu_core`, `atg_cp_ring`, `atg_su_dcache/icache` 等）および新規 NoC/MMU 論理に対し Yosys `minimal` (`gfx-fpga-test-minimal` / `compute-fpga-test-minimal`) & `high-perf`（`gfx-vulkan10-su*` / `gfx-all-su*`）監査を通過させ、全テストベンチ 100% PASS を達成する。
