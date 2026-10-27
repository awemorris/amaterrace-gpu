# Amaterrace GPU 可変アドレス空間アーキテクチャ仕様書
## （内部 30〜40bit / 外部 40〜48bit / LSB 削減配線 / 偶数レジスタペア）

- **文書バージョン**: 1.0.0
- **策定日**: 2026-10-27
- **対象ハードウェア**: Amaterrace GPU (Kintex-7 KC705 評価ボード / 今後の ASIC・大規模 FPGA 展開)
- **ステータス**: 承認済みアーキテクチャ仕様 (Approved Specification)

---

## 1. エグゼクティブサマリ & 全体アーキテクチャ思想

Amaterrace GPU は、パーソナルワークステーションから組み込み・産業用までを射程に入れたプログラマブル 3D/コンピュート GPU である。
現代の 64 ビット OS（Linux, FreeBSD, zedBSD 等）において、ホストシステムメモリ（RAM）は 4 GiB の境界を日常的に超え、64 ビット DMA アドレスが標準的に割り当てられる。一方、GPU 内部のローカルメモリ（VRAM）やオンチップインターコネクトにおいて無条件に 64 ビット完全幅の信号線を配線することは、FPGA（Xilinx 7 シリーズ等）におけるルーティング混雑（Routing Congestion）、配線遅延の増大、フリップフロップ・LUT・BRAM リソースの浪費を招く。

本仕様では、以下の 4 本柱からなる**「可変アドレス空間 & LSB 削減配線 & 偶数レジスタペア」**アーキテクチャを採用し、**「外部 64 ビット完全親和性」**と**「内部ハードウェア極限軽量化」**を両立する。

```
+---------------------------------------------------------------------------------------+
|  Host System Memory (x86-64 / AArch64 / RV64)                                         |
|  Physical Address (PA): 40〜48-bit (1 TiB 〜 256 TiB)                                 |
+---------------------------------------------------------------------------------------+
                                  ▲
                                  │ PCIe Gen2 x4 (64-bit AXI AXI-MM Container)
                                  ▼
+---------------------------------------------------------------------------------------+
|  PCIe Host Bridge / DMA Engine (boards/kc705/lib/atg_kc705_pcie.v)                    |
|  - AXI Address Container: 64-bit [63:0] (上位ビットゼロパディング)                    |
|  - 有効物理アドレス幅: PA_BITS (40〜48 ビット)                                         |
+---------------------------------------------------------------------------------------+
                                  ▲
                                  │ Host Aperture (PA: 40〜48-bit)
                                  ▼
+---------------------------------------------------------------------------------------+
|  Amaterrace GPU Core Top (atg_top.v)                                                  |
|                                                                                       |
|  [GPU Virtual Address (VA): 30〜40-bit]                                               |
|  - SU / VF / TU / ROP / BLT 内部仮想空間 (1 GiB 〜 1 TiB, 既定 32-bit: 4 GiB)        |
|                                                                                       |
|  +---------------------------+       +---------------------------------------------+  |
|  | Shader Unit (atg_su)      |       | MMU & Page Table Walker (atg_mmu)           |  |
|  | - 32-bit Register File    |       | - 4 KiB ページ (下位 12-bit オフセット非変換)|  |
|  | - 偶数レジスタペア        |──────>| - VPN: [VA_BITS-1:12] (18〜28 ビット CAM)   |  |
|  |   r[2k]:r[2k+1] (64-bit)  |       | - PTE: 64-bit 標準フォーマット              |  |
|  +---------------------------+       | - PPN: [PA_BITS-1:12] (28〜36 ビット)       |  |
|                                      +---------------------------------------------+  |
|                                                             │                         |
|  [LSB 削減バス構造]                                         ▼                         |
|  - Dword バス: [VA_BITS-1:2] 伝送 (下位 2-bit 省略 + wstrb[3:0] 併送)                 |
|  - Line バス:  [VA_BITS-1:6] 伝送 (下位 6-bit 省略 + 64B キャッシュ整列)              |
|                                                                                       |
+---------------------------------------------------------------------------------------+
```

