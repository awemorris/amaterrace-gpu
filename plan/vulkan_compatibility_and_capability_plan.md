<!-- awesome-plan project=amaterrace-gpu record=vulkan_compatibility_and_capability_plan -->

# Amaterrace GPU: Vulkan 互換 API 移行及びモジュール Capability 化計画書

**文書管理番号**: `AP-DOC-20261027-VULKAN-CAPS`  
**対象プロジェクト**: Amaterrace GPU (`ATG1`)  
**作成エージェント**: D1 (Documentation Subagent)  
**ステータス**: レビュー待ち計画資料（Proposal for User Review）  

---

## 1. エグゼクティブサマリー & 背景方針

### 1.1 背景：現実的な FPGA 制約と Vulkan の乖離
従来の設計思想では「Vulkan 1.0 適合（Conformance）」を意識した仕様策定が進められていました。しかしながら：
1. **FPGA リソースの壁**: Vulkan 1.0 の厳密な CTS（Conformance Test Suite）パスには、広範なテクスチャ形式、高精度例外、全サンプリングモード（MSAA 4x 等）、各種ブレンディングモードが必須とされ、低〜中価格帯の FPGA（Xilinx Artix-7 35T/50T/100T、Gowin、Efinix、iCE40 等）ではリソース枯渇（LUT/BRAM/DSP不足）を招きます。
2. **OS / ソフトウェアスタックの実態**:
   - ディスプレイ制御において、ドライバは Vulkan 1.1 の拡張である `VK_KHR_display` を使用してフレームバッファやスキャンアウトを制御しています。
   - 一方で OS 側は Vulkan 1.0 のマクロをエクスポートするなど、実運用環境自体が厳密な「Vulkan 1.0 単一適合」とは乖離しています。

### 1.2 基本方針の転換
* **「Vulkan 適合（Conformance）」から「Vulkan 互換 API（Compatible API）」へ**:
  * 厳格な CTS 適合の標榜を取り下げ、**Vulkan 互換 API（Vulkan-Compatible API）** として位置付けます。
  * ハードウェアに実装されている機能は、標準 Vulkan API（`vkCreateGraphicsPipelines`, `vkCmdDraw`, `vkQueueSubmit`, `vkCmdCopyBuffer` 等）経由で 100% 正常に利用可能とします。
  * ドライバおよび OS は、GHCI の Capability レジスタ（`DEVICE_CAPS`, `CAPS`, `EXT_CAP_*`）をクエリし、サポートされている機能のみを Vulkan の `VkPhysicalDeviceFeatures` および `VkFormatProperties` として上位レイヤに公開します。
* **徹底的なモジュール Capability 化（オプション化）**:
  * コア（最小限描画に必要な機能）と、オプション（FPGA 規模に応じてビルド時に着脱可能な機能）を厳格に二分します。
* **SU 物理レーン数のスケーリング（4, 8, 16, 32 lanes）**:
  * GSI1 の論理 Warp 幅 32 スレッドを維持したまま、物理レーン数 `NPHYS` を **4, 8, 16, 32** から選択可能にします（デフォルト: 8）。
* **次世代シェーダ（Task / Mesh Shader）の Capability 化**:
  * `VK_EXT_mesh_shader`（Task Shader および Mesh Shader）をオプション Capability として位置づけ、将来の独立した Workstream（WS004）にてオプション実装します。
* **ビルド時一元設定（`config.mk`）の確立**:
  * すべてのパラメータと機能有効化フラグを `config.mk` で宣言し、Verilog の `parameter` / `define` および GHCI Capability レジスタに自動連動させます。

---

## 2. モジュール別コア（必須機能）／オプション（Capability）分類表

GPU の各ハードウェアブロックにおいて、描画パイプラインの動作を担保するための最小限「コア機能」と、ビルド時に除外・縮小可能な「オプション機能」を以下のように分類・定義します。

