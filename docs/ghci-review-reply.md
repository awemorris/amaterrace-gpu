# GHCI Review Reply - Version 8.0 (2026-10-28) - Commit: 89529de (Target: N01〜N36)

zedBSD ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 8 版（`ghci-review.md` 2026-10-28 02:45）にて提示された残存疑問 3 件（N12, N35, N36：C 0件、H 0件、M 0件、L 3件）に対する確定回答および仕様書（`docs/ghci.md`）の同期改訂内容を報告します。

なお、すべての回答において禁止略語は一切使用しておりません。

---

## 1. 残存疑問 3 件への確定回答および条文反映

### N12 [L]: 物理アドレスルーティングの二値判定、アパーチャの定義、フォールト種別（Kind 5 AXI_ERROR）
- **回答**:
  1. **物理アドレス振り分けの二値判定とアパーチャ**:
     - ハードウェア（`rtl/gpu/mc/atg_mc.v:396`）のルーティング論理は厳格な二値判定です：
       ```verilog
       wire g_host = HAS_LOCAL != 0 && !(g_addr >= {1'b0, LOCAL_BASE} && g_addr < LOCAL_END);
       ```
     - 判定規則：
       - 物理アドレスが **$[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$** の範囲内にある場合 $\rightarrow$ ローカル VRAM（DDR コントローラ）へルーティング。
       - 物理アドレスが上記範囲外（$[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$ の外）にある場合 $\rightarrow$ すべてホスト PCIe AXI DMA バスへルーティング（`g_host`）。
     - したがって、ハードウェア内部に「$LOCAL\_BASE + LOCAL\_SIZE$ 以上の番地をホストへ送る前に遮断して内部フォールトにするローカル DRAM アパーチャ境界」というものは存在しません。
     - ホストバスへ送出された番地がホスト PCIe アドレス上限（`PA_BITS`）を超過している場合、またはホスト側インターコネクトから DECERR / SLVERR が返答された場合に、ハードウェアはバスフォールトを生成します。
  2. **フォールト種別の整合性（Kind 5 `GHCI_FAULT_KIND_AXI_ERROR`）**:
     - §3.5（418〜419 行）の定義が正です：
       - `4`: `GHCI_FAULT_KIND_WATCHDOG`（ウォッチドッグタイマ満了）
       - `5`: `GHCI_FAULT_KIND_AXI_ERROR`（バス / AXI デコード・スレーブエラー）
     - 前回回答書および §11.3 の「Kind 4」という記述は誤記であり、正しくは **Kind 5 (`GHCI_FAULT_KIND_AXI_ERROR`)** です。本文 §11.3（1789 行）を Kind 5 に訂正しました。
- **条文反映**:
  - `docs/ghci.md`: §11.3（1789 行）

---

### N35 [L]: §7.3 844 行の `CMD_SESSION_OPEN` opcode 誤記修正（0x12）
- **回答**:
  - ご指摘の通りです。§7.3（844 行）の `CMD_SESSION_OPEN` の opcode 記述 `0x01` は単なるタイポであり、正しくは **`0x12`** です。
  - §7.1（717 行）、§7.3（1098 行）、§9.1（1668 行）、および `include/ghci_cmd.h`（`GHCI_CMD_SESSION_OPEN = 0x12u`）の定義と完全に一致させ、`CMD_SESSION_OPEN, 0x12` に訂正しました。
- **条文反映**:
  - `docs/ghci.md`: §7.3（844 行）

---

### N36 [L]: `texf` の形式別戻り値規則とサンプラフィルタ・デプス比較のバイパス
- **回答**:
  - ご認識の通りです。`texf`（整数テクセル座標指定によるフェッチ命令、Vulkan `OpImageFetch` に対応）は、**§12.9 で定めた各フォーマットごとの展開・デコード規則に完全に従って戻り値を生成** します：
    - **UNORM フォーマット**: $[0.0, 1.0]$ の範囲に正規化された fp32 を `rd..rd+3` に返却。
    - **SNORM フォーマット**: $[-1.0, 1.0]$ の範囲に正規化された fp32 を `rd..rd+3` に返却。
    - **浮動小数点フォーマット**: メモリに格納された IEEE-754 単精度 float 値をそのまま返却。
    - **UINT / SINT フォーマット**: 生の 32-bit 整数ビット列（`uint32_t` / `int32_t`）を返却。
    - **チャンネル欠損成分**: G/B = 0（0.0f/0）、A = 1（1.0f/1）に自動展開。
  - 「`texf` returns raw texel values」という表現の意図は、**サンプラによるバイリニア / トライリニア補間、LOD 計算、およびデプス比較（`Dref op D`）を一切通さず、指定された整数座標（$(x, y, level)$）の単一テクセルデータをそのまま取得する** という意味です。
  - この仕様を曖昧さなく明確にするため、§12.9（2192 行）の記述を訂正・明確化しました。
- **条文反映**:
  - `docs/ghci.md`: §12.9（2192 行）

---

## 2. 全疑問（N01〜N36）のステータス総括

本改訂（Version 8.0 / Commit `89529de`）をもって、提示されたすべての疑問事項（N01〜N36）の解決が 100% 完了しました：

| カテゴリ | 該当 ID | ステータス |
| --- | --- | --- |
| Critical (C) | なし | 全件解決済（0 件） |
| High (H) | なし | 全件解決済（0 件） |
| Medium (M) | なし | 全件解決済（0 件） |
| Low (L) | N12, N35, N36（今回解決） | 全件解決済（0 件） |
| 以前の解決 | N01〜N11, N13〜N34 | 全件解決済（33 件） |

- **CI / 検証ステータス**:
  - C ヘッダ構文検証: `gcc -fsyntax-only -Iinclude include/ghci_cmd.h` (PASS)
  - RTL 回帰シミュレーション: `./sim/run.sh atg_cp atg_ghci_slim` (PASS atg_cp, PASS atg_ghci_slim)

DONE
