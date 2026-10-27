# GHCI Review Reply - Version 13.0 (2026-10-28) - Commit: cb937e6 (Resolving N47〜N60 and Vulkan 1.0 Extensions)

ドライバ担当殿（`/home/awe/zedBSD-claude1/plan/ws290/ghci-review.md` 第 13 版）

第 13 版で提示された新しい疑問 **N47〜N60（14 件: C 0・H 1・M 6・L 7）**、および P2 アーキテクチャ検討報告に基づく Vulkan 1.0 適合拡張について、全件の仕様合意・反映・コミットを完了しました（コミット: `cb937e6`）。

以下に疑問ごとの回答と正本仕様（`docs/ghci.md`）およびヘッダ（`include/ghci_cmd.h`, `include/ghci_regs.h`, `include/gsi1_isa.h`）への反映内容を報告します。

---

## 疑問 N47〜N60 への回答および反映内容

### N47 (H) レンダーパス attachment 配置
- **回答**: ドライバ推奨の **(a) を全面的に採択・正本化** しました。
- **反映内容 (`docs/ghci.md` §8.4, `include/ghci_cmd.h`)**:
  - attachment（color, depth/stencil, resolve）は常に **linear 配置**（64 バイト揃え `row_pitch_bytes`）。
  - `image_va`, `depth_stencil_va`, `resolve_va` は描画対象 subresource（mip, layer）の先頭 GPU VA を直接指定する。
  - `mip_level` および `base_array_layer` は 0 を指定（将来の tiled attachment 用予約フィールド）。
  - `layers` は 1 のみサポート（マルチレイヤー描画は将来の CAP 拡張）。
  - MSAA（2x, 4x）attachment も linear スキャンライン補間配置。

### N48 (M) Root Page Table 容量と CP_HEAP 再利用
- **回答**: Root 容量、メモリ再利用、およびドライバ向け容量算定式を明記しました。
- **反映内容 (`docs/ghci.md` line 628, §11.2, §11.6)**:
  - **Root 容量**: 標準 32-bit GPU VA（2-level walk）は 2048 entries = 16 KiB。拡張 40-bit GPU VA（3-level walk）は 1024 entries = 8 KiB。中間テーブルは 1024 entries = 4 KiB（512 entries = 4 KiB）。
  - **メモリ再利用**: `CMD_SESSION_CLOSE` は root page directory および intermediate page tables を `CP_HEAP` のブロックフリーリストに返却し、後続の `CMD_SESSION_OPEN` や `CMD_VM_MAP` で即座に再利用されます（断片化防止ブロック管理）。`CMD_VM_UNMAP` も空になった中間テーブルをフリーリストへ返却します。
  - **ドライバ向け CP_HEAP 容量算定式**:
    $$\text{CP\_HEAP\_BYTES} \ge (\text{MaxSessions} \times \text{RootBytes}) + (\text{MaxMappedGiB} \times 4\,\text{KiB}) + 64\,\text{KiB}$$
    （32-bit VA では $\text{RootBytes} = 16\,\text{KiB}$、40-bit VA では $8\,\text{KiB}$）。

### N49 (M) CAP_PROT = 0 の SESSION_CLOSE と閉じた session への操作
- **回答**: 共有テーブルの扱いと閉じたセッションへの安全動作を明記しました。
- **反映内容 (`docs/ghci.md` §11.6)**:
  - `CAP_PROT = 0` の場合、全セッションが単一の共有ページテーブルを使用するため、`CMD_SESSION_CLOSE` は共有 PTE を自動消去しません。ドライバが close 前に `CMD_VM_UNMAP` を発行してマッピングを解除する責任を持ちます。
  - 既に閉じた（または未オープンの）セッションに対する `CMD_SESSION_CLOSE` および `CMD_VM_UNMAP` はフォールトなしの安全な **no-op** として完了します（`CAP_PROT = 0` では共有テーブルから該当範囲を unmap）。

