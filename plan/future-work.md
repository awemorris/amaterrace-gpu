<!-- awesome-plan project=amaterrace-gpu record=future-work -->

# Future Work Board

現時点のコミットメントには含まれないアイデアや、意図的に後回しとした作業の台帳。

| ID | 項目 | 目的・価値 | 起源・経緯 | 状態 | 再検討トリガー |
| :---: | :--- | :--- | :--- | :---: | :--- |
| **fw001** | `fw-kc705-hostmem` | VRAM を KC705 DDR3 からホストメモリへ移行（Unified Memory 化） | 2026-10-25 ユーザー指示「VRAMは最終的にはDDR3ではなくホストメモリにしたいですが、その実験のためには、Sukuna RISCを実装してKC705でCPU+GPUを動かす必要があります。」 | defer | Sukuna RISC CPU 実装完了後 |
| **fw002** | `fw-kc705-rpi5` | KC705 GPU を Raspberry Pi 5 の M.2（PCIe x1）からネイティブ利用 | 2026-10-26 ユーザー相談 | defer | PC Linux / VF2 実機 bring-up 完了後 |
| **fw003** | `fw-amaterrace-asic-flow` | 3nm ASIC フロー（商用 EDA または OpenROAD）と外部算術 IP（DesignWare, UNIMACRO 等）の検討 | 2026-10-26 ユーザー相談 | defer | ASIC ターゲット着手時 |
| **fw004** | `fw-amaterrace-linux` | Linux 7.3 DRM/KMS ドライバ（GPL/Zlib デュアル）および Mesa Vulkan パッチ | 2026-10-25 ユーザー指示 | defer | zedBSD 上での実機 Vulkan 安定動作後 |
| **fw005** | `fw-sa-core` | Systolic Array (SA) コア本体 `atg_sa` 実装（32×32 行列エンジン） | 2026-10-23 ユーザー指示「SAの設計と実装はかなり後に回して、SUがきちんとISAを実装できてからにします。」 | defer | SU による全 ISA 実装完了後 |
| **fw006** | `fw-sa-online` | SA 出口でのオンライン softmax / layer norm 集計・正規化回路 | 2026-10-23 ユーザー合意（案 B） | defer | `fw005` 実装後 |
| **fw007** | `fw-sa-vulkan` | Vulkan から SA を呼ぶ独自拡張 `VK_KEI_systolic_dispatch` | 2026-10-23 設計 | defer | `fw005` 実装後 |
| **fw008** | `fw-amaterrace-noc` | SU 間の NoC（Fat Tree による in-network reduction、LLM パッチ集約） | 2026-10-25 ユーザー指示「LLM対応するときには、SUごとにパッチを担当して、それをマージするためにやはりfat-treeなどのNoC的なトポロジは必要」 | defer | NSU が 4 を超える LLM スケーリング時 |