| ハードウェアブロック | コア機能（必須最小限 / Baseline Core） | オプション機能（ビルド時パラメータ / Capability） | 削減される FPGA リソース |
| :--- | :--- | :--- | :--- |
| **CP**<br>(Command Processor) | • 64-bit コマンドリングパーサ<br>• WPTR/RPTR ドアベル制御<br>• 割り込み (IRQ) & フェンス完了通知<br>• 単一グラフィックスキュー | • `CAP_HW_WALKER`: 自律 2 レベル MMU ページウォーカー<br>• `CAP_SECONDARY_RING`: セカンダリリング直接実行<br>• `CAP_INDIRECT_DRAW`: インダイレクト描画引数解決<br>• `CP_FIRMWARE`: RV32IM マイクロコードコア（超小型時は固定 FSM へ置換） | BRAM（マイクロコード用）<br>LUT（32-bit CPU 論理）<br>TLB 比較器群 |
| **SU**<br>(Shader Unit) | • GSI1 64-bit ISA デコード<br>• 32 スレッド論理 Warp 管理<br>• `NPHYS` スカラー PE（INT32, FP32 加算/乗算/FMA）<br>• 汎用レジスタファイル（スレッドあたり 32 本）<br>• 基本分岐 & PC 制御 | • `NPHYS`: 物理レーン数 [4, 8, 16, 32]<br>• `CAP_FP16` (`PACKED`): FP16×2 パックド演算<br>• `CAP_SUBGROUP`: スレッド間交換 (`shfl`, `vote`, `ballot`)<br>• `CAP_SFU`: ハードウェア超越関数 (`rcp`, `rsq`, `sin`, `cos`)<br>• `LDS_BYTES`: 共有メモリ (0KB, 1KB, 2KB, 4KB)<br>• `CAP_SA`: シストリック行列アクセラレータ接続<br>• `CAP_MESH_SHADER` / `CAP_TASK_SHADER`: VK_EXT Task & Mesh Shader（独立WS） | DSP48E1（大幅削減）<br>分散 RAM / BRAM<br>クロスバースイッチ論理 |
| **RX**<br>(Rasterizer) | • 三角形エッジ方程式算出 ($E_0, E_1, E_2$)<br>• ファインスキャン（ピクセル/クワッド生成）<br>• 透視変換補正重心座標補間 ($1/W$, UV, Z) | • `CAP_MSAA` (`MSAA_SAMPLES`): MSAA (1x, 2x, 4x)<br>• `CAP_EARLY_Z`: Hi-Z RAM による早期オクルージョン除外<br>• `CAP_COARSE_SCAN`: 階層型粗タイリング走査<br>• `CAP_WIDE_LINES` / `CAP_LARGE_POINTS`: 太線・点スプライト | BRAM（Hi-Z RAM）<br>乗算器/加算器（粗走査器）<br>サンプルマスク比較器 |
| **TU**<br>(Texture Unit) | • 2D テクスチャサンプリング（Nearest, Bilinear）<br>• 基本フォーマット（RGBA8, R8, RGB565）<br>• クランプ・リピートアドレッシング | • `CAP_TEX_TRILINEAR`: トライリニア & Mipmap 補間<br>• `CAP_TEX_BC`: テクスチャ圧縮デコーダ（BC1〜BC7）<br>• `CAP_TEX_3D_CUBE`: 3D ボリューム・キューブマップ<br>• `CAP_TEX_MSHR`: 非ブロッキング MSHR キャッシュ<br>• `TU_L1_BANKS`: キャッシュバンク数（1, 2, 4 バンク） | BRAM（テクスチャキャッシュ）<br>大量の LUT（BC 展開論理）<br>MSHR FIFO & 比較器 |
| **ROP**<br>(Render Output) | • レイト Z & ステンシルテスト<br>• 標準アルファブレンド（Src/Dst, Add/Sub）<br>• 単一カラーレンダーターゲット<br>• タイルライトバック | • `CAP_DUAL_SOURCE`: デュアルソースブレンディング (`Src1Color`/`Src1Alpha`)<br>• `CAP_LOGIC_OP`: 16 種類の Vulkan ビット演算 LogicOp<br>• `CAP_MRT`: マルチレンダーターゲット（2〜4 枚）<br>• `CAP_FAST_CLEAR`: 高速クリアメタデータ RAM<br>• `CAP_MSAA_RESOLVE`: 4 サンプルダウンサンプリング | BRAM（タイルバッファ）<br>LUT（ブレンダ・ロジック演算器）<br>ライト結合バッファ |
| **BLT**<br>(2D Blitter) | • 矩形メモリコピー & ソリッドカラークリア<br>• リニアバッファ DMA 転送 | • `CAP_BLT_SWIZZLE`: タイル配列 ↔ リニア相互変換<br>• `CAP_BLT_ALPHA_OVER`: 2D アルファ合成<br>• `CAP_BLT_PINGPONG`: デュアル Ping-Pong DMA バッファ | 内部 FIFO（BRAM/分散RAM）<br>アドレス計算用加算器 |
| **DC**<br>(Display Controller) | • リニアフレームバッファからのダイレクトスキャンアウト<br>• 基本ビデオタイミング生成（CEA/VESA）<br>• メモリアービタ優先度制御 (`dc_urgent`) | • `CAP_DC_HW_CURSOR`: ハードウェアカーソルプレーン<br>• `CAP_DC_COLOR_LUT`: ガンマ補正 / カラーパレット RAM<br>• `CAP_DC_MULTI_PLANE`: 複数オーバーレイプレーン合成 | BRAM（カーソル/パレット）<br>ピクセルクロックドメイン同期論理 |

