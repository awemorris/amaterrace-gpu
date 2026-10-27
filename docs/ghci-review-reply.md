# GHCI Review Reply - Version 3.0 (2026-10-27) - Commit: 0fc7927 (Target: N01〜N30)

zedBSD ドライバ開発チーム（amaterrace.ko）による「GHCI レビュー 第 3 版（ghci.md 382dd77 に対する疑問 N01〜N30、2026-10-27 20:15）」で提示された全 30 項目（解決済 4 件、継続検討・新規 26 件）について、amaterrace-gpu 正準仕様書 `docs/ghci.md`（commit: `0fc7927`、2532 行）への直接改訂を完了しました。以下に各項目への対応内容、根拠節、および該当行番号を報告します。

---

## 疑問への回答（N01〜N30）

### N01 [C] PSO Shader State & Register Pool 定義
- **回答**: 
  1. `GhciPipelineState`（§8.2, 1099〜1102 行）の `dw13`〜`dw15` にシェーダリソース上限およびコンピュート/フラグ設定を正式定義しました：
     - `dw13` (`shader_resource_limits`): `[7:0] used_regs_vs`, `[15:8] used_regs_fs`, `[23:16] used_regs_cs`, `[31:24] varying_count` (0..16)。
     - `dw14` (`compute_local_size`): `[9:0] local_size_x`, `[19:10] local_size_y`, `[29:20] local_size_z`。
     - `dw15` (`compute_lds_and_flags`): `[15:0] lds_bytes`, `[16] fs_centroid`, `[17] fs_depth_export`, `[18] fs_discard`。
  2. レジスタ本数は **最大 64 本（`r0..r63`）** です。旧記述「r0..r62（63本）」のタイポを修正し、`r0..r63`（64本、インデックス 0〜63）に統一しました。
- **根拠節・行**: §8.2 (1099〜1102 行)、§12.10.1 (2099〜2106 行)。

### N02 [C] Descriptor Table インデックス・オフセット加算・命令列
- **回答**:
  1. ディスクリプタテーブルは `set 0..3` をスロットにバインドし、型混在テーブルのオフセット計算はドライバパイプラインレイアウト作成時に決定されるオフセットに基づき：
     $$\text{Descriptor VA} = \text{table\_va} + \text{binding\_offset\_bytes} + (\text{element\_idx} \times \text{descriptor\_size\_bytes})$$
     （テクスチャ 32B、サンプラ/バッファ 16B）に従ってシェーダが仮想アドレスを算出します。
  2. Uniform / Storage バッファの読み出し命令列：ディスクリプタから 64-bit ベース GPU VA を `ld.64` で取得し、データアクセスは GSI1 正準メモリ命令 `lw` / `ld.64` を実行します。
  3. Dynamic offset は、ドライバが `CMD_LOAD_CONST` を介してプッシュ定数レジスタに渡すか、バインド時にベース VA に加算します。シェーダ側は渡されたベースアドレスにオフセットを加えて `ld.64` / `lw` を発行します。
  4. §8.4 から旧式の疑似命令 `tex ld`・`gsi1_load` を完全に排除し、正準 ISA 命令（`texl`, `texb`, `ld.64`, `lw`）へ刷新しました。
- **根拠節・行**: §8.4 (1187〜1190 行)、§12.10.2 (2113〜2123 行)。

### N03 [C] In-Memory Render Pass Descriptor (`GhciRenderPassDesc`) 64-bit 化と全仕様
- **回答**:
  1. 構造体を 64-bit 完全対応の 192 バイト（64 バイト境界整列）に刷新しました：
     - 各アタッチメントに 64-bit GPU VA（`uint64_t image_va`, `depth_stencil_va`, `resolve_va`）を採用。
     - `row_pitch_bytes` を `uint32_t`（最大 4 GiB ピッチ対応、16384×4B や 16384×16B を余裕で収容）に拡張。
     - `layers` を `uint16_t`（1..2048）に拡張。
     - `mip_level` フィールド（0..15）を追加。
  2. クリア色指定と優先順位：
     - `clear_color_table_va`（64-bit GPU VA）を追加：非 0 の場合、アタッチメント 0〜7 の各 128-bit `VkClearColorValue`（float[4] / int32[4] / uint32[4]、計 128B）テーブルを参照。
     - 0 の場合、アタッチメント 0 は `color_clear_rgba`、1〜7 は 0 クリア。
     - `LoadOp == 1 (CLEAR)` またはパケットの clear_flags のいずれかが指定されていればクリアを実行（LoadOp 優先）。
  3. §7.2 opcode `0x2B` のサイズ記述を 192 バイトに修正。
