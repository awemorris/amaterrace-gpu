# GHCI Review Reply - Version 4.0 (2026-10-27) - Commit: 7153329 (Target: N01〜N32)

本回答書は、ドライバ開発チーム（`amaterrace.ko`）より提示された「GHCI レビュー 第 4 版（疑問 N01〜N32）」に対するハードウェア・アーキテクチャ仕様策定チーム（D1）の完全確定回答です。
対象コミット `7153329` において、`docs/ghci.md` および `include/ghci_cmd.h` を直接改訂・同期し、指摘されたすべての矛盾、欠落、仕様の食い違いを完全に解消しました。

---

## 1. 解決済み項目の確認（10 件）

第 4 版にて解決を確認いただいた以下の 10 件について、改訂版 `7153329` においても定義の同一性と整合性を完全に維持しています：
- **N05**: セッション fault 後の隔離処理・リソース回収手順（§3.3, §10, 1534〜1548 行）
- **N06**: クライアントセッション fault 時にデバイスは `FAULTED` に遷移しない規定（§3.3, §10, 1540 行）
- **N15**: キャッシュ無効化・フラッシュの `CMD_BARRIER` 明示 flags 化（§7.3, §11.5, 899〜913 行, 1772〜1787 行）
- **N19**: `EXT_CAP_FMT0` および `FMT_OPTIMAL` の bit 定義（§3.2.2, §4.1, 303〜312 行, 487〜506 行）
- **N20**: シェーダ実行 fault の分類（kind 1/9/10）およびステージ特定（§3.5, §12.6, 420〜438 行, 2013〜2035 行）
- **N22**: グラフィクスとコンピュートパイプラインの独立 bind point（§7.3, 755〜765 行）
- **N26**: ウォッチドッグタイマのパケット毎リセット、外部待ち（`wdt_hold`）時の一時停止、満了時動作（§10, 1549〜1563 行）
- **N27**: `CMD_VM_UNMAP` 完了時における RPTR 前進と物理ページの安全な再利用保証（§6.4, 690〜698 行, §11.2, 1688〜1694 行）
- **N29**: UMA プラットフォームにおけるブート時スキャンアウト framebuffer の扱い（§13.3, 2490〜2525 行）
- **N30**: `GCLK_HZ` を基準とした Vulkan `timestampPeriod` 算出式（§8.6, 1498 行）

---

## 2. 残る疑問への完全確定回答（22 件: C 1, H 9, M 8, L 4）

### N02 [C] ディスクリプタ番地計算式、テーブル配置、および動的オフセット
- **番地計算式の統一**:
  一般化された確定式として §8.4（1279〜1287 行）および §12.10.2（2223〜2229 行）を統一しました：
  $$\text{desc\_va} = \text{set\_base\_va} + \text{binding\_offset\_bytes} + (\text{element\_idx} \times \text{descriptor\_size\_bytes})$$
- **`binding_offset_bytes` の決定者と通知**:
  User-Mode Driver (UMD) がパイプラインレイアウト作成時（`vkCreatePipelineLayout`）に `VkDescriptorSetLayout` に基づいて静的に決定します。シェーダコンパイラが生成する GSI1 命令内に即値オフセットとして直接埋め込まれます。
- **Set 0〜3 の `table_va` の読み出し**:
  `CMD_BIND_DESCRIPTOR_TABLE(set_index, table_va, count)` の実行時、CP が 64-bit `table_va` を Shader Unit の定数レジスタバンクに自動反映します（§8.4, 1288〜1295 行）：
  - Set 0: `c[24..25]`
  - Set 1: `c[26..27]`
  - Set 2: `c[28..29]`
  - Set 3: `c[30..31]`
  これによりシェーダは 1 サイクルの即値オペランドとしてディスクリプタセット基底 VA を参照可能です。
- **`texl` などのスロット（`sub[3:0]`, 0〜15）**:
  即値スロット形式のテクスチャサンプリング命令では、`sub[3:0]`（0〜15）は **Descriptor Set 0 の binding 0〜15**（テクスチャ）を直接参照し、Set 1 のサンプラー 0〜15 と対を成します（§8.4, 1298〜1301 行, §12.10.2, 2234〜2236 行）。
