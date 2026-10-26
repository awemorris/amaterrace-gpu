<!-- awesome-plan project=amaterrace-gpu record=ws002 -->

# WS002 Vulkan 1.0 仕様適合性・グラフィックス機能補完

- Master: [plan/master.md](../master.md)（2026-10-26 新設、ユーザー指示および R1 敵対的アドバイスに基づく）
- Primary Milestone: **MG005**（Vulkan 1.0 完全適合）
- Guardrail: [plan/guardrail.md](../guardrail.md)、[docs/style.md](../../docs/style.md)
- Status: `planned`（コアパイプライン化完了後に着手するため後回し）
- 出典・経緯:
  - 2026-10-26 ユーザー: 「Vulkan 1.0の仕様に足りていないところはWSを立てて実装phaseにして、実装を後回しにします。Vulkanを満たすためでなく、そもそもの設計の問題のような、根本的なものや、高速化のために必要となるアドバイスがほしいです。」
  - 2026-10-26 R1 アドバイス書: ROP のコアパイプライン化と直交する機能拡張（Logic Op、Dual Source Blending、Independent Blend、MRT 8 アタッチメント等）を後回し WS として切り出し。

## 概要

Amaterrace GPU のハードウェアパイプライン化および物理最適化が完了した後に、Vulkan 1.0 仕様への完全適合を達成するために不足している描画機能・ROP 論理演算・マルチアタッチメント拡張等を段階的に実装する。

## Phase

| Phase | 内容 | 依存 | 状態 |
| --- | --- | --- | --- |
| [p001](phase001/phase.md) | ROP Logic Op（論理演算 16 種）& Independent Blend per RT（RT 個別ブレンド） | ws001-p014 | planned |
| [p002](phase002/phase.md) | SU / ROP Dual Source Blending（フォント描画用 src1 カラー出力） | ws001-p010, p001 | planned |
| [p003](phase003/phase.md) | MRT 8 アタッチメント拡張（CAPS[30] 4 -> 8 拡張 & ディスクリプタ対応） | p001 | planned |
| [p004](phase004/phase.md) | TU 異方性フィルタリング（Anisotropic Filtering 最大 16x EWA ループ） | ws001-p021 | planned |
| [p005](phase005/phase.md) | TU シームレスキューブマップフィルタリング（面境界テクセル補間） | ws001-p018 | planned |
| [p006](phase006/phase.md) | TU デスクトップ標準圧縮テクスチャ（BC1〜BC7 ハードウェアデコーダ） | ws001-p020 | planned |
| [p007](phase007/phase.md) | RX 拡張プリミティブ（Wide Lines, Point Sprites, Multi-Viewport 等） | ws001-p025 | planned |
| [p008](phase008/phase.md) | 間接描画 & インスタンシング（MultiDrawIndirect, Vertex Attribute Divisor） | ws001-p033 | planned |
| [p009](phase009/phase.md) | 非同期 DMA 転送キュー & 3D ボリュームコピー（専用キュー・ボリューム画像） | ws001-p030 | planned |
| [p010](phase010/phase.md) | WSI 高度表示機能（HDR10、マルチプレーンオーバーレイ、VRR） | ws001-p039 | planned |
