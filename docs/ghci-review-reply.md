# GHCI Review Reply - Version 5.0 (2026-10-28) - Commit: fcd97e1 (Target: N01〜N33)

zedBSD ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 5 版（`ghci-review.md` 2026-10-28 02:13）にて提示された残存疑問 11 件（N02, N13, N14, N12, N16, N23, N25, N32, N33, N03, N21）に対する確定回答および仕様書（`docs/ghci.md`）・Cヘッダ（`include/ghci_cmd.h`）の同期改訂内容を報告します。

なお、すべての回答において禁止略語は一切使用しておりません。

---

## 1. 残存疑問 11 件への確定回答および条文反映

### N02 [H]: Constant Bank 重なり、texl descriptor 解決式、Combined Sampler
- **回答**:
  1. **Constant Bank 重なり・優先順位（Last Writer Wins）**:
     - Shader Unit の物理 Constant Bank は 512 ワード（$c[0..511]$）の単一 SRAM であり、`CMD_LOAD_CONST` と `CMD_BIND_DESCRIPTOR_TABLE` は同じ物理メモリに書き込みます。
     - 標準配置では、プッシュ定数および動的オフセットは先頭 96 バイト（24 dwords、$c[0..23]$）に格納し、$c[24..31]$（8 dwords）に Set 0〜3 の基底仮想アドレス（64-bit VA × 4）を CP が自動ミラーリングします。
     - プッシュ定数が 96 バイトを超えて 128 バイト（32 dwords、$c[0..31]$）をフルに使用する場合、`CMD_LOAD_CONST` が $c[24..31]$ を上書きします（**Last Writer Wins**）。この場合、シェーダは拡張コンスタント領域（$c[32..511]$、`lwc` 命令で 1 サイクルロード）または Uniform Buffer 経由で Set 基底アドレスを取得します。再度 `CMD_BIND_DESCRIPTOR_TABLE` が実行された場合は、該当 Set のスロット（Set $s$ は $c[24+2s .. 25+2s]$）が再ミラーリングされます。
  2. **`texl` slot $k$ のアドレス解決**:
     - テクスチャ命令におけるスロット番号 $k = \text{sub}[3:0]$（0〜15）は、ハードウェア Texture Unit（TU）が直接 Set 0（テクスチャ）および Set 1（サンプラ）の固定オフセットスロットとして解決します：
       $$\text{Texture Desc VA} = \text{set0\_base\_va} + (k \times 32)$$
       $$\text{Sampler Desc VA} = \text{set1\_base\_va} + (k \times 16)$$
     - TU によるハードウェアフェッチにおいて `binding_offset_bytes` は使用されません。`binding_offset_bytes` は、シェーダが ALU / メモリアドレス計算命令（`ld.64`, `lw`）を用いてバッファディスクリプタを読み出す際にのみ適用されます。
  3. **Combined Sampler の引数受け渡し**:
     - GSI1 1.0 において、テクスチャ命令（`texl`, `texb`, `texf`）は命令語内の 4-bit 即値 `sub[3:0]`（0〜15）によってテクスチャ／サンプラスロットを指定します。
     - 旧ドラフトに存在した「32-bit index ペアをレジスタに読み出して渡す」という記述は、静的スロット指定方式と矛盾していたため完全に削除しました。16 個の静的スロット（$0..15$）により、Vulkan 1.0 必須要件である `maxPerStageDescriptorSamplers = 16` を 100% 満たします。
- **条文反映**:
  - `docs/ghci.md`: §8.4（1320〜1335 行、1400〜1430 行）、§12.10.2（2250〜2268 行）

---