- **Combined Image Sampler インデックス対**:
  `GhciCombinedImageSampler` の `texture_index` は **Set 0（テクスチャ配列）** のインデックス、`sampler_index` は **Set 1（サンプラー配列）** のインデックスを指します（§8.4, 1362〜1373 行）。
- **動的オフセット (`VK_DESCRIPTOR_TYPE_*_DYNAMIC`)**:
  **シェーダが動的オフセットを加算**します。ディスクリプタからロードしたバッファ基底 GPU VA に対し、プッシュ定数（`c0..c31`）経由で渡された動的オフセットをシェーダが加算してからメモリアクセス命令を発行します（§8.4, 1296〜1297 行, §12.10.2, 2232〜2234 行）。ディスクリプタテーブルメモリ自体の書き換えは行いません。

### N08 [H] フェンス値の単調増加性、エラー通知方式、および完了保証
- **64-bit 単調増加と値の書き込み**:
  GPU およびドライバは、常に要求された本来の 64-bit シーケンス番号 **`target_seq` をメモリに書き込みます**（§10, 1542〜1547 行）。これにより `(int64_t)(current_seq - wait_seq) >= 0` の符号付き比較条件が成立し、ホスト待ちキューが確実に起床します。
- **エラー状態通知（0xFFFFFFFF の完全排除）**:
  フェンスメモリに `0xFFFFFFFF` を書き込む仕様は単調増加性を破壊するため **完全に廃止・削除** しました（§10, 1546 行, §5.2, 574 行, App. A, 2630 行）。待機側（ドライバ/クライアント）は、`IRQ_STATUS.IRQ_FAULT` 受信時にラッチされた `FAULT_INFO` をドライバが検知し、該当セッションのソフトウェア管理構造体に fault フラグを設定（`-EIO` / `VK_ERROR_DEVICE_LOST`）することでエラーを検知します。
- **実行前に破棄されたフェンス**:
  リング投入前またはリング内で破棄されたフェンスは、ドライバ（KMD）がホストメモリ上のフェンスアドレスに要求シーケンス値 `target_seq` を代行書き込みし、セッションエラーをマークして待機スレッドを起床させます。

### N09 [H] CP_HEAP の動的拡張方式、アドレス空間、および Session 0 OOM
- **動的拡張方式の一本化**:
  ページテーブル内部に物理アドレスによる次段ポインタを保持する多段構造（§11.2）であるため、不連続領域へのコピー移転はポインタ再配置不可につき **廃止** し、**連続ページへの拡張（On-the-Fly Expansion）に一本化** しました（§11.2, 1651〜1656 行）。ドライバは動作中（`CTRL.RUN == 1`）に `CP_HEAP_LIMIT` をより高い物理境界へ直接追記することで安全に拡張可能です。
- **`CTRL.TLB_FLUSH` の記述整合**:
  移転拡張の廃止に伴い、`CTRL.TLB_FLUSH` をドライバが手動発行する記述を削除しました。
- **CP_HEAP のアドレス空間**:
  `CP_HEAP_BASE` および `CP_HEAP_LIMIT` は 32-bit GPU 物理アドレス（PA）であり、ホスト DMA アパーチャ（$< \text{HOST\_LIMIT}$）またはローカル VRAM（$\ge \text{LOCAL\_BASE}$）のいずれにも配置可能です（§11.2, 1644 行）。
- **Session 0 の OOM**:
  Session 0（カーネルリング）が発行した `CMD_VM_MAP` が OOM に陥った場合は、Session 0 の障害としてデバイス全体が `STATUS.FAULTED` に遷移します（§11.2, 1660 行, §11.6, 1834 行）。クライアントセッション（$S \ge 1$）の OOM では当該クライアントのみが fault します。

### N10 [H] セッション管理パケット誤り時の fault 対象セッション
- **フォールト対象セッションの特定**:
  Session 0 がクライアントセッション $S \in [1, 15]$ を対象に発行した管理パケット（`CMD_VM_MAP`, `CMD_VM_UNMAP`, `CMD_SESSION_OPEN`）でエラー（マッピング衝突、閉じたセッションへのアクセス、テーブル確保 OOM 等）が発生した場合、**対象クライアントセッション $S$ のみが fault（`SESSION_ACTIVE[S] = 0`）** します（§11.6, 1823〜1833 行）。
