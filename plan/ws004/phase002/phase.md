<!-- awesome-plan project=amaterrace-gpu record=ws004-p002 -->

# Phase ws004-p002: SU 内部 Meshlet プリミティブエクスポート（atg_su_exp_mesh）& LDS インターフェース設計・実装

- Workstream: [WS004](../ws.md)
- Status: `cleared`
- Depends on: ws004-p001

## 目的

承認された SU support for task/mesh shader（vk_ext_mesh_shader, vk_ext_task_shader）アーキテクチャ設計（64頂点/126プリミティブ、LDS 2.5 KiB 収容、追加 BRAM ゼロ、LDS 自律バースト DMA エクスポート、RX 直結ストリームバス）に基づき、Shader Unit（SU: `atg_su_exp` および `atg_su_lds`）内部のエクスポートシーケンサ（`atg_su_exp_mesh`）およびインターフェースを設計・実装する。

## 変更対象ファイル

- `rtl/gpu/su/atg_su_exp_mesh.v` (新規: mesh shader エクスポートシーケンサ & 2段スキッドバッファ)
- `rtl/gpu/su/atg_su_exp.v` (mesh shader エクスポートシーケンサ u_mesh 統合 & GSI1 target 0x200 kick 連携)
- `rtl/gpu/su/atg_su_lds.v` (Port B 独立読み出しポート新設、追加 BRAM ゼロ)
- `rtl/gpu/su/atg_su.v` (mesh shader エクスポートポート新設: `mesh_valid`, `mesh_ready`, `mesh_tri`, `mesh_last`, `mesh_id`)
- `rtl/gpu/top/atg_top.v` (トップレベルでの mesh ポート配線・スタブ整合)
- `spec/gpu/su/atg_su_exp.md` (mesh shader インターフェース仕様・シーケンサ動作の文書化)
- `sim/tb/atg_su_exp_mesh_tb.v` (新規単体テストベンチ: 三角形完全生成、高速ハードウェアカリングスキップ、スキッドバッファバックプレッシャー)
- `sim/tb/atg_su_lds_tb.v`, `sim/tb/atg_su_exp_tb.v` (ポート整合性更新)

## 完了条件

- Mesh Shader 完了時に、LDS からカリング通過三角形（3頂点座標および属性）が 1 サイクル/三角形の持続スループットで `mesh_tri` バスに出力されること。
- `python3 tools/arith-lint.py --top atg_su_exp` が 0 演算子逸脱を維持すること。
- 単体テストベンチが正常に PASS すること。

## 実装内容

1. **`atg_su_exp_mesh.v`（新規エクスポートシーケンサ）**:
   - Meshlet 規模（最大 64 頂点、126 プリミティブ）に対応。
   - `kick_valid` により起動し、LDS からプリミティブインデックス `{Flags[7:0], V2[7:0], V1[7:0], V0[7:0]}` を読み出し。
   - **高速ハードウェアカリングスキップ**: カリングフラグ（bit 7）が立っているプリミティブは頂点リードをスキップし、1 サイクルで破棄して次プリミティブへ進行。
   - **パイプラインバースト頂点リード**: カリング通過三角形の 3 頂点座標（XYZW: 128-bit × 3）および Varying 属性（96-bit × 3）を 21 サイクルで連続バーストリード。
   - **702-bit 三角形フォーマットアセンブリ**: `atg_rx_setup` の入力バス `cl_tri` と完全互換な 702-bit パッケージを生成。
   - **2段スキッドバッファ（Ping-Pong バッファ）**: RX 側が受け入れ可能（`mesh_ready == 1`）な場合は 1 サイクル/三角形のワイヤスピードで持続供給し、RX ビジー時（`mesh_ready == 0`）はデータを保持してバックプレッシャーを吸収。
2. **`atg_su_lds.v`（Port B 読み出しポート新設）**:
   - 既存の 4 KiB BRAM（RAMB36E1）の空きポート（Port B）を活用し、`mesh_rd_en`, `mesh_rd_addr`, `mesh_rd_data` を新設。追加の Block RAM 消費ゼロを達成。
3. **`atg_su_exp.v` & `atg_su.v` 配線**:
   - `atg_su_exp` に `u_mesh` を内蔵し、GSI1 命令 `exp`（target `0x200`）によるキック機構を実装。
   - `atg_su.v` トップに `mesh_valid`, `mesh_ready`, `mesh_tri`, `mesh_last`, `mesh_id` を露出。
4. **仕様書・テストベンチ**:
   - `spec/gpu/su/atg_su_exp.md` を更新。
   - `sim/tb/atg_su_exp_mesh_tb.v` を作成し、全テスト項目（トポロジ・頂点属性整合、カリングスキップ、バックプレッシャー耐性、0 プリミティブ境界）を検証。

## 検証結果

- `tools/arith-lint.py`:
  - `atg_su_exp_mesh`: `0 operators outside rtl/library/arith`（Clean）
  - `atg_su_exp`: `0 operators outside rtl/library/arith`（Clean）
  - `atg_su_lds`: `0 operators outside rtl/library/arith`（Clean）
  - `atg_su`: `0 operators outside rtl/library/arith`（Clean）
  - `atg_top`: `0 operators outside rtl/library/arith`（Clean）
- Verilator lint (`verilator --lint-only -Wall -Iinclude`):
  - `atg_su`: 警告 0（Clean）
  - `atg_top`: 警告 0（Clean）
- 単体テストベンチ:
  - `PASS atg_su_exp_mesh (0 s)`
  - `PASS atg_su_lds (1 s)`
  - `PASS atg_su_exp (3 s)`