### N13 [H]: Blitter / Transfer コマンドのレイアウト定義と Descriptor row_pitch_bytes
- **回答**:
  1. **サブリソース（Mip / Layer / Slice）のアドレス解決**:
     - 画像転送・Blit コマンドは 2D サブリソーススライスに対して直接動作します。ドライバは対象の Mip レベルおよび配列レイヤの先頭 GPU 仮想アドレスを計算し、パケットの `src_va` / `dst_va` に渡します：
       $$\text{slice\_va} = \text{image\_base\_va} + \text{mip\_offset} + (\text{layer} \times \text{slice\_pitch\_bytes})$$
     - パケット内の `src_xy`, `dst_xy`, `extent` は、当該 2D スライス上の相対座標として扱われます。これにより、Blitter ハードウェアが複雑な 3D Mip 階層を自律トラバースする必要を排除し、完全ステートレスに転送を実行します。
  2. **転送コマンドの dword 拡張と format / pitch / flags の完全定義**:
     - `CMD_COPY_IMAGE`（0x41, 11 dw）: `src_va[63:0]`, `dst_va[63:0]`, `src_pitch`, `dst_pitch`, `src_xy`, `dst_xy`, `extent`, `format_and_flags`（`[7:0] format` (`VkFormat`), `[8] src_tiled`, `[9] dst_tiled`）。
     - `CMD_BLIT`（0x42, 12 dw）: `src_va[63:0]`, `dst_va[63:0]`, `src_pitch`, `dst_pitch`, `src_min_xy`, `src_max_xy`, `dst_min_xy`, `dst_max_xy`, `formats_and_filter`（`[7:0] src_format`, `[15:8] dst_format`, `[16] filter`, `[17] src_tiled`, `[18] dst_tiled`）。
     - `CMD_RESOLVE_IMAGE`（0x44, 11 dw）: `src_va[63:0]`, `dst_va[63:0]`, `src_pitch`, `dst_pitch`, `src_offset_xy`, `dst_offset_xy`, `extent_xy`, `params`（`[7:0] format`, `[9:8] resolve_mode`, `[11:10] samples`）。
     - `CMD_COPY_BUFFER_TO_IMAGE`（0x45, 10 dw）: `src_buffer_va`, `dst_image_va`, `buffer_row_pitch`, `image_row_pitch`, `image_offset_xy`, `image_extent_xy`, `format_and_flags`（`[7:0] format`, `[8] tiled`）。
     - `CMD_COPY_IMAGE_TO_BUFFER`（0x46, 10 dw）: `src_image_va`, `dst_buffer_va`, `image_row_pitch`, `buffer_row_pitch`, `image_offset_xy`, `image_extent_xy`, `format_and_flags`（`[7:0] format`, `[8] tiled`）。
  3. **Descriptor の `row_pitch_bytes` の定義**:
     - リニア画像の場合、Level 0 の行ピッチ（バイト）を指定します。Level > 0 のピッチはハードウェアが $\max(64, \lceil \text{width}_l \times \text{bpp} \rceil)$（64 バイト整列）として計算します。
     - タイル画像の場合、Level 0 のタイル行ピッチ（$\text{tile\_row\_pitch\_bytes} = \lceil \text{width}/8 \rceil \times \text{tile\_size\_bytes}$、256 バイト整列）を指定します。
- **条文反映**:
  - `docs/ghci.md`: §7.3（994〜1060 行）、§8.3（1265〜1272 行）
  - `include/ghci_cmd.h`: `GhciCmdCopyImage` (11 dw), `GhciCmdBlit` (12 dw), `GhciCmdResolveImage` (11 dw), `GhciCmdCopyBufferToImage` (10 dw), `GhciCmdCopyImageToBuffer` (10 dw)

---

### N14 [H] & N23 [M]: CMD_SET_DYNAMIC_STATE のパケット構造と Vertex Stride
- **回答**:
  1. **`CMD_SET_DYNAMIC_STATE`（0x26）の統一タグ付き構造（固定 6 dwords）**:
     - RTL デコーダ（`atg_cp_seq_dec.v:157`）の `h_need = 8'd5`（ヘッダ 1 dw + ペイロード 5 dw = 6 dw）に完全準拠し、`state_id` を用いた固定長 6 dwords パケットとして定義しました：
       - `dword 0`: Header (`opcode = 0x26, dwords = 6`)
       - `dword 1`: `state_id` (`GHCI_DYNAMIC_STATE_*`)
       - `dword 2..5`: ペイロード（4 dwords）
     - サポートする `state_id`:
       - `0x01` (`DEPTH_BIAS`): `dword 2: constant_factor`, `dword 3: slope_factor`, `dword 4: clamp`
       - `0x02` (`BLEND_CONSTANTS`): `dword 2..5: float rgba[4]`
       - `0x03` (`STENCIL_PARAMS`): `dword 2: [7:0] front_compare_mask, [15:8] front_write_mask, [23:16] front_ref`; `dword 3: [7:0] back_compare_mask, [15:8] back_write_mask, [23:16] back_ref`
       - `0x04` (`LINE_WIDTH`): `dword 2: float line_width`
       - `0x07` .. `0x0E` (`BLEND_ATTACHMENT_0..7`): `dword 2: uint32_t blend_state`（PSO dw11 と同一レイアウト、アタッチメント `state_id - 7` に適用）
       - `0x10` (`BORDER_COLOR_TABLE`): `dword 2: table_va_lo`, `dword 3: table_va_hi`（16 個 × 16 バイト = 256 バイトのボーダーカラーテーブルの 64-bit セッション GPU VA）
  2. **Vertex Stride の明確化**:
     - `CMD_BIND_VERTEX_BUFFERS` の `stride_bytes`（32-bit、$0..4095$）が常に優先・決定権を持ちます。
     - Vulkan の stride 0（全頂点が同一要素を参照）は、`stride_bytes = 0` として直接指定可能です。
     - PSO dw12（`vertex_strides`、bindings 0..3 の 8-bit 既定値）を継承して使用したい場合は、`stride_bytes = 0xFFFFFFFF`（`GHCI_STRIDE_FROM_PSO`）を指定します。Binding 4〜15 は PSO に既定値が存在しないため、`CMD_BIND_VERTEX_BUFFERS` で $0..4095$ の stride を直接指定します。
