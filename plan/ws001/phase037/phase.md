<!-- awesome-plan project=amaterrace-gpu record=ws001-p037 -->

# Phase 037: am_axi_master.v の深層 Outstanding 化（16〜32 枠対応）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Major (DDR3/4 高レイテンシ環境下でのメモリ帯域飽和)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/library/bus/am_axi_master.v` において、`OUTSTANDING_LOG2 = 2`（最大 4 リクエスト）と極めて浅く設定されているため、DDR3 メモリのラウンドトリップレイテンシ（50〜100 サイクル）下でリクエストキューが即座に詰まり、メモリ帯域の 20% 未満しか引き出せない問題を解決する。
Outstanding 管理構造を最大 16〜32 枠（`OUTSTANDING_LOG2 = 4/5`）へ拡張し、高レイテンシ環境下でもパイプラインを常時満杯にして DDR 物理帯域を 85% 以上飽和させる。

## 範囲・作業内容

1. **Outstanding 管理テーブルの深層化**:
   - `am_axi_master.v` のインフライトリクエスト追跡バッファ（ID/Key 追跡、タグ格納 FIFO）の深さをパラメータ化し、16〜32 枠へ拡張。
   - レジスタスライス（Phase 035 の Skid Buffer）を AXI チャネル（AW, W, B, AR, R）に挿入し、段数増加に伴うタイミング悪化を防止。
2. **単体・回帰検証**:
   - `sim/tb/am_axi_master_tb.v` による 32 枠フルインフライト時のリオーダー、インターリーブ応答検証。
   - `sim/verilator/run.sh` PASS。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 32 枠の Outstanding リクエストが正常に追跡・完了できること。
- メモリ応答遅延が大きい環境下での実効スループットが劇的に向上すること。
