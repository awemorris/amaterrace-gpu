<!-- awesome-plan project=amaterrace-gpu record=ws002-p006 -->

# Phase 006: TU デスクトップ標準圧縮テクスチャ（BC1〜BC7 デコーダ）

- **親**: [WS002](../ws.md)
- **状態**: `planned`
- **依存**: [ws001-p020](../../ws001/phase020/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

PC / デスクトップ環境の標準テクスチャ圧縮フォーマットである Block Compression（BC1〜BC5: DXT1〜DXT5、BC6H: HDR、BC7: 高品位 UNORM）のハードウェアデコーダを実装し、商用 Vulkan アプリケーションの互換性を確立する（現状はモバイル向けの ETC2/EAC のみ）。

## 範囲・作業内容

1. **BC1〜BC7 ハードウェアデコーダの実装**:
   - `rtl/gpu/tu/atg_tu_bc.v` を新設。
   - $4 \times 4$ テクセルブロックのビットストリームを展開し、RGBA8 / FP16 テクセルをリアルタイム伸張。
2. **キャッシュ・フォーマットパイプライン統合**:
   - Stage 4 (DECP) に BC デコードパスを追加。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` 必須）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_bc.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu_bc.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_decp.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_bc_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu_bc.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_tu_bc (
    input  wire        clk,
    input  wire        rst_n,

    // デコード要求 (1 ブロック = 64/128 bits)
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [3:0]  fmt_bc,      // 1:BC1, 2:BC2, 3:BC3, 4:BC4, 5:BC5, 6:BC6H, 7:BC7
    input  wire [127:0] in_block,
    input  wire [3:0]  sub_texel,   // ブロック内テクセルインデックス (0..15)

    // デコード結果 (RGBA8888 または FP16x4)
    output wire        out_valid,
    input  wire        out_ready,
    output wire [31:0] out_rgba,
    output wire [63:0] out_fp16
);
```

### 3. RTL アーキテクチャと補間ロジック
- **BC1〜BC3 (RGB565 エンドポイント)**:
  $c_0$ と $c_1$ から中間色を補間（$2/3 c_0 + 1/3 c_1$ 等）。加減算・シフトで実装。
- **BC4/BC5 (単一・2 チャンネル UNORM8/SNORM8)**:
  8-bit エンドポイント $e_0, e_1$ から 6 または 8 段階のランプを補間。
- **BC6H / BC7 (モードベース可変パーティション)**:
  モードビットをデコードし、サブセット分割（1〜3 サブセット）に応じて P-bit およびウェイトインデックスを適用。
- 1 サイクルスループットでパイプラインデコード。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: エンドポイント補間の加算・除算（シフト）には必ず `am_add` / `am_addsub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_bc_tb.v`
- **検証項目**:
  1. BC1〜BC7 の Khronos 公式テストベクタ（全モード）を投入し、出力ピクセルがビット完全一致すること。
  2. 毎サイクル 1 テクセルの連続デコードスループットを維持すること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_bc
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- BC1〜BC7 の全フォーマットが仕様通りに伸張できること。
- `sim/run.sh atg_tu_bc` が PASS すること。
- R1 レビュー APPROVE 獲得。
