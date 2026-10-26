<!-- awesome-plan project=amaterrace-gpu record=ws001-p010 -->

# Phase 010: SU パイプライン真の 6 段化（Real Pipelining）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p008](../phase008/phase.md), [ws001-p009](../phase009/phase.md)
- **優先度**: Critical (200 MHz タイミング完全収束 & 1 GHz+ ASIC 化)
- **出典**: ユーザー諮問（SU 設計問題とパイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`SHORT_LAT = 6`（6 サイクル固定遅延）でありながら演算器が `LAT = 0`（完全組み合わせ回路）でステージ 0 に全演算が偏在し、残り 5 段が単なる FF シフトレジスタ（遅延線）となっている「見せかけのパイプライン（Fake Pipeline）」を解体する。
全 6 ステージに演算負荷を均等分散する本物の 6 段物理パイプラインへ再設計し、ステージ 0 の極大クリティカルパスを解消して 200 MHz で WNS > 2.0 ns の安全マージンを確立する。

## 範囲・作業内容

1. **`am_fpu_core.v` のパイプライン段数 `LAT = 4` 有効化**:
   - Stage 1: オペランドアライメント・符号処理
   - Stage 2: 33×33 乗算器初段（DSP48E1 `AREG/BREG = 1`）
   - Stage 3: 乗算カスケード（DSP48E1 `MREG = 1`）
   - Stage 4: ポスト加算（DSP48E1 `PREG = 1`）および桁落ち正規化・丸め（`am_fp_rnd`）
   - 各段にパイプラインイネーブル `en` を配線。

2. **整数 ALU（`rtl/gpu/su/atg_su_alu.v`）の 4 段パイプライン分割**:
   - 加減算、バレルシフト、論理演算、比較演算を 4 段に均等配分。
   - `LAT = 4` で FPU パイプラインとサイクル同期。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` DSP48E1 カスケード必須）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_pipe.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_lane.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_alu.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_fpu.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/su/atg_su_pipe.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_su_pipe_real_tb.v`

### 2. モジュールインターフェース設計 (`atg_su_pipe.v`)
- ワープディスパッチインターフェースおよびレジスタライトバックインターフェースの信号名・機能は完全互換。
- 内部の各実行ステージにクロックイネーブル `en` を接続し、パイプラインホールドに対応。

### 3. RTL アーキテクチャとパイプライン均等分割
- **EX1 (Alignment & Shifter)**:
  指数差分計算、仮数部シフト（`am_shift`）、整数論理演算。
- **EX2 (Multiply / Add Stage 1)**:
  FMA 用 33x33 乗算器初段（DSP48E1 AREG/BREG）。
- **EX3 (Cascade / Add Stage 2)**:
  カスケード部分積加算（DSP48E1 MREG）。
- **EX4 (Normalization & Rounding)**:
  LOD（Leading Zero Count）、仮数部丸め（`am_fp_rnd`）、フラグ確定。
- **EX5 (Writeback Prep)**:
  ライトバックデータ整列・フォワーディングバスドライブ。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: FMA 乗算および整数乗算には必ず `am_mul` を使用し、DSP48E1 の `AREG/BREG/MREG/PREG` をすべて有効（`LAT=3`）とすること。
- **算術演算子禁止**: すべての加減算には `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストコマンド**:
  ```bash
  ./sim/run.sh atg_su_pipe_real
  ./sim/verilator/run.sh
  python3 tools/arith-lint.py
  ```
- 既存のすべてのシェーダプログラム（Vertex / Fragment / Compute）の実行結果がビット完全一致すること。

---

## 検証基準（受け入れ条件）

- 演算論理が 6 ステージに均等に分散され、Fake Pipeline が解消されること。
- Vivado 合成で SU のクリティカルパスが大幅に短縮され、200 MHz で WNS > 2.0 ns となること。
- R1 レビュー APPROVE 獲得。
   - Stage 1: 比較判定・基本ビット論理演算
   - Stage 2: 33 ビット加減算（`am_addsub`）
   - Stage 3: バレルシフタ（`am_shift` Bit Reversal 型）
   - Stage 4: 演算結果選択マルチプレクサ

3. **SU トップ（`atg_su_fpu.v`, `atg_su_alu.v`）の末尾遅延レジスタの撤廃**:
   - 従来の `pipe[0]` への一括ラッチおよび `pipe[1..5]` のシフトレジスタを全廃。
   - 演算器自体のパイプライン出力が直接 Stage 4/5 のライトバック（WB）へ接続される構造へ刷新。

4. **単体および全体回帰検証**:
   - `sim/run.sh am_fpu_core`（6,000 ベクトル等価検証）。
   - `sim/run.sh atg_su_alu`, `atg_su_fpu`, `atg_su:+quick`。
   - `sim/verilator/run.sh`（全 7 モード）によるビット完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 演算結果が旧実装と 100% ビット完全一致すること。
- Vivado 合成時における SU 演算部の最長ロジック段数が劇的に短縮され、200 MHz において WNS が大幅に改善すること。