---

## 3. SU（Shader Unit）物理レーン数のスケーリング設計

### 3.1 物理レーン数パラメータ（`NPHYS`）の設定範囲
GSI1 の命令セット仕様において、**論理 Warp 幅は 32 スレッド固定**です。  
ハードウェアが 1 命令（1 つの Warp）を実行するのに要するサイクル数 $G$ は次式で表されます：
$$G = \frac{32}{\text{NPHYS}}$$

本計画では、物理レーン数の設定可能範囲を **`[4, 8, 16, 32]`** と定義します（RTLデフォルト: 8）。

| NPHYS 設定 | 実行サイクル $G$ | スカラー PE 数 | DSP48E1 数 (FP32) | 想定ターゲット FPGA クラス | 備考 |
| :---: | :---: | :---: | :---: | :--- | :--- |
| **32** | 1 cycle | 32 lanes | 32 DSPs | ハイエンド FPGA (Kintex UltraScale+, Virtex-7) | フル並列、最大スループット |
| **16** | 2 cycles | 16 lanes | 16 DSPs | ミッドレンジ FPGA (Kintex-7 325T, Zynq-7030) | 高性能バランス型 |
| **8** | 4 cycles | 8 lanes | 8 DSPs | **現行標準構成 (Kintex-7 KC705, Artix-7 100T)** | デフォルト設定 |
| **4** | 8 cycles | 4 lanes | 4 DSPs | エントリー FPGA (Artix-7 50T, Gowin GW2A-55) | 1 クワッド単位同時実行 |

### 3.2 グループカウンタ幅（`GRP_W`）の導出
グループ幅 $GRP\_W = \lceil \log_2(32 / \text{NPHYS}) \rceil$ と定義します：
* `NPHYS = 32`: `GRP_W = 1`（0固定）
* `NPHYS = 16`: `GRP_W = 1`
* `NPHYS = 8`: `GRP_W = 2`
* `NPHYS = 4`: `GRP_W = 3`

`atg_su.v` および `atg_su_lane.v` 等の内部バス・カウンタは `GRP_W` に従って自動導出されます。全設定において 2×2 ピクセルクワッド（4 スレッド）が単一サイクルまたは 2 サイクル内で完結するため、クワッド微分（`qd`: $ddx, ddy$）もシンプルかつ高効率に処理されます。

---

## 4. ビルド時設定メカニズム（`config.mk`）のアーキテクチャ設計

### 4.1 ディレクトリ構成と設定フロー
```
amaterrace-gpu/
├── config.mk.template        # 全設定項目のテンプレート・ドキュメント付き初期設定
├── config.mk                 # ユーザー／ボード別ビルド設定（.gitignore 対象、未存在時は default を使用）
├── Makefile                  # config.mk を include して Verilog マクロ・パラメータを生成
└── include/
    └── atg_config.vh         # Makefile から自動生成される Verilog 設定ヘッダ
```

### 4.2 `config.mk` 設定定義案（主要項目）