---

## 2. アドレス空間の階層定義

### 2.1 外部ホスト物理アドレス空間（Host PA）: 40〜48 ビット可変
- **定義**: ホストのメインメモリを DMA アクセス（リングバッファ読出し、フェンス書戻し、テクスチャ/頂点ストリーミング等）する際に使用される物理アドレス。
- **ビット幅**: `PA_BITS`（40〜48 ビット可変、KC705 既定値: 40 ビット = 1 TiB アドレス空間）。
- **AXI コンテナ**: 外部 AXI ポート（`m_awaddr`, `m_araddr`）は業界標準の 64 ビット幅（`[63:0]`）を採用。上位 `[63:PA_BITS]` は 0 にパディングする。
- **ホスト OS 親和性**: Linux の `dma_alloc_coherent()` 等が 4 GiB 境界を超える高位アドレス（`0x0000_0001_0000_0000` 以上）を返却しても、上位 32 ビットが切り捨てられることなく完全透過に通信可能。

### 2.2 内部仮想アドレス空間（GPU VA）: 30〜40 ビット可変
- **定義**: GPU シェーダ（SU）、頂点フェッチャ（VF）、テクスチャユニット（TU）、ラスタライザ（RX）、レンダーバックエンド（ROP）、ブリッター（BLT）が取り扱う仮想アドレス空間。
- **ビット幅**: `VA_BITS`（30〜40 ビット可変、KC705 既定値: 32 ビット = 4 GiB 空間）。
- **スケーラビリティ**:
  - 組み込み / 小型 FPGA: `VA_BITS = 30`（1 GiB、配線最小化）
  - KC705 (Kintex-7): `VA_BITS = 32`（4 GiB、現行システム整合）
  - 大規模 FPGA / 将来 ASIC: `VA_BITS = 40`（1 TiB、大規模 VRAM・統一メモリ対応）

### 2.3 内部配線の LSB（下位ビット）削減原則
物理配線層において、自明なゼロビットや冗長ビットを排除することで、FPGA の配線リソース（Interconnect Routing Fabric）の消費を 15〜25% 抑制する。

1. **ワード（Dword, 32-bit）単位インターコネクト**:
   - 下位 2 ビット（`[1:0]`）を物理配線から省略。
   - 実配線幅: `[VA_BITS-1:2]`（`VA_BITS = 32` のとき 30 ビット）。
   - サブワードアクセス（Byte / Halfword）は、4 ビットのバイトイネーブル（`wstrb[3:0]` / `be[3:0]`）を併送することで完全担保。
2. **キャッシュライン（Line, 64-byte）単位インターコネクト**:
   - 下位 6 ビット（`[5:0]`）を物理配線から省略。
   - 実配線幅: `[VA_BITS-1:6]`（`VA_BITS = 32` のとき 26 ビット）。
   - L2 キャッシュ、メモリコントローラ（MC）、TLB 間の転送はすべて 64 バイト整列で行われるため、情報欠損はゼロ。

---

## 3. MMU / ページテーブル / TLB アーキテクチャ

### 3.1 ページサイズとオフセットバイパス
- **ページサイズ**: 標準 4 KiB（12 ビットページオフセット: `[11:0]`）。
- 下位 12 ビットはアドレス変換の影響を受けず、仮想アドレスから物理アドレスへそのまま透過（Bypass）する。
- したがって、MMU および TLB の変換対象は**上位ビットのみ**となる。

### 3.2 TLB CAM（Content Addressable Memory）比較器の軽量化
- **VPN (Virtual Page Number)**:
  $$\text{VPN 幅} = \text{VA\_BITS} - 12$$
  - `VA_BITS = 30`: 18 ビット
  - `VA_BITS = 32`: 20 ビット
  - `VA_BITS = 40`: 28 ビット
- 64 ビット完全長を比較する場合（52 ビット比較器）に比べ、比較回路の LUT 数が半分以下となり、L1/L2 TLB のクリティカルパス遅延を大幅に削減。

