# GHCI Review Reply - Version 6.0 (2026-10-28) - Commit: bc3b4e6 (Target: N01〜N33)

zedBSD ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 6 版（`ghci-review.md` 2026-10-28 02:29）にて提示された残存疑問 7 件（N02, N14, N12, N16, N25, N21, N33：C 0件、H 0件、M 4件、L 3件）に対する確定回答および仕様書（`docs/ghci.md`）・C ヘッダ（`include/ghci_cmd.h`）の同期改訂内容を報告します。

なお、すべての回答において禁止略語は一切使用しておりません。

---

## 1. 残存疑問 7 件への確定回答および条文反映

### N02 [M]: 128B Push Constant 上書き時の TU 動作、c[32..511] 書込元、Vulkan Set と Hardware Set の対応
- **回答**:
  1. **TU 専用ポインタレジスタと Constant Bank の関係**:
     - `CMD_BIND_DESCRIPTOR_TABLE(set_index, table_va, count)` 実行時、CP は Memory Controller / Texture Unit（TU）内の**専用 64-bit ハードウェアレジスタ `SET_TABLE_ADDR[0..3]`** に `table_va` をラッチします。
     - Texture Unit はテクスチャフェッチ（`texl` 等）において常に `SET_TABLE_ADDR[0]`（テクスチャ）および `SET_TABLE_ADDR[1]`（サンプラ）を参照します。
     - Constant Bank $c[24..31]$ へのミラーリングは、Shader Unit（SU）の ALU 命令から 1 サイクルで Set 基底アドレスを参照できるようにするためのオペランド利便機能に過ぎません。
     - したがって、128 バイトのプッシュ定数が `CMD_LOAD_CONST` によって $c[24..31]$ を上書きした場合でも、TU の `SET_TABLE_ADDR[0..1]` レジスタは**一切影響を受けず有効のまま保持**され、その後の `texl` は正常にテクスチャ・サンプラを読み出します。
  2. **$c[32..511]$ の書込**:
     - $c[32..511]$ は、ドライバが `CMD_LOAD_CONST(offset_dwords, count_dwords, data...)` で `offset >= 32` を指定して直接書き込みます。シェーダは `lwc rd, imm(rs1)` 命令を用いて 1 サイクルでロードします。
  3. **Vulkan Descriptor Set（0〜3）とハードウェアスロット（0〜3）の対応**:
     - ドライバチームのご認識の通りです。バッファディスクリプタ（UBO/SSBO）は Vulkan Set 0〜3 がハードウェアスロット 0〜3 に 1 対 1 に対応します。
     - ハードウェア TU のテクスチャ命令は常に Set 0 をテクスチャ、Set 1 をサンプラとして参照するため、UMD はテクスチャディスクリプタをハードウェア Set 0、サンプラディスクリプタをハードウェア Set 1 に束ねて配置・バインドします（Combined Image Sampler も同様に Set 0/1 に分離して束ねます）。
- **条文反映**:
  - `docs/ghci.md`: §8.4（1411〜1425 行）

---

### N14 [M]: Dynamic State の初期値、PSO との優先度、CAP_MRT_BLEND=0 時の動作
- **回答**:
  1. **Dynamic State の初期値 / リセット時定数**:
     - 最初の `CMD_SET_DYNAMIC_STATE` 発行前（リセット直後）の既定値は以下の通り定義されます：
       - `stencil_compare_mask = 0xFF`（全ビット比較）
       - `stencil_write_mask = 0xFF`（全ビット書込許可）
       - `stencil_reference = 0x00`
       - `depth_bias = {constant: 0.0f, slope: 0.0f, clamp: 0.0f}`
       - `blend_constants = {1.0f, 1.0f, 1.0f, 1.0f}`
  2. **PSO と `CMD_SET_DYNAMIC_STATE` の優先順位（Last Writer Wins）**:
     - `CMD_BIND_PIPELINE` は PSO にベイクされた静的ベースライン値（dw9 line width, dw11 blend state）を設定します。
     - `CMD_BIND_PIPELINE` の後に `CMD_SET_DYNAMIC_STATE` が発行された場合、動的ステートが PSO のベースライン値を上書きします（`state_id = 0x04` が dw9 line width を上書き、`state_id = 0x07..0x0E` がアタッチメント $i$ の dw11 blend を上書き）。
     - その後に別な `CMD_BIND_PIPELINE` が発行された場合、新パイプラインの静的ベースライン値が再設定されます（**後勝ち・Last Writer Wins**）。
  3. **`CAP_MRT_BLEND == 0` のハードウェアに `state_id = 0x07..0x0E` を送信した場合**:
     - 独立アタッチメントブレンド回路が存在しないため、ハードウェアは `GHCI_FAULT_KIND_KICK_ABSENT`（Kind 2、syndrome `0x0007`）のフォールトを発生させます。
- **条文反映**:
  - `docs/ghci.md`: §7.3（842〜850 行）

---