- **根拠節・行**: §7.2 (724 行)、§8.4 (1192〜1264 行)。

### N04 [M] 二次コマンドバッファの権限分離と WRITE_TIMESTAMP
- **回答**:
  1. Vulkan の `vkCmdWriteTimestamp` 仕様に準拠し、二次バッファ内での `CMD_WRITE_TIMESTAMP` は **`flags[0] == 0`（セッション GPU VA クエリプールへの非同期書き込み）に限り許可** されます。ホスト物理 PA への直接書き込み（`flags[0] == 1`）および `CMD_FENCE`/`WAIT_FENCE` は禁止です。
  2. 二次バッファ内での二次バッファ呼び出し（ネスト呼び出し）は禁止されており、ハードウェアは **`GHCI_FAULT_KIND_INVALID_OP`（Kind 1, syndrome `0x0001`）** を発生させてセッションをフォルトさせます。
- **根拠節・行**: §6.0 (597〜604 行)、§7.3 (936〜938 行)。

### N05 [解決済] セッションフォルト後の動作と回収
- **確認**: 第 2 版にて解決済。クライアントセッションフォルト時、GPU は `STATUS.RUNNING` を維持し、該当セッションの描画/ディスパッチは NOP 廃棄、`CMD_FENCE` は正常完了してホスト wait queue を unblock します。
- **根拠節・行**: §3.3 (360〜379 行)、§10 (1416〜1434 行)。

### N06 [H] 単一クライアント時のセッションフォルト vs デバイス FAULTED
- **回答**: 
  - §3.3 および §10 の「開いた client の session が全部 fault したら FAULTED」という旧仕様の記述を完全に削除し、矛盾を解消しました。
  - **確定仕様**: クライアントセッション（$i \ge 1$）のフォルトは、オープンしているクライアント数が 1 つであっても、あるいは全クライアントがフォルトした場合であっても、**決してデバイスの `STATUS.FAULTED` には遷移しません**。デバイスは `STATUS.RUNNING` を維持し、ホスト KMD（セッション 0）による安全なセッションクローズ（`CMD_SESSION_CLOSE`）と資源回収が可能です。
  - `STATUS.FAULTED` に遷移するのは、セッション 0（カーネルリング）の不正操作、AXI バスデッドロック（`AXI_STUCK`）、またはウォッチドッグ満了時のみです。
- **根拠節・行**: §3.3 (370〜385 行)、§10 (1430〜1445 行)。

### N07 [M] セッション 0 ルートページテーブル確保タイミング
- **回答**:
  - 電源投入/リセット直後は `CP_HEAP_BASE/LIMIT` が 0 であるため、事前確保は行われません。
  - ホストドライバが初期化手順（Appendix A, step 4/6）において `CP_HEAP_BASE` および `CP_HEAP_LIMIT` を設定し、`CTRL.RUN = 1` をセットした瞬間に、CP ファームウェアが `CP_HEAP_BASE` の先頭 4 KiB を Session 0 のルート L1 ページディレクトリとして自動初期化します。
  - そのため、リングパケット処理が開始される時点で Session 0 のルートは常に確保完了しています。
- **根拠節・行**: §6.0 (618〜628 行)、Appendix A (2505〜2515 行)。