- **Session 0 およびデバイスの状態**:
  Session 0 は fault せず、**`STATUS.FAULTED` もセットされません**（§11.6, 1834〜1835 行）。ドライバは対象セッションに対してのみエラー（`-EINVAL`, `-ENOMEM` 等）を返却し、デバイスおよび他のセッションの実行は継続します。Session 0 自身（$S = 0$）を対象とするマッピングエラーの場合に限り、`STATUS.FAULTED` がセットされます。

### N11 [H] CMD_FENCE flags の統一、INLINE_VALUE=0 の動作、fence_addr 所在
- **flags 定義の完全同期**:
  §7.3（933〜937 行）、§9.1（1514〜1515 行）、および `include/ghci_cmd.h`（382〜385 行）の定義を完全に統一しました：
  - `[0]`: `GHCI_FENCE_FLAG_IRQ` (0x1) — 完了時に `IRQ_STATUS[0]`（`IRQ_FENCE`）を発生
  - `[1]`: `GHCI_FENCE_FLAG_MEM_WRITE` (0x2) — `fence_addr` への 64-bit シーケンス値書き込みを実行
  - `[2]`: `GHCI_FENCE_FLAG_HOST_FLUSH` (0x4) — フェンス発行前に GPU ダーティキャッシュをフラッシュ
- **`MEM_WRITE = 0`（旧 INLINE_VALUE=0）の動作**:
  メモリ書き込みを省略し、割り込み（IRQ）通知のみを実行します（§7.3, 936 行）。
- **`fence_addr` の所在**:
  ホスト PCIe DMA メモリ（PA/IOVA）およびローカル VRAM（$\ge \text{LOCAL\_BASE}$）の双方が指定可能です（§6.0, 617 行, §7.3, 929 行, §9.1, 1513 行）。

### N12 [H] VM_FLAG_LOCAL 物理番地、HOST_LIMIT の定義、DISP2 レジスタ
- **`VM_FLAG_LOCAL` の物理アドレス**:
  **絶対 GPU 物理アドレス（PA, $\ge \text{LOCAL\_BASE}$）** です（§11.2, 1677 行, §11.3, 1754 行）。「LOCAL_BASE + offset」という相対表現を完全に排除しました。
- **`HOST_LIMIT` の定義**:
  **32-bit バイト物理アドレスのアパーチャ閾値**（4 KiB アライメント）です（§11.3, 1754 行）。PFN 表現を排除しました。$0 \le \text{PA} < \text{HOST\_LIMIT}$ がホスト PCIe AXI DMA にルーティングされ、$\text{PA} \ge \text{LOCAL\_BASE}$ がローカル VRAM にルーティングされます。
- **4 GiB 超の表現**:
  GPU 内部の物理バスアドレス空間は 32-bit アパーチャとしてマッピングされており、4 GiB を超えるホスト物理メモリへのアクセスは PCIe ルートコンプレックス / IOMMU によるインバウンド DMA アドレス変換（IOVA）を介して行われます。
- **DISP2 のスキャンアウトレジスタ**:
  DISP2 の `FB_BASE` (+0x20) および `FB_NEXT` (+0x24) は **32-bit GPU 物理アドレス** です（§13.2, 2446〜2447 行）。ローカル VRAM（$\ge \text{LOCAL\_BASE}$）またはホスト DRAM（$< \text{HOST\_LIMIT}$）の物理アドレスを直接指定します。

### N13 [H] タイル配置規則、ピッチ、圧縮フォーマット、および DMA パケット詳細
- **タイルのマクロ配置**:
  $8 \times 8$ テクセルのマイクロタイル（Morton 順）は、サーフェス上を行優先（Row-Major）で配置します（§8.5.2, 1460〜1464 行）：
  $$\text{tile\_offset} = (t_y \times \text{tile\_row\_pitch\_bytes}) + (t_x \times \text{tile\_size\_bytes})$$
  ここで $\text{tile\_row\_pitch\_bytes} = \lceil \text{width} / 8 \rceil \times \text{tile\_size\_bytes}$（256 バイトアライメント）。
