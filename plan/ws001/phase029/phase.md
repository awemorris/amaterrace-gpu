<!-- awesome-plan project=amaterrace-gpu record=ws001-p029 -->

# Phase 029: CP 64ワード循環コマンドプリフェッチ FIFO（ノーウェイトパケット供給）

- **親**: [WS001](../ws.md)
- **状態**: `completed` (2026-10-26 R1敵対的レビューAPPROVE・FW全14件PASS)
- **依存**: [ws001-p002](../phase002/phase.md)
- **優先度**: Major (コマンドリング 32B 境界停止の完全消滅)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/cp/atg_cp_ring.v` において、コマンドリングフェッチ用のバッファが単一の 32 バイトラインしかないため、32 バイト境界を跨ぐたびに外部メモリリード待ち（15〜25 サイクル）でデコードが完全停止している問題を解消する。
64 ワード（256 バイト）の循環プリフェッチ FIFO を導入し、デコーダがパケットを処理中に先行して次パケットをフェッチする二重バッファリングにより、コマンド供給バブルを完全にゼロにする。

## 範囲・作業内容

1. **64 ワード循環プリフェッチ FIFO の実装**:
   - `atg_cp_ring.v` を改修し、64 ワード BRAM/分散 RAM FIFO を配置。
   - FIFO 残量が閾値（例: 32 ワード）を下回った際、自動的にリングバッファから先行バーストフェッチを発行。
2. **パケット境界アライメント制御**:
   - コマンドデコーダ（`atg_cp_seq_dec.v`）に対し、ワード境界を跨ぐパケットをノーウェイトで連続供給。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp_ring.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/cp/atg_cp_ring.md`
- テスト検証: `/home/awe/amaterrace-gpu/fw/cp/tests/run.sh`

### 2. モジュールインターフェース設計 (`atg_cp_ring.v`)
- CP 内部バスおよびデコーダ向けインターフェースは完全互換を維持。
- パケット読み出しインターフェース（`pkt_valid`, `pkt_ready`, `pkt_data[31:0]`）は FWFT（First-Word Fall-Through）動作。

### 3. RTL アーキテクチャとプリフェッチ制御
- FIFO 深度: 64 ワード（256 バイト）。
- 水位監視: FIFO 内のワード数が 32 未満（`fifo_count < 32`）かつリングバッファに未読データがある場合、AMB 経由で 32 バイト（8 ワード）ラインリード要求を自動的に先行発行。
- これにより、デコーダがコマンドを解析・実行している背後で常に次パケットがプリフェッチされ、32B 境界での停止が完全に消滅する。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: ポインタインクリメント、残量計算等はすべて `am_add` / `am_sub` を使用すること。

### 5. テスト検証シナリオ（T1/P1 共通）
- **テストコマンド**:
  ```bash
  ./fw/cp/tests/run.sh
  ./sim/run.sh atg_cp_tb
  python3 tools/arith-lint.py
  ```
- CP コマンドリングテスト全 14 ケースがすべて PASS すること。

---

## 検証基準（受け入れ条件）

- 32 バイト境界でのデコーダ停止が完全に解消されること。
- `fw/cp/tests/run.sh` が PASS すること。
- R1 レビュー APPROVE 獲得。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- コマンドライン境界を跨ぐ描画パケット列において、フェッチストールが一切発生しないこと。
- 全既存テストベンチが完全 PASS すること。

---

## 完了記録（2026-10-26）

1. **RTL 最適化実装**:
   - `rtl/gpu/cp/atg_cp_ring.v`: 8 エントリ（64 ワード / 256 バイト）の循環ラインバッファ（キャッシュ）およびバックグラウンド・プリフェッチ FSM を新設。
   - クラス N パケットデコードの背後で次ラインを自動先行フェッチし、32B/64B 境界でのリード待ち（15〜25 サイクル）を完全隠蔽（0 サイクル・ノーウェイト供給）。
   - ドアベル書き込み時のアトミックなキャッシュ無効化（`buf_valid <= 8'd0`, `stale <= 1'b1`）により、周回時の古いデータの誤読を完全防止。
   - `spec/gpu/cp/atg_cp_ring.md`: 仕様書更新。
2. **検証結果**:
   - `sim/run.sh atg_cp_ring`: **PASS** (1 s)
   - `fw/cp/tests/run.sh`: **全 14 ケース PASS**（diag, sessions, buffers, images, draw, compute, transfer, mmu, prot 等）
   - `sim/run.sh atg_top_fw`: **PASS** (104 s)
   - `tools/lint.sh`: 全モジュール Clean（0 warnings）
   - `python3 tools/arith-lint.py`: **0 operators outside rtl/library/arith (PASS)**
3. **敵対的レビュー（R1 判定）**:
   - **APPROVE**（`adversarial_review_ws001_p029_cp_ring.md`）。64 ワード循環プリフェッチキャッシュ、バックグラウンドフェッチ FSM、ドアベル無効化、Guardrails 完全準拠を承認。
