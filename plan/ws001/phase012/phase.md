<!-- awesome-plan project=amaterrace-gpu record=ws001-p012 -->

# Phase 012: スコアボード主導型ワープスケジューラ（GTO & Replay 根絶）

- **親**: [WS001](../ws.md)
- **状態**: `in-review`
- **依存**: [ws001-p011](../phase011/phase.md)
- **優先度**: Major (I$ 帯域浪費・空転の根絶 & キャッシュローカリティ向上)
- **出典**: ユーザー諮問（SU 根本問題）および R1 敵対的アーキテクチャ分析レポート

## 目的

依存待機中のワープを無差別にフェッチし、スコアボードでハザードを検出して命令を破棄・再フェッチする「Replay 空転」を 100% 根絶する。
スコアボード（`atg_su_sb.v`）からイシュー可能なワープマスクをスケジューラ（`atg_su_sched.v`）へ常時フィードバックし、Ready なワープのみをフェッチするスコアボード主導型スケジューリング、および GTO（Greedy-Then-Oldest）ポリシーを導入する。

## 範囲・作業内容

1. **スコアボード主導型フィードバック（`warp_ready` 信号網）**:
   - `atg_su_sb.v` がワープごとのハザード状態（ロングオペレーション未完了、RAW 依存、空きエントリなし）を判定し、`warp_ready[NWARPS-1:0]` を生成。
   - `atg_su_sched.v` は `warp_ready == 1` のワープからのみフェッチ要求（I$）を発行。
   - Replay 機構（`fb_kind = 2`）を廃止。

2. **GTO（Greedy-Then-Oldest）スケジューリングポリシーの実装**:
   - 単純ラウンドロビンを廃止。
   - 実行中ワープがストール（キャッシュミスやロングレイテンシ待ち）するまで同一ワープを連続実行し、ストール時に最も長く待機しているワープへ切り替え。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_sb.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_sched.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/su/atg_su_sched.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_su_sched_gto_tb.v`

### 2. モジュールインターフェース設計 (`atg_su_sb.v` & `atg_su_sched.v`)
- `atg_su_sb.v` から `output wire [NWARPS-1:0] warp_ready` を出力。
- `atg_su_sched.v` へ `input wire [NWARPS-1:0] warp_ready` を入力。
- Replay 信号（`fb_kind`）の処理ロジックを整理・縮小。

### 3. RTL アーキテクチャと GTO スケジューリング
- **Greedy（強欲実行）**:
  現在選択されているワープが次サイクルも `warp_ready == 1` であれば、ワープ切り替えを行わずに同一ワープの次の PC をフェッチし続ける。これにより命令キャッシュおよびテンポラリレジスタの局所性が最大化される。
- **Oldest（最古待機ワープへの交代）**:
  現在ワープがハザード等で `warp_ready == 0` に落ちた場合、待機サイクル数が最も長い Ready ワープを選択してディスパッチ。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 待機カウンタの加算・比較には必ず `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_su_sched_gto_tb.v`
- **検証項目**:
  1. 命令 Replay（無駄なフェッチと破棄）の発生回数がゼロになること。
  2. メモリアクセス待ちが発生した際に、即座に他ワープへ切り替わり、I$ 稼働率が向上すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_su_sched_gto
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- Replay 空転がゼロになり、不要な命令フェッチが根絶されること。
- `sim/run.sh atg_su_sched_gto` が PASS すること。
- R1 レビュー APPROVE 獲得。
   - 単一ワープの L1 データキャッシュおよび LDS（共有メモリ）の局所性を最大化。

3. **単体・回帰検証**:
   - I$ アクセス頻度およびキャッシュミス率の低減確認。
   - `sim/run.sh atg_su_sched`, `atg_su_sb`。
   - `sim/verilator/run.sh`（全 7 モード）での全パス確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 命令フェッチの Replay 発生回数が完全ゼロになること。
- メモリアクセスを伴うシェーダーにおいてキャッシュヒット率が向上すること。
