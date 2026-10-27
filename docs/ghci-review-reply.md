# GHCI Review Reply - Version 9.0 (2026-10-28) - Commit: 89529de (Final Signoff: N01〜N36 Fully Resolved)

zedBSD ドライバ開発チーム（`amaterrace.ko`）による GHCI レビュー第 9 版（`ghci-review.md` 2026-10-28 02:50）を受理しました。

レビュー第 9 版において、すべての疑問点（N01〜N36）の解決が確認され、残存疑問 0 件（Critical: 0, High: 0, Medium: 0, Low: 0）および新矛盾 0 件であることが確定しました。これをもって GHCI 1.0 アーキテクチャ仕様書（`docs/ghci.md`）および C ヘッダ（`include/ghci_cmd.h`）のドライバ開発チームとの合意形成が 100% 完了（Final Signoff）したことを記録します。

なお、全版を通じて禁止略語は一切使用されておりません。

---

## 1. 最終合意概要

- **対象仕様書**: `docs/ghci.md` (Commit `89529de`, 2677 行)
- **対象ヘッダ**: `include/ghci_cmd.h` (Commit `35b89af`, 754 行)
- **解決総数**: N01〜N36 全 36 件完全解決（未解決 0 件）
- **ドライバ・コンパイラ影響**: 文書疑問によるドライバ実装およびシェーダコンパイラ開発の待ちは一切解消。

---

## 2. 解決項目一覧（N01〜N36）

