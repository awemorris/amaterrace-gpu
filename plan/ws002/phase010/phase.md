<!-- awesome-plan project=amaterrace-gpu record=ws002-p010 -->

# Phase 010: WSI 高度表示機能（HDR10、マルチプレーンオーバーレイ、VRR）

- **親**: [WS002](../ws.md)
- **状態**: `cleared`
- **依存**: [ws001-p039](../../ws001/phase039/phase.md)
- **優先度**: Minor (Vulkan / WSI 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan WSI（Window System Integration）および最新のディスプレイ表示規格に対応するため、10-bit / HDR10 スキャンアウト、動画再生用のマルチプレーンオーバーレイ（YUV420/NV12 独立ハードウェアプレーン合成）、および可変リフレッシュレート（VRR / Adaptive Sync: VBLANK 動的変調）を実装する。

## 範囲・作業内容

1. **10-bit / HDR10 パイプライン**:
   - 10-bit RGB / A2B10G10R10 フレームバッファの 10-bit パイプライン処理。
   - BT.2020 色空間変換マトリクスおよび SMPTE ST 2084（PQ）EOTF 補正 LUT。
2. **マルチプレーンハードウェアオーバーレイ**:
   - プライマリ 3D プレーンとは独立した動画・UI 専用の第 2 オーバーレイプレーン（スケーラ・カラーキー合成付き）。
3. **VRR（Variable Refresh Rate）制御**:
   - フレーム描画完了（フリップ）タイミングに応じた動的 VBLANK 伸長・同期制御。
4. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - 乗算演算子 `*` 厳禁（`am_mul` 必須）。
   - クロック分周厳禁（ピクセルレート生成は PLL/CE 制御）。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc.v`
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc_tgen.v`
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc_hdr.v`
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/dc/atg_dc_plane2.v`
- 更新: `/home/awe/amaterrace-gpu/spec/gpu/dc/atg_dc.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_dc_wsi_tb.v`

### 2. モジュールインターフェース設計 (`atg_dc_hdr.v` & `atg_dc_plane2.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_dc_hdr (
    input  wire        pclk,
    input  wire        prst_n,
    input  wire        hdr_en,
    input  wire [9:0]  in_r, in_g, in_b, // 10-bit RGB
    output reg  [9:0]  out_r, out_g, out_b
);
```

### 3. RTL アーキテクチャと VRR 制御
- **HDR10 EOTF**: 1024 エントリの BRAM/LUT による SMPTE ST 2084（PQ カーブ）非線形ガンマ変換。
- **マルチプレーン合成**: 第 2 DMA が NV12 動画フレームをフェッチし、YUV $\to$ RGB 変換（`am_mul` マトリクス）を経てプライマリプレーンとピクセル単位でアルファ合成。
- **VRR（Adaptive Sync）**:
  - `atg_dc_tgen.v`: 垂直ブランキング期間（VBLANK）のカウンタを可変にする。
  - 次フレームのフリップ準備完了信号（`flip_ready`）が来るまで VBLANK を伸長（最大フレーム周期まで）。
  - フリップが完了した瞬間に VSYNC を終了してアクティブ走査を開始することで、テアリングなし・スタッターなしの同期表示を実現。

### 4. 厳格な Guardrails 注意事項
- **乗算 `*` 厳禁**: 色空間変換マトリクス（BT.709 $\to$ BT.2020、YUV $\to$ RGB）には必ず `am_mul` を使用すること。
- **クロック分周禁止**: タイミングジェネレータのカウンタは `pclk` のイネーブルストローブで制御すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_dc_wsi_tb.v`
- **検証項目**:
  1. 10-bit フレームバッファからの HDR10 スキャンアウト精度検証。
  2. 不規則なフレーム描画完了タイミングに対し、VBLANK が動的に伸縮してテアリングフリーで表示されること。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_dc_wsi
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 10-bit HDR10 出力が正常に行われること。
- マルチプレーンオーバーレイが正しく合成されること。
- VRR タイミングジェネレータが可変フレームレートに追従すること。
- `sim/run.sh atg_dc_wsi` が PASS すること。
- R1 レビュー APPROVE 獲得。
