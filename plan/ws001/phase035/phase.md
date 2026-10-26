<!-- awesome-plan project=amaterrace-gpu record=ws001-p035 -->

# Phase 035: Full Skid Buffer（am_skid.v）実装と形式検証（0 バブル切断）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (長距離ハンドシェイク配線の完全タイミング切断 & 100% スループット保証)
- **出典**: ユーザー諮問（DC & BUS 最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

GPU 内部のブロック間長距離配線において、Forward（`valid` / `data`）と Reverse（`ready`）の両方向のタイミングパスをフリップフロップで完全に切断しつつ、バブルなし（100% スループット）でデータを転送可能な Full Skid Buffer（レジスタスライス）`rtl/library/bus/am_skid.v` を実装・共通化する。

## 範囲・作業内容

1. **`am_skid.v` の設計・実装**:
   - `rtl/library/bus/am_skid.v` を新設。
   - メインレジスタおよびスキッドレジスタ（2 エントリ構造）によるゼロバブル切断。
   - `in_ready` はスキッドレジスタが空のとき即座にアサート（組み合わせループなし）。
   - パラメータ `W`（データ幅）対応。
2. **単体・形式検証**:
   - `sim/tb/am_skid_tb.v` を作成し、バックプレッシャー、ランダムストール、連続バースト転送でのスループット 100% およびデータ順序保存を完全検証。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- `valid` および `ready` の組み合わせパスが完全に遮断され、かつ毎サイクル 1 トランザクションを遅延なく中継できること。
