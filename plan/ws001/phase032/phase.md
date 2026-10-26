<!-- awesome-plan project=amaterrace-gpu record=ws001-p032 -->

# Phase 032: VF 4ストリーム並列属性 DMA & ラインバッファ拡張

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p027](../phase027/phase.md)
- **優先度**: Major (頂点属性フェッチストールの解消)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/vf/atg_vf_fetch.v` において、頂点属性を 1 頂点ずつ、有効属性を 1 個ずつ、たった 2 エントリのラインバッファで逐次フェッチしているため、頂点ワープの生成が大幅に遅延している問題を解消する。
最大 4 系統の頂点バッファストリームを並列にフェッチ可能な DMA エンジンおよび 1 KiB 属性バッファを導入し、頂点供給レートを 4 倍に引き上げる。

## 範囲・作業内容

1. **マルチストリーム並列属性フェッチの実装**:
   - `atg_vf_fetch.v` を改修し、位置（Position）、法線（Normal）、カラー（Color）、UV 等の独立したバインディングストリームを並列にリクエスト発行。
   - 各ストリーム専用の 256 バイトプリフェッチ FIFO を配置。
2. **頂点フォーマット変換（`atg_vf_conv.v`）のパイプライン化**:
   - 8-bit/16-bit 整数、半精度、単精度浮動小数点から 32-bit 内部フォーマットへの変換段を固定 1 サイクルパイプライン化。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/vf/atg_vf_fetch.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/vf/atg_vf_conv.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/vf/atg_vf_fetch.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_vf_tb.v`

### 2. モジュールインターフェース設計 (`atg_vf_fetch.v`)
- 最大 4 系統のバッファバインディング（`vbuf_base[0..3]`, `vbuf_stride[0..3]`）に対応。
- 4 系統の AMB リクエストを並行して発行可能なマルチチャンネル DMA。

### 3. RTL アーキテクチャと属性アセンブリ
- 各属性ストリーム専用の 256 バイト FIFO（Phase 035 の Skid Buffer または `am_fifo`）を配置。
- 頂点インデックス $i$ に応じて 4 本のストリームから各属性フィールドを切り出し、1 つの頂点属性ベクタへ合成（Gather）。
- 頂点ワープ（32 頂点）を最短レイテンシでアセンブルし、SU へディスパッチ。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 頂点アドレス計算（`base + index * stride`）には必ず `am_add`, `am_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストコマンド**:
  ```bash
  ./sim/run.sh atg_vf
  ./sim/verilator/run.sh
  python3 tools/arith-lint.py
  ```
- 複数頂点バッファバインディングを持つシーンで、頂点データが欠落なく SU へ供給されることを確認。

---

## 検証基準（受け入れ条件）

- 4 系統の属性ストリームが並列フェッチできること。
- `sim/run.sh atg_vf` が PASS すること。
- R1 レビュー APPROVE 獲得。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 頂点属性フェッチのレイテンシが大幅に短縮され、SU への頂点ワープ供給が途切れないこと。
- 頂点座標および属性値がビット完全一致すること。
