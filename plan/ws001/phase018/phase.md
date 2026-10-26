<!-- awesome-plan project=amaterrace-gpu record=ws001-p018 -->

# Phase 018: TU 4 レーン並列ストリームアドレス生成（atg_tu_addr 逐次 FSM 撤廃・1 cycle/quad 化）

- **親**: [WS001](../ws.md)
- **状態**: `completed` (2026-10-26 R1敵対的レビューAPPROVE・1 cycle/quad達成)
- **依存**: [ws001-p001](../phase001/phase.md)
- **優先度**: Critical (アドレス生成レイテンシ 8〜16 サイクルから 1 サイクルへ短縮)
- **出典**: ユーザー諮問（TU パイプライン化）および R1 敵対的アーキテクチャ分析レポート

## 目的

`rtl/gpu/tu/atg_tu_addr.v` において、クアッド（4 レーン）のアドレス計算を 1 レーンずつ 2 サイクルかけて FSM で逐次計算している構造（LA $\to$ LB $\to$ LA $\to$ LB、計 8〜16 サイクル浪費）を完全撤廃する。
クアッド共有の LOD $\lambda$ 計算、および 4 レーン並列 Wrap & Footprint アドレス生成を 1 サイクルで完了し、毎サイクル 1 クアッドを処理可能なストリームパイプラインを構築する。

## 範囲・作業内容

1. **4 レーン並列アドレス生成回路の実装**:
   - `atg_tu_addr.v` の逐次ステートマシン（LA/LB）を撤廃。
   - クアッド間偏微分から共通 LOD $\lambda$ を 1 サイクルで決定（Stage 1）。
   - クアッド 4 レーンの Wrap（Repeat, ClampToEdge, ClampToBorder 等）およびバイリニア用 $2 \times 2$ テクセルオフセット計算を 4 レーン並列展開（Stage 2）。

2. **ストリーミングインターフェースの整備**:
   - 入力 `tx_valid` / `tx_ready` から出力 `ta_valid` / `ta_ready` までの固定 2 サイクルパイプライン化。
   - スループット 1 cycle/quad の連続受け入れ対応。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 禁止（`am_mul` 使用）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_addr.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu_addr.md`
- 新設・更新: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_addr_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu_addr.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_tu_addr #(
    parameter NLANES = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // 上流（サンプラー要求）インターフェース
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [NLANES*32-1:0] in_u,       // 4 レーン U 座標 (fp32 または fx32)
    input  wire [NLANES*32-1:0] in_v,       // 4 レーン V 座標
    input  wire [15:0]         in_tex_w,   // テクスチャ幅
    input  wire [15:0]         in_tex_h,   // テクスチャ高さ
    input  wire [3:0]          in_wrap_m,  // Wrap モード (Repeat, Clamp, etc.)
    input  wire [3:0]          in_filter,  // Point / Bilinear / Trilinear

    // 下流（キャッシュアクセス）インターフェース
    output wire        out_valid,
    input  wire        out_ready,
    output wire [NLANES*4*32-1:0] out_texel_addr, // 最大 16 テクセル物理アドレス
    output wire [NLANES*16-1:0]   out_frac_u,     // 補間用 frac_u
    output wire [NLANES*16-1:0]   out_frac_v      // 補間用 frac_v
);
```

### 3. RTL アーキテクチャ詳細
- **Stage 1 (LOD & Unnormalized Coords)**:
  クアッド内レーン差分 $|u_1 - u_0|$, $|v_1 - v_0|$ からフットプリント直径を計算し、LOD レベル（ミップレベル）を算出。
- **Stage 2 (4 レーン並列 Wrap & $2 \times 2$ アドレス展開)**:
  4 レーンそれぞれに対して、整数座標 $(X_0, Y_0)$ と $(X_1, Y_1)$ を Wrap 規則（Repeat: `X & (W-1)`、Clamp: 飽和）に従い並列生成。
  ベースアドレス＋ストライド加算は `am_add` / `am_mul` を通して行い、16 テクセル分のアドレスを生成。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: ストライド乗算には必ず `am_mul` を使用すること。
- **算術演算子禁止**: すべての加減算には `am_add`, `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_addr_tb.v`
- **検証項目**:
  1. 毎サイクル 1 クアッドの連続入力に対して、2 サイクル遅延後に毎サイクル 16 テクセルアドレスが出力されること。
  2. Repeat / Clamp / Mirror 各 Wrap モードの境界値でのアドレス計算の正確性検証。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_addr
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 逐次ステートマシンが撤廃され、スループット 1 cycle/quad を達成すること。
- `sim/run.sh atg_tu_addr` が PASS すること。
- `tools/arith-lint.py` 違反 0 件。
- R1 レビュー APPROVE 獲得。

3. **単体・回帰検証**:
   - `sim/tb/atg_tu_addr_tb.v` による全 Wrap モード・全テクスチャサイズの並列計算ベクトル検証。
   - `sim/run.sh atg_tu`, `sim/verilator/run.sh`（`tex.png`, `core.png`）でのビット完全一致確認。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

## 検証基準（受け入れ条件）

- アドレス生成が 1 cycle/quad のスループットで連続処理できること。
- 既存テストにおいて画像出力が 1 bit の差異もなく一致すること。

---

## 完了記録（2026-10-26）

1. **RTL パイプライン化実装**:
   - `rtl/gpu/tu/atg_tu_addr.v`: 8〜16 サイクルの逐次 FSM（LA $\to$ LB × 4）を解体し、4 レーン並列 2 段ストリームパイプライン（LA $\to$ LB $\to$ OUT）へ刷新。$u, v, w$ 軸並列の LOD 評価回路により、スループット 1 cycle/quad、レイテンシ 2 サイクルを達成。
   - `rtl/gpu/tu/atg_tu_desc.v`: 4 レーン並列読み出しポート（`rd_level0..3` $\to$ `rd_loff0..3`, `rd_plane0..3`）を追加。
   - `rtl/gpu/rop/atg_rop_cache.v`: Verilator lint 警告の完全クリーン化。
   - `spec/gpu/tu/atg_tu_addr.md`: 仕様書改定。
2. **検証結果**:
   - `sim/run.sh atg_tu_addr`: **PASS** (101 s; 全 24 機能テストグループ完全通過)
   - `sim/run.sh atg_tu`: **PASS** (140 s; 32B/64B 両構成の統合テスト通過)
   - `tools/lint.sh`: 全モジュール Clean（0 warnings）
   - `python3 tools/arith-lint.py`: **0 operators outside rtl/library/arith (PASS)**
   - `sim/verilator/run.sh`: 全 7 シーン **PASS**（tex.png, core.png 完全一致）。
3. **敵対的レビュー（R1 判定）**:
   - **APPROVE**（`adversarial_review_ws001_p018_tu_addr.md`）。4 レーン並列ストリーム化、1 cycle/quad スループット、Guardrails 完全準拠を承認。