- **圧縮フォーマット（BC1〜7, ETC2）のタイル配置**:
  $4 \times 4$ テクセルブロック（8 または 16 バイト）が $2 \times 2$ ブロック集まって $8 \times 8$ マクロタイルを形成し、Morton 順で格納されます（§8.5.2, 1465〜1466 行）。
- **タイルド mipmap 配置**:
  各 mip レベルが独立したタイルグリッドを持ち、256 バイト境界で連続配置されます（§8.5.2, 1467〜1468 行）。
- **DMA / Blit コマンドパケットの完全配置**:
  §7.3 にすべてのパケット構造を dword 単位で明記しました：
  - `CMD_COPY_BUFFER` (0x40): 8 dw（flags [0] async, [1] fill_pattern, [2] flush_src, [3] flush_dst; 4-byte aligned size; fill_data）（959〜972 行）
  - `CMD_COPY_IMAGE` (0x41): 8 dw（src_va, dst_va, src_xy, dst_xy, extent）（974〜984 行）
  - `CMD_BLIT` (0x42): 10 dw（src_va, dst_va, src_min/max_xy, dst_min/max_xy, filter）（986〜998 行）
  - `CMD_FILL_BUFFER` (0x43): 5 dw（dst_va, size, pattern）（1000〜1007 行）
  - `CMD_RESOLVE_IMAGE` (0x44): 9 dw（src_va, dst_va, src_xy, dst_xy, extent, mode）（1009〜1020 行）
  - `CMD_COPY_BUFFER_TO_IMAGE` (0x45): 8 dw（src_buf_va, dst_img_va, pitch, xy, extent）（1022〜1032 行）
  - `CMD_COPY_IMAGE_TO_BUFFER` (0x46): 8 dw（src_img_va, dst_buf_va, pitch, xy, extent）（1034〜1044 行）

### N14 [H] ステンシル front/back、LogicOp、MRT Blend、MSAA、Vertex Stride
- **ステンシル front/back の op エンコーディング**:
  `GhciPipelineState.depth_stencil_state`（dw10）に Front および Back の全操作（fail, pass, depthFail, compareOp 各 3-bit）を完全割当しました（§8.2, 1177 行, 1200〜1202 行）：
  - `[8:6]` front_fail, `[11:9]` front_pass, `[14:12]` front_depth_fail, `[17:15]` front_compare
  - `[20:18]` back_fail, `[23:21]` back_pass, `[26:24]` back_depth_fail, `[29:27]` back_compare
  - `[30]` separate_back_stencil_enable
- **LogicOp の配置**:
  `flags`（dw8）の `[9:6]` に 4-bit `VkLogicOp`（0..15）を配置しました（§8.2, 1175 行, 1195〜1196 行）。`[5]` が logic_op_enable です。
- **アタッチメント毎の Blend (`CAP_MRT_BLEND`)**:
  `EXT_CAP_FEATURE[15]` が `CAP_MRT_BLEND` を示します。1 の場合、ドライバは `CMD_SET_DYNAMIC_STATE`（state_id 7..14）により各カラーアタッチメント 0..7 のブレンドを個別に設定可能です（§8.2, 1208〜1211 行）。0 の場合は dw11 が全アタッチメントに一括適用されます。
- **MSAA 関連フィールド**:
  `flags`（dw8）に `[10] alpha_to_coverage`, `[11] sample_shading`, `[15:12] sample_mask`、`raster_state`（dw9）に `[13:6] line_width`（8-bit 固定小数点: 16 = 1.0）を配置しました（§8.2, 1175〜1176 行）。
- **Vertex Stride の優先順位**:
  `CMD_BIND_VERTEX_BUFFERS` が動的 32-bit stride（> 0）を指定した場合はそれが常に優先され、`stride == 0` が指定された場合にのみ PSO dw12 のデフォルト 8-bit stride が適用されます（§8.2, 1179 行）。

