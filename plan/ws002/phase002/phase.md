<!-- awesome-plan project=amaterrace-gpu record=ws002-p002 -->

# Phase 002: SU / ROP Dual Source Blending（フォント描画用 src1 カラー出力）

- **親**: [WS002](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p010](../../ws001/phase010/phase.md), [ws002-p001](../phase001/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

サブピクセルフォントレンダリング等で必須となる Dual Source Blending（`SRC1_COLOR`, `ONE_MINUS_SRC1_COLOR`, `SRC1_ALPHA`, `ONE_MINUS_SRC1_ALPHA`）をサポートするため、SU のフラグメントエクスポートパスおよび ROP ブレンド入力パスを拡張する。

## 範囲・作業内容

1. **SU エクスポートパス拡張**:
   - `atg_su_exp.v` において、フラグメントシェーダのロケーション 0 (`src0`) およびロケーション 1 (`src1`) のカラー出力を ROP へ転送するバス拡張。

2. **ROP ブレンドファクタ拡張**:
   - `atg_rop_blend.v` に `src1` を第 2 ソースとして選択可能なファクタ生成ロジックを追加。

3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` / `am_fp_mul` のみ）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/su/atg_su_exp.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/rop/atg_rop_blend.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/rop/atg_rop_blend.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_rop_dualsrc_tb.v`

### 2. モジュールインターフェース設計 (`atg_rop_blend.v` 拡張)

```verilog
    // クアッド入力
    input  wire [NPIX*32-1:0] in_src0, // 通常のフラグメントカラー
    input  wire [NPIX*32-1:0] in_src1, // 第 2 ソースカラー（Dual Source Blending 用）
    input  wire [NPIX*32-1:0] in_dst,
    input  wire        in_has_src1
```

### 3. RTL アーキテクチャと Dual Source ブレンドファクタ
- ブレンドファクタ定義への追加:
  - `VK_BLEND_FACTOR_SRC1_COLOR`: ファクタとして `in_src1[RGB]` を選択。
  - `VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR`: ファクタとして `1.0 - in_src1[RGB]` を選択。
  - `VK_BLEND_FACTOR_SRC1_ALPHA`: ファクタとして `in_src1[A]` を選択。
  - `VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA`: ファクタとして `1.0 - in_src1[A]` を選択。
- SU 側エクスポートパス（`atg_su_exp.v`）において、Location 1 への書き出し命令（`EXPORT COLOR1`）を検知し、ROP パイプラインへ `src0` と同期して転送。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: ブレンドファクタとカラーの乗算は必ず `am_mul` / `am_fp_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_rop_dualsrc_tb.v`
- **検証項目**:
  1. サブピクセルフォント描画（`src0` = テキスト色、`src1` = サブピクセルカバレッジマスク）において、LCD サブピクセルアンチエイリアシングが正常にブレンドされること。
  2. `SRC1_COLOR` および `ONE_MINUS_SRC1_COLOR` ファクタの全ビット精度検証。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_rop_dualsrc
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- Dual Source Blending の全ファクタが正常に動作すること。
- `sim/run.sh atg_rop_dualsrc` が PASS すること。
- R1 レビュー APPROVE 獲得。