### N08 [M] リセット手順・CP_HEAP ページ解放・レジスタ復帰順
- **回答**:
  1. `CTRL.RESET = 1`（ソフトリセット）発行時、CP 内部のアロケーションポインタは `CP_HEAP_BASE` にリセットされ、旧ページテーブルページは自動的に全解放されます。そのためドライバは `CMD_SESSION_OPEN` および `CMD_VM_MAP` を最初から再発行します。
  2. レジスタ復帰順（§5.2 および Appendix A）を正式化：`WDT_CYCLES` 設定 $	o$ `IRQ_ENABLE` 設定 $	o$ `CTRL`（`RUN | WDT_EN | IRQ_GLOBAL`）の順で書き戻します。
  3. フォルトやリセットで中途終了した未完了フェンスは、ドライバがエラー状態 `GHCI_FENCE_STATUS_FAULT`（`0xFFFFFFFF`）を書き込んで完了させ、ホストの待機スレッドがデッドロックしないよう保証します。
- **根拠節・行**: §5.2 (563〜576 行)、§10 (1431〜1435 行)、Appendix A (2524〜2531 行)。

### N09 [H] CP_HEAP 動的拡張・割り込み・不連続時の扱い
- **回答**:
  1. **連続領域の動的拡張（オンライン）**: ホスト OS が既存の `CP_HEAP_LIMIT` に続く連続物理ページを確保できる場合、**`CTRL.RUN == 1` の稼働中のまま `GHCI_REG_CP_HEAP_LIMIT` に新しい上限 PA を直接上書きして即座に拡張可能** です。CP MMU のアロケータは次回のアロケーション時から新上限を参照します。
  2. **不連続・再配置時（一時停止）**: 連続ページが取れない場合は、`CTRL.RUN = 0` で一時停止（この間、`RING_RPTR`、リング内容、セッション情報、既存ページテーブルは完全に保持されます）し、より大きな連続領域を確保して既存ヒープをコピーし、`CP_HEAP_BASE/LIMIT` を更新して `CTRL.TLB_FLUSH = 1` 後に `CTRL.RUN = 1` で再開します。
  3. `CMD_VM_MAP` がヒープ枯渇（Kind 8 MMU OOM）で失敗した場合、そのセッションのみが停止（`SESSION_ACTIVE[S] = 0`）し、後続の同セッション宛パケットは安全にスキップされます。セッション 0 や他セッションへの影響はありません。
  4. CP_HEAP は 32-bit PA（4 GiB 未満）または Discrete GPU 上のローカル VRAM（`LOCAL_BASE` 配下）に配置可能です。
- **根拠節・行**: §11.2 (1548〜1565 行)。

### N10 [H] VM_MAP / UNMAP エッジケースとフォールト種別
- **回答**:
  - **マッピング済み領域への `VM_MAP`**: 既存の有効 PTE との衝突を検知し、**`GHCI_FAULT_KIND_PERM_FAULT`（Kind 10, syndrome `0x0010`）** を発生させ、当該セッションがフォルトします。
  - **部分 UNMAP**: 4 KiB ページ単位での任意の部分 UNMAP を完全サポートしています。
  - **未マップ領域の UNMAP**: 冪等操作（no-op）として扱い、エラーにならず正常終了します。
  - **オープン中セッションへの `SESSION_OPEN`**: **`GHCI_FAULT_KIND_INVALID_OP`（Kind 1, syndrome `0x0020`）**。セッション 0 に通知されますが、既存セッションは破壊されません。
  - **`SESSION_OPEN` 時のルート確保失敗**: `CP_HEAP` 枯渇時は **`GHCI_FAULT_KIND_MMU_OOM`（Kind 8）** が発生し、セッションはオープンされません。
  - **クローズ済みセッションへの `VM_MAP`**: **`GHCI_FAULT_KIND_INVALID_OP`（Kind 1, syndrome `0x0021`）**。
  - **Session 0 パケットのフォルト**: カーネルリングの異常であるため、デバイス全体の `STATUS.FAULTED` となります。
  - **`CAP_PROT = 0` 時の PROTECTED**: API 層では `VK_ERROR_FEATURE_NOT_PRESENT` を返し、ハードウェアに渡った場合は **`GHCI_FAULT_KIND_INVALID_OP`（Kind 1）** で即座にリジェクトします。
- **根拠節・行**: §4.1 (520〜526 行)、§11.6 (1725〜1739 行)。