### N16 [H] MMIO レジスタマップ整合（ISA_ID, WDT_CYCLES, GCLK_HZ, CAPS）
- **`WDT_CYCLES` と `NATIVE_ISA_ID` の分離**:
  `0x048` は厳密に `WDT_CYCLES`（RW）です（§3.1, 224 行）。`NATIVE_ISA_ID`（RO, `"GSI1"` = `0x47534931`）は空いていた MMIO **`0x068`** に確定配置しました（§3.1, 232 行, §3.2.1, 271 行）。
- **`GCLK_HZ` の配置**:
  MMIO **`0x064`** が正本です（§3.1, 231 行）。`VEND+0x10` は Page 0 のミラーです。
- **旧 `CAPS2` の完全排除**:
  旧 `CAPS2` は削除され、L2/L1 キャッシュ仕様は `MEM` 拡張機能（`0x1E0 + 0x14`）、LDS 容量は `EXT_CAP_FEATURE[27:20]` に配置されています（§11.5.1, 1790〜1810 行）。
- **§12 の CAPS と `DEVICE_CAPS` の関係**:
  §12 の旧 GSI1 コア内部機能ビットとホスト MMIO レジスタとの対応関係を §12.1（1868〜1878 行）に明記しました：
  - Subgroup 命令（`shfl`, `vote`, `ballot`）: `EXT_CAP_FEATURE[29]`（`CAP_SUBGROUP`）
  - Packed FP16 演算: `DEVICE_CAPS[6]` / `EXT_CAP_FEATURE[28]`（`CAP_FP16`）
  - 高度テクスチャ（.3 形式, 深度比較, gather）: `DEVICE_CAPS[25]`（`CAP_TEX_FFILT`）
  - マルチサンプリング問い合わせ（`texsz.s`）: `DEVICE_CAPS[31]`（`CAP_MSAA_4X`）
  - ROP パッカー: `DEVICE_CAPS[26]`（`CAP_ROP_PACK`）
  - メモリ保護: `DEVICE_CAPS[24]`（`CAP_PROT`）

### N32 [H] 仕様書（ghci.md）と C ヘッダ（ghci_cmd.h）の整合性
- **正本の決定**:
  **`docs/ghci.md` がアーキテクチャ仕様の唯一の正本** であり、`include/ghci_cmd.h` は仕様書と 100% ビット完全同期する実装ヘッダと定義しました（§7.2, 710〜711 行）。
- **BARRIER flags の完全同期**:
  `include/ghci_cmd.h`（363〜369 行）および §7.3（906〜913 行）を同期：
  `WAIT_IDLE` (bit 0), `INVAL_ICACHE` (bit 1), `INVAL_TEX` (bit 2), `FLUSH_L1_DATA` (bit 3), `INVAL_L1_DATA` (bit 4), `INVAL_DESCRIPTOR` (bit 5), `FLUSH_L2` (bit 6)。
- **FENCE flags の完全同期**:
  `include/ghci_cmd.h`（382〜385 行）、§7.3（933〜937 行）、および §9.1（1514〜1515 行）を同期：
  `IRQ` (bit 0), `MEM_WRITE` (bit 1), `HOST_FLUSH` (bit 2)。
- **`GhciCmdQuery` の 4 dword 化**:
  `include/ghci_cmd.h`（399〜404 行）を 4 dword（64-bit `query_pool_va`, `query_index_and_flags`）に改訂し、§7.3（1033〜1040 行）と完全一致させました。

### N01 [M] used_regs 上限、Mesh/Task シェーダ、および local_size
- **`used_regs` の上限（63）**:
  GSI1 ISA §12.3 において汎用レジスタは `r0..r62` の 63 本であり、オペランド 63 はシストリックキュー `rq`（予約）です。したがって汎用レジスタ割り当ての上限は **63** であり、PSO dw13 の有効値は **1..63**（`r0..r(used_regs-1)`）です（§8.2, 1180 行, §12.2, 1884〜1886 行, §12.10.1, 2212 行）。
- **Mesh / Task シェーダのレジスタ数**:
  Mesh/Task シェーダ（`ms_code_va`）はコンピュートワープで動作するため、レジスタ割り当て数は **`used_regs_cs`（dw13 `[23:16]`）** が適用されます（§8.2, 1180 行, 1187〜1188 行, §12.10.1, 2212 行）。