### N12 [M]: 非 MMU 64-bit 番地（fence_addr）のルーティングと header の GhciCmdFlip
- **回答**:
  1. **非 MMU 64-bit アドレス（`CMD_FENCE` の `fence_addr`）のルーティング**:
     - `CMD_FENCE` の `fence_addr[63:0]` は、32-bit ローカル VRAM 窓 $[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$ に含まれる場合のみローカル DRAM へ書き込まれます。
     - それ以外（アドレスの上位 32-bit が非ゼロ、または $LOCAL\_BASE$ 未満）の場合は、すべてホスト PCIe AXI DMA マスターへルーティングされ、`HOST_LIMIT` に制限されることなく、システムの `PA_BITS`（40〜48 bit）までの 64-bit ホスト物理アドレス（または IOVA）へ直接書き込まれます。
  2. **ディスプレイスキャンアウトアドレス**:
     - ディスプレイスキャンアウトコントローラ（DISP2）は 32-bit DMA アドレス生成器を備えているため、スキャンアウトアドレスは 32-bit GPU 物理アドレス空間内（ローカル VRAM $\ge LOCAL\_BASE$、または 32-bit ホスト UMA アパーチャ $< HOST\_LIMIT$）に限定されます。
  3. **`include/ghci_cmd.h` の `GhciCmdFlip` コメント修正**:
     - `GhciCmdFlip` のコメントを本文に合わせて修正しました：
       - `base_lo`: 32-bit GPU physical scanout address (`< HOST_LIMIT` or `>= LOCAL_BASE`)
       - `base_hi`: Must be 0
       - `record_pa_lo`: 32-bit GPU physical address of 16-byte record (`< HOST_LIMIT` or `>= LOCAL_BASE`)
       - `record_pa_hi`: Must be 0
- **条文反映**:
  - `docs/ghci.md`: §7.3（959 行）
  - `include/ghci_cmd.h`: `GhciCmdFlip`（738〜746 行）

---

### N16 [M]: MEM_CACHE_CFG の 256 KiB 表現と §12.9 のドラフト注記撤廃
- **回答**:
  1. **`MEM_CACHE_CFG` のビット配置修正**:
     - 8-bit では 256 が表現できないため、32-bit レジスタ `MEM_CACHE_CFG` のビット割当を以下のように改訂しました：
       - `[15:0] L2_CACHE_KB`: 16-bit 整数値（0, 16, 64, 128, 256 KiB を直接格納可能）
       - `[23:16] L2_WAYS`: L2 連想度（0, 4, 8, 16 way）
       - `[27:24] L1_TEX_CACHE_KB`: テクスチャ L1 容量（4, 8, 16 KiB）
       - `[31:28] VF_CACHE_LINES`: 頂点フェッチャラインバッファ数（2, 4, 8 line）
  2. **§12.9 の「draft, CAPS[26]」注記の完全撤廃**:
     - §12.9 に残存していた「(draft, CAPS[26])」の注記（.3 形式、texel offset、`texsz.d`、depth compare、gather、`texqlod`）を**完全に削除**しました。
     - これらはドラフトではなく、GSI1 コア（`GHCI_CAP_GSI1 == 1`）を持つすべての Amaterrace GPU における**公式・確定の GHCI 1.0 標準命令**です。また、旧 `CAPS[26]` レジスタへの言及もすべて削除しました。
- **条文反映**:
  - `docs/ghci.md`: §11.3（1789 行）、§12.9（2150〜2240 行）

---

### N25 [L]: §13.2 の Plane 0 取り込みにおける IMMEDIATE 対応
- **回答**:
  - §13.2 2520 行目の記述を §7.3 に合わせて改訂しました：
    「Plane 0 takes its pending image at the next vsync (when `VSYNC_WAIT` is set, the default), or immediately upon packet processing (when `IMMEDIATE` is set, or while `ENABLE` is 0); `FB_BASE` then shows it (N25).」
- **条文反映**:
  - `docs/ghci.md`: §13.2（2520 行）

---

### N21 [L]: §3.4 の事象名称の DISP_IRQ_STATUS 統一
- **回答**:
  - §3.4 405 行目の旧事象名称を、`DISP_IRQ_STATUS` の公式ビット名称（`VSYNC`, `FLIP_DONE`, `CURSOR_FLIP_DONE`, `HOTPLUG`, `UNDERFLOW`, `DISP_ERROR`）に完全統一しました。
- **条文反映**:
  - `docs/ghci.md`: §3.4（399 行、405 行）

---

### N33 [L]: alpha to one 削除、centroid ビット位置、テクスチャフォーマット対応
- **回答**:
  1. **alpha to one の扱い**:
     - Amaterrace GPU はオプショナル機能である `alphaToOne` をサポートしません（回路未実装）。§12.11 の per-sample 処理手順から「then alpha to one」を完全に削除しました。
  2. **Centroid のビット位置**:
     - `fs_centroid` は PSO dw15 `compute_lds_and_flags[16]` に配置されており、dw8 の `flags` ではないことを条文内で明確化しました。
  3. **`texl` / `texf` が読み出せるフォーマットと sample count**:
     - 旧ドラフトの `TEX_IMAGE` 記述を撤廃し、テクスチャ命令が読み出せるフォーマットは **§8.5.1 の包括フォーマット対応表（Sampled 列）によって正本定義**されることを明記しました。
     - `texsz.s rd` は `GhciTextureDescriptor.sample_count` の値（1, 2, 4）を直接返します。
- **条文反映**:
  - `docs/ghci.md`: §12.9（2168〜2185 行）、§12.11（2281 行、2305 行、2321 行）

---

## 2. 成果物一覧および検証状況

1. **仕様改訂コミット**:
   - `bc3b4e6` (`bc3b4e67f2e51921356f91cb97e5ea46a8caee97`)
   - `docs/ghci.md`: 77 行修正（残存 7 件の疑問を 100% 解決）
   - `include/ghci_cmd.h`: 8 行修正（GhciCmdFlip コメント同期）
2. **C ヘッダ構文チェック**:
   - `gcc -fsyntax-only -Iinclude include/ghci_cmd.h` $\to$ **PASS**（エラー 0 件）
3. **シミュレーション回帰テスト**:
   - `./sim/run.sh atg_cp atg_ghci_slim` $\to$ **PASS**（全テスト完全通過）
4. **禁止語句チェック**:
   - リポジトリ内全ファイルおよび本返答において 0 件であることを確認済。

DONE
