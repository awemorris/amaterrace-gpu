# GHCI Review Reply - Version 7.0 (2026-10-28) - Commit: 35b89af (Target: N01〜N34)

zedBSD ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 7 版（`ghci-review.md` 2026-10-28 02:38）にて提示された残存疑問 4 件（N34, N12, N14, N33：C 0件、H 0件、M 1件、L 3件）に対する確定回答および仕様書（`docs/ghci.md`）・C ヘッダ（`include/ghci_cmd.h`）の同期改訂内容を報告します。

なお、すべての回答において禁止略語は一切使用しておりません。

---

## 1. 残存疑問 4 件への確定回答および条文反映

### N34 [M]: テクスチャフォーマット別 `texl` / `texf` の戻り値仕様（浮動小数点、SNORM、整数、欠損チャンネル補完）
- **回答**:
  1. **浮動小数点フォーマット（`R16_SFLOAT`, `R32_SFLOAT`, `R16G16_SFLOAT`, `R16G16B16A16_SFLOAT`, `R32G32B32A32_SFLOAT` 等）**:
     - **[0, 1] に丸めず、格納された IEEE-754 単精度浮動小数点数の値をそのまま返します**。
     - HDR 値や負値、1.0 を超える値は完全に保持されます（旧 §12.9 の「and floating-point formats return [0, 1] normalized values」という記述は推敲時の誤記載であり、直ちに訂正しました）。
  2. **SNORM フォーマット（`R8_SNORM`, `R8G8_SNORM`, `R8G8B8A8_SNORM`, `R16_SNORM` 等）**:
     - ご認識の通り、正規化符号付き浮動小数点数値として **$[-1.0, 1.0]$** の範囲を fp32 で `rd..rd+3` に返します。
  3. **UINT / SINT フォーマット（`R8_UINT`, `R8_SINT`, `R16_UINT`, `R16_SINT`, `R32_UINT`, `R32_SINT`, RGBA 整数等）**:
     - `texl` および `texf` 実行時、`rd..rd+3` には fp32 変換を行わず、**生の 32-bit 整数ビット列（`uint32_t` / `int32_t`、8-bit/16-bit 整数は符号拡張またはゼロ拡張）** をそのまま格納します。
     - SPIR-V / Vulkan の仕様に準拠し、シェーダプログラムは `rd..rd+3` を整数レジスタとして直接演算命令で使用できます。
  4. **R / RG 等のチャンネル欠損フォーマットにおける未定義成分（G, B, A）の戻り値**:
     - Vulkan / GHCI 1.0 の標準フォーマット拡張規則に準拠します：
       - 欠損した **G 成分・B 成分は `0`（浮動小数点/UNORM/SNORM は `0.0f`、整数は `0`）** を返します。
       - 欠損した **A（Alpha）成分は `1`（浮動小数点/UNORM/SNORM は `1.0f`、整数は `1`）** を返します。
       - 具体的には：
         - R フォーマット（例: `R8_UNORM`, `R32_SFLOAT`, `R32_UINT`）: `(R, 0, 0, 1)`（float は `(R, 0.0f, 0.0f, 1.0f)`）
         - RG フォーマット（例: `R8G8_UNORM`, `R16G16_SFLOAT`）: `(R, G, 0, 1)`（float は `(R, G, 0.0f, 1.0f)`）
         - RGB フォーマット（例: `R8G8B8_UNORM`）: `(R, G, B, 1)`（float は `(R, G, B, 1.0f)`）
         - 比較なしデプスフォーマット: `(D, 0.0f, 0.0f, 1.0f)`
- **条文反映**:
  - `docs/ghci.md`: §12.9（2154〜2156 行、2186〜2194 行）

---

