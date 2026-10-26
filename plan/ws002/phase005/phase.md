<!-- awesome-plan project=amaterrace-gpu record=ws002-p005 -->

# Phase 005: TU シームレスキューブマップフィルタリング

- **親**: [WS002](../ws.md)
- **状態**: `completed`
- **依存**: [ws001-p018](../../ws001/phase018/phase.md)
- **優先度**: Minor (Vulkan 1.0 適合性・後回し実装)
- **出典**: ユーザー指示（Vulkan 1.0 適合の後回し WS 切り出し）および R1 アドバイス書

## 目的

Vulkan 1.0 コア仕様で義務付けられているキューブマップの面境界（Face Edge）におけるシームレスフィルタリング（境界を跨いだテクセル間のバイリニア補間）を実装し、キューブマップの継ぎ目ノイズを完全に解消する。

## 範囲・作業内容

1. **面境界テクセルフェッチ回路**:
   - `atg_tu_addr.v` において、境界を越えたテクセル座標を隣接するキューブ面の適切なテクセルへリマッピングする境界変換ロジックを追加。
2. **キューブ面間座標変換**:
   - 6 面（+X, -X, +Y, -Y, +Z, -Z）の境界トポロジーテーブルに基づき、オーバーフローしたテクセルの面番号および回転座標（$(u', v') = (v, \text{size}-1-u)$ 等）を 1 サイクルで変換。
3. **Guardrails & リント**:
   - `python3 tools/arith-lint.py` で生演算子 0 件。
   - R1 による敵対的コードレビュー（APPROVE 必須）。

---

## 実装設計詳細ガイドライン（Opus 5.5 向け）

### 1. 対象ファイル一覧（絶対パス）
- 更新: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_addr.v`
- 新設: `/home/awe/amaterrace-gpu/rtl/gpu/tu/atg_tu_cube_edge.v`
- 新設: `/home/awe/amaterrace-gpu/spec/gpu/tu/atg_tu_cube_edge.md`
- 新設・検証: `/home/awe/amaterrace-gpu/sim/tb/atg_tu_cube_tb.v`

### 2. モジュールインターフェース設計 (`atg_tu_cube_edge.v`)

```verilog
`timescale 1ns / 1ps
`default_nettype none

module atg_tu_cube_edge (
    input  wire [2:0]  face_in,      // 0:+X, 1:-X, 2:+Y, 3:-Y, 4:+Z, 5:-Z
    input  wire [15:0] u_in, v_in,   // テクセル座標 (符号付きまたはオフセット付き)
    input  wire [15:0] size,         // 面サイズ

    output reg  [2:0]  face_out,     // 変換後面番号
    output reg  [15:0] u_out, v_out  // 変換後座標
);
```

### 3. RTL アーキテクチャと面間トポロジー変換
- テクセル座標が境界外（$u < 0$, $u \ge \text{size}$, $v < 0$, $v \ge \text{size}$）になった場合、立方体の 12 稜線の隣接関係に基づいて面番号と座標を変換。
- 例: Face +X の右境界（$u \ge \text{size}$）は Face -Z の左境界へ接続。
- コーナー（頂点）付近の 3 面境界テクセルは、隣接 2 面の平均値でフォールバック。

### 4. 厳格な Guardrails 注意事項
- **算術演算子禁止**: 境界座標計算（`size - 1 - u` 等）には必ず `am_sub` を使用すること。

### 5. テストベンチ検証シナリオ（T1/P1 共通）
- **テストファイル**: `sim/tb/atg_tu_cube_tb.v`
- **検証項目**:
  1. キューブマップの全 12 本のエッジ境界を跨ぐバイリニアサンプリングにおいて、面を跨いだテクセル値が正確にブレンドされること。
  2. スカイボックス描画時に継ぎ目線（シーム）が 1 ピクセルも現れないこと。
- **実行コマンド**:
  ```bash
  ./sim/run.sh atg_tu_cube
  python3 tools/arith-lint.py
  ```

---

## 検証基準（受け入れ条件）

- 6 面の境界を跨ぐ補間において、シーム（継ぎ目線）が一切生じないこと。
- `sim/run.sh atg_tu_cube` が PASS すること。
- R1 レビュー APPROVE 獲得。
