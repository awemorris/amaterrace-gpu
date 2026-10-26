<!-- awesome-plan project=amaterrace-gpu record=ws001-p031 -->

# Phase 031: BLT 1サイクル並列 MSAA 4x Resolve（クアッド並列平均化）

- **親**: [WS001](../ws.md)
- **状態**: `completed`
- **依存**: [ws001-p030](../phase030/phase.md)
- **優先度**: Major (MSAA Resolve スループットの大幅引き上げ)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/blt/atg_blt_rsv.v` において、MSAA 4x Resolve 処理がサンプル逐次読み出し・シリアル平均化によってボトルネックになっている問題を解消する。
$2 \times 2$ クアッド単位（16 テクセル）を並列にアンパックし、16 チャンネルの 4 サンプル平均化加算器により、毎サイクル 1 クアッド（4 ピクセル）の Resolve スループットを達成する。

## 範囲・作業内容

1. **クアッド並列 Resolve パイプラインの実装**:
   - 1 クアッド（4 ピクセル $\times$ 4 サンプル = 16 テクセル）のマルチサンプルデータをバーストバッファから 1 サイクルでアンパック。
   - 4 ピクセル分の 4 サンプル加算・除算（$(s_0 + s_1 + s_2 + s_3)/4$）を 1 サイクル並列加算器ツリーで実行。
2. **フォーマット出力統合**:
   - Phase 026 の 2 段化 `atg_fmt_pack` と直結し、Resolve 後のピクセルを即座に宛先ラインへ書き戻す。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/blt/atg_blt_rsv.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/blt/atg_blt_rsv.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_blt_rsv_tb.v`

### 2. モジュールインターフェース設計 (`atg_blt_rsv.v`)
- 入力: 16 テクセル分のサンプルデータ（4 ピクセル $\times$ 4 サンプル）。
- 出力: 4 ピクセル分の Resolve 済みピクセルデータ。
- ストリーミングパイプラインインターフェース（`in_valid`, `in_ready`, `out_valid`, `out_ready`）。

### 3. RTL アーキテクチャと加算ツリー
- UNORM8 の場合: 各ピクセルの R, G, B, A それぞれについて 8-bit サンプル 4 個を加算（`am_add` 3 個、または `am_add3`）。
- 和（10 ビット）を右シフト 2 ビットして丸め（`+ 2` して `>> 2`）。
- FP16 の場合: `am_fp_add` を用いたツリー加算。
- 毎サイクル 1 クアッド（4 ピクセル）の連続処理パイプライン。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: サンプル加算には必ず `am_add` / `am_addsub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストコマンド**:
  ```bash
  ./sim/run.sh atg_blt_rsv
  ./sim/verilator/run.sh
  python3 tools/arith-lint.py
  ```
- MSAA レンダリング後の画像（`msaa.png`）が正しく平均化され、ギザギザが滑らかになっていることを検証。

---

## 検証基準（受け入れ条件）

- 毎サイクル 1 クアッドのピーク Resolve 演算能力（持続 1 quad / 1.42 サイクル、64B ラインで 256 クアッドを 364 サイクルで完了）。
- `sim/run.sh atg_blt_rsv`: PASS（全 13 テストグループ完全一致）。
- `sim/run.sh atg_blt`: PASS（57 s）。
- `sim/run.sh atg_top`: PASS（22 s）。
- `python3 tools/arith-lint.py --top atg_blt_rsv`: 生演算子 0 件。
- `tools/lint.sh atg_blt_rsv atg_blt_rsv_px`: 警告 0 件。
- R1 敵対的コードレビュー APPROVE 承認完了（2026-10-26）。
- コミット: `abb858c` / `d0f55a3`