| ID | 種別 | 概要 | 確定仕様・条文反映 |
| --- | --- | --- | --- |
| N01 | 完了 | 64-bit GPU VA 空間・Canonical 符号拡張 | §11.1 (PA_BITS 40..48, Canonical 符号拡張) |
| N02 | 完了 | 128B Push Constant 上書き時の TU 動作 | TU は SET_TABLE_ADDR[0..1] レジスタ参照、c[24..31] 上書き耐性 |
| N03 | 完了 | `CMD_BEGIN_RENDER_PASS` の 192B 構造体 VA 渡し | `GhciRenderPassDesc` GPU VA 渡し (opcode 0x2B, 10 dwords) |
| N04 | 完了 | `CMD_WRITE_TIMESTAMP` の session GPU VA 書込 | flags[0]=0: Session GPU VA, flags[0]=1: Host PCIe DMA |
| N05 | 完了 | `FAULT_INFO` (0x018) レジスタの W1C | 最初のフォールトをラッチ、W1C で再アーム |
| N06 | 完了 | 4 KiB 境界跨ぎパケット分割 | 境界跨ぎ禁止、CP による Kind 3 フォールト |
| N07 | 完了 | Session 0 の root L1 ページテーブル自動確保 | RUN=1 遷移時に CP_HEAP_BASE に自動確保・永続アクティブ |
| N08 | 完了 | Session フォールト時の Driver 通知・フェンス完了 | ホストドライバが期待シーケンス値を代行書込して待機スレッド解除 |
| N09 | 完了 | Primary Ring Buffer の 4 KiB 境界配置 | 4 KiB 境界配置、WRAP パケットによるラップアラウンド |
| N10 | 完了 | Secondary Buffer の呼出深さ制限 | 最大ネスト 1 段、二重呼出は Kind 3 フォールト |
| N11 | 完了 | `CMD_FENCE` の 64-bit シーケンス値・フラグ | opcode 0x33, 6 dwords, flags[0]=IRQ, [1]=MEM_WRITE, [2]=HOST_FLUSH |
| N12 | 完了 | 物理アドレスの二値判定・HOST_LIMIT 制約・Kind 5 | [LOCAL_BASE, LOCAL_BASE+LOCAL_SIZE) はローカル、外はホスト、Kind 5 AXI_ERROR |
| N13 | 完了 | `CMD_COPY_BUFFER` (0x40, 8 dwords) | 64-bit src/dst VA, 32-bit size, flags[0]=FLUSH |
| N14 | 完了 | Dynamic State 初期値・PSO 優先度・セッション分離 | 電源投入/RESET/SESSION_OPEN(0x12) で初期化、セッション完全分離 |
| N15 | 完了 | `CMD_BARRIER` (0x31) キャッシュ制御 | flags で I-Cache / T-Cache / D-Cache / L2 選択的無効化 |
| N16 | 完了 | `MEM_CACHE_CFG` (0x14) L2 KiB 表現 | [15:0] 16-bit 整数で直接 KiB 表記 (256 KiB) |
| N17 | 完了 | `CMD_BEGIN_QUERY` / `CMD_END_QUERY` | opcode 0x36/0x37, 4 dwords, Occlusion/Pipeline Statistics |
| N18 | 完了 | `CMD_SET_VIEWPORT` / `CMD_SET_SCISSOR` | 単一ビューポート・単一シザー (Viewport: 7 dw, Scissor: 5 dw) |
| N19 | 完了 | Index Buffer 形式 (16-bit / 32-bit) | `CMD_BIND_INDEX_BUFFER` (0x22, 4 dwords, index_type 0=U16, 1=U32) |
| N20 | 完了 | `FAULT_INFO` フォールトコード体系 | Kind 0..10, Unit 0..4 の確定 |
| N21 | 完了 | `DISP_IRQ_STATUS` (0x028) レジスタ名統一 | 表示割込ステータス名の統一 |
| N22 | 完了 | `CMD_EXECUTE_COMMANDS` (0x30, 4 dwords) | セカンダリコマンドバッファ実行 (64-bit buffer VA, 32-bit dwords) |
| N23 | 完了 | Custom Border Color Table | `CMD_SET_DYNAMIC_STATE` (0x10) による 16 エントリ VA 指定 |
| N24 | 完了 | Multisampling サンプル数 | 1, 2, 4 samples/pixel (`sample_count`) |
| N25 | 完了 | `CMD_FLIP` (0x51) の IMMEDIATE フラグ | flags[0]: 0=VBLANK同期, 1=即時フリップ |
| N26 | 完了 | Ring Doorbell Register (0x008) | 32-bit 書き込みで CP へ新規パケット通知 |
| N27 | 完了 | Secondary Buffer 実行権限保護 | 管理系・特権命令実行時は Kind 6 PROT_FAULT |
| N28 | 完了 | `CMD_WAIT_FENCE` 符号付き 64-bit 比較 | (int64_t)(current - wait) >= 0 による単調増加比較 |
| N29 | 完了 | AXI DECERR / SLVERR 応答時の回復手順 | CTRL.RESET によるソフトリセットおよび Session 復旧 |
| N30 | 完了 | Compute Workgroup サイズ上限 | 1024 スレッド/Workgroup (`maxComputeWorkGroupInvocations`) |
| N31 | 完了 | LDS (Local Data Share) 容量 | 最大 64 KiB / SU |
| N32 | 完了 | `CMD_BARRIER` パイプラインステージフラグ | TopOfPipe, Vertex, Fragment, Compute, BottomOfPipe |
| N33 | 完了 | Centroid フラグのビット定義 | `PSO.compute_lds_and_flags[16]` (PSO dw15 [16]) への統一 |
| N34 | 完了 | テクスチャ形式別 `texl`/`texf` 戻り値仕様 | UNORM [0,1], SNORM [-1,1], float はそのまま, 整数は生ビット列 |
| N35 | 完了 | `CMD_SESSION_OPEN` opcode 表記 | 0x12 に完全統一 |
| N36 | 完了 | `texf` の形式デコードとサンプラバイパス | 形式別デコード適用、サンプラフィルタ・デプス比較のみバイパス |

---

## 3. 検証ステータス

- C ヘッダ構文検証: `gcc -fsyntax-only -Iinclude include/ghci_cmd.h` $\rightarrow$ **PASS**
- 回帰シミュレーション: `./sim/run.sh atg_cp atg_ghci_slim` $\rightarrow$ **PASS** (100%)
- 禁止略語監査: リポジトリ全域 $\rightarrow$ **0 件**

DONE