```makefile
# ==============================================================================
# Amaterrace GPU (ATG1) Build Configuration (config.mk)
# ==============================================================================

# Target Board Preset: kc705, basys3, arty_a7, minimal_sim
TARGET_PRESET            ?= kc705

# ------------------------------------------------------------------------------
# 1. Shader Unit (SU) Scaling
# ------------------------------------------------------------------------------
CONFIG_SU_NPHYS          ?= 8        # Physical lanes: 4, 8, 16, 32 (Default: 8)
CONFIG_SU_NWARPS         ?= 4        # Resident warp slots: 2, 4, 8
CONFIG_SU_NREGS          ?= 32       # GPRs per thread: 32 or 64
CONFIG_SU_ENABLE_FP16    ?= 1        # 1: Enable packed FP16x2 arithmetic, 0: Disable
CONFIG_SU_ENABLE_SUBGROUP?= 1        # 1: Enable shfl/vote/ballot, 0: Disable
CONFIG_SU_ENABLE_SFU     ?= 1        # 1: Hardware rcp/rsq/sin/cos, 0: SW emulation
CONFIG_SU_LDS_KB         ?= 4        # Workgroup Local Data Share: 0, 1, 2, 4 KB
CONFIG_SU_ENABLE_SA      ?= 0        # 1: Attach Systolic Tensor Accelerator, 0: Disable
CONFIG_SU_ENABLE_MESH    ?= 0        # 1: Enable VK_EXT Task & Mesh Shader capability (WS004), 0: Disable

# ------------------------------------------------------------------------------
# 2. Rasterizer (RX) Configuration
# ------------------------------------------------------------------------------
CONFIG_RX_ENABLE_MSAA    ?= 1        # 1: Support MSAA, 0: 1x sampling only
CONFIG_RX_MSAA_SAMPLES   ?= 4        # Max MSAA samples: 2 or 4
CONFIG_RX_ENABLE_EARLY_Z ?= 1        # 1: Hierarchical Hi-Z RAM, 0: Late Z only
CONFIG_RX_COARSE_SCAN    ?= 1        # 1: Two-level hierarchical scan, 0: Direct fine scan

# ------------------------------------------------------------------------------
# 3. Texture Unit (TU) Configuration
# ------------------------------------------------------------------------------
CONFIG_TU_ENABLE_BC      ?= 0        # 1: BC1-BC7 decompressors, 0: Uncompressed only
CONFIG_TU_ENABLE_TRILINEAR?=1        # 1: Trilinear/Mipmap interpolation, 0: Bilinear only
CONFIG_TU_ENABLE_3D_CUBE ?= 0        # 1: 3D volume & Cube maps, 0: 2D textures only
CONFIG_TU_L1_BANKS       ?= 4        # Texture cache banks: 1, 2, 4
CONFIG_TU_ENABLE_MSHR    ?= 1        # 1: Non-blocking MSHR, 0: Blocking single-issue

# ------------------------------------------------------------------------------
# 4. Render Output Backend (ROP) Configuration
# ------------------------------------------------------------------------------
CONFIG_ROP_DUAL_SOURCE   ?= 0        # 1: Vulkan Dual-Source Blending, 0: Single source
CONFIG_ROP_ENABLE_LOGICOP?= 0        # 1: 16 Vulkan LogicOp modes, 0: Blend only
CONFIG_ROP_FAST_CLEAR    ?= 1        # 1: Tile state tracking fast clear, 0: Direct write
CONFIG_ROP_MRT_COUNT     ?= 1        # Simultaneous Multiple Render Targets: 1, 2, 4

# ------------------------------------------------------------------------------
# 5. Command Processor (CP) & Memory Hierarchy
# ------------------------------------------------------------------------------
CONFIG_CP_AUTONOMOUS_MMU ?= 1        # 1: 2-level hardware page walker, 0: Static mapping
CONFIG_CP_USE_RV32_CORE  ?= 1        # 1: RV32IM microcode core, 0: Lightweight hardwired FSM
CONFIG_MC_L2_CACHE_KB    ?= 64       # Shared Last-Level Cache size (KB): 0, 16, 32, 64, 128
CONFIG_DC_ENABLE_CURSOR  ?= 1        # 1: Hardware cursor plane, 0: Software cursor
```

### 4.3 Makefile から Verilog への伝播方式
`Makefile` 内で `atg_config.vh` を自動生成し、RTL コンパイル時に include させます：