- **条文反映**:
  - `docs/ghci.md`: §7.3（770〜780 行、816〜855 行）、§8.2（1214 行、1230 行、1238 行）、§8.3（1293 行）
  - `include/ghci_cmd.h`: `GhciCmdSetDynamicState` (6 dw), `GHCI_DYNAMIC_STATE_*`, `GHCI_STRIDE_FROM_PSO`

---

### N12 [M]: HOST_LIMIT と Host PA (PA_BITS) および CMD_FLIP base_hi
- **回答**:
  1. **§11.2 の flag 表の修正**:
     - §11.2 1667 行目の「`LOCAL_BASE + offset`」を完全に削除し、`1 = Physical address is an absolute GPU physical address in local device VRAM (phys >= LOCAL_BASE); 0 = Host PCIe bus address or IOVA` に修正しました。
  2. **Host PA と `HOST_LIMIT` の関係**:
     - `HOST_LIMIT` は GPU 内部の物理バスアドレス空間におけるルーティング境界（閾値）です。
     - `CMD_VM_MAP` において `VM_FLAG_LOCAL == 0`（Host メモリ）の場合、`phys[63:0]` は 64-bit のホスト物理アドレス（または IOVA）であり、`PA_BITS`（40〜48 bit、`EXT_CAP_FEATURE[11:8]`）まで有効です。IOMMU が無く 32-bit PCIe DMA コントローラを使用するプラットフォームでのみ、ホスト物理アドレスが `HOST_LIMIT`（4 GiB 未満）に制限されます。
  3. **`CMD_FLIP` の `base_hi` と `FB_BASE` / `FB_NEXT`**:
     - ディスプレイスキャンアウトはローカル VRAM（$\ge \text{LOCAL\_BASE}$）またはホスト UMA アパーチャ（$< \text{HOST\_LIMIT}$）のいずれかから読み出しますが、これらはすべて 32-bit GPU 物理アドレス空間内に収まります。
     - したがって、`CMD_FLIP` の `base_hi` および `record_pa_hi` は **0 でなければなりません**。ハードウェアは `base_hi == 0` を検証し、`base_lo` を `FB_BASE` / `FB_NEXT` に書き込みます。
- **条文反映**:
  - `docs/ghci.md`: §11.2（1667 行）、§11.3（1775〜1785 行）、§7.3（1145 行）
  - `include/ghci_cmd.h`: `GhciCmdFlip`

---

### N16 [M]: MEM_CACHE_CFG の配置と CAP_TEX_FFILT
- **回答**:
  1. **`MEM_CACHE_CFG` の配置とビット定義**:
     - §11.3 の `MEM` 機能ブロック（オフセット `0x1E0..0x1F7`、24 バイトウィンドウ）の `+0x14` に `MEM_CACHE_CFG`（RO）を明記しました：
       - `[7:0] L2_CACHE_KB`: L2 キャッシュ容量（0, 16, 64, 128, 256 KiB、0 は L2 なし／バイパス）
       - `[15:8] L2_WAYS`: L2 連想度（0, 4, 8, 16 way）
       - `[23:16] L1_TEX_CACHE_KB`: テクスチャ L1 容量（4, 8, 16 KiB）
       - `[31:24] VF_CACHE_LINES`: 頂点フェッチャラインバッファ数（2, 4, 8 line）
     - §4.1 の `MEM` レジスタウィンドウ範囲も `0x1E0..0x1F7` に更新しました。
  2. **`CAP_TEX_FFILT` と `.3` 形式（2D 配列・3D・Cube）の関係**:
     - `.3` 座標形式（2D 配列、3D、Cube マップ）、深度比較（`.c`）、および Gather（`texg`）は、GSI1 コア（`GHCI_CAP_GSI1 == 1`）の Texture Unit における**標準基本機能**です。
     - `DEVICE_CAPS[25]`（`CAP_TEX_FFILT`）は、浮動小数点線形補間フィルタ回路（`atg_tu_ffilt`）が合成されているか否かのみを示します。`CONFIG_TU_ENABLE_FFILT = 0` の場合でも、UNORM8 のバイリニア補間は動作し、FP16/FP32 テクスチャは最近傍（Point）サンプリングにフォールバックします。2D 配列・Cube・3D のサンプリングが禁止されることはありません。旧 `CAPS[26]` との混同を解消し、§12.1 の記述を修正しました。
