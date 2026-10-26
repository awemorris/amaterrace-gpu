<!-- awesome-plan project=amaterrace-gpu record=ws001-p014 -->

# Phase 014: 8-bit unorm 高速ブレンド & div255 1段化（Lerp 変形・乗算器半減）

- **親**: [WS001](../ws.md)
- **状態**: `completed` (2026-10-26 R1敵対的レビューAPPROVE・全数網羅PASS)
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (ROP クリティカルパス遅延 75% 削減 & 乗算器 50% 削減)
- **出典**: ユーザー諮問（ROP ブレンド高速化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rop/atg_rop_div255.v` が抱える 5 段キャリーチェイン縦列（`am_add` 5 段カスケード、遅延約 2.5ns）を、数学的恒等式に基づく 1 段加算器（遅延約 0.6ns）へ刷新する。
同時に `rtl/gpu/rop/atg_rop_blend.v` の標準アルファブレンドを線形補間（Lerp: $D + (S - D) \cdot \alpha$）に変形し、16 チャンネルの 8-bit 乗算器を 32 個から 16 個へ半減させる。

## 範囲・作業内容

1. **`atg_rop_div255.v` の 1 段加算化**:
   - $0 \le x \le 65025$ における最近接丸め $\lfloor (x + 128) / 255 \rfloor$ の数学的恒等式：
     $$t = x + 128 \implies q = (t + (t \gg 8)) \gg 8$$
   - 従来の 5 段の `am_add` を撤廃し、わずか 1 個の 17-bit 加算器とビット配線のみで構成。

2. **`atg_rop_blend.v` の Lerp 最適化**:
   - `SRC_ALPHA`, `ONE_MINUS_SRC_ALPHA` 等の標準ブレンドモードに対し、2 乗算（$S \cdot \alpha + D \cdot (1 - \alpha)$）を 1 乗算（$D + (S - D) \cdot \alpha$）へ最適化。
   - 乗算器インスタンス数を 32 個から 16 個へ半減（Kintex-7 LUT6 実装、DSP 0 個）。

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_div255_tb.v` を新設し、0〜65025 の全入力値について旧実装および数学的厳密値と 100% 一致することを確認。
   - `sim/verilator/run.sh`（全 7 スイート）で画像出力の完全一致を確認。
   - `python3 tools/arith-lint.py` で演算子違反 0 件を確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- `atg_rop_div255` が加算器 1 段で構成され、全値域でビット完全一致すること。
- `atg_rop_blend` の乗算器数が半減し、既存シミュレーション画像と 1 bit の狂いもなく一致すること。

---

## 完了記録（2026-10-26）

1. **RTL 最適化実装**:
   - `rtl/gpu/rop/atg_rop_div255.v`: 5 段キャリーチェイン縦列を単一の 17 ビット加算器 `am_add #(.W(17))` 1 個のみに集約（遅延 75% 削減、~0.6ns）。
   - `rtl/gpu/rop/atg_rop_blend.v`: Lerp 変形（$D \pm \text{div255}(|S - D| \cdot \alpha)$）により、乗算器数を 32 個から 16 個へ半減（LUT6 合成、DSP 0 個）。パイプラインレジスタ Stage 2 を 512 bit から 256 bit へ半減。LAT=3 不変。
   - `spec/gpu/rop/atg_rop_div255.md`, `spec/gpu/rop/atg_rop_blend.md`: 仕様書更新。
   - `sim/tb/atg_rop_div255_tb.v`: $0 \le x \le 65025$ 全 65,026 値の全数網羅テストベンチ新設。
2. **検証結果**:
   - `sim/run.sh atg_rop_div255`: **PASS** (1 s、全 65,026 値 100% 一致)
   - `python3 tools/arith-lint.py`: **0 operators outside rtl/library/arith (PASS)**
   - `sim/verilator/run.sh`: 全 7 スイート（`basic`, `raster`, `shade`, `tex`, `msaa`, `compute`, `core`）すべて **PASS**（画像 1 bit の狂いもなく完全一致）。
3. **敵対的レビュー（R1 判定）**:
   - **APPROVE**（`adversarial_review_ws001_p014_rop_blend.md`）。恒等式に基づく 1 段加算器化、全数網羅テスト、Lerp による乗算器半減、LAT=3 遅延不変性、Guardrails 完全準拠を承認。