- **`local_size` エンコーディングとハードウェア上限**:
  dw14 のビットフィールドは最大 1024 まで表現可能ですが、ハードウェアの上限は `maxComputeWorkGroupSize = {256, 256, 64}` かつ総インボケーション数 $\le 256$ です（§8.2, 1181 行, §8.6, 1495 行）。

### N03 [M] Render Pass の baseArrayLayer、Resolve、Clear 解釈
- **`base_array_layer` フィールドの追加**:
  `GhciColorAttachmentDesc`, `GhciDepthStencilAttachmentDesc`, `GhciResolveAttachmentDesc` のパディングバイトを `uint8_t base_array_layer`（0..255）として定義しました（§8.4, 1297 行, 1307 行, 1317 行, `include/ghci_cmd.h`, 522 行, 532 行, 542 行）。
- **Resolve アタッチメント数**:
  `GhciRenderPassDesc.resolve` はカラーアタッチメント 0（標準スワップチェーン target）のレンダーパス終了時自動ハードウェア resolve 先を定義します。アタッチメント 1..7 の MRT resolve はドライバが `CMD_RESOLVE_IMAGE`（0x44）を発行して実行します（§8.4, 1346〜1349 行）。
- **`clear_color_table_va == 0` 時のクリア値解釈**:
  `clear_color_table_va == 0` の場合、ハードウェアはフォーマットに応じた **全ゼロ（0.0f / integer 0 / 透明黒）** でクリアします（§8.4, 1343〜1344 行）。アタッチメント 0 は `CMD_BEGIN_RENDER_PASS.color_clear_rgba` を適用可能です。

### N07 [M] Session 0 root table の再作成タイミングと Reset 後の再マッピング
- **`CTRL.RUN` 0→1 での root table の扱い**:
  Session 0 の root table（4 KiB）は、全デバイスリセット（`CTRL.RESET = 1 -> 0`）後の最初の `CTRL.RUN = 1` 投入時にのみ `CP_HEAP_BASE` に初期化されます。通常の `RUN = 0 -> 1`（一時停止・再開）では **作り直されず、既存のセッションおよびマッピングがそのまま保持されます**（§11.2, 1648〜1651 行）。
- **Reset 後の Session 0 マッピング**:
  全リセット（`CTRL.RESET = 1`）後はヒープポインタが `CP_HEAP_BASE` に戻るため、ドライバ（KMD）はクライアントセッションを開く前に **Session 0 自身のページマッピング（`CMD_VM_MAP`）を再発行** します（§5.2 step 7, 574 行, App. A step 7, 2630 行）。

### N21 [M] ディスクリプタ事象通知、DISP2 割り込みステータス/マスクレジスタ
- **`IRQ_STATUS` bit 3 への一本化**:
  ディスプレイコントローラの全事象はプライマリ割り込み **`IRQ_STATUS[3]`（`GHCI_IRQ_DISPLAY`）** に集約されます（§3.4, 400 行, §9.2, 1525 行, §13.2, 2403〜2404 行）。旧記述「bit 9-12」を完全削除しました。
- **DISP2 内部イベントレジスタの追加**:
  DISP2 レジスタウィンドウ内に以下を追加しました（§13.2, 2446〜2447 行）：
  - `+0x18`: `DISP_IRQ_STATUS` (R/W1C) — `[0] VSYNC`, `[1] FLIP_DONE` (Plane 0), `[2] CURSOR_FLIP_DONE` (Plane 1), `[3] HOTPLUG`, `[4] UNDERFLOW`
  - `+0x1C`: `DISP_IRQ_ENABLE` (RW) — DISP2 各事象の割り込みマスク（非ゼロで `IRQ_STATUS[3]` をアサート）
  ドライバは `DISP_IRQ_STATUS` を読んで事象を特定し、W1C でクリアします。

### N23 [M] テクスチャ記述フォーマット、サンプラー compare_op、カスタムボーダー色
- **テクスチャフォーマットの VkFormat 化**:
  `GhciTextureDescriptor.format` を `VkFormat` 列挙値直接指定として定義を統一しました（§8.3, 1231 行, `include/ghci_cmd.h`, 207 行）。
