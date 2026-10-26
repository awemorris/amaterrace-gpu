<!-- awesome-plan project=amaterrace-gpu record=ws004 -->

# WS004 次世代ジオメトリ（VK_EXT_mesh_shader, VK_EXT_task_shader）SU support for task/mesh shader アーキテクチャ

- Master: [plan/master.md](../master.md)（2026-10-27 新設、ユーザー指示に基づく）
- Primary Milestone: **MG007**（Task / Mesh Shader 統合アーキテクチャ）
- Guardrail: [plan/guardrail.md](../guardrail.md)、[docs/style.md](../../docs/style.md)
- Status: `active`
- 出典・経緯:
  - 2026-10-27 ユーザー: 「task, mesh シェーダーについては、独立した回路よりも、シェーダー内蔵の機能がいいと思うので、まずは方式検討のphaseを作ってください。方式は私が議論の上で承認します。」

## 概要

従来の固定ジオメトリパイプライン（VF + Primitive Assembler）に独立した固定機能回路を追加するのではなく、Shader Unit（SU）のコンピュート/汎用実行リソース（LDS、Warp スケジューラ、スカラー PE）およびエクスポートバス（EXP）を内蔵統合して task shader および mesh shader（`VK_EXT_mesh_shader`, `VK_EXT_task_shader`）を直接実行する SU support for task/mesh shader 方式を策定・設計・実装する。

まずは Phase 001 にて方式検討（アーキテクチャ比較、LDS アロケーション、プリミティブ出力と RX 直結パス）を行い、ユーザーの議論・承認を経て詳細設計・実装へと進める。

## Phase

| Phase | 内容 | 依存 | 状態 |
| --- | --- | --- | --- |
| [p001](phase001/phase.md) | SU support for task/mesh shader（vk_ext_mesh_shader, vk_ext_task_shader）内蔵アーキテクチャ方式検討・比較資料作成 | - | completed |
| [p002](phase002/phase.md) | SU 内部 Meshlet プリミティブエクスポート（atg_su_exp_mesh）& LDS インターフェース設計・実装 | p001 | active |
| [p003](phase003/phase.md) | CP タスクディスパッチ & メッシュパイプライン統合・検証（承認後着手） | p002 | queued |