- **条文反映**:
  - `docs/ghci.md`: §4.1（484 行）、§11.3（1781 行）、§12.1（1904 行）

---

### N25 [M]: DISP2 Record 形式、Immediate Flip 優先度、display_id
- **回答**:
  1. **Record 形式の統一（16 バイト）**:
     - §13.2 の旧記述（2 ワード `{value, FRAME_COUNT}`）を完全に改訂し、§7.3 と同様に 16 バイトの `{uint32_t value, uint32_t frame_count, uint32_t timestamp_lo, uint32_t timestamp_hi}` に統一しました。
     - `GHCI_FLIP_FLAG_RECORD_ENABLE`（`flags[3] == 1` かつ `record_pa != 0`）のときに書き込まれます。
  2. **`record_pa` のアドレス空間**:
     - `record_pa` は 32-bit GPU 物理アドレス（`record_pa_hi == 0`）です。ホスト通知用にはホストメモリアパーチャ（$< \text{HOST\_LIMIT}$）のアドレスを指定し、GPU が PCIe DMA 経由でホストメモリへ直接書き込みます。
  3. **`VSYNC_WAIT` と `IMMEDIATE` の優先度**:
     - `VSYNC_WAIT=1, IMMEDIATE=0`: 標準 VSYNC 同期フリップ（次の VSYNC で反映）。
     - `IMMEDIATE=1, VSYNC_WAIT=0`: 即時フリップ（現在のフレーム内で直ちに反映、テアリング許容）。
     - 両方 0: `VSYNC_WAIT = 1` が既定値として適用されます。
     - 両方 1: **`IMMEDIATE = 1` が優先**されます。
  4. **`display_id` 1 のコントローラ**:
     - GHCI 1.0 では、単一ディスプレイ構成（KC705 等）では `display_id = 0`（MMIO `0x200` の DISP2）のみが存在します。`display_id = 1` はデュアルディスプレイ拡張用として予約されており、単一コントローラ構成で `display_id != 0` を指定すると `GHCI_FAULT_KIND_INVALID_ARG`（Kind 1）が発生します。
- **条文反映**:
  - `docs/ghci.md`: §7.3（1142〜1165 行）、§13.2（2471〜2472 行、2523〜2540 行）
  - `include/ghci_cmd.h`: `GhciCmdFlip`

---

### N32 [M]: BEGIN_RENDER_PASS の flags と PSO dw8 のヘッダ同期
- **回答**:
  1. **`GhciCmdBeginRenderPass.flags` の同期**:
     - `include/ghci_cmd.h`（580 行付近）のコメントを本文 §7.3（884〜888 行）に合わせて完全に同期しました：
       `/* dw8: [7:0] clear_color (attachments 0..7), [8] clear_depth, [9] clear_stencil, [16] inline_secondary (N03, N32) */`
  2. **`GhciPipelineState.flags`（dw8）の sample shading の追加**:
     - `include/ghci_cmd.h`（182 行）の `flags` コメントに `[11] sample shading` を追加し、本文 §8.2 と 100% 一致させました。
- **条文反映**:
  - `include/ghci_cmd.h`: 182 行、580 行付近

---

### N33 [M]: PSO と State Word（MS_CTRL/SAMPLE_KILL）の優先度と Descriptor の対応
- **回答**:
  1. **PSO と State Word の優先度（PSO が正本）**:
     - GHCI 1.0 では、Immutable Pipeline State Object（`GhciPipelineState`、§8.2）および Render Pass Descriptor（`GhciRenderPassDesc`、§8.4）が**正本**です。
     - 内部ラスタライザレジスタ（`MS_CTRL 0x05E`, `SAMPLE_KILL 0x05F`）は、CP が `CMD_BEGIN_RENDER_PASS` および `CMD_BIND_PIPELINE` を実行する際に**ハードウェア内部で自律的に設定**します。ドライバが `SET_REG` を発行することはなく、旧ドラフトの `SET_REG` 記述は廃止・修正されました。
  2. **Sample Shading の可否**:
     - Sample Shading はネイティブにサポートされます。`PSO dw8 [11]`（`sample_shading`）が 1 の場合、ラスタライザはカバーされたサンプル位置ごとにフラグメントシェーダを実行します（`FragCoord` および重心座標も各サンプル位置で評価）。0 の場合はピクセル単位（Coarse Pixel Shading）で実行されます。
  3. **Descriptor フィールドとの対応**:
     - `TEX_IMAGE[3:0]` $\to$ `GhciTextureDescriptor.mip_levels` (1..15)
     - `TEX_IMAGE[15:12]` $\to$ `GhciTextureDescriptor.sample_count` (1, 2, 4)
     - `format 4` $\to$ `GhciTextureDescriptor.format = VK_FORMAT_B5G6R5_UNORM_PACK16`（8）または `R5G6B5_UNORM_PACK16`（84）
     - `TEX_SAMPLER[9]` $\to$ `GhciSamplerDescriptor.compare_enable`
     - `TEX_SAMPLER[12:10]` $\to$ `GhciSamplerDescriptor.compare_op` (`VkCompareOp`)
