<!-- awesome-plan project=amaterrace-gpu record=ws001-p017 -->

# Phase 017: ROP L1 タイルキャッシュ導入 & 外部メモリスラッシング解消

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p016](../phase016/phase.md), [ws001-p003](../phase003/phase.md)
- **優先度**: Major (外部 DRAM トラフィック 70〜80% 削減 & キャッシュスラッシング解消)
- **出典**: ユーザー諮問（ROP パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/rop/atg_rop_wb.v` にあるわずか 2 ライン（64B/128B）の Write-Combining バッファを廃止する。
8KB Color / 8KB Depth の 4-way Set-Associative タイルキャッシュ（$8 \times 8$ ピクセル単位、RAMB36E1 推論）を導入し、トライアングル描画中の外部メモリトラフィックを 70〜80% 削減してレンダリングレイテンシを完全に隠蔽する。

## 範囲・作業内容

1. **ROP 専用 L1 タイルキャッシュの実装**:
   - `rtl/gpu/rop/atg_rop_cache.v` を新設。
   - Color キャッシュ（8 KiB, 4-way, 64B ライン）および Depth キャッシュ（8 KiB, 4-way, 64B ライン）を RAMB36E1 推論構造で実装。
   - エビクションポリシーは Tree-PLRU、ライトバック＋ダーティビット管理。

2. **パイプライン・AMB インターフェース統合**:
   - Phase 016 の 5 段パイプラインの Stage 1（TAG/Read）および Stage 4（COMM/Write）と直結。
   - ミス時のリフィルおよびエビクションは、Phase 003 の共有 L2 キャッシュ（LLC）と AMB バースト転送で連携。

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_cache_tb.v` によるキャッシュヒット/ミス、エビクション、ダーティフラッシュの完全検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 連続するトライアングル描画においてタイルキャッシュヒット率が 90% 以上となり、外部メモリアクセスが劇的に削減されること。
- 全既存テストベンチにおいて画像崩れなく完全 PASS すること。