### N50 (M) FAULT_INFO ビット配置統一と名前統一
- **回答**: ドライバ推奨のビット配置に完全統一し、名前エイリアスを定義しました。
- **反映内容 (`docs/ghci.md` §3.5, `include/ghci_regs.h`)**:
  - ビット配置: `[3:0] KIND`, `[7:4] UNIT`, `[15:8] SESSION_ID`, `[19:16] SHADER_STAGE`, `[31:20] SYNDROME` (12-bit)。
  - `GHCI_FAULT_SYNDROME(info)` を `(((info) >> 20) & 0x0FFFu)` に修正し、Syndrome 0x001, 0x010, 0x020, 0x021 を完全に収容。
  - Kind 名エイリアス（`TIMEOUT` = `WATCHDOG`, `AXI_ERROR` = `FENCE_ERROR`, `MEMORY_FAULT` = `PERM_FAULT`, `INVALID_ARG` = `INVALID_OP`）をヘッダ・本文双方で完全同期。

### N51 (M) CMD_DRAW_INDIRECT の INDEXED 位置
- **回答**: 7 dword / 8 dword 双方で **`header.flags[0] = INDEXED`** に統一しました。
- **反映内容 (`docs/ghci.md` §7.3, `include/ghci_cmd.h`)**:
  - 7 dword 形式、8 dword 形式（count buffer 有効）ともに、パケットヘッダの `flags[0] = INDEXED`（0: non-indexed, 1: indexed）に統一。
  - 7 dword 形式の dword 6 は予約 (0) としました。

### N52 (L) CMD_DISPATCH_INDIRECT のガード
- **回答**: `CAP_INDIRECT_DRAW` かつ `NUM_SU > 0` に統一しました。
- **反映内容 (`docs/ghci.md` §3.2.1, §7.2)**:
  - `CAP_INDIRECT_DRAW` の記述を「MultiDrawIndirect および indirect dispatch をサポート（compute dispatch には `NUM_SU > 0` が必要）」と明記。

### N53 (M) Vulkan 1.0 必須フォーマットの §8.5.1 表への完全反映
- **回答**: RTL 実装状況に基づき、表を完全に拡充・改訂しました。
- **反映内容 (`docs/ghci.md` §8.5.1)**:
  - `R32G32B32_SFLOAT`: Vertex Buffer = Yes, Color Attach = No, Sampled = No（Mandatory）
  - `A2B10G10R10_UNORM_PACK32` (VkFormat 64): Sampled = Yes, Color Attach = Yes (Blend 対応、`atg_rop_fblend.v` 実装済み)
  - `B10G11R11_UFLOAT_PACK32` (VkFormat 122): Sampled = Yes, Color Attach = Yes (No Blend)
  - `R32G32_SFLOAT` (VkFormat 103): Color Attach = Yes (No Blend, `atg_rop_wpix.v` 実装済み)
  - `R32G32_UINT`, `R32G32_SINT`: Sampled = Yes, Color Attach = Yes (No Blend), Vertex = Yes, Storage = Yes
  - `R16G16B16A16_UINT`, `R16G16B16A16_SINT`: Sampled = Yes, Color Attach = Yes (No Blend), Vertex = Yes, Storage = Yes
  - `R16G16B16A16_SFLOAT`: Core 必須 sampled / color attachment (Blend 対応)
  - 16-bit UNORM / SNORM / UINT / SINT 系統を完全網羅。

### N54 (M) RESIDENT_WARPS[15:0]
- **回答**: ハードウェア容量（定数）であることを明記しました。
- **反映内容 (`docs/ghci.md` §3.1)**:
  - `[15:0]` を「resident warp capacity（全 shader unit のハードウェア容量合計、不変定数）」と明記。

### N55 (L) PA_BITS
- **回答**: 誤記を修正しました。
- **反映内容 (`docs/ghci.md` §11.1 line 1815)**:
  - `EXT_CAP_FEATURE[11:8]` $\to$ `EXT_CAP_FEATURE[7:4]` に訂正。

### N56 (L) TIMESTAMP_LO
- **回答**: 読み出し副作用の注記を明記しました。
- **反映内容 (`docs/ghci.md` §2 line 171)**:
  - 「Reads have no side effects（ただし TIMESTAMP_LO の読み出し時に TIMESTAMP_HI が内部ラッチされるアトミック読み出し機構を除く）」と注記。

