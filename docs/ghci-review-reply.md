# GHCI Review Reply - Version 14.0 (2026-10-28) - Commit: 20bf888 (Resolving N62〜N72 and Final Signoff Readiness)

ドライバ担当殿（`/home/awe/zedBSD-claude1/plan/ws290/ghci-review.md` 第 14 版）

第 14 版で提示された新しい疑問 **N62〜N72（11 件: C 0・H 1・M 6・L 4）** について、全件の仕様合意・整合・反映およびコミットを完了しました（コミット: `20bf888`）。

以下に疑問ごとの回答と正本仕様（`docs/ghci.md`）およびヘッダ（`include/ghci_regs.h`, `include/gsi1_isa.h`）への反映内容を報告します。

---

## 疑問 N62〜N72 への回答および反映内容

### N62 (H) GSI1 テクスチャ命令における Sampler Slot エンコーディング
- **回答**: ドライバ指摘のとおり `w1[14:11]` は `tex_dw` (`w1[13:10]`) および `.sat` (`w1[14]`) と衝突していたため、テクスチャ命令で完全未使用である **`w1[9:6]`（4 ビット）を `samp_slot[3:0]` に再配置** しました。
- **反映内容 (`include/gsi1_isa.h`, `docs/ghci.md` §8.4, §12.9, §12.10.2)**:
  - `GSI1_W1_SAMP_SLOT_SHIFT 6u`（`w1[9:6]`）: サンプラースロット $k_{\text{samp}} \in [0, 15]$（Set 1）。
  - `GSI1_W1_TEX_SLOT_SHIFT 17u`（`w1[20:17]` = `sub[3:0]`）: テクスチャスロット $k_{\text{tex}} \in [0, 15]$（Set 0）。
  - これにより、`tex_du` (`[25:22]`), `tex_dv` (`[29:26]`), `tex_dw` (`[13:10]`), `.sat` (`[14]`) との重複が 1 ビットもなく完全に解消されました。
  - 「1:1 mode」という曖昧な表現を全廃し、シェーダは常に `tex_slot` と `samp_slot` を明示指定します（Combined Sampler の場合は単に `w1[9:6] = w1[20:17]` とエンコード）。

### N63 (M) FAULT_INFO.KIND の 1 対 1 一意化
- **回答**: ドライバ推奨のとおり、1 つの Kind 値に複数の異なる原因を兼ねさせる別名を全廃し、**cf8be08 の厳格な 1 対 1 定義（Kind 0〜10）に復元** しました。
- **反映内容 (`include/ghci_regs.h`, `docs/ghci.md` §3.5)**:
  - `Kind 1`: `INVALID_OP`（未定義 opcode、不正引数 `INVALID_ARG`、シェーダ未定義命令）
  - `Kind 2`: `KICK_ABSENT`（未実装ユニットキック、リング範囲外 `RING_OOB`）
  - `Kind 3`: `BAD_REG`（不正ヘッダ、パケット長不一致、セカンダリ禁止命令 `PRIVILEGED_OP`）
  - `Kind 4`: `WATCHDOG`（タイムアウト `TIMEOUT`）
  - `Kind 5`: `AXI_ERROR`（バス DECERR/SLVERR、フェンス書き込み応答エラー `FENCE_ERROR`）
  - `Kind 6`: `PROT_FAULT`（セッション保護違反、セカンダリ特権違反）
  - `Kind 7`: `LOCKED_REG`（実行中の保護 MMIO レジスタ書き込み）
  - `Kind 8`: `MMU_OOM`（CP_HEAP 枯渇）
  - `Kind 9`: `PAGE_FAULT`（未マップ仮想アドレスアクセス; Read vs Write は `SYNDROME[20]` で識別: 0=Read, 1=Write）
  - `Kind 10`: `PERM_FAULT` / `MEMORY_FAULT`（メモリアライメント違反、LDS 範囲外、メモリ保護違反）
  - `PAGE_READ` や `PAGE_WRITE` を Kind 値に直接割り振ることを廃止し、ドライバは `KIND` で純粋なハードウェア分類を一意に識別可能です。

### N64 (M) CP_HEAP 容量算定式の是正
- **回答**: ドライバ担当が提示した正確な多層テーブル容量算定式を全面的に採択しました。
- **反映内容 (`docs/ghci.md` §11.6 line 1920)**:
  $$\text{CP\_HEAP\_BYTES} \ge \sum_{\text{sessions}} \left( \text{RootBytes} + (\text{is\_va40} ? 4\,\text{KiB} \times \lceil\text{MappedRange} / 1\,\text{GiB}\rceil : 0) + 4\,\text{KiB} \times \lceil\text{MappedRange} / 2\,\text{MiB}\rceil \right) + 64\,\text{KiB}$$
  - $\text{RootBytes}$: 32-bit VA は 16 KiB、40-bit VA は 8 KiB。
  - `CAP_PROT = 0` の場合は全セッションが 1 組の共有テーブルを使うため、グローバルなマップ範囲に対して 1 回のみ算定。

