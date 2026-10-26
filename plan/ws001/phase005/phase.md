<!-- awesome-plan project=amaterrace-gpu record=ws001-p005 -->

# Phase 005: マルチエンジン独立キューイング & ハードウェアプリエンプション

- **親**: [WS001](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p004](../phase004/phase.md)
- **優先度**: Major
- **出典**: R1 敵対的仕様レビュー（観点2 & 3: 単一リング直列化、プリエンプション不在による UI フリーズ）

## 目的

単一リングバッファによる直列実行（Graphics / Compute / DMA 転送のブロッキング）を解消し、マルチエンジン独立キューイング（Async Compute / バックグラウンド DMA 転送の並行実行）と、ドロー/ワープ境界でのハードウェアプリエンプションを実現する。

## 範囲・作業内容

1. **独立キューレジスタマップの拡張**:
   - `RING[i]_BASE/SIZE/WPTR/RPTR`（Graphics, Compute, Copy/DMA の 3 系統独立キュー）の実装。
2. **ハードウェアコンテキストスイッチ・プリエンプション機構**:
   - ドローコール境界またはワープ境界での実行中断・コンテキスト退避・復帰機構の実装。
   - OS コンポジタの低遅延割り込み保証。
3. **キュー間依存関係同期**:
   - キューを跨いだ軽量セマフォ同期機構の実装。
4. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp_ring.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp_regs.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/cp/atg_cp.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_cp_multi_queue_tb.v`

### 2. モジュールインターフェース設計 (`atg_cp_ring.v` 拡張)
- キュー ID `queue_id[1:0]` (0: Graphics, 1: Compute, 2: Copy/DMA)。
- 各キューに対応する `WPTR`, `RPTR`, `BASE`, `SIZE` レジスタアレイ。
- キューごとの独立フェッチアービタ（ラウンドロビン＋優先度制御）。

### 3. RTL アーキテクチャとプリエンプション動作
- **プリエンプション要求**: ホストから `CP_PREEMPT` レジスタへ書き込み。
- **実行中断**: 実行中のシェーダ/ラスタライズ処理に対し、現在のドローコールまたはワープ完了境界で新規イシューを停止。
- **コンテキスト退避**: CP が現在のステートレジスタ（パイプライン設定、バインディング等）を指定メモリ領域へ DMA 保存。
- **高優先度キュー実行**: コンポジタ（UI）用キューの実行を開始。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: ポインタ計算等はすべて `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_cp_multi_queue_tb.v`
- **検証項目**:
  1. 長時間の Compute カーネル実行中に、Graphics キューへドローコールを投入した際、コンテキストスイッチが正常に発生して割り込み処理されること。
  2. Copy/DMA キューがバックグラウンドで並行実行されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_cp_multi_queue
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- バックグラウンド DMA 転送中であっても Graphics ドローコールが並行して実行されること。
- 長時間実行シェーダーに対してプリエンプション要求を発行し、指定レイテンシ以内にコンテキストスイッチが完了すること。
- R1 レビュー APPROVE 獲得。
