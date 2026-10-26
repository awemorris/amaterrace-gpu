<!-- awesome-plan project=amaterrace-gpu record=ws004-p003 -->

# Phase ws004-p003: CP タスクディスパッチ & メッシュパイプライン統合・検証

- Workstream: [WS004](../ws.md)
- Status: `queued`
- Depends on: ws004-p002

## 目的

`atg_su_exp_mesh` による Meshlet プリミティブエクスポート機構をラスタライザ（`atg_rx_setup`）および Command Processor（CP）のタスクディスパッチと統合し、`VK_EXT_mesh_shader` / `VK_EXT_task_shader` のエンドツーエンドなメッシュシェーディングパイプラインの動作を検証する。

## 変更対象ファイル

- `rtl/gpu/rx/atg_rx_setup.v` (Mesh ストリーム入力と VF 入力の排他 MUX 接続)
- `rtl/gpu/cp/` (Task / Mesh 起動パケットデコードおよびワークグループディスパッチ)
- `rtl/gpu/top/atg_top.v` (`atg_su` の `mesh_*` 出力と `atg_rx` の接続)
- `sim/tb/atg_top_mesh_tb.v` (メッシュパイプライン統合テストベンチ)

## 完了条件

- Mesh Shader からエクスポートされた三角形群がラスタライザ（RX）および ROP を経由してフレームバッファに正しく描画されること。
- `tools/lint.sh`（Verilator -Wall）が警告 0 件で通過すること。
- `python3 tools/arith-lint.py` が 0 演算子逸脱を維持すること。
- 統合テストベンチが正常に PASS すること。
