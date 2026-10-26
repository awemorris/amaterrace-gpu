<!-- awesome-plan project=amaterrace-gpu record=ws004 -->

# WS004 次世代ジオメトリ（VK_EXT Task / Mesh Shader）シェーダ内蔵（NGG方式）アーキテクチャ

- Master: [plan/master.md](../master.md)（2026-10-27 新設、ユーザー指示に基づく）
- Primary Milestone: **MG007**（Task / Mesh Shader NGG 統合アーキテクチャ）
- Guardrail: [plan/guardrail.md](../guardrail.md)、[docs/style.md](../../docs/style.md)
- Status: `active`
- 出典・経緯:
  - 2026-10-27 ユーザー: 「task, mesh シェーダーについては、独立した回路よりも、AMD NGGのようなシェーダー内蔵の機能がいいと思うので、まずは方式検討のphaseを作ってください。方式は私が議論の上で承認します。」

## 概要

従来の固定ジオメトリパイプライン（VF + Primitive Assembler）に独立した固定機能回路を追加するのではなく、AMD NGG（Next-Generation Geometry）アプローチに倣い、Shader Unit（SU）のコンピュート/汎用実行リソース（LDS、Warp スケジューラ、スカラー PE）およびエクスポートバス（EXP）を内蔵統合して Task Shader および Mesh Shader（`VK_EXT_mesh_shader`）を直接実行する方式を策定・設計・実装する。

まずは Phase 001 にて方式検討（アーキテクチャ比較、LDS アロケーション、プリミティブ出力と RX 直結パス）を行い、ユーザーの議論・承認を経て詳細設計・実装へと進める。

## Phase

| Phase | 内容 | 依存 | 状態 |
| --- | --- | --- | --- |
| [p001](phase001/phase.md) | AMD NGG 方式に倣う Task / Mesh Shader シェーダ内蔵アーキテクチャ方式検討・比較資料作成 | - | completed |
| [p002](phase002/phase.md) | SU 内部 Meshlet プリミティブエクスポート & LDS インターフェース設計・実装 | p001 | active |
| [p003](phase003/phase.md) | CP タスクディスパッチ & メッシュパイプライン統合・検証（承認後着手） | p002 | queued |