### N11 [H] `fence_addr` のアドレス空間と `CMD_FENCE` フラグ
- **回答**:
  1. `fence_addr`（`CMD_FENCE` および `CMD_WAIT_FENCE`）は 64-bit 物理アドレス（PA）です。UMA ではホスト DRAM PA、Discrete GPU では `HOST_LIMIT` 境界に基づきホスト DRAM PA またはローカル VRAM PA のいずれにも配置可能です。
  2. `CMD_FENCE`（0x33）のフラグ定義を正準化・統一しました：
     - `bit 0`: `INLINE_VALUE`（64-bit シーケンス値を指定アドレスに直接書き込み）。
     - `bit 1`: `WRITEBACK` / `MEM_WRITE`（フェンス書き込み前に GPU の全ダーティライトキャッシュをフラッシュ）。
     - `bit 2`: `HOST_FLUSH` / `INTERRUPT`（書き込み完了時に `GHCI_IRQ_FENCE` 割り込みを発行）。
- **根拠節・行**: §7.3 (918〜934 行)、§9.1 (1403〜1406 行)。

### N12 [H] 64-bit PA、`HOST_LIMIT`、`LOCAL_BASE`、`FB_BASE/NEXT`
- **回答**:
  1. 40-bit 以上の PA 環境（`PA_BITS >= 40`）において、`HOST_LIMIT` はホスト DRAM とローカル VRAM を振り分ける 4 KiB ページフレーム番号境界（またはアパーチャ閾値）を表します。
  2. `CMD_VM_MAP` で `VM_FLAG_LOCAL`（bit 1）が 1 の場合、`phys_page` はローカル VRAM 内の **絶対物理アドレス（`phys >= LOCAL_BASE`）** です。
  3. DISP2 の `FB_BASE` / `FB_NEXT` は、下位 32-bit（`0x200`, `0x204`）に加え、上位 32-bit レジスタ `FB_BASE_HI`（`0x208`）および `FB_NEXT_HI`（`0x20C`）と対になって 64-bit 物理アドレスを構成します。32-bit 環境では上位は 0 です。
- **根拠節・行**: §6.0 (616 行)、§11.3 (1649 行)、§13.2 (2314〜2320 行)。

### N13 [H] イメージレイアウト・コピー・BLIT パケット仕様
- **回答**:
  1. **タイル形状**: オプティマルタイル（`flags[0] = 1`）は **$8 \times 8$ ピクセルマイクロタイル** であり、内部はモートン（Z-order）順でインターリーブされます。
  2. **サブリソース配置**: 配列レイヤーごとに連続配置（Layer 0 の Mip 0, Mip 1... が 64B 整列で配置され、続いて Layer 1）。
  3. **Depth/Stencil パッキング**: D24S8 は 32-bit インターリーブ（Depth `[23:0]`, Stencil `[31:24]`）、D32S8 は 64-bit インターリーブ（Depth float32 `[31:0]`, Stencil uint8 `[39:32]`）。
  4. **バッファ $\leftrightarrow$ イメージコピー**: 専用コマンド `CMD_COPY_BUFFER_TO_IMAGE`（0x45, 8 dw）および `CMD_COPY_IMAGE_TO_BUFFER`（0x46, 8 dw）を新設・定義。
  5. `CMD_COPY_IMAGE`（0x41, 8 dw）、`CMD_BLIT`（0x42, 10 dw）、`CMD_RESOLVE_IMAGE`（0x44, 9 dw）の完全な dword レイアウトを策定。
  6. `CMD_COPY_BUFFER`（0x40）は最小 4 バイト整列、バースト最適 64 バイト整列、フラグ `[0]` async, `[1]` fill pattern。
- **根拠節・行**: §7.2 (738〜742 行)、§8.5.2 (1360〜1373 行)。

