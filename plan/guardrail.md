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

## 3. 乗算器・DSP48E1 カスケード制約

- **`SYNTH_KINTEX7` 時**: `am_mul.v` 内では `*` を使用せず、`DSP48E1` プリミティブを直接インスタンス化し、部分積は `PCOUT -> PCIN` カスケード（17-bit 右シフトおよび同重み加算）で加算する。fabric の加算器は一切使わない。
- **汎用・シミュレーション時**: `ifndef SYNTH_KINTEX7` では `*` を用いた汎用 Verilog 記述とし、`LAT` 段のパイプラインレジスタによりサイクル・イネーブル挙動を DSP 版と完全一致させる。
- **等価性検証**: unisim（`DSP48E1.v` + `glbl.v`）を用いた単体等価試験で全 76 インスタンス対（幅 × SIGNED × LAT）のビット・サイクル完全一致を検証する。

---

## 4. ボード・クロック・ビルド制約

- **クロック分周の禁止**: ロジック（カウンタ、トグル FF 等）によるクロック分周を一切行わない。クロックは PLL/MMCM の出力から専用クロック配線（BUFG 等）を用いて分配する。
- **IP クロック入力**: MIG 等の IP のクロック入力は、ベンダーリファレンスに従い、SYSCLK ピンから直接入力バッファ経由で PLL へ入力する。
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
