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
