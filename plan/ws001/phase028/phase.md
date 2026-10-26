<!-- awesome-plan project=amaterrace-gpu record=ws001-p028 -->

# Phase 028: MC フラットクロスバー & QoS アービタ（調停遅延 8clk -> 2clk、DC 優先帯域保証）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p027](../phase027/phase.md)
- **優先度**: Major (メモリアービタ往復遅延 75% 削減 & 画面表示アンダーフロー完全防止)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/mc/atg_mc_tree.v` および `atg_rt.v` のバイナリツリー調停により、往復で 8 サイクルの固定遅延が付加されている問題を解消する。
2 段の QoS 優先度付きフラットクロスバーを導入して調停遅延を 2 サイクルに短縮し、Display Controller（DC）への最優先帯域保証と 3D クライアント間の公平な帯域配分を両立させる。

## 範囲・作業内容

1. **フラットクロスバー & QoS アービタの実装**:
   - `atg_mc_tree.v` の多段バイナリツリーを解体し、マトリクス型フラットクロスバーへ再設計。
   - DC（Display Controller）リクエストに対し最優先スロット（Strict Priority）を割り当て、画面表示のアンダーフローをハードウェア的に完全防止。
   - 3D/コンピュートクライアント（SU, TU, ROP, VF, BLT）間には重み付けラウンドロビン（Deficit Weighted Round Robin）を適用。
2. **相互接続遅延の短縮**:
   - リクエスト発行から L2 キャッシュ（または MIG）到着までのレイテンシを 4 サイクルから 1 サイクルへ、レスポンス返却を 4 サイクルから 1 サイクルへ短縮（計 8 サイクル $\to$ 2 サイクル）。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/mc/atg_mc_tree.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/mc/atg_mc.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/mc/atg_mc_tree.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_mc_arb_tb.v`

### 2. モジュールインターフェース設計 (`atg_mc_tree.v`)
- 全クライアント（NCLIENT 本）の要求・応答インターフェースは完全互換。
- 内部のツリールータ（`atg_rt.v`）の多段チェーンを廃止し、1 ステップの並列アービタ＋マルチプレクサへ刷新。

### 3. RTL アーキテクチャと QoS 調停
- **Priority Level 1 (Strict Priority)**: DC クライアント。DC から要求があれば、他のクライアントに優先して即座にグラントを付与。
- **Priority Level 0 (DWRR)**: SU, TU, ROP, BLT, VF。トークンカウンタ（クレジット）を用いた重み付け調停で、特定クライアントの帯域飢餓を防止。
- レジスタスライス（Phase 035 の `am_skid`）を入力ポートおよび出力ポートに配置し、200 MHz でのタイミングクロージャを確保。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: DWRR トークン更新等の加減算には必ず `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_mc_arb_tb.v`
- **検証項目**:
  1. 調停往復遅延が 2 サイクルに短縮されていること。
  2. 3D クライアントが連続リクエストを投げていても、DC のリクエストが遅延なく最優先でグラントされること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_mc_arb
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 調停遅延が 2 サイクル以下であること。
- DC 優先調停が正常に機能すること。
- `sim/run.sh atg_mc_arb` が PASS すること。
- R1 レビュー APPROVE 獲得。
   - `sim/verilator/run.sh` PASS。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- メモリアービタ遅延が 2 サイクルに短縮されること。
- 最大負荷レンダリング中も DC へのフレームバッファリードが途切れないこと。
