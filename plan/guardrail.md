<!-- awesome-plan project=amaterrace-gpu record=guardrail -->

# Guardrail Board

Amaterrace GPU プロジェクトの設計・コーディング・検証における制約と規約の台帳。

## 正式規約と簡潔規約へのリンク

- 正式規約（Authoritative）: [docs/style.md](../docs/style.md)、[spec/README.md](../spec/README.md)
- 簡潔規約（Concise, モデル注入用）: [standards/concise/verilog-and-scripts.md](standards/concise/verilog-and-scripts.md)
- 自動化対応表: [standards/automation.md](standards/automation.md)

---

## 1. ソースコード・言語・ライセンス制約

- **言語**: Verilog-2005（Icarus Verilog `-g2005`、Verilator `--lint-only -Wall`、Vivado の共通サブセット）。`rtl/` や `boards/` で SystemVerilog を使用しない。
- **ファイルヘッダ**: 各ファイルの先頭に `timescale 1ns / 1ps` および `default_nettype none` を置き、末尾に `default_nettype wire` を置く。
- **モジュール構成**: 1 ファイル 1 モジュール。ファイル名＝モジュール名。原則として 400 行以内。
- **仕様書**: 各モジュールに対応する仕様書を `spec/` 以下の同名パス（例: `rtl/gpu/su/atg_su_fpu.v` に対し `spec/gpu/su/atg_su_fpu.md`）に保持する。
- **ライセンス**: Zlib ライセンスヘッダをすべてのソースに付与する。

---

## 2. 算術演算子制約（Arithmetic Discipline）

- **シグナル演算子の禁止**: `+`, `-`（単項含む）, `*`, `/`, `%`、およびシグナルによるシフト（`<<`, `>>`, `>>>`）は、`rtl/library/arith/`（旧 `rtl/common/`）内のモジュール（`am_add`, `am_sub`, `am_addsub`, `am_shift`, `am_mul`, `am_div`, `am_msb`）の中だけで記述する。
- **例外**: パラメータ・定数式、定数量のシフト、定数 2 のべき乗による演算、テストベンチ（`sim/`）。比較演算子（`<`, `==` 等）は対象外。
- **自動検証**: `tools/arith-lint.py` により `0 operators outside rtl/library/arith` を常時検証する。

---

## 3. FPGA ハードウェア構造・DSP48E1 必須設計規則（必読: [plan/fpga.md](fpga.md)）

> [!IMPORTANT]
> **すべてのコーディング担当サブエージェント（P1〜P8）は、RTL の作成・変更に着手する前に、必ず [plan/fpga.md](fpga.md) を通読し、その物理構造・アンチパターン・レジスタバインド・カスケード規則を完全に遵守することを義務づける。**

- **乗算演算子 `*` の完全禁止**:
  - ソースツリー内において、信号乗算演算子 `*` を使用してはならない（合成ツールによるファブリック加算器への意図しない逃げとタイミング破綻を防ぐため）。
  - すべての乗算は `am_mul.v` 経由で行い、`SYNTH_KINTEX7` においては `DSP48E1` プリミティブを真に直接インスタンス化する。
- **DSP 内部パイプラインレジスタの物理バインド**:
  - ファブリックで DSP 出力を受けて `always @(posedge clk) r <= p_comb;` と遅延させるアンチパターンを **完全禁止** する。
  - `LAT` パラメータ（0〜3）は、必ず DSP 内部レジスタ（`AREG/BREG`, `MREG`, `PREG`）に 1 対 1 で直結する（`LAT <= 3` でファブリックレジスタ 0 個）。
- **`PCOUT -> PCIN` カスケードの正確な OPMODE 制御**:
  - 符号なし 17 ビット単位でタイル分割し、部分積加算は隣接スライスの専用配線 `PCOUT -> PCIN` のみで完結させる。
  - ファブリック加算器（`+`）は 1 ビットたりとも使用してはならない。
  - 初段: `OPMODE = 7'b0000001` (Z=0, Y=0, X=M)
  - 17bit 上位シフト段: `OPMODE = 7'b1010001` (Z=PCIN>>17, Y=0, X=M)
  - 同重み加算段: `OPMODE = 7'b0010001` (Z=PCIN, Y=0, X=M)
- **等価性検証**: unisim（`DSP48E1.v` + `glbl.v`）を用いた単体等価試験で全 76 インスタンス対（幅 × SIGNED × LAT）のビット・サイクル完全一致を常時検証する。

---

## 4. ボード・クロック・ビルド制約（詳説: [plan/fpga.md](fpga.md) §5, §6）

- **ロジッククロック分周の完全禁止**:
  - ロジック（カウンタ、トグル FF 等）によるクロック分周信号を後続のクロックピン（`clk`）に接続することは完全禁止。
  - クロックは PLL/MMCM の出力から専用クロック配線（BUFG 等）を用いて分配し、低速化はクロックイネーブル `en` ストローブで行う。
- **IP クロック入力の PLL 直結ルール（BUFG 挿入禁止）**:
  - MIG や PCIe 等の物理層（PHY）を持つ IP のクロック入力は、ベンダーリファレンスに従い、SYSCLK / PLL から直接配線する。
  - PLL 出力と MIG 入力の間に勝手に `BUFG` を挿入してはならない（位相関係が狂い、キャリブレーションが 50/50 失敗する実例あり、[fpga.md](fpga.md) §5.4）。
- **P&R の確率論的性質と泥臭いロジック書き換えの覚悟**:
  - RTL の論理的正しさと FPGA のタイミング的正しさは完全に別物である。
  - P&R はヒューリスティックであり、Vivado のバージョンやシード値に強く依存する。タイミング収束（WNS >= 0）のためには、パイプライン分割やファンアウト制限などの ad-hoc なロジック修正が必然的に必要となる（[fpga.md](fpga.md) §6）。
- **ビルド再現性と警告開示**:
  - Vivado 2026.1（build 6511674）、Default ストラテジを使用。
  - Debug OFF での検証を原則とする。
  - 合成・配置配線で発生したすべての Warning はリスト化してユーザーに提示し、勝手に無害と判断しない。

---

## 5. Git コミット規約

- **コミットメッセージ**: `git commit` のコミットメッセージは常に **`-m WIP`** とする（2026-10-26 ユーザー指示:「gitのcommitは -m WIP とします。ルールとしてガードレールに記録してください。」）。
- **履歴と説明の所在**: 詳細な作業内容・変更理由・検証結果はコミットメッセージではなく、Awesome Plan の Phase 記録（`phase.md`、`work-spec.md`）側に詳細に記録する。

---

## 6. エージェント体制と運用規約

- **Q1（メインエージェント）**: 計画策定、サブエージェント管理（P1–P8, T1–T8）、および成果物マージの責任者。
- **P1〜P8（実装担当）**:
  - RTL コーディング担当は **Claude Opus 5.5 Medium** で起動する。
  - 同時実行数 $N$ の制御（$N=1$: P1、$N=2$: P1, P2、最大 P8）。
  - テストは Q1 に依頼し、**結果を待たずに依存関係が満たされている別作業に着手する**。
- **T1〜T8（テスト担当）**: Q1 からディスパッチされ、各種検証・シミュレーションを実行して Q1 に結果を返す。
- **サブエージェント別 Queue**: Queue はサブエージェントごとに持ち、独立して割り当て・追跡を行う。
