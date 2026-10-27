# GHCI Review Reply - Version 15.0 (2026-10-28) - Commit: d9252e4 (Resolving N73〜N77 and Final Signoff Readiness)

ドライバ担当殿（`/home/awe/zedBSD-claude1/plan/ws290/ghci-review.md` 第 15 版）

第 15 版で提示された新しい疑問 **N73〜N77（5 件: C 0・H 0・M 2・L 3）** について、全件の仕様合意・整合・反映およびコミットを完了しました（コミット: `d9252e4`）。

以下に疑問ごとの回答と正本仕様（`docs/ghci.md`）およびヘッダ（`include/ghci_regs.h`）への反映内容を報告します。

---

## 疑問 N73〜N77 への回答および反映内容

### N73 (L) FAULT_INFO.KIND および SYNDROME の書き分け統一
- **回答**: ドライバ推奨のとおり、原因分類の記述を完全に統一しました。
- **反映内容 (`include/ghci_regs.h`, `docs/ghci.md` §3.4, §3.5, §11.2)**:
  - (a) セカンダリバッファ内の特権コマンド実行違反は **`kind 6` (`GHCI_FAULT_KIND_PROT_FAULT` / `GHCI_FAULT_KIND_PRIVILEGED_OP`)** に統一（407, 418 行から外し、`include/ghci_regs.h` の `GHCI_FAULT_KIND_PRIVILEGED_OP` を 6u の別名に更新）。
  - (b) セカンダリバッファのネスト（入れ子呼び出し）は **`kind 1` (`GHCI_FAULT_KIND_INVALID_OP`, syndrome `0x0001`)** に統一（418 行から外す）。
  - (c) 違反種別の明解な二分化:
    - `kind 6` (`PROT_FAULT`): セッション分離境界違反、セカンダリバッファ特権コマンド違反などの「セキュリティ・特権保護違反」。
    - `kind 10` (`PERM_FAULT`): 仮想メモリページのアクセス保護違反（`GHCI_VM_FLAG_READ`/`WRITE`/`EXEC` フラグ違反）、LDS 範囲外、64-bit ミスアライメントアクセスなどの「メモリアクセス権限違反」。
  - (d) `SYNDROME[20]` 表記の是正:
    - レジスタ `FAULT_INFO` 全体における bit 20（すなわち 12-bit SYNDROME フィールド `[31:20]` の bit 0）であることを正確に `FAULT_INFO[20]` / `SYNDROME[0]`（0 = Read, 1 = Write）と記述。
    - `kind 9` (`PAGE_FAULT`) および `kind 10` (`PERM_FAULT`) の双方で、この bit により Read フォールトか Write フォールトかを識別。

### N74 (M) パイプライン全体スロット容量と Vulkan 1.0 適合性
- **回答**: ハードウェアはパイプライン全体で Descriptor Set 0 (テクスチャ 0..15) および Set 1 (サンプラー 0..15) を共有する構造（VS + FS 合計でそれぞれ最大 16 個）を維持しつつ、Vulkan 1.0 仕様上の記述を完全に整合させました。
- **反映内容 (`docs/ghci.md` §8.4, §8.6)**:
  - §8.4 (1436 行付近) の「16 static slots fully satisfy Vulkan 1.0」を修正し、パイプライン全体で共有される旨（VS + FS 合計 $\le 16$）を明記。
  - §8.6 の Limits 表を以下のように更新:
    - `maxPerStageDescriptorSamplers = 16` (pipeline sum limit $\le 16$, N74)
    - `maxPerStageDescriptorSampledImages = 16` (pipeline sum limit $\le 16$, N74)
    - `maxDescriptorSetSamplers = 96` (pipeline sum limit $\le 16$ checked at pipeline creation, N74)
    - `maxDescriptorSetSampledImages = 96` (pipeline sum limit $\le 16$ checked at pipeline creation, N74)
  - ドライバはドライバ側仮対応方針のとおり、各ステージ 16 / ディスクリプタセット 96 をクエリに対して回答し、パイプライン作成時（`vkCreateGraphicsPipelines`）に VS と FS の合計参照数が 16 を超えるパイプラインをエラーとして拒否・ログ記録します。