### N14 [H] PSO 詳細パラメータ・トポロジ・頂点ストライド
- **回答**:
  1. **頂点ストライドの優先度**: `GhciPipelineState.vertex_strides`（dw12）は binding 0..3 のデフォルト 8-bit ストライドです。一方、`CMD_BIND_VERTEX_BUFFERS`（0x21）で指定された 32-bit 動的ストライド（最大 4095 バイト）がある場合、**`CMD_BIND_VERTEX_BUFFERS` が完全に優先・上書き** します。
  2. **トポロジ**: `POINT (0)`, `LINE (1)`, `LINE_STRIP (2)`, `TRIANGLE (3)`, `TRIANGLE_STRIP (4)` をサポート。`TRIANGLE_FAN` や adjacency / patch は未サポートであり、設定時は `INVALID_OP` フォルトとなります（ドライバ側でインデックス展開）。
  3. **ステンシル**: `depth_stencil_state`（dw10）に Front/Back 操作および比較演算子をエンコード。動的参照値は `CMD_SET_DYNAMIC_STATE`（0x26）で設定。
  4. **マルチ MRT ブレンド**: アタッチメント 0 の設定が全体に適用され、`CAP_MRT_BLEND` 有効時は独立ブレンドテーブルを参照します。
- **根拠節・行**: §8.2 (1098〜1112 行)。

### N15 [H] キャッシュ無効化セマンティクス（BARRIER による明示化）
- **回答**:
  - 旧仕様の暗黙の無効化（LOAD_PROGRAM, INVALIDATE）記述を完全削除しました。
  - **確定仕様**: ホストやシェーダによるメモリ更新後のキャッシュ無効化は、すべて **`CMD_BARRIER`（opcode `0x31`）のフラグ** により明示的に制御されます：
    - シェーダコード更新時: `flags[4] = 1` (`INVAL_ICACHE`)。
    - テクスチャ更新時: `flags[3] = 1` (`INVAL_TEX`)。
    - コンピュート $	o$ 頂点/ホスト読み出し: `flags[1] = 1` (`FLUSH_L1_DATA`) & `flags[2] = 1` (`INVAL_L1_DATA`)。
    - ディスクリプタ / PSO 更新時: `flags[5] = 1` (`INVAL_DESCRIPTOR`)。
    - なお、CP の PSO 内部ステージングは `CMD_BIND_PIPELINE` 実行時に自動無効化されます。
- **根拠節・行**: §7.3 (892〜906 行)、§11.5 (1671〜1688 行)。

### N16 [H] レジスタ競合の解消（ISA_ID vs GCLK_HZ, CAPS 配置）
- **回答**:
  1. `NATIVE_ISA_ID` の正準アドレスは **MMIO `0x048`**（読み出し値 `"GSI1"` = `0x47534931`）です。旧記述にあった `VEND+0x10` は削除しました。
  2. `GCLK_HZ` の正準アドレスは **MMIO `0x064`**（32-bit RO）です。
  3. 機能フラグは Page 0 の `DEVICE_CAPS`（`0x008`）および `EXT_CAP_FEATURE`（`0x084`）が唯一無二の正準ソースです。
- **根拠節・行**: §3.1 (231 行)、§3.2.1 (268〜275 行)、§4.1 (478〜482 行)。

### N17 [M] オクルージョンクエリ 64-bit 化と間接ディスパッチ
- **回答**:
  1. `CMD_BEGIN_QUERY` / `CMD_END_QUERY` を 4 dwords に拡張し、`query_pool_va_lo` / `query_pool_va_hi` による **完全 64-bit GPU VA** 指定に対応しました。
  2. dword 3 に `[24] flags[0]` (PRECISE: 1 = 正確なサンプル数、0 = boolean pass) および `[25] flags[1]` (AVAILABILITY: 可用性ビット書き込み) を定義。
  3. `CMD_DRAW_INDIRECT`（0x29）の 8 dw 形式において、header `flags[0]` または dword 7 にて indexed（`VkDrawIndexedIndirectCommand`）を指定可能としました。
  4. 新規コマンド **`CMD_DISPATCH_INDIRECT`（opcode `0x2E`, 6 dw）** を正式追加しました。
- **根拠節・行**: §7.2 (722, 727, 735 行)、§7.3 (836〜864, 940〜948 行)。