```makefile
# Makefile Snippet
include/atg_config.vh: config.mk
	@echo "/* Automatically generated by Makefile from config.mk. DO NOT EDIT. */" > $@
	@echo "\`ifndef ATG_CONFIG_VH" >> $@
	@echo "\`define ATG_CONFIG_VH" >> $@
	@echo "\`define CFG_SU_NPHYS $(CONFIG_SU_NPHYS)" >> $@
	@echo "\`define CFG_SU_NWARPS $(CONFIG_SU_NWARPS)" >> $@
	@echo "\`define CFG_SU_NREGS $(CONFIG_SU_NREGS)" >> $@
ifeq ($(CONFIG_SU_ENABLE_FP16),1)
	@echo "\`define CFG_ENABLE_FP16 1" >> $@
endif
ifeq ($(CONFIG_RX_ENABLE_MSAA),1)
	@echo "\`define CFG_ENABLE_MSAA 1" >> $@
	@echo "\`define CFG_MSAA_SAMPLES $(CONFIG_RX_MSAA_SAMPLES)" >> $@
endif
ifeq ($(CONFIG_TU_ENABLE_BC),1)
	@echo "\`define CFG_ENABLE_BC 1" >> $@
endif
	@echo "\`endif /* ATG_CONFIG_VH */" >> $@
```

---

## 5. GHCI Capability レジスタマッピング案

ビルド時に設定された機能パラメータは、ホスト CPU（KMD / UMD）がランタイムに検知できるよう、GHCI の MMIO レジスタに反映されます。

### 5.1 `DEVICE_CAPS` (Offset 0x008)

| Bits | 名前 | ビルド時対応設定 | 意味 |
| :--- | :--- | :--- | :--- |
| `[0]` | `CAP_UMA` | プラットフォーム | 1 = UMA 共有 DRAM、0 = ディスクリート VRAM |
| `[1]` | `CAP_IOMMU` | システム接続 | 1 = プラットフォーム IOMMU 有効 |
| `[2]` | `CAP_HW_WALKER` | `CONFIG_CP_AUTONOMOUS_MMU` | 1 = 自律 2 レベルハードウェアページテーブルウォーカー内蔵 |
| `[3]` | `CAP_INDIRECT_DRAW` | `CONFIG_CP_USE_RV32_CORE` | 1 = 間接描画（MultiDrawIndirect）対応 |
| `[4]` | `CAP_SECONDARY_RING`| `CONFIG_CP_USE_RV32_CORE` | 1 = セカンダリリングバッファ直接実行対応 |
| `[5]` | `CAP_DUAL_SOURCE` | `CONFIG_ROP_DUAL_SOURCE` | 1 = デュアルソースブレンディング対応（`Src1Color`/`Src1Alpha`） |
| `[6]` | `CAP_FP16` | `CONFIG_SU_ENABLE_FP16` | 1 = パックド FP16×2 浮動小数点演算対応 |
| `[7]` | `CAP_GSI1` | 固定 (1) | 1 = GSI1 64-bit 標準シェーダ ISA 実行 |
| `[15:8]` | `PHYS_LANES` | `CONFIG_SU_NPHYS` | **Shader Unit 物理レーン数（4, 8, 16, 32）** |
| `[23:16]` | `NUM_SU` | ボード設定 | 実装 Shader Unit 数（通常 1） |
| `[30]` | `CAP_TASK_SHADER` | `CONFIG_SU_ENABLE_MESH` | 1 = VK_EXT Task Shader 対応（WS004 オプション） |
| `[31]` | `CAP_MESH_SHADER` | `CONFIG_SU_ENABLE_MESH` | 1 = VK_EXT Mesh Shader 対応（WS004 オプション） |

### 5.2 `CAPS` (Offset 0x020)

| Bits | 名前 | ビルド時対応設定 | 意味 |
| :--- | :--- | :--- | :--- |
| `[17]` | `CAP_FW_READY` | `CONFIG_CP_USE_RV32_CORE` | 1 = ファームウェア稼働（0 = 固定 FSM 制御） |
| `[19]` | `CAP_NATIVE_ISA` | 固定 (0) | 0 = GSI1 標準 ISA 準拠 |
| `[24]` | `CAP_SUBGROUP` | `CONFIG_SU_ENABLE_SUBGROUP` | 1 = サブグループ演算対応（`shfl`, `vote`, `ballot`） |
| `[25]` | `CAP_SA` | `CONFIG_SU_ENABLE_SA` | 1 = シストリック行列アクセラレータ接続 |
| `[26]` | `CAP_TEX_ADV` | `CONFIG_TU_ENABLE_TRILINEAR` | 1 = 拡張テクスチャ演算（深度比較、Gather、QueryLod） |
| `[28]` | `CAP_PACKED_MATH` | `CONFIG_SU_ENABLE_FP16` | 1 = パックド半精度/整数演算命令対応 |
| `[29]` | `CAP_MSAA` | `CONFIG_RX_ENABLE_MSAA` | 1 = マルチサンプルラスタライズ対応（4x / 2x） |
| `[30]` | `CAP_VARYING_64` | ボード設定 | 1 = 64 Varying ワード対応（0 = 16 ワード） |