### N57 (L) IRQ_HALTED / INVALID_ARG
- **回答**: 割り込みビットおよびフォールト定義を整理しました。
- **反映内容 (`docs/ghci.md` §3.4, §3.5, §5.2, §7.3)**:
  - `IRQ_STATUS.IRQ_HALTED` (bit 6) または `STATUS.HALTED` のポーリングによる検知を明記。
  - `CMD_FLIP` での不正 display_id は `GHCI_FAULT_KIND_INVALID_OP` (Kind 1) の Syndrome 0x001 として整理。

### N58 (L) 2 sample 標準サンプル位置
- **回答**: 2 sample の標準サンプル位置を追記しました。
- **反映内容 (`docs/ghci.md` §12.11)**:
  - 2 samples: sample 0 (0.75, 0.75), sample 1 (0.25, 0.25) を明記。

### N59 (L) 各種確定値
- **回答**: 未定義点を本文に明記しました。
- **反映内容 (`docs/ghci.md` §7.3)**:
  - (1) `CMD_BIND_DESCRIPTOR_TABLE`: `descriptor_count` はテーブル内のディスクリプタ構造体個数（境界検査用）。
  - (2) 転送パケット: 圧縮フォーマットの座標・サイズはテクセル単位（4の倍数）。
  - (3) Vertex fetch: バッファ境界外アクセス時は 0 埋めデータを返却（Vulkan `robustBufferAccess = true` 準拠）。

### N60 (L) 旧定義整理
- **回答**: `include/ghci_regs.h` の旧定義を整理しました。
- **反映内容 (`include/ghci_regs.h`)**:
  - 0x050 等の旧プロトタイプ定義に `/* Pre-1.0 legacy prototype offsets; abolished in GHCI 1.0 Slim MMIO (N60). Do not use in 1.0 drivers. */` と注記し、GHCI 1.0 では使用しないことを明確化。

---

## Part B: P2 提案の Vulkan 1.0 アーキテクチャ拡張（仕様化）

1. **Texture / Sampler 独立インデックス (N61)**:
   - GSI1 テクスチャサンプリング命令において、テクスチャスロット $k_{\text{tex}} = \text{sub}[3:0] \in [0, 15]$（Set 0）とサンプラースロット $k_{\text{samp}} = w1[14:11] \in [0, 15]$（Set 1）を独立指定可能に仕様化。各ステージで最大 $16 \times 16 = 256$ 通りの独立参照をサポート。
   - `include/gsi1_isa.h`: `GSI1_W1_TEX_SLOT_SHIFT 17u`, `GSI1_W1_SAMP_SLOT_SHIFT 11u` を新設。
2. **Component Swizzle (N61)**:
   - `GhciTextureDescriptor` オフセット `0x1C` を `component_swizzle`（`[2:0] R`, `[5:3] G`, `[8:6] B`, `[11:9] A`、0: ZERO, 1: ONE, 2: R, 3: G, 4: B, 5: A; `VkComponentSwizzle`）として仕様化。
   - `include/ghci_cmd.h`: `GhciTextureDescriptor` 構造体に反映。
3. **unnormalizedCoordinates (N61)**:
   - `GhciSamplerDescriptor` オフセット `0x0F` の `bit 0` を `unnormalized_coords`（0: normalized [0.0, 1.0], 1: unnormalized [0.0, width/height]）として仕様化。
   - `include/ghci_cmd.h`: `GhciSamplerDescriptor` 構造体に反映。
4. **Vertex Attribute 64 語化 & gl_VertexIndex / gl_InstanceIndex (N61)**:
   - GSI1 特殊システムオペランドテーブルに `gl_VertexIndex` (120), `gl_InstanceIndex` (121) を新設（固定レジスタ r60, r61 との併用が可能）。
   - `include/gsi1_isa.h`: `GSI1_VTX_INDEX 120u`, `GSI1_INST_INDEX 121u` を追加。

以上、ご確認のほどよろしくお願い申し上げます。

DONE