### N18 [M] CAP_PROT=0, CAP_HW_WALKER=0 時の動作
- **回答**:
  - `CAP_HW_WALKER = 0`: MMU なしのフラット物理アドレス動作。`CMD_SESSION_OPEN` は Session 0 のみを返し、`CMD_VM_MAP`/`UNMAP` は `GHCI_FAULT_KIND_KICK_ABSENT`（Kind 2）を返します。
  - `CAP_HW_WALKER = 1, CAP_PROT = 0`: 仮想記憶は有効ですが、全セッションでグローバルページテーブルを共有します（プロセス間保護なし）。
  - `CAP_HW_WALKER = 1, CAP_PROT = 1`: 完全なマルチセッション保護（セッションごとに独立したルートページテーブル）。
  - `VM_FLAG_COHERENT`（bit 2）はスヌープまたは L1/L2 キャッシュバイパスを有効化し、`VM_FLAG_WC`（bit 3）は Write-Combining 設定を行います。
- **根拠節・行**: §11.6 (1710〜1724 行)。

### N19 [M] EXT_CAP_FMT0 ビット配置・重複削除・FMT_OPTIMAL
- **回答**:
  1. §3.2.2（旧 302〜305 行）にあった重複行を完全に削除しました。
  2. `EXT_CAP_FMT0`（`0x080`）の正準ビット配置：
     `[6:0]` BC1-BC7, `[7]` ETC2, `[8]` ASTC（予約0）, `[9]` sRGB, `[10]` FP16_FILTER (`CAP_TEX_FFILT`), `[11]` FP32_FILTER, `[15:12]` `MAX_COLOR_ATTACHMENTS`（8 を報告）。
  3. `maxColorAttachments` は `MAX_MRT`（`EXT_CAP_FEATURE[18:15]`）および `FMT_LIMITS[3:0]` と完全に一致（8）します。
  4. `FMT_OPTIMAL` のビット配置を定義：`bit 0: SAMPLE`, `bit 1: FILTER_LINEAR`, `bit 2: COLOR_ATTACHMENT`（Vulkan の `1 << 7` に対応）, `bit 3: BLEND`, `bit 4: DEPTH_STENCIL`, `bit 5: VERTEX_BUFFER`, `bit 6: BLIT_SRC`, `bit 7: BLIT_DST`, `bit 8: STORAGE_IMAGE`。
- **根拠節・行**: §3.2.2 (285〜304 行)、§4.1 (483〜495 行)。

### N20 [解決済] ISA フォールトの Kind 1/9/10 分類
- **確認**: 第 2 版にて解決済。未定義命令/不正修飾子は Kind 1、未マップアクセスは Kind 9、保護違反/読み書き権限違反は Kind 10 に分類され、`FAULT_INFO` に stage と PC が記録されます。
- **根拠節・行**: §3.5 (404〜425 行)、§12.6 (1911〜1920 行)。

### N21 [M] 割り込みステータスビット・フレーミングエラー種別・DISP2
- **回答**:
  1. §3.4 の `IRQ_STATUS` 定義（`[0] FENCE`, `[1] FAULT`, `[2] WATCHDOG`, `[3] DISPLAY`, `[5] SOFT`）が正準仕様です。
  2. §6.2 のフレーミングエラー種別を「kind 2」から **`GHCI_FAULT_KIND_BAD_REG`（Kind 3）** に修正しました。
  3. トップレベルの `IRQ_DISPLAY`（bit 3）は DISP2 サブシステムの集約割り込みであり、詳細な VSYNC / HSYNC / UNDERFLOW 事象は DISP2 `STATUS`（`0x214`）で読み取り・クリアされます。
- **根拠節・行**: §3.4 (383〜403 行)、§6.2 (661 行)、§9.2 (1420〜1425 行)。

### N22 [解決済] グラフィックス・コンピュート PSO バインドポイント分離
- **回答**: 第 2 版にて解決済。`CMD_BIND_PIPELINE` の `flags[0]` により 0=Graphics, 1=Compute を分離し、双方が独立してアクティブ状態を保持します。
- **根拠節・行**: §7.3 (748〜760 行)。