### N65 (M) VS と FS での Texture / Sampler スロットの Draw パイプライン共有定義
- **回答**: ハードウェアの Draw パイプライン仕様を正確に明記しました。
- **反映内容 (`docs/ghci.md` §8.4 line 1341)**:
  - 1 回の Draw パイプラインにおいて、Set 0（textures 0..15）および Set 1（samplers 0..15）はパイプライン全体（VS + FS）で共有されます。
  - したがって、1 つのグラフィックスパイプライン内で参照可能な独立テクスチャは合計最大 16 個、サンプラーは合計最大 16 個となります（`maxPerStageDescriptorSamplers = 16` は個別ステージの単独利用時の最大値を表し、パイプライン合計 16 個の制限に従います）。

### N66 (M) Vertex Attribute 64 語化と gl_VertexIndex / gl_InstanceIndex
- **回答**: §12.3 のオペランド表に `120` と `121` を明記し、§12.10.3 の記述を整合させました。
- **反映内容 (`docs/ghci.md` §12.3, §12.10.3)**:
  - §12.3 オペランド表: `120: vtx_idx (gl_VertexIndex)`, `121: inst_idx (gl_InstanceIndex)` を定義。
  - §12.10.3: 頂点入力属性は $r0..r59$（最大 60 語）。シェーダはネイティブシステムオペランド `120` / `121` からレジスタ消費ゼロで参照可能。レガシー互換として `used_regs_vs >= 62` の場合はハードウェア VF が $r60$ / $r61$ にも自動配送。

### N67 (M) Vulkan 1.0 必須フォーマットの補完
- **回答**: §8.5.1 の表に必須フォーマットを追記し、ガード表記を整理しました。
- **反映内容 (`docs/ghci.md` §8.5.1)**:
  - `R32G32B32_UINT` (104, 12 B): Vertex Buffer = Yes, Mandatory
  - `R32G32B32_SINT` (105, 12 B): Vertex Buffer = Yes, Mandatory
  - `R32G32B32A32_SINT` (108, 16 B): Color Attach = Yes (No Blend), Vertex = Yes, Storage = Yes
  - `R16G16B16A16_SFLOAT` (97): Guard を「Mandatory (Core mandatory sampled & color attachment)」と明確化。
  - 未サポートの任意/拡張フォーマット（`B4G4R4A4_UNORM_PACK16`, `A8B8G8R8_*`, `A2B10G10R10_UINT`, `E5B9G9R9` 等）について「Vulkan 1.0 においてオプショナルであり、未サポートまたはシェーダエミュレーション」と注記。

### N68 (L) 2 sample 標準サンプル位置の本文反映
- **回答**: §12.11 line 2456 付近に確実に反映しました。
- **反映内容 (`docs/ghci.md` §12.11)**:
  - `with 2 samples, sample 0 (0.75, 0.75), sample 1 (0.25, 0.25)` を追記。

### N69 (L) IRQ_STATUS.IRQ_HALTED (bit 6) の §3.4 表への追記
- **回答**: §3.4 の IRQ_STATUS 表に bit 6 を追記しました。
- **反映内容 (`docs/ghci.md` §3.4, `include/ghci_regs.h`)**:
  - `[6] IRQ_HALTED: Core execution halted following CTRL.HALT (section 5.2, N69)` を追記。
  - `include/ghci_regs.h`: `#define GHCI_IRQ_HALTED (1u << 6)` を追加。

### N70 (M) CMD_DISP_SET のパケットサイズ統一
- **回答**: ドライバ担当推奨の **`1 + 2*N` dwords** に完全統一しました。
- **反映内容 (`docs/ghci.md` §7.2, §7.3)**:
  - §7.2 表: `1+2N`
  - §7.3 本文: `1 + 2*N dwords (header + N pairs of {offset, value}, no count word)`

### N71 (L) Vulkan limits 値の §8.6 表への追加
- **回答**: 要求された全リミットプロパティを §8.6 表に追記しました。
- **反映内容 (`docs/ghci.md` §8.6)**:
  - `subPixelPrecisionBits`: 4 (1/16 pixel grid)
  - `viewportSubPixelBits`: 0 (integer snapping)
  - `maxViewportDimensions`: { 16384, 16384 }
  - `viewportBoundsRange`: [ -32768.0, 32767.0 ]

### N72 (L) 文書内の食い違い解消
- **回答**: 3 点の食い違いをすべて統一しました。
- **反映内容 (`docs/ghci.md`)**:
  - (1) ETC2/EAC: `CAP_ETC2` (`EXT_CAP_FMT0[7]`) が 1 のとき有効（Amaterrace 標準搭載）。
  - (2) `lw`/`sw`: 自然アライメント語アクセスは bits 1:0 を無視。4 バイト境界を跨ぐミスアライメントは `kind 10 PERM_FAULT` を発生。
  - (3) Push constants: 128 bytes（$c0..c31$ の 32 語）に統一。

---

以上、全疑問 N62〜N72 の解消が完了しました。ご確認のほどよろしくお願い申し上げます。

DONE