### 5.3 拡張 Capability レジスタ（`EXT_CAP_*`）の新設案

将来の Vulkan 互換ドライバがサポートフォーマットを動的に問い合わせるための拡張レジスタブロック（PCIe 拡張機能または MMIO オフセット `0x080` 以降）：

* **`EXT_CAP_FMT0` (Offset 0x080) - テクスチャ圧縮サポートビットマップ**:
  * `[0]`: BC1 (DXT1) RGB/RGBA
  * `[1]`: BC2 (DXT3) RGBA
  * `[2]`: BC3 (DXT5) RGBA
  * `[3]`: BC4 単一チャンネル (R)
  * `[4]`: BC5 デュアルチャンネル (RG / 法線マップ)
  * `[6]`: BC7 高品位 RGBA
* **`EXT_CAP_FEATURE` (Offset 0x084) - レンダリング機能詳細ビットマップ**:
  * `[0]`: `LOGIC_OP` 有効
  * `[1]`: `EARLY_Z` 有効
  * `[2]`: `HW_CURSOR` 有効
  * `[3]`: `COLOR_LUT` 有効
  * `[7:4]`: `MAX_MRT_COUNT` (1, 2, 4)

---

## 6. プロファイル別推奨プリセット構成

本アーキテクチャにより、以下のような極めて柔軟な FPGA 展開が可能となります。

```
[ Minimal Profile ]            [ Balanced Profile (KC705) ]       [ High-Performance Profile ]
(Artix-7 35T / 50T)            (Xilinx Kintex-7 KC705)            (UltraScale+ / Discrete PCIe)
────────────────────────       ─────────────────────────          ────────────────────────────
• NPHYS = 4                    • NPHYS = 8 (Default)              • NPHYS = 16 or 32
• No MSAA (1x only)            • MSAA 4x Supported                • MSAA 4x/8x Supported
• No Texture Compression       • BC1/BC2/BC3 Option               • Full BC1-BC7 Decompress
• Single Render Target         • Dual-Source Blend                • MRT 4 Render Targets
• Late Z Only (No Hi-Z)        • Early Z (Hi-Z RAM)               • Early Z + Hierarchical Stencil
• Fixed FSM Command Processor  • RV32IM Microcode CP              • Multi-Core RV32 CP + DMA
• Scanout 640x480 / 720p       • Full 1080p60 Scanout             • 4K Video Scanout
• Mesh/Task Shader Disabled    • Mesh/Task Optional               • Mesh/Task Hardware Enabled
```

---

## 7. 実装ステップとロードマップ

1. **Phase 1: 設定ヘッダ (`atg_config.vh`) と `config.mk` の新設**:
   * リポジトリルートに `config.mk.template` を作成。
   * `Makefile` に `include/atg_config.vh` の自動生成ルールを追加。
2. **Phase 2: SU 物理レーンスケーリング（NPHYS = 1, 2）の RTL 拡張**:
   * `atg_su_lane.v` のグループカウンタ幅 `GRP_W` の一般化。
   * 極小レーン時の `qd`（クワッド微分）アキュムレータ回路の実装およびバイパススイッチ追加。
3. **Phase 3: モジュール別オプションの Verilog プリプロセッサ条件分岐化**:
   * `atg_rx.v`: `CFG_ENABLE_MSAA`, `CFG_ENABLE_EARLY_Z` によるマクロ分岐。
   * `atg_rop.v`: `CFG_ENABLE_DUAL_SOURCE`, `CFG_ENABLE_LOGICOP` によるマクロ分岐。
   * `atg_tu.v`: `CFG_ENABLE_BC` による圧縮デコーダの着脱。
4. **Phase 4: GHCI Capability レジスタの Verilog パラメータ直結**:
   * `atg_cp_regs.v` 内の `DEVICE_CAPS`, `CAPS` をハードコードから `CFG_*` マクロ／トップレベルパラメータによる動的生成へ変更。
5. **Phase 5: 検証・回帰テスト**:
   * `NPHYS = 1, 2, 4, 8, 16` の全バリエーションについて Verilator lint および directed testbench（`sim-quick`）のパスを確認。
