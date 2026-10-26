# Agent Guidelines for Amaterrace GPU

Read and follow [.agents/skills/awesome-plan/SKILL.md](.agents/skills/awesome-plan/SKILL.md) as the Awesome Plan agent skill for project planning, execution boundaries, Guardrails, bug handling, and Queue operation.
Read [plan/config.md](plan/config.md) to locate this project's current Awesome Plan records.

## Key Operational Guidelines

- **Consult Before Acting**: Do not start implementation, FPGA builds, or hardware operations without presenting the proposal and obtaining explicit user approval.
- **Storage Mode**: Local-only mode. All planning, queuing, and tracking records live strictly under `plan/`. Do not interact with or publish to GitHub Issues.
- **Coding & RTL Standards**: Follow [docs/style.md](docs/style.md) and [plan/guardrail.md](plan/guardrail.md). Verilog-2005 only. Signal arithmetic operators (`+`, `-`, `*`, etc.) must remain strictly within `rtl/library/arith/` (verified via `tools/arith-lint.py`).
- **Git Commit Rule**: Always commit with `-m WIP`. Detailed context and records belong in `plan/`.

## 実行体制とエージェント運用規則

- **メインエージェント（Q1）**:
  - 計画立案、Queue 管理、サブエージェント（P1–P8, T1–T8）の起動・指示・ディスパッチ、成果物のマージを担当する。
  - 共有計画・記録（`plan/`）の唯一の責任更新者。
- **実装サブエージェント（P1〜P8）**:
  - RTL コーディングを行うサブエージェントは **Claude Opus 5.5 Medium** モデルで起動する。
  - 同時並行度 $N$: $N=1$ なら P1 のみ、$N=2$ なら P1, P2 を使用（最大 P8 まで）。
  - **非同期テストフロー**: 実装完了後、P1–P8 は Q1 にテスト実行を依頼する。**P1–P8 はテスト結果を待たずに、依存関係の満たされている別な作業に進む**。
- **テスト担当サブエージェント（T1〜T8）**:
  - P1–P8 からの依頼を受けた Q1 が、T1–T8 にテストをディスパッチする。
  - テスト結果は Q1 に報告され、Q1 経由で P1–P8 に伝達・記録される。
- **レビュー担当サブエージェント（R1）**:
  - P1–P8 が実装を完了した際、Q1 は R1 にコード差分および仕様整合性の敵対的レビューをディスパッチする。
  - **レビュー観点**:
    1. [plan/fpga.md](plan/fpga.md) の完全遵守（乗算演算子 `*` 禁止、DSP48E1 直接インスタンス化、`LAT <= 3` での内部レジスタ完全割当、ファブリック加算器/FF 排除、クロック分周禁止、IP PLL 直結等）。
    2. コーディング規約・Guardrails（Verilog-2005、演算子は `rtl/library/arith/` 限定）。
    3. 仕様適合性（`docs/`、`plan/` の Phase 要件、ヘッダ定義との整合性）。
  - **差し戻しループ**:
    - R1 が指摘事項（REJECT）を出した場合、Q1 はその指摘を対象サブエージェント（P1〜P8）に伝達して作業を差し戻し（修正ループ）、修正完了後に R1 が再レビューを行う。
    - R1 が APPROVE した場合に限り、完了確定として扱う。
- **サブエージェント別 Queue**:
  - Queue はサブエージェントごとに独立して管理する（`plan/queue.md` 内に P1〜P8 ごとのレーンを保持）。