### 3.3 64 ビット標準 PTE（Page Table Entry）フォーマット
メモリ上に配置されるページテーブルエントリ（PTE）は、将来の 64 ビット OS・アーキテクチャ標準に準拠した **8 バイト（64 ビット）標準アライメント**とする。

```
 63       PA_BITS          12 11     8 7   6   5   4   3   2   1   0
+------------+---------------+--------+---+---+---+---+---+---+---+---+
|  Reserved  |      PPN      | RSVD/  | G | U | A | D | X | W | L | V |
|  (All 0)   | [PA_BITS-1:12]| Soft   |   |   |   |   |   |   |   |   |
+------------+---------------+--------+---+---+---+---+---+---+---+---+
```

- `V` (bit 0): Valid（有効ビット）
- `L` (bit 1): Local（0: ホストメモリ, 1: ローカル DDR3/DDR4）
- `W` (bit 2): Writable（書込み許可）
- `X` (bit 3): Executable（命令フェッチ許可）
- `D` (bit 4): Dirty（書込み発生フラグ）
- `A` (bit 5): Accessed（参照フラグ）
- `U` (bit 6): User（ユーザ空間アクセス許可）
- `G` (bit 7): Global（ASID フラッシュ免除）
- `PPN` (`[PA_BITS-1:12]`): 物理ページ番号。
  - `PA_BITS = 40` の場合: `PPN = [39:12]`（28 ビット）。ビット `[63:40]` は 0 予約。
  - `PA_BITS = 48` の場合: `PPN = [47:12]`（36 ビット）。ビット `[63:48]` は 0 予約。

---

## 4. シェーダ（SU / GSI1）におけるポインタ表現（偶数レジスタペア）

### 4.1 32 ビット単一幅レジスタファイルの維持
NVIDIA（CUDA/PTX）、AMD（GCN/RDNA）、Intel（Xe）などの主要 GPU アーキテクチャと同様に、**物理汎用レジスタ（GPR）は 32 ビット幅を厳格に維持**する。レジスタ幅を 64 ビットに拡張することは、シリコン面積および FPGA の分散 RAM/BRAM リソースを倍増させ、大半の 32 ビット浮動小数点（fp32）・整数演算において半分のビットが無駄になるため採用しない。

### 4.2 偶数レジスタペアによる 64 ビットポインタ表現
64 ビットアドレス（広域ポインタ）を取り扱う命令（`LOAD64`, `STORE64`, `ATOMIC64`, `GLOBAL_LOAD` 等）では、**偶数レジスタ番号 $2k$** を指定することで、隣接する奇数レジスタ $2k+1$ と結合したペアレジスタとして扱う。

$$\text{Address}[63:0] = \{ r[2k+1][31:0],\; r[2k][31:0] \}$$

- **下位 32 ビット**: $r[2k]$（偶数レジスタ: ベースアドレス下位）
- **上位 32 ビット**: $r[2k+1]$（奇数レジスタ: ベースアドレス高位、最大 `PA_BITS-1` まで有効）

### 4.3 ポート数増加ゼロのハードウェア的根拠
レジスタペア読出しのためにレジスタファイルの読出しポートを増設（2 ポート $\to$ 4 ポート化等）すると、BRAM/分散 RAM の多重化やクロック周波数低下を招く。本アーキテクチャでは以下のハードウェア特性により、**既存の 2 読出しポート構成をそのまま維持**する。

1. **Load 命令のアドレス生成特性**:
   - `LOAD` 命令が必要とするオペランドは「メモリアドレス」のみである。
   - 既存のレジスタファイルは 1 命令あたり 2 ソースオペランド（`src0`, `src1`）を同時読出し可能。
   - したがって、`src0` に $r[2k]$、`src1` に $r[2k+1]$ を割り当てるだけで、**追加ポートなしに 1 サイクルで 64 ビットアドレスを同時読出し**可能。
