<!-- awesome-plan project=amaterrace-gpu record=ws004-p003 -->

# Phase ws004-p003: CP タスクディスパッチ & メッシュパイプライン統合・検証

- Workstream: [WS004](../ws.md)
- Status: `completed`
- Depends on: ws004-p002

## 目的

`atg_su_exp_mesh` による Meshlet プリミティブエクスポート機構をラスタライザ（`atg_rx_setup`）および Command Processor（CP）のタスクディスパッチと統合し、`VK_EXT_mesh_shader` / `VK_EXT_task_shader` のエンドツーエンドなメッシュシェーディングパイプラインの動作を検証する。

## 変更対象ファイル

- `rtl/gpu/rx/atg_rx_setup.v`: Mesh ストリーム入力（`mesh_*`）と従来クリップ入力（`cl_*`）の静的 MUX（Option 4 Priority MUX）実装。
- `rtl/gpu/rx/atg_rx.v`: トップポートに `mesh_*` を追加し `setup` に配線。
- `rtl/gpu/rx/atg_rx_scan.v`: 未使用信号を `unused_ok` で吸収（Verilator -Wall 警告 0 維持）。
- `rtl/gpu/cp/atg_cp_ring.v`: GHCI 2.0 パケット（`CMD_DRAW_MESH_TASKS` 0x2A 等）のパケット長デコード追加（減算は `am_sub`）。
- `rtl/gpu/cp/atg_cp_seq.v`, `atg_cp_seq_dec.v`, `atg_cp_seq_wait.v`: `CMD_DRAW_MESH_TASKS` のディスパッチ、キャッシュ無効化、依存性管理。
- `rtl/gpu/su/atg_su_exp.v`, `atg_su_exp_mesh.v`: パラメータ `AW`（LDS アドレス幅）に応じた安全なゼロ拡張ガード実装。
- `rtl/gpu/su/atg_su_lds.v`: シミュレーション初期化時の 0 クリア追加（BRAM 不定値伝播防止）。
- `rtl/gpu/top/atg_top.v`: `atg_su` 0 の `mesh_*` 出力と `atg_rx` の `mesh_*` 入力を直結。
- `sim/tb/atg_top_mesh_tb.v`: エンドツーエンド統合テストベンチ（Mesh Shader 起動 $\rightarrow$ LDS 書き込み $\rightarrow$ `atg_su_exp_mesh` エクスポート $\rightarrow$ `atg_rx_setup` $\rightarrow$ `atg_rx_scan` $\rightarrow$ `atg_rop` $\rightarrow$ メモリ描画検証）。
- `sim/tb/atg_cp_mesh_tb.v`, `atg_rx_setup_tb.v`, `atg_rx_pipeline_tb.v`, `atg_rx_ext_prim_tb.v`: 単体テストベンチのポート更新および mesh stream テストケース追加。

## 完了条件

- [x] Mesh Shader からエクスポートされた三角形群がラスタライザ（RX）および ROP を経由してフレームバッファに正しく描画されること（`PASS atg_top_mesh` 確認）。
- [x] `tools/lint.sh`（Verilator -Wall）が警告 0 件で通過すること（`atg_top`, `atg_rx`, `atg_su_exp_mesh`, `atg_cp_ring` 等警告 0 件確認）。
- [x] `python3 tools/arith-lint.py` が 0 演算子逸脱を維持すること（0 operators outside `rtl/library/arith` 確認）。
- [x] 統合テストベンチが正常に PASS すること（全 8 テスト完全 PASS）。
