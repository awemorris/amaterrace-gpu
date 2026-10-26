<!-- awesome-plan project=amaterrace-gpu record=ws004-p001 -->

# Phase ws004-p001: SU support for task/mesh shader（vk_ext_mesh_shader, vk_ext_task_shader）内蔵アーキテクチャ方式検討

- Workstream: [WS004](../ws.md)
- Status: `completed`
- Depends on: None

## 目的

独立した専用固定ハードウェア回路を新設するのではなく、Shader Unit（SU）内部の既存リソース（Warp スケジューラ、スカラー PE、LDS、エクスポートバス）を最大限に活用して task shader および mesh shader（`VK_EXT_mesh_shader`, `VK_EXT_task_shader`）を実行する SU support for task/mesh shader 方式を検討・整理し、ユーザーレビュー・議論のための詳細資料を作成する。

## 検討テーマ

1. **独立専用パイプライン回路 vs シェーダ内蔵方式の比較**:
   - FPGA リソース消費（LUT / DSP / BRAM）、データ移動オーバーヘッド、パイプラインの柔軟性の観点からの定量・定性比較。
2. **Meshlet 出力バッファリングと LDS（Local Data Share）の活用**:
   - 頂点配列（Vertices: 最大 256）およびプリミティブインデックス配列（Primitives: 最大 512）を LDS 経由でどのように一時保持し、RX（ラスタライザ）へ直接ストリーム転送するか。
3. **Task -> Mesh 間ペイロードの受け渡し方式**:
   - Task Shader が生成する Mesh ワークグループ起動数およびユーザー定義ペイロードの転送メカニズム（LDS 経由 vs L2C スクラッチパッド経由）。
4. **RX（ラスタライザ）への直結エクスポートパス**:
   - 従来の頂点フェッチャ（VF）バイパス構造。SU のエクスポートユニット（`atg_su_exp_mesh`）から直接 RX セットアップエンジンへ三角形ストリームを供給するインターフェース設計。

## 完了条件

- ユーザーと議論し、採用方式についての明確な合意・承認を得ること。

## 決定事項（2026-10-27 ユーザー承認完了）

全主要論点について【推奨案】を採用することでユーザー合意・承認を完了：
1. **Meshlet 規模**: **64 頂点 / 126 三角形**（1 Warp 処理、LDS 2.5 KiB 収容、追加 BRAM ゼロ）。
2. **Task-to-Mesh ペイロード**: **L2C / 共有メモリスクラッチパッド**（スケーラブル、追加回路不要）。
3. **RX 直結エクスポート**: **LDS 自律バースト DMA エクスポート**（シェーダ完了後、atg_su_exp_mesh 内シーケンサが LDS から atg_rx_setup へ直接ストリーム転送）。
4. **レガシー VF 共存**: **RX 入力での静的排他 MUX**（既存パイプライン資産を 100% 維持）。
