<!-- awesome-plan project=amaterrace-gpu record=ws001-p033 -->

# Phase 033: VF 32エントリ Post-Transform Vertex Cache（PT-VC: 頂点重複計算 60% 削減）

- **親**: [WS001](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p032](../phase032/phase.md), [ws001-p010](../phase010/phase.md)
- **優先度**: Critical (インデックス再利用による頂点シェーダ負荷 & メモリトラフィック 50〜75% 削減)
- **出典**: ユーザー諮問（周辺ブロック最適化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/vf/atg_vf.v` に頂点キャッシュが存在しないため、インデックス描画（Indexed Draw）時に平均 3〜6 倍存在する同一頂点を毎回 DRAM からフェッチし、SU 頂点シェーダを重複実行している GPU アーキテクチャ上の最大欠落を解決する。
32 エントリの Post-Transform Vertex Cache（PT-VC）を導入し、同一インデックスの頂点シェーディング結果を 0 サイクルで再利用して、頂点処理性能を 2〜3 倍に引き上げる。

## 範囲・作業内容

1. **32 エントリ Post-Transform Vertex Cache の実装**:
   - `rtl/gpu/vf/atg_vf_vc.v` を新設。
   - 32 エントリのインデックスタグ CAM（FIFO / LRU 置換）。
   - シェーディング済み頂点データ（クリップ座標 $x, y, z, w$、ポイントサイズ、Varying 出力）を保持する高速 BRAM/分散 RAM。
2. **シェーダバイパス制御**:
   - インデックスフェッチ時に PT-VC を検索。
   - **Hit**: SU への頂点イシューを完全バイパスし、キャッシュから直接ラスタライザ（RX）のプリミティブテーブルへ転送（0 サイクルシェーディング）。
   - **Miss**: 通常通り SU へ頂点ワープを発行し、シェーディング完了後に PT-VC へコミット。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/vf/atg_vf_vc.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/vf/atg_vf_vc.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/vf/atg_vf.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_vf_vc_tb.v`

### 2. モジュールインターフェース設計 (`atg_vf_vc.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_vf_vc #(
    parameter NENTRIES = 32,
    parameter VDATA_W  = 512  // クリップ座標 + Varying 属性
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,       // ドローコール境界でのキャッシュフラッシュ

    // インデックスルックアップポート
    input  wire        lookup_valid,
    input  wire [31:0] lookup_index,
    output wire        hit,
    output wire [VDATA_W-1:0] hit_vdata,
    output wire [4:0]  hit_slot,

    // SU シェーダ完了コミットポート
    input  wire        commit_valid,
    input  wire [31:0] commit_index,
    input  wire [VDATA_W-1:0] commit_vdata
);
```

### 3. RTL アーキテクチャとバイパス制御
- 32 エントリの全並列 CAM 照合（`lookup_index == entry_idx[i]`）。
- ヒットした頂点は SU ワープキューを介さず、RX 側の頂点アセンブラへ直接転送。
- ミスした頂点のみが SU にディスパッチされ、SU がシェーダプログラムを完走した時点で PT-VC の該当エントリへ結果が書き込まれる（Write-Through / Commit）。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: ポインタ、LRU カウンタ等の更新には必ず `am_add` / `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_vf_vc_tb.v`
- **検証項目**:
  1. インデックス共有メッシュ（例: 球体や立方体メッシュ）を投入した際、同一頂点の再計算がバイパスされ、SU へのワープ投入数が 50% 以上削減されること。
  2. 出力される頂点データが非キャッシュ時とビット完全一致すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_vf_vc
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- PT-VC ヒット時にシェーダ実行がバイパスされること。
- インデックス描画での頂点処理スループットが 2 倍以上に向上すること。
- `sim/run.sh atg_vf_vc` が PASS すること。
- R1 レビュー APPROVE 獲得。
3. **単体・回帰検証**:
   - `sim/tb/atg_vf_vc_tb.v` によるインデックス再利用ヒット率、エビクション、コーナーケース検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 典型的な 3D メッシュ（インデックス共有モデル）において、頂点シェーダの実行回数が 50〜70% 削減されること。
- レンダリング結果が既存シミュレーション画像と 1 bit の差異もなく一致すること。