### N23 [M] フォーマット指定の VkFormat 一本化とサンプラ詳細
- **回答**:
  1. すべての記述（テクスチャ、アタッチメント、バッファ）において、曖昧さのあった独自 ID（1..14）を全廃し、**`VkFormat` 列挙値（1..130+）に完全一本化** しました（例: `VK_FORMAT_R8G8B8A8_UNORM = 37`, `VK_FORMAT_D32_SFLOAT = 126` など）。
  2. `GhciSamplerDescriptor`（16 バイト, §8.3）に以下を正式追加・定義：
     - `0x0C max_anisotropy`: 最大異方性比率（1..16）。
     - `0x0D border_color_type`: 0=TransparentBlack, 1=OpaqueBlack, 2=OpaqueWhite, 3=CustomTable。
     - `0x0E border_color_idx`: 128-bit カスタムボーダー色テーブルへのインデックス（0..15）。浮動小数点および整数ボーダー色に完全対応。
- **根拠節・行**: §8.3 (1135〜1155 行)、§8.4 (1198 行)。

### N24 [M] LDS 容量通知・2x MSAA・maxStorageBufferRange
- **回答**:
  1. **LDS 容量通知**: `EXT_CAP_FEATURE`（`0x084`）の `[23:16]` に `CAP_LDS_SIZE_KB` を新設しました。KC705 評価機では 4 KiB（4096 バイト）、製品 ASIC では 16 KiB（16384 バイト）が報告されます。KC705 でも 4 KiB 以下のコンピュートシェーダは完全に動作します。
  2. **2x MSAA**: §12.11 および §8.5.2 にて、1, 2, 4 サンプルを正式サポートとして整合させました。
  3. **maxStorageBufferRange**: 64-bit GPU VA 空間において、1 つのバッファディスクリプタあたり最大 4 GiB（$2^{32}-1$ バイト）をサポートします。
- **根拠節・行**: §3.2.2 (292 行)、§8.6 (1342, 1362 行)、§12.11 (2133 行)。

### N25 [M] `CMD_FLIP` パケット構造・完了レコード・表示モード
- **回答**:
  1. `CMD_FLIP`（0x51）を 6 dword の正準レイアウトに確定しました：
     - dw0: Header (opcode 0x51, count 6)
     - dw1: `display_id`（0=Primary, 1=Secondary）
     - dw2-3: `base_lo` / `base_hi`（64-bit スキャンアウト物理アドレス）
     - dw4: `flags`（`[0]` VSYNC_WAIT, `[1]` IMMEDIATE, `[2]` RECORD_ENABLE）
     - dw5: `flip_record_va_lo`（完了レコード物理/GPU アドレス；0 でレコード書き込み無効）
  2. `RECORD_ENABLE` 有効時、VSYNC 完了時にハードウェアが `{ uint32_t frame_count, uint32_t timestamp }` を書き込みます。
  3. 固定モードテーブルに加え、DISP2 コントローラの I2C/DDC マスタ（`0x230..0x238`）を通じて接続モニタの生 EDID（128/256B）を直接読み取り可能です。
- **根拠節・行**: §7.3 (1040〜1052 行)、§13.2 (2314〜2330 行)。

### N26 [M] ウォッチドッグタイマ計時仕様・一時停止・満了動作
- **回答**:
  1. **パケット単位計時**: カウンタは各コマンドパケットの開始時に **自動的に 0 にリセット** されます（パケット間累計ではありません）。
  2. **一時停止（`wdt_hold`）**: 以下の外部待機中、タイマはハードウェアによって一時停止されます：
     - コマンドリング空（`RING_RPTR == RING_WPTR`）
     - `CMD_WAIT_FENCE` によるホストフェンス待ち
     - `CMD_FLIP` による VSYNC 待ち
     - `CTRL.HALT = 1` によるホスト一時停止
     - 外部バスターンアラウンド待機（AXI レイテンシ等）
     これにより、VSYNC 待ちやフェンス待ちで誤ってウォッチドッグが発報することはありません。
  3. **満了動作**: パケット実行が `WDT_CYCLES` を超過した場合、`FAULT_INFO` に Kind 4（TIMEOUT）を記録し、`IRQ_WATCHDOG` と `IRQ_FAULT` を同時に発報します。クライアントセッション起因であればそのセッションのみを終了させて次のパケットに進みます。セッション 0 起因またはパイプラインロック時は `STATUS.FAULTED` となります。