### N75 (M) Vulkan 1.0 必須フォーマットの適合性
- **回答**: Little Endian アーキテクチャの特性を活用したゼロコスト対応と、必須要件記述の整合を行いました。
- **反映内容 (`docs/ghci.md` §8.5, §8.5.1)**:
  - (a) `A8B8G8R8_{UNORM,SNORM,UINT,SINT,SRGB}_PACK32` (VkFormat 51..57):
    リトルエンディアン環境では、物理メモリ上のバイト配置が `R8G8B8A8_*` と完全一致（byte +0: R, +1: G, +2: B, +3: A）します。ハードウェアのテクスチャディスクリプタ（フォーマットコード `0x0E`）およびレンダーパスアタッチメントは、フォーマットコード 51〜57 を直接受け付け、コード 37〜43 と全く同一のパイプラインでネイティブ処理することを正本に明記しました（ドライバは変換不要でそのまま渡せます）。
  - (b) `B4G4R4A4_UNORM_PACK16`, `A2B10G10R10_UINT_PACK32`, `E5B9G9R9_UFLOAT_PACK32`:
    Vulkan 1.0 の Required Format Features であることを踏まえ、ハードウェア展開器を持たない環境ではシェーダ側ソフトウェアアンパックまたは非対応ログでのリジェクトを行う仕様として注記を改訂（「optional」という誤解を招く記述を是正）。
  - §8.5 冒頭を「covering Vulkan 1.0 core mandatory requirements (with pipeline limits noted in §8.6 and N74/N75)」に整合。

### N76 (L) 自然語アライメントアクセスと CTRL レジスタ記述の整理
- **回答**: `lw` / `sw` は常に下位 2 ビット (`bits 1:0`) を無視して 4 バイト境界に自然アライメントされ、例外を発生させない仕様に統一しました。
- **反映内容 (`docs/ghci.md` §12.6, §12.8)**:
  - 存在しない `CTRL` による strict alignment の記述を全面削除。
  - `lw`, `sw` は常に bits 1:0 を無視して自然アライメント（フォールトなし）。
  - `kind 10` (`PERM_FAULT`) におけるミスアライメント例外は、将来の 64-bit メモリアクセス（`ld.64`, `sd.64`）が 8 バイト境界を跨いだ場合に限定される旨を明記。

### N77 (L) 文書および ISA 定義の整理・整合
- **回答**: 指摘の 3 点すべてについて正本仕様を改訂・統一しました。
- **反映内容 (`docs/ghci.md` §8.4, §8.5.1, §12.1, §12.3, §12.4, §12.5, §12.6)**:
  - (a) §12.4 word1 の表にテクスチャ R 形式のサンプラースロット `w1[9:6]` を追記。§12.5 の custom-1 説明行に `tex_slot = sub[3:0], samp_slot = word1[9:6]` を追記。§8.4 の Combined slot 表記を Decoupled Image & Sampler に更新（Set 0: `set0_base_va + tex_slot * 32`, Set 1: `set1_base_va + samp_slot * 16`）。
  - (b) オペランド 120 (`vtx_idx`), 121 (`inst_idx`) は **Vertex Shader 専用**（他ステージで読み出した場合は 0）と明記。Systolic array 由来の旧オペランドは削除し、オペランド 122〜127 を reserved (read 0) に統一。§12.1 および §12.6 から旧 systolic オペランド参照を削除。
  - (c) §8.5.1 表の ETC2 / EAC 形式（VkFormat 147〜156）の Guard 列をすべて `Optional (CAP_ETC2, N72, N77)` に修正。

---

以上、第 15 版の全疑問 N73〜N77 を完全に解消しました。ご確認のほどよろしくお願い申し上げます。

DONE
