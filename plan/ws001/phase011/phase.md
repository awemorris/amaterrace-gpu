<!-- awesome-plan project=amaterrace-gpu record=ws001-p011 -->

# Phase 011: オペランドフォワーディング（Bypass ネットワーク）の実装

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p010](../phase010/phase.md)
- **優先度**: Major (IPC 3〜5 倍向上 & RAW ストール根絶)
- **出典**: ユーザー諮問（SU 高速化）および R1 敵対的アーキテクチャ分析レポート

## 目的

現行 SU において「バイパス（Operand Forwarding）なし」のために先行命令の結果がレジスタファイルに書き戻されるまで同一レジスタ読み出しが必ず 6 サイクル待たされ、低ワープ時に実効 IPC が 0.16 に大暴落している問題を根絶する。
Stage 4 (EX4) および Stage 5 (WB) から Stage 0 (OPD) へのオペランドフォワーディングネットワークを導入し、RAW 依存レイテンシを 6 サイクルから実質 1〜2 サイクル（または 0 バブル）に短縮する。

## 範囲・作業内容

1. **オペランドコレクタ（`rtl/gpu/su/atg_su_opd.v`）のバイパス MUX 拡張**:
   - `rs1`, `rs2`, `rs3` の各オペランドフェッチに対し、EX4 バスおよび WB バスからのフォワーディング比較・マルチプレクサを追加。
   - 同一ワープかつレジスタ番号一致時の優先バイパス選択。

2. **スコアボード（`rtl/gpu/su/atg_su_sb.v`）の短レイテンシ依存カウント短縮**:
   - 短レイテンシ演算完了待ちカウントダウンを、従来の `SHORT_LAT + 1`（7 サイクル）から `BYPASS_LAT`（1〜2 サイクル）へ短縮。
   - バック・トゥ・バックの依存命令（例: `add r1, r2, r3` の直後の `sub r4, r1, r5`）がストールなしでイシュー可能になるよう調停ロジックを改定。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_opd.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_sb.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_pipe.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/su/atg_su_opd.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_su_forwarding_tb.v`

### 2. モジュールインターフェース設計 (`atg_su_opd.v` 追加ポート)
- `fwd_ex4_valid`, `fwd_ex4_warp[3:0]`, `fwd_ex4_rd[5:0]`, `fwd_ex4_data[31:0]`
- `fwd_wb_valid`, `fwd_wb_warp[3:0]`, `fwd_wb_rd[5:0]`, `fwd_wb_data[31:0]`

### 3. RTL アーキテクチャとフォワーディング判定
- 各オペランド（`rs1`, `rs2`, `rs3`）について：
  ```verilog
  wire hit_ex4 = fwd_ex4_valid && (fwd_ex4_warp == cur_warp) && (fwd_ex4_rd == rs_idx) && (rs_idx != 6'd0);
  wire hit_wb  = fwd_wb_valid  && (fwd_wb_warp  == cur_warp) && (fwd_wb_rd  == rs_idx) && (rs_idx != 6'd0);

  assign rs_val = hit_ex4 ? fwd_ex4_data :
                  hit_wb  ? fwd_wb_data  : rf_rdata;
  ```
- スコアボード側のハザード判定ビットを即座に解放し、後続命令が次サイクルにイシューできるようにする。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: カウンタ、レジスタ番号比較等に算術演算子を使用しないこと。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_su_forwarding_tb.v`
- **検証項目**:
  1. `add r1, r2, r3` の直後に `add r4, r1, r5` を実行し、RAW ハザードで 6 サイクルストールすることなく、フォワーディングデータを用いて 1 サイクルで後続命令が正しく演算を完了すること。
  2. 1 ワープのみの実行において IPC が 0.16 から 1.0 近くまで劇的に向上すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_su_forwarding
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- RAW 依存命令がフォワーディングにより最小レイテンシで実行できること。
- 単一ワープ実行時の実効 IPC が大幅に向上すること。
- `sim/run.sh atg_su_forwarding` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - 連続 RAW 依存命令（チェイン演算）を含む専用マイクロベンチマークによる IPC 向上検証（サイクル数大幅短縮の確認）。
   - `sim/run.sh atg_su` および `sim/verilator/run.sh`（全 7 モード）での全パス確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- RAW 依存を持つシェーダープログラムの実行サイクル数が最大 50〜70% 削減されること。
- 単一ワープ実行時の実効 IPC が大幅に向上すること。