- **根拠節・行**: §3.1 (224 行)、§10 (1447〜1470 行)。

### N27 [L] `CMD_VM_UNMAP` 完了タイミングと物理ページ再利用保証
- **回答**:
  1. `CMD_VM_UNMAP` のリタイア条件：CP が該当 PTE をクリアし、全実行ユニットへの TLB 無効化ブロードキャストの完了応答を受け取った後に初めて `RING_RPTR` が進みます。
  2. ホストによる物理ページの安全な解放・再利用タイミング：`CMD_VM_UNMAP` の直後に `CMD_FENCE` を発行し、そのフェンス完了を確認した時点で、GPU 側の全パイプラインおよびキャッシュからの参照が完全に切れたことが保証され、物理ページを安全に回収・再利用できます。
- **根拠節・行**: §6.4 (671〜680 行)、§11.2 (1568〜1575 行)。

### N28 [L] ドキュメント誤記修正・固定オフセット・MSI 条件
- **回答**:
  1. §7.3 `CMD_BARRIER` の表記を `0x31` に統一（`0x30` を削除）。
  2. §7.3 `CMD_WAIT_FENCE` の表記を `0x34` に統一（`0x37` を削除）。
  3. §4.1 の固定オフセットを `0x1E0 MEM` に修正（`0x100` はリストヘッダ）。
  4. §12.11 / §13.2 から旧式の単位名 `WAIT_IDLE` / `RESULT` を排除し、正準コマンド `CMD_BARRIER` / `CMD_FENCE` に統一。
  5. §15.2 MSI 送信条件に `CTRL.IRQ_GLOBAL == 1` を明記。
  6. §15.1 / §15.2 BAR0 アパーチャ：KC705 PCIe BAR0 は 128 KiB（先頭 64 KiB が GHCI 正準レジスタ領域）。
  7. §12.11 および §12.12 から `(draft)` 表示を削除し、Approved Architecture として確定。
- **根拠節・行**: §4.1 (480, 497 行)、§7.3 (892, 928 行)、§12.11 (2130 行)、§12.12 (2210 行)、§15.2 (2494 行)。

### N29 [解決済] UMA ブートフレームバッファのシームレス引き継ぎ
- **確認**: 第 2 版にて解決済。ファームウェアが描画したフレームバッファを、GPU リセットを介さずに DISP2 コントローラがそのままスキャンアウトし続け、OS ドライバがシームレスに引き継ぐプロトコルが策定されています。
- **根拠節・行**: §13.3 (2424〜2450 行)。

### N30 [L] `timestampPeriod` 定義の統一
- **回答**:
  - 正準計算式は常に以下です：
    $$\text{timestampPeriod (ns)} = \frac{1\,000\,000\,000}{\text{GHCI\_REG\_GCLK\_HZ}}$$
  - §8.6 に記載の「10.0 ns」は、KC705 FPGA 評価機（`GCLK_HZ = 100,000,000`）における公称値（代表例）であることを明記しました。ドライバは実行時に `GHCI_REG_GCLK_HZ`（`0x064`）を読み取って動的に算出します。
- **根拠節・行**: §3.1 (231 行)、§3.2.3 (312〜315 行)、§8.6 (1366 行)。

---

## 結論

- **N01〜N30 の全 30 項目について、疑問・食い違い・未解決事項のすべてを正準仕様書 `docs/ghci.md`（commit: `0fc7927`）に完全に反映・解消しました**。
- これにより、KMD（カーネルモードドライバ）の基盤部分にとどまらず、**シェーダ実行・ディスクリプタ管理・レンダーパス・描画・コンピュートディスパッチを含めた完全なドライバ実装を開始できる状態** が整いました。

DONE