2. **Store 命令のバンク時間多重**:
   - `STORE` 命令ではアドレス（64-bit）と書込みデータ（32-bit または 64-bit）が必要となる。
   - Amaterrace GPU の Shader Unit（SU）は、1 ワープを複数サイクル（サブグループ実行: 例 NPHYS=8, NWARPS=4 で 4 サイクル実行）かけてパイプライン処理する。
   - オペランドコレクタ（Operand Collector）がサイクル 0 でアドレスペア $\{r[2k+1], r[2k]\}$ を読み出し、サイクル 1 で書込みデータ $r[\text{data}]$ を読み出す時間多重（Time-Multiplexing）を行うため、物理ポートの追加は一切不要。
3. **偶奇バンク（Even/Odd Banking）構造**:
   - 物理レジスタファイルを「偶数レジスタバンク（Bank 0）」と「奇数レジスタバンク（Bank 1）」に 2 分割配置。
   - 偶数レジスタと奇数レジスタは常に異なる独立した BRAM/分散 RAM メモリブロックにマップされるため、バンク衝突（Bank Conflict）が構造的に発生せず、1 サイクル並列アクセスが保証される。

---

## 5. コンフィグパラメータの追加・変更一覧

プロジェクト設定（`config.mk`）、自動生成ヘッダ（`include/atg_config.vh`）、およびトップモジュール（`atg_top.v`）に追加・統合されるパラメータ体系を以下に示す。

