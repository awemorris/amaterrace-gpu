<!-- awesome-plan project=amaterrace-gpu record=ws001-p027 -->

# Phase 027: MC AXI バースト結合キュー（Burst Coalescer: ARLEN=3/7 自動マージ）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p003](../phase003/phase.md)
- **優先度**: Critical (DDR3 バス物理稼働率 25% 未満から 85% 以上へ引き上げ)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/mc/atg_mc.v` において、すべての外部メモリアクセスを `ARLEN=0` / `AWLEN=0`（単発 32 バイトアクセス）で発行しているため、DDR3 メモリの Row Activate（tRCD）や Precharge（tRP）が毎回発生し、バス稼働率が 25% 未満に低迷している致命的病理を解消する。
同一ページ・連続アドレスへのアクセスを自動的に検知して `ARLEN=3`（128B）または `ARLEN=7`（256B）のバーストアクセスに統合する AXI Burst Coalescer を実装する。

## 範囲・作業内容

1. **AXI Burst Coalescer の実装**:
   - `rtl/gpu/mc/atg_mc_coalesce.v` を新設。
   - 4 エントリのライン結合キューにより、隣接するキャッシュラインアクセスを監視。
   - 連続するリード/ライト要求を単一の AXI バーストトランザクション（`ARLEN/AWLEN > 0`）へ自動マージ。
2. **バーストレスポンス分配機構**:
   - 外部メモリから返されるバーストデータストリームを各クライアント（SU, TU, ROP, BLT）の要求タグへ正確に逆多重化（Demux）。
3. **単体・回帰検証**:
   - `sim/tb/atg_mc_coalesce_tb.v` によるバースト結合・分割・タイムアウトフラッシュの検証。
   - `sim/verilator/run.sh`（全 7 モード）での全パス確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 連続メモリアクセス時に AXI バーストが自動発行され、DDR バス効率が大幅に向上すること。
- 全クライアントのデータ整合性が完全に維持されること。
