<!-- awesome-plan project=amaterrace-gpu record=ws002-p009 -->

# Phase 009: 非同期 DMA 転送キュー & 3D ボリュームコピー

- **親**: [WS002](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p030](../../ws001/phase030/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan 1.0 仕様で定められる専用非同期転送キュー（`VK_QUEUE_TRANSFER_BIT`: 3D レンダリングやコンピュートシェーダと完全に独立してバックグラウンドで動作する DMA エンジン）、および 3D テクスチャ（ボリュームテクスチャ）のバッファ・画像間コピー（`vkCmdCopyBufferToImage` 3D）をサポートする。

## 範囲・作業内容

1. **独立非同期 DMA リングバッファ**:
   - グラフィックスリングとは独立した DMA 専用リングバッファおよび同期セマフォ機構を CP / BLT に追加。
2. **3D スライス間コピー制御**:
   - 奥行き（Depth / Slice）ストライドを伴う 3D ボリュームテクスチャのパッキング・アンパッキング制御を追加。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` 必須）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/blt/atg_blt_2d.v`
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/blt/atg_blt_3d.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/blt/atg_blt_3d.md`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/cp/atg_cp_ring.v`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_blt_async_tb.v`

### 2. モジュールインターフェース設計 (`atg_blt_3d.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_blt_3d (
    input  wire        clk,
    input  wire        rst_n,

    // 3D コピー要求
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] src_base, dst_base,
    input  wire [31:0] src_row_stride, dst_row_stride,
    input  wire [31:0] src_slice_stride, dst_slice_stride,
    input  wire [15:0] copy_w, copy_h, copy_d, // 幅・高さ・スライス数

    // 完了通知
    output reg         done
);
```

### 3. RTL アーキテクチャと 3D ループ制御
- 3 重ループ（$Z \to Y \to X$）のハードウェアステートマシン。
- 1 つのスライス（2D 面）の転送が完了するたびに、ベースアドレスに `slice_stride` を加算（`am_add`）。
- CP 側の専用 Transfer キュー（`RING_DMA`）から直接ディスパッチされ、グラフィックス側のドローコールと並行して AMB メモリ帯域を消費。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 3D オフセット計算（`z * slice_stride + y * row_stride`）には必ず `am_add`, `am_mul` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_blt_async_tb.v`
- **検証項目**:
  1. 3D ボリューム画像（$128 \times 128 \times 64$ テクセル）のバッファ間コピーが、スライス跨ぎを含めて正確に完了すること。
  2. メインの 3D 描画中にバックグラウンドで非同期転送キューが動作し、データ破壊やデッドロックが起きないこと。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_blt_async
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 独立非同期 DMA 転送キューが正常に動作すること。
- 3D ボリュームコピーが正確に実行できること。
- `sim/run.sh atg_blt_async` が PASS すること。
- R1 レビュー APPROVE 獲得。
