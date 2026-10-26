<!-- awesome-plan project=amaterrace-gpu record=ws001-p013 -->

# Phase 013: レジスタファイル最適化（BRAM 半減・マルチ SU 面積削減）

- **親**: [WS001](../ws.md)
- **状態**: `in-progress`
- **依存**: [ws001-p010](../phase010/phase.md)
- **優先度**: Major (マルチ SU 化に向けた BRAM シリコン面積半減)
- **出典**: ユーザー諮問（SU 根本問題）および R1 敵対的アーキテクチャ分析レポート

## 目的

1 サイクルで 3 オペランド（`rs1`, `rs2`, `rs3`）を同時読み出しするためにレジスタファイル（`rtl/gpu/su/atg_su_rf.v`）全体を 3 重に保持し、1 SU あたり 24 個もの BRAM36 を浪費している構造を解体する。
オペランドコレクタの時間差読み出し機構により、RF を True Dual-Port BRAM 1 面（または 2 面）へ集約し、BRAM 使用量を 50% 以上削減してマルチ SU 展開を容易にする。

## 範囲・作業内容

1. **オペランドコレクタ（`atg_su_opd.v`）の時間差フェッチ**:
   - 3 オペランドを 1 クロックで一括読み出しするのではなく、イシュー前の空きスロットまたは 2 サイクルに分散してフェッチする Collector アーキテクチャへ改修。

2. **レジスタファイル（`atg_su_rf.v`）の 3 重レプリケーション廃止**:
   - 3 コピーの BRAM を、True Dual-Port BRAM（ポート A: 読み出し 1、ポート B: 読み出し 2 / 書き込み）または 2 面構成へ再設計。
   - 1 SU あたりの BRAM36 消費を 24 個から 8〜12 個へ半減。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - BRAM 同期リード推論の徹底。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_rf.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_opd.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/su/atg_su_rf.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_su_rf_opt_tb.v`

### 2. モジュールインターフェース設計 (`atg_su_rf.v`)
- 3 つの個別リードポートから、時間多重化されたデュアルポートインターフェースへ移行。
- 書き込みポートは 1 本（WB ステージから）。

### 3. RTL アーキテクチャと BRAM 構成
- True Dual-Port BRAM（RAMB36E1）を推論。
  - Port A: `rd_addr_a`, `rd_data_a`
  - Port B: `wr_en`, `wr_addr`, `wr_data` / `rd_addr_b`, `rd_data_b`
- 3 オペランド命令（FMA 等）の場合、オペランドコレクタが先行サイクルで 1 つのオペランドをプリフェッチするか、BRAM 2 面構成（合計 8 個の BRAM）で 2 リード＋1 ライトを毎サイクル実現。

### 4. 厳格な Guardrails 注意事項
- **BRAM 同期リード必須**: 非同期リードを記述して LUTRAM に逃げられないよう、クロック同期リードを厳守すること。
- **算術演算子禁止**: `tools/arith-lint.py` 遵守。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_su_rf_opt_tb.v`
- **検証項目**:
  1. 連続する FMA 命令、ALU 命令において、レジスタの読み書き競合が発生せず、正しい値が演算器へ渡ること。
  2. Vivado 合成において、SU 単体の BRAM36 使用量が 12 個以下に半減していることを確認。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_su_rf_opt
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- レジスタファイルの BRAM 消費量が 50% 削減されること。
- 全命令が正確にレジスタ値を読み書きできること。
- `sim/run.sh atg_su_rf_opt` が PASS すること。
- R1 レビュー APPROVE 獲得。
   - `sim/run.sh atg_su_rf`, `atg_su_opd`。
   - `sim/verilator/run.sh`（全 7 モード）での全パス確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- BRAM36 消費数が半減し、かつ命令スループットを阻害しないこと。
- 全既存テストベンチが完全 PASS すること。