### N12 [L]: アドレスルーティングの記述統一、32-bit DMA 時の HOST_LIMIT 制約、CMD_WAIT_FENCE の適用
- **回答**:
  1. **ローカル VRAM 範囲記述の統一（§11.3 と §7.3）**:
     - §7.3（960 行）の定義が正です。ローカル VRAM は厳密に **$[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$** の範囲です。
     - $LOCAL\_BASE + LOCAL\_SIZE$ 以上の番地（ローカル DRAM アパーチャ内の未マッピング領域）へのアクセスは無効（未マッピング）であり、ホストへルーティングされることはなく、ハードウェア AXI デコードエラー（フォールト Kind 4 `GHCI_FAULT_KIND_AXI_ERROR`）を発生させます。
     - §11.3（1788 行）の記述を §7.3 に完全統一し修正しました。
  2. **IOMMU 無し・32-bit DMA コントローラ環境における `fence_addr` の HOST_LIMIT 制約**:
     - ご認識の通りです。IOMMU を持たず 32-bit PCIe DMA コントローラを使用するシステムでは、物理バス幅が 32-bit であるため、ホストメモリ番地（`CMD_FENCE` および `CMD_WAIT_FENCE` の `fence_addr` を含む）は物理的に **`HOST_LIMIT` 未満（< 4 GiB）に制約** されます。
     - 64-bit DMA コントローラ（または IOMMU）を持つシステムでは、フル `PA_BITS`（40〜48 bit）がサポートされ、`HOST_LIMIT` の制限を受けません。
  3. **`CMD_WAIT_FENCE` へのルーティング規則の適用**:
     - `CMD_WAIT_FENCE`（opcode 0x34）の `fence_addr` にも、`CMD_FENCE` と**全く同一の物理アドレスルーティング規則が適用** されます。
     - $[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$ 内の番地はローカル VRAM をポーリング参照し、それ以外の番地はホスト PCIe DMA メモリを参照します。
- **条文・ヘッダ反映**:
  - `docs/ghci.md`: §7.3（960 行, 968 行）, §11.3（1788 行）
  - `include/ghci_cmd.h`: `GhciCmdWaitFence` コメント（607〜614 行）

---

### N14 [L]: Dynamic State の初期値リセット契機とセッション分離（Session Lifetime）
- **回答**:
  1. **初期値への復帰契機**:
     - 「Initial / Reset Defaults」（`stencil_compare_mask = 0xFF`, `stencil_write_mask = 0xFF`, `stencil_reference = 0x00`, `depth_bias = {0,0,0}`, `blend_constants = {1,1,1,1}`）に戻る契機は以下の 3 つです：
       1. ハードウェア電源投入時（Power-On Reset）
       2. ソフトウェアリセット実行時（`CTRL.RESET`）
       3. 新規セッションオープン時（`CMD_SESSION_OPEN`, opcode 0x01）
     - リングバッファの submission 境界や単なるコマンドバッファの切り替えではリセットされません。
  2. **セッション間分離とステートの残存**:
     - Dynamic State はハードウェア内部のコンテキストステートメモリにおいて **セッション単位（Per-Session）** で保持・管理されます。
     - `CMD_BIND_SESSION` によってアクティブセッションが切り替えられる際、切り替え先セッションの専用 Dynamic State が復元されます。
     - したがって、**あるセッションで設定された動的ステートが別なセッションの draw に漏洩・波及することは一切ありません（完全なセッション分離）**。
- **条文反映**:
  - `docs/ghci.md`: §7.3（843〜848 行）

---

### N33 [L]: §12.11 2286 行の Centroid 参照記述（PSO dw15 [16] への修正）
- **回答**:
  - ご指摘の通りです。§12.11（旧 2278 行、現 2286 行）における centroid の記述 `flags[16] fs_centroid` を、PSO dw15 [16] である **`compute_lds_and_flags[16] fs_centroid`（PSO dw15 [16]）** に修正しました。
  - これにより、§8.2（1222 行）、§12.10（2250 行）、§12.11（2286 行、2289 行、2313 行）の全記述が 100% 整合しました。
- **条文反映**:
  - `docs/ghci.md`: §12.11（2286 行）

---

## 2. 全疑問（N01〜N34）のステータス総括

本改訂（Version 7.0 / Commit `35b89af`）をもって、提示されたすべての疑問事項（N01〜N34）の解決が完了しました：

| カテゴリ | 該当 ID | ステータス |
| --- | --- | --- |
| Critical (C) | なし | 全件解決済（0 件） |
| High (H) | なし | 全件解決済（0 件） |
| Medium (M) | N34（今回解決） | 全件解決済（0 件） |
| Low (L) | N12, N14, N33（今回解決） | 全件解決済（0 件） |
| 以前の解決 | N01〜N11, N13, N15〜N32 | 全件解決済（30 件） |

- **CI / 検証ステータス**:
  - C ヘッダ構文検証: `gcc -fsyntax-only -Iinclude include/ghci_cmd.h` (PASS)
  - RTL 回帰シミュレーション: `./sim/run.sh atg_cp atg_ghci_slim` (PASS atg_cp, PASS atg_ghci_slim)

DONE
