# GHCI Review Reply - Version 20.0 (2026-10-28) - Commit: c3e79dd

zedBSD ドライバ担当殿の GHCI レビュー 第 20 版（ハードウェア境界観点 H1〜H12 に関する専門コードレビュー依頼 第 2 回）に対する、Amaterrace GPU 側の確定回答および審査結果です。

---

## ■ 1. 総合判定

**判定: CONDITIONAL APPROVE（条件付き承認）**

ハードウェアアーキテクチャおよび RTL 実装との整合性、ならびに弱順序プロセッサ（VisionFive 2 / riscv64）でのメモリ整合性モデルの観点から敵対的審査を実施いたしました。
基本設計および多くのプロトコル処理は極めて堅牢ですが、実機および弱順序 CPU でのデータ破損・デッドロックを防止するため、**2 件の重大指摘（C01, C02）の改修** を求めます。その他の観点については追認・全面合意いたします。

---

## ■ 2. 審査指摘事項（C01 〜 C06）

| ID | 観点 | 重さ | 対象ファイル・箇所 | 仕様節 (ghci.md) | 指摘内容およびハードウェア側の技術的根拠 |
| --- | --- | --- | --- | --- | --- |
| **C01** | H1 | **H** | `cp.c` (`take_fence`), `cmd.c` (`ghci_fence_read`) | §6, §9.1 | **【ロードメモリバリア（Load Barrier）の欠落】**<br>`riscv64`（VisionFive 2）や ARM64 などの弱順序 CPU アーキテクチャにおいて、CPU が `ghci_fence_read()` で 64-bit フェンスカウンタの完了を検出した後に、GPU 先行書き込みバッファ（レンダリング結果画像・クエリプール等）を読み取る際、CPU がフェンス成立前に投機ロードした古いキャッシュラインを読み込んでしまう競合（Stale Cache Read）が発生します。<br>`ghci_cp_doorbell()` では先行ストアバリア `kern_io_write_barrier()` が完璧に入っていますが、読み出し側でロードバリアが欠落しています。<br>**要求修正**: `ghci_fence_read()` の末尾、または `ghci_fence64_passed() == true` 直後に `kern_io_read_barrier()`（または `atomic_thread_fence(memory_order_acquire)`）を明示的に発行してください。 |
| **C02** | H3 | **H** | `recover.c` (`reset_and_check`) | §3.3, §10 | **【リセット復旧時における `STATUS.MEM_READY` ポーリング待機の欠落】**<br>`recover.c` 内の `reset_and_check()` において、`CTRL.RESET` 発行後に `CTRL.RESET` の自己クリア（0 復帰）のみを待機し、`STATUS.MEM_READY == 1` の確認を行わずにレジスタ再設定および `CTRL.RUN` 投入・Liveness プローブ送信を行っています。<br>初期化時（`pci-attach.c`）と同様に、ハードウェアの `CTRL.RESET` はコアパイプラインと AXI キューを初期化するため、DRAM PHY / MIG の調停・校正状態が安定するまで数ミリ秒を要します。`STATUS.MEM_READY == 1` を待たずに AXI アクセスを開始すると、未準備のメモリコントローラにより `AXI_ERROR` / `AXI_STUCK` が再発し、恒久的な `RECOVERY_LOST` に直行します。<br>**要求修正**: `recover.c` の `reset_and_check()` において、`CTRL.RESET == 0` の確認直後に `STATUS.MEM_READY == 1` をポーリング待機（上限 500 ms 等）する処理を追加してください。 |
| **C03** | H8 | **M** | `layout.h`, `vk-pass.c`, `vk-layout.c` | §12.11, N79 | **【MSAA 行ストライド 64B アライメント】**<br>最新コミットにおいて `ghci_layout_row` が `roundup(P_min, 64)` に更新されていることを確認いたしました。TU/ROP のメモリライン境界と完全に一致しており、**追認・解決済み** といたします。 |
| **C04** | H2, H5 | **L** | `display-scan.c`, `cp.c` | §3.4, §13.2 | **【DISP2 割り込みおよび W1C 順序】**<br>子割り込み `DISP_IRQ_STATUS` を先行クリアした後に親 `GHCI_REG_IRQ_STATUS[3]` をクリアする順序、および FLIP レコードの保留・回収シーケンスが完璧に実装されています。**承認（APPROVE）** いたします。 |
| **C05** | H9 | **L** | `compiler/gsi1-io.c`, `gsi1-abi.h` | §12.10.3, N78 | **【頂点属性レジスタ配置・クリップ座標】**<br>累積 $base_i$ による属性配置、および Position ベクトルの $w$ 成分（クリップ除数）の配置がハードウェア仕様と完全に一致しています。**承認（APPROVE）** いたします。 |
| **C06** | H11, H12 | **L** | `phase016/phase.md`, `phase017/phase.md` | §7.3, §11.1 | **【外部イベント待機時のカーネルキュー分割・p016/p017 計画】**<br>リングバッファ内にクライアント直接制御の `WAIT_FENCE` を置かず、カーネル側でサブミッションを分割してイベント成立まで保留するアプローチは、ハードウェアの Watchdog 誤発火やリング枯渇デッドロックを防止する極めて優れた設計です。ハードウェア設計側として **全面的に支持・追認** いたします。 |

---

## ■ 3. 仕様追記事項（N80）

指摘 C02 に伴い、正本 `docs/ghci.md` §3.3 および §10 に以下の規程を明記・改訂いたしました（Commit: `c3e79dd`）：

- **【N80】リセット復旧時における `STATUS.MEM_READY` 必須待機の明記**:
  - `CTRL.RESET` 発行後、ドライバは `CTRL.RESET` の自己クリア（0 復帰）を確認した後、必ず `STATUS.MEM_READY == 1`（DRAM PHY / MIG 校正完了およびメモリ調停安定化）をポーリング確認しなければならない。
  - `STATUS.MEM_READY == 1` を確認する前にレジスタ再設定や `CTRL.RUN` 投入・Liveness プローブ発行を行うことは禁止される。

---

## ■ 4. 今後の進め方

- 重大指摘 **C01**（`ghci_fence_read` へのロードバリア追加）および **C02**（`recover.c` での `STATUS.MEM_READY` 待機追加）の修正を取り込んでいただき、次版にてご提示いただければ直ちに最終 Signoff といたします。

DONE
