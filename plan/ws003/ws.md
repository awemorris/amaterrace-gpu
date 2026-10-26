<!-- awesome-plan project=amaterrace-gpu record=ws003 -->

# WS003 Vulkan 互換 API モジュール別 Capability 化 & config.mk ビルド設定

- Master: [plan/master.md](../master.md)（2026-10-27 新設、ユーザー指示および Vulkan 互換計画書に基づく）
- Primary Milestone: **MG006**（モジュール別 Capability & ビルド時一元設定）
- Guardrail: [plan/guardrail.md](../guardrail.md)、[docs/style.md](../../docs/style.md)
- Status: `completed`
- 出典・経緯:
  - 2026-10-27 ユーザー: 「Vulkan 1.0は適合しなくてもよく、MSAAなどをcapabilityビットでオプションにしていきたい。その理由は、現実的な価格のFPGAに入れられる機能が限られているから。Vulkan 1.0が定めている機能であっても、テクスチャの圧縮、イメージの形式、サンプリングの数など、すべてオプションのcapabilityにしたい。何をオプションにして、何をコアにできるか、検討して資料を作成してほしい。... SU laneの数は、Warpが論理32だが、実装は4,8,16,32から選べるようにする。これらのすべてのオプションをビルド時のオプションにしたい。config.mkでMakefileから読まれる設定にする。N=3で作業可能とします。」

## 概要

厳格な Vulkan 1.0 CTS 適合から「Vulkan 互換 API」への方針転換に伴い、各モジュールの機能を Baseline Core（必須）とオプション Capability に再編し、`config.mk` によるビルド時の一元管理メカニズムと GHCI レジスタへの動的マッピングを確立する。
（※ VK_EXT Task & Mesh Shader の実装は、将来の独立した Workstream WS004 として実施）

## Phase

| Phase | 内容 | 依存 | 状態 |
| --- | --- | --- | --- |
| [p001](phase001/phase.md) | ビルド設定基盤（`config.mk.template`, `config.mk`, Makefile 自動生成ルール, `include/atg_config.vh`, `make menuconfig`） | - | completed |
| [p002](phase002/phase.md) | SU 物理レーン（`NPHYS=4,8,16,32`）および演算オプション（FP16, Subgroup, SFU, LDS）のパラメータ/マクロ結合 | p001 | completed |
| [p003](phase003/phase.md) | RX（MSAA 有効/無効/サンプル数、Hi-Z Early-Z 着脱、Coarse Scan 着脱）の Capability 化 | p001 | completed |
| [p004](phase004/phase.md) | TU（テクスチャ圧縮 BC1-BC7 デコーダ着脱 `CONFIG_TU_ENABLE_BC`, トライリニア補間着脱, 3D/Cube 着脱）の Capability 化 | p001 | completed |
| [p005](phase005/phase.md) | ROP（Dual Source Blend 着脱, LogicOp 着脱, Fast Clear 着脱, MRT 数）の Capability 化 | p001 | completed |
| [p006](phase006/phase.md) | CP & GHCI レジスタ連携（`DEVICE_CAPS`, `CAPS`, `EXT_CAP_*` レジスタ連動、Task/Mesh Capability ビット定義） | p002, p003, p004, p005 | completed |
| [p007](phase007/phase.md) | プロファイル別プリセットビルド検証（Minimal, Balanced, High-Performance）および全体回帰テスト | p006 | completed |