- **条文反映**:
  - `docs/ghci.md`: §12.11（2270〜2340 行）

---

### N03 [L]: clear_color_table_va が 0 のときのクリア色解釈
- **回答**:
  - `clear_color_table_va == 0` の場合：
    - **Color Attachment 0**: 常に `CMD_BEGIN_RENDER_PASS.color_clear_rgba` の値を用いてクリアされます。解釈は Attachment 0 の `format` によって決まります：
      - 8-bit UNORM / SNORM / sRGB フォーマット（`R8G8B8A8_*`, `B8G8R8A8_*` 等）：Packed 4×8-bit（`[7:0] R, [15:8] G, [23:16] B, [31:24] A`）。
      - 単一チャネル 32-bit フォーマット（`R32_SFLOAT`, `R32_UINT` 等）：R チャネル用の 32-bit 浮動小数点／整数クリア値。
    - **Color Attachments 1..7**: パケット内にインラインクリア値が存在しないため、各アタッチメントのフォーマットに応じた**全ゼロ（0.0f / 整数 0 / 透明な黒）**でクリアされます。
  - アタッチメントごとに個別の 128-bit 浮動小数点／整数クリア値を指定する場合は、`clear_color_table_va` を使用します。
- **条文反映**:
  - `docs/ghci.md`: §8.4（1380〜1390 行）

---

### N21 [L]: DISP2 割り込み階層、DISP_ERROR、イベント名称の完全統一
- **回答**:
  1. **DISP_ERROR ビットの追加**:
     - DISP2 機能ブロックの `DISP_IRQ_STATUS`（+0x18）および `DISP_IRQ_ENABLE`（+0x1C）に `bit 5` として `DISP_ERROR`（スキャンアウト読出エラー `STATUS[3]`、レコード書込エラー `STATUS[4]`、不正レジスタ書込 `STATUS[5]`）を追加しました。
  2. **割り込みハンドラ手順（§9.2）**:
     - `IRQ_STATUS[3]`（`GHCI_IRQ_DISPLAY`）は DISP2 イベントの集約サマリです。ハンドラは `DISP_IRQ_STATUS`（`0x218`）を読み出し、処理したビットに 1 を書き込んでクリア（W1C）した後、`IRQ_STATUS[3]` に 1 を書き込んでクリアします。
  3. **イベント名称の統一（§13.2）**:
     - 旧用語（VBLANK, `IRQ_STATUS.FLIP` 等）を廃止し、`DISP_IRQ_STATUS` のビット名（`VSYNC`, `FLIP_DONE`, `CURSOR_FLIP_DONE`, `HOTPLUG`, `UNDERFLOW`, `DISP_ERROR`）に完全統一しました。
- **条文反映**:
  - `docs/ghci.md`: §3.4（399 行、404 行）、§9.2（1557 行）、§13.2（2471〜2472 行、2523〜2540 行）
  - `include/ghci_cmd.h`: `GHCI_DISP_IRQ_BIT_*`

---

## 2. 成果物一覧および検証状況

1. **修正コミット**:
   - `fcd97e1` (`fcd97e19ce3d5e2365cf8527a20c38662ce2a87a`)
   - `docs/ghci.md`: 291 行修正（N01〜N33 すべての仕様を矛盾なく反映）
   - `include/ghci_cmd.h`: 154 行修正（C 構文チェック `gcc -fsyntax-only` パス確認済）
2. **シミュレーション回帰テスト**:
   - `./sim/run.sh atg_cp atg_ghci_slim` $\to$ **PASS**（全テスト完全通過）
3. **禁止語句チェック**:
   - リポジトリ内全ファイルおよび本返答において 0 件であることを確認済。

DONE
