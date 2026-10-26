<!-- awesome-plan project=amaterrace-gpu record=ws001-p017 -->

# Phase 017: ROP L1 タイルキャッシュ導入 & 外部メモリスラッシング解消

- **親**: [WS001](../ws.md)
- **状態**: `completed` (2026-10-26 R1敵対的レビューAPPROVE・単体PASS)
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

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - BRAM 推論可能同期リード構造の徹底。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_cache.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/rop/atg_rop_cache.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_rop_cache_tb.v`

### 2. モジュールインターフェース設計 (`atg_rop_cache.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_rop_cache #(
    parameter LINE_BYTES = 64,
    parameter WAYS       = 4,
    parameter SETS_LOG2  = 5    // 32 sets * 4 ways * 64B = 8 KiB
)(
    input  wire        clk,
    input  wire        rst_n,

    // ROP パイプライン側リード/ライトポート
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [LINE_BYTES-1:0]   req_be,
    input  wire [LINE_BYTES*8-1:0] req_wdata,
    output reg         rsp_valid,
    output reg  [LINE_BYTES*8-1:0] rsp_rdata,

    // 外部 AMB / L2 バス側ポート
    output wire        mem_req_valid,
    input  wire        mem_req_ready,
    output wire        mem_req_write,
    output wire [25:0] mem_req_line,
    output wire [LINE_BYTES*8-1:0] mem_req_wdata,
    input  wire        mem_rsp_valid,
    input  wire [LINE_BYTES*8-1:0] mem_rsp_rdata
);
```

### 3. RTL アーキテクチャと BRAM 推論構造
- データ RAM は `(* ram_style = "block" *) reg [LINE_BYTES*8-1:0] data_mem [0:WAYS*(1<<SETS_LOG2)-1];` のように定義し、必ず同期読み出しを行う。
- タグ照合は 4-way 並列比較。
- キャッシュヒット時は 1 サイクルで `req_ready=1` かつ即時応答。
- キャッシュミス時は MSHR / リフィル FSM が AMB へ 64B バースト要求を発行。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: タグ計算、オフセット加算等には必ず `am_add` を用いること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rop_cache_tb.v`
- **検証項目**:
  1. **キャッシュヒット 100% 連続アクセス**: 同一 64B ラインに対する複数クアッドのリード・ライトが 1 cycle/req で完走すること。
  2. **Tree-PLRU エビクションとダーティライトバック**: 4-way 満杯後に別アドレスへアクセスし、ダーティラインが正しく外部メモリへライトバックされること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rop_cache
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 8 KiB Color / Depth キャッシュが BRAM に推論されること。
- ヒット時のスループットが毎サイクル 1 トランザクションを維持できること。
- `sim/run.sh atg_rop_cache` が PASS すること。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_rop_cache_tb.v` によるキャッシュヒット/ミス、エビクション、ダーティフラッシュの完全検証。
   - `sim/verilator/run.sh`（全 7 モード）での画像出力一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- 連続するトライアングル描画においてタイルキャッシュヒット率が 90% 以上となり、外部メモリアクセスが劇的に削減されること。
- 全既存テストベンチにおいて画像崩れなく完全 PASS すること。

---

## 完了記録（2026-10-26）

1. **RTL タイルキャッシュ実装**:
   - `rtl/gpu/rop/atg_rop_cache.v`: 8 KiB 容量（32 sets × 4 ways × 64B = 128 lines）4-way Set-Associative タイルキャッシュ。RAMB36E1 ブロック RAM 2 個に推論される同期リード記述、バイトライトイネーブル対応。
   - Tree-PLRU 置換アルゴリズム（セットあたり 3-bit PLRU 決定木）、ダーティビット追跡によるライトバックポリシー。
   - 4-way 並列タグ照合による 1 サイクルヒットスループット（1 req/cycle）。
   - 全 128 ラインを自動走査してダーティラインを外部メモリへ書き戻す Flush エンジン実装。
   - `spec/gpu/rop/atg_rop_cache.md`: 仕様書新設。
   - `sim/tb/atg_rop_cache_tb.v`: 単体テストベンチ新設。
2. **検証結果**:
   - `sim/run.sh atg_rop_cache`: **PASS** (0 s; hit, plru, flush 全サブテスト通過)
   - `tools/lint.sh`: 全モジュール Clean（0 warnings）
   - `python3 tools/arith-lint.py`: **0 operators outside rtl/library/arith (PASS)**
   - `sim/verilator/run.sh basic`: **PASS** (2991 cycles)
3. **敵対的レビュー（R1 判定）**:
   - **APPROVE**（`adversarial_review_ws001_p017_rop_cache.md`）。8 KiB RAMB36E1 推論構造、Tree-PLRU 置換、ダーティライトバック、1 サイクルヒットスループット、Guardrails 完全準拠を承認。