- **`compare_op` の値**:
  `VkCompareOp` と 1:1 完全一致（0: NEVER, 1: LESS, 2: EQUAL, 3: LEQUAL, 4: GREATER, 5: NOTEQUAL, 6: GEQUAL, 7: ALWAYS）です（§8.3, 1252 行, `include/ghci_cmd.h`, 226 行）。
- **カスタムボーダー色テーブルの配置**:
  16 エントリ（各 128-bit `VkClearColorValue` = 256 バイト）のテーブルは、**`CMD_SET_DYNAMIC_STATE`（state_id `0x10`）** によりテーブルの 64-bit GPU VA を渡してバインドします（§8.3, 1258 行）。

### N24 [M] KC705 LDS 4 KiB と Vulkan 1.0 適合性
- **ビット配置の重なり解消**:
  N31 にて `EXT_CAP_FEATURE[27:20]` に確定分離しました。
- **KC705 でのコンピュート提供方針**:
  KC705 FPGA プロトタイプでは Block RAM 制約により 4 KiB となります。Vulkan 1.0 厳格準拠テストを行う場合、ドライバは 4 KiB 超の LDS 要求に対してスクラッチメモリへのコンパイラスピルを行うか、またはコンピュートキューファミリを露出せずラスタライザ特化デバイスとして公開します。量産 ASIC では 16 KiB / 64 KiB をネイティブ提供します（§8.6, 1496 行, §11.5.1, 1809 行）。

### N25 [M] CMD_FLIP 8 dword 化、TAKEN 値、フリップレコード、および DDC/EDID
- **`CMD_FLIP` パケット構造の 8 dword 化**:
  パケット構造を 8 dword に確定しました（§7.3, 1047〜1064 行, `include/ghci_cmd.h`, 616〜629 行）：
  - dw0: Header (opcode = 0x51, dwords = 8)
  - dw1: `display_id` (0..1)
  - dw2-3: `base_lo/hi` (64-bit PA)
  - dw4: `flags` (`[0]` VSYNC_WAIT, `[1]` IMMEDIATE, `[2]` PLANE_CURSOR [0: FB, 1: Cursor], `[3]` RECORD_ENABLE)
  - dw5: `value`（プレゼンテーション追跡タグ、`TAKEN0`/`TAKEN1` にラッチ）
  - dw6-7: `record_pa_lo/hi`（16 バイトレコードの 64-bit 物理アドレス）
- **完了レコードの内容**:
  `RECORD_ENABLE` 指定時、フリップ完了時に 16 バイトレコード `{ uint32_t value, uint32_t frame_count, uint32_t timestamp_lo, uint32_t timestamp_hi }` を `record_pa` に書き込みます（§7.3, 1064 行）。
- **DDC / EDID の読み出し経路**:
  DISP2 レジスタ `0x60 I2C_CTRL`, `0x64 I2C_DATA`, `0x68 I2C_STATUS`（MMIO `0x260`..`0x268`）がディスプレイコネクタの DDC I2C バス（スレーブアドレス `0x50` / `0xA0`）に直結された I2C マスターです。ドライバはこの I2C レジスタを介して 128 バイトの EDID EEPROM を直接読み出します（§13.2, 2454〜2456 行）。

### N31 [M] EXT_CAP_FEATURE のビット重複解消と maxColorAttachments の正本
- **ビット割り当ての完全分離**:
  `EXT_CAP_FEATURE`（0x084）のビット割り当てを以下のように再設計・確定しました（§3.2.2, 280〜298 行）：
  - `[14]`: `CAP_COLOR_LUT`
  - `[15]`: `CAP_MRT_BLEND`（独立ブレンド対応）
  - `[19:16]`: `MAX_MRT`（4-bit, 値 1..8）
  - `[27:20]`: `CAP_LDS_SIZE_KB`（8-bit, 値 0..255 KiB）
  - `[28]`: `CAP_FP16`
  - `[29]`: `CAP_SUBGROUP`
  - `[31:30]`: 予約（0）