### 5.1 コンフィグレーション・マクロ定義 (`include/atg_config.vh`)
```verilog
/* Address Space Architecture Configuration */
`define CFG_GPU_VA_BITS      32        /* GPU Virtual Address Width: 30..40 (Default: 32) */
`define CFG_HOST_PA_BITS     40        /* Host Physical Address Width: 40..48 (Default: 40) */
`define CFG_LINE_BYTES       64        /* Cache Line Size: 64 bytes */
`define CFG_LINE_SHIFT       6         /* log2(CFG_LINE_BYTES) = 6 */
`define CFG_PAGE_BYTES       4096      /* Virtual Page Size: 4 KiB */
`define CFG_PAGE_SHIFT       12        /* log2(CFG_PAGE_BYTES) = 12 */

/* Derived Bus Widths (LSB Reductions) */
`define CFG_DWORD_ADDR_BITS  (`CFG_GPU_VA_BITS - 2)   /* Word-addressed bus width (30-bit) */
`define CFG_LINE_ADDR_BITS   (`CFG_GPU_VA_BITS - 6)   /* Line-addressed bus width (26-bit) */
`define CFG_VPN_BITS         (`CFG_GPU_VA_BITS - 12)  /* Virtual Page Number width (20-bit) */
`define CFG_PPN_BITS         (`CFG_HOST_PA_BITS - 12) /* Physical Page Number width (28-bit) */
```

### 5.2 `menuconfig` / ビルドシステム連携 (`tools/menuconfig.py`, `config.mk.template`, `Makefile`)

TUI / CLI コンフィグレーションツール `tools/menuconfig.py`、プロジェクト設定テンプレート `config.mk.template`、およびビルドシステム `Makefile` に以下の項目を追加し、対話的設定および自動ヘッダ生成を行う。

#### 1. `tools/menuconfig.py` 項目定義

**A. アドレス空間設定 (Section 5: CP & Memory)**:
- **`CONFIG_GPU_VA_BITS`**:
  - **Type**: `choice` (`["30", "32", "36", "40"]`), **Default**: `"32"`
  - **Label**: `"GPU Virtual Address Width (VA_BITS)"`
  - **Help**: `"Internal GPU virtual address representation width in bits (30..40, 1 GiB to 1 TiB). 32 bits = 4 GiB."`
- **`CONFIG_HOST_PA_BITS`**:
  - **Type**: `choice` (`["40", "44", "48"]`), **Default**: `"40"`
  - **Label**: `"Host Physical Address Width (PA_BITS)"`
  - **Help**: `"Host physical address width for PCIe DMA in bits (40..48, 1 TiB to 256 TiB). 40 bits = 1 TiB."`

**B. テクスチャ圧縮 & 高度サンプリング (Section 3: Texture Unit)**:
- **`CONFIG_TU_ENABLE_BC`**: `bool` (既定: 0) — Block Compression (BC1-BC7) デコンプレッサ
- **`CONFIG_TU_ENABLE_ETC2`**: `bool` (既定: 0) — ETC2 / EAC テクスチャデコンプレッサ (フォーマット 147..156)
- **`CONFIG_TU_ENABLE_ANISO`**: `bool` (既定: 0) — 異方性フィルタリング (最大 16x EWA)
- **`CONFIG_TU_ENABLE_SEAMLESS_CUBE`**: `bool` (既定: 0) — シームレスキューブマップ境界補間
- **`CONFIG_TU_ENABLE_FP_FILTER`**: `bool` (既定: 0) — 浮動小数点テクスチャフィルタリング (FP16/FP32, `DEVICE_CAPS[25]`)
- **`CONFIG_TU_ENABLE_ARRAY`**: `bool` (既定: 0) — 1D/2D テクスチャ配列レイヤアドレッシング

**C. イメージ・フォーマット & レンダーターゲット形式 (Section 4: ROP & Formats)**:
- **`CONFIG_FMT_ENABLE_FP16`**: `bool` (既定: 0) — 16-bit 浮動小数点カラー形式 (R16F, RGBA16F)
- **`CONFIG_FMT_ENABLE_FP32`**: `bool` (既定: 0) — 32-bit 浮動小数点カラー形式 (R32F, RGBA32F)
- **`CONFIG_FMT_ENABLE_SRGB`**: `bool` (既定: 1) — sRGB ハードウェアガンマ変換 & フレームバッファ
- **`CONFIG_FMT_ENABLE_RGB565`**: `bool` (既定: 1) — 16-bit パックドカラー形式 (RGB565, RGBA4, ARGB1555)
- **`CONFIG_FMT_ENABLE_DEPTH24_S8`**: `bool` (既定: 1) — 24-bit 深度 / 8-bit ステンシル (D24_UNORM_S8_UINT)
- **`CONFIG_FMT_ENABLE_DEPTH32F`**: `bool` (既定: 0) — 32-bit 浮動小数点高精度深度 (D32_SFLOAT)
- **`CONFIG_FMT_ENABLE_DEPTH16`**: `bool` (既定: 1) — 16-bit 深度 (D16_UNORM)

#### 2. `config.mk.template` への追加
```makefile
# ==============================================================================
# Address Space & Interconnect Configuration
# ==============================================================================
# GPU Virtual Address Width in bits: 30 (1 GiB), 32 (4 GiB), 36 (64 GiB), 40 (1 TiB)
CONFIG_GPU_VA_BITS ?= 32

# Host Physical Address Width for PCIe DMA in bits: 40 (1 TiB), 44 (16 TiB), 48 (256 TiB)
CONFIG_HOST_PA_BITS ?= 40

# Texture Compression & Advanced Features
CONFIG_TU_ENABLE_BC            ?= 0
CONFIG_TU_ENABLE_ETC2          ?= 0
CONFIG_TU_ENABLE_ANISO         ?= 0
CONFIG_TU_ENABLE_SEAMLESS_CUBE ?= 0
CONFIG_TU_ENABLE_FP_FILTER     ?= 0
CONFIG_TU_ENABLE_ARRAY         ?= 0

# Image Formats & Attachments
CONFIG_FMT_ENABLE_FP16         ?= 0
CONFIG_FMT_ENABLE_FP32         ?= 0
CONFIG_FMT_ENABLE_SRGB         ?= 1
CONFIG_FMT_ENABLE_RGB565       ?= 1
CONFIG_FMT_ENABLE_DEPTH24_S8   ?= 1
CONFIG_FMT_ENABLE_DEPTH32F     ?= 0
CONFIG_FMT_ENABLE_DEPTH16      ?= 1
```

#### 3. `Makefile` による自動ヘッダ生成連携
`Makefile` の `include/atg_config.vh` 生成ルールにおいて、以下のコンパイルフラグおよびマクロ定義を出力：
```makefile
# include/atg_config.vh 生成ルールへの反映
echo "\`define CFG_GPU_VA_BITS $(CONFIG_GPU_VA_BITS)" >> $@
echo "\`define CFG_HOST_PA_BITS $(CONFIG_HOST_PA_BITS)" >> $@
# TU & FMT マクロ出力連携
```

### 5.3 トップモジュール (`atg_top.v`) パラメータシグネチャ
```verilog
module atg_top #(
    parameter [31:0] GCLK_HZ      = 32'd100000000,
    parameter S_ID_W              = 12,
    parameter S_LEN_W             = 4,
    parameter LINE_BYTES          = 64,
    parameter LINE_SHIFT          = 6,
    parameter DATA_W              = 512,

    /* --- 新規追加: アドレス空間パラメータ --- */
    parameter VA_BITS             = 32,  /* 内部仮想アドレス幅 (30..40) */
    parameter PA_BITS             = 40,  /* 外部ホスト物理アドレス幅 (40..48) */
    parameter HOST_LIMIT_PA       = 40,  /* ホスト DMA 境界チェック幅 */
    ...
) (
    input wire clk,
    input wire rst_n,
    ...
    /* ホストレジスタスレーブポート (BAR0): 64-bit 固定化済み */
    input wire [63:0]             s_wdata,
    input wire [7:0]              s_wstrb,
    output wire [63:0]            s_rdata,

    /* メモリマスタポート (AXI4 Master to Memory/Interconnect) */
    output wire [63:0]            m_awaddr,  /* 64-bit コンテナ (上位はゼロパディング) */
    output wire [63:0]            m_araddr,  /* 64-bit コンテナ (上位はゼロパディング) */
    ...
);
```

---

## 6. ブロック別・モジュール別の変更詳細仕様

### 6.1 `atg_top.v` およびメモリインターコネクト (`am_axi_split`, `atg_mc`)
- **AXI アドレスバスの 64-bit コンテナ化**:
  - `m_awaddr`, `m_araddr` を `[63:0]` で宣言。
  - 内部メモリコントローラ（`atg_mc`）から出力された `[PA_BITS-1:0]` アドレスを上位ゼロ拡張：
    ```verilog
    assign m_awaddr = { {(64-PA_BITS){1'b0}}, mc_awaddr[PA_BITS-1:0] };
    assign m_araddr = { {(64-PA_BITS){1'b0}}, mc_araddr[PA_BITS-1:0] };
    ```
- **`am_axi_split.v`**:
  - ホストメモリ空間（Aperture: `[0, HOST_LIMIT)`) とローカル DDR3 空間（`[LOCAL_BASE, +LOCAL_BYTES)`) のデコードアドレス判定器を `PA_BITS` パラメータ化。

### 6.2 コマンドプロセッサ (`atg_cp`)
- **`atg_cp_ring.v` (Command Ring)**:
  - `RING_BASE_LO` (0x020) と `RING_BASE_HI` (0x024) を内部で 64 ビットレジスタ `ring_base_pa[63:0]` としてラッチ。
  - ホストメモリからリングコマンドパケットをフェッチする AXI AR アドレス生成：
    $$\text{fetch\_araddr} = \text{ring\_base\_pa}[PA\_BITS-1:0] + \{\text{rptr},\, 2'b00\}$$
    （加算は `rtl/library/arith/am_add.v` を経由）。
- **`atg_cp_fence.v` (Fence DMA)**:
  - `CMD_FENCE` で指定される 64 ビットホスト通知先アドレスをそのまま保持し、上位 `PA_BITS` 幅でホスト DMA 書込みを発行。
- **`atg_cp_regs.v` (Host Registers)**:
  - 64 ビット化された BAR0 スレーブポート（`am_axi_regs.v`）と連動し、`RING_BASE` や `FAULT_ADDR` の 64 ビット読み出しを 1 回の AXI リード（2 サイクルフェッチ）で完全にサポート。

### 6.3 仮想記憶ユニット (`atg_mmu`, `atg_tlb_l1`, `atg_tlb_l2`)
- **TLB タグ比較器 (`atg_tlb_*.v`)**:
  - タグ幅を `VA_BITS - 12`（VPN 幅）にパラメータ化。
  - キャッシュラインオフセット・ページ内オフセットを比較から完全除外。
- **ページテーブルウォーカー (`atg_mmu_walker.v`)**:
  - 64 ビット PTE フォーマットのパース：
    ```verilog
    wire pte_v     = pte_data[0];
    wire pte_local = pte_data[1];
    wire pte_w     = pte_data[2];
    wire pte_x     = pte_data[3];
    wire [PA_BITS-1:12] pte_ppn = pte_data[PA_BITS-1:12];
    ```
  - 変換後物理アドレス合成：
    $$\text{PA}[PA\_BITS-1:0] = \{ \text{pte\_ppn}[PA\_BITS-1:12],\; \text{va}[11:0] \}$$

### 6.4 シェーダユニット (`atg_su`)
- **レジスタファイル (`atg_su_rf.v`)**:
  - 32 ビット幅 $\times$ 64 エントリ構成を維持。
  - 偶数アドレス `ra[5:0] = {idx[5:1], 1'b0}` と奇数アドレス `ra+1 = {idx[5:1], 1'b1}` の同時読出しを可能にする偶奇 2 バンク構造を採用。
- **LSU (Load/Store Unit, `atg_su_lsu.v`)**:
  - ポインタアドレスを `[VA_BITS-1:0]` として受領。
  - Dword アライメントバスへ出力する際、下位 2 ビットをマスクし、実配線 `lsu_addr[VA_BITS-1:2]` と `lsu_be[3:0]` を出力。

### 6.5 固定機能パイプライン (`atg_tu`, `atg_vf`, `atg_rop`, `atg_blt`)
- **テクスチャユニット (`atg_tu`)**:
  - サンプラ記述子内のベースアドレスを `VA_BITS` に追従。
  - キャッシュフェッチアドレスは下位 6 ビット（テクセルライン）を排した Line アドレス `[VA_BITS-1:6]` で TU キャッシュに要求。
- **頂点フェッチャ (`atg_vf`)**:
  - 頂点バッファの `ATTR_BASE` を `VA_BITS` 幅で保持。
- **レンダーバックエンド (`atg_rop`) & ブリッター (`atg_blt`)**:
  - レンダーターゲットベースアドレス（`RT_BASE[0..7]`）およびブリット転送先・転送元アドレスを `VA_BITS` 幅でハンドリング。

### 6.6 KC705 ボード階層 (`boards/kc705`)
- **`boards/kc705/atg_kc705_top.v`**:
  - PCIe ブリッジ（`atg_kc705_pcie`）と `atg_top` を接続する GPU $\to$ Host メモリマスタバス（`h_awaddr`, `h_araddr`）を 64 ビット化（`[63:0]`）。
- **`boards/kc705/lib/atg_kc705_pcie.v`**:
  - Xilinx AXI Bridge for PCI Express の `s_axi` スレーブインターフェース接続を 64 ビットアドレス対応に更新。
- **`boards/kc705/ip.tcl`**:
  - `atg_kc705_pcie_ip`（AXI Memory Mapped To PCI Express IP）のコンフィグレーションにおいて、ホスト DMA の 64 ビット空間アクセスを許可：
    ```tcl
    CONFIG.AXIBAR_AS_0 {true} \
    CONFIG.AXIBAR_0 {0x0000000000000000} \
    CONFIG.AXIBAR_HIGHADDR_0 {0xFFFFFFFFFFFFFFFF}
    ```
  - `atg_kc705_host_dn`（Data Width Converter）の `CONFIG.ADDR_WIDTH 64` 設定。

### 6.7 ソフトウェア・ドライバ・ヘッダ互換性 (`include/ghci_*.h`, `docs/ghci.md`)
- `include/ghci_regs.h` において、`RING_BASE`、`FAULT_ADDR` は既に `_LO` (0x020) と `_HI` (0x024) に分割定義されており、レジスタレイアウトの破壊的変更は不要（**完全な下位バイナリ互換を維持**）。
- 64 ビット PTE 構造体定義（C 言語ヘッダ）:
  ```c
  typedef struct {
      uint64_t v        : 1;   /* Valid */
      uint64_t local    : 1;   /* 1: VRAM, 0: Host System RAM */
      uint64_t writable : 1;   /* Write permission */
      uint64_t exec     : 1;   /* Execute permission */
      uint64_t dirty    : 1;   /* Dirty bit */
      uint64_t accessed : 1;   /* Accessed bit */
      uint64_t user     : 1;   /* User accessible */
      uint64_t global   : 1;   /* Global mapping */
      uint64_t rsvd_soft: 4;   /* OS Software bits */
      uint64_t ppn      : 36;  /* Physical Page Number (up to 48-bit PA) */
      uint64_t reserved : 16;  /* Reserved (must be zero) */
  } __attribute__((packed)) GhciPte64;
  ```

---

## 7. 段階的移行・実装・検証計画

本アーキテクチャへの移行は、既存機能の継続的動作（Regression Free）を保証するため、以下の 4 フェーズに分割して推進する。

| フェーズ | 対象領域 | 主要タスク | 検証・ゲート基準 |
|:---|:---|:---|:---|
| **Phase A**<br>(基盤・設定) | コンフィグ & 定義層 | - `tools/menuconfig.py` に `CONFIG_GPU_VA_BITS`, `CONFIG_HOST_PA_BITS` および各種テクスチャ圧縮・イメージ形式選択肢追加<br>- `config.mk.template` および `Makefile` への自動生成ルール追加<br>- `include/atg_config.vh` にアドレス幅・フォーマットマクロ追加<br>- `docs/ghci.md` およびヘッダの PTE 定義同期 | - `python3 tools/menuconfig.py --show` 正当性確認<br>- `tools/arith-lint.py` 0 違反<br>- `tools/lint.sh` 全通過 |
| **Phase B**<br>(CP & ホスト DMA) | コマンドプロセッサ & PCIe | - `atg_cp_ring.v` の 64-bit PA フェッチ実装<br>- `atg_cp_fence.v` の 64-bit 書戻し対応<br>- `atg_kc705_pcie.v` の 64-bit AXI 接続拡張<br>- `ip.tcl` の 64-bit アドレス設定 | - `atg_kc705_pcie_tb` PASS<br>- 4 GiB 超高位アドレス DMA テスト PASS |
| **Phase C**<br>(MMU & 内部 LSB 削減) | 仮想記憶 & バス層 | - `atg_mmu` 64-bit PTE 展開<br>- TLB CAM の VPN 幅（`VA_BITS-12`）最適化<br>- ワードバス（-2bit）/ ラインバス（-6bit）配線適用 | - `atg_mmu_tb`, `atg_top_tb` PASS<br>- 配線 LUT 使用量削減の確認 |
| **Phase D**<br>(SU & パイプライン) | シェーダ & 固定機能 | - `atg_su_rf.v` 偶数レジスタペア読出し論理の検証<br>- LSU 64-bit ポインタ処理<br>- `atg_tu` / `atg_vf` アドレス幅追従 | - 全ユニットテスト・シーンテスト PASS<br>- Vivado 合成・インプリタイミング検証 |

---

## 8. まとめ

本仕様の採用により、Amaterrace GPU は以下の利点を獲得する：

1. **実用的 64-bit ホスト完全親和**: ホスト OS の 64 ビット DMA アドレス（4 GiB 超）へ完全対応し、実機 PC での PCIe プラグ＆プレイを保証。
2. **ハードウェアリソースの最小化**: 内部アドレス幅の可変設定（既定 32 ビット）と LSB 削減配線により、FPGA の配線混雑と LUT 消費を大幅に抑制。
3. **レジスタファイルの面積効率維持**: 32 ビット汎用レジスタファイルと偶数レジスタペア機構により、ポート増設ゼロで 64 ビットアドレッシングを実現。
4. **バイナリ互換性の維持**: GHCI 1.0 のレジスタ定義およびコマンドパケット仕様を完全に踏襲し、既存ソフトウェア・ドライバとの互換性を堅持。
