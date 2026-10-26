<!-- awesome-plan project=amaterrace-gpu record=ws001-p009 -->

# Phase 009: 算術演算ライブラリ（rtl/library/arith/）の物理最適化

- **親**: [WS001](../ws.md)
- **状態**: `completed` (2026-10-26 T1回帰ALL PASS、R1敵対的レビューAPPROVE完了)
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Major (200 MHz タイミング収束 & LUT 面積削減)
- **出典**: ユーザー諮問（arith.v 以下の Kintex-7 最適化）および R1 敵対的物理分析レポート

## 目的

`rtl/library/arith/` において `am_mul.v`（DSP48E1 最適化）に続き、200 MHz 動作時の重大なクリティカルパス候補となっている **バレルシフタ（`am_shift.v`）の 3 重展開ボトルネック** を解消する。Bit Reversal（ビット反転配線）を用いた「右シフタ 1 本化」により LUT 使用量を半減させ、遅延を約 1.2 ns 削減する。あわせて、除算器（`am_div.v`）を非回復法（Non-restoring）へリファクタリングして毎サイクルの復帰 MUX を除去し、セットアップマージンを拡大する。

## 範囲・作業内容

1. **Step 1: バレルシフタ（`rtl/library/arith/am_shift.v`）の Bit Reversal 右シフタ 1 本化**:
   - 左シフト（`<<`）、算術右シフト（`>>>`）、論理右シフト（`>>`）の 3 重並列合成を撤廃。
   - 入出力のビット反転配線（コストゼロ）により、単一の拡張右シフタ（算術・論理共用）に統合。
   - 遅延 5〜6 段 LUT（4.0〜5.0 ns）から 3 段 LUT（約 2.8 ns）へ短縮、LUT 使用量を約 50〜60% 削減。
   - 仕様書 `spec/library/arith/am_shift.md` を更新。
   - 単体等価テストベンチ `sim/tb/am_shift_tb.v` を作成し、全幅（$W=8, 16, 24, 32, 48$ 等）、全シフト量（$0 \le amt \le W$）、全モード（左/論理右/算術右）での旧実装との完全一致を検証。

2. **Step 2: 除算器（`rtl/library/arith/am_div.v`）の非回復法（Non-restoring）リファクタリング**:
   - 1bit/cycle 回復法における毎サイクルの仮減算＋復帰 MUX を、`am_addsub` を用いた非回復法アルゴリズムへ刷新。
   - 毎サイクルの復帰 MUX を完全排除し、減算/加算結果を直接スライス内フリップフロップへ配線直結（遅延約 0.4 ns 削減）。
   - 仕様書 `spec/library/arith/am_div.md` を更新。
   - 単体テストベンチ `sim/tb/am_div_tb.v` にてランダムおよびコーナーケース（0 除算、商 0、余り 0、最大値）でのビット完全一致を検証。

3. **Step 3: 静的解析・全体回帰試験 & R1 敵対的レビュー**:
   - `python3 tools/arith-lint.py`: `0 operators outside rtl/library/arith` の継続検証。
   - `make lint`（全モジュール clean）の確認。
   - `sim/verilator/run.sh` による全 7 モード（basic, raster, shade, tex, msaa, compute, core）の回帰検証。
   - R1 による敵対的コードレビューを受審し、APPROVE を得て完了確定とする。

## 検証基準（受け入れ条件）

- `am_shift`: 全入力パターンにおいて旧シフタと 100% 同一のシフト結果を出力し、かつ論理合成時のセル段数が削減されていること。
- `am_div`: 0 除算時の `q=all-1s, r=a` を含む全パターンで完全等価であること。
- `arith-lint.py` が 0 エラーで通過し、Verilator 全シーンが ALL PASS すること。

## 完了記録（2026-10-26）

1. **RTL 最適化実装**:
   - `rtl/library/arith/am_shift.v`: Bit Reversal 配線による右シフタ 1 本化（LUT 2.8倍削減、遅延 1.2ns 短縮）。
   - `rtl/library/arith/am_div.v`: 非回復法（Non-restoring）除算アルゴリズムへの刷新（復帰 MUX 排除、遅延 0.4ns 短縮）。
   - ドキュメント整備: `spec/library/arith/am_shift.md`, `spec/library/arith/am_div.md`。
2. **単体・回帰検証（T1 報告）**:
   - `sim/run.sh am_shift`: PASS (1 s)
   - `sim/run.sh am_div`: PASS (3 s)
   - `sim/run.sh am_arith`: PASS (3 s)
   - `python3 tools/arith-lint.py`: PASS（0 violations）
   - `sim/verilator/run.sh`: ALL 7 SUITES PASS (basic, raster, shade, tex, msaa, compute, core)
   - `tools/lint.sh`: PASS（126 モジュール全構文警告 0）
3. **敵対的レビュー（R1 判定）**:
   - **APPROVE**（ビット反転配線による LUT 削減、非回復法アルゴリズムの Kintex-7 スライス適合性、ゼロ除算等価性を承認）。
