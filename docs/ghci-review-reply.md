# GHCI Review Reply - Version 11.0 (2026-10-28) - Commit: cf8be08 (N45 & N46 Fully Resolved)

GHCI ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 11 版（`ghci-review.md` 2026-10-28 03:45）を受理しました。

レビュー第 11 版で提示された残存疑問（N45, N46）について、ドライバ担当チームの提示された推し案に完全に従い、仕様書 `docs/ghci.md` および ISA ヘッダ `include/gsi1_isa.h` を改訂・コミット（`cf8be08`）しました。

---

## 1. 確定仕様・条文反映詳細 (N45, N46)

### N45 (L): `include/gsi1_isa.h` の pre-1.0 レガシー記述整理と機能フラグ正式化
- **レガシーコンテナヘッダ・インターフェース表の明記**:
  - `include/gsi1_isa.h` 冒頭およびヘッダ定義部に、GHCI 1.0 は pure binary（`GhciPipelineState`, §8.2, §12.10.1）を提出し、旧 16-word コンテナヘッダおよび interface kinds は pre-1.0 の後方互換性定義（deprecated）であることを明記しました。
- **機能フラグ表記の正式化**:
  - `GSI1_FLAG_PACKED`: `CAP_FP16` (`DEVICE_CAPS[6]`)
  - `GSI1_FLAG_SUBGROUP`: `CAP_SUBGROUP` (`EXT_CAP_FEATURE[29]`)
  - `GSI1_FLAG_SYSTOLIC`: GHCI 1.0 では予約（reserved）
  - `GSI1_FLAG_CENTROID`: `fs_centroid` (`PSO dw15 [16]`)
  - `GSI1_FLAG_DEPTH`: `fs_depth_export` (`PSO dw15 [17]`)
  - `GSI1_FLAG_KILL`: `fs_discard` (`PSO dw15 [18]`)
- **`lda` 注記の能力依存記述削除**:
  - Varying 64 ワード（$w = 0..63$）は GHCI 1.0 の標準コア機能であるため、「A GPU with CAPS[30]」の記述を削除し、「GHCI 1.0 supports 64 varying words (0-63, Vulkan's 64 output and input components).」に改めました。

### N46 (L): パイプライン作成拒絶時の表記（Vulkan 戻り値名の削除）
- `docs/ghci.md` §12.10.3 2298 行において、Vulkan の特定エラーコード名 `(VK_ERROR_INITIALIZATION_FAILED)` を削除し、アーキテクチャ仕様として中立な規定に修正しました：
  > "Total register allocation for attributes must satisfy $\sum C_i \le 60$ ($r0..r59$). If total required attribute registers exceed 60, the driver must reject pipeline creation."

---

## 2. 検証ステータス

- C ヘッダ構文検証: `gcc -fsyntax-only -Iinclude include/ghci_cmd.h include/gsi1_isa.h` $\rightarrow$ **PASS**
- 回帰シミュレーション: `./sim/run.sh atg_cp atg_ghci_slim` $\rightarrow$ **PASS** (100%)
- 禁止略語監査: リポジトリ全域 $\rightarrow$ **0 件完全維持**
- セッション分離・MMU 透過性要件: 完全遵守

DONE