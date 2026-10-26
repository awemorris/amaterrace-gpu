<!-- awesome-plan project=amaterrace-gpu record=bug-board -->

# Bug Board

Amaterrace GPU の既知の不具合および調査中事象の台帳。

| ID | 症状・事象 | 再現性 | 状態 | 起源・発見 Phase | 次のアクション・トリガー |
| :---: | :--- | :---: | :---: | :---: | :--- |
| **bug001** | 電源断直後のコールドブート時に稀に `CPFW_STATUS 9`（ファームウェア未起動）となる | unreproduced | tracking | 旧 ws288-p044（実機検証） | 再発時の JTAG レジスタダンプ収集。リセット再試行処理はドライバ側に実装済み。 |
| **bug002** | Xilinx AXI-PCIe IP が BAR を詰めるため `BAR2` が PCIe 空間に出ない | reproduced | tracking | 旧 ws288-p043（VF2 attach） | `ip.tcl` で BAR0 + BAR1 構成に修正予定。 |