- **`maxColorAttachments` の単一正本**:
  **`EXT_CAP_FEATURE[19:16]`（`MAX_MRT`）が単一の正本** です。`EXT_CAP_FMT0[15:12]` および `FMT_LIMITS[3:0]` はこれをミラーしており、すべて 8 を返します。

### N04 [L] 二次コマンドバッファ内の禁止コマンドの fault kind
- **違反種別に応じた厳格な区別**:
  - **`kind 6` (`GHCI_FAULT_KIND_PROT_FAULT`)**: 特権・セキュリティ境界違反（セッション/MMU 操作 `CMD_VM_MAP`, `CMD_VM_UNMAP`, `CMD_SESSION_OPEN`, `CMD_SESSION_CLOSE`, `CMD_BIND_SESSION`、ディスプレイ制御 `CMD_DISP_SET`, `CMD_FLIP`、ホスト PA 書き込み `CMD_FENCE`, `CMD_WAIT_FENCE`, `CMD_WRITE_TIMESTAMP` with flags[0]=1）を検出したときに発生（§6.0, 604〜607 行）。
  - **`kind 1` (`GHCI_FAULT_KIND_INVALID_OP`)**: 構造的・プロトコル違反（二次バッファの入れ子実行 `CMD_EXECUTE_COMMANDS` [syndrome `0x0001`]、または未定義/不正サイズオペコード）を検出したときに発生（§6.0, 608 行）。

### N17 [L] Occlusion Query の availability word 配置
- **AVAILABILITY word のメモリオフセット**:
  - `flags[1] (AVAILABILITY) == 0`: 1 クエリあたり 8 バイト（64-bit カウントのみ）。$\text{query\_pool\_va} + (\text{query\_index} \times 8)$ に書き込み（§7.3, 1038〜1039 行）。
  - `flags[1] (AVAILABILITY) == 1`: 1 クエリあたり 16 バイト（Vulkan `VK_QUERY_RESULT_WITH_AVAILABILITY_BIT` 準拠）。$\text{query\_pool\_va} + (\text{query\_index} \times 16)$ に 64-bit カウントを書き込み、直後の $\text{query\_pool\_va} + (\text{query\_index} \times 16) + 8$ に 64-bit availability フラグ（`1ULL`）を書き込みます（§7.3, 1040〜1041 行）。

### N18 [L] CAP_HW_WALKER=0 および CAP_PROT=0 時の動作明確化
- **`CAP_HW_WALKER == 0` 時の SESSION_OPEN**:
  ハードウェアが MMU を持たないため Session 0 のみが有効です。`session_id >= 1` に対する `CMD_SESSION_OPEN` は **`GHCI_FAULT_KIND_KICK_ABSENT` (Kind 2) で即時リジェクト** されます（§11.6, 1816〜1817 行）。
- **`CAP_PROT == 0` 時の VM_MAP**:
  全セッションで単一のグローバルルートページテーブルを共有します。`CMD_VM_MAP` の `session_id` フィールドは無視され、共有グローバルテーブルにマッピングが登録されます（§11.6, 1818〜1819 行）。

### N28 [L] §12.11 の旧記述（WAIT_IDLE of every unit, blitter's RESOLVE）の刷新
- **旧記述の完全置換**:
  §12.11 の旧記述を完全に削除し、`CMD_RESOLVE_IMAGE`（0x44）、レンダーパス内自動 resolve（`GhciRenderPassDesc.resolve`）、および `CMD_BARRIER`（0x31, `GHCI_BARRIER_FLAG_WAIT_IDLE`）による同期規定に更新しました（§12.11, 2307〜2313 行）。

---

## 3. レグレッションテストおよび品質検証結果

1. **禁止略語チェック**:
   - `docs/`, `include/`, `rtl/`, `sim/` 全域において、禁止略語（3 文字の頭字語）の出現数は **厳密に 0 件** です。
2. **シミュレーション回帰テスト**:
   - `./sim/run.sh atg_cp atg_ghci_slim` を実行し、全テストパスを確認：
     - `PASS atg_cp (0 s)`
     - `PASS atg_ghci_slim (1 s)`

DONE