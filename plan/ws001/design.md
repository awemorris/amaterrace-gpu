<!-- awesome-plan project=amaterrace-gpu record=ws001-p001-design -->

# WS001 の設計: FPGA の GPU の IP「Amaterrace GPU」と GHCI — ZYBO（XC7Z010）で workflow、本命は KC705（XC7K325T）

2026-10-23 P2（ws001-p001、worktree p2-ws288-p001、基点 main c327d0c73）。親: [WS001](ws.md)。**版 9**（2026-10-25 P2、ws001-p025 の設計の段、zedBSD の worktree p2-p025、基点 main 05cfe206c、amaterrace-gpu は main e64da02 を読んだだけ: **§19 timing**（目標の Fmax、clock の領域、pipeline の方針、面積の見通し）を新設: p036・p038・p024 の測定の経路の棚卸し、KC705 の案 K1〜K4 と推し K2（SU を独立の sclk 200 MHz、他は gclk 100 MHz）、ASIC（3 nm、1.0〜1.5 GHz）の見込みを 2 つの推定の方法で、sclk ↔ gclk の境の 14 の channel と `am_cdc_*`・`am_rst_cdc`、XDC の gray の pointer の制約、SU の `SHORT_LAT` 6 → 約 11〜12 と bus の使用率の見積もり、経路の種類ごとの段の入れ方、p032 への論点、面積の見込み（板で約 216k〜223k、K2 の目安 LUT ≤ 85%）、実装の段 T0〜T5 と 72 LW（CDC の T1 は別の Phase の推し）、U100〜U109、design-reviewer の 24 件の対応は §19.15）。**版 8**（2026-10-25 P3、ws001-p035 の設計の段、zedBSD の worktree p3-p006、amaterrace-gpu の worktree p3-p035（aa78b64 の上）: **§18 DC を GHCI の GPU の一部に**を新設: DC を `rtl/gpu/dc/` の atg_top の子に（board の reset の domain）、新しい capability DISP2、scanout の register は CP の RUNNING の間は ring の µop（新しい 15 DISP_SET・16 FLIP）だけが書き host は IDLE・HALTED・FAULTED だけ（RUNNING の write は捨てて BAD_WRITE）、present = FLIP（plane ごとの待ちの slot、取り込みで `atg_cp_disp` の record の書き手が `{value, FRAME_COUNT}` を書き IRQ_STATUS.FLIP）、DC は「全部の unit」に入らない、scanout の誤りは device の fault にしない、event は IRQ_STATUS [12:9]、mode の表、cursor の plane（gclk で合成）、image の条件と SHARED・COPY の route、ADV7511 と HPD は host の driver のまま、driver の UNGATED・queue・scan の hold・recover の数え直し、GHCI §13.2 の案、試験、段 D1〜D8 と 51 LW、U90〜U99、review 2 回（28 件・21 件）の対応は §18.15・§18.16）。**版 7**（2026-10-25 P1、ws001-p034 の設計の段、worktree p1-p030、基点 main 485108a30: **§17 session の保護**（GHCI §11.6、PROT）を新設: granule ごとの所有の表と MC の root の PLB・grant の CAM、AMB の header の chk・slot、unit は 1 度に 1 つの session（drain・invalidate・scrub）、firmware の µop と DMA の検査、heap の private と可視の区分、driver の方針、GHCI の draft、model・TB、段 R1〜R8 と 54 LW、U61〜U72、review 2 回（33 件・21 件）の対応。review は [design-review-p034.md](design-review-p034.md)）。**版 6**（2026-10-25 P1、ws001-p030 の設計の段、worktree p1-p030、基点 main 32b51bf34: **§16 Vulkan 1.0 core の残り**を新設（limit・feature・必須の format の表、format の共通の土台と FMT capability、ROP の stencil・D16・depth bounds・depth の clip/clamp/bias・MRT 4 の beat・f32 の blend・occlusion の counter、RX の point・line・viewport の矩形・guard band の clip・depth bias、VF の format と robust の limit、TU の format と swizzle と f32 の filter、BLT の KEEP、µop 14 QUERY、GHCI の draft、model・TB・scene、段 S1〜S11 と 79 LW（ETC2 は後の Phase）、U47〜U60、review 2 回（35 件・23 件）の対応）。§8 に p030 の行を足した。review は [design-review-p030.md](design-review-p030.md)）。**版 5**（2026-10-25 P2、ws001-p027 の設計の段、worktree p2-p027、基点 main bb8e0f161: **§15 MSAA** を新設（Vulkan 1.0 core の multisample の要求の表、RX の sample の coverage、fragment の入力 r6〜r9、SU の exp 0x105、ROP の `atg_rop_ms`、sample-interleaved の配置、resolve の内蔵の draw、TU の `texf` の sample、GHCI の draft、model・TB・scene、段と LW、U43〜U46）。§3.7 と §8 に p027 の行を足した。review は [design-review-msaa.md](design-review-msaa.md)）。**版 4**（同日 P1、worktree p1-ws001-d4、基点 main b9284693c → main c10f7ea78 を merge: ユーザーの版 4 の決定の列（FP16/INT8 の mixed precision → online の softmax/LN → SIMD-8 の取り下げ → 案 B（SA に寄せ SU は最小）→ **SA の設計と実装は延期、SU が GSI1 を実装してから。SA は KC705 に入らなくてよい**）の最後の形: §3.9 は SU ↔ SA の大まかな整合（`rq` = r63 の予約、entry = SA の vector、decoupled な SA、案 B の構成、KC705 は raster/compute 構成だけ）の 5 点だけに縮め、詳細の sketch は Appendix A（延期）に移した。GSI1 は版 3 の最小の形（packed の超越は無し）。p020〜p022 は Future Work（trigger: p008〜p010 cleared）。§7.6 の RTL の進め方（top-down の分割・空の module・spec）と p023 を新設、p003 の実測と reserved-memory を反映、U39 は閉じた。design-reviewer の v4 の指摘（High 7・Medium 15・Low 11）と対応は §14。review 1 の README（a217bf8）との食い違いは U39）。**版 3**（同日 P1、worktree p1-ws288-d3、基点 main 01f261168: ユーザーの 4 つの決定（§2.1 の冒頭）に合わせて §2.4（ring の command = Kei GPU command protocol の gpu-op、CP は RISC-V 風の `atg_cpu` の firmware が解く）と §3（GHCI の標準の shader ISA「GSI1」、RISC-V の 32 bit の形を低位に持つ 64 bit 固定、小さな hardware の scoreboard）を書き直し、§6.6・§6.7・§6.9・§8（p017〜p019 の新設、392 LW）・§3.9（systolic array と ISA の FIFO の register `rq`、同日のユーザーの要件）・§6.10・§9（R23〜R30、U18〜U30）・§10（21〜30）・§11・§13 を足した。版 2 の節の番号は保った。design-reviewer の指摘（Critical 2・High 10・Medium 22・Low 15）と対応は §13（末尾）。**版 2**（同日: design-reviewer の指摘 38 件（Critical 3・High 15・Medium 14・Low 6）の全部に対応。対応の表は §12。版 1 からの主な変更: detach と reset の順序（§1.3・§6.2）、FENCE の意味（§2.4）、drv_gpu の capability と jobs と capset（§6.4）、window と IRQ の devcfg の事実への修正（§5.1・§6.2）、CP の状態遷移と ring の約束（§2.6・§2.7）、fault は v1 は device 全体（§2.5）、統一 shader の deadlock と ROP の順序（§3.8）、cache の無効化（§2.4 `INVALIDATE`）、見積もりの計算し直しと **7010 では block を分けた bitstream で確かめる**方針（§3.6・R1）、GHCI の標準と vendor の境（§2.1）、KC705 は 1 device（§6.5）、Phase の循環の解消（§8）。）
この Phase は設計だけで、RTL も C も書かない。RTL の置き場所は https://github.com/awemorris/amaterrace-gpu （この Phase では書かない。clone `/home/awe/amaterrace-gpu` は commit 1791b32「Initial」= ユーザーの `README.md` だけ）、計画はこの zedBSD の `plan/ws001/`（2026-10-23 ユーザー「planはこのままzedBSDを使いましょう。」）。FPGA の CPU は https://github.com/awemorris/sukuna-risc.git （2026-10-23 ユーザー「mc64をsukuna-riscに改名しました。」）。

**ユーザーの仕様（amaterrace-gpu の README.md、1791b32 → 版 4 の時点では a217bf8: 「LLM: CP --> VF --> SU --> SA --> SU --> SA -> ... --> SU --> ROP -> MC」「Systolic Array: 32 x 32, 0.8 TOPS/SU @200MHz」が足された。SA の節との整合は U39、2026-10-23「概略を書きました。書き足してOKです。」）が上位**。この設計はそれに従う: block の名前と略号 **GHCI**（この project が提案する、Vulkan 互換の GPU のための標準の HCI）、**DC**（Display Controller）、**CP**（Command Processor）、**BLT**（Blitter）、**VF**（Vertex Fetcher）、**RX**（Rasterizer）、**SU**（Shader Unit）、**TU**（Texture Unit）、**ROP**（Buffer Writer）、**MC**（Memory Controller）。全体は `CPU -- (AXI4) -- CP`、fill/copy は `CP → BLT → MC`、primitive は `CP → VF → SU → RX → SU → ROP → MC`（TU は 2 段目の SU から）。shader は「Warp: 32-lane scalar with 16-bit packed」、register file は未定（「xxx」→ §3.5 と U12 で提案、[proposed/README-additions.md](proposed/README-additions.md) に README への書き足しの案）。

**到達目標**: 上の block を、ZYBO で小さな端から端までの道（CP + BLT の fill/copy を `fpgareg` で動かし、次に DC）から積み上げ、KC705 で SU を複数並べて zedBSD の Vulkan（libvulkan → kernel の executor）から使えるようにする。zedBSD の側の driver は **GHCI の汎用の driver**（Amaterrace に固有なのは shader の ISA の backend だけ）。

## 0. 出典と確認の水準

読んだ物（この checkout、main c327d0c73）:

- zedBSD の GPU の枠組み: `include/drivers/gpu/gpu.h`（`drv_gpu_ops`、interface 版 9、optional の表の契約）、`src/drivers/gpu/gpu.c`（版 2 で読んだ: 669〜686 行 = `/dev/gpuN` は **空いている最小の番号**、1024〜1045 行 = `GPU_CAP_JOB` は `GPU_CAP_NOTIFICATION` と `jobs` の reserve/commit/cancel が揃わないと `EINVAL`、`NOTIFICATION` は `commands` の submit/drain が要る、775〜830 行 = `drv_gpu_unregister` は **`online = 0`・`recovery->fault(ENODEV)`・`report_error(ENODEV)`・node の削除まで済ませてから** session が残れば `EBUSY` を返す）、`gpu-display.h`・`gpu-share.h`・`gpu-scanout.h`（`import_image`・`query_device`・`constraints`、「同じ device の scanout は普通の share の import で足りる」）、`include/uapi/gpu.h`・`gpu-op.h`・`gpu-job.h`・`gpu-fence.h`。
- libvulkan（版 2 で読んだ）: `context.c` 124 行（`CAPSET|BLOB|TRANSFER|COMMAND|MAPPING` が必須）、142〜170 行（capset id 4、≥ 156 byte、wire 1、XML の版、timelines ≠ 0）、172〜200 行（160 byte の vendor の magic と flag: `OPAQUE|STRICT_QUEUE|QUIESCE`）、`instance.c` 732〜734 行・`device.c` 279〜281 行（`strict_queue`・`native_quiescence`・`GPU_CAP_JOB|JOB_CAPACITY` が無いと device を作らない）。native の driver の capset の作り方は `src/drivers/gpu/powervr/render-runtime.c` の `runtime_capset`（175 行）。
- 既存の driver の形: `src/drivers/gpu/bcm2711/`（`vk/` 26k 行、`compiler/` 11k、`display/` 13k = display だけの別の drv_gpu device、static で kernel の寿命）、`powervr/`（`vk/` 9k、`compiler/` 14k）、`nvrtx/`（PCI の attach）、`venus/`（8k）、共有の `src/drivers/gpu/compiler/ir.h`（scalar の SSA、if-converted、Boolean は 32 bit の all-ones/zero。op の一覧は §6.6 の表）。
- kernel の API（版 2）: `include/kern/pmem.h`（`kern_pmem_alloc_limited`（連続の run。「末尾」は保証しない）、`kern_pmem_map_uncached(run)`、`kern_device_map`）、`include/kern/irq.h`（`kern_irq_register`・`kern_irq_register_msi`）。driver は `hal_*` を直接呼ばない。
- WS286 の板の事実と driver: [plan/ws286/design.md](../ws286/design.md) §1.1、§3.11〜§3.12（PS の DMA は CPU の cache と coherent でない、L2 off）、§5.6・§5.10。`include/uapi/fpga.h`、`src/drivers/platform/zybo/zynq-devcfg.c`（版 2 で確かめた: `WINDOW_PHYS 0x43c00000`・`WINDOW_BYTES 0x10000`・`PL_IRQ 61` は **固定**、`fpga.window=` の boot parameter は無い、attach の時から IRQ 61 の handler を持つ（284 行））、`platform/armv7/zybo/pl/plio/plio.v`・`plio.xdc`。
- KC705 の workflow: [phase001-kc705-bringup.md](phase001-kc705-bringup.md)、`platform/fpga/kc705/bringup/bringup.v`、`plan/tools/kc705/vivado-build.tcl`。
- Vivado 2026.1 の board store（KC705 1.7）: DDR3（MIG の preset `mig.prj`: 64 bit、800 MHz = 1250 ps、PHY 4:1、ui_clk 200 MHz）、PCIe x1〜x8、sys_diff_clock 200 MHz、LED・button・DIP・UART・IIC・flash（linear/SPI）。**HDMI は board file に無い**（UG810 未読、未確認）。
- 部品の規模（Vivado の `get_parts`、実測）: xc7z010clg400-1 LUT 17,600・FF 35,200・BRAM36 60・DSP48E1 80、speed -1。xc7k325tffg900-2 LUT 203,800・FF 407,600・BRAM36 445・DSP 840・GTX 16、speed -2。
- host の道具（実測）: iverilog 12.0、Vivado 2026.1（`xsim` 有り）、openFPGALoader 0.13.1、openocd 0.12.0、openXC7。**無い物**: verilator、cocotb。
- 版 3 で読んだ物（main 01f261168）: `include/uapi/gpu-op.h` の全部（2016 行: 冒頭の wire の規則 56〜122 行、1 submission の枠 93〜104 行、各 command の引数と「Sent by / Decoded by」、記録 93〜136 の形 1267〜1281 行、178〜180 の transport、zedBSD 固有の 0x10000〜の video）、`include/uapi/gpu.h`（`gpu_command_submit`・`gpu_command`・capability）、`include/uapi/gpu-job.h`（reserve/commit/cancel/capacity）、`src/drivers/gpu/powervr/vk/vk-stream.c`（frame の実行、route の表、reply の選択と trailer の release store、`EXECUTE_STREAMS` の入れ子）、`src/drivers/gpu/powervr/render-runtime.c`（`runtime_command` は frame をその場で実行、jobs の ops）、`src/drivers/gpu/compiler/ir.h`（op の一覧 263〜633 行、atomic・fence・texture の種類）、`src/drivers/gpu/i915/render/internal.h`（`i915_wire_reader` を powervr が再利用している）、amaterrace-gpu の p002 の途中（commit 06edac2 + 未 commit の `include/ghci_regs.h`・`ghci_packets.h`（placeholder）・`rtl/gpu/cp/atg_cp.v`（stub、ring 無し）・`atg_blt.v`・`atg_mc.v`・`atg_top.v`、合計 2162 行）、sukuna-risc の README（RV64GC、2-issue、2-SMT、約 22,000 LUT、KC705 で 200 MHz が目標。RTL は未 commit）、共有の LLVM の `clang --print-targets`（riscv32 が有る、実測）。

確認の水準の印: 「実測」= この checkout か host で確かめた。「推定」= 経験則の見積もりで、p002 以降の Vivado の `report_utilization` で置き換える。「未確認」= 文書を読めていない（UG810、UG585 の HP port の細部、DS187、AMD の IP の EULA、XDMA の細部）。

## 1. 全体の構成と clock・reset

### 1.1 block と流れ（README の図に従う）

```
   CPU -- (AXI4) -- CP                      ※ ZYBO の GP0 は AXI3。boards/zybo の wrapper が単発の AXI4-Lite に直す

   Fill/Copy:   CP --> BLT --> MC
   Primitive:   CP --> VF --> SU --> RX --> SU --> ROP --> MC
                                              |
                                              +--> TU --> MC
   Compute:     CP --> SU --> MC
   Systolic:    SU <-(FIFO rq)-> SA <-- MC（重みの stream。KC705 だけ、optional）
   Display:     DC --> MC（KC705）/ 自分の AXI（ZYBO の HP1）

   +------------------------------------------------------------------+
   | atg_top（GPU の IP）                                                |
   |  atg_cp   GHCI の register、ring、µop の sequencer、state、fence、IRQ、DBG |
   |  atg_cpu  CP の制御 processor（RV32IM、firmware が Vulkan の command を解く） |
   |  atg_blt  2D の fill / copy / tile                                 |
   |  atg_vf   index と頂点の読み、primitive の組み立て                  |
   |  atg_su[N] shader unit（vertex も fragment も compute もここ）      |
   |  atg_rx   clip・viewport・edge function・quad の走査               |
   |  atg_tu   sampler と texture cache                                 |
   |  atg_rop  depth・stencil・blend・書き戻し（Buffer Writer）           |
   |  atg_sa   systolic array（SU と decoupled、FIFO で SU の rq に、重みは MC から。optional、§3.9） |
   |  atg_mc   内部の memory bus（AMB）の arbiter、aperture、AXI master  |
   +------------------------------------------------------------------+
   +------------------------------------------------------------------+
   | atg_dc（DC の IP、別の top。7010 では GPU と同時に載せない）         |
   +------------------------------------------------------------------+
```

- GPU（`atg_top`）と DC（`atg_dc`）は別の IP、別の top。7010 には同時に載せなくてよい（2026-10-23 ユーザー）。ZYBO では別々の bitstream（§8）。KC705 では 1 つの bitstream に両方を載せ、MC の口を共有し（§4.2）、zedBSD からは **1 つの GHCI の device**（display の ops 付き、§6.5）に見える。
- block の間の内部の memory の口は 1 つの自前の bus「AMB」（§4.1）。外の AXI は MC の `am_axi_master` 1 つだけが話す。block は AXI を知らない。
- primitive の流れで SU は 2 回通る（頂点の warp と fragment の warp）。同じ SU が両方を走らせ、RX は頂点の出力を post-transform の buffer（PT）から取って fragment の warp を作る（deadlock の回避は §3.8）。TU は fragment の warp（と compute）から使う。
- CP は 2 つの部分（版 3、§2.4.7）: `atg_cp`（hardware: HCR、ring の DMA、class N の µop の sequencer、fence、IRQ、fault、DBG）と `atg_cpu`（RV32IM の小さな制御 processor。firmware が ring の class V の packet = Vulkan の command を解いて µop を `atg_cp` に渡す）。firmware の無い構成（ZYBO の bitstream 1・3・4）では `atg_cp` だけで class N を実行する。
- 性能の counter と debug の register は小さく（§2.2）。DBG の ADDR/DATA で CPU が AMB を通して DDR を読み書きできるので、**最初の milestone は kernel の driver 無しに `fpgareg` だけで BLT の結果を確かめられる**（§8 p003）。
- **7010 では全 block が 1 つの bitstream に入らない見込み**（§3.6）。ZYBO は block を分けた bitstream（CP+BLT、DC、CP+RX+ROP、CP+SU の compute）で workflow と各 block を確かめ、全体の結合は Verilator と KC705 で確かめる（R1・U17）。

### 1.2 名前と parameter

- RTL の module の接頭辞: `atg_`（Amaterrace GPU の block: `atg_cp`・`atg_blt`・`atg_vf`・`atg_su`・`atg_rx`・`atg_tu`・`atg_rop`・`atg_mc`・`atg_dc`）、共通の部品は `am_`（`am_afifo`、`am_sync`、`am_axi_master`、`am_axi_regs`、`am_jtag_regs`）。
- GHCI の ID（§2.2）: magic `"GHCI"`、vendor `"AMAT"`（Amaterrace）、device `"ATG1"`（この GPU の 1 代目）、ISA `"GSI1"`（GHCI Shader ISA 1 = 標準の ISA、§3。Amaterrace の native も GSI1）。
- 主な parameter（top で与える。board ごとの値は §3.7 の表）: `NSU`（SU の数）、`NPHYS`（SU の物理の lane の数: 8/16/32。**warp は常に 32 lane**（README）で、`32/NPHYS` cycle で 1 命令を流す、§3.1）、`NWARPS`（常駐の warp の数）、`NREGS`（thread ごとの register の数、U12）、`LINE_BYTES`（AMB の line: 32 か 64）、`AMB_W`（AMB の beat の幅、64〜512）、`AXI3`（1 で AXI3 の master）、`TU_BILINEAR`、`ROP_STENCIL`、`PACKED`（16 bit packed の演算器）、`SUBGROUP`（`shfl`/`vote`/`ballot`）、`SA_COLS`（systolic array の列。0 = 無し、§3.9）、`SA_DTYPE`、`SA_FIFO_DEPTH`、`SB_ENTRIES`、`ADDR_W` = 32。

### 1.3 clock・reset・quiesce

| 領域 | ZYBO | KC705 | 中身 |
| --- | --- | --- | --- |
| `gclk`（GPU の core、register、AMB の client 側） | FCLK_CLK0 = 100 MHz（plio と同じ。`ps7_init` の DIV0 = 10、WS286 §1.2） | SYSCLK 200 MHz → MMCME2 → 100 MHz（最初は ZYBO と同じ値で timing の目標を 1 つにする。閉じたら 150 MHz を試す、§9 R3） | CP・BLT・VF・RX・SU・TU・ROP・MC の arbiter |
| `mclk`（AXI の master 側） | = `gclk`（HP0 の `S_AXI_HP0_ACLK` に FCLK_CLK0 を返す。同期なので CDC 無し） | MIG の `ui_clk` = 200 MHz | `am_axi_master` と AMB の master 側の FIFO。`gclk` ≠ `mclk` の時は `am_afifo`（gray の pointer の非同期 FIFO、自前）で要求と応答を渡す |
| `pclk`（pixel） | FCLK_CLK0 → MMCME2 → 25.2 MHz（640×480。100 MHz から 25.175 ちょうどは作れない: 25.2 は VGA の許容の中（0.1%）、**実機の monitor で確かめる**）/ 74.25 MHz（720p） | SYSCLK → MMCME2 → 同上 | DC の timing generator と出力。v1 は **2 mode だけ**（1 つの MMCM の 4 出力: 25.2・126・74.25・371.25。BUFGMUX で対を切り替え。800×600・1024×768 は後に DRP の再設定で足す、§5.1） |
| `pclk5`（TMDS の serial） | pclk × 5（OSERDESE2 の DDR で 10 bit/pixel） | KC705 の HDMI は ADV7511 の parallel（§5.3、未確認）なので無し | DC の TMDS の出力だけ |
| `hclk`（host link） | 無し | PCIe の `user_clk`（Gen2 x4 で 125 MHz の見込み。§4.3 で決める） | PCIe の bridge の AXI 側。register は `am_afifo` 経由で `gclk` へ、DMA は AMB の master 側へ |
| `tck` | JTAG | JTAG | KC705 の debug の bridge（§4.4）。`am_sync` の 2 段の同期で `gclk` へ |

- reset は領域ごとに **同期・active low**（`rst_n`）。入口は ZYBO が `FCLK_RESET0_N`（devcfg の `FPGA_ENABLE` が `FPGA_RST_CTRL` を解除すると **上がる**、WS286 §5.6）、KC705 が `!mmcm_locked | mig_ui_clk_sync_rst | cpu_reset` の OR の反転。各領域の reset の解除は `am_sync` で同期する。
- **reset の領域は 3 つ**: (a) GPU の core（CP の制御、BLT、VF、RX、SU、TU、ROP）、(b) MC と `am_axi_master`（AXI の outstanding を持つ）、(c) DC。`CTRL.RESET`（§2.2）は **(a) だけ**を reset し、(b) と (c) には触らない。MC は core の reset の後に「GPU の client の待ち行列を捨てる」`flush` を受ける（応答待ちの transaction は応答が来るまで保つ）。DC は自分の `CTRL.RESET` を持つ。
- **quiesce（AXI を静める）の定義**: `CTRL.HALT`（§2.6）→ MC が GPU の client からの **新しい AR/AW の発行を止め**、発行済みの W の beat を出し切り、全部の B/R の応答を待つ。応答は AXI の約束で必ず返るので有限（返らない AXI は壊れた system で、`WDT_CYCLES` の 4 倍を待って `STATUS.AXI_STUCK` を立てる。その時 hardware は何もできず、driver は PL の書き直し（ZYBO）か PCIe の reset（KC705）に上げる）。`STATUS.AXI_IDLE` は **GPU の client の分だけ**を数える（KC705 の DC は常に読んでいるので含めない）。
- **`CTRL.RESET` の順序は hardware が守る**: `RESET` を書くと CP は `HALT` → quiesce → `AXI_IDLE` を待ってから (a) を 1 cycle reset し、MC を flush し、`RESET` の bit を落とす。watchdog（§2.5）が切れた時も同じ順（FAULT を立て、HALT し、quiesce を待ってから driver の `RESET` を待つ。**hardware は自分では reset しない**）。AXI の途中で reset する道は無い。

## 2. GHCI（GPU Host Controller Interface）: CP の register、command、fence、割り込み、状態遷移、ring

### 2.1 GHCI が決める物と決めない物（AHCI・xHCI の類推）

- **2026-10-23 ユーザーの決定（command と ISA、版 3 で §2.4・§3 を書き直す）**:「コマンドは、現在のカーネルのコマンド（Venus由来）を使いましょう。ISAはRISC-Vベースでカスタムしましょう。RISC-V仕様に則る必要はないです。ベースにしつつ、他のGPUの平均を取って、実装しやすくよく使われるものを、我々の命令形式にフィットさせて取り込んでいきましょう。」
  - command: GHCI の ring の command は、zedBSD の kernel の今の command（`include/uapi/gpu-op.h` の Kei GPU command protocol 版 1、番号は Venus の wire format 1 と同じ。zedBSD だけの物は `GPU_OP_OWN_FIRST` から）を使う。版 2 の独自の opcode（§2.4）は置き換える。CP がこの Vulkan の command の流れを解く（firmware か hardware かは版 3 で決める）。
  - ISA: RISC-V を基にした独自の shader の ISA（GHCI の標準の ISA）。RISC-V の仕様に従う必要は無い。他の GPU（NVIDIA・AMD・Intel・Arm・PowerVR など）で共通によく使われ、実装しやすい物を、我々の命令の形式に合わせて取り込む。版 2 の "ATS1"（64 bit の固定長）は置き換える。

- **2026-10-23 ユーザーの決定（版 2 の「shader の ISA は決めない」を改める）**:「GHCIは標準のシェーダーISAを定義し、ベンダ独自のシェーダISAはオプションで利用可能。標準ISAの実装は、このGPUではハードウェアでそのまま実装されるが、コマンドプロセッサがJITコンパイルしてネイティブISAに変換してもOK。」
  - GHCI は **標準の shader の ISA**（命令・符号化・binary の形・実行の model のうち driver から見える所）を決める。GHCI の GPU は全部この標準の ISA の program を受ける。
  - vendor 独自の ISA は **任意**。`ISA_ID` などで標準の ISA に加えて持てる（driver は使ってもよい）。
  - 2026-10-23 ユーザー（続けて）「ネイティブISAを直接送信も可能。」→ driver は標準の ISA の代わりに、その GPU の native（vendor）の ISA の program を直接送ってもよい（CP の JIT を通らない）。program ごとにどちらの ISA かを示す（`LOAD_PROGRAM` の flag か ISA の ID、p002 の ghci.md で決める）。
  - 標準の ISA の実装の仕方は自由: **Amaterrace は hardware がそのまま実行する**（native = 標準）。他の実装は **CP が受け取った標準の ISA を JIT して自分の native の ISA に変えてよい**（driver からは見えない）。
  - これで汎用の driver（zedBSD の `src/drivers/gpu/ghci/`）は ISA の backend を 1 つ（標準の ISA）持てば、どの GHCI の GPU でも shader まで動かせる。版 3 で決めた: 標準の ISA は §3 の **GSI1**（RISC-V を基にした 64 bit 固定）、Amaterrace の native = GSI1、driver の backend は `isa/gsi1/`（§6.6）。command の側は §2.4（ring の class V = gpu-op、CP の firmware が解く）。

- **決める（公開・版付き・vendor に依らない。amaterrace-gpu の `docs/ghci.md` が正本、GHCI 1.0）**: (a) Host Control Register（HCR）の配置と意味（§2.2）、(b) extended capability の list（DC・debug・vendor の register の見つけ方）、(c) command ring と packet の封筒、class V（Vulkan の command = Kei GPU command protocol の gpu-op）の意味と GHCI 固有の command（session・memory・program・native）、class N の標準の µop（§2.4）、(c') 標準の shader ISA「GSI1」と program の binary の形、native の ISA の送り方（§3）、(d) state register file のうち **Vulkan の固定機能に当たる標準の領域**（§2.3）、(e) fence・割り込み・fault・watchdog・aperture・quiesce・reset の約束（§2.5〜§2.7）、(f) memory の model（32 bit の GPU address、aperture、将来の MMU の capability）、(g) CP の状態遷移（§2.6）と ring の約束（§2.7）。
- **決めない（vendor、`VENDOR`・`DEVICE`・`ISA` の ID で識別）**: vendor の native の ISA（`NATIVE_ISA_ID`、任意。GSI1 の上位集合でも別物でもよい）、CP の firmware の中身（GHCI は class V の意味だけを決める）、**実装の都合**（NPHYS、NWARPS、NREGS、cache の大きさ、SB_ENTRIES、`PACKED`・subgroup の有無 = `VEND` の register と `CAPS` の bit。GSI1 の program は `nregs` などを header に持ち、firmware が実装に合うかを検査する、§3.4.4）、texture の tile の並び（capability で「linear だけ」「4×4 tile」を名乗る）、vendor の µop（class 1 の 0〜63、§2.4.2）、vendor の state（0x1E0〜0x1FF）、vendor の register（extended capability `VEND`。Amaterrace は NWARPS・NREGS・NPHYS・PACKED をここに置き、ISA の backend が読む）。
- 汎用の driver（zedBSD の `src/drivers/gpu/ghci/`、§6）は HCR・ring・fence・割り込み・memory・標準の state・標準の opcode・DC の capability を扱い、**ISA の ID で compiler の backend を選ぶ**（標準の "GSI1" は必ず持つ。`NATIVE_ISA_ID` の backend は任意）。shader の無い GPU（`ISA_ID` = 0）と firmware の無い構成（`CAPS[17]` = 0）は BLT と DC だけで attach する（display + 2D の device として使える。Vulkan は出さない）。**「汎用」の意味（版 3）**: host interface・BLT・DC・Vulkan の中継（`vk/`）・GSI1 の backend の全部が汎用で、Amaterrace に固有の driver の code は無い。vendor の違いは firmware と `VEND` の register に閉じる（README-additions の文もこの形）。
- 版: HCR の `GHCI_VERSION` の major が変わる時だけ互換を壊す。minor の追加は末尾の register と新しい capability と opcode だけ。zedBSD の driver は major 1 だけを受ける。R19: v1 は Amaterrace が実装する物だけを標準に書く。

### 2.2 Host Control Register（HCR、64 KiB の窓の中の offset、32 bit、little endian）

窓: ZYBO の GPU の bitstream は GP0 `0x43C00000`（devcfg の固定の窓、64 KiB、IRQ_F2P[0] = GIC 61）、ZYBO の DC だけの bitstream も **同じ窓の offset 0**（DC だけの GHCI、§5.1）と IRQ_F2P[0]。KC705 は PCIe の BAR0（**128 KiB**: +0x00000 HCR、+0x10000 DC の register）と JTAG。slave は **17 bit** を解き、範囲の外は 0 を返す（64 KiB の alias で二重に見えない）。

| offset | 名前 | R/W | 中身 |
| --- | --- | --- | --- |
| 0x000 | GHCI_MAGIC | R | `0x47484349`（"GHCI"） |
| 0x004 | GHCI_VERSION | R | [31:16] major（1）、[15:0] minor（0） |
| 0x008 | VENDOR_ID | R | FourCC。Amaterrace は `0x414D4154`（"AMAT"） |
| 0x00C | DEVICE_ID | R | FourCC。`0x41544731`（"ATG1"）。DC だけの instance は `"ATDC"` |
| 0x010 | ISA_ID | R | FourCC の標準の ISA。GHCI 1.0 は `0x47534931`（"GSI1"、§3）。0 = shader 無し |
| 0x014 | DEVICE_VERSION | R | vendor の実装の版（major.minor） |
| 0x018 | EXTCAP | R | extended capability の list の先頭の offset（byte、0 = 無し）。各 entry は 2 word: word0 `{[7:0] id, [15:8] cap の版, [31:16] 次の entry までの dword 数（この entry からの相対、0 = 終わり）}`、word1 = cap の register の offset（byte、窓の先頭から）。id: 1 `DISP`（DC、§5）、2 `DBG`（JTAG の bridge の有無）、3 `PERF`、4 `VEND`（vendor の register）、5 `MMU`（将来）、6 `CPFW`（CP の firmware の載せ替え、版 3、§2.4.10）、7 `SA`（systolic array の形、§3.9） |
| 0x01C | GCLK_HZ | R | core の clock。driver が timeout を秒に直す |
| 0x020 | CAPS | R | [0] CP と ring が有る、[1] BLT、[2] shader（`ISA_ID` ≠ 0）、[3] DC がこの窓に有る（`DISP` の entry と対）、[7:4] log2(warp の lane 数)（Amaterrace は 5）、[8] TU bilinear、[9] ROP stencil、[10] `WAIT_VSYNC` 可、[11] texture の tile（0 linear、1 4×4）、[15:12] 標準の state の版、[16] MMU、**[17] VKCP**（class V の packet を解く firmware が走っている。版 3）、**[18] FWLOAD**（`CPFW` で firmware を載せ替えられる）、**[19] NATIVE_ISA**（`NATIVE_ISA_ID` ≠ `ISA_ID`）、[23:20] log2(memory の line の byte)（5 = 32、6 = 64）、**[24] SUBGROUP**（§3.4 の `shfl`/`vote`/`ballot` が有る。版 3、U27）、**[25] SA**（systolic array、§3.9）、[26]・[27] reserved（版 4 の packed の超越と GRAPHICS は SA の延期で取り下げ。Appendix A。**版 5 の注**: 今の正は amaterrace-gpu の ghci.md §3.2 = [26] TU の拡張、[27] graphics、[28] packed、[29] MS4（draft、§15.10）。この表は版 4 の時点の物） |
| 0x024 | CAPS2 | R | [7:0] queue（ring）の数（v1 は 1）、[15:8] shared memory KiB、[23:16] constant の領域の word/16、[27:24] texture の slot の数/4（v1 は 4 = 16 slot）、[31:28] 頂点の属性の数/4（4 = 16） |
| 0x028 | SCRATCH | RW | 32 bit（疎通） |
| 0x02C | COUNTER | R | `gclk` の数（free running） |
| 0x030 | CTRL | RW | [0] RUN、[1] RESET（W1S、§1.3 の順で self-clear）、[2] HALT、[3] STEP（HALTED で 1 command）、[4] WDT_EN。状態遷移は §2.6 |
| 0x034 | STATUS | R | [0] CP busy、[1] BLT busy、[2] VF busy、[3] RX busy、[4] ROP busy、[5] TU busy、[6] SU busy（OR）、[7] SA busy（版 3）、[8] AXI_IDLE（GPU の client の outstanding が 0）、[9] FAULT、[10] HALTED、[11] RING_EMPTY、[12] MEM_READY（KC705: MIG の calibration 完了。ZYBO: 1）、[13] AXI_STUCK、[14] QUIESCED（新しい発行を止めている）、[19:16] 状態（§2.6 の番号） |
| 0x038 | IRQ_STATUS | R/W1C | [0] FENCE、[1] FAULT、[2] RING_EMPTY、[3] WATCHDOG、[4] DBG_DONE、[5] SOFT（IRQ_SET で立てる）、[6] HALTED（HALT の完了）、**[7] RESULT**（firmware が frame の result を書き終えた。版 3）、**[8] RETIRE**（`RPTR` が packet を越えた。版 3） |
| 0x03C | IRQ_ENABLE | RW | [8:0]。IRQ の線 = OR(IRQ_STATUS & IRQ_ENABLE)（level、plio と同じ約束） |
| 0x040 | IRQ_SET | W1S | [5] |
| 0x044 | WDT_CYCLES | RW | 1 command の上限の cycle 数（既定 2^28 ≈ 2.7 s @ 100 MHz） |
| 0x050 | RING_BASE | RW | ring の GPU address（32 byte 揃え）。RUNNING では書けない（無視、FAULT 種別 7） |
| 0x054 | RING_SIZE | RW | log2(byte)（10〜20）。同上 |
| 0x058 | RING_WPTR | RW | dword の index（ring の中、mod size）。書くと doorbell（§2.7） |
| 0x05C | RING_RPTR | R | CP が **解き終えて block に渡した**（parse 済みの）dword の index。非同期の block の完了は別（`WAIT_IDLE`・`FENCE`） |
| 0x060 | APERTURE_BASE | RW | GPU が触ってよい address の範囲の先頭（32 byte 揃え）。**全部の AMB の要求がここで検査される**。RUNNING では書けない |
| 0x064 | APERTURE_LIMIT | RW | 範囲の終わり（含まない） |
| 0x068 | FAULT_ADDR | R | 最後の fault の address |
| 0x06C | FAULT_INFO | R | [7:0] client の番号、[8] write、[15:12] 種別（1 aperture、2 未知の opcode、3 ring の誤り、4 watchdog、5 AXI の SLVERR/DECERR、6 RUN 中の KICK、7 RUNNING での禁止の書き込み、8 ISA の誤り（SU。版 3、§3.4.1。`FAULT_ADDR` = PC））、[23:16] 種別 1〜5 の時の block、[31:24] JOB_TAG（§2.4: fault した仕事の tag。CP が検出した時はその command の tag、非同期の時は block が持つ tag） |
| 0x070 | FENCE_LAST | R/W | 最後に書いた fence の値。**reset の後に driver が「最後に完了した値」を書き戻す**（§2.5） |
| 0x048 | NATIVE_ISA_ID | R | 版 3。vendor の native の ISA の FourCC（`GHCI_PROGRAM` で直接送れる物）。`ISA_ID` と同じなら native = 標準（Amaterrace: "GSI1"）。0 = native を直接は受けない |
| 0x0B0 | CP_HEAP_BASE | RW | 版 3。firmware の object の heap（aperture の中、32 byte 揃え）。RUNNING では書けない（FAULT 種別 7） |
| 0x0B4 | CP_HEAP_LIMIT | RW | 同上（終わり、含まない）。既定は driver が 8 MiB を与える |
| 0x0C0〜0x0DF | VEND（Amaterrace） | R | 8 word: NWARPS、NREGS、NPHYS、PACKED、SB_ENTRIES、PT の entry 数、reserved × 2 |
| 0x120〜0x13F、0x150〜0x15F | 0x120 CPFW_CTRL / 0x124 CPFW_STATUS / 0x128 CPFW_IBASE / 0x12C CPFW_IWORDS / 0x130 CPFW_DBASE / 0x134 CPFW_DWORDS / 0x138 CPFW_VERSION / 0x13C reserved / **0x150〜0x15C CPFW_MBOX0..3**（2026-10-23 p017 の実装で直した: 0x120〜0x13F の 8 word に 11 個は入らず、0x140〜0x14F は SA の予約） | RW/R | 版 3、extended capability `CPFW`（id 6）。`CPFW_CTRL` [0] LOAD（W1S: IMEM の像と DMEM の像を DMA、`READY` で終わり）、[1] RUN、[2] HALT（今の packet の後で止める）。`CPFW_STATUS` [0] READY、[1] FAULT、[2] ALIVE（heartbeat）、[15:8] firmware の状態。LOAD は IDLE・HALTED で CPU が止まっている時だけ（§2.4.7） |
| 0x140〜0x14F | SA_CAPS / SA_SU | R / RW | 版 3、extended capability `SA`（id 7、§3.9） |
| 0x080〜0x08C | PERF0〜3 | R | busy の cycle の合計（標準の意味は「busy の cycle」4 本まで。Amaterrace: SU、RX、TU、MC）。`PERF_CTRL` 0x090 [0] で clear |
| 0x0A0 | DBG_ADDR | RW | AMB を通した memory の読み書きの address（4 byte 揃え、aperture の検査を受ける）。書くと read を始める（非同期） |
| 0x0A4 | DBG_DATA | RW | 読み: `DBG_STATUS.busy` が 0 の時の最後の read の値（slave は **待たせない**）。書き: `DBG_ADDR` へ write を始める |
| 0x0A8 | DBG_STATUS | R | [0] busy、[1] error（aperture の外）。完了で `IRQ_STATUS.DBG_DONE` |
| 0x0F00 | KICK | W | [0] BLIT、[1] DRAW、[2] DISPATCH（STATE の値で直接 kick。ring 無しの最初の試験と debug 用。IDLE と HALTED でだけ受ける。RUNNING では FAULT 種別 6） |
| 0x1000〜0x17FC | STATE[0..511] | RW | state register file の alias（§2.3）。IDLE・HALTED でだけ書ける（RUNNING は無視して種別 7）。ring の `SET_REG` と同じ場所 |
| 0x100〜 | EXTCAP の entry の list | R | `DISP`（KC705: +0x10000 を指す。ZYBO の DC だけの bitstream: +0x0200）、`DBG`、`PERF`（P2 の実装: capability の register `PERF_SRCn` は 0x110〜、counter は 0x080〜）、`VEND`（0x0C0）、`CPFW`（0x120）、`SA`（0x140）。版 3 の追加は P2 の 0x110 の後ろに置く（M5） |
| 他 | — | R | 0（書き込みは無視、応答は OKAY） |

### 2.3 state register file（STATE[0..511]。0x000〜0x1DF は GHCI の標準、0x1E0〜0x1FF は vendor）

| index | block | 中身（32 bit の word。float は IEEE の bit） |
| --- | --- | --- |
| 0x000〜0x01F | BLT | 0 OP（[1:0] 0 FILL、1 COPY、2 TILE（linear → vendor の tile）、3 UNTILE。[4] blend over。[9:8] bpp（0 = 32、1 = 16）。[12] COPY の向き）、1 DST_BASE、2 DST_STRIDE（byte）、3 SRC_BASE、4 SRC_STRIDE、5 DST_XY、6 SRC_XY、7 SIZE、8 COLOR、9 CLIP_MIN、10 CLIP_MAX |
| 0x020〜0x04F | VF | 0 TOPOLOGY（[2:0] 0 points、1 lines、2 line strip、3 triangles、4 triangle strip、5 triangle fan）、1 INDEX_BASE、2 INDEX_FORMAT（0 無し、1 u16、2 u32）、3 FIRST（first vertex / first index）、4 COUNT、5 PRIM_RESTART（[0]）、6 INSTANCE_COUNT、7 FIRST_INSTANCE、8 VERTEX_OFFSET（base vertex、signed）、9〜15 reserved、16+2k ATTR[k]_BASE、17+2k ATTR[k]_DESC（[15:0] stride、[19:16] format（0 R32F、1 RG32F、2 RGB32F、3 RGBA32F、4 RGBA8_UNORM、5 RGBA8_UINT、6 RG16F、7 RGBA16F、8 R32_UINT、9 RG32_UINT）、[20] per-instance、[31:24] instance の divisor）、k < 16。**属性 k の行き先の register と component の数は STATE `ATTR_DST[k]`**（0x1C0〜0x1CF、版 3、M12） |
| 0x050〜0x06F | RX | 0〜5 VIEWPORT（float: x_scale、y_scale、x_off、y_off、z_scale、z_off）、6 SCISSOR_MIN、7 SCISSOR_MAX、8 CULL（[1:0] none/front/back、[2] front = CCW）、9 DEPTH_CLAMP、10 RAST_MODE、11 VARYING_COUNT（0〜32 word）、12 DEBUG_COLOR（shader 無しの定数色、p007）、13 PROVOKING（[0] 0 = first、1 = last） |
| 0x070〜0x08F | ROP | 0 RT_BASE、1 RT_STRIDE、2 RT_FORMAT（0 BGRA8、1 RGBA8、2 RGB565）、3 RT_SIZE、4 DS_BASE、5 DS_STRIDE、6 DEPTH（[0] test、[1] write、[4:2] func、[5] D24S8、[6] D32F）、7 STENCIL_FRONT、8 STENCIL_OPS、9 STENCIL_BACK、10 BLEND（版 1 と同じ bit）、11 BLEND_CONST、12 WRITE_MASK |
| 0x090〜0x18F | TU（**16 slot × 16 word**） | 16s+0 BASE（level 0）、+1 SIZE（[15:0] w、[31:16] h）、+2 LEVELS（[3:0] mip の数 ≤ 13）、+3 SAMPLER（[1:0] wrap u、[3:2] wrap v、[4] mag linear、[5] min linear、[6] mip linear、[7] compare、[10:8] compare func、[12] format）、+4〜+15 MIP_OFFSET[1..12]（level 0 からの byte の offset。driver が計算） |
| 0x190〜0x1AF | program | 0 VS_BASE、1 VS_WORDS、2 FS_BASE、3 FS_WORDS、4 CS_BASE、5 CS_WORDS、6 CONST_BASE、7 CONST_WORDS（constant の領域 0。ISA が意味を決める）、8 LDS_BYTES、9 WG_SIZE（[7:0] x、[15:8] y、[23:16] z）、10 VS_OUT_WORDS（position の後の varying の word 数） |
| 0x1B0〜0x1BF | SA（予約。延期、§3.9・Appendix A） | 0 |
| 0x1C0〜0x1CF | VF（版 3） | ATTR_DST[k]: [5:0] 先頭の register、[7:6] component の数 − 1（program の header の interface の表から firmware が書く） |
| 0x1D0〜0x1DF | reserved | 0 |
| 0x1E0〜0x1FF | vendor | Amaterrace v1 は 0x1FF を DBG_MARK に使う |

### 2.4 command（ring の中、32 bit の dword の列。版 3: Vulkan の command（gpu-op）の class と native の µop の class）

#### 2.4.1 方針（2026-10-23 ユーザー「コマンドは、現在のカーネルのコマンド（Venus由来）を使いましょう。」）

- ring が運ぶ command は **zedBSD の Kei GPU command protocol 版 1**（`include/uapi/gpu-op.h`。番号は Venus の wire format 1 と同じ、zedBSD だけの物は `GPU_OP_OWN_FIRST` = 0x10000 から）。libvulkan が `GPU_COMMAND_SUBMIT` で kernel に渡す stream（`[u32 番号][u32 flags][引数…]` の列、1 submission の枠は `SET_REPLY_STREAM(178)` → command… → `SEEK_REPLY_STREAM(179)` → `ENUMERATE_INSTANCE_VERSION(137)` の trailer、gpu-op.h の 93〜123 行）を、zedBSD の driver（§6.7）が**検証して GPU の memory の staging にほぼそのまま写し、ring には frame の packet を置き**（§2.4.6）、GPU の CP がそれを解く。
- CP の中で gpu-op を解くのは **firmware**（小さな RISC-V 風の制御 processor `atg_cpu`、§2.4.7。hardware で解く案は採らない。理由は §2.4.7 の表と §10 の 21）。firmware は Vulkan の object（pipeline・descriptor set・render pass・framebuffer・image view・sampler・command buffer の記録）を GPU の memory の中の heap に持ち、`QUEUE_SUBMIT` で記録を辿って、固定機能の block と SU を動かす **µop**（版 2 の `SET_REG`・`BLIT`・`DRAW`・`DISPATCH`・`FENCE`・`WAIT_IDLE`・`LOAD_CONST`・`LOAD_PROGRAM`・`INVALIDATE`…）に直して hardware の sequencer に流す。
- µop は GHCI の **class N（native）の packet** として ring にも直接書ける（driver 無しの bring-up、`ghci-blit` の試験、SU の compute の試験、CP に firmware が無い構成の GPU）。class N の標準の µop（class 0 の op 0〜63）は GHCI が決め、vendor の µop（class 1 の op 0〜63）は vendor が決める。**Amaterrace の v1 は class N の標準の µop だけで固定機能を動かせる**（版 2 の設計が成立する）ので、p003・p004・p007・p008 の板の受け入れは firmware 無しで行える。
- 1 本の ring に class N と class V（Vulkan）の packet が混ざってよい。CP は ring の順に処理し、class V の packet を firmware が解いている間は次の packet を取らない（µop の列は 1 本、順序は ring の順）。

#### 2.4.2 packet の封筒（envelope）

```
dword0（共通）: [31:30] class   [29:24] op（class N だけ）   [23:16] JOB_TAG   [15:0] n または [15:8] flags [7:0] n
  class 0 = N 標準の µop（op 0〜63）     dword0 = [31:30]=00 [29:24] op [23:16] JOB_TAG [15:8] flags [7:0] n（payload の dword 数 ≤ 255）
  class 1 = N vendor の µop（op 0〜63）  同上（Amaterrace: 0 DRAW_RAW、1 DBG_MARK）
  class 2 = V（Vulkan の command）       dword0 = [31:30]=10 [29:24] 0 [23:16] JOB_TAG [15:0] n（dword1 以降の dword 数 ≤ 65535）
      dword1 = gpu-op の番号（u32）、dword2 = [0] REPLY（libvulkan が送った flag のまま）[1] RESULT（dword3 が有効）[31:8] 0、
      dword3 = result の address（GPU の address、8 byte 揃え。RESULT = 0 なら 0）、dword4〜 = gpu-op.h の「Arguments」の wire のまま（u32/u64/構造体、little endian）
  class 3 = 詰め物                       dword0 = [31:30]=11 [15:0] n（CP は n dword を読み飛ばす。環の端の padding、§2.7）
```

- 版 2 の header（`[31:24] opcode [23:16] flags [15:8] JOB_TAG [7:0] n`）は**この形に置き換える**（p004 で ring を作る時にこの封筒で作る。p002 の `ghci_packets.h` は placeholder のまま）。JOB_TAG の位置が class に依らず同じなので、`FAULT_INFO[31:24]` への写しは 1 本の配線。
- class V の `n` は driver が各 command の引数を**解いて**数える（gpu-op の wire には長さが無い: gpu-op.h 71〜73 行）。driver は中継する command の構造体の形を全部知っている（検証のために解く、§6.7）ので、長さは副産物。CP の firmware は `n` を使って packet の終わりを知り、解けない command は packet ごと捨てて result に `VK_ERROR_FEATURE_NOT_PRESENT` を書く（stream を止めない。gpu-op.h 117〜119 行の「executor が止める」は driver の段で起きる: driver が中継しない番号は driver が `ENOTSUP` で止める）。
- 1 packet は環の端を跨がない（§2.7）。class V の 1 packet は最大 256 KiB（ring は最大 1 MiB、`RING_SIZE` 10〜20）。**v1 の driver は class V の packet を `GHCI_FRAME`（8 dword。command の列は staging に置く、§2.4.6）だけにする**ので、この上限にも ring の満にも当たらない。command を直に ring に載せる形は封筒として許す（他の実装・試験用）。
- `RPTR`（§2.2）の意味は変わらない: class N は sequencer に渡した位置、class V は firmware が packet を解き終えて µop を sequencer に渡し終えた位置。driver は `RPTR` より前の ring を書き換えてよい（firmware は packet の中身を heap に写してから `RPTR` を進める。RTL と firmware の規則）。

#### 2.4.3 class N（µop）: hardware の sequencer が実行する物

版 2 の表をそのまま class N の標準の µop にする（意味は版 2 と同じ、§2.5 の FENCE の意味も同じ）。

| op | 名前 | payload | 意味 |
| --- | --- | --- | --- |
| 0 | NOP | n 個（読み飛ばす） | |
| 1 | SET_REG | (index, value) × n/2 | STATE[index] = value。index ≥ 512 は FAULT 種別 3 |
| 2 | BLIT | 0 | STATE の BLT の範囲で 1 回。flags[0] = 1 なら終わりまで sequencer が待つ |
| 3 | DRAW | 0 | VF を kick。開始の時に D$ と T$ を無効化 |
| 4 | DISPATCH | 3（gx、gy、gz） | compute。flags[1] = SA（この dispatch が systolic array を所有する、§3.9） |
| 5 | FENCE | 2（addr、value） | 完全な fence（§2.5）。flags[0] = 1 なら `IRQ_STATUS.FENCE` |
| 6 | WAIT_IDLE | 0 | flags = 待つ block の mask（0 は全部） |
| 7 | LOAD_CONST | 3（領域 k、addr、words） | constant の領域 k に DMA（実行中の warp が無い時。暗黙の `WAIT_IDLE(SU)`） |
| 8 | LOAD_PROGRAM | 1（stage） | 「stage の program が変わった」の印: I$ を無効化 |
| 9 | WAIT_FENCE | 2（addr、value） | memory の word が `(int32)(mem − value) ≥ 0` になるまで poll。watchdog の対象 |
| 10 | PERF_RESET | 0 | |
| 11 | WAIT_VSYNC | 0 | CAPS[10] の時だけ |
| 12 | INVALIDATE | 0 | flags の mask: [0] D$、[1] T$、[2] constant、[3] I$ |
| 13 | RESULT | 3（addr、status、aux） | **版 3 で追加**: `addr` に 2 word `{status, aux}` を書く（firmware が class V の result を書く道。driver も使ってよい）。FENCE と同じ順序の規則（先行する書き込みの後） |
| 14〜63 | reserved | | FAULT 種別 2 |
| vendor 0 | DRAW_RAW（Amaterrace） | 9（3 頂点 × x, y, z） | VF と SU 無しで RX に 1 つの三角形（p007） |
| vendor 1 | DBG_MARK（Amaterrace） | 1 | STATE[0x1FF] = payload |

- JOB_TAG・並列性（1 本の ring、1 queue）・順序の規則は版 2 のまま（§6.4）。
- sequencer への µop の入口は 2 つ: ring（class N）と firmware（`UOP_FIFO`、§2.4.7）。両方とも同じ封筒の形で、ring の順と firmware の順を CP が直列にする。

#### 2.4.4 class V: どの gpu-op を GPU が扱い、どれを driver が host で解くか

分類（zedBSD の driver の `vk/` が決める、§6.7）: **D** = driver だけ（ring に載せない）、**R** = そのまま中継（driver は検証と長さの計算だけ）、**R'** = driver が解いて書き換えた GHCI 固有の command（`GPU_OP_GHCI_*`、§2.4.5）にして中継、**X** = 拒む（`ENOTSUP`、libvulkan は `VK_ERROR_DEVICE_LOST`。bcm2711 と同じ）。原則: **host の memory・CPU の mapping・kernel の資源・SPIR-V と compile・driver が返事を作る物は D、GPU の object と GPU の仕事は R/R'**。

| gpu-op（番号） | 分類 | 根拠・中身 |
| --- | --- | --- |
| 0〜8、11、12、155（instance・physical device・device・queue） | **D**（12 は R も伴う） | 返事は driver が HCR の CAPS/CAPS2/VEND と §3.7 の limit から作る（bcm2711 の `fixed_query` と同じ形）。session の文脈（JOB_TAG）は node の `open` で作り（`GHCI_SESSION_OPEN`）、`close` で消す（`GHCI_SESSION_CLOSE`）。`CREATE_DEVICE` は D（driver の帳簿）、`DESTROY_DEVICE` は D + R（firmware はその device の識別子の下の object を返す。他の device の object は残る: 1 session に VkDevice が 2 つあってもよい）。`GET_DEVICE_QUEUE2` の timeline は 0 だけ（1 queue） |
| 9・10・13〜17（proc addr、layer、extension、GetDeviceQueue） | D | libvulkan が送らない（gpu-op.h） |
| 18 `QUEUE_SUBMIT` | **R** + FENCE | driver は packet の後に class N `FENCE(fence page, value = device の fence の次の値, IRQ)` を置き、session の「最後の fence の値」を更新する（jobs との結びは §6.4）。semaphore は 1 queue の in-order では順序に効かないので firmware は識別子の存在だけ確かめる。result = 受理の VkResult（firmware が packet を解いた時点で書く。§2.4.6） |
| 19・20（WaitIdle） | D | 送られない |
| 21 `ALLOCATE_MEMORY` | **R'** → `GHCI_MEMORY` | driver の allocator（§6.3）が GPU の address を取り（import の record なら blob の address）、`[memory の識別子][GPU address][bytes][flags]` を firmware に知らせる。firmware は memory の識別子 → address の表を持つだけ |
| 22 `FREE_MEMORY` | R | firmware は表から消す。driver は「その時点の session の最後の fence の値」が過ぎてから返す（§6.3） |
| 23〜27（map、flush、commitment） | D / X（27 は X） | |
| 28・29 `BIND_*_MEMORY` | R | firmware が buffer/image の object に address を結ぶ。driver も帳簿に bind を記録する（56 の返事と scanout の import のため） |
| 30・31 memory requirements、56 subresource layout、84 granularity | **D** | driver が buffer/image の create info（driver の帳簿、下の「driver が持つ物」）から計算。layout の式は `ghci_layout.h`（R23） |
| 32〜34 sparse | X | |
| 35〜39 fence | D | driver の fence の帳簿: VkFence → 「それを signal する submit の fence の値」。fence page と `FENCE_LAST` で答える（§2.5、§6.4） |
| 40・41 semaphore | R | firmware は識別子を覚えるだけ |
| 42〜46 event、47〜49 query pool | X | v1 は無し |
| 50〜55、57・58 buffer・buffer view・image・image view | R（driver は 50・54 の create info の形も帳簿に写す） | buffer view（52）は v1 の shader が使わない → R だが firmware は object を作るだけ |
| 59・60 `CREATE/DESTROY_SHADER_MODULE` | **D** | driver が SPIR-V の word を帳簿に持つだけ（compile は pipeline の作成の時。C1） |
| 65・66 `CREATE_GRAPHICS/COMPUTE_PIPELINES` | **R'**（`GHCI_PROGRAM` × stage の後に、command 自体を R で中継） | driver が `pStages[]` の module・stage・entry の名前を解き、stage ごとに SPIR-V を GSI1 に compile（`drv_gpu_shader_parse(words, count, stage, …)`、Guardrail: compile は kernel 空間）、binary（§3.4.4、interface の表を含む）を GPU の memory に置き、`GHCI_PROGRAM [pipeline の識別子][stage][ISA][address][bytes]` を pipeline ごと・stage ごとに送ってから create の command を中継する。firmware は (pipeline, stage) で program を引く。entry の名前: v1 は「その stage の entry が 1 つの module」だけ受け、複数なら `VK_ERROR_FEATURE_NOT_PRESENT`（共有の compiler に entry の選択を足すのは別の判断、§6.6）。compile の失敗は driver が返事に `VK_ERROR_INVALID_SHADER_NV` 相当（`VK_ERROR_INITIALIZATION_FAILED`）で書き、command を中継しない |
| 67 `DESTROY_PIPELINE` | R | firmware は object を消す。driver は pipeline の binary を「その時点の session の最後の fence」が過ぎてから返す（module の寿命とは無関係。H3） |
| 68・69 pipeline layout、70〜79 sampler・descriptor set layout・pool・set・update | R | firmware が descriptor set の内容を持ち、draw/dispatch の時に program の interface の表で (set, binding) → TU の slot・constant の領域・storage の base に写す |
| 61〜64 pipeline cache | D | 空の cache（`GET_PIPELINE_CACHE_DATA` は 0 byte） |
| 80〜83 framebuffer・render pass | R | |
| 85〜89 command pool・buffers | R | firmware が記録の置き場（heap）を持つ |
| 90〜92 begin/end/reset | R | firmware が記録の状態を変え、result を解いた時点で書く（§2.4.6）。driver は 90・91・92 の返事をその result から書く |
| 93〜95、98、100〜107、110、112〜116、119、121、126、132、133、135（記録される command のうち v1 が実装する物） | **R** | firmware が記録に積む（wire のまま写す）。`QUEUE_SUBMIT` で辿って µop にする。barrier（126）は `WAIT_IDLE` + `INVALIDATE`（§6.4 の規則）に。114 の拡大・縮小、121、115/116 の format の変換は BLT では出来ない → **firmware の内蔵の GSI1 の program**（firmware の像に入れた blit・clear の kernel。p018 の範囲、M16） |
| 96・97・99（line width、depth bias、depth bounds） | R（firmware が読んで捨てる） | i915 と同じ |
| 108・109・111（indirect） | X | v1 は `DRAW_INDIRECT` の µop が無い（§3.7） |
| 117・118（update/fill buffer） | **R** | firmware が BLT の µop（FILL、COPY）に。118 は BLT の FILL、117 は inline の byte を heap に写して COPY（M6 の規則で書き込みの応答を待ってから） |
| 120・122（clear depth/stencil、resolve） | 120 R（BLT の FILL で D24S8/D32F）、122 **R**（版 5.1: BLT の RESOLVE、§15.8） | |
| 123〜125 event、127〜131 query、134 next subpass、136 execute commands | X | |
| 137 trailer、178 reply stream、179 seek | **D** | driver が返事と trailer を書く（§2.4.6）。ring に載せない |
| 180 `EXECUTE_STREAMS` | D | driver が blob の stream を自分で解いて（入れ子）、中の command を上の規則で扱う |
| 148・150・161（properties2、image format properties2、external buffer properties） | **D** | libvulkan が external memory の fd の道で送る（`external-properties.c`、`memory.c`）。driver が UUID と external の properties を答える |
| 0x10000〜0x1000d video | X | |
| `GPU_OP_GHCI_*`（§2.4.5） | — | driver が作る。libvulkan は送らない（userland からは `GHCI_NATIVE` だけを試験の build で受ける。他は `EINVAL`） |

- **driver が持つ物**（M1。「driver は Vulkan の object の意味を知らなくてよい」の正確な範囲）: 識別子の帳簿（種類と親の device）、buffer/image の create info（大きさ・format・tiling・usage・mip・layer: memory requirements・subresource layout・scanout の import のため）、memory の割当と bind、shader module の SPIR-V、pipeline → binary、fence の帳簿、command buffer の「begin 済み・end 済み」の状態（`QUEUE_SUBMIT` の検証）。持たない物: pipeline の状態の意味、descriptor の内容、render pass・framebuffer の意味、記録の中身。
- **GPU が「扱う」の意味**: firmware が object の意味（Vulkan の規格の、v1 の部分集合）を解いて µop にする。他の GHCI の GPU でも `vk/` は同じで、違うのは firmware。
- **どの session の仕事か**: JOB_TAG = session の番号（node の `open` ごとに 1〜255。0 は driver 自身の試験用）。firmware は tag ごとに object の表を分け、他の tag の識別子は見えない（識別子は libvulkan が session ごとに採るので衝突しない: gpu-op.h 59〜60 行）。v1 の fault の回復は device 全体のまま（§2.5）。

#### 2.4.5 GHCI 固有の gpu-op（`GPU_OP_GHCI_*`、`include/uapi/gpu-op.h` に足す。番号は **0x10100〜の案**、Q1 が確定（U10・U26））

| 番号（案） | 名前 | 引数（class V の wire） | 意味 |
| --- | --- | --- | --- |
| 0x10100 | `GPU_OP_GHCI_SESSION_OPEN` | [u32 tag][u32 flags][u64 heap の上限 byte] | firmware が tag の文脈を作る。result = 0 か `VK_ERROR_OUT_OF_DEVICE_MEMORY` |
| 0x10101 | `GPU_OP_GHCI_SESSION_CLOSE` | [u32 tag] | tag の object を全部返す。完了は後ろの FENCE で |
| 0x10102 | `GPU_OP_GHCI_MEMORY` | [u64 memory の識別子][u64 GPU address][u64 bytes][u32 flags（[0] host visible、[1] import）] | `ALLOCATE_MEMORY` の置き換え |
| 0x10103 | `GPU_OP_GHCI_PROGRAM` | [u64 pipeline の識別子][u32 stage][u32 ISA の FourCC][u64 binary の address][u32 bytes][u32 flags] | pipeline の stage の program（C1）。ISA は `ISA_ID`（標準 "GSI1"）か `NATIVE_ISA_ID`。それ以外は result = `VK_ERROR_INCOMPATIBLE_DRIVER`。他の実装の CP が JIT するのはここ（§3.4.5） |
| 0x10104 | `GPU_OP_GHCI_NATIVE` | [u32 count][count × class N の packet] | **試験用**: driver が白表で検査して class N として ring に写す。`CONFIG_GHCI_NATIVE` の build と root だけ。白表（試験の build）: NOP・SET_REG（index は全部）・BLIT・DRAW・DISPATCH（flags[1] の SA を含む）・FENCE・WAIT_IDLE・LOAD_CONST・LOAD_PROGRAM・INVALIDATE・RESULT。address の word は aperture の中かを見る（M20） |

- `GPU_OP_PROTOCOL_VERSION` は変えない（番号の追加だけ。i915 の video と同じ「自分の番号」の扱い。gpu-op.h の冒頭の文に GHCI の行を足すのは実装の Phase）。

#### 2.4.6 frame の運び方（staging）、返事（reply）と result、完了の通知

- **class V の frame は ring に直接は載せない**（H2・L6）: driver は 1 submission の中継する command の列（各 command に `[u32 番号][u32 flags][u32 result の index][引数…]` の封筒を付けた物）を **staging**（driver が GPU の memory に持つ環: 既定 4 MiB、aperture の中、session で共有）に写し、ring には class V の packet を 1 つだけ置く: dword1 = `GPU_OP_GHCI_FRAME`（0x10105、driver 内部）、dword4〜 = `[u64 staging の address][u32 bytes][u32 result page の address][u32 record の数]`。firmware はそこから読む。1 frame に割り込み 1 回、大きさの上限は staging（libvulkan の 1 MiB の記録の flush も入る）、ring の packet は小さいので ring が満ちる事は実質無い（満ちたら driver は `IRQ_STATUS[8] RETIRE`（版 3 で追加: `RPTR` が packet を越えるたび）を待つ）。
- **result の record**（2 word `{status, aux}` の列、frame ごとの result page）: firmware は **各 command を解いた時点で**（block の完了を待たず）その command の record を書く。`QUEUE_SUBMIT` の result は「記録を辿って µop を出せた」= 受理で、draw の完了ではない。frame の最後に firmware は「frame done」の record を書き、`IRQ_STATUS[7] RESULT` を立てる（CPU の制御 window から。H1）。firmware の DMA の書き込みが MC に受理された順で record が見えるよう、record の書き込みは firmware の DMA の応答を待ってから IRQ（M6）。
- **返事は driver が全部書く**（gpu-op.h 75〜79 行の形、trailer を最後に release store で。powervr の `vk-stream.c` の `version_reply` と同じ）。firmware は返事を書かない（U24）。返事の cursor の順序（M2）: driver は frame を解く時に、D の返事はその場で書き、R/R' の REPLY を求める command の返事の **大きさを計算して cursor の場所を空け**（返事の形は gpu-op.h の「Reply」で全部決まっている: `[number][VkResult]`、create の form の `[u64 1][識別子]`、`ALLOCATE_COMMAND_BUFFERS` の `[u64 count][…]` など）、result が来てから埋める。
- **ioctl の中で眠らない**（M3）: `commands.submit`（`GPU_COMMAND_SUBMIT`、`drv_gpu_completion` 付き）は staging に写し、ring に packet を置き、doorbell を鳴らして返る。device ごとの **reply thread**（kernel の thread）が `RESULT` の IRQ で起き、frame の record を読んで返事を埋め、trailer を release store で書き、**その後に** `drv_gpu_complete(completion, 0)`（libvulkan は通知を待ってから trailer を poll する: `context.c` の `vulkan_decoder_wait` → `vulkan_context_poll`）。REPLY を求める R/R' の無い frame（記録の送り）も同じ道（firmware の「frame done」で完了。順序を保つため）。fault の時は reply thread が pending の frame を error で完了する（`recovery.fault`）。
- 誤りの種類: (1) driver の検証で落ちる（`EINVAL`/`ENOTSUP`、ring に載せない。libvulkan は `DEVICE_LOST` にする）、(2) firmware が command を解けない/状態が使えない（record に VkResult、frame は続く、libvulkan はその command の VkResult を見る）、(3) 実行中の fault（§2.5、device 全体）。

#### 2.4.7 CP の構成: firmware か hardware か（推し: firmware。U19）

| 案 | 中身 | 7010 の資源（推定） | 工数 | 判断 |
| --- | --- | --- | --- | --- |
| **F. firmware**（推し） | `atg_cp`（HCR、ring の DMA、class N の sequencer、fence、IRQ、fault = P2 が作っている物）+ **`atg_cpu`**（RV32IM、in-order 3 段、IMEM 32 KiB、DMEM 16 KiB、AMB の port 1 つ、µop の FIFO、mailbox）+ firmware（C、`fw/cp/`）。firmware が gpu-op の wire を解き、object を heap（`CP_HEAP_*`、GPU の memory）に持ち、µop を出す | CPU LUT 2.5k、FF 1.5k、DSP 1（mul）+ 除算器 0.3k LUT、BRAM36 12（IMEM 8 + DMEM 4）。bitstream 1「2D」4.7k → **7.5k（43%）**、BRAM 5 → 17 | core 12 LW + firmware の runtime 20 LW + Vulkan の object model 44 LW（±50%）= 76 LW | 柔軟（Vulkan の規格の変化は firmware で吸収）。RTL は小さいまま。性能: draw 1 つの変換は object を heap（uncached の DDR、DMA 経由）から読むので **数 µs〜十数 µs** の見込み（M21。p017 の最初に測る。vkdemo・compositor の数百 draw/frame で数 ms なら v1 は受け、足りなければ object を DMEM に cache） |
| H. hardware で解く | RTL の状態機械が gpu-op の wire（pNext の chain、配列、入れ子の構造体、u64 の識別子の表）を解く | 部分集合（BIND・DRAW・SET_VIEWPORT・PUSH_CONSTANTS・BEGIN_RENDER_PASS）だけでも LUT 6〜10k + object の表の BRAM。pipeline の作成は不可能に近い | 30 LW 以上、変更のたびに合成 | **採らない**。結局 driver が object を解いて µop を作る事になり、「ring は gpu-op」の決定に反する |
| F'. firmware、CPU は sukuna-risc | ユーザーの CPU をそのまま | README: RV64GC、2-issue、SMT、**約 22,000 LUT**（7010 の 125%） | — | v1 では不可。**RV32 の最小の構成が sukuna-risc に出来たら `atg_cpu` を差し替えられる形**にする（同じ bus の口: 命令 fetch は IMEM の BRAM、data は DMEM + AMB の port + 制御 register の window。U20） |

- **2026-10-23 p017 の RTL で変えた点**（P2、amaterrace-gpu 0b78ff5、spec/gpu/cp/atg_cpu*.md）: core は 3 段ではなく **4 段**（F・D・E・W、W からの forwarding。3 段は 7010 の 10 ns に 8.2 ns 足りなかった。分岐の成立は 2 bubble、rv32i の CPI 1.27）。窓・DMEM の load/store は全部 2 cycle。窓に **IRQ_EN**（index 0x0D、reset 0。halt_req は firmware が消せない level なので mask が要る）、FW_STATUS の書き込み bit 16 **PARK**（halt の要求に firmware が packet を終えてから PARK を書き、そこで core が止まる）、CPFW_STATUS [3] STOPPED・[4] LOADING。RESET で残る register（IBASE/IWORDS/DBASE/DWORDS、READY）は reset を持たない。合成（atg_cpu だけ、place and route）: ZYBO 100 MHz で LUT 3000・FF 1600・BRAM36 12・DSP 4（WNS +0.341 ns）、KC705 200 MHz で LUT 3392（WNS +0.116 ns）。
- **`atg_cpu` の仕様（案）**: **RV32IM の全部を hardware**（`mul*` は DSP、`div*`/`rem*` は 32 cycle の逐次の除算器 ≈ 0.3k LUT。H5: `-march=rv32im` の clang は `div` を出すので software にはしない）、C 無し、FPU 無し、Machine mode だけ、割り込みは 1 本（ring に class V の packet が来た、fence の完了、HALT の要求）、`mcycle`、`csr` の代わりに memory-mapped の制御 window（`0xF000_0000`〜: 自分の packet の address と長さ、`UOP_FIFO`（µop の dword を書く。満なら stall）、**STATE の読み**（書きは `UOP_FIFO` の `SET_REG` だけ: 非同期の block が読んでいる STATE を直に書かない。H10）、`RPTR` の進め、DMA（AMB の line の読み書き、heap ↔ DMEM。書き込みの応答の数が読める）、`FENCE_LAST`、`COUNTER`、mailbox 4 word（`CPFW_MBOX`）、`RESULT` の IRQ、`DONE`（packet の処理の終わり）。3 段 pipeline（fetch、decode/execute、writeback）で 7010 -1 で 100 MHz、325T -2 で 200 MHz（R25）。**RTL は amaterrace-gpu の `rtl/gpu/cp/atg_cpu.v`**（U20）。
- **firmware**: C、`-ffreestanding -nostdlib -march=rv32im -mabi=ilp32`、共有の LLVM の clang（`build/llvm/bin/clang --print-targets` に riscv32 が有る、実測。**compiler-rt の builtins は無い**（`build/llvm/lib/clang/<版>/` に `lib/` が無い、実測）ので `fw/cp/` に `memcpy`・`memset`・`memcmp`・`__udivdi3`・`__umoddi3` 等を自前で持つ。toolchain は変えない）。大きさの目標: 64 KiB 以内（IMEM 32 KiB に入らなければ IMEM を 64 KiB = BRAM36 16 に。p017 の最初に測る、R26）。**firmware は bitstream の BRAM に初期値として入れる**（IMEM と DMEM の 2 つの像。`$readmemh`。driver は file を要らない）+ **`CPFW` の extended capability で host から載せ替えられる**（`CPFW_IBASE/IWORDS`（IMEM）と `CPFW_DBASE/DWORDS`（DMEM の .data と .rodata の像）の 2 対。H4）。**再起動の規則**: `.data` の原本は DMEM の像の中の「初期値の区画」に置き、`boot.S` が起動のたびに作業の区画へ写す（BRAM は reset で初期値に戻らないため）。p017 の受け入れに「書き換えた `.data` が RESET の後に戻る」を入れる。zedBSD の tree に blob を置くかは U21。
- **heap**: driver が attach で `CP_HEAP_BASE/LIMIT`（aperture の中、既定 8 MiB。**driver の allocator はこの領域・ring・staging・fence page・result page を session に貸さない**、L14）を与える。firmware の allocator（first-fit、session ごとの上限）。object の表は識別子の hash（64 bit → 12 bit、chain）。記録（command buffer）は heap の中の chunk の list。
- **watchdog と状態遷移**（M7）: class V の packet の処理も `WDT_CYCLES` の対象。counter は **CPU が `UOP_FIFO` の満で止まっている cycle と DMA の応答待ちの cycle を数えない**（長い submit で誤って発火しないため）。`HALT`・`STEP` の「1 command」は class V では **1 packet（= 1 frame）**。`CPFW_CTRL.HALT` は「今の packet の後で CPU を止める」（`CTRL.HALT` の quiesce の一部として CP が自動で行う）。`CPFW_CTRL.LOAD` は IDLE・HALTED で、かつ CPU が止まっている時だけ受ける。`CAPS[17] VKCP` は **静的**（bitstream に firmware が入っている）、走っているかは `CPFW_STATUS.READY`。reset で残る register に `CP_HEAP_*`・`CPFW_IBASE/IWORDS/DBASE/DWORDS`、消える物に `CPFW_STATUS`・CPU の状態（§2.6 の表に追記）。firmware が止まった時は FAULT 種別 4 → §2.5 の回復（`RESET` は `atg_cpu` も reset し、firmware は BRAM の像から再起動。heap は driver が作り直す）。
- **ZYBO の bitstream**: 1「2D」(p003・p004) に CPU は入れない。**1'「2D + FW」**（CP + CPU + MC + BLT、p017）で class V の道（`CMD_FILL_BUFFER`/`CMD_COPY_BUFFER` → BLT）を板で確かめる。3「raster」と 4「compute」には CPU を入れない（4 は 78% + 2.5k = 92% で閉じない見込み、U25）: SU と RX/ROP は class N で確かめ、class V の全部の道は Verilator と KC705（p011・p014）。

#### 2.4.8 firmware の中身（p017・p018 の設計の入口）

- 構成: `boot.S`（stack、bss、`.data` の写し、割り込みの入口）、`packet.c`（frame の受け取り、wire の reader: u32/u64/構造体/配列/pNext の chain。gpu-op.h の「wire form」56〜66 行の規則。**codec は driver と firmware で 1 つの表から生成する**（`ghci_vkwire.inc`: command ごとの引数の形。M21。i915 の `vulkan-codec.inc` は 2808 行、同じ物を 2 度は書かない）、`heap.c`、`object.c`（識別子の表、種類ごとの struct）、`memory.c`（識別子 → address）、`program.c`（binary の header と interface の表の検証、§3.4.4。他の実装の JIT の場所）、`pipeline.c`（create info → STATE の word の列）、`descriptor.c`、`pass.c`（render pass・framebuffer → ROP/RX の STATE、clear → BLT の FILL か内蔵の kernel）、`record.c`（記録の積み・辿り）、`submit.c`（記録 → µop: bind の状態機械、draw の前に変わった STATE だけ `SET_REG`、push constant → `LOAD_CONST`、barrier → `WAIT_IDLE`/`INVALIDATE`）、`blit.c`（内蔵の GSI1 の program: 拡大・縮小の blit、format の変換、clear attachments。binary は firmware の像に入れ、起動で heap に写す）、`uop.c`（`UOP_FIFO`）、`result.c`。
- **memory の順序の規則**（M6: `atg_mc` は client の間の順序を守らない）: firmware が DMA で heap に書いた物（inline の data、内蔵の program、push constant の写し）を他の client（CP の `LOAD_CONST`、BLT、SU、TU）が読む µop は、**その書き込みの応答が全部返ってから** `UOP_FIFO` に出す（window の「DMA の応答の数」で確かめる）。
- 1 draw の µop の列（典型）: `SET_REG` × 10〜40（変わった物だけ）、`LOAD_PROGRAM`（program が変わった時）、`LOAD_CONST`（push constant が変わった時: 暗黙の `WAIT_IDLE(SU)` で pipeline が空く。R24）、`DRAW`。
- 誤りは result に VkResult。firmware が自分の不変条件を破った時（assert）は `CPFW_STATUS.FAULT` と FAULT 種別 4 の道。
- **他の GHCI の実装**: firmware は vendor の物（GHCI は firmware の中身を決めない。決めるのは class V の意味 = Vulkan の規格の部分集合と、result・frame・session・program・memory の固有の command）。

#### 2.4.9 class V の 1 frame の流れ（vkCmdDraw を含む command buffer の submit）

1. app → libvulkan: `vkEndCommandBuffer` で記録（93〜135）と `END_COMMAND_BUFFER(91)` を 1 frame に、`GPU_COMMAND_SUBMIT`（libvulkan/context.c の transaction、`drv_gpu_completion` 付き）。
2. driver `commands.submit`（§6.7）: frame を解く。`SET_REPLY_STREAM` で返事の blob を選ぶ（D）。記録の各 command: 番号が R の白表に有り引数が解ける → staging に写す（result の index を付ける）。`END_COMMAND_BUFFER` も R（返事の場所を空ける）。class V の packet（`GHCI_FRAME`、staging の address と長さ、result page）を ring に置き、doorbell（`RING_WPTR`）。返る。
3. CP: ring から class V の packet → `atg_cpu` に割り込み → firmware が staging を読み、記録を heap に積み、record を書き、「frame done」→ `RESULT` の IRQ → `DONE` → `RPTR`。
4. driver の reply thread: record を読み、`END_COMMAND_BUFFER` の返事（VkResult）と trailer を書き、`drv_gpu_complete`。libvulkan の `vkEndCommandBuffer` が返る。
5. app → `vkQueueSubmit`: libvulkan は `GPU_JOB_RESERVE`（token = driver の marker）→ frame `QUEUE_SUBMIT(18)` + trailer を `GPU_COMMAND_SUBMIT` → `GPU_JOB_COMMIT`。driver: 2 と同じく staging + packet、その後ろに class N `FENCE(fence page, value = device の次の fence の値, IRQ)`、session の「最後の fence の値」を更新、doorbell。firmware が `QUEUE_SUBMIT` を解いて記録を辿り µop を流し、受理の record を書く → reply thread が返事と trailer → `drv_gpu_complete`。`commit`（§6.4）は marker を「最後の fence の値」に結ぶ。
6. sequencer: 先行の DRAW の完了を待って fence page に書き、`FENCE_LAST` を更新、`IRQ_STATUS.FENCE`。driver の IRQ の bottom half: fence page の値を読み、`(int32)(value − marker の値) ≥ 0` の marker を `drv_gpu_complete`（job の完了、libvulkan の `vkWaitForFences` が起きる）。

#### 2.4.10 P2 の p002（HCR・ring・fence・IRQ）との整合

- 変えない: HCR の offset と bit のうち P2 の `ghci_regs.h`/`.vh` にある物（§2.2。**P2 の実装は EXTCAP の list が 0x100、`PERF` の capability の register（`PERF_SRCn`）が 0x110〜0x11F、`PERF` の counter が 0x080〜0x08C**。版 3 の追加はその後ろに置く、M5）、CP の状態遷移（§2.6）、ring の約束（§2.7）、fence・IRQ・fault・watchdog・reset（§1.3・§2.5）、`KICK` と STATE の alias（class N の無い最初の道）。
- 足す（§2.2 の表に追記、P2 は p002 では触らない）: `NATIVE_ISA_ID`（0x048）、`CP_HEAP_BASE/LIMIT`（0x0B0/0x0B4）、`VEND`（0x0C0〜0x0DF、8 word: NWARPS、NREGS、NPHYS、PACKED、SB_ENTRIES、PT の大きさ、reserved × 2）、`CPFW` の extended capability（id 6、register は **0x120〜0x13F**: `CPFW_CTRL`（[0] LOAD W1S、[1] RUN、[2] HALT）、`CPFW_STATUS`（[0] READY、[1] FAULT、[2] ALIVE、[15:8] firmware の状態）、`CPFW_IBASE`・`CPFW_IWORDS`（IMEM の像）、`CPFW_DBASE`・`CPFW_DWORDS`（DMEM の像）、`CPFW_VERSION`、`CPFW_MBOX0..3`）、`SA` の capability（id 7、**0x140〜0x14F**、§3.9）、`CAPS[17] VKCP`（静的: firmware が入っている）、`CAPS[18] FWLOAD`、`CAPS[19]`（`NATIVE_ISA_ID` ≠ `ISA_ID`）、`CAPS[24] SUBGROUP`、`CAPS[25] SA`、`IRQ_STATUS[7] RESULT`・`[8] RETIRE`、`STATUS[7] SA_BUSY`、FAULT 種別 8。`CAPS2` は不変。`UOP_FIFO` は CPU の window だけ（HCR には出さない）。
- 変える: ring の packet の封筒（§2.4.2。p004 がこの形で作る。p002 の `ghci_packets.h` は placeholder のままでよい）、class N の `RESULT` µop（13）、class 3 の詰め物。
- firmware が無い構成（`CAPS[17]` = 0、ZYBO の bitstream 1・3・4）: driver は class V を送らず、`vk/` は attach しない。device の capability は `RESOURCE | TRANSFER | MAPPING | BLOB | SHARE | ALLOCATION_SHARE`（+ `DISPLAY | DISPLAY_EVENTS`）だけで、`CAPSET`・`COMMAND`・`NOTIFICATION`・`JOB` は名乗らない（libvulkan は device を作らない。L12）。`CAPS[2]` = 1 でも `CAPS[17]` = 0 なら Vulkan の device は出さない。

### 2.5 fence・割り込み・失敗

- **fence の値**は 32 bit で driver が単調に増やす。wrap は `(int32)(a − b)` で比べる（`WAIT_FENCE` も同じ）。fence の書き込み先は driver が GPU の memory の中に取った「fence page」（4 KiB、ZYBO は uncached の alias で CPU が読む、§6.3）。**reset の後**: driver は fence page の word と `FENCE_LAST` に「最後に完了した値」を書き戻してから `RUN` にする（比較が狂わない）。driver は 2^31 を超える前に（例 2^30 ごと）全部の pending を待って値を折り返す。
- IRQ: ZYBO は `IRQ_F2P[0]`（GIC 61、devcfg の固定）。GPU の bitstream では GPU、DC だけの bitstream では DC がこれを使う。KC705 は PCIe の MSI（§4.3 の表: user IRQ 0 = GPU、1 = DC。XDMA の channel の IRQ は別の vector）、JTAG の時は poll。level で、W1C の約束は plio と同じ。driver の handler は mask → 読んで W1C → unmask。
- **失敗と回復（v1 は device 全体）**: (1) aperture の外・AXI の error・watchdog・RUN 中の禁止の操作 → `FAULT`、CP は FAULTED、`HALT` と quiesce を自動で始める（§1.3）。進行中の block は `HALT` を見て止まる。driver は `FAULT_INFO`（block・tag）を log し、**`drv_gpu_report_error` → `recovery.fault` → `recovery.reset`**（`CTRL.RESET`、ring と fence page を作り直し、全 session の未完了の fence を error で完了）。「他の session は続ける」は **CP が parse の時に検出した誤り（種別 2・3・7）で、まだ何も block に渡していない時だけ**（その submit の session に `drv_gpu_report_session_error`、CP は `STEP` で次の header へ）。SU/ROP に入っていた他の session の仕事を黙って失う道は無い。(2) **watchdog**: 1 つの command が `WDT_CYCLES` を超える → FAULT 種別 4。driver 側も `execution_timeout_ns` で二重に見る。(3) `AXI_STUCK`: hardware では直らず、driver は device を失った物として扱う（`report_error`、ZYBO は `fpgaload` で書き直し、KC705 は PCIe の reset）。
- **何が起きないか**: GPU は aperture の外を決して読み書きしない。v1 は session ごとの隔離は無い（1 つの aperture を全 session が共有、R7）。

### 2.6 CP の状態遷移

| 状態（`STATUS[19:16]`） | 入る条件 | 受ける物 | 出る遷移 |
| --- | --- | --- | --- |
| 0 IDLE | reset の後、`RUN` = 0 | HCR の全部の書き込み、`KICK`、STATE の alias、`DBG` | `RUN` ← 1 → RUNNING |
| 1 RUNNING | `RUN` = 1 | `RING_WPTR`（doorbell）、`IRQ_*`、`SCRATCH`、`DBG`、`HALT`、`RESET`。**`RING_BASE/SIZE`・`APERTURE_*`・STATE の alias・`KICK` は無視して FAULT 種別 6/7** | `HALT` ← 1 → HALTING; FAULT → FAULTED; `RUN` ← 0 は今の command の後に IDLE（doorbell は保つ） |
| 2 HALTING | `HALT` ← 1 か FAULT | 読みだけ | 今の command（block の非同期の仕事を含む）が終わるか fault で止まったら quiesce → HALTED（`IRQ_STATUS.HALTED`） |
| 3 HALTED | HALTING の後 | IDLE と同じ + `STEP`（1 command）、`HALT` ← 0 で RUNNING へ | `RESET` → RESETTING |
| 4 FAULTED | FAULT | HALTING と同じ（自動で quiesce まで進む）。`STATUS.FAULT` = 1 | `RESET` だけ → RESETTING |
| 5 RESETTING | `RESET` ← 1（どの状態からでも。RUNNING からは HALTING を経る） | 読みだけ | `AXI_IDLE` → core の reset、MC の flush → IDLE。`RESET` の bit が落ちる |

- reset で **残る** register: `APERTURE_*`、`RING_BASE/SIZE`、`IRQ_ENABLE`、`WDT_CYCLES`、`SCRATCH`、STATE、`CP_HEAP_*`、`CPFW_IBASE/IWORDS/DBASE/DWORDS`、`SA_SU`（版 3）。**消える**: `RING_WPTR/RPTR`（0）、`IRQ_STATUS`、`FAULT_*`、`FENCE_LAST`（driver が書き戻す）、`CTRL.RUN`、`CPFW_STATUS`、CPU の状態（firmware は BRAM の像から再起動）、SA の FIFO と accumulator、block の内部（cache、PT、warp）。driver は reset の後に ring を先頭から使い直す。

### 2.7 ring の約束

- ring は `RING_SIZE` の byte の、dword の環。`WPTR`・`RPTR` は dword の index（0 ≤ x < size/4）。空: `WPTR == RPTR`。満: `(WPTR + 1) mod n == RPTR`（**1 dword を空ける**）。driver の空きは `(RPTR − WPTR − 1) mod n`。
- packet は環の端を跨がない: 残りに入らない時は driver が class 3 の詰め物（§2.4.2、n = 残り − 1。n が 255 を超えてもよい）で端まで埋めて先頭へ。CP は header の `n` が `WPTR` を越える時（driver の誤り）を FAULT 種別 3 とする（待たない。driver は **packet 全部を書いてから** `WPTR` を進める）。
- doorbell の前の CPU 側の順序: ZYBO は uncached（Normal non-cacheable）の書き込みの後、device の register の書き込みの前に **`dsb st`**（`kern_` の mmio の write が barrier を含むかは p006 で確かめ、含まなければ driver が明示に置く）。KC705 は BAR1（AXI-MM の posted write）の後に **BAR1 の最後の word を読み戻してから** BAR0 の doorbell を書く（posted write の追い越しを防ぐ）。
- CP は doorbell のたびに `RPTR` の line を **読み直す**（先読みした古い line を捨てる）。CP の先読みは `WPTR` まで。
- ring が満ちた時: driver は `IRQ_STATUS[8] RETIRE`（`RPTR` が packet を越えた）を待って空きを得る（`RING_EMPTY` の IRQ は使わない）。v1 の driver の packet は小さい（frame は 8 dword、FENCE は 4 dword）ので実質起きない。
- `RPTR` は「parse して block に渡した」位置。driver は `RPTR` で ring の再利用を判断してよい（packet の中身は CP が block に写し終えているので、`RPTR` より前は書き換えてよい。block が参照する memory（頂点、texture）は fence で守る）。

## 3. SU（Shader Unit）と GHCI の標準の shader ISA「GSI1」（版 3。amaterrace-gpu の `docs/gsi1.md` の内容。版 2 の "ATS1"（64 bit の独自の形）を置き換える）

2026-10-23 ユーザー「ISAはRISC-Vベースでカスタムしましょう。RISC-V仕様に則る必要はないです。ベースにしつつ、他のGPUの平均を取って、実装しやすくよく使われるものを、我々の命令形式にフィットさせて取り込んでいきましょう。」「GHCIは標準のシェーダーISAを定義し、…」「ネイティブISAを直接送信も可能。」

- **名前**: GHCI Shader ISA 1、FourCC **"GSI1"**（`0x47534931`）。`ISA_ID` = "GSI1" は GHCI 1.0 の shader 付きの GPU の全部で同じ（標準の ISA）。Amaterrace の native の ISA は GSI1 そのもの（`NATIVE_ISA_ID` = "GSI1"、`CAPS[19]` = 0）。版 2 の "ATS1" の名前と `isa/ats1/` は **`isa/gsi1/`** に変える（U18）。
- **RISC-V を基にする、とは**: (a) 命令の低位の 32 bit は RISC-V の 32 bit の形（R・R4・I・S・B・U の field の位置と、7 bit の major opcode の値、funct3/funct7 の値）そのもの、(b) 整数・load/store・分岐・乗除・単精度の float の命令は RISC-V（RV32IMF + Zfa の `fround`、Zbb の min/max/andn）の mnemonic と意味を使う、(c) GPU の物（exec mask、texture、export、LDS、quad、shuffle、packed fp16、超越関数）は RISC-V の custom の major opcode（custom-0〜3）に置く。**RISC-V の規格には従わない所**: 64 bit 固定長（§3.3）、register が 64 本で x0 を 0 に固定しない、比較の結果は all-ones/0 の Boolean（§3.2）、FP の register file を分けない（1 つの register file）、CSR・ecall・特権・例外は無い、`fdiv` 無し。RISC-V の toolchain はそのまま使わない（assembler は自前の `gsi1asm.py`。mnemonic が同じなので読みやすい）。
- 他の GPU から取る物（共通で、実装しやすい物）: 表は §3.4.6。

### 3.1 実行の model

- **warp は 32 lane の scalar、16 bit packed 付き**（README）。lane ごとに 32 bit の register の列。physical lane は `NPHYS`（8/16/32）で、1 命令を `32/NPHYS` cycle で流す。ISA・compiler・driver・API から見える幅は常に 32（subgroup の幅 = 32）。同じ binary が NPHYS に依らず動く（p008 の受け入れ）。
- **SM/CU に当たる単位**（版 2 と同じ）: NPHYS の SIMD の datapath、`NWARPS` の常駐の warp の round-robin の scheduler、BRAM の register file（§3.5）、I$・D$、LDS、constant bank、PT、primitive table。
- **warp の状態**: PC（命令の index）、`EXEC`（32 bit の mask、compiler が `exec.*` で管理。hardware は再収束を扱わない）、`KILLED`（sticky、fragment の discard）、scoreboard の entry（§3.1.1）、`WAIT` の counter（class m・t・x の未完の数）、warp の種類（vertex/fragment/compute）と workgroup の番号。
- **predication**: lane が EXEC の外なら register の書き込みと memory・texture・export の副作用を行わない。`KILLED` の lane は副作用（`sw`・`atom`・`exp`・`tex`）を行わないが EXEC は変えない（版 2 と同じ）。**helper lane**（M10）: fragment の warp では RX が EXEC を **quad 単位**（4 lane の全部）で立て、三角形の外の lane（helper）も `qd` と `texb` の微分のために走らせる。副作用の mask = coverage（特殊 operand 119 `mask`、RX が書く）& ~KILLED で、helper の lane は `sw`・`atom`・`exp` を行わない（Vulkan の規則）。compute・vertex の warp では `mask` = EXEC の初期値。
- **分岐**: warp 単位。`bany`/`bnone`（Boolean の register を EXEC の lane で見る）、`bexnz`/`bexz`（EXEC が 0 でない/0）、`j`。compiler は IR（if-converted、`SELECT`）のまま、loop と「副作用の有る区間の skip」だけに分岐と EXEC を使う（§6.6）。
- **精度**: fp32 は IEEE の形、丸めは命令の rm（既定 RNE）、denormal は flush（入力も出力も）。fp16 の packed も同じ規則。超越は 2 ulp 程度、`rcp`・`rsq` は 1 ulp（table + Newton 1 段）。整数は 32 bit の 2 の補数。
- **命令の発行**: warp ごとに in-order、1 命令ずつ。短い命令（class a: ALU、class f: FP の pipeline）は順に完了する。長い命令（class m: memory、t: texture、x: 超越・除算）は順不同に戻る → scoreboard が依存を守る。

#### 3.1.1 scoreboard（2026-10-23 ユーザー「数は少なくていいので、scoreboardを実装できないでしょうか。性能に大きく影響しますので」）

- warp ごとに **`SB_ENTRIES` 個**（ZYBO 4、KC705 8。p008 で LUT を実測して決める）の entry `{valid, dst[6:0], class[1:0], width[1:0]}`。長い命令（class m・t・x）の発行で entry を取り（dst と、texture なら dst..dst+3 の幅）、戻りの書き込みで返す。entry が無ければ発行を止める（他の warp は発行できる）。
- 発行の検査（毎 issue）: 命令の source（rs1・rs2・rs3 と、`texl`/`texb`/`texf` の暗黙の rs1+1）と dst（rd と、texture の暗黙の rd..rd+3）の **範囲**を全 entry の dst の範囲と比べ、重なれば止める（RAW・WAW。WAR は source を発行の段で読む in-order の設計なので起きない: `sw`・`exp`・`atom` の data も発行の段で読む）。範囲の重なりは entry ごとに 2 つの比較（base ≤ x < base + width）× 5 operand × 8 entry ≈ 400 LUT（版 3 の見積もりを直した、M9）。
- **`wait` 命令は残す**（class ごとの counter: cm = 未完の `sw`/`atom`（BRESP 待ち）、ct = 未完の texture、cx = 未完の超越・除算）。値の待ちは scoreboard が行うので compiler は `wait` を **store の完了の順序（`fence`・`bar`・`end` の前）**にだけ使う。`end` は暗黙に `wait 0,0,0`。
- 短い命令（class a・f）の結果は **1 本の固定長の pipeline**（a も f と同じ段で書き戻す。長さは f の 5〜6 段）の順に書き戻る（bypass 無し）ので、a と f の間の WAW は起きない。同じ warp の次の発行は `32/NPHYS` cycle 後: NPHYS 8（4 cycle）では RF の読みの段が結果の書き戻しの 1〜2 cycle 前に来るので **interlock で 1〜2 cycle 待つ**（版 2 の「4 cycle が隠れる」は誤り、M9）。NPHYS 16 で 3〜4、NPHYS 32 で 4〜5 cycle。NWARPS の他の warp が埋める。
- EXEC が全部 0 の class m・t・x の命令は memory・texture の要求を出さず、scoreboard の entry も取らない（戻りが無いので待てない、M9）。lane ごとの mask は要求の数だけを変え、entry と `cm`・`ct`・`cx` の数は命令ごとに 1。`sw` の `cm` は MC の BRESP で減る（aperture の外は error の応答で減る）。
- compiler の scheduling（§6.6）: 長い命令の結果を使う命令を遠ざけ、独立の命令で埋める。NWARPS の他の warp が残りの latency を隠す。

### 3.2 register と operand の空間

| operand の番号（7 bit） | 意味 | 使える所 |
| --- | --- | --- |
| 0〜62 | `r0`〜`r62`（thread ごとの 32 bit の GPR。実際の数 `NREGS` は `VEND` の register。NREGS = 32 の構成で r32〜r62 を使う program は `GHCI_PROGRAM` の result で拒む: header の `nregs` > NREGS） | rd・rs1・rs2・rs3 |
| 63 | **`rq`**: systolic array の FIFO の口（dst に書く = push、source に読む = pop。GPR ではない。全部の実装で予約、§3.9） | rd・rs1・rs2・rs3（SA の dispatch の warp だけ。他は ISA の fault） |
| 64〜95 | `c0`〜`c31`（constant bank の先頭 32 word。以降は `lwc`） | rs1・rs2・rs3 |
| 96 `zero`、97 `one`（1.0f）、98 `onei`（1）、99 `half`（0.5f）、100 `two`（2.0f）、101 `mone`（−1.0f）、102 `lane`（0〜31）、103 `warp`、104 `exec`、105 `killed`（自分の lane の discard の bit を Boolean に）、106〜108 `wgx/wgy/wgz`、109〜111 `lidx/lidy/lidz`、112 `lidn`（local index）、113 `prim`、114 `front`（Boolean）、115〜117 `nwgx/nwgy/nwgz`、118 `oneh2`（packed 1.0h × 2）、119 `mask`（coverage の mask: fragment の warp は RX の covered な lane の 32 bit（p009 の RTL）、compute と vertex は EXEC の初期値。版 5 で直した）、120 `qstat`（SA の FIFO の数、§3.9）、121 `sastat`（SA の状態）、122 `qtag`（pop した entry の tag、版 4）、123〜127 reserved | 特殊（inline の定数と system の値。AMD の inline constant、NVIDIA の `SR_*` に当たる） | rs1・rs2・rs3 |

- **x0 の固定は無い**: `r0` も普通の register。RISC-V の pseudo（`mv rd, rs` = `addi rd, rs, 0`、`not` = `xori rd, rs, -1`、`neg`）はそのまま使える。`nop` は custom-3 の funct3 111 sub 0（何も書かない。`addi r0, r0, 0` は r0 の scoreboard に掛かるので nop にしない、L11）。
- **Boolean**: 32 bit の all-ones = true、0 = false（共有の IR と同じ）。**全部の比較命令（`slt`・`sltu`・`slti`・`sltiu`・`feq`・`flt`・`fle`・`fne`、packed の `fcmp2`）は Boolean を書く**（RISC-V の 0/1 からの逸脱。U23）。`exec.*`・`bany`・`ball`・`kill`・`vote`・`ballot` は Boolean を「0 でなければ true」と読む。`sel` は **bit ごと**（rd = (rs1 & rs2) | (~rs1 & rs3)、IR の SELECT と同じ。M15）。
- 符号化: rd・rs1・rs2 は word0 の RISC-V の位置に下位 5 bit、word1 に上位 2 bit（§3.3）。rs3 は R4 の位置（word0[31:27]）に下位 5 bit、word1 に上位 2 bit。特殊 operand（96〜127）は上位 2 bit が 11 なので **word1 が 0 の命令は r0〜r31 だけを使う純粋な RISC-V の形**になる（手で読める・書ける）。

### 3.3 命令の形（64 bit 固定。word0 = RISC-V の 32 bit の形、word1 = 拡張。U22）

```
word0（little endian の低位の 32 bit。RISC-V の形そのまま）:
  R   [6:0] opcode [11:7] rd [14:12] funct3 [19:15] rs1 [24:20] rs2 [31:25] funct7
  R4  [6:0] opcode [11:7] rd [14:12] rm/funct3 [19:15] rs1 [24:20] rs2 [26:25] fmt/funct2 [31:27] rs3
  I   [6:0] opcode [11:7] rd [14:12] funct3 [19:15] rs1 [31:20] imm[11:0]（符号拡張）
  S   [6:0] opcode [11:7] imm[4:0] [14:12] funct3 [19:15] rs1 [24:20] rs2 [31:25] imm[11:5]
  B   [6:0] opcode [7] imm[11] [11:8] imm[4:1] [14:12] funct3 [19:15] rs1 [24:20] rs2 [30:25] imm[10:5] [31] imm[12]（imm[12:1] を 12 bit の符号付きの**命令数**として読む: 目標 = PC + sext(imm[12:1])。±2048 命令。imm[0] は無い）
  U   [6:0] opcode [11:7] rd [31:12] imm[31:12]
word1（拡張。0 なら「RISC-V の形のまま、r0〜r31、修飾無し」）:
  [1:0] rd[6:5]  [3:2] rs1[6:5]  [5:4] rs2[6:5]  [7:6] rs3[6:5]
  [8] n1（rs1 を負に）[9] a1（rs1 の絶対値）[10] n2 [11] a2 [12] n3 [13] a3   ※ float の命令だけ。整数の命令では 0
  [14] sat（結果を [0,1] に飽和。float だけ）
  [16:15] hsel（packed: 00 両方、01 low だけ、10 high だけ、11 swap して両方）
  [21:17] sub（副種別: atomic の種類、texture の slot、quad の種類、shuffle の種類、超越の種類、sactl/exec の種類）
  [31:22] imm_hi[9:0]（I/S/B の imm の上に足して 22 bit の符号付き offset）
  U 形（`lui`/`movi`）だけ別: [1:0] rd[6:5]  [13:2] imm[11:0]（`movi` の下位 12 bit。`lui` は 0）  [31:14] 0
```

- **なぜ 64 bit 固定か**（U22。§10 の 23・24）: (1) decode が 1 種類（I$ から毎 issue 1 word、PC は命令の index）、(2) FMA の 3 source + 修飾 + 64 本の register + constant/特殊 operand が入る、(3) word1 = 0 で RISC-V の 32 bit の形がそのまま読める、(4) I$ 2 KiB = 256 命令で版 2 と同じ（shader は小さい）。AMD の 32/64 可変・NVIDIA の 128 固定・PowerVR の 64 固定の中で、FPGA で最も単純な物。
- 命令の index は PC（8 byte 単位）。program の base は `VS_BASE` 等（§2.3、8 byte 揃え）。分岐の offset は命令数。
- 即値（M11）: I/S の offset = **sext(imm12) + (sext(imm_hi[9:0]) << 12)**（22 bit の符号付き、±2 MiB。word1 = 0 なら RISC-V の `lw r1, -4(r2)` と同じ値）。B の offset は上の命令数。`lui rd, imm20` は RISC-V と同じ（rd = imm20 << 12）。`movi rd, imm32` は `lui` と同じ符号化で word1[13:2] に imm[11:0] を足した物（rd = (imm20 << 12) | imm[11:0]。word1[13:2] = 0 なら `lui`）。`movi` は assembler の名前で、decoder は `lui` の 1 種類。

### 3.4 命令の一覧と opcode の対応（v1）

#### 3.4.1 major opcode の対応（word0[6:0]。RISC-V の値）

| opcode | RISC-V の名前 | GSI1 での用途 |
| --- | --- | --- |
| 0110011 | OP | 整数 R: `add sub sll slt sltu xor srl sra or and`、M: `mul mulh mulhsu mulhu div divu rem remu`（funct7 0000001。`div*`/`rem*` は共有の除算器、class x）、Zbb: `min max minu maxu`（funct7 0000101）、`andn orn xnor`（funct7 0100000、funct3 111/110/100） |
| 0010011 | OP-IMM | `addi slti sltiu xori ori andi slli srli srai` |
| 0110111 | LUI | `lui`、`movi`（word1 に imm[11:0]） |
| 0010111 | AUIPC | reserved（PC 相対の data は無い） |
| 0000011 | LOAD | `lw rd, imm(rs1)`（funct3 010、global、D$）、`lwc rd, imm(rs1)`（funct3 110、constant bank を word の index で。rs1 は index、imm は word）。`lb lh lbu lhu` は reserved（v2） |
| 0100011 | STORE | `sw rs2, imm(rs1)`（funct3 010）。`sb sh` は reserved |
| 1100011 | BRANCH | funct3 000 `bany rs1, off`（EXEC の lane のどれかで rs1 ≠ 0）、001 `bnone rs1, off`、010 `ball rs1, off`、011 `j off`、100 `bexnz off`（EXEC ≠ 0）、101 `bexz off`。RISC-V の `beq` 等（lane ごとの条件）は無い（warp 単位の分岐だけ） |
| 1101111 / 1100111 | JAL / JALR | reserved（v1 は subroutine 無し。v2 で `jal`） |
| 1010011 | OP-FP（fmt = 00、single） | `fadd.s fsub.s fmul.s`（funct7 0000000/0000100/0001000）、`fsgnj.s`（= `fmv`、修飾で neg/abs が出来るので `fsgnjn/fsgnjx` は pseudo）、`fmin.s fmax.s`（0010100）、`fsqrt.s`（0101100、class x）、`fcvt.w.s fcvt.wu.s`（1100000、rm: rtz が IR の F2I）、`fcvt.s.w fcvt.s.wu`（1101000）、`feq.s flt.s fle.s`（1010000、funct3 010/001/000）+ **`fne.s`（funct3 011、unordered も true）**、`fround.s`（Zfa: 0100000、rs2 = 00100、rm: rne/rtz/rdn/rup = round even/trunc/floor/ceil）。**`fdiv.s` は無い**（`rcp` + Newton を compiler が組む。IR に FDIV は無い）。`fclass fmv.x.w fmv.w.x` は無い（register file は 1 つ） |
| 1000011 / 1000111 / 1001011 / 1001111 | MADD / MSUB / NMSUB / NMADD | `fmadd.s rd, rs1, rs2, rs3`（rd = rs1×rs2 + rs3）、`fmsub.s`、`fnmsub.s`、`fnmadd.s`（RISC-V と同じ意味。修飾で負・絶対値も可） |
| 0001011 | custom-0「memory・同期」 | funct3 000 `lds rd, imm(rs1)`（shared の word）、001 `sts rs2, imm(rs1)`、010 `atom rd, (rs1), rs2`（global、sub = 種類: IR の 11 種 `and or xor xchg add sub smax smin umax umin cmpxchg`、`cmpxchg` の比較値は rs3。MC の atomic unit、D$ の line を無効化、class m）、011 reserved（shared の atomic、v2）、100 `fence`（imm[2:0]: [0] global = 未完の `sw`/`atom` の BRESP を待つ、[1] shared、[2] acquire = D$ を無効化）、101 `bar`（workgroup の全 warp の到達）、110 `wait cm, ct, cx`（imm[11:0] = 3 × 4 bit の上限）、111 `end` |
| 0101011 | custom-1「texture・入出力・lane の間」 | funct3 000 `texl rd, rs1, rs2`（rs1 = u、rs1+1 = v、rs2 = lod。slot = sub[3:0]（16 slot）。rd..rd+3。texel の offset は v1 では無し: IR の offset ≠ 0 は拒む、M14）、001 `texb rd, rs1, rs2`（rs2 = bias。lod は quad の微分から TU が計算）、010 `texf rd, rs1, rs2`（整数の texel、rs1 = x、rs1+1 = y、level = rs2。slot = sub[3:0]）、011 `texsz rd, rs1`（level rs1 の w・h を packed 16 × 2。slot = sub[3:0]）、100 `exp rs2, imm`（target = imm12: 0x000+k POS の k、0x010+4v+c varying v の c、0x100+c COLOR0 の c、0x104 DEPTH。非同期、`end` で揃う）、101 `lda rd, imm`（primitive table の頂点 imm[1:0] の word imm[7:2]）、110 `qd rd, rs1`（sub: 0 `qdx`（lane^1 との差、fine）、1 `qdy`（lane^2）、2〜5 `qswap`（lane^1 / lane^2 / lane^3 / quad の lane 0 を配る））、111 `shfl rd, rs1, rs2`（sub: 0 idx、1 xor、2 up、3 down、4 bfly。rs2 = lane/mask/delta。**`CAPS[24]` の時だけ**） |
| 1011011 | custom-2「16 bit packed」 | funct3 000 `fadd2`、001 `fsub2`、010 `fmul2`、011 `ffma2`（R4 の形）、100 `fmin2`/`fmax2`（funct7 で）、101 `iadd2`/`isub2`/`imul2`、110 `fcmp2`（funct7: lt/ge/eq/ne、half ごとに 0xFFFF/0）、111 は funct7 で: **0000000 `packh rd, rs1, rs2`**（2 つの fp32 → half × 2）、**0000001 `unpackh rd, rs1`**（sub: low/high → fp32）、**0000010 `swaph`**、他の funct7 は reserved（版 4 で一度足した packed の超越 `exp2h2` 等は SA の延期で取り下げ、Appendix A）。`packh`/`unpackh` は **`PACKED` に依らず必須**、他は `PACKED` = 0 の構成で FAULT（U15） |
| 1111011 | custom-3「GPU の制御・超越・選択・投票」 | funct3 000 `sel rd, rs1, rs2, rs3`（R4 の形: rd = (rs1 & rs2) \| (~rs1 & rs3)）、001 `exec.set rs1` / `exec.and rs1` / `exec.or rs1` / `exec.save rd`（sub）、010 `kill rs1`（sticky）、011 超越（sub: 0 `rcp`、1 `rsq`、2 `exp2`、3 `log2`、4 `sin`、5 `cos`、6 `fract`（= x − floor(x)、短い: class f）。0〜5 は class x）、100 `vote rd, rs1`（sub: 0 any、1 all → 全 lane に同じ Boolean。`CAPS[24]`）、101 `ballot rd, rs1`（EXEC の中で rs1 ≠ 0 の lane の mask を全 lane に。`CAPS[24]`）、110 `sactl rs1`（systolic array の制御の word、§3.9。`CAPS[25]`）、111 `nop`（sub 0。他の sub は reserved） |
| 0000111 / 0100111 / 0001111 / 1110011 / 1010111 / 1110111 | LOAD-FP / STORE-FP / MISC-MEM / SYSTEM / OP-V / OP-VE | **vendor の拡張の空間**（GSI1 は使わない。vendor の ISA（`NATIVE_ISA_ID`）が GSI1 の上位集合ならここに置く） |

- word0[1:0] は常に 11（RISC-V の 32 bit の形の印。00/01/10 は FAULT: 圧縮命令は無い）。
- 命令ごとの形（L11）: OP・OP-FP・custom の 2 source の命令は R、`fmadd` 系・`sel`・`ffma2`・`atom`（rs3 = cmpxchg の比較値）は R4、OP-IMM・`lw`・`lwc`・`lds`・`lda`・`texsz` は I、`sw`・`sts`・`exp` は S、BRANCH は B、`lui`/`movi` は U、`texl`/`texb`/`texf`/`qd`/`shfl`/`vote`/`ballot`/`sactl`/`exec.*`/`kill`/`fence`/`bar`/`wait`/`end`/`nop` は R（使わない field は 0。`wait` の 3 つの上限は imm12 の 3 × 4 bit なので I）。
- 未定義の opcode・funct・sub、`CAPS` に無い機能（packed、subgroup）、`nregs` を超える register は **ISA の fault**: warp は止まり、SU が `FAULT` 種別 8（**版 3 で追加**: ISA の誤り。`FAULT_INFO[23:16]` = SU の番号、`FAULT_ADDR` = PC）を立てる → §2.5 の回復。

#### 3.4.2 命令の群と latency の class

| 群 | 命令 | class | 備考 |
| --- | --- | --- | --- |
| 整数 | `add sub and or xor sll srl sra slt sltu` と I 形、`min max minu maxu andn orn xnor`、`lui movi` | a（1 issue） | `slt*` は Boolean |
| 乗算 | `mul mulh mulhu mulhsu` | f（DSP、3 cycle） | |
| 除算 | `div divu rem remu` | x（共有の除算器、lane ごと 34 cycle） | scoreboard |
| fp32 | `fadd.s fsub.s fmul.s fmadd.s fmsub.s fnmsub.s fnmadd.s fmin.s fmax.s fsgnj.s fround.s fcvt.* feq flt fle fne`、`fract` | f（DSP の pipeline、4〜6） | 修飾 n/a/sat |
| 超越 | `rcp rsq exp2 log2 sin cos fsqrt.s` | x（共有の 1 本、32 + 8 cycle） | scoreboard |
| packed | `fadd2 fsub2 fmul2 ffma2 fmin2 fmax2 fcmp2 iadd2 isub2 imul2 swaph`、`packh unpackh` | f | `PACKED`（U15） |
| memory | `lw sw lwc lds sts atom fence bar wait end` | m（`lw` は D$ hit で 4、miss で AMB の latency。`lwc`・`lds` は 2） | `sw`/`atom` は cm、`lw`/`atom` の戻りは scoreboard |
| texture | `texl texb texf texsz` | t | scoreboard（rd..rd+3） |
| 入出力・lane | `exp lda qd shfl vote ballot` | a（`shfl` は 2 pass = 2 × 32/NPHYS cycle）| `shfl`/`vote`/`ballot` は `CAPS[24]`（KC705 のみ。+0.5k LUT/SU の staging RAM、§3.6） |
| 制御 | `bany bnone ball j bexnz bexz exec.set exec.and exec.or exec.save kill sel` | a | 分岐は 1 cycle の bubble |
| systolic（予約） | `rq`（operand 63 の push/pop）、`sactl`、`qstat`/`sastat`/`qtag` | a（v1 は ISA の fault） | SA は延期（§3.9、Appendix A） |

#### 3.4.3 入力と出力（版 2 と同じ。GHCI が決めるのは「属性 k は入力 slot k」「fragment の入力は ISA が決める」だけ）

- vertex の warp: VF が属性 k の component（1〜4 word）を STATE `ATTR_DST[k]`（§2.3、0x1C0〜。firmware が program の header の interface の表から書く）の先頭の register から連続に書いてから始める（k < 16。16 属性 × 4 component は NREGS 32 に入らないので、compiler は使う属性と component だけを表に出す、M12）。出力は `exp`（POS、POINT_SIZE = 0x004、varying、SECOND_COLOR = 0x108+c）。
- fragment の warp: RX が `r0 = b0`、`r1 = b1`、`r2 = b2`（perspective 補正済み、元の 3 頂点に対する barycentric）、`r3 = z`、`r4 = x + 0.5`、`r5 = y + 0.5`（画素の中心、p009 の RTL）を書いてから始める。版 5（§15.4）: `r6 = SampleMaskIn`（常に）、MS_CTRL[4] の時 `r7〜r9` = centroid の barycentric。export の `0x105` = SampleMask の出力。varying は `lda` × 3 + `fmul` + `fmadd` × 2 で compiler が補間（flat は `lda` の頂点 0、noperspective は §3.8 の式）。
- compute の warp: 入力は特殊 operand（`wg*`、`lid*`、`lidn`、`nwg*`）。

#### 3.4.4 program の binary の形（`GHCI_PROGRAM` が指す物。`gsi1_isa.h`）

```
word 0  magic "GSI1"（0x47534931）       word 1  版（1）
word 2  stage（0 vertex、1 fragment、2 compute）  word 3  flags（[0] packed を使う、[1] subgroup（shfl/vote/ballot）を使う、[2] LDS を使う、[3] atomic を使う、[4] systolic array（rq）を使う（予約）、[5] reserved）
word 4  code_words（64 bit 命令の数 × 2）  word 5  code_offset（header の先頭からの word 数、= 16）
word 6  nregs（使う r の最大 + 1 ≤ NREGS） word 7  lds_bytes
word 8  wg_size（x | y << 8 | z << 16）    word 9  const_words（c0.. の使う数）
word 10 iface_offset（interface の表の word の位置、= 16）  word 11 iface_entries（表の entry の数）
word 12 entry（code の中の命令の index）   word 13 isa_min_version（1）
word 14 push_bytes（push constant の byte 数）  word 15 reserved（0）
word 16〜 interface の表（entry ごとに 4 word: kind（1 頂点の属性、2 varying の入力、3 出力、4 uniform block、5 sampled image、6 storage buffer、7 push constant、8 shared の大きさ）、set、binding か location、slot/register/offset/size（kind ごと: 属性 = 先頭の register | component << 8、uniform block = constant の領域の word の offset | size、sampled image = TU の slot、storage = constant bank の base の word（address と大きさを firmware がここに置く）、push = constant の word の offset））
code_offset〜 命令（8 byte 揃え）
```

- firmware（`program.c`）は magic・版・`nregs ≤ NREGS`・flags と `CAPS` の整合・`code_words`・interface の表（slot の数 ≤ CAPS2、constant の word ≤ 領域）を検査し、`GHCI_PROGRAM` の result に VkResult を書く。driver も compile の時に同じ検査をする（二重）。**interface の表が descriptor と program を結ぶ唯一の約束**（C1）: firmware は draw/dispatch の時に bound の descriptor set の (set, binding) をこの表で TU の slot・constant の領域の offset・storage の base に写し、`SET_REG`/`LOAD_CONST` にする。
- **native の ISA の直接の送信**: `GHCI_PROGRAM` の ISA の FourCC が `NATIVE_ISA_ID` なら binary の形は vendor の物（GHCI は magic と版の 2 word だけ決める: word 0 = vendor の FourCC、word 1 = 版）。driver は `NATIVE_ISA_ID` の backend を持つ時だけ送る。Amaterrace では native = GSI1 なので区別が無い。

#### 3.4.5 他の実装の CP-JIT（GHCI の規則）

- GHCI 1.0 の shader 付きの GPU は GSI1 の program を**必ず**受ける。native の ISA が GSI1 でない実装は、`GHCI_PROGRAM` で firmware が GSI1 → native に変換（JIT）して heap に置く（driver からは見えない。result で失敗を返せる: `VK_ERROR_INITIALIZATION_FAILED`）。変換の cache は firmware の物（識別子ごと）。
- JIT のために GSI1 が約束する事: (1) program は自己完結（header に register 数・LDS・入出力）、(2) 分岐の目標は命令の index で静的（間接分岐無し）、(3) 特殊 operand と `exp` の対象は番号で固定、(4) memory の model は「aperture の中の 32 bit の address、coherent でない cache、`fence` で順序」。
- Amaterrace は JIT をしない（hardware がそのまま実行）。

#### 3.4.6 他の GPU から取った物と出典の扱い

| 物 | どこに有るか（公開の文書の一般知識） | GSI1 での形 |
| --- | --- | --- |
| compiler が管理する exec mask、hardware の divergence stack 無し | AMD GCN/RDNA の EXEC、Arm Mali | `exec.*`、`bany`/`bnone` |
| 長い命令の宛先の scoreboard + 明示の wait の counter | NVIDIA（Volta 以降の dependency barrier）、AMD の `s_waitcnt` | 小さな hardware の scoreboard + `wait`（§3.1.1） |
| FMA の source の修飾（neg/abs）と飽和 | NVIDIA・AMD VOP3・Intel | word1 の n/a/sat |
| inline の定数と system の値を operand の番号で | AMD の inline constant、NVIDIA の SR | 特殊 operand 96〜127 |
| constant bank の operand | NVIDIA の `c[bank][offset]`、AMD の SGPR | `c0`〜`c31` + `lwc` |
| 16 bit packed（2 × fp16） | AMD VOP3P、NVIDIA HFMA2、Arm、PowerVR | custom-2 |
| quad の微分と swap | 全部 | `qd` |
| shuffle・vote・ballot | NVIDIA SHFL/VOTE、AMD DPP/permute、Intel | custom-1 `shfl`、custom-3 `vote`/`ballot`（optional） |
| texture の LOD/bias/fetch/size | 全部 | custom-1 |
| 超越関数の専用 unit | NVIDIA MUFU、AMD `v_exp_f32` 等 | custom-3 の 011 |
| block floating point（行ごとの共有の指数、版 4） | Microsoft MSFP、OCP MX の一般知識 | Appendix A.2（延期） |
| online softmax（running max と rescale した running sum、版 4） | Milakov & Gimelshein 2018（arXiv:1805.02867）の一般知識 | Appendix A（延期） |
| Welford の逐次の分散と Chan の合わせ（版 4） | 一般知識（Welford 1962、Chan et al. 1979） | Appendix A（延期） |
| LDS・barrier・atomic | 全部 | custom-0 |

- **出典の扱い**（Guardrail「MIT・GPL の出典のデータの引用」）: GSI1 は公開の ISA の文書の**一般的な知識**（命令の種類と意味）から設計し、他の GPU の opcode の値・field の位置・名前は写さない。RISC-V の opcode の値と field の位置は RISC-V の仕様（CC-BY 4.0 の文書。値は事実）から取り、`gsi1_isa.h` の該当 block に「Values referenced: The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA, version 20240411, chapter "RV32I Base Integer Instruction Set" (opcode map), "M", "F", "Zfa", "Zbb"」と**版を含めて**書く（Guardrail、L10）。gpu-op の番号を firmware と `docs/ghci.md` が使う所は「Values referenced: zedBSD include/uapi/gpu-op.h（が引く venus-protocol の XML、commit ca19b635…）」。code・comment・構造は写さない。zedBSD の driver と amaterrace-gpu の両方 Zlib。**商標**（推測の懸念、L10）: RISC-V は RISC-V International の商標なので、GSI1 は「RISC-V 互換」を名乗らず、文書では「RISC-V の 32 bit の形を基にした独自の ISA」とだけ書く。

### 3.5 unit の内部と register file（U12）

- **register file の大きさ** = 32 lane × NREGS × NWARPS × 32 bit × 複製の数。3 つの source を同じ cycle に読むために **同じ内容を 3 つ複製**（各複製は BRAM の 2 port の 1 つを書き込み、1 つを読みに）。lane の bank は物理の lane ごと（NPHYS 個）で、1 つの bank が `32/NPHYS` 個の architectural な lane を持つ。候補:

| 構成 | NREGS | NWARPS | bit（×3 複製） | BRAM36（SU 1 つ、NPHYS 8〜16） | 板での意味 |
| --- | --- | --- | --- | --- | --- |
| A | 32 | 4 | 393 Kbit | **12** | 7010 の推し |
| B | 32 | 8 | 786 Kbit | 24 | 325T の候補（latency を隠す warp が多い） |
| C | 64 | 4 | 786 Kbit | 24 | 325T の推し（compiler の register の圧力が楽、N = 8 で 192 = 43%） |
| D | 64 | 8 | 1.57 Mbit | 48 | 325T で N = 8 だと 384（445 の 86%）。N = 4 なら可 |

  NPHYS = 32 では bank が 1 lane 分（NREGS × NWARPS word = 128〜512 word）で BRAM18 の最小の深さ（512 × 36）を下回り、**BRAM の数が 2 倍になる**（32 bank × 3 複製 = BRAM18 × 96 = BRAM36 × 48）。推し: **7010 は A、325T は C（NPHYS 16）**。複製を 2 つに減らす案（src2 を 1 cycle 遅れて読む）は p008 で LUT と BRAM を測って決める。
- **書き込み port の調停**（複製ごとに 1 本）: 優先は (1) ALU の書き戻し（毎 cycle NPHYS lane）、(2) LDG/LDC/TEX/超越/除算の戻り（戻りの FIFO に貯め、ALU の書き戻しが無い cycle か、issue を 1 cycle 止めて書く）、(3) VF/RX の入力（warp の slot が空の時だけ書くので競合しない）。
- **scheduler**: 毎 cycle、`ready` な warp を round-robin で 1 つ選び、`32/NPHYS` cycle 占める。pipeline は fetch（I$）→ decode → RF 読み（1）→ 実行（1〜6）→ 書き戻し。同じ warp の連続の発行は dst の依存を interlock。
- **I$**: 2 KiB（256 命令、32 byte line の direct map）。**D$**: 1 KiB（32 line、direct map、write-through、valid の flash clear で無効化）。coalescer: 32 lane の address を line ごとにまとめる（`32/NPHYS` cycle に分けて比較）。**LDS**: 4 KiB（BRAM36 × 1）、KC705 は 16 KiB。**constant bank**: 256 word（BRAM18 × 1）。
- **PT（post-transform の buffer）**: 32 頂点 × (4 + 32) word = 1152 word（BRAM36 × 1.3 → 2）。**p030 S13（2026-10-25）で KC705 は 4 + 64 word**（Vulkan 1.0 の 64 component。PT は NPHYS 16 の bank ごとに 4 × 68 word で BRAM18 × 1 のまま、推定）。vertex の warp は **PT に 32 頂点分の空きを予約できた時だけ**始まる（§3.8）。
- **primitive table**: NWARPS × 8 primitive × 3 頂点 × 36 word（NWARPS 4 で 3456 word = BRAM36 × 4）。`LDA` は 1 cycle に NPHYS/4 個の primitive を読むので、**table を NPHYS/4 複製**（NPHYS 8 で 2 複製 = BRAM36 × 8、NPHYS 16 で 4 複製 = 16。§3.6 に入れた）。varying を 16 word に絞る ZYBO の構成は半分。**p030 S13（2026-10-25）で改めた**: table は varying の word だけ（position の 4 word は RX が写さないので持たない）、KC705 は 64 word、複製は min(NPHYS/4, 2)、同期の読み（BRAM）で 1 つの lane group を NR = NPHYS/4/複製 cycle（NPHYS 16 で 2）に分けて読む（`atg_su_lda` の x_ready が後の cycle で 0）。KC705: 4 × 8 × 3 × 64 = 6144 word × 2 複製 = SU ごとに BRAM36 × 12（推定、旧 16）。
- **超越・除算の unit**: unit に 1 本ずつ。`RCP/RSQ` は table（BRAM18 × 1）+ Newton 1 段（DSP × 2）、`EXP2/LOG2/SIN/COS` は範囲の縮小 + 多項式（DSP × 4）。

### 3.6 大きさ（LUT/FF/BRAM36/DSP）の見積もり — **推定**、内訳から計算し直した（版 2）。実測で置き換える

- **2026-10-24 ユーザー（FP16 だけの GPU の話の後）「了解です。そのまま勧めましょう。」→ KC705 の SU は案 A: fp32 は FPU の少ない lane（例: NPHYS 8 の SU に FPU 1〜2 lane、32 lane を順に流す）、fp16 の packed の演算（PACKED）は全 lane。Vulkan の fp32 の正しさは保ち、速さを fp16 に寄せる。案 B（頂点の変換は VF/RX の固定の回路で fp32、SU は fp16 を主に）は合わせて検討。FPU の lane の数は p012〜p015 の合成で決める。** 測った根拠: ZYBO の構成（NPHYS 8）で SU 70,735 LUT のうち FPU 39,281（1 lane ≈ 4.9k、組み合わせの fp32。乗算はほぼ DSP、LUT は shifter・正規化・丸め）。
- **2026-10-24 ユーザー「FP32は全laneでいいと思います。」→ 直前の案 A（fp32 は FPU の少ない lane）を改める: KC705 の SU は fp32 の FPU を全 lane に持つ（NPHYS 分）。fp16 の packed（PACKED）も持つ。SU の数・NPHYS は KC705 の合成で決める。**

版 3 の追加（推定、表には未反映。p008・p017 の実測で直す）: 64 bit の decode と scoreboard（§3.1.1）+0.4k LUT/SU、`shfl`/`vote`/`ballot` の staging RAM +0.5k LUT/SU（KC705 だけ、U27）、`atg_cpu` 2.5k LUT + DSP 1 + BRAM36 12（bitstream 1' と KC705。§2.4.7）。`atg_sa` は延期（Appendix A の sketch に資源の表）。

内訳（LUT）: fp32 の FMA は物理 lane あたり DSP 3 + **LUT 400**（正規化・丸め。版 1 の 250 は楽観。幅は 300〜700）、整数 ALU LUT 150、packed の fp16 LUT +150 + DSP 2。超越 1.5k + DSP 4、除算 0.3k、scheduler・decode・interlock・sequencing 1.8k、D$ と coalescer 1.5k、LDS/const/EXP/LDA/PT の制御 0.6k。固定の block: CP 1.8k、BLT 1.0k、VF 1.5k（instancing 入り 1.7k）、RX 3.3k（DSP 15）、ROP 1.5k（DSP 8。stencil 無しで 1.2k）、TU 2.2k（DSP 12。最近傍だけで 1.4k、DSP 4）、MC 1.5k、regs 0.4k。

| 構成 | 中身 | LUT | BRAM36 | DSP | 7010 の % | 判断 |
| --- | --- | --- | --- | --- | --- | --- |
| 固定の block 全部（KC705 の形） | CP+BLT+VF+RX+ROP+TU+MC+regs | **13.4k** | 12 | 35 | 76% | SU 無しでも 7010 の 3/4 |
| SU、NPHYS 8、A、packed 無し | 8×550 + 1.5k + 0.3k + 1.8k + 1.5k + 0.6k | **10.1k** | 12 RF + 1 I$ + 1 D$ + 1 LDS + 0.5 const + 2 PT + 4 prim(16 varying、2 複製) ≈ 22 | 24 + 4 + 2 = 30 | 57% | — |
| SU、NPHYS 4、NWARPS 2、A' | 4×550 + 1.5k + 0.3k + 1.5k + 1.2k + 0.5k | 7.2k | 6 + 1 + 1 + 1 + 0.5 + 2 + 2 ≈ 14 | 12 + 6 = 18 | 41% | — |
| ZYBO 全部（NPHYS 4、TU 最近傍、stencil 無し） | 13.4k − 0.8k − 0.3k + 7.2k | **19.5k** | 26 | 45 | **111%** | **入らない** |
| **ZYBO bitstream 1「2D」** | CP+BLT+MC+regs | 4.7k → **実測 3,802 LUT・3,719 FF・BRAM 0.5・DSP 0、WNS +0.190 ns @100 MHz**（p003、2026-10-23。BLT だけで 2,727 LUT: 推定の 1.0k は小さすぎ、CP+MC+regs は推定の 3.7k に対し約 1.1k） | 5 → 0.5 | 0 | 22% | p003 cleared・p004 |
| ZYBO bitstream 1 の **実測**（p002、Vivado 2026.1、xc7z010clg400-1、配線後） | CP の stub（ring 無し）+ BLT の骨（32 bpp の FILL/COPY、clip）+ MC（client 2）+ regs | **2.45k**（regs 0.28k、CP 0.60k、BLT 1.39k、MC 0.17k）、FF 2.63k | 0.5（STATE の BRAM18） | 0 | 14% | 100 MHz で WNS +0.473 ns。[phase002](phase002/phase.md) |
| **ZYBO bitstream 2「DC」** | DC（regs、dma、tgen、VGA/TMDS、I2C 無し） | 2.0k | 3 | 0 | 11% | p005 |
| **ZYBO bitstream 3「raster」** | CP+MC+regs+RX+ROP（stencil 無し）+ VF（DRAW_RAW だけなら VF 無し） | 8.2k（VF 入り 9.9k） | 7 | 23 | 47〜56% | p007 |
| **ZYBO bitstream 4「compute」** | CP+MC+regs+SU（NPHYS 8、A） | 13.8k | 27 | 30 | **78%** | p008。閉じなければ NPHYS 4（10.9k、62%） |
| ZYBO「graphics + SU」（NPHYS 4、TU 無し、VF 入り） | 9.9k + 7.2k | 17.1k | 21 | 41 | 97% | **当てにしない**（p009 は Verilator と KC705） |
| KC705 unit（NPHYS 16、C、packed） | 16×700 + 1.5k + 0.3k + 1.8k + 1.5k + 0.6k | 16.9k | 24 RF + 2 + 1 + 4 LDS + 0.5 + 2 + 16 prim（4 複製）≈ 50 | 80 + 6 = 86 | — | — |
| KC705 N=4 | 4 × 16.9k + 13.4k + MIG 10k + PCIe/XDMA 8k + DC 2k + JTAG 0.3k | **101k（50%）** | 200 + 12 + 4 + 16 + 3 = **235（53%）** | 344 + 35 = **379（45%）** | 325T | 最初の目標 |
| **KC705 N=6**（版 3 の板の目標、M17） | 6 × 17.8k（SU + decode/scoreboard 0.4k + shuffle 0.5k）+ 13.4k + MIG 10k + XDMA 8k + DC 2k + JTAG 0.3k + RX 2 本 3.3k + `atg_cpu` 2.5k + `atg_sa` 10k | **156k（77%）** | 300 + 12 + 4 + 16 + 3 + CPU 12 + SA 4 = **351（79%）** | 6 × 86 + 35 + CPU 1 + SA 256 = **808（96%）** | 325T | **版 4 の最後: SA 無し、CPU 付き**（SA は延期）: LUT 146k（72%）、BRAM 347、DSP 552（66%） |
| KC705 N=8 | 8 × 17.8k + 上 + CPU + SA | **192k（94%）** | 435 + 16 = **451（> 445）** | 723 + 257 = **980（> 840）** | 325T | **入らない**（M17）。SA 無し・RF の複製 2 でも BRAM が限界。N=8 は SA 無しの構成として p015 で実測 |

- **p030 S13（2026-10-25、推定）**: KC705 の primitive table を 64 varying word・複製 2（§3.5）にして、SU ごとの BRAM36 は prim 16 → 12（6144 word × 2）、PT は BRAM18 × 16 のまま。N=6 の BRAM36 の見込みは 347 → 323（445 の 73%）。表の KC705 の行は直していない（旧の内訳のまま）。実測は `make oxc-core`（T、KC705 の SU の parameter を `CORE_PARAMS` で）。
- 結論（R1・U17）: **7010 では GPU の全 block を 1 つの bitstream に載せない**。block ごとの bitstream で workflow と各 block を板で確かめ、全体の結合は Verilator と KC705。KC705 は **raster/compute 構成だけ**（版 4 の最後: N=4 から始めて N=6、CPU 付き。SA は延期で KC705 に入らなくてよい、§3.9）。N=8 は BRAM が限界で p015 の実測で決める。
- p002 の実測（2026-10-23、[phase002](phase002/phase.md)）で直す係数: **BLT は 1.0k → 1.4k**（32 bpp の FILL/COPY と clip だけで 1.39k: 2 line の buffer と word 単位の shifter が大半。16 bpp・blend・tile を足した p003 の実測は **2.73k**（§3.6 の bitstream 1 の行））、**MC は 2 client で 0.17k**（そのうち AXI master が 0.15k。client の間の mux は合成の最適化で BLT の側に吸収されて分けて測れない。1 client あたり line 幅の wdata の mux が要るので **推定** で 32 byte の line で約 0.1〜0.15k/client、N=8 の 22 client で 2.5〜3.5k。版 2 の 1.5k は少なめの恐れ。p015 で測る）、**regs 0.4k → 0.3k**、**CP は stub で 0.6k**（ring・fence・状態遷移の全部は p003・p004 で測る。1.8k は据え置き）。BRAM は 5 の見込みに対して 0.5（MC と BLT に FIFO の BRAM が無い）。bitstream 1 の全体は 4.7k の見込みに対して 2.45k（CP を 1.8k にしても 3.7k、21%）。SU の係数は p008 の最初の合成で直す。

### 3.7 board ごとの parameter と Vulkan の limit

| | ZYBO（bitstream 4 の SU） | KC705 |
| --- | --- | --- |
| NSU / NPHYS / NWARPS / NREGS | 1 / 8 → 4 / 4 → 2 / 32 | 4 → 6〜8 / 16 / 4 / 64 |
| LINE_BYTES / AMB_W / AXI3 | 32 / 64 / 1 | 64 / 512 / 0 |
| I$ / D$ / T$ / LDS / const / varying | 2 KiB / 1 KiB / —（TU 無し）/ 4 KiB / 256 word / 16 word | 2 KiB / 1 KiB / 4 KiB / 16 KiB / 256 word / 64 word（p030 S13。旧 32） |
| TU_BILINEAR / ROP_STENCIL / PACKED | — / 0 / 0（**U15**: README の「16-bit packed」からの逸脱。`PACKH/UNPACKH` は有る） | 1 / 1 / 1 |
| gclk | 100 MHz | 100 → 150 MHz（版 9: §19 の推しは gclk 100 MHz・SU の sclk 200 MHz、U100） |

**Vulkan 1.0 の最小の limit と v1 の未達（driver が報告する値。libvulkan の N1・N2 と同じ「規格に合わない点」として記録し、U8 の app が要る物から足す）**:

| limit / 機能 | Vulkan の最小 | v1 | 備考 |
| --- | --- | --- | --- |
| maxVertexInputAttributes | 16 | 16 | 版 2 で 8 → 16 |
| maxVertexOutputComponents・maxFragmentInputComponents | 64 | 64（64 word）KC705 / 16（16 word）ZYBO | 1 word = 1 component。旧版の「128（32 word）/ 64（16 word）」は誤り（32 word は 32 component）。KC705 は p030 S13 で 32 → 64 word。ZYBO は未達 |
| maxPerStageDescriptorSamplers / SampledImages | 16 | 16 | 版 2 で 8 → 16 slot |
| maxComputeWorkGroupInvocations | 128 | 128（NWARPS 4）/ 64（NWARPS 2、ZYBO）| ZYBO は未達 |
| maxComputeSharedMemorySize | 16 KiB | 16 KiB / 4 KiB（ZYBO） | ZYBO は未達 |
| mip の段 | 4096 で 13 | 13 | 版 2 で offset を 12 個に |
| instancing（instanceCount・firstInstance・vertexOffset・per-instance） | 必須 | 有り | 版 2 で VF に足した |
| indirect の draw/dispatch | 必須 | **無し** | driver が `ENOTSUP`。v2 で CP に `DRAW_INDIRECT`（memory の引数）を足す |
| cube / 3D / array / gather / compare の texture | 必須（cube・array） | **有り**（p009 part E・F、2026-10-25 02:53。GHCI §8.4・§12.9） | multisample の sampled image は p027 |
| multisample（4x の framebuffer と sampled image、resolve） | 必須（1 と 4） | **p027 で足す**（版 5） | §15。sampleRateShading は無し（U43）。この表の texture・format の行は p009 part E・F で変わった（cube・3D・array・compare は part E・F、正は amaterrace-gpu の README と ghci.md §8.4） |
| geometry / tessellation | optional | 無し | |
| spill（register の溢れ） | — | **拒む** | NREGS 32 の ZYBO で多い（R8） |
| texture の format | 多数 | RGBA8/BGRA8 だけ | |
| queue | 1 以上 | 1（graphics+compute+transfer の 1 family） | |

### 3.8 統一 shader の deadlock の回避、ROP の順序、clip（版 2 で追加）

- **warp の slot の予約**: SU の NWARPS の slot のうち **少なくとも 1 つは fragment の warp 専用**（`NWARPS_FRAG_RESERVE` = 1、KC705 は 2）。vertex の warp は残りの slot にだけ入る。
- **PT の予約**: VF は vertex の warp を始める前に PT に 32 頂点分の空きを予約する（予約できなければ VF は待つ: RX が PT を消費すれば空く）。RX は PT の三角形を primitive table に写し（clip を含む）、fragment の warp を出し終えたら PT の entry を返す。fragment の warp は ROP に出し終えたら slot を返す。環: VF → SU(vertex) → PT → RX → SU(fragment) → ROP → MC。**ROP は MC の書き込みの受理だけに依存し、MC は ROP を優先する**ので ROP は必ず進む → fragment の slot が空く → RX が進む → PT が空く → vertex の warp が進む。deadlock 無し。
- **頂点の再利用**: v1 は index の再利用の cache を持たない（同じ index は再び shade する）。post-transform cache は p015 の後。
- **ROP の順序**: RX は fragment の warp に **連番**（primitive の順）を付け、ROP は連番の順に退かせる（reorder の scoreboard: NWARPS × NSU entry。早く終わった warp の EXP の data は SU の出力 buffer（warp の slot に付属）に留まり、ROP が受けるまで slot を返さない）。複数の RX（p015）は画面を帯で分け、帯ごとに連番を持つ。
- **clip**: 近平面だけ geometric に clip（1 → 1〜2 三角形）。clip で生まれた頂点の varying は RX が補間して primitive table の新しい entry に書く（VARYING_COUNT 個の lerp、逐次）。遠平面は depth clamp、x・y は guard band（16.8 の固定小数の範囲）。barycentric は **元の 3 頂点に対して**（clip の頂点も元の頂点の線形結合なので、fragment から見れば一貫する）。provoking vertex は `PROVOKING` の規則で primitive table の頂点 0 に置く。

### 3.9 systolic array（SA）と SU の大まかな整合（版 4。**SA の設計と実装は延期**: 詳細は末尾の Appendix A の sketch）

ユーザー（2026-10-23）:「SAの設計と実装はかなり後に回して、SUがきちんとISAを実装できてからにします。SUとSAで大まかな整合性を持たせて設計を進めるのみにします。SAはKC705に入らなくてもいいです。」（それ以前の決定: 版 3 の「register 1 つを FIFO に予約」「SA は SU と decoupled、重みは MC から stream」、版 4 の「FP16/INT8 の mixed precision」「online の softmax/LN」「SIMD-8 はやめる」「案 B で SA に寄せ、SU は最小」）

この節が **今の計画の中で守る物**（SU の実装 p008〜p010 が SA と食い違わないための約束）は次の 5 点だけ。他（BFP の数値の規則、stream-out の順、tag、reduction/normalize の段、token buffer、資源、cycle の例、KC705 の SA 構成）は Appendix A の sketch で、SU が GSI1 を実装した後（trigger: p008・p009・p010 が cleared）に設計し直す。

1. **GSI1 は operand 番号 63 を FIFO の口 `rq` として予約する**（U28）。GPR は r0〜r62（NREGS 32 の構成でも 63 は `rq`）。dst に書くと push、source に読むと pop。空の pop・満の push は **発行の段でその warp だけ止まる**（scoreboard の entry は使わない。class a・f の命令の operand にだけ使える。class m・t・x の dst と、暗黙の連続の register が 63 に掛かる物は ISA の fault）。SA の無い構成（v1 の全部）では `rq` を使う命令は ISA の fault（種別 8）。SU の実装（p008）は **`rq` の番号を GPR に割り当てない事と、operand の decode に `rq` の口（発行の段の stall の信号 1 対）を残す事**だけを満たす。
2. **entry = SA の 1 本の vector（行 = token ごとに 1 値）**。幅と型（32 × FP16 = 64 byte か 32 × 32 bit = 128 byte か）、32 lane の warp の push/pop が 1 entry か 2 entry かは SA の設計で決める（Appendix A の案は 32 × FP16、2 entry、偶奇の対）。SU の側はどちらでも `NPHYS × 32 bit` の口で済む。
3. **SA は SU と decoupled な unit**（`atg_top` の兄弟。SU に 1 対 1 で結ぶ）。SA の中に PE の配列（SIMD 1）、重みと scale を **MC から stream する client**、SU との in/out の FIFO、CP からの制御（STATE の `SA_*` 0x1B0〜0x1BF は予約、`DISPATCH` の flags[1]、`STATUS[7] SA_BUSY`、`CAPS[25] SA`、extended capability `SA` id 7 の 0x140〜0x14F は予約）。SU の側に SA の制御は `sactl`（custom-3 funct3 110、sub で対象）と特殊 operand 120 `qstat`・121 `sastat`・122 `qtag` の **番号の予約**だけ（意味は Appendix A の案。v1 の SU は fault）。
4. **案 B の構成**（ユーザー「案BでSAに寄せましょう。SUはミニマルな形にしましょう」）: online の reduction（softmax の running max と rescale した running sum、layer norm の Welford）は **SA の出口の段**で、normalize（`exp2(x − m)·(1/s)`、`(x − mean)·rstd·γ_j + β_j`）は **SA の入口（折り返し）の段**で、1 列/cycle。生の x は SA の側の buffer か memory に。**SU は指揮だけ**（tile の順、address、tag、確定の合図 = `sactl` の列）。したがって **GSI1 に SA のための命令は増やさない**: packed FP16 の超越（版 4 の最初の案）は取り下げ（custom-2 の funct7 4〜7 と `CAPS[26]`、header の flags[5] は reserved）、subgroup の `shfl`/`vote`/`ballot` は optional のまま（`CAPS[24]`）、packed FP16 の演算は graphics のため（U15 のまま）。
5. **KC705 の計画は raster/compute 構成だけ**（§3.6。SA の bitstream と 325T の DSP の割り当ては計画から外す。SA は KC705 に入らなくてよい）。ZYBO にも載せない。

- **README の「Systolic Array: 32 x 32, 0.8 TOPS/SU @200MHz」**（a217bf8）: U39 の答え（ユーザー「積和を 1 回 2 op と数えた上で 2 倍にしてます」）= 32 × 32 MAC × 2 op × 200 MHz × 2 = 0.82 TOPS。×2 の根拠は未記載（推測: PE あたり 2 MAC/cycle、例えば INT8 の積を 2 つ）。README はそのまま。**延期した SA の設計はこの ×2 を満たす形（PE あたり 2 MAC/cycle など）にする**（Appendix A の sketch は 1 MAC/PE/cycle で 0.41 TOPS なので、再設計の時に合わせる）。
- **Phase**: SA の p020（core）・p021（Vulkan の経路）・p022（SA 構成と online の経路）は **Future Work**（§8 の末尾。trigger「SU が GSI1 を実装した（p008〜p010 cleared）」。番号 p020〜p022 は予約のまま）。§7.6 の module の木の SA の module は、p023 では **`atg_sa` の top の port だけ**を予約の形で置き（中身の module の spec は延期）、`atg_su` の `rq` の口の port を spec に書く。
- **zedBSD の側**: v1 の driver・compiler は `rq`・`sactl` を出さない（IR に無い）。SA の Vulkan の経路（独自の拡張 `VK_KEI_systolic_dispatch` の案、§6.10）も延期。

## 4. MC（Memory Controller）の抽象と host link

### 4.1 AMB（Amaterrace memory bus）と `atg_mc`

- **line は `LINE_BYTES`（32 か 64）**: ZYBO は 32（HP の 64 bit × 4 beat）、KC705 は **64**（MIG の AXI4 512 bit = 64 byte × 1 beat、DDR3 の BL8 × 64 bit = 64 byte と同じ。32 では帯域が半分になる）。client 側の口は 1 line 丸ごと: 要求 `{valid, write, addr[31:log2(LINE)], be[LINE−1:0], wdata[8·LINE−1:0], tag[7:0], ready}`、応答 `{valid, tag, rdata, error}`。cache の line と texture の tile（4×4 × 4 byte = 64 byte）は `LINE_BYTES` に合わせる（32 なら tile は 2 line）。atomic は別の小さな口 `{valid, op[3:0], addr[31:2], a, b}` → `{valid, old}`（MC の中の 1 本の read-modify-write の unit で直列に）。
- `atg_mc`: client の数 ≤ **32**（N=8 で CP、BLT、VF、SU × 8 × 2（D$、I$+const）、TU、ROP、DC = 22。`FAULT_INFO` の client は 8 bit）。arbiter は固定の優先の group（1: DC、2: CP の fence・ROP、3: 他は round-robin）。同じ client の要求は順序を守る。応答は tag で返す。**aperture の検査**はここで全 client に対して行い、外れた要求は実行せずに `error` を返して `FAULT` を立てる。quiesce と flush は §1.3。将来の MMU はここに入る。
- **client の木（router の tree、2026-10-23 ユーザー、p023 milestone 4 で実装）**: ユーザー「2分岐くらいのルーター（RT）を配置できませんか？N乗の規模のセレクタを入れるよりも合成しやすく、ASICでもルーティングしやすいからです。」「atg_rtという名前でモジュールを作って、インスタンスを並べるのがいいかなあと思います。VRAMとしてアクセスできる範囲を絞るなら、32bit未満のアドレス配線でもいいかなと思いますし、ルーティングするならデータとアドレスで共有してNoC的にしてもいいと思います。本格的なNoCじゃなくて、そのエッセンスを採用したルーティングですね。ルートがMCで、DCが根元にあって優先される必要がありますね。」→ 上の flat な arbiter を置き換えた（amaterrace-gpu の `spec/gpu/mc/atg_mc.md`・`atg_rt.md`・`atg_mc_tree.md`・`spec/common/am_amb_to_rt.md`）:
  - client ごとの leaf（`am_amb_to_rt`。client の AMB の口は変えない）が要求を flit の packet にする: header の flit（優先の bit、write、window の外、tag、client の番号、route、VRAM の window の中の line、byte enable）と、write なら data の flit 1 つ（line 全部）。address と data は 1 本の channel を共有する。応答は 1 flit（write、error、tag、route、line）。応答を 1 flit にしたのは、AXI master の応答が待てない（back-pressure が無い）ので、header と data の 2 flit にすると read の帯域が半分になるため。
  - `atg_rt`（2 分岐）を `generate` で完全 2 分木に並べ、根が MC の root（aperture・window の検査と `am_axi_master`）。**1 hop に 1 段の register**（要求・応答の両方向）。要求は packet の境で 2:1 の調停: header の優先の bit が勝ち、同じなら交互（router ごとの round-robin）。packet の途中は lock（packet を混ぜない）。応答は route の bit（router の段ごとに 1 bit）で 2 つに分ける。
  - **DC は根元**: `ROOT_CLIENT`（KC705 の DC = `atg_top` の `C_EXT`）は最上段の router の child 0 で、MC から 1 hop。優先の bit は `HIGH_MASK`（CP と DC）。他の client は child 1 の部分木（深さ `TREE_L` = clog2(client 数)）。
  - **address の幅**: `VRAM_AW`（< 32 で VRAM の window に絞る。ZYBO の 64 MiB なら 26）の offset だけを木に流し、root が `VRAM_BASE` を足す。window の外の address は leaf が印を付け、root が aperture の fault にする（`FAULT_ADDR` は VRAM_BASE + 下位の bit）。
  - **latency**: 要求・応答とも `TREE_L`（DC は 1）cycle 増える（KC705 の 22 client で 5、ZYBO の 2D の 2 client で 1）。以前の flat な arbiter は 0 cycle。throughput は root で read 1/cycle、write は 2 flit なので 1/2 cycle（ZYBO の HP は 1 line = 4 beat なので影響無し、KC705 の 512 bit の MIG では write の peak が半分。必要なら後で要求の flit を広げる）。
  - **公平性**: 優先の bit の client は経路の各 router で勝つので、待つのは経路の register に入っている packet だけ。他は router ごとに交互なので、全 client が常に要求を出すと深さ d の leaf は root の packet の 1/2^d を得る（均衡の木なので、負荷が同じなら公平）。優先の client が常に要求すると、同じ router の他方は飢える（DC の場所の意図どおり）。
  - 順序: 1 client の経路は 1 本なので要求・応答の順序は保たれる（read 同士・write 同士。read と write の間は従来どおり保証しない）。quiesce は root が grant を止める（要求は木の register で待つ）。`axi_idle` は AXI master が idle で、木の応答の register も空の時。flush は木と root を空にする（CP の RESET で client も同じ cycle に reset される）。
  - 資源（**推定**、未合成）: 1 hop は 1 方向あたり約 line + 30 bit の FF。KC705（512 bit の line、32 router）で約 34k FF（325T の 8%）、ZYBO の 2D（1 router）で約 0.6k。Vivado の実測で直す。
- `am_axi_master`: AMB の line を AXI の burst にする（AMB_W = 64 なら INCR 4 beat、512 なら 1 beat）。parameter `AXI3`（AxLEN 4 bit、`WID`、burst ≤ 16）。outstanding は read 4・write 4。`SLVERR/DECERR` は `error`。quiesce の「新しい発行を止める・応答を待つ」はここ。
- ZYBO: HP0 は AXI3 64 bit（**HP の AXI3 の WID と 64 bit の WSTRB、FIFO の深さは UG585 を読んで p002 で固定する（未確認）**）。GP0 の slave は plio と同じ。**PS の DDR は CPU の cache と coherent でない**（WS286 §3.12）ので、driver は GPU の memory を uncached で扱う（§6.3）。
- KC705: MIG 7 Series（Vivado の IP、`mig.prj` の preset、AXI4 の slave 512 bit、`ui_clk` 200 MHz、DDR3 1 GB）。`am_axi_master`（AXI3 = 0、512 bit）を MIG の AXI4 に直結。`init_calib_complete` を `STATUS.MEM_READY` に。MIG の設定は TCL の `create_ip` で再生成し、生成物は repository に入れない。

### 4.2 DC の memory の口

- ZYBO: DC は `S_AXI_HP1` を自分の `am_axi_master`（read だけ）で読む。GPU と DC が別の bitstream なので共有の問題は無い。
- KC705: 1 つの `atg_mc` の client（`C_DC`、優先）として読む。line の FIFO（2 行）が有れば優先だけで足りる。**版 8（§18、p035 D2b で実装）**: `C_DC` は root の自分の入口（`ROOT_KEEP`、PROT の有無に依らない）を持ち、`QUIESCE_EXEMPT` に入り、CTRL.RESET の flush は C_DC の leaf・入口・誤りの応答を残し、`axi_idle` は DC の要求を待たない（scanout は GPU の HALT・FAULT・reset を跨ぐ）。

### 4.3 KC705 の host link（案と推し）

| 案 | 中身 | 利点 | 欠点・risk |
| --- | --- | --- | --- |
| A. **PCIe の endpoint → x86 の zedBSD** | Vivado の「7 Series Integrated Block for PCI Express」（無償）+ 「DMA/Bridge Subsystem for PCIe（XDMA）」（無償）。BAR0 = HCR + DC（128 KiB、AXI-Lite）、BAR1 = GPU の DDR3 への窓（64 MiB）、DMA は XDMA の H2C/C2H、割り込みは MSI。zedBSD の側は `nvrtx` と同じ `drv_pci_driver_register` + BAR の map + `drv_pci_device_allocate_irqs`。**PCI の照合は class code**（0x038000: display controller、other）+ BAR0 の `GHCI_MAGIC` の読み（vendor/device の組の固定ではない。AHCI の class code の照合と同じ）。Amaterrace の subsystem は "AT"/"G1" | 既存の amd64 の zedBSD と PCI の枠組み。host の CPU が速い | 板を PC の x8/x16 slot に挿す（**U2**）。**FPGA を書き直すと PCIe の link が落ちる** |
| A'. **PCIe + Linux の host + VFIO で QEMU の zedBSD の guest**（**推し**） | 板を Linux の PC に挿し、`vfio-pci` で QEMU の amd64 の zedBSD の guest に渡す。FPGA の書き直し: guest を止め → host で `remove` → JTAG → root port の **secondary bus reset** → `rescan` → guest を起動。**電源投入の時に FPGA が未設定だと BIOS が BAR を割り当てない**（経験則、未確認）ので、(a) KC705 の linear（BPI）flash に bitstream を書いて電源投入で設定する（100 ms 以内の設定の規則）か、(b) host の kernel に `pci=realloc`（と bridge の窓の予約）。手順は `plan/tools/kc705/pcie-reload.sh` に | zedBSD の driver は A と同じ code。rescan と再起動の問題を Linux の host が吸収。T1 の既存の QEMU の運用に載る | VFIO の IOMMU の group の分離（chipset に依る）。DMA の address は guest の物理（IOMMU が翻訳。XDMA は 64 bit の address） |
| B. **soft CPU sukuna-risc + zedBSD の移植** | ユーザーの CPU を 325T に載せ、zedBSD を移植し（RISC-V なら BSP）、GPU を内部の AXI で繋ぐ | 板だけで完結。将来の形 | sukuna-risc の完成と zedBSD の移植が GPU の前に要る。GPU の bringup が CPU に直列 |
| C. **既存の soft RISC-V（VexRiscv 等、Sv32）+ riscv32 の BSP** | MMU 付きの RISC-V の soft core（MIT） | B より早い | 外部の core の導入。遅い CPU で kernel の中の compile が遅い |
| D. **JTAG だけ**（HCR への bridge、§4.4） | OpenOCD の `drscan` で register を読み書き、DDR は `DBG_ADDR/DATA` | PCIe も CPU も無しで MIG・CP・BLT・DC・SU を板で確かめられる。**KC705 の最初の milestone の道** | 遅い。本番の道ではない |

**推し**: **D で KC705 の最初の milestone（MIG + CP + BLT + DC、SU の compute）を通し、本番は A'**。A' の PC はユーザーの判断（**U2**）。B は sukuna-risc の進み次第で後から足す。C は A' が使えない時の予備。MSI の vector の表（A/A'）: XDMA の user IRQ 0 = GPU の IRQ の線（**版 8（§18）で DC の event も GHCI の IRQ_STATUS [12:9] に入ったので、DC の別の vector は無い**）、XDMA の channel の IRQ（H2C/C2H）はその後の vector（driver は `drv_pci_device_allocate_irqs` で 4 本を取る。**XDMA の vector の割り当ての規則は PG195 未読で未確認**、p013 で読む）。

### 4.4 KC705 の JTAG の bridge（`am_jtag_regs`、GHCI の `DBG` capability）

- BSCANE2 の USER2（IR 0x03）に 72 bit の DR `{cmd[7:0], addr[31:0], data[31:0]}`: cmd 1 = write、2 = read（次の scan で data が返る）、3 = status。`tck` → `gclk` は `am_sync` の握手。`am_axi_regs` の第 2 の master として多重化。
- host の道具: `plan/tools/kc705/jtag-reg.sh read OFF | write OFF VALUE | mem-read ADDR | mem-write ADDR VALUE`（`DBG_*` の非同期の形: ADDR を書く → STATUS を poll → DATA を読む）。

## 5. DC（Display Controller、`atg_dc`、別の IP）

**版 8（§18、ws001-p035 で実装、2026-10-25）で置き換え**: KC705 の DC は GPU の unit（`rtl/gpu/dc/`、`atg_top` の子、board の reset の domain）。GHCI の capability は DISP2（id 11、窓は HCR の 0x200〜0x2FF、`atg_cp_disp` が host の write を CP の state で門にかける）。scanout の register は CP が RUNNING・HALTING の間は ring の µop DISP_SET・FLIP だけが書き、present は FLIP（copy しない）。DC の event は IRQ_STATUS [12:9]。mode の表・cursor の plane（plane 1）・CONNECTED は DC が持つ。下の §5.1〜§5.2 の KC705 の記述（+0x10000 の窓、DC の IRQ_STATUS/IRQ_ENABLE、host が FB_NEXT を書く flip）は版 7 までの物で、ZYBO の DC（DISP、id 1、CP の無い形）の記録として残す（ZYBO は 2026-10-24 に目標から外れ、RTL の `STANDALONE` は p035 D3 で消した）。

### 5.1 中身

- `atg_dc_regs`（AXI の slave）: ZYBO の DC だけの bitstream は **devcfg の固定の窓 `0x43C00000` の offset 0 に GHCI の header（0x000〜0x024 の 10 word: `DEVICE_ID` "ATDC"、`ISA_ID` 0、`CAPS` = [3] だけ、`EXTCAP` → `DISP` の entry が +0x200 を指す）** を置き、IRQ_F2P[0]（GIC 61）を使う。汎用の driver は `CAPS[0]` = 0（CP 無し）を見て ring・aperture・`MEM_READY` に触らず、display だけの device として attach する。KC705 は版 7 まで GPU の窓の +0x10000（`DISP` の entry が指す）だった。版 8 では DISP2 の窓（HCR の 0x200、§18.3）で、同じ device の display の ops になる（§6.5）。

| offset（DISP の register の先頭から） | 名前 | R/W | 中身 |
| --- | --- | --- | --- |
| 0x00 | DC_ID | R | `0x41544443`（"ATDC"） |
| 0x04 | DC_VERSION | R | |
| 0x08 | DC_CAPS | R | [0] VGA、[1] TMDS、[2] ADV7511、[7:4] 対応する format、[8] cursor（v1 は 0）、[11:9] mode の数（v1 は 2） |
| 0x10 | CTRL | RW | [0] ENABLE、[1] RESET（W1S）、[2] TEST_PATTERN、[5:4] FORMAT（0 BGRA8、1 RGBA8、2 RGB565）、[6] OUTPUT（0 VGA、1 HDMI） |
| 0x14 | STATUS | R | [0] running、[1] underflow（sticky）、[2] idle（ENABLE = 0 で DMA の outstanding が 0）、[15:4] 今の line |
| 0x18 | IRQ_STATUS | R/W1C | [0] VSYNC、[1] UNDERFLOW、[2] FLIP_DONE |
| 0x1C | IRQ_ENABLE | RW | |
| 0x20 | FB_BASE | R | 今 scan している framebuffer |
| 0x24 | FB_NEXT | RW | 次の vsync で取り込む（flip） |
| 0x28 | FB_STRIDE | RW | byte |
| 0x2C | FB_SIZE | RW | [15:0] w、[31:16] h |
| 0x30〜0x4C | H_ACTIVE/H_FP/H_SYNC/H_BP、V_* | RW | timing、`SYNC_POL`（0x50） |
| 0x54 | FRAME_COUNT | R | vsync の数（32 bit、DC の reset で 0。driver は 64 bit の software の counter に積む: display の `events` の sequence は 1 から始めて戻らない約束） |
| 0x58 | PCLK_SEL | RW | [0] 0 = 25.2 MHz（640×480）、1 = 74.25 MHz（720p）。BUFGMUX で `pclk`/`pclk5` の対を切り替え。他の mode は後に MMCM の DRP で |
| 0x60〜0x6C | I2C_CTRL/DATA/STATUS | RW | KC705 の ADV7511 の設定用の小さな I2C master（DC_CAPS[2] の時だけ） |

- `atg_dc_dma`: `FB_BASE` から 1 line ずつ読み、line FIFO（2 line、BRAM36 × 3）に積む。`ENABLE` = 0 で新しい要求を止め、outstanding が 0 で `STATUS.idle`（detach の quiesce、§6.2）。
- `atg_dc_tgen`: `pclk` で h/v の counter、`DE`・`HSYNC`・`VSYNC`。vsync で `FB_NEXT` を取り込み（`FLIP_DONE`）、`FRAME_COUNT`、`IRQ_STATUS.VSYNC`。
- 出力: **ZYBO VGA**（RGB 5-6-5 の抵抗の DAC。pin は Digilent の Zybo-Master.xdc から p005 で Values referenced）。**ZYBO HDMI**（TMDS、OSERDESE2、`TMDS_33`。720p の 742.5 Mb/s は **DS187 未読で未確認**: 640×480 から）。**KC705 HDMI（ADV7511）**: **UG810 未読で未確認**（pin の数、I2C の address、mux）。p012 の前に UG810（**U7**）。

### 5.2 zedBSD の側（§6.5）

- ZYBO（別々の bitstream）: DC は display だけの GHCI の device（`drv_gpu_display_ops` の query/mode/claim/release/present/wait/events、`scanout` の `query_device`/`constraints`/`import_image`（borrowed の physical pages を DMA の到達と cache の属性で検査: ZYBO は `gpu.mem` の領域の中の linear の image だけ受ける））。GPU の device は `share`（`export_resource`/`release`/`import_resource`/`get_scanout_backing`）を持つ。libvulkan の `VK_KHR_display` の WSI がそのまま使える。
- KC705: 1 つの device に display の ops も載せる（same-device scanout は普通の share の import で足りる、`gpu-scanout.h`）。版 8（§18.7、p035 D7）: driver（`display.c`・`display-scan.c`）は DISP2 を探し、点灯・消灯・present・cursor を ring の packet（DISP_SET・FLIP）で行い、record の page で取り込みを知る。route は SHARED（import の時に `GPU_IMPORT_SCANOUT` で判定）と COPY。

### 5.3 未確認の事と最初の確かめ

- ZYBO の HDMI の pin と bank、VGA の pin: Digilent の XDC を p005 で読む。KC705 の HDMI: UG810（U7）。
- 最初の確かめは `TEST_PATTERN`（memory を読まない）→ DDR の framebuffer（`DBG_ADDR/DATA` で塗る）。monitor の目視はユーザー（ユーザーの試験の一覧）。

## 6. zedBSD の側: 汎用の GHCI の driver、/dev の node、Vulkan の executor、compiler の backend、試験の道

### 6.1 置き場所と名前

- `src/drivers/gpu/ghci/`（prefix `ghci_`、Zlib、WS001 の範囲。**GHCI の汎用の driver**。版 3: Amaterrace に固有の code は無い。`isa/gsi1/` は GHCI の標準の ISA の backend）:
  - `ghci.c`（attach の共通: MAGIC/VERSION/CAPS の確かめ、EXTCAP の走査、`drv_gpu_register`、session の数の帳簿）、`zybo-attach.c`（PL の窓、§6.2）、`pci-attach.c`（KC705）、`hcr.h`（§2.2）、`packets.h`（§2.4。amaterrace-gpu の `include/ghci_packets.h` の写し、§7.2）。
  - `cp.c`（ring、doorbell、fence、IRQ の handler、状態遷移の driver 側、watchdog、fault の報告と reset）、`memory.c`（GPU の address の allocator: first-fit の区間の木、session の帳簿、遅延の解放の list と **回収の thread**）、`blit.c`、`native.c`（試験用、§6.4）、`state.c`（標準の state の word の組み立て）、`jobs.c`（§6.4 の jobs の ops）、`capset.c`。
  - `display/`（`display.c`・`display-irq.c`・`scanout.c`・`adv7511.c`）。
  - `isa/gsi1/`（§6.6）。backend は `struct ghci_isa_backend {fourcc, compile, release, limits}` の表で `ISA_ID`（と `NATIVE_ISA_ID`）から選ぶ。
  - `fw/`（版 3）: `CPFW` の載せ替え（`ghcictl fw-load`、root）と firmware の版の読み。blob の置き場は U21。
  - `vk/`（§6.7）。
- `/dev/gpuN`: **空いている最小の番号**（`gpu.c` 669〜686 行）なので、driver も道具も `gpu_info.driver_name`（"ghci:AMAT:ATG1"・"ghci-dc:AMAT:ATDC"）で選ぶ。
- ZYBO の PL の memory の pool: `src/drivers/platform/zybo/pl-memory.c`（新規。版 4、review 20: p003 以降は DTB の `/reserved-memory/gpu@1c000000`（64 MiB、no-map。`plan/ws001/tests/zybo-gpu-sd.dts`）が領域で、予約の page は `kern_pmem_alloc_limited` からは返らない。driver は node を名前で探し（`drv_fdt_child` で `/reserved-memory` の子 `gpu@…`。p006 で `compatible = "amaterrace,gpu-memory"` を dts に足して `drv_fdt_find_compatible` でも引けるようにする）、`struct kern_pmem {base, size}` を作って **`kern_pmem_map_uncached`** で uncached の alias を持つ（armv7 の `hal_pmem_map_uncached` は「RAM の bank の中で page 揃え」だけを検査し、窓は 256 MiB。**`kern_device_map(UNCACHED)` は使わない**: armv7 では RAM の bank の中なら cached の direct map の alias が返る（`src/hal/armv7/space.c`）。HAL の変更は無い）。`gpu.mem=` の boot parameter は reserved-memory が無い board の予備。**devcfg の寿命で、GPU の device と DC の device の両方が借りる**。`fpgaload` で block が入れ替わっても pool は残る）。
- userland: 試験 `userland/tests/ghci-blit/`、`userland/tests/ghci-display/`、道具 `userland/base/ghcictl/`（**追加は Q1 に名前の確認**）。boot の parameter は `docs/` の boot parameter の文書に足す。

### 6.2 attach と detach: ZYBO（PL の窓）と KC705（PCI）

- ZYBO の **PL の block の登録**（`zynq-devcfg.c` の変更、WS286 の file だが完了した WS なので WS001 が変える。Q1 に知らせる）: `FPGA_ENABLE` の後に窓の offset 0 の magic を読み、登録された block の driver（`{magic, attach(window_phys, size, irq), detach(), busy()}`）の magic と合えば attach を呼ぶ（`DEVICE_ID` と EXTCAP の形も確かめ、同じ物が 2 回見えたら拒む）。**block の driver が attach している間**: devcfg は IRQ 61 の handler を `kern_irq_unregister` で外して block の driver に渡し、`FPGA_IRQ_WAIT` と `FPGA_REG_WRITE` は `EBUSY`（`FPGA_REG_READ` は可: `fpgareg read` で debug）。detach で戻す。
- **detach の状態機械**（`FPGA_PROGRAM`・`FPGA_DISABLE` の前。`drv_gpu_unregister` が最初の呼び出しで device を offline にする（`gpu.c` 775〜830 行）事を踏まえる）:
  1. devcfg が block の driver の `busy()` を呼ぶ。GPU の driver は自分の session の数（`open`/`close` で数える）が 0 でなければ `EBUSY` を返し、**unregister を呼ばない**。`fpgaload` は「GPU の session を閉じてから」と表示する。
  2. 0 なら GPU の driver は hardware を静める: DC の `ENABLE` = 0 → `STATUS.idle`、CP の `HALT` → `HALTED`・`AXI_IDLE`（§1.3。`AXI_STUCK` なら報告して進む: PL の書き直しが回復の道）。
  3. `drv_gpu_unregister` を呼ぶ。0 なら完了。`EBUSY`（1 と 3 の間に open された）なら device はもう offline なので、**その session が閉じるまで `drv_gpu_unregister` を retry**（devcfg の `FPGA_PROGRAM` は最大 5 s 待ち、超えたら `EBUSY` を返す。device は offline のまま次の retry で回収され、次の attach は新しい登録）。
  4. その後に devcfg が level shifter と reset に触る（outstanding の AXI が無い事を 2 で確かめている）。
  - **JTAG（openFPGALoader）での PL の書き直しは block が attach している間は禁止**（`pl-jtag.sh` は zedBSD を見られないので、運用の規則として `fpgaload --disable` を先に打つ。design の試験の script がこの順を守る）。
- KC705（A'）: PCI の class code 0x038000 で照合し、BAR0 の `GHCI_MAGIC` を読んで確かめる。BAR0 = HCR + DC（128 KiB、`DRV_GPU_MAPPING_DEVICE`）、**BAR2**（2026-10-25 08:00 Q1: GHCI §15.2 に合わせて BAR1 から直した）= DDR の窓（64 MiB）。XDMA の channel は `resource_read/write` と ring・program・const の転送に。MSI 4 本。
- attach の順: `GHCI_MAGIC`・`GHCI_VERSION.major`・`CAPS`・`ISA_ID`（backend が有るか）を確かめ → `CAPS[0]` なら `CTRL.RESET` → `MEM_READY` を 1 s 待つ → `APERTURE` → `RING_BASE/SIZE` → fence page と `FENCE_LAST` → `IRQ_ENABLE` → `RUN`。`CAPS[3]` なら display の ops を足す。

### 6.3 memory（所有権・寿命・coherency）

- ZYBO: PL の memory の pool（§6.1）= aperture。CPU は uncached の alias だけで触る（WS286 §3.12）。`resource_map` は `DRV_GPU_MAPPING_UNCACHED_RAM`。**HAL の変更は無い**（`kern_pmem_*` で足りる）。
- KC705: GPU の DDR3（1 GB）が aperture。host からは BAR1 の窓（先頭 64 MiB を host visible の heap、残りを device local として memory type を 2 つ報告）と XDMA。
- 所有: allocation は session が持ち、`close` で全部返す（GPU がまだ参照し得る物は `drain` で待つ）。ring・fence page・staging は device。
- 寿命の規則: 参照を含む command の fence が signal するまで free しない。`resource_destroy` は「その時点の session の最後の fence の値（§6.4）≤ 完了した値」を確かめ、違えばその値と共に遅延の list に積む（L7）。**回収は IRQ の handler ではなく回収の thread**（handler は完了した fence の値を更新して thread を起こす。thread が allocator の mutex を取って返し、`drv_gpu_capacity_changed` を呼ぶ）。

### 6.4 drv_gpu との結び（capability・jobs・capset・command の道）

- **capability**（`drv_gpu_register` の検査（`gpu.c` 1024〜1045 行）と libvulkan の要求（`context.c` 124 行、`instance.c` 732 行）を満たす組）: GPU の device は `RESOURCE | CAPSET | BLOB | TRANSFER | COMMAND | MAPPING | NOTIFICATION | FENCE | JOB | JOB_CAPACITY | SHARE | ALLOCATION_SHARE`（KC705 は + `DISPLAY | DISPLAY_EVENTS`）。DC だけの device は `RESOURCE | TRANSFER | MAPPING | BLOB | SHARE | ALLOCATION_SHARE | DISPLAY | DISPLAY_EVENTS`。
- **ops**: `commands.submit/drain`（submit = frame を staging に写し ring に packet を置いて doorbell、`QUEUE_SUBMIT` の frame には後ろに FENCE を置く。完了は reply thread が trailer の後に `drv_gpu_complete`（§2.4.6）。drain = session の pending の frame と fence を全部待つ）、`jobs.reserve/commit/cancel/capacity`（**powervr の `render-runtime.c` の marker の形**、C2: reserve = session の marker（固定の数、例 64）を 1 つ取って completion を持ち token を返す（sequence は core の物で driver は見ない）。commit = marker を「session の最後の fence の値」（直前の `QUEUE_SUBMIT` の frame が置いた FENCE の値。driver の 32 bit の device 全体の fence、§2.5）に結ぶ。その値が既に過ぎていれば commit の中で `drv_gpu_complete`。cancel（通常）= marker を返す。cancel（fault）= completion を保ち、回復で ERROR で完了。capacity = 空きの marker の数）。IRQ の bottom half は fence page の値を読み、過ぎた marker を順に `drv_gpu_complete`、`recovery.stop_begin/stop_poll/fault/reset`（§2.5）、`share.*`、`display.*`（KC705 と DC）、`scanout.*`（DC）。
- **capset**: `get_capset` は powervr の `runtime_capset`（`render-runtime.c` 175 行）と同じ形: id 4、176 byte、wire 1、XML の版は libvulkan の `VULKAN_PROTOCOL_XML_VERSION`、timelines ≠ 0、160 byte に vendor の magic、164 byte に flag `OPAQUE | STRICT_QUEUE | QUIESCE`（libvulkan が native の device を作る条件）。**libvulkan は変えない**。
- **native の packet（試験用）**: `GPU_OP_GHCI_NATIVE`（§2.4.5、**0x10104 の案。番号は Q1 に確認**、U10）。payload は class N の packet の列で、driver はそのまま ring に写す。**build の option `CONFIG_GHCI_NATIVE`（試験の image だけ）と root だけ**に限り、driver は opcode の白表（NOP/SET_REG/BLIT/FENCE/WAIT_IDLE/INVALIDATE）と `SET_REG` の index の白表（BLT の範囲だけ）で検査し、address の word は aperture の中かを見る。それ以外は `EINVAL`。`userland/tests/ghci-blit/` が使う。compositor は使わない。
- 並行性と lock: ring への書き込みは 1 つの mutex（`cp_lock`）。IRQ の handler は spin で `completed_fence` と pending の list を守り、`drv_gpu_complete` は spin の外。
- 失敗: §2.5（v1 は device 全体の fault → reset。parse の誤りだけ session の error）。
- **BLT と ROP の順序（driver の規則）**: render pass の clear（BLT の FILL）の後、DRAW の前に `WAIT_IDLE(BLT)`。copy（BLT）が draw の結果を読む前に `WAIT_IDLE(ROP)`。CPU・BLT が書いた texture・buffer を shader が読む前に `INVALIDATE(D$|T$)`（DRAW/DISPATCH の暗黙の無効化で足りる場合が多い）。pipeline barrier は `WAIT_IDLE` + `FENCE`。

### 6.5 display device

- ZYBO: `display/display.c` が display だけの device を登録（`drv_gpu_unregister` できる寿命。bcm2711 の static の形は取らない）。`query`（1 output、mode は 640×480@60 と 1280×720@60）、`mode`（timing と `PCLK_SEL`）、`claim/release`（lease は 1 つ）、`present`（`FB_NEXT`）、`wait`・`events`（64 bit の software の sequence、VSYNC で進める）。`scanout.import_image` で GPU の device が export した allocation（pool の中の linear の image）を scan に使う。
- KC705: 1 つの device に display の ops（same-device の share の import）。**版 8（§18.7、p035 D7 で実装）**: DISP2、ring の点灯・消灯（DISP_SET）、present = FLIP（SHARED は copy しない、COPY は driver の frame への BLIT の後）、UNGATED と adoption_wait、queue（深さ 2）と mailbox、scan の hold、recover の数え直し（STATUS[31]・TAKEN0/1）、DISP_ERROR の数と mask、hotplug の poll（ADV7511 の HPD）。
- cursor は版 8 で plane 1（64 × 64 BGRA8、DC が gclk で合成、§18.5 の `atg_dc_cursor`）。overlay は無し。

### 6.6 compiler の backend（`isa/gsi1/`、IR → GSI1。版 3）

**更新（2026-10-25 07:12 Q1）**: 実装は `src/drivers/gpu/ghci/compiler/`（p010）。下の表のうち texture の offset・gather・compare・cube・3D・array を「拒む」とする行は古い: p009 part E・F と p010 で全部対応した（GHCI §12.9）。拒む物は cube array・dual-source blend・gl_Layer。shared memory の atomic は p030 S15 で `atoms`（`atom` の sub[4]）として足した（2026-10-25 P2）。

- 入力は共有の `struct drv_gpu_shader_ir`（`src/drivers/gpu/compiler/ir.h`、op の一覧は 263〜633 行）。SPIR-V の front end は書かない（Guardrail: compile は kernel 空間の driver）。出力は §3.4.4 の binary（header + 64 bit の命令）。backend の表 `struct ghci_isa_backend {fourcc, compile, release, limits}` に "GSI1" を登録し、`ISA_ID` で選ぶ（GHCI 1.0 の shader 付きの GPU は全部 "GSI1" なので、実質この 1 つ）。
- **IR の op の対応表（全部）**:

| IR | GSI1 |
| --- | --- |
| CONST / ICONST / BOOL | `movi`（小さい整数は `addi rd, zero, imm`） |
| LOAD_INPUT（vertex） | 属性の slot k = r_k（VF が書く）。`mv` |
| LOAD_INPUT（fragment） | `lda` × 3 + `fmul.s` + `fmadd.s` × 2（flat は `lda` の頂点 0、noperspective は §3.8） |
| STORE_OUTPUT | `exp` |
| LOAD_PUSH / LOAD_UBO | `c` の operand（32 word まで）か `lwc` |
| FADD FSUB FMUL | `fadd.s fsub.s fmul.s`（FNEG/FABS は operand の修飾 n/a に畳む） |
| RSQ SIN COS RCP SQRT EXP2 LOG2 | custom-3 の `rsq sin cos rcp exp2 log2`、`fsqrt.s` |
| FLOOR FTRUNC FROUND_EVEN | `fround.s`（rm = rdn / rtz / rne） |
| FRACT | `fract` |
| FMIN FMAX | `fmin.s fmax.s` |
| FLT FGE FEQ FNEU | `flt.s`、`fle.s`（operand を入れ替え）、`feq.s`、`fne.s` |
| AND OR NOT SELECT | `and or`、`xori rd, rs, -1`、`sel` |
| KILL | `kill` |
| IADD ISUB IMUL INEG IAND IOR IXOR INOT SHL SHR ASR | `add sub mul`、`sub rd, zero, rs`、`and or xor`、`xori -1`、`sll srl sra` |
| UDIV UMOD IDIV IREM | `divu remu div rem`（class x） |
| I2F U2F F2I F2U | `fcvt.s.w fcvt.s.wu fcvt.w.s fcvt.wu.s`（rm = rtz） |
| ILT ULT | `slt`、`sltu`（Boolean） |
| IGE UGE | `slt`/`sltu` + `xori rd, rd, -1`（2 命令） |
| IEQ INE | `xor t, a, b` + `sltiu rd, t, 1` / `sltu rd, zero, t`（2 命令） |
| MOVE / LOOP_BEGIN / LOOP_END | `mv` / `exec.save rS`（loop の前）+ label / 条件 → `exec.and cond` + `bexnz label` + `exec.set rS`（loop の後。`exec.save` は EXEC に依らず全 lane に書く、M13） |
| SKIP_BEGIN / SKIP_END | `exec.save` + `bexz` + … + `exec.set` |
| SAMPLE / SAMPLE_BIAS / SAMPLE_LOD | `texb`（bias 0 / bias）/ `texl` |
| DDX DDX_FINE DDY DDY_FINE | `qd`（sub 0/1）、coarse は `qd` + `qd sub 5` |
| PACK_HALF / UNPACK_HALF | `packh` / `unpackh` |
| TEXTURE（LD / RESINFO / SAMPLE*・gather・Dref・offset、2D・array・3D・cube） | `texf` / `texsz`（`.l`・`.d`）/ `texb`・`texl`（`.c`・`.3`・offset）/ `texg` / `texqlod`（p009 part E・F で入った、2026-10-25 02:53 Q1 の更新） |
| LOAD_STORAGE / STORE_STORAGE / ATOMIC / STORAGE_SIZE | `lw` / `sw` / `atom` / firmware が interface の表の storage の entry の constant の word に置く大きさを `lwc`（C1）。述語付き（ir.h の component 1、`ATOMIC_PREDICATED`）は `exec.save` + `exec.and pred` + 命令 + `exec.set`（M14） |
| ATOMIC（shared、`LOCATION_SHARED`） | **拒む**（shared の atomic は GSI1 v1 で reserved、M14） |
| TEXTURE の texel の offset ≠ 0、SAMPLE_DERIVS、gather、compare | **拒む**（`ENOTSUP`、M14） |
| STORE_OUTPUT（POINT_SIZE / SECOND_COLOR / LAYER） | `exp 0x004` / `exp 0x108+c` / 拒む |
| NOP | 出さない（`nop` は pad だけ） |
| LOAD_SYSTEM | 特殊 operand（`wg*`、`lid*`、`lidn`、`prim`） |
| LOAD_SHARED / STORE_SHARED / BARRIER / FENCE | `lds` / `sts` / `bar` / `fence` |
| LOAD_VERTEX_INPUT / EMIT_VERTEX / END_PRIMITIVE（geometry） | **拒む**（geometry stage 無し） |
| SA の拡張の op（延期。Appendix A.4） | v1 は無し（`rq`・`sactl` は出さない） |

- register の割り当て: linear scan、r0〜r(NREGS−1)（63 は `rq`、§3.9）。溢れは拒む（`ENOTSUP`、R8）。header の `nregs` に最大 + 1。
- **compile の時点と entry**（C1）: pipeline の作成で stage ごとに `drv_gpu_shader_parse(words, count, stage, …)`。v1 は「その stage の entry point が 1 つの module」だけ受ける（entry の名前で選ぶ API は共有の `spirv.c` に無い。足すのは共有の compiler の変更で Q1 の判断）。binary の interface の表（§3.4.4）は IR の `drv_gpu_shader_ir_uniform`（set、binding、kind、offset、size）と入出力の location から作る。
- scheduling: 長い命令（class m・t・x）の結果を使う命令を遠ざけ、独立の命令で埋める（scoreboard が止める間を減らす）。`wait` は `sw`/`atom` の完了が要る時（`fence`・`bar` の前）だけ。
- host の試験: `tests/ghci-gsi1-compiler-host-test.c`（符号化の往復 + `tests/gsi1-model.c`（amaterrace-gpu の `sim/models/gsi1_model.c` の写し、§7.2）で実行して CPU の参照と比べる）。
- 出典の規則（§3.4.6）: `gsi1_isa.h` の opcode の値の block に RISC-V の仕様の「Values referenced:」。他の GPU の物は写さない。

### 6.7 Vulkan の executor（`vk/`）= 検証する中継（版 3）

- libvulkan は変えない。`vk/` は gpu-op の stream を**解いて検証し**、§2.4.4 の表のとおりに D（driver が答える）/ R（そのまま ring へ）/ R'（`GPU_OP_GHCI_*` に書き換えて ring へ）/ X（拒む）に分ける。Vulkan の object の意味（pipeline の状態、descriptor の内容、render pass）は firmware の物で、driver は持たない。
- **既存の executor の構造との対応**: powervr の `vk/`（`vk-stream.c` の frame と route の表、`i915_wire_reader` の再利用）を型にする。route は `device`（D: instance・physical device・device・queue。capset と limit の表）、`memory`（R': allocator、`GHCI_MEMORY`、遅延解放）、`program`（D: module の SPIR-V の帳簿。pipeline の作成で stage ごとに compile → `GHCI_PROGRAM`、C1）、`object`（R: 50〜58・65〜89 の長さの計算と識別子の帳簿（session の close で `SESSION_CLOSE` に先立って driver 側の帳簿を消す））、`command`（R: 90〜136 の白表と長さ）、`queue`（R + FENCE + job）、`transport`（D: 178・179・137・180）。i915 の「object → recording → range → transport」の順の dispatch と同じ形で、handler の中身が「長さを数えて写す」に変わる。
- **wire の長さ**: handler は各 command の引数を gpu-op.h の「Arguments」の形で読み（構造体は field の順、pNext の chain、配列は count と u64 の count）、読んだ byte 数が packet の `n`。知らない sType の chain は拒む（`EINVAL`）。
- **返事**: D の返事はその場で書く。R/R' で REPLY を求める command は返事の大きさ分の cursor を空けて result の index を付け、frame を staging に写して ring に `GHCI_FRAME` を置いて返る。device の **reply thread** が `RESULT` の IRQ で record を読んで返事を埋め、trailer を release store で書き、`drv_gpu_complete`（§2.4.6。ioctl の中では眠らない、M3）。
- **session**: `open` で tag（1〜255、空きの最小）を取り `SESSION_OPEN` を ring に送る。`close` で `drain`（pending の fence を待つ）→ `SESSION_CLOSE` + FENCE → driver の帳簿と allocation を返す。
- **大きさ**: 6〜8k 行（codec は生成、帳簿と D の返事と reply thread と layout を含む。版 2 の 8〜12k より減る: Vulkan の object の意味が firmware に移ったため。M1）。p019 の LW 26。
- 最初の目標は vkdemo の部分集合（U8）: instance/device/queue、memory、buffer・image（2D、RGBA8/BGRA8、D24S8）、shader module、descriptor set（UBO・sampled image・storage）、pipeline、render pass（1 subpass）、command buffer（bind・draw・draw indexed・dispatch・copy・barrier・clear）、fence/semaphore、swapchain は WSI。

### 6.9 firmware（`fw/cp/`、amaterrace-gpu。版 3）

- 置き場所は amaterrace-gpu の `fw/cp/`（C、Zlib、`docs/style.md` の規約 + zedBSD の `plan/coding-style.md` を当てる: WS001 の p016 で全文を見直す）。build は共有の LLVM の clang（riscv32 の target、実測で有る）で `-ffreestanding -nostdlib -march=rv32im -mabi=ilp32`、link script は `fw/cp/link.ld`（IMEM 0x0000_0000、DMEM 0x2000_0000、制御の window 0xF000_0000）。toolchain は変えない（使うだけ）。
- 成果物 `atg1-cp.bin`（+ `.hex` を bitstream の BRAM の初期値に）。zedBSD の tree に blob を置くか（`userland/firmware/amaterrace/`、`CPFW` の載せ替え用）は U21。v1 の driver は blob 無しで動く（bitstream に入っている firmware を使う）。
- 試験: Verilator の harness（p017 から `atg_cpu` を含む）、firmware の単体の試験（host の C で packet の reader・heap・object の表を試す: `fw/cp/tests/`）。

### 6.10 systolic array の zedBSD の側（版 4: 延期）

- SA は延期（§3.9）。v1 の driver・compiler は `rq`・`sactl` を出さない。Vulkan からの見せ方（独自の拡張 `VK_KEI_systolic_dispatch` の案: 案 B では指揮だけなので GEMM・attention・LN を拡張の構造体で表せ、FP16 の IR は要らない）は Appendix A.4 の sketch。`VK_KHR_cooperative_matrix` はこの SA の形では実装できない（版 3 の H8）。

### 6.8 試験の道（host → simulation → 板）

| 段 | 道具 | 何を確かめるか | 誰が |
| --- | --- | --- | --- |
| RTL の lint | `verilator --lint-only -Wall`（**U3**）。無ければ `iverilog -Wall` | 0 warning | 担当 |
| block の unit の TB | iverilog（`sim/tb/<block>_tb.v`、`PASS <name>`、`sim/run.sh NAME`） | AXI の slave/master、`am_afifo`、AMB の arbiter と quiesce、CP（**状態遷移、ring の wrap と満、FENCE の完全性（非同期の BLIT の後の fence）、FAULT と reset の順、EXTCAP**）、BLT、RX、ROP（**重なる 2 三角形の blend の順**）、SU（命令ごと、NPHYS 8/16/32 で同じ）、TU | 担当 |
| 全体の simulation | **Verilator**（C++ の harness: DDR の model、HCR、`ghci_packets.h`、ISA の model） | 各 milestone の板の場面（fill → DBG、fence → IRQ、三角形の PNG、compute）、**fault の注入 → reset → 次の仕事が動く**、**ring の wrap の負荷（満ちる・空ける）** | 担当 |
| Vivado の合成 | `vivado-build.sh`（IP 有りは `vivado-build-ip.tcl`）、ZYBO は Vivado（新設）か openXC7 | 実測の使用量、timing、DRC | 担当 |
| 板 ZYBO | `fpgaload` + `fpgareg`（`plan/tools/zybo/ghci-*.sh`）。SSH は WS289 の LAN が有る image なら `deploy.sh`。**生きた serial の判定と担当が JTAG を直に触る例外は WS286 の物（AGENTS.md）で、WS001 への拡張は U16** | p003〜p005・p007・p008 の板の受け入れ、p006 の `ghci-blit`・`ghci-display`、**detach/reattach（session を開いたままの `fpgaload` が EBUSY、閉じた後に通る）** | 担当、画面の目視はユーザー |
| 板 KC705 | `jtag-load.sh` + `jtag-reg.sh` | p012、p014 | 担当 |
| firmware（版 3） | `fw/cp/tests/`（host の C で packet の reader・heap・object の表を単体で）、Verilator の harness に `atg_cpu` + firmware を含めて class V の packet を流す（p017・p018）、`atg_cpu` の命令の TB（riscv-tests 風の自前の部分集合） | fill/copy の中継、object の作成 → µop の列の期待、watchdog → RESET → 再起動、`CPFW` の載せ替え | 担当 |
| QEMU | GPU は無い。kernel 側の build と boot の回帰（armv7-virt の PNG、driver の無い platform を壊さない） | 各 Phase | T1 |
| VFIO の実機 | A' の QEMU の guest（SSH/QMP の PNG） | p013 以降 | T1 |

QEMU と実機の証拠は分けて書く。やっていない確認は「未実施」と書く。

## 7. repository の分割、license、bitstream の配布

### 7.1 何をどこに置くか

| 置き場所 | 中身 |
| --- | --- |
| **amaterrace-gpu** | `README.md`（ユーザーの物。書き足しの案は [proposed/README-additions.md](proposed/README-additions.md)）、`docs/ghci.md`（**GHCI 1.0 の正本**: §2）、`docs/gsi1.md`（§3、GSI1 の正本）、`docs/style.md`、`rtl/common/`、`rtl/gpu/{cp,blt,vf,rx,su,tu,rop,mc}/`（`cp/` に `atg_cpu.v`）、`rtl/dc/`、`fw/cp/`（CP の firmware、§6.9）、`include/`（`ghci_regs.vh`・`gsi1_isa.vh`、C の `ghci_regs.h`・`ghci_packets.h`・`ghci_layout.h`・`gsi1_isa.h`）、`boards/zybo/`、`boards/kc705/`、`boards/kc705-sukuna/`（将来）、`sim/`、`tools/`、`LICENSE`。Vivado の project・IP の生成物・bitstream は commit しない |
| **zedBSD** | `src/drivers/gpu/ghci/`、`src/drivers/platform/zybo/pl-memory.c` と `zynq-devcfg.c` の変更、`include/uapi/gpu-op.h` の番号、`userland/tests/ghci-*`、`userland/base/ghcictl/`、`tests/ghci-*-host-test.c`・`tests/gsi1-model.c`、`plan/tools/zybo/ghci-*.sh`・`plan/tools/kc705/jtag-reg.sh`・`pcie-reload.sh`、`plan/ws001/`。既存の `plio` と `kc705/bringup` は zedBSD に残す |
| **sukuna-risc** | CPU の RTL（WS001 の外） |

### 7.2 共有する header の規則

- `ghci_regs.h`・`ghci_packets.h`・`ghci_layout.h`（image の layout の式: driver の memory requirements と firmware が同じ物を使う、R23）・`gsi1_isa.h` は amaterrace-gpu が正本。zedBSD は写しを置き、先頭に「copied from amaterrace-gpu <commit>」と SPDX。`plan/tools/ghci-sync.sh` で `diff`（CI では走らせない）。ISA の model も同じ。GHCI の版の定数を header に持ち、driver が attach で比べる。

### 7.3 RTL の規約

- Verilog-2005（iverilog・Vivado・Verilator で通る部分集合）、`default_nettype none`、module 1 つ = file 1 つ、同期 reset、vendor の primitive は `boards/` と `rtl/common/xilinx/` だけ、lint 0 warning、plio.v と同じ形の先頭の comment。amaterrace-gpu の `docs/style.md`。Guardrail には 1 行（Q1）。

### 7.4 license（**U1**）

| 案 | 判断 |
| --- | --- |
| **Zlib**（推し） | zedBSD と同じ。写す header に壁が無い。仕様の文書も Zlib で揃える |
| CERN-OHL-P-2.0 | hardware 向け。写す header の dual の手間 |
| Apache-2.0 / Solderpad 2.1 | 特許の条項。混在の管理 |

- 参照: AMD/Xilinx の公開の文書と Vivado の board file だけ。他の GPU の RTL は読まないし写さない。GPL は参照しない。

### 7.5 AMD の IP を含む bitstream の配布（**U6**）

- MIG・PCIe・XDMA は代えない（ユーザー）。EULA を読むまで public の repository は RTL と TCL だけ、bitstream は release の添付も保留。

### 7.6 RTL の進め方: top-down の分割、空の module、module ごとの仕様の text（版 4、2026-10-23 ユーザー）

ユーザー:「方針として、まずブロックをトップダウンに分割して、ブロックのI/Oだけ定義して、空のモジュールを書きましょう。仕様はモジュールごとにテキストファイルにしましょう。ステートもかなり大まかにはテキストに記載しておきましょう。これで、だいぶ下位のAIモデルでもVerilogが記述できるはずです。」

- **順序**: p023（§8）で GPU の全部を module の木に分け、module ごとに (a) port だけの空の Verilog（親に配線済み、Verilator の lint が通る）と (b) 仕様の text（`spec/<path>/<module>.md`）を書く。その後の実装の Phase（p004〜p019）の仕事の単位は **「`spec/X.md` から module X とその TB を実装する」**（1 module = 1 人日 / 下位の model の 1 session の大きさ）。既に実装済みの module（`am_*`、`atg_cp`、`atg_blt`、`atg_mc`、`atg_top`、ZYBO の top）も今の RTL から spec を書く（RTL が正、spec はそれを写す。差があれば spec に「RTL と違う」と書き、直すのは実装の Phase）。
- **大きさの規則**（U38）: 1 module ≤ **400 行**の Verilog、状態機械は 1 つ、clock の領域は 1 つ（跨ぐ物は `am_afifo`/`am_sync` だけ）、port の数 ≤ 40。超える見込みなら分ける。
- **置き場所**（U37）: amaterrace-gpu の `spec/` が `rtl/` と同じ path（例 `rtl/gpu/su/atg_su_sb.v` ↔ `spec/gpu/su/atg_su_sb.md`）。board の top は `spec/boards/<board>/<top>.md`。`spec/README.md` に template と規則。design.md（zedBSD の plan）は「なぜ」と全体、spec は「何を」の正本（**spec と RTL が食い違えば RTL を直す**。design.md と spec が食い違えば design.md を直してから spec）。
- **module の木（p023 の入力。実装の Phase の割り当ては §8 の表）**:

| block | module（`atg_<block>_<part>`） | 主な中身（§） |
| --- | --- | --- |
| common | `am_afifo`・`am_fifo`・`am_sync`・`am_axi_regs`・`am_axi_master`（済み）、`am_jtag_regs` | §1.3、§4.4 |
| CP | `atg_cp_regs`（HCR、EXTCAP）、`atg_cp_state`（STATE の BRAM と alias）、`atg_cp_ring`（RING の DMA、封筒の解読、class の振り分け、RPTR）、`atg_cp_seq`（class N の µop の sequencer: SET_REG/BLIT/DRAW/DISPATCH/WAIT_*/INVALIDATE）、`atg_cp_fence`（FENCE/RESULT の書き込みと BRESP の待ち、FENCE_LAST）、`atg_cp_ctl`（状態遷移、HALT/RESET/quiesce、watchdog、FAULT）、`atg_cp_irq`、`atg_cp_dbg`（DBG_ADDR/DATA）、`atg_cp`（結線。今の stub を分ける） | §2.2〜§2.7 |
| CPU | `atg_cpu_core`（RV32IM の 3 段: fetch・decode/exec・wb）、`atg_cpu_alu`、`atg_cpu_muldiv`、`atg_cpu_mem`（IMEM/DMEM の BRAM と load/store）、`atg_cpu_win`（制御の window: packet、UOP_FIFO、STATE の読み、DMA、RESULT の IRQ、mailbox、DONE）、`atg_cpu_dma`、`atg_cpu`（結線） | §2.4.7 |
| BLT | `atg_blt`（済み。400 行を超えるなら `atg_blt_rd`/`atg_blt_wr`/`atg_blt_ctl` に） | §2.3 |
| VF | `atg_vf_index`（index の読みと restart）、`atg_vf_fetch`（属性の読み、instancing）、`atg_vf_conv`（format の変換、ATTR_DST）、`atg_vf_asm`（primitive の組み立て、PT の予約）、`atg_vf` | §2.3、§3.8 |
| SU | `atg_su_sched`（warp の slot、round-robin、NPHYS の sequencing）、`atg_su_fetch`（PC、I$ の口）、`atg_su_icache`、`atg_su_dec`（64 bit の decode、operand の番号、修飾）、`atg_su_sb`（scoreboard と wait の counter）、`atg_su_rf`（BRAM の RF、複製、書き込みの調停）、`atg_su_opd`（operand の集め: GPR/c/特殊/rq、修飾）、`atg_su_alu`（整数）、`atg_su_fpu`（fp32、FMA、比較、変換、fround）、`atg_su_pk`（packed）、`atg_su_pkx`（packed の超越）、`atg_su_xu`（fp32 の超越、共有）、`atg_su_div`、`atg_su_exec`（EXEC/KILLED/mask、分岐）、`atg_su_lsu`（lw/sw/atom、coalescer）、`atg_su_dcache`、`atg_su_lds`、`atg_su_cbank`（constant、lwc、LOAD_CONST）、`atg_su_tex`（TU への要求と戻り）、`atg_su_exp`（EXP の buffer、PT/ROP へ）、`atg_su_lda`（primitive table）、`atg_su_lane`（qd・shfl・vote・ballot の staging）、`atg_su_rq`（rq の口の予約: 発行の段の stall の信号と operand 63 の decode。中身は SA と一緒に延期）、`atg_su_wb`（書き戻しの調停）、`atg_su`（結線） | §3 |
| RX | `atg_rx_clip`、`atg_rx_setup`（viewport、edge の係数）、`atg_rx_scan`（quad の走査、coverage）、`atg_rx_order`（warp の連番）、`atg_rx` | §3.8、§2.3 |
| TU | `atg_tu_addr`（slot、mip、wrap）、`atg_tu_cache`、`atg_tu_filter`（最近傍/bilinear）、`atg_tu` | §2.3 |
| ROP | `atg_rop_order`（連番の scoreboard）、`atg_rop_ds`（depth/stencil）、`atg_rop_blend`、`atg_rop_wb`（write-combine、書き戻し）、`atg_rop` | §2.3、§3.8 |
| MC | `atg_mc_arb`、`atg_mc_aper`（aperture の検査）、`atg_mc_atom`、`atg_mc`（済みの物を分ける） | §4.1 |
| DC | `atg_dc_regs`、`atg_dc_dma`、`atg_dc_tgen`、`atg_dc_vga`、`atg_dc_tmds`、`atg_dc_i2c`、`atg_dc` | §5 |
| SA（延期: p023 は `atg_sa` の top の port だけ予約。中の module の spec は SA の設計の時） | `atg_sa_in`、`atg_sa_pe_*`、`atg_sa_array`、`atg_sa_drain`、`atg_sa_red`（出口の reduction、案 B）、`atg_sa_norm`（入口の normalize）、`atg_sa_buf`（token buffer）、`atg_sa_wfetch`、`atg_sa_fifo`、`atg_sa_ctl`、`atg_sa` | Appendix A |
| top | `atg_top`（parameter で block の有無）、`boards/zybo/`: `zybo_2d`、`zybo_2dfw`、`zybo_dc`、`zybo_raster`、`zybo_compute`、`boards/kc705/`: `kc705_raster`（`kc705_sa` は延期） | §1、§3.6 |

  合計 約 80 module（common 6、CP 9、CPU 7、BLT 1〜3、VF 5、SU 27（p009 で `atg_su_pt` を分けた）、RX 6（p009 で `atg_rx_frag` を分けた）、TU 4、ROP 5、MC 4、DC 7、SA 1 + 延期 10、top 7（`kc705_sa` は延期））。

- **spec の template**（`spec/README.md`、各 `spec/<path>/<module>.md` はこの節の順）:
  1. **目的**（1〜3 文）と block の中の位置（親、子）。
  2. **parameter**（名前、既定、意味、取り得る値）。
  3. **port の表**: 名前、方向、幅、clock/reset の領域、意味、**handshake と timing**（valid/ready、1 cycle の pulse、level、「読みの応答は次の cycle」など）。
  4. **振る舞い**（text。何を入力して何を出すか、順序の約束、他の module との関係）。
  5. **状態機械**（大まかに: 状態の一覧と、遷移の条件を text で。「IDLE →(start)→ RUN →(done)→ IDLE」の形で十分）。
  6. **latency / throughput の目標**（cycle 数、1 cycle あたりの処理量、clock の目標）。
  7. **corner case と誤り**（空/満、同時の要求、reset の途中、aperture の外、EXEC = 0 など）。
  8. **TB が確かめる事**（`PASS <name>` の一覧。TB の file は `sim/tb/<module>_tb.v`）。
  9. **参照**（design.md の §、他の spec、出典の規則が要る値の「Values referenced:」）。
  10. **状態**: 空 / 実装済み（commit）/ RTL と spec の差。
- **空の module の形**: `plio.v` と同じ先頭の comment（SPDX Zlib）、`default_nettype none`、parameter と port だけ、本体は出力の tie-off（`assign out = '0;`）と `/* spec/<path>/<module>.md */` の 1 行。親は子を instance して配線する（本当の信号の名前で）。`tools/lint.sh`（`verilator --lint-only -Wall`）が木の全部で通る事が p023 の受け入れ。
- **下位の model での実装**: 実装の Phase の起動の指示は「`spec/X.md` と親の spec を読み、X.v の本体を書き、`sim/tb/X_tb.v` の PASS を全部通す。port と parameter は変えない（変えたい時は spec を直す提案を Q1 に）」の形にする。設計の文脈は spec の §9 の参照で足りるようにする。

## 8. Phase と LW（8 LW ≈ 2〜3 時間。p001 はこの設計。版 3 で p017〜p019 を新設し、p004・p008・p010・p011 を書き直した。版 4: **p023（module の分割と spec、p004 より前）**を新設（p020〜p022 の SA は Future Work）。**p004 以降の実装の Phase の仕事の単位は「`spec/X.md` から module X と TB を実装」**（§7.6）で、下の表の「内容」は spec の束の名前として読む（Phase ↔ module の表は §8 の末尾））

| Phase | 内容 | 受け入れ（板で見る物） | 依存 | LW |
| --- | --- | --- | --- | --- |
| p002 | amaterrace-gpu の骨組み、`docs/ghci.md` 1.0 の草稿（host interface の部分。command の節は版 3 の §2.4 を写す）、`am_axi_regs`・`am_axi_master`（quiesce 付き）・`am_afifo`・`atg_mc`、TB の枠、Verilator の harness の骨、**bitstream 1（CP+MC+BLT）の合成で LUT を実測し §3.6 を直す**（2026-10-23 P2 が実装中: `rtl/common/*`、`atg_cp.v`（stub）、`atg_blt.v`、`atg_mc.v`、`atg_top.v`、`include/ghci_regs.h` を読んだ） | host: TB PASS、lint 0 | p001、U1、U3 | 14 |
| p003 | CP v0（HCR、状態遷移、IRQ、STATE、`KICK`、非同期の `DBG`、EXTCAP）+ BLT + ZYBO の top（PS7、GP0、HP0）→ 板: `fpgareg` で fill/copy → `DBG` で DDR を照合。GPU の DDR は DTB の `/reserved-memory/gpu@1c000000`（64 MiB、no-map、`plan/ws001/tests/zybo-gpu-sd.dts`。`make-zybo-boot-files.py` が 512 MiB を要るので `memory@0` は縮めない） | **最初の端から端**: `fpgareg` だけで fill/copy。`IRQ_SET` → `fpgareg wait` | p002 | 12（**cleared 2026-10-23**、実測は §3.6） |
| **p023**（新設、版 4、**p004 より前**） | **top-down の分割・空の module・module ごとの spec**（§7.6）: (a) GPU の全部（CP と `atg_cpu`、BLT、VF、SU の scheduler/scoreboard/RF/ALU/LSU/cache…、RX、TU、ROP、MC、DC、SA、ZYBO と KC705 の top）を約 80 の module に分ける（1 module ≤ 400 行、1 状態機械）、(b) module ごとに port だけの空の Verilog を書き親に配線して木の全部で `verilator --lint-only` を通す、(c) module ごとに `spec/<path>/<module>.md`（template は §7.6: 目的・parameter・port の表と handshake・振る舞い・大まかな状態機械・latency/throughput・corner case・TB の PASS・参照）。済みの module（`am_*`、`atg_cp`、`atg_blt`、`atg_mc`、`atg_top`、ZYBO の top）は今の RTL から spec を書く。`spec/README.md` に template と規則 | `tools/lint.sh` が木の全部で 0 warning、spec が全 module に有り §1〜§9 が埋まっている、Q1 の読み合わせ（port の名前と幅が design.md と合う） | p001（版 4）、p002（common と stub が有る）、U37、U38 | 44（spec 80 × 0.4 + stub と配線と lint 8 + 済みの module の spec 4） |
| p004 | ring + **版 3 の封筒（§2.4.2）** + class N の sequencer（§2.4.3 の 14 µop、`RESULT` を含む）+ fence + 割り込み + fault + reset: `RUN`、ring の約束（§2.7）、完全な FENCE、watchdog、FAULT、`RESET` の順、class V の packet は **firmware が無い構成では FAULT 種別 2**。板: `DBG` で ring を書き doorbell、`fpgareg wait` で FENCE、aperture の外で FAULT → RESET → 次の fill が通る | ring の fill → FENCE → IRQ → 値、**fault → reset → 回復**、wrap の TB、class 3 の詰め物 | p003 | 14 |
| p005 | DC（bitstream 2）: VGA（先）→ TMDS、`TEST_PATTERN` → DDR の framebuffer。窓の offset 0、IRQ_F2P[0] | color bar の目視、framebuffer の目視、`fpgareg wait` で VSYNC | p002 | 14 |
| p006 | zedBSD: devcfg の block の登録と IRQ の受け渡し、`pl-memory.c`、`ghci.c`・`cp.c`・`memory.c`・`blit.c`・`native.c`（`GPU_OP_GHCI_NATIVE`）・`state.c`・`jobs.c`・`capset.c`、display device と scanout、`ghci-blit`・`ghci-display`、host の試験（封筒・allocator・fence の wrap・状態遷移の driver 側） | `ghci-blit` PASS（板）、`ghci-display` の画面（目視）、**detach/reattach の試験**、QEMU armv7-virt の回帰（T1） | p004、p005 | 24 |
| p007 | RX + ROP（bitstream 3、`DRAW_RAW`、`DEBUG_COLOR`、ROP の順序の scoreboard）→ DC | 三角形の画面、depth、重なる blend の順、Verilator の PNG | p004、p005 | 18 |
| p008 | SU v0 と **GSI1 の compute の部分集合**（bitstream 4「compute」、CPU 無し）: `atg_su`（NPHYS の sequencing、RF、書き込み port の調停、I$、D$、LDS、const、超越、**scoreboard**（§3.1.1）、64 bit の decode（§3.3））、整数・fp32・memory・LDS・制御・`sel`・`exec.*` の命令、ISA の model（C）、`gsi1asm.py`/`gsi1dis.py`、TB、`DISPATCH`。**U12 の確定、SB_ENTRIES の実測**。板: vector add と reduction を `DBG` で | compute kernel が板で正しい、model と一致（NPHYS 8/16/32）、scoreboard の TB（RAW/WAW/entry 満） | p004、U12、U22 | 34 |
| p009 | VF + SU の vertex/fragment + PT + primitive table + `lda` + `exp` + `qd` + helper lane と coverage の mask（M10）+ `ATTR_DST`（M12）+ TU（最近傍 → bilinear）+ texture の命令 + deadlock の回避 + `PACKED`（KC705 の構成）+ `shfl`/`vote`/`ballot`（`CAPS[24]`、optional） | textured な三角形（**Verilator の PNG**。板は KC705 の p014） | p007、p008、U27 | 28 |
| p010 | compiler の backend（zedBSD `isa/gsi1/`、IR → GSI1、§6.6）、**`gsi1_isa.h` の binary の header と interface の表の確定**（C1。p018 はこれに依存）、host の試験（符号化の往復 + model で実行して CPU の参照と比べる、interface の表の検査） | host PASS | p008、U22、U23 | 24 |
| p011 | **端から端の統合**: libvulkan → `vk/`（p019）→ ring → firmware（p018）→ block で vkdemo の 1 frame。**場**（H6）: host で build した `vk/` と libvulkan を、偽の drv_gpu（`tests/` の host の harness: ioctl の代わりに関数、HCR と memory を Verilator に DPI で結ぶ）と Verilator（`atg_cpu` + firmware を含む）で繋ぐ。性能の最初の計測（draw あたりの firmware の cycle、1 frame の往復） | vkdemo の 1 frame の readback が参照と一致（**Verilator**。板は p014） | p009、p010、p018、p019 | 28（±30%） |
| p012 | KC705（RTL と sim。板での確認は p024、2026-10-24 ユーザー）: MIG、MMCM、`LINE_BYTES` 64、JTAG の bridge、CP + BLT + DC（HDMI は U7）、`vivado-build-ip.tcl` | `jtag-reg.sh` で fill → `DBG`、color bar | p004、p005、U7 | 20 |
| p013 | KC705 の host link A': PCIe + XDMA、BAR、MSI、`pci-attach.c`、`pcie-reload.sh` | guest の zedBSD から `ghci-blit` PASS | p006、p012、U2 | 24（**後回し**: Future Work fw-kc705-pcie） |
| p014 | KC705 の全 pipeline の bitstream（N=1: VF+SU+RX+TU+ROP、`PACKED`、**CPU と firmware**）、vkdemo を板で（JTAG の bridge で ring と firmware を載せ、画面は DC） | **vkdemo が KC705 で参照と一致** | p011、p024 | 18 |
| p015 | 複数の SU（N=4 → 6〜8）、work の分配、RX 2 本（200 MHz の timing は p025）、PERF、BRAM の実測で N を決める | N=4 で vkdemo、N≥6 で合成が閉じる | p014 | 18 |
| p016 | 規約の全文の見直し（C: driver・firmware）、RTL の lint、`docs/ghci.md` 1.0・`docs/gsi1.md` の確定 | 動作は不変 | p015 | 10 |
| **p024**（新設、2026-10-24 ユーザー「タイミングの調整と KC705 での確認は別なフェーズに分けた方がいいと思います。」） | **KC705 の板での確認**: MIG の IP の生成（`vivado-build-ip.tcl`）、bitstream、JTAG の bridge で fill → `DBG`、HDMI（ADV7511）の color bar、p007・p009 の raster・shade・tex の scene を板で（timing を詰めない低い clock でよい） | 実機で fill → `DBG`、color bar、scene が sim と一致 | p012 | — |
| **p025**（新設、同上） | **timing の調整**（**版 9: 目標の Fmax・clock の領域・段は §19、推しは SU 200 MHz・他 100 MHz（U100）**）: KC705 で 200 MHz（R3）。blend の 2 段化（`plan/ws001/blend-stage-split.patch`）、RX・ROP・SU・TU の pipeline の分割、out-of-context の Vivado での測定 | KC705 の全 pipeline が 200 MHz で WNS ≥ 0 | RTL が揃った後（p009 以降） | — |
| **p027**（新設、版 5） | **MSAA**（§15）: RX の sample の coverage（`atg_rx_cov`）と fragment の入力 r6〜r9（`atg_rx_bary`）、SU の `exp 0x105` と `ex_ms`、ROP の `atg_rop_ms` と sample ごとの ds・wb、TU の MS の `texf`、`msmodel.py`、`atg_top_msaa_tb`、Verilator、GHCI §12.11（draft） | MS の color・depth と resolve が model と word ごとに一致（sim、KC705 と ZYBO の形）、既存の scene が bit で同じ | p009（part F）、U43〜U46 | 41（版 5.1: S7 の BLT の resolve 8、S1 +1） |
| **p030**（新設、版 6） | **Vulkan 1.0 core の残り**（§16）: format の土台（`atg_fmt_*`、sRGB、FMT capability）、VF の format と ATTR_LIMIT、RX の clip（line・point・guard band・depth clamp）と setup（parallelogram・正方形・viewport・bias）、CP の `QUERY`、ROP の f32 の blend・stencil・D16・bounds・clamp・MRT 4・occlusion、TU の format・swizzle・f32 の filter、BLT の分割・KEEP・画素 8/64/128 bit・RESOLVE の平均 3〜7、`atg_top_core_tb`（ETC2 と CP の待ちの修正は範囲の外） | §16.20 の scene が model と word ごとに一致（sim、2 つの形）、既存の scene が bit で同じ（意図した差は vec-diff）、`make verilator` PASS | p027（S5・S7〜S10 の前に各段の merge、CP の待ちの修正）、p009 part F（S9）、U47〜U60 | 79 |
| **p017**（新設） | **CP の CPU と firmware の土台**: `atg_cpu`（RV32IM、§2.4.7）、IMEM/DMEM、制御の window、`UOP_FIFO`、`CPFW` の extended capability（load/run/halt/version/mbox）、class V の packet の受け渡しと `RPTR`、watchdog の対象化、`fw/cp/` の build（共有の clang、`-march=rv32im`）、firmware の runtime（boot、heap、packet の reader、result、µop の出力）、**class V の最初の道**: `GHCI_SESSION_OPEN/CLOSE`・`GHCI_MEMORY`・`CREATE/DESTROY_BUFFER`・`BIND_BUFFER_MEMORY`・`CMD_FILL_BUFFER`/`CMD_COPY_BUFFER` の記録と `QUEUE_SUBMIT` → BLT の µop。bitstream 1'「2D + FW」 | TB: CPU の命令の試験（riscv-tests の自前の部分集合）、firmware の fill/copy が Verilator と **板（ZYBO 1'）**で `DBG` の照合に合う、`CPFW` の載せ替え、firmware の無限 loop → watchdog → RESET → 回復 | p004、U19、U20 | 32 |
| **p018**（新設） | **firmware の Vulkan の object model と draw/dispatch**（§2.4.8）: object の表、image/image view/sampler、`GHCI_PROGRAM`（pipeline の stage の binary と interface の表の検証）、pipeline layout・descriptor set layout/pool/set/update、render pass・framebuffer、graphics/compute pipeline → STATE の word の列、記録の全部の R の command、`QUEUE_SUBMIT` の辿り（bind の状態機械、interface の表で descriptor → `SET_REG`/`LOAD_CONST`、`LOAD_PROGRAM`、barrier、clear → BLT、内蔵の blit/clear の kernel、`DRAW`/`DISPATCH`）、record の VkResult と `RESULT` の IRQ、`DESTROY_DEVICE`/session の close の回収。MSAA の resolve（2026-10-25 05:03 Q1、p027 の U44）: BLT の RESOLVE は STATE 0x00B まで毎回書く、前の draw は `WAIT_IDLE` flags 0 で待つ | Verilator: firmware の試験の harness（host の C から staging と frame の packet を作って流し、µop の列と STATE と record の期待と比べる）、vkdemo の部分集合の command の列が期待の µop になる | p017、p009（STATE の意味）、**p010（binary の interface の表）**、U24 | 44（±50%） |
| **p019**（新設） | **zedBSD の `vk/` = 検証する中継**（§6.7）: codec の生成（`ghci_vkwire.inc`、firmware と共有、M21）と wire の reader（i915 の `i915_wire_reader` を powervr と同じ形で再利用）、D/R/R'/X の表、driver の帳簿（M1）、D の返事（capset・limit・memory requirements・**`ghci_layout.h`**（driver 側の正本の写し、M22）・fence）、R' の書き換え（`GHCI_MEMORY`、pipeline の作成で stage ごとの compile → `GHCI_PROGRAM`）、staging と `GHCI_FRAME`、result page と **reply thread**、jobs の marker（§6.4）、`EXECUTE_STREAMS` の入れ子、session の open/close、host の試験（gpu-op の frame を作って staging と ring の packet の列と返事の blob を比べる）、**ZYBO 1' で libvulkan の `vkCmdFillBuffer`/`vkCmdCopyBuffer` を実 driver で通す試験**（H6。T1 に依頼） | host PASS（staging の列と返事の blob の形が libvulkan の読む形）、ZYBO 1' の fill/copy（板）、**Verilator の端から端は p011** | p006、p010、p017（`GHCI_*` の形）、U24、U26 | 26 |

合計 **446 LW**（表の 19 行を script で足した値。p013 の 24 を除くと 422。p018 の ±22 で 424〜468。SA の p020〜p022（88 LW の見積もり）は Future Work に移して表から外した。p023 の 44 は spec と空の module で、後の Phase の実装の見積もりは「spec から書く」前提なので変えていない。p001 は表に無い）。版 2 は 304。増分の主は firmware（p017 + p018 = 76）で、p011 が 48 → 24 に減った（Vulkan の object の意味が driver から firmware に移った分）。最初の端から端（p002〜p004）は 40 LW、画面まで（p005・p006）で 78 LW。

依存の図（版 5: 合計の 446 LW は p027 の 32 を含まない。p010 が p027 に依るのは §15.11 の MS の入出力の約束（r6〜r9、`exp 0x105`、`texf` の rs2、`texsz.s`）で、p010 の範囲に入れる）: p009（part F）→ p027 → {p010, p018, p019}; p002 → p023（spec）→ {p004, p005, p007, p008, p017} の実装（p003 は済み）; p002 → {p003 → p004, p005} → p006; p004 → p007 → p009; p004 → p008 → {p009, p010}; p004 → p017 → p018 ← p009; {p006, p010, p017} → p019; p010 → p018（binary の interface の表、M22）; {p009, p010, p018, p019} → p011; {p004, p005} → p012 → p013（後回し）; {p011, p012} → p014 → p015 → p016; SA の p020〜p022 は Future Work（下）。循環は無い。**Verilator の端から端（p011）の前に板で見える物**: ZYBO の 1・1'・2・3・4 の bitstream（p003・p017・p005・p007・p008）。
**Phase ↔ module（版 4、§7.6 の木。各 Phase は列挙した spec の module と TB を実装する）**:

| Phase | module |
| --- | --- |
| p004 | `atg_cp_ring`・`atg_cp_seq`・`atg_cp_fence`・`atg_cp_ctl`（ring、watchdog、FAULT/RESET の順）・`atg_cp_irq`、`atg_cp` の結線 |
| p005 | `atg_dc_*`、`zybo_dc` |
| p007 | `atg_rx_*`、`atg_rop_*`、`zybo_raster` |
| p008 | `atg_su_sched`・`rq`（口の予約だけ）・`fetch`・`icache`・`dec`・`sb`・`rf`・`opd`・`alu`・`fpu`・`xu`・`div`・`exec`・`lsu`・`dcache`・`lds`・`cbank`・`wb`、`atg_su` の結線、`zybo_compute` |
| p009 | `atg_vf_*`、`atg_su_tex`・`exp`・`pt`・`lda`、`atg_rx_frag`、`atg_tu_*`、`kc705_raster`（N=1） |
| p012 | `am_jtag_regs`、MIG/MMCM の wrapper、`kc705_raster` の board |
| p017 | `atg_cpu_*`、`atg_cpu_win`、`CPFW`（`atg_cp_regs` の追加）、`zybo_2dfw` |
| p015 | `atg_top` の N 本の結線、RX 2 本、work の分配（`atg_cp_seq` の拡張） |


**ws.md の「進め方（案）」（DC → BLT → CP の順）からの変更（U14）**: 版 2 のまま（CP + BLT が先。`DBG_ADDR/DATA` で DDR を読めるので driver も画面も無しに板で結果を照合できる）。

**Future Work（Q1 が `plan/future-work.md` に登録する候補。番号 p020〜p022 は予約）**: fw-sa-core（p020: `atg_sa` の core = Appendix A.2、trigger「p008〜p010 cleared = SU が GSI1 を実装」、見積もり 36 LW）、fw-sa-online（p022: 案 B の reduction/normalize/token buffer と SA 構成の bitstream、Appendix A の全部、trigger 同上 + p020、32 LW ±50%）、fw-sa-vulkan（p021: 独自の拡張 `VK_KEI_systolic_dispatch`、libvulkan と共有の compiler の変更を含むので別の WS の候補、trigger p020、20 LW）。README の 0.8 TOPS/SU（×2）を満たす PE（2 MAC/cycle）の案は fw-sa-core で。

## 9. risk と U 項目

### 9.1 risk

| # | risk | 対処 |
| --- | --- | --- |
| R1 | **7010 に全 block が入らない**（§3.6: 全部で 111%、graphics+SU で 97%） | **block を分けた bitstream**（§3.6 の 1〜4）で板の workflow と各 block を確かめ、結合は Verilator と KC705（U17）。p002・p008 の実測で係数を直す。係数が 20% 良ければ「graphics + SU」を試す |
| R2 | fp32 の pipeline が 100 MHz で閉じない（7010-1） | DSP の pipeline を全段。閉じなければ ZYBO は 50 MHz（`GCLK_HZ`） |
| R3 | KC705 で 100 → 200 MHz（2026-10-23 README のユーザーの目標。150 MHz は版 2 の値） | p015 で。100 MHz でも N=8 で 25.6 GFLOPS |
| R4 | HP の AXI3 の細部（WID、WSTRB、outstanding）の誤り | p002 の TB の protocol checker、p003 の板で `DBG` を先に。UG585 を p002 で読む |
| R5 | PS の DDR の non-coherent で uncached の alias が遅い | ZYBO は workflow の板。cache を使う道は後 |
| R6 | 1 ring・1 queue | v1 の限界。p015 の後に複数 |
| R7 | GPU MMU が無く、session の隔離が無い | v1 は「1 user の板」。MMU は GHCI の capability で将来 |
| R8 | spill 無し・cube/3D 無し・NREGS 32 で shader が通らない | vkdemo から始め、`ENOTSUP` と log。§3.7 の未達の表 |
| R9 | p011 の規模（±50%） | U8 で部分集合を固定、powervr の `vk/` を型に |
| R10 | PCIe の link が FPGA の書き直しで落ちる、BIOS が BAR を割り当てない | A' の `pcie-reload.sh`（SBR、rescan）、flash からの設定か `pci=realloc` |
| R11 | AMD の IP の bitstream の配布 | U6 |
| R12 | KC705 の HDMI が未確認 | U7。p012 は `DBG` で受け入れ |
| R13 | ZYBO の TMDS の速さ | VGA を先に。640×480 から |
| R14 | （版 2 で解消: ZYBO は IRQ 61 だけを使う） | — |
| R15 | （版 2 で解消: 窓は 64 KiB のまま、DC だけの bitstream は offset 0） | — |
| R16 | 共有の header・仕様・RTL・driver の 4 つがずれる | `ghci-sync.sh`、版の定数の比較、p016 で照合 |
| R17 | Verilator が無い（U3 が否） | iverilog の全体の TB（遅い） |
| R18 | 32 lane の warp を NPHYS で分ける sequencing の誤り | NPHYS 8/16/32 で同じ model と比べる（p008） |
| R19 | GHCI の一般化が重くなる | v1 は Amaterrace の形だけを標準に。実行の model は vendor（§2.1） |
| R20 | 統一 shader の deadlock（§3.8）、ROP の順序 | 予約の規則と scoreboard。p007・p009 の TB |
| R21 | 325T の BRAM（N=8 で 98%） | p015 で RF の複製 2 か NREGS 32 か primitive table の複製の削減を実測で選ぶ。N=6 を許容 |
| R22 | detach の競合で device が offline のまま残る（§6.2 の 3） | retry と 5 s の上限。次の attach は新しい登録 |
| R23 | （版 3）image の layout の式が driver（memory requirements の返事）と firmware（bind・draw）で食い違う | 式は `ghci_layout.h` の 1 つの C の関数（amaterrace-gpu が正本、zedBSD は写し、§7.2）。host の試験で両方の写しを同じ入力で比べる（p019） |
| R24 | （版 3）`LOAD_CONST` が暗黙の `WAIT_IDLE(SU)` を挟むので push constant が変わる draw のたびに pipeline が空く | v1 は受ける（vkdemo・compositor の draw 数では ≤ 1 ms/frame の見込み）。p015 で constant の領域を warp ごとの base（STATE の word を SU が warp の開始で読む）に変える案を実測で決める |
| R25 | （版 3）`atg_cpu` が 325T -2 で 200 MHz に閉じない | 3 段の短い pipeline、BRAM の IMEM/DMEM を register で挟む。閉じなければ CPU だけ `gclk/2` の領域（`am_afifo` で µop を渡す） |
| R26 | （版 3）firmware が IMEM 32 KiB に入らない | 目標 64 KiB 以内で設計し、IMEM を 64 KiB（BRAM36 16）に出来る parameter にする。7010 の bitstream 1' でも BRAM は 60 の内 25 | **（2026-10-25 ユーザー「IMEM を 128 KiB」: KC705 は IMEM 128 KiB（BRAM36 32）、DMEM は 0x0002_0000 から。firmware が 64 KiB を使い切ったため。p034 の R6、amaterrace p1-p034 34cb3ae）**
| R27 | （版 3）REPLY を求める frame ごとに firmware の往復（`QUEUE_SUBMIT`・create は毎回）で latency が積む | result は firmware が解いた時点で書き、GPU の完了は待たない（H1）。1 往復 = firmware が frame を解く時間（µs〜十数 µs）+ IRQ + reply thread。p011 で計測。libvulkan の transport の timeout は 10 s（`context.c`） |
| R28 | （版 3）firmware の Vulkan の部分集合が compositor の要る物に足りない（p018 の規模 ±50%） | U8 の順（vkdemo → compositor の最小 → mview）で部分集合を固定。足りない物は result の `VK_ERROR_FEATURE_NOT_PRESENT` で見える |
| R29 | （版 3 → 版 4、延期）SA の DSP が 325T に入らない | SA は延期で KC705 に入らなくてよい（§3.9）。Appendix A の sketch |
| R30 | （延期）SA の入力の帯域と律速 | Appendix A |
| R31 | （延期）`rq` の deadlock | Appendix A |

### 9.2 U 項目（ユーザーの判断。各々に推し）

2026-10-23 ユーザー「推しでオーケーです。」→ U18〜U28・U37・U38 は推しで決定（U29〜U36・U40 は版 4 で取り下げ、U39 は閉じた）。


2026-10-23 ユーザー（U2）: PCIe は「フリーズしたときホストPCの再起動は必要ですか？」等の問いの後「了解です。安定してきたらPCIeにしましょう。PCをSwitchbotで電源ON/OFFはできますが、BIOSが停電後の自動電源ONができるかは不明です。」→ U2 は「当面 KC705 は USB JTAG だけ（構成も操作も JTAG の bridge）。GPU が安定したら PCIe（Alveo 型: USB JTAG で構成し PCIe で Linux から。flash の基本の bitstream か部分再構成の固定の領域で link を保つ）」。p013 は Future Work fw-kc705-pcie。README の目標「Synthesis goal is 200MHz on KC705 board and 800MHz for ASIC processes.」（ユーザー、c840a0a）により KC705 の gclk の目標は 200 MHz（p015、R3 の 150 MHz を改める）。


2026-10-23 ユーザー「U項目は推奨で承認します。」→ U1・U3〜U17 は推しで決定。U2 は同時の問い「KC705はUSB JTAGで運用できませんか？」への答えの後に確定（保留）。


| # | 問い | 推し |
| --- | --- | --- |
| U1 | amaterrace-gpu の license と GHCI の仕様の文書の license | **Zlib**（仕様の文書も） |
| U2 | KC705 の host link と PC | **A'**（Linux の PC + VFIO + QEMU の zedBSD）。PC は 10.0.30.5 の 13400F の desktop の 2 本目の slot（x8 以上が空いているか）。sukuna-risc は後から |
| U3 | host に Verilator（Debian の package、sudo）を入れる。cocotb は入れない | **入れる** |
| U4 | ZYBO の GPU の memory 64 MiB（p003 から DTB の `/reserved-memory/gpu@1c000000`（64 MiB、no-map）、p006 からは同じ領域を `pl-memory.c` の pool に） | **64 MiB**（決定済み。版 4: 448 MiB の `memory@0` の縮小は採らなかった: `make-zybo-boot-files.py` が 512 MiB を要る） |
| U5 | 7010 の SU の構成を小さく（NPHYS 8 → 4、NWARPS 4 → 2、TU 無し、stencil 無し） | **可** |
| U6 | AMD の IP の bitstream の配布は EULA の確認まで保留 | **この規則で** |
| U7 | KC705 の HDMI: UG810 をユーザーが host に置く | **置いてもらう**。無ければ HDMI は別 Phase |
| U8 | Vulkan の v1 の部分集合 | **vkdemo → compositor の最小 → mview** |
| U9 | PCIe の照合は class code 0x038000 + BAR0 の magic。Amaterrace の subsystem は "AT"/"G1"、device ID は PCIe の IP の既定のまま | **この形**（vendor/device の固定の組にしない） |
| U10 | 名前: `src/drivers/gpu/ghci/`、`ghci_`、`isa/gsi1/`（版 3）、driver_name "ghci:AMAT:ATG1"/"ghci-dc:AMAT:ATDC"、`GPU_OP_GHCI_*` = 0x10100〜、`ghcictl`、`ghci-*` の試験、`pl-memory.c` | **この名前**（Q1 が番号と devfs を確かめる） |
| U11 | ZYBO の VGA を HDMI より先に | **VGA が先** |
| U12 | **register file**: 7010 は NREGS 32・NWARPS 4（BRAM36 12）、325T は NREGS 64・NWARPS 4（24/SU） | **この値**。複製 3 → 2 は p008 の実測で |
| U13 | GHCI の範囲（§2.1） | **この範囲** |
| U14 | ws.md の順（DC → BLT → CP）を CP + BLT → DC に変える（§8） | **変える** |
| U15 | ZYBO の SU で 16 bit packed の演算器を外す（README の「16-bit packed」からの逸脱。`PACKH/UNPACKH` は残す。KC705 は有り） | **外す**（7010 の DSP と LUT） |
| U16 | WS286 の例外（ZYBO の実機は生きた serial で判定、JTAG を使う Phase は担当が板を直に触る）を WS001 にも適用する | **適用する**（AGENTS.md の例外の行に WS001 を足すのは Q1） |
| U17 | 7010 では block を分けた bitstream で確かめ、全体の結合は Verilator と KC705（§3.6） | **この方針** |
| **U18**（版 3） | 標準の shader ISA の名前と FourCC: "GSI1"（GHCI Shader ISA 1）。Amaterrace の native = GSI1。`isa/gsi1/`、`docs/gsi1.md`、`gsi1_isa.h`、`gsi1asm.py` | **"GSI1"**（GHCI の標準なので vendor の名前（ATS1）を付けない） |
| **U19**（版 3） | CP の形: F. firmware（`atg_cpu` RV32IM + `fw/cp/`）か H. hardware で gpu-op を解くか（§2.4.7） | **F**（H は部分集合でも 6〜10k LUT、pipeline の作成は不可能に近く、結局 driver が µop を作る事になる） |
| **U20**（版 3） | `atg_cpu` の RTL の置き場所と出自: (a) amaterrace-gpu の `rtl/gpu/cp/atg_cpu.v` に最小の RV32IM を新しく書く、(b) sukuna-risc に RV32 の最小の構成を作って使う（README の構成は RV64GC・22k LUT で 7010 に入らない） | **(a)** を p017 で。bus の口（IMEM・DMEM・制御の window・AMB の port）を文書にし、後で (b) に差し替えられる形にする |
| **U21**（版 3） | firmware の配り方: (a) bitstream の BRAM の初期値だけ（driver は file を要らない）、(b) (a) + zedBSD の `userland/firmware/amaterrace/atg1-cp.bin`（Zlib、amaterrace-gpu の commit を記録）を `CPFW` で載せ替え | **(a) を v1**、(b) は開発の反復（`ghcictl fw-load`、root）のために `CPFW` の capability だけ作る。blob を zedBSD の tree に入れるかは p017 の後に Q1 に聞く |
| **U22**（版 3） | 命令の長さ: (a) 64 bit 固定（word0 = RISC-V の 32 bit の形、word1 = 拡張）、(b) 32/64 の可変（AMD 型）、(c) 32 bit 固定（純粋な RISC-V の形、r0〜r31、修飾無し） | **(a)**（§3.3。decode が 1 種類、FMA の 3 source + 修飾 + 64 本の register が入る、word1 = 0 で RISC-V の形がそのまま読める） |
| **U23**（版 3） | 比較命令（`slt*`・`feq/flt/fle`）の結果を RISC-V の 0/1 でなく all-ones/0 の Boolean にする（共有の IR と同じ。RISC-V からの逸脱） | **Boolean**（compare の unit が 1 つで済み、`sel`・`exec.*` が直に読める） |
| **U24**（版 3） | 返事（reply）の書き手: (a) driver が全部書き、firmware の結果は result の record（frame の最後の FENCE を待つ）、(b) firmware が返事の blob に直接書く | **(a)**（返事の cursor は frame の中で順に進むので、2 つの書き手では順序が守れない。§2.4.6） |
| **U25**（版 3） | ZYBO の bitstream 3「raster」・4「compute」に `atg_cpu` を入れない（class N で板の受け入れ。class V の全部の道は Verilator と KC705）。bitstream 1'「2D + FW」を p017 で足す | **入れない**（4 は 78% + 2.5k ≈ 92% で閉じない見込み） |
| **U26**（版 3） | `GPU_OP_GHCI_*` の番号（0x10100〜0x10104 の案、§2.4.5）と `include/uapi/gpu-op.h` への追加の文 | **この番号**（Q1 が U10 と一緒に確かめる） |
| **U27**（版 3） | `shfl`/`vote`/`ballot`（subgroup の命令）を GSI1 の **optional**（`CAPS[24]`）にし、Amaterrace は KC705 だけ実装（+0.5k LUT/SU）、ZYBO は無し | **optional** |
| **U28**（版 3、SA） | FIFO の register の番号: **63**（operand の空間の最上位。GPR は r0〜r62）。NREGS 32 の構成でも 63 | **63** |
| U29〜U36・U40（版 3・版 4 の SA の詳細） | **取り下げ**（2026-10-23 ユーザー「SAの設計と実装はかなり後に回して…」）。Appendix A の sketch に残し、fw-sa-* の時に立て直す | — |
| **U39**（閉じた） | README の「Systolic Array: 32 x 32, 0.8 TOPS/SU @200MHz」の数え方 | ユーザー「積和を 1 回 2 op と数えた上で 2 倍にしてます」= 32 × 32 × 2 op × 200 MHz × 2。×2 の根拠は未記載（推測: PE あたり 2 MAC/cycle）。README はそのまま。延期した SA の設計は ×2 を満たす形にする（§3.9） |
| **U37**（版 4） | spec の置き場所と形: amaterrace-gpu の `spec/` が `rtl/` と同じ path、Markdown、template は §7.6 の 10 節、`spec/README.md` | **この形** |
| **U38**（版 4） | module の大きさの規則: ≤ 400 行、状態機械 1 つ、clock の領域 1 つ、port ≤ 40 | **この規則** |

HAL（`include/hal/hal.h`）の変更は **無い**。

## 10. 選ばなかった案と理由

| 案 | 理由 |
| --- | --- |
| 1. GPU MMU を v1 から | 7010 に入らない。aperture で「CPU の memory を壊さない」は守れる。GHCI の capability に場所を残した |
| 2. AXI Interconnect の IP | 7010 の LUT と simulation の model。自前の AMB |
| 3. predicate register と divergence の stack | compiler が exec を管理する（ユーザーの合意）。IR が if-converted |
| 4. register ごとの scoreboard | class の counter + `WAIT` の方が小さい |
| 5. 専用の補間の unit | `LDA` + FMA は小さく、varying の数が可変。性能が要る時に `IPL` |
| 6. SU が bilinear を命令で | 命令数 4 倍。ZYBO は TU 無し、KC705 は unit の bilinear |
| 7. tile-based の rendering | 7010 の BRAM。immediate mode から |
| 8. DC を GPU の中に | ユーザーの決定（別の IP）。KC705 では 1 つの driver の device に載せる（§6.5）|
| 9. cocotb | Verilator の C++ の harness と iverilog で足りる |
| 10. KC705 の host を soft CPU から | GPU の bringup が CPU に直列。PCIe + VFIO は既存の運用に載る |
| 11. 64 bit の fence・`WAIT_FENCE` の無し | 32 bit + `(int32)` + 折り返しの規則で足りる |
| 12. ring を複数に v1 から | p015 の後 |
| 13. bitstream を zedBSD の tree に | U6 と tree の分割 |
| 14. ACP で coherent に | L2 と SCU の前提が増える。HP + uncached |
| 15. warp の幅を板ごとに変える | README の「32-lane」。`32/NPHYS` cycle で流せば ISA は 1 つ |
| 16. vendor ごとの driver | README の GHCI の趣旨に反する。汎用の `ghci/` + ISA の backend |
| 17. 軽い fence（BRESP だけ） | 完了の意味が二重になり、driver の寿命の規則を誤る（C3）。v1 は完全な fence だけ |
| 18. 7010 で全 block を 1 つの bitstream に無理に入れる（NPHYS 4、varying 8…） | 97〜111% で timing と配線が閉じず、workflow の確立という目的に合わない。block ごとの bitstream の方が各 block の板の受け入れが早い |
| 19. `fpga.window` の boot parameter で窓を 128 KiB に | devcfg に無い機能を足す Phase が p005 の前に要る。DC だけの bitstream を offset 0 に置けば不要 |
| 20. PCIe を vendor/device の固定の組で照合 | AHCI/xHCI の class code の照合と違い、「汎用」に反する |
| 21.（版 3）CP の hardware が gpu-op の wire を解く | pNext の chain・配列・入れ子の構造体・u64 の識別子の表を RTL で解くのは部分集合でも 6〜10k LUT で、pipeline の作成は不可能に近い。結局 driver が object を解いて µop を作る = 版 2 の形に戻り、「ring は gpu-op」の決定に反する（§2.4.7） |
| 22.（版 3）firmware が返事の blob に直接書く | 返事の cursor は frame の中で順に進み、D の返事（driver）と R の返事（firmware）が混ざる frame で順序が守れない。result の record と frame の最後の FENCE で十分（§2.4.6） |
| 23.（版 3）32 bit 固定の純粋な RISC-V の形 | FMA の 3 source + 修飾、64 本の register、constant/特殊 operand、texture の slot、32 bit の即値が入らない。`lui`+`addi` の対と `mv` が増え、shader の性能に効く |
| 24.（版 3）32/64 bit の可変長（AMD 型） | fetch が 2 word の窓と line を跨ぐ場合を扱い、PC が 4 byte 単位になる。I$ の密度の利点は shader が小さいので要らない |
| 25.（版 3）sukuna-risc をそのまま CP の CPU に | README の構成（RV64GC、2-issue、SMT、約 22k LUT）は 7010 の 125%。制御 processor には過大。RV32 の最小の構成が出来たら差し替える（U20） |
| 26.（版 3）driver が Vulkan の object を解いて µop の列を ring に書く（版 2 の形を保つ） | ユーザーの決定（ring は gpu-op）に反し、driver が vendor ごとになる。class N の道は試験と bring-up に残した |
| 27.（版 3）scalar unit（AMD の SALU）と scalar の register | uniform な値は `vote`/`ballot` と constant bank で足りる。SU の LUT を増やさない |
| 28.（版 3）hardware の divergence stack と predicate register | 版 2 の案 3 のまま（compiler が EXEC を管理、IR が if-converted） |
| 29.（版 3）`fdiv.s` を hardware に | IR に FDIV は無く、`rcp` + Newton で足りる。除算器は整数だけ |
| 30.（版 3）SA を SU の中の命令（`mma` 型の tensor の命令）に | ユーザーの要件（SA は SU と decoupled、FIFO で横の口に）。decoupled なら SA の大きさ・型を SU と独立に決められ、SU 無しの DMA の mode も将来足せる |
| 31.（版 3）SA の FIFO を特殊 operand（96〜127）に | dst の field は 0〜63 だけなので push が書けない。register 63 を予約すれば push も pop も普通の命令の operand で済む |
| 32.（版 3）weight-stationary（TPU 型）の SA | 重みを MC から stream する要件に合うのは出力固定（A は横、B は縦に流れ、C が PE に留まって drain で横から出る）。weight-stationary だと C が縦から出て「横の口の RW」に合わない |
| 33.（版 4）SA の PE を SIMD-8（32 × 32 × 8 = 8192 MAC/cycle）に | 2026-10-23 ユーザー「了解、SIMD-8はやめましょう。」。KC705 では DSP が 840 の約 10 倍、LUT が約 3 倍、activation の供給 256 値/cycle（SU の 32 の 8 倍）、重み 256 byte/cycle ≈ 38 GB/s（DDR3 12.8 GB/s）で成り立たない。**PE は SIMD 1 で、大きさは配列の数・列数・clock で伸ばす**（32 × 32 × 1: 200 MHz ≈ 0.41 TOPS、ASIC 800 MHz ≈ 1.6 TOPS、mixed INT8/FP16） |
| 34.（版 4）SU の vector 命令と投機的な online softmax（SU の warp が `rq` から 1 列ずつ pop して packed FP16 の命令で処理） | 2026-10-23 ユーザー「SUにベクトル命令と投機的オンラインsoftmaxの実装を考えましたが、ハードウェア効率が悪すぎるので、案BでSAに寄せましょう。SUはミニマルな形にしましょう。」→ reduction は SA の出口、normalize は SA の入口、SU は指揮だけ（案 B、§3.9 の 4、Appendix A）。その後 SA 自体を延期 |

## 11. 敵対的な読み直し（版 2 の自己点検）

1. 完全な FENCE（§2.4）は BLIT と DRAW の非同期性を毎回打ち消す: submit ごとに 1 つの fence なので、1 submit の中の複数の draw は並ぶ。性能が要る時は軽い fence を後で足す（案 17）。
2. detach の 3（§6.2）で device が offline のまま 5 s を超える事: `fpgaload` に `EBUSY` を返し、次の `fpgaload` で retry する。永久に残らない（session は ENODEV で閉じる）。
3. `RPTR` で ring を再利用してよい（§2.7）は、CP が packet を **block に写し終えている**事が前提。`SET_REG` の value は STATE に写すので良いが、`DRAW` の payload（gx・gy・gz など）も CP の register に写す（block は ring を読まない）。RTL の規則にする。
4. KC705 の BAR1 の読み戻し（§2.7）は PCIe の往復（µs）で、submit ごとに 1 回なら許容。
5. 32 lane の coalescer は `32/NPHYS` cycle に分けて比較するので、1 つの `LDG` の address の計算に NPHYS/32 の割合で cycle が要る（performance の話で正しさではない）。
6. `KILL` の sticky が EXEC と別なので、`EXEC_SAVE` の値に killed が混ざらない。compiler は loop の条件に killed を含めない（IR の `KILL` の後の code は走ってよい）。
7. ZYBO の DC だけの bitstream が IRQ 61 を使い、GPU の bitstream も 61 を使う: 同時に居ないので衝突しない。KC705 は MSI で分ける。
8. §3.6 の表は内訳から計算したが係数は推定のまま。p002 と p008 の実測が最初の仕事（表に明記）。

版 3 の自己点検:

9. gpu-op の wire に長さが無いので、driver は中継する command の引数を**全部**解けなければ ring に載せられない（§2.4.2）。知らない sType の chain は拒む。これは bcm2711・i915 と同じ制約で、libvulkan が送る形は gpu-op.h が全部書いている。
10. class V の packet を firmware が解いている間、ring は止まる（µop は 1 本）。長い object の作成（pipeline）が draw の列に挟まると GPU が空く。v1 は受ける（object の作成は frame の前）。複数の ring（R6）の時に class V を別の ring に分ける。
11. firmware の無限 loop は watchdog（class V の packet も `WDT_CYCLES` の対象）で FAULT → RESET → firmware の再起動。heap は driver が作り直すが **他の session の object も全部消える**（v1 の回復は device 全体、§2.5 と同じ）。
12. R の command の返事は firmware が command を解いた時点の record から書く（§2.4.6）ので、`vkEndCommandBuffer`・`vkQueueSubmit` の VkResult は Vulkan の規格どおりの場所で返る。GPU の実行の誤りは fence の error（job の ERROR）で出る。
13. 64 bit 固定の命令で word0 が RISC-V の形でも、**RISC-V の binary は動かない**（x0、Boolean、分岐の意味が違う）。「RISC-V を基にする」の意味は §3 の冒頭に限る。
14. `shfl` の staging RAM は NPHYS の複製（§3.6 の +0.5k/SU は NPHYS 16 の値）。NPHYS 32 では 32 複製 = 32 Kbit の distributed RAM（1k LUT）。KC705 は NPHYS 16 なので問題ない。
15. scoreboard の entry が texture の rd..rd+3 を 1 entry で覆う（width）ので、4 register の内の 1 つを読む命令も止まる。正しい。
16. `ISA fault`（種別 8）は warp を止めるが他の warp は続く → device 全体の FAULT で止める（§2.5）。「他の session は続ける」は parse の誤りだけ、の規則のまま。
17. `rq` の pop が発行の段で止まる間、同じ warp の後ろの命令は出ない（in-order）が他の warp は出る。SA の dispatch の warp が全部 pop で止まり、SA が drain に入らない（K 回の push が揃わない）と止まる → `sactl 2`（drain）は push が K に満たない時は拒む（`sastat` で分かる）。compiler は K を `SA_K` と一致させる。
18. `rq` を dst にする命令が EXEC の外の lane で 0 を push する規則は、lane の mask で行列の一部を 0 にする用途（端の tile）に使える。

## 12. review の指摘と対応（版 2、design-reviewer、2026-10-23、38 件。節の番号は版 2 の物）

| # | 指摘（要旨） | 対応（節） |
| --- | --- | --- |
| C1 | detach が unregister の EBUSY を当てにしていたが、unregister は先に device を offline にする。level shifter を閉じる前の AXI の静めが無い | §6.2 の detach の状態機械（session の数を先に見る、quiesce、retry、5 s の上限）。JTAG の書き直しは attach 中は禁止 |
| C2 | watchdog が AXI_IDLE を待たずに reset、KC705 の DC で AXI_IDLE が真にならない、DC が core の reset を受ける | §1.3: reset の領域を 3 つに分け、quiesce を定義、AXI_IDLE は GPU の client だけ、hardware は自分で reset しない、`AXI_STUCK` |
| C3 | FENCE が非同期の block の完了を含まない。IRQ の時点 | §2.4: 完全な fence（全 command の完了 + ROP の flush + 全 BRESP → 書く → その BRESP → IRQ）。軽い fence は無し（案 17） |
| H1 | cap の組が登録を通らず、libvulkan にも見つからない。jobs・capset が無い | §6.4: cap の組、jobs/commands/recovery の ops、capset（powervr の形、vendor の suffix） |
| H2 | 64 KiB の alias で二重 attach | §2.2: 17 bit を解き範囲の外は 0。登録は DEVICE_ID と EXTCAP も見て二重を拒む |
| H3 | `fpga.window` は実在せず、IRQ 62 も未対応 | §5.1・§6.2: ZYBO の DC だけの bitstream は窓の offset 0・IRQ 61。128 KiB の窓は KC705 の BAR0 だけ。R14・R15 を解消 |
| H4 | devcfg の IRQ 61 の handler と `fpgareg` の生の書き込みが driver と競合 | §6.2: attach 中は IRQ を block の driver に渡し、`FPGA_IRQ_WAIT`・`REG_WRITE` は EBUSY |
| H5 | CP の状態遷移が無い | §2.6 の表（状態、受ける物、reset で残る/消える register） |
| H6 | ring の wrap・満/空・RPTR の意味・barrier・先読み | §2.7 |
| H7 | 非同期の fault の帰属、session 単位の回復の穴 | §2.5: v1 は device 全体の fault → reset、session の error は parse の誤りだけ。JOB_TAG を header と FAULT_INFO に |
| H8 | 統一 shader の deadlock、PT の定義 | §3.8（新設）、§3.5 の PT、§3.6 に BRAM |
| H9 | ROP の rasterization order | §3.8: 番号と scoreboard。p007 の TB に重なる blend の順 |
| H10 | cache の無効化の約束が無い | §2.4 `INVALIDATE`、DRAW/DISPATCH の暗黙の無効化、ISA の `FENCE acquire`・`ATOM` の規則 |
| H11 | 見積もりの足し算が内訳と合わない | §3.6 を内訳から計算し直し（FMA 400 LUT）。結論を「7010 では block を分けた bitstream」に変え（R1・U17）、「極小は入る」を取り下げ |
| H12 | p011 ↔ p013 の循環 | §8: p013 は `ghci-blit` だけ、p014（KC705 の全 pipeline、N=1）を新設、p011 の板は p014 |
| H13 | 2 device の share の ops の取り違え、pool の所有者 | §5.2・§6.5: GPU は share、DC は scanout の import。pool は `pl-memory.c`（devcfg の寿命） |
| H14 | KC705 の device-local の VRAM は pages で表せない、BAR0 の外 | §6.5: KC705 は 1 device（same-device の share）。BAR0 を 128 KiB に |
| H15 | 標準に ATS1 の実行の model が混入、PCI の固定の組、「汎用」の過大 | §2.1・§2.3: 実行の model を vendor へ（slot、constant の領域、VEND の register）。PCI は class code + magic（U9）。README の文を直した |
| M1 | native の packet の検査 | §6.4: `CONFIG_GHCI_NATIVE` と root、opcode と index の白表 |
| M2 | DBG_DATA が GP0 を長く止める | §2.2: 非同期（ADDR → STATUS の poll → DATA）、slave は待たせない |
| M3 | EXTCAP の next の幅 | §2.2: 2 word の entry、相対の dword 数 16 bit |
| M4 | DC だけの header が CP の有無を表せない | §2.2 CAPS[0..3]、§5.1 の 10 word、attach の分岐 |
| M5 | 32 byte line と MIG の 512 bit、client の上限 | §4.1: `LINE_BYTES` 32/64、client ≤ 32 |
| M6 | IR の下げ方の漏れ、KILL の後の副作用 | §6.6 の全 op の表、§3.1 の killed の規則、`TEXB`・`TEXF` の level・`TEXSZ` の level・`QSWAP sub 3` |
| M7 | barycentric の意味、clip の頂点、provoking | §3.4 の入力（補正済み、元の 3 頂点）、§3.8 の clip、`PROVOKING` |
| M8 | Vulkan の最小の limit の未達 | §3.7 の表（属性 16、slot 16、mip 13、instancing を足す。indirect・cube は未達として記録） |
| M9 | DSP の主張、packed と「同じ binary」 | §3.4: DSP 2、`PACKH/UNPACKH` は必須、`PACKED` の無い構成は U15 |
| M10 | RF の書き込み port、LDA の port | §3.5: 書き込みの調停、primitive table の複製（§3.6 に） |
| M11 | MMCM の出力の数、25.175 | §1.3・§5.1: v1 は 2 mode、1 MMCM の 4 出力、BUFGMUX、25.2 MHz の注意 |
| M12 | fence の wrap・reset の初期化、IRQ での mutex | §2.5（書き戻しと折り返し）、§6.3（回収の thread） |
| M13 | PCIe の最初の列挙、SBR、MSI の vector | §4.3 A'（flash か realloc、SBR、vector の表） |
| M14 | LW と試験の計画の漏れ、ZYBO の例外 | §8 の LW（p006 24、p008 30、p011 48）、§6.8 の試験（detach/reattach、fault の注入、wrap の負荷、2 device）、U16 |
| L1 | reset の極性 | §1.3 |
| L2 | RF の表の重複、NPHYS 32 の BRAM | §3.5 |
| L3 | 参照の誤り | 直した（§11 の番号を付け直し） |
| L4 | `/dev/gpuN` の番号 | §6.1: 空いている最小 |
| L5 | `hal_*` でなく `kern_*`、末尾の保証 | §6.1・§6.3 |
| L6 | ws.md の mc64、順序の変更の記録、README の確定値の書き方、FRAME_COUNT の 64 bit | ws.md を直す（P2 の path）、U14、README-additions を「proposed」の書き方に、§5.1 の FRAME_COUNT |

## 13. review の指摘と対応（版 3、design-reviewer、2026-10-23、49 件: Critical 2・High 10・Medium 22・Low 15）

（注: 版 4 の最後で SA の詳細は Appendix A に移った。この表と §14 の「§3.9.x」「Appendix A.x」は sketch の中の節を指す。）

reviewer が照合した code: `gpu-op.h`、`gpu.h`、`gpu-job.h`、`drivers/gpu/gpu.h`、`gpu.c`、powervr の `vk-stream.c`・`render-runtime.c`・`vk-draw.c`、`compiler/ir.h`・`spirv.h`、libvulkan の `context.c`・`queue.c`・`sync.c`・`commands.c`・`external-properties.c`・`memory.c`、Guardrail、共有の LLVM の resource dir、amaterrace-gpu の `ghci_regs.h/.vh`・`ghci_packets.h`・`atg_mc.v`・`atg_cp.v`。P1 が対応の前に確かめた物: `spirv.h:48` の `drv_gpu_shader_parse` の stage、`gpu.h:36・53〜56` の ops の形、powervr の `runtime_reserve/commit`（marker、`powervr_session_pend`）、`gpu.c:1140・1155・3310・6032`（`command` と `commands->submit` の使い分け）、`context.c:884〜891・962`（通知の後に trailer を poll）、`build/llvm/lib/clang/<版>/` に `lib/` が無い事、P2 の `ghci_regs.vh` の `GHCI_EXTCAP_LIST = 0x100`・`PERF_SRC0 = 0x110`。

| # | 指摘（要旨） | 対応（節） |
| --- | --- | --- |
| C1 | `CREATE_SHADER_MODULE` の時には stage も entry も interface も無く compile できない。binary に resource の表が無い | compile は **pipeline の作成の時**に stage ごと（59・60 は D、65・66 は R' で `GHCI_PROGRAM [pipeline][stage]` を先に送る）。binary の header に **interface の表**（属性・varying・uniform block・sampled image・storage・push・shared）を足し、firmware が descriptor を slot に写す唯一の約束にした。v1 は stage ごとに entry 1 つの module だけ。p010 が表を確定し p018 が依存（§2.4.4・§2.4.5・§3.4.4・§6.6・§8） |
| C2 | `reserve` に sequence は無く、commit の前に fence が完了し得る。「commit = doorbell」と submit の中の doorbell が矛盾 | powervr の marker の形に: driver の 32 bit の device 全体の fence、`QUEUE_SUBMIT` の frame が FENCE を置いて session の「最後の fence の値」を更新、commit は marker をその値に結ぶ（過ぎていれば commit の中で完了）、通常の cancel・fault の cancel を書いた（§6.4・§2.4.9） |
| H1 | 返事を完全な FENCE で待つので submit・create が GPU の完了を待つ | result は **firmware が command を解いた時点**で record に書き、frame の最後に `RESULT` の IRQ。FENCE は job の完了だけ。R27 を直した（§2.4.6） |
| H2 | 1 MiB の記録の frame が ring に入らず、満の時に待つ手段が無い | class V の frame は **staging**（GPU の memory の環、4 MiB）に写し、ring には `GHCI_FRAME`（8 dword）だけ。1 frame に割り込み 1 回。ring の満は `IRQ_STATUS[8] RETIRE` で待つ（§2.4.6・§2.7） |
| H3 | module の destroy で binary を解放すると pipeline が解放後の memory を実行する | binary は pipeline の物（C1）。`DESTROY_PIPELINE` の後に session の最後の fence が過ぎてから返す（§2.4.4） |
| H4 | firmware の再起動で DMEM が初期値に戻らず、CPFW は IMEM だけ | `CPFW_IBASE/IWORDS` と `CPFW_DBASE/DWORDS` の 2 対、`.data` の原本を像の中に持ち `boot.S` が毎回写す、p017 の受け入れに試験（§2.4.7・§2.2） |
| H5 | `-march=rv32im` の clang は `div` を出す。compiler-rt が無い | RV32IM の全部を hardware（逐次の除算器 0.3k LUT）、`mem*`・`__udivdi3` 等は `fw/cp/` に自前。toolchain は変えない（§2.4.7） |
| H6 | libvulkan + driver + firmware を端から端で流す場が無い（KC705 に host が無い、ZYBO は 1' だけ） | p011 に host の harness（偽の drv_gpu + Verilator の DPI）を明記、p019 に ZYBO 1' で libvulkan の fill/copy、p020 に KC705 の JTAG の道具 `ghci-sa-jtag.sh`（§8） |
| H7 | SA の FIFO を dispatch の全 warp が共有して混ざる | **1 warp が `sactl 4/5` で acquire/release**（他の warp は fault、acquire は空くまで止まる）。CP は SA の dispatch を直列に（§3.9） |
| H8 | `VK_KHR_cooperative_matrix` はこの SA の形では実装できない | U30 を (b) NATIVE → (c) 独自の拡張 `VK_KEI_systolic_dispatch` に変え、cooperative matrix は v2 の Future Work（条件を書いた）。p021・§6.10・Appendix A.4 を直した |
| H9 | `rq` を class m/t/x の dst にすると順序が狂う。暗黙の register の範囲が 63 に掛かる | `rq` は class a・f だけ、m/t/x の dst と暗黙の範囲が 63 に掛かる命令は ISA の fault。push の満は credit で（§3.9） |
| H10 | firmware が STATE を window から直に書くと非同期の block と競合 | window の STATE は読みだけ。書きは `UOP_FIFO` の `SET_REG` だけ（§2.4.7） |
| M1 | 「driver は object の意味を知らなくてよい」が D の表と矛盾 | driver が持つ物（帳簿・create info・bind・SPIR-V・fence・記録の状態）を列挙し、p019 を 6〜8k 行・26 LW に（§2.4.4・§6.7） |
| M2 | 返事の cursor の順序（D と R が混ざる frame） | R の返事の大きさは gpu-op.h の「Reply」で決まるので cursor を空けて後で埋める（§2.4.6） |
| M3 | ioctl の中で眠る案は NOTIFICATION の形に合わない | 眠らない。device の reply thread が IRQ で返事と trailer を書いてから `drv_gpu_complete`（libvulkan は通知の後に trailer を poll する）（§2.4.6・§6.7） |
| M4 | session の tag の取り方が 2 通り | tag は node の open。`DESTROY_DEVICE` は D + R で device の下の object だけ返す（§2.4.4） |
| M5 | `CPFW` と `SA` の offset の重なり、`VEND` の幅、P2 の EXTCAP/PERF の offset とのずれ | `VEND` 0x0C0〜0x0DF（8 word）、`CPFW` 0x120〜0x13F、`SA` 0x140〜0x14F。P2 の `PERF_SRC` 0x110・list 0x100 を事実として書いた（§2.2・§2.4.10） |
| M6 | MC は client の間の順序を守らない | firmware の DMA の書き込みの応答が揃ってから、それを参照する µop と `RESULT` の IRQ を出す規則（§2.4.6・§2.4.8） |
| M7 | watchdog・HALT/STEP・CPFW_CTRL.HALT・LOAD・CAPS[17]・reset で残る register | 全部書いた: counter は `UOP_FIFO` の満と DMA の待ちを数えない、STEP = 1 packet、HALT の関係、LOAD の条件、`CAPS[17]` は静的、§2.6 の表に追記（§2.4.7・§2.6） |
| M8 | fence の値の領域が一貫しない | device 全体の 32 bit の 1 本に統一（§6.4、C2） |
| M9 | scoreboard の穴（暗黙の register、範囲の WAW、EXEC = 0、WAR、a/f の latency、NPHYS 8 の主張） | 範囲の比較（400 LUT）、暗黙の source/dst を含める、EXEC = 0 は要求も entry も無し、source は発行の段で読む、a と f は 1 本の固定長の pipeline、NPHYS 8 は interlock 1〜2 cycle（§3.1.1） |
| M10 | helper lane と coverage の規則が無い | EXEC は quad 単位、副作用の mask = coverage（`mask` operand）& ~KILLED（§3.1、p009） |
| M11 | 分岐の単位と即値の結合が曖昧 | B は imm[12:1] を命令数（±2048）、I/S は sext(imm12) + (sext(imm_hi) << 12)（§3.3） |
| M12 | 「属性 k = r_k」は vec4 を表せない | 属性の行き先は STATE `ATTR_DST[k]`（0x1C0〜）と interface の表（§2.3・§3.4.3） |
| M13 | `exec.save`・`vote`・`ballot` の predication、loop の下げ方 | EXEC に依らず全 lane に書く。`exec.save` は loop の前（§3.9 の注・§6.6） |
| M14 | §6.6 の表の漏れ | 述語付きの store/atomic、shared の atomic（拒む）、texel の offset・derivs・gather（拒む）、POINT_SIZE・SECOND_COLOR・LAYER、NOP、`texf`/`texsz` の level を register に（§6.6・§3.4.1） |
| M15 | `sel` の定義が 2 通り | bit ごと（rd = (rs1 & rs2) \| (~rs1 & rs3)）に統一（§3.2・§3.4.1） |
| M16 | 拡大・縮小の blit・clear attachments は BLT では出来ない | firmware の内蔵の GSI1 の program（`blit.c`、p018）（§2.4.4・§2.4.8） |
| M17 | KC705 の N=8 は CPU + SA を足すと BRAM も DSP も超える | 板の目標を **N=6**（156k LUT、351 BRAM、808 DSP）に。N=8 は SA 無しの構成として p015 で実測（§3.6） |
| M18 | SA の帯域・利用率・先読み・型の詰め方・drain の順 | push 12.8 GB/s、1 tile ≈ K + 31 + COLS step、実効 64〜128 MAC/cycle、先読み 4 KiB、int16/int8 は word の下位、drain は列の逆順（Appendix A.2） |
| M19 | SA の EXEC = 0 と終わり・`sactl 2` の拒み・HALT | push/pop は EXEC に依らず必ず 1 entry、dispatch の終わりで FIFO を捨てる、`sactl 2` の拒みは `sastat[4]`、HALT/RESET は abort で待ちを解く（§3.9・Appendix A.2） |
| M20 | `GHCI_NATIVE` の白表が SA の試験を通さない、KC705 に host が無い | 試験の build の白表を広げた（SET_REG 全部、DISPATCH、LOAD_PROGRAM…）、KC705 は JTAG の道具（§2.4.5・p020） |
| M21 | firmware の性能の見積もりが楽観、codec を 2 度書く | 「数 µs〜十数 µs」に直し p017 で測る。codec は `ghci_vkwire.inc` を 1 つの表から生成して driver と firmware で共有（§2.4.7・§2.4.8・p019） |
| M22 | Phase の依存の漏れ | `ghci_layout.h` は p019、p010 → p018、p008 ← U22・U23、p009 ← U27、p019 ← U24・U26。toolchain は変えない（H5）（§8） |
| L1 | 148・150・161 が表に無い | D（external の properties）（§2.4.4） |
| L2 | `GHCI_*` の受け入れの文の矛盾 | libvulkan は送らない、userland の試験の build は `GHCI_NATIVE` だけ（§2.4.4） |
| L3 | vendor の opcode の範囲が 3 通り | class 1 の op 0〜63 に統一（§2.1・§2.4.1） |
| L4 | 詰め物が NOP（n ≤ 255）では埋められない | class 3 の詰め物（§2.7） |
| L5 | `EINVAL` でも結局 DEVICE_LOST | 文を直した（§2.4.6） |
| L6 | 256 KiB を超える packet | staging（H2）で上限に当たらない（§2.4.2） |
| L7 | `FREE_MEMORY` の遅延解放が待つ fence | その時点の session の最後の fence の値（§2.4.4・§6.3） |
| L8 | LW の範囲の計算 | 454 LW、±22 で 432〜476（§8） |
| L9 | 下書きの文、節の順、冒頭の件数、ws.md の U の範囲 | `movi`・ILT の文を直した。§6.9 → §6.8 と §12 の前の §13 は版 2 の番号を保つため: §13 は末尾に移した。冒頭と ws.md を直した |
| L10 | 出典の版、gpu-op の出典の引き継ぎ、商標 | RISC-V の仕様の版（20240411）、gpu-op.h の引用の書き方、「RISC-V 互換」を名乗らない注（§3.4.6） |
| L11 | `nop` が r0 に書く、`wait` の置き場、`texl` の slot、形の列 | `nop` は custom-3 111、`wait` は imm、slot は sub[3:0]、命令ごとの形の行（§3.2・§3.3・§3.4.1） |
| L12 | firmware の無い構成の capability | `CAPSET`・`COMMAND`・`NOTIFICATION`・`JOB` を名乗らない（§2.4.10） |
| L13 | MC の client に `atg_cpu`・SA が無い | Appendix A.2 に注（§4.1 の内訳は p002 の実測の時に直す） |
| L14 | allocator が `CP_HEAP` を除外する規則、shader が heap を壊せる | 除外の規則（§2.4.7）。R7 の「session の隔離が無い」に含む |
| L15 | `GET_DEVICE_QUEUE2` の文 | 書き直した（§2.4.4） |

未対応で残す物: 無し（全部に対応）。確かめていない事: reviewer の M21（firmware の性能）は推測のまま p017 で測る。L10 の商標は推測の懸念で、文言の変更だけ行った。

## 14. review の指摘と対応（版 4、design-reviewer、2026-10-23、33 件: High 7・Medium 15・Low 11、Critical 0）

reviewer が照合した物: design.md の §3.1〜§3.6・§2.2〜§2.4・§6・§8、`compiler/ir.h`、Guardrail、`kern/pmem.h`・`pmem.c`・`uncached.c`、`hal/armv7/space.c`・`page.c`・`fdt.c`、`phase003/phase.md`、`tests/zybo-gpu-sd.dts`、amaterrace-gpu の README（a217bf8）。P1 が対応の前に確かめた物: README の 36〜37 行（LLM の流れ）と 45 行（32 × 32、0.8 TOPS/SU）。

| # | 指摘（要旨） | 対応（節） |
| --- | --- | --- |
| 1 (H) | README（a217bf8）の「0.8 TOPS/SU」「LLM の流れに VF と ROP」と SA の形（1 つ、0.41 TOPS、VF/ROP 無し）が食い違う | **U39**（TOPS の数え方、SU ごとか、VF/ROP を載せるか。推し: 0.41 TOPS/SA、SU ごとに最大 1 つ（KC705 は SU0 だけ）、VF/ROP は載せない）。§0 に a217bf8 を記録、§3.9 の冒頭と 3.9.1 の所有を「SU に 1 対 1」に |
| 2 (H) | 1 命令 = 2 entry の偶奇が奇数の COLS/K・FP32・abort で崩れる | SA が対に揃える: K は偶数（奇数は拒む）、COLS_USED が奇数なら PAD の entry、FP32 は常に 2 entry、scale は「scale + PAD」、abort で偶奇を 0 に。kernel の規約（PAD は −65504 / 数えない）（§3.9） |
| 3 (H) | 行の scale が偶奇の半分を合わせていない、\|a\| > scale が未定義 | `fmax2` → `shfl` xor 16 → `fmax2` → push の手順、hardware は ±2047 に飽和して `sastat[6]`（§3.9・Appendix A.2） |
| 4 (H) | attention の例に Q の push が無く deadlock、P × V は P を 2 回流す | kernel を「tile n の push → tile n−1 の pop」の software pipeline に、Q は tile ごとに push、P は LDS から 2 回 push。cycle 数を数え直した（Appendix A.5） |
| 5 (M) | FP32 + DBUF で out-FIFO 32 entry では deadlock | FIFO を 64 entry に、安全な規則を式で（push 済みで pop していない tile ≤ 1 + DBUF、未読の出力 ≤ 64）（§3.9・Appendix A.2） |
| 6 (M) | cycle 数が interlock と命令の不足を数えていない | 命令列を書き直し（`addi`、`lds`、`unpackh`、FP32 の s）、鎖の bubble を含めた保守的な値（softmax 25 cycle/列、LN 28、attention ≈ 23,000 cycle、LN ≈ 11,700）に。展開で 1.5〜2 倍の見込みと p022 の実測（Appendix A.5） |
| 7 (M) | SU が律速なので LUT の PE は v1 で効かない | U31 の推しを「p020 の最初は 32 × 16 の DSP だけ、32 × 32 は 2 段目で実測」に（Appendix A.2・§9.2） |
| 8 (M) | 資源の内訳と合計が合わず、mux と超越が抜け | 内訳の表（32 × 32 ≈ 90k、32 × 16 ≈ 23k）、DSP の PE は bank A = P register、packed の超越 5k/SU、SA 構成 ≈ 157k / 90k（Appendix A.2・§3.6） |
| 9 (M) | 先読み BRAM 1 つでは 9 byte/cycle、FIFO の BRAM | 先読み BRAM36 × 4（256 bit）、FIFO は LUTRAM 64 entry（Appendix A.2） |
| 10 (M) | stream-out の向き・deskew・DBUF の切り替え | 降順の drain → 2 × 32 entry の並べ替え buffer → 昇順、tile の全部が揃ってから drain、SA 全体の stall、bank の規則（Appendix A.2）。p020 の TB に入れた |
| 11 (M) | TILE_LAST と `qtag` の意味 | LAST/TILE_LAST は最後の列の entry だけ、`qtag` = 最後の pop の 2 entry の tag（EXEC に依らず）、loop の判定は `bany`、kernel は EXEC 全部 1（§3.9） |
| 12 (M) | abort の後の loop が終わらない、HALT の意味 | tag を 6 bit に（ABORT・PAD）、abort は FAULT/RESET だけ、HALT は dispatch を完走（§3.9） |
| 13 (M) | BFP の精度の主張、丸め・bias・subnormal・Inf | 上界の式、RNE、E は biased（2^(E−25)）、subnormal は 0、Inf/NaN は飽和 + sticky、P の scale は 1/s（Appendix A.2・Appendix A.5、U29） |
| 14 (M) | LN の折り返しに scale と 1/n の表の抜け | 2 段の確定（y → max → scale → push）、1/n は LDS の表（Appendix A.5） |
| 15 (M) | s を FP16 で足すと N が大きいと落ちる、−inf | s は FP32、mask と m の初期値は −65504（Appendix A.5） |
| 16 (M) | LDS の N の計算 | N ≤ 2048（Appendix A.5、U34） |
| 17 (M) | SA 構成に graphics が無い事を capability で表せない | `CAPS[27] GRAPHICS`、0 なら compute の queue だけ、firmware は draw を拒む（§2.2・§3.9）。`atg_cpu` の有無は U40 |
| 18 (H) | p020 ↔ p022 の clearance の循環、SA の track が Vulkan の後ろ | p020 の依存を {p008, p012}、受け入れは Verilator と合成、板は p022。packed・`shfl`・`vote`・`ballot` を p009 から p022 へ（§8） |
| 19 (L) | LW の合計が表の和と合わない | script で足して書き直した（§8） |
| 20 (M) | §6.1 の pl-memory が reserved-memory と食い違う、`kern_device_map` の罠 | node を名前（と p006 で足す compatible）で探し `struct kern_pmem` → `kern_pmem_map_uncached`。`kern_device_map(UNCACHED)` は使わない。HAL の変更は無し（§6.1） |
| 21 (M) | 「2 SU で 2 head」は所有の規則と矛盾 | SU1 の用途（量子化・LN・SA を使わない compute）に書き直し、2 warp の交互は v2（§3.9・Appendix A.5） |
| 22 (L/M) | custom-2 funct3 111 の funct7 の表、header の flag | funct7 の表（packh 0、unpackh 1、swaph 2、超越 4〜7）、flags[5]（§3.4.1・§3.4.4） |
| 23 (L) | 「NPHYS 個/cycle」が曖昧 | half の評価 2 × NPHYS 個/cycle、SU あたり 5k LUT（§3.4.1・Appendix A.5） |
| 24 (L) | FIFO の口の幅と途中の停止 | 発行の時に 2 entry / credit 2 を確かめ途中では止めない、幅は NPHYS × 32 bit（§3.9） |
| 25 (L) | PE の段数と DSP の配置 | 段数を揃える、pblock は p020（Appendix A.2・§8） |
| 26 (L) | acquire の例外、lane 0 と EXEC、bit の位置 | acquire は所有していなくても可、値は lane 0 から EXEC に依らず、`sactl.ctl` の word は `SA_CTRL` と同じ bit（§3.9） |
| 27 (L) | 古い文（§6.10、§3.6、R29、README、ws.md、§3.7、`SA_DTYPE`、用語） | 全部直した（README は entry = 32 × FP16、版 4、U40 まで。§3.7 に SA 構成の行。`SA_CAPS[19:16]`。「左の口の vector」） |
| 28 (L) | ASIC で kernel が同じ事を shader が確かめられない | FP の PE も scale + PAD を受けて捨てる、`sastat[7]`（§3.9・Appendix A.6） |
| 29 (L) | accumulator と出力の溢れ | `SA_K` ≤ 8192、FP16 の出力は ±65504 に飽和 + sticky（Appendix A.2） |
| 30 (L) | p022 の LW が楽観、200 MHz に依存 | 32 LW ±50%、100 MHz の数を併記（Appendix A.5・§8） |
| 31 (L) | 出典の表に版 4 の物が無い | §3.4.6 に packed の超越・BFP・online softmax・Welford/Chan を一般知識として足した |
| 32 (L) | 共有の IR に FP16 が無く p021 は GEMM 止まり | p021 の範囲を GEMM に明記、FP16 の IR は Future Work（Appendix A.4・§8） |
| 33 (L) | 小さな数（pop の数え過ぎ、KC705 の固定 block、BLT の見込み） | 直した（Appendix A.5・§3.6） |

未対応で残す物: 無し。その後のユーザーの決定（案 B → SA の延期）で、SA の詳細（1〜16・21〜30・33 の対応）は Appendix A の sketch に移り、計画の critical path からは外れた。U39 は閉じた（§3.9）。確かめていない事: 資源と cycle の数は推定のまま。

## 15. MSAA（multisample の描画と sample する image。版 5、ws001-p027 の設計の段。版 5.1 で resolve を BLT の RESOLVE に）

**版 5.1**（2026-10-25 P2、ws001-p027 の実装の段の最初、zedBSD の worktree p2-p027（main b5c6f2407）、amaterrace-gpu の worktree p2-p027（main 5a7a5c4 を merge した a928541））: U44 の回答（§15.20）で §15.8 の resolve を **BLT の op RESOLVE**（専用の streaming の engine `atg_blt_rsv`）に書き直し、§15.1・§15.2・§15.9〜§15.20 をそれに合わせた。段 S7 を足し計 39 LW。§15 の外の §2.4.4 の表の gpu-op 122 と §8 の p027 の行の LW（32 → 39）は Q1 が直す。review は [design-review-msaa.md](design-review-msaa.md) の review 3。

2026-10-25 P2（ws001-p027、q1558-i01、zedBSD の worktree p2-p027（基点 bb8e0f161）、amaterrace-gpu の worktree p2-p027（基点 main 87457fa）を読んだ）。承認: 2026-10-25 ユーザー「了解です。SAはfuture workに回します。p009, msaaを優先して実装してください。…」（[phase027](phase027/phase.md)）。この節は設計だけで、RTL・model・firmware・driver は書かない。review の指摘と対応は [design-review-msaa.md](design-review-msaa.md)。

### 15.0 出典と確認の水準

- **読んだ RTL・spec（amaterrace-gpu 87457fa、実測）**: `spec/gpu/rx/`（`atg_rx`・`atg_rx_setup`・`atg_rx_scan`・`atg_rx_frag`）、`rtl/gpu/rx/atg_rx_scan.v`（edge は 15.8 の固定小数、`a8 = A << 8` が 1 pixel の歩み、E は bbox の原点の画素の中心の値で top-left の bias を含む、被覆の判定は `lv[47]`（負なら外）、bbox は頂点の画素の min〜max+1 ∩ scissor ∩ RT）、`rtl/gpu/rx/atg_rx_setup.v`（bbox の計算）、`rtl/gpu/rx/atg_rx_frag.v`（PL → DIV → BC → WR、約 200 cycle/quad、z は [0, 1] に clamp して r3）、`spec/gpu/rop/`（`atg_rop`・`order`・`ds`・`wb`）、`rtl/gpu/rop/atg_rop_ds.v`（1 quad ずつ、行ごとに line を 1 本読み 2 lane を試す。**stencil の op は未実装**）、`spec/gpu/su/atg_su_exp.md`・`atg_su_opd.md`・`atg_su_sched.md`・`atg_su_lda.md`、`rtl/gpu/su/atg_su_opd.v`（operand 119 `mask` = warp の coverage の 32 bit を全 lane に）、`rtl/gpu/su/atg_su_exp.v`（r3〜r5 を fl_* から snoop）、`rtl/gpu/su/atg_su_lda.v`（`pw_addr[11]` = 1 の書き込みは 0xFFF の map 以外は捨てる）、`spec/gpu/blt/atg_blt.md`（696 行、U38 の分割が未）、`spec/gpu/tu/*`、`docs/ghci.md`（§3.2 CAPS、§8.4、§12.2〜§12.10）、`include/ghci_regs.vh`（RX の 0x05E・0x05F、ROP の 0x07D〜0x08F は空き）、`tools/rxmodel.py`（RX と ROP の model）・`tumodel.py` の関数の一覧。
- **zedBSD（bb8e0f161、実測）**: `src/drivers/gpu/compiler/ir.h`（`DRV_GPU_IR_IMAGE_MULTISAMPLED`、「a multisampled 2D image is fetched with the sample as its layer」、LD の message）、`spirv.c`（Centroid は「a draw has one sample per pixel」として効果無し、BuiltIn の SampleMask・FragDepth は扱っていない）。
- **Vulkan の文面（Khronos の Vulkan 仕様、docs.vulkan.org の latest、2026-10-25 に WebFetch で読んだ。CC-BY-4.0）**: §15.1 の表に引用の短い句を付ける。1.0 と latest の差が効く所（`framebufferIntegerColorSampleCounts` は 1.2、maintenance10 の resolve の緩和）は表に書いた。**未取得**: `VkImageCreateInfo` の「samples ≠ 1 なら 2D・mipLevels 1・optimal・cube 不可」（記憶。VUID の文は読んでいない）、SPIR-V の BuiltIn SampleMask と Centroid の decoration が Shader の capability で足りる事（SPIR-V の仕様の記憶）、必須の format の表の列（WebFetch で列が読めなかった）。
- **P3 の part F の descriptor の案**（2026-10-25 Q1 経由、draft、実装中）: +0 TEX_BASE、+1 TEX_SIZE、+2 TEX_IMAGE（[3:0] level 数、[7:4] format、[8] 4×4 tiled、[11:9] view type（0 2D、1 2D array、2 3D、3 cube）、**[15:12] samples（MSAA の予約）**、[31:16] depth/layer 数）、+3 TEX_LAYER_STRIDE、+4 TEX_SAMPLER、+5 TEX_LOD、+6〜15 予約。命令は funct7[5] の「.3」形（3 つ目の座標 rs1+2、Dref は rs1+3）。§15.9 はこれに合わせた。

### 15.1 Vulkan 1.0 core の要求（文面）と v1 の値

| 項目 | Vulkan の要求（文面の要点） | v1（この設計） |
| --- | --- | --- |
| `framebufferColorSampleCounts` | Required Limits の表: min `(VK_SAMPLE_COUNT_1_BIT \| VK_SAMPLE_COUNT_4_BIT)`。「color attachments with floating- or fixed-point formats」 | 1\|4（ROP の RT の format: BGRA8・RGBA8・RGB565。4x の RGB565 の image を sample するために TU の `texf` に 16 bit の texel を足す: §15.9、review 1。resolve は BLT の UNORM565: §15.8） |
| `framebufferIntegerColorSampleCounts` | 1.2 の limit、min 1 | 1.0 には無い。整数の RT の format は v1 に無い |
| `framebufferDepthSampleCounts` / `StencilSampleCounts` | min 1\|4 | 1\|4（D24S8・D32F。stencil の op は ROP に未実装: §15.18） |
| `framebufferNoAttachmentsSampleCounts` | min 1\|4（attachment の無い subpass） | 1\|4（RX の coverage だけ。ROP は書かない） |
| `sampledImageColorSampleCounts` | min 1\|4（optimal の 2D、SAMPLED、整数でない color） | 1\|4（RGBA8・BGRA8・RGB565 を `texf` で。565 は S5 で足す） |
| `sampledImageIntegerSampleCounts` | min 1 | 1 |
| `sampledImageDepthSampleCounts` | min 1\|4 | 1\|4（D24・D32F を `texf` で。compare は無視） |
| `sampledImageStencilSampleCounts` | min 1\|4 | **未達**: TU に stencil の aspect の読みが無い（§15.18） |
| `storageImageSampleCounts` | 「Unsupported Limit」= 1、feature `shaderStorageImageMultisample` が有れば 1\|4 | 1（feature 0） |
| `maxSampleMaskWords` | min 1 | 1 |
| `standardSampleLocations` | Boolean、core は値の要求無し（Roadmap 2022・1.4 で TRUE） | TRUE（下の位置を使う） |
| 標準の位置（`VK_SAMPLE_COUNT_4_BIT`） | 「(0.375, 0.125)」「(0.875, 0.375)」「(0.125, 0.625)」「(0.625, 0.875)」、i 番目 = sample の index i。1 sample は (0.5, 0.5) | 同じ（§15.3） |
| `subPixelPrecisionBits` | min 4 | 8（15.8 の固定小数、既存） |
| MS が要る format の条件 | `VkImageFormatProperties::sampleCounts` は tiling LINEAR、2D 以外、cube compatible、`COLOR_ATTACHMENT` も `DEPTH_STENCIL_ATTACHMENT` も無い format では 1 だけ。usage ごとに上の limit の上位集合の積 | MS は attachment に使える format だけ。driver（p019）が format の property で返す |
| feature `sampleRateShading` | 任意。SPIR-V の SampleRateShading・InterpolationFunction の capability はこの feature（spirvenv の表）。SampleId・SamplePosition の使用は sample shading を有効にする | **0**（U43）。v2 の案は §15.19 |
| feature `alphaToOne` | 任意（無ければ `alphaToOneEnable` は FALSE） | **1**（ROP の mux 1 つ、§15.6） |
| feature `variableMultisampleRate` | 任意 | 0（subpass の attachment と pipeline の sample の数は同じ） |
| `alphaToCoverageEnable` | feature の条件が無い = 必須。「No specific algorithm is specified」、1 の数が alpha に比例する事を意図 | ROP（§15.6） |
| `pSampleMask`（sample mask test） | 必須。coverage の bit を mask の 0 の bit で落とす。順は shading の前 | RX（`SAMPLE_KILL`、§15.3） |
| SampleMask の built-in（入力・出力） | 出力は coverage と AND（「the coverage mask is ANDed with the bits of the SampleMask built-in」）、入力と同じ符号化。出力は変数なので最後に書いた値が効く | 入力 r6、出力 `exp 0x105`（最後の書き込みが勝つ、§15.4・§15.5） |
| input attachment（`subpassInputMS` を含む） | core | v1 に無い（§15.18）。MS の input attachment は `texf` の rs2 = sample に写せる |
| 補間の位置 | 「Interpolation of input variables is performed at an implementation-defined position within the fragment area being shaded.」Centroid: 「must also fall within the bounds of the primitive being rasterized」。Sample: sample の位置（sample shading 用） | 既定 = 画素の中心（今と同じ）。Centroid = r7〜r9（§15.4） |
| FragCoord | sample shading が無ければ x・y は fragment の中心。Centroid は無視 | r4・r5 = 画素の中心（今と同じ） |
| FragDepth | 「replace the fragment's calculated depth values for each sample in the input SampleMask」 | sample の全部に同じ値（§15.6） |
| fragment の操作の順 | sample mask test → fragment shading → multisample coverage（alpha to coverage・alpha to one）→ depth bounds → stencil → depth → … | RX → SU → ROP の `atg_rop_ms` → `atg_rop_ds` → `atg_rop_wb` |
| polygon の被覆 | point sampling。edge の上の sample は「exactly one of the polygons must result in a covered sample」 | sample ごとに同じ edge 関数と top-left の bias（§15.3） |
| resolve（render pass の `pResolveAttachments`、`vkCmdResolveImage`） | 「the samples corresponding to each pixel location in the source are converted to a single sample」。整数は 1 つの sample を選ぶ、float・normalized は実装依存。src は sample ≥ 2、dst は 1、同じ format、dst に `COLOR_ATTACHMENT`（maintenance10 の前）。1.0 は color だけ（depth/stencil の resolve は 1.2 の拡張） | BLT の op RESOLVE（専用の streaming の engine、UNORM は channel ごとの RNE の平均、整数は sample 0。§15.8、U44） |
| 他の command | `vkCmdCopyImage` は sample の数が同じなら可（「The sample count of srcImage and dstImage must match」）。image ↔ buffer の copy と blit は MS 不可（記憶） | BLT の COPY・FILL を幅 ×S で（§15.8） |

### 15.2 決めた事の要約

1. **4x だけ**（1 と 4。2・8 は報告しない）。標準の位置。fragment の shader は **pixel ごとに 1 回**（sample shading は U43 で v1 に無し）。
2. **RX** が sample ごとの coverage（edge 関数を sample の offset で評価、sequential に 4 cycle）と `pSampleMask` を出す。fragment の warp に **r6 = SampleMaskIn**（全 mode で）、必要なら **r7〜r9 = centroid の barycentric** を書く。
3. **SU** は RTL の core（sched・opd・RF）を変えない。`atg_su_exp` が r6 を snoop し、新しい export の target `0x105`（SampleMask の出力、最後の書き込みが勝つ）を drain の時に r6 と AND する。decode は `texsz.s` だけ足す。`mask` operand（119）と side-effect の lane は今のまま（「どれかの sample が covered な lane」）。
4. **ROP** に新しい子 `atg_rop_ms`（sample ごとの depth z_s = z_c + d_s、alpha to coverage、alpha to one、coverage の合成）を `atg_rop_order` と `atg_rop_ds` の間に置き、`ds` と `wb` は (lane, sample) の 16 entry を回す。
5. **memory の配置** = pixel ごとに S 個の sample を連続に（sample-interleaved）、行 = roundup(w, 2) × S × 画素の byte。2×2 の quad の 1 行の全 sample が 1 本の line（32/64 byte）に入る。
6. **resolve** = **BLT の op RESOLVE**（版 5.1、U44 の回答）: BLT の中の新しい streaming の engine `atg_blt_rsv` が MS の src の line を続けて読み、format ごとに平均（UNORM8・UNORM565 は channel ごとの RNE、整数は sample 0、sRGB・float の code は予約）して linear か tile の dst に書く。clear・MS ↔ MS の copy は BLT の FILL/COPY を幅 ×S で。
7. **TU** の `texf` は MS の slot で **rs2 = sample の index**（level の代わり。MS の image は level 1 つ）。address は x' = x·S + s、行の texel 数 roundup(w, 2)·S。`texsz.s`（imm 3。imm 2 は part F の `texsz.d`）= sample の数。descriptor は P3 の TEX_IMAGE[15:12] = log2(samples)。RGB565 の 4x のために `texf` に 16 bit の texel を足す。
8. **GHCI**（draft）: CAPS[29] MS4、STATE 0x05E `MS_CTRL`・0x05F `SAMPLE_KILL`、GSI1 の fragment の入力 r6〜r9 と `exp 0x105`、`texf` の MS の読み、`texsz.s`。amaterrace-gpu の `docs/ghci.md` §12.11（draft）に書いた。

### 15.3 RX: sample ごとの coverage と標準の 4x の位置（`atg_rx_scan` と新しい子 `atg_rx_cov`）

- **位置と offset**: 画素の中心からの offset（pixel）と subpixel（1/256 px、15.8）での値:

| sample | 位置 | offset (dx, dy) | subpixel |
| --- | --- | --- | --- |
| 0 | (0.375, 0.125) | (−0.125, −0.375) | (−32, −96) |
| 1 | (0.875, 0.375) | (+0.375, −0.125) | (+96, −32) |
| 2 | (0.125, 0.625) | (−0.375, +0.125) | (−96, +32) |
| 3 | (0.625, 0.875) | (+0.125, +0.375) | (+32, +96) |

  edge の値は E（subpixel² の単位、画素の中心、bias 込み）で、1 pixel の歩みは A << 8（A は subpixel の差）。よって sample s の値 = E + A·dx_s + B·dy_s（dx_s, dy_s は上の subpixel）。A·32 = A << 5、A·96 = (A << 6) + (A << 5) の shift と加算だけで乗算器は要らない。三角形ごとに 3 edge × 4 sample の offset `O[e][s]`（48 bit）を三角形の読み込みの次の cycle に作る（576 FF）。
- **tie の規則**: bias は edge ごとの定数（top-left）で、sample の値にもそのまま含まれる。隣り合う 2 つの三角形は共有の edge の係数が符号反転で、bias は片方だけなので、edge の上の sample はちょうど一方が被覆する（Vulkan の「exactly one of the polygons」）。sample の位置は 1/8 px の倍数で 15.8 で正確に表せる。
- **bbox**: 今の bbox（頂点の画素の min〜max+1 ∩ scissor ∩ RT）は三角形の全体を含む画素の矩形なので、sample が covered な画素は全部その中（変えない）。
- **評価の順**（`MS_CTRL[3:0]` = 2 の時だけ。1x は今の 1 quad/cycle のまま）: quad ごとに cycle 0 = 今の中心の評価（`ccov[3:0]`、centroid の選択に使う）、cycle 1〜4 = sample 0〜3。sample の cycle は edge ごとに `es[e] = ec[e] + O[e][s]` を **3 本の 48 bit の加算器**で作り（register）、今の lane の加算器（ec + a8/b8 の 12 本）の入力を `ec` から `es` に mux で替える（加算器は 3 本だけ増える）。16 bit の `scov[4l+s]`。**`fq_scov` = `scov & ~{4{SAMPLE_KILL[3:0]}}`（SAMPLE_KILL を引いた後**、lane ごとに sample の bit を落とす）で、0 でない lane が covered。quad の全 lane が 0 なら quad を捨てる。1 quad ≈ 5 cycle（frag の約 200 cycle に比べ小さい）。
- **空の quad の短絡**（細い三角形で walk が 5 倍遅くならないため）: 中心の評価で、ある edge の 4 lane の値が全部 `−maxO[e]`（その edge の `|O[e][s]|` の最大、三角形の読み込みで作る）より小さければ、その quad の sample は全部外なので SAMP を飛ばす（保守的: 飛ばしてよい時だけ飛ばす）。
- **1x**: `scov[4l]` = 今の `cov[l]`（中心 = sample 0 の位置 (0.5, 0.5)）& ~SAMPLE_KILL[0]。今の PASS の出力は変わらない（SAMPLE_KILL の reset 値 0 = 全部残す）。
- **`atg_rx_cov`（新、≈120 行、FSM 無し）**: 入力 `ec[3]`・`a8[3]`・`b8[3]`・quad の xy と bbox・sample の番号（0 = 中心、1〜4）、出力 4 lane の bit。`O[e][s]` の register を持つ（`load` で作る）。`atg_rx_scan` は `atg_rx_cov` を instance し、`S_WALK` に MS の副状態 `S_SAMP`（counter 0〜4）を足す（≈+40 行、≈340 行）。
- **port**: `atg_rx_scan` の `fq_cov` 4 → `fq_scov` 16（4l+s）と `fq_ccov` 4（中心が三角形の中か、lane ごと）。27 → 28 port。direct の道（DRAW_RAW、`dx_*`）は v1 は 1x の coverage のまま（§15.6 の注）。

### 15.4 RX: fragment の warp の入力（`atg_rx_frag` と新しい子 `atg_rx_bary`）

- **r0〜r5**: 今のまま（b0, b1, b2, z, x + 0.5, y + 0.5）。**ただし 4x の時 r3 = 画素の中心の z を clamp せずに**（中心が三角形の外の画素の z は [0, 1] の外になり得て、clamp した値に sample の差を足すと誤るため。clamp は ROP が sample ごとに行う、§15.6）。1x は今の clamp のまま（既存の vector を変えない）。
- **r6 = SampleMaskIn**（**1x でも 4x でも書く**）: lane の `scov & ~SAMPLE_KILL` の 4 bit（1x は bit 0）を 32 bit に 0 拡張。helper の lane は 0。Vulkan の SampleMask 入力（「the coverage」、sample mask test の後）に当たる。compiler（p010）は SampleMaskIn を r6 として読む（使わない program は r6 を一時に使ってよい: RX の書き込みは warp の開始の前）。
- **r7〜r9 = centroid の b0, b1, b2**（`MS_CTRL[4]` CENTROID の時だけ。firmware が fragment の program の header（p010 で flag を足す、§15.11）から立てる）: 位置 = lane の `ccov` が 1 なら中心（r0〜r2 と同じ値を写す）、0 なら `scov` の最小の index の sample の位置。i' = i + dx_s、j' = j + dy_s（fp32 で正確: |i| < 2^16、dx は 1/8 の倍数）で 1/w・b0/w・b1/w の plane を評価し直し、r = 1/(1/w)、b0、b1、b2 を同じ式で。helper の lane は中心。compiler は centroid の varying をこの 3 つで補間する（`lda` × 3 + `fmul` + `fmadd` × 2、noperspective は §3.4.3 と同じ式（§3.8）を r7〜r9 に）。**FragCoord.z**: 4x の r3 は clamp しないので primitive の外の中心では [0, 1] の外になり得る。compiler は 4x の pipeline（multisample の state は pipeline の作成の時に分かる）で FragCoord.z を読む時、`sat` の修飾（1 命令）で [0, 1] にする（review 2 の 17）。
- **d_s（sample s の depth の差）**: **三角形ごとに 1 回**（`t_load` の後、最初の warp の前）、d_s = fadd(fmul(Az, dx_s), fmul(Bz, dy_s))（RX の fmul・fadd、RNE、FTZ。dx_s, dy_s は §15.3 の pixel の値で fp32 で正確）。同じ三角形の warp ごとに、その 4 word を primitive table の口の特別の address **`fl_pw_addr` 0xFF8〜0xFFB** で SU に送る（`atg_su_lda` は `pw_addr[11]` = 1 の 0xFFF 以外を捨てるので変わらない。`atg_su_exp` が snoop する）。1x では送らない。**制約**: v1 の warp は三角形 1 つだけ（pmap = 0、`atg_su_lda` の PRIMS = 8 は予約）なので d_s は warp ごとの値でよい。将来 1 つの warp に複数の三角形を詰める時は、d_s を primitive ごとにし（primitive table の primitive の予約の word に置き、ROP へは quad の primitive の番号で選ぶ）、この snoop の address を primitive ごとに広げる（§15.13 にも書く）。
- **時間**: 1 quad の WR は 24 → 28 回の書き込み（r6）、CENTROID で +12 回（r7〜r9）と plane 3 つ + 除算 1 + BC（≈+60 cycle/quad）。d_s は三角形ごとに ≈30 cycle（`dz_done` の印を `t_load` で消し、0 の時だけ DZ を通る。4 word は warp ごとの COPY で毎回送る、review 2 の 7）。
- **分割**: `atg_rx_frag`（321 行）に足すと 400 行を超えるので、lane の算術（plane の評価、fdiv、barycentric、d_s）を **`atg_rx_bary`（新、≈220 行、FSM 1 つ: IDLE →(start)→ PL → DIV → BC → DONE、IDLE →(dz)→ DZ（8 回の fmul と 4 回の fadd）→ DONE）**に移す。入力: plane の係数（sp_tri の z・1/w・b0/w・b1/w）、quad の (i, j)、lane ごとの offset の選択（3 bit: 0 中心、1〜4 sample）、出力: 4 lane の b0・b1・b2・z、または d_s × 4。`atg_rx_frag` は COL → ALLOC → COPY → DZ（MS の d_s）→ 各 quad: BARY（中心）→ [BARY（centroid）] → WR → GO の順序だけを持つ（≈260 行）。fmul・fadd・fdiv は `atg_rx_bary` が持つ。
- **port**: `atg_rx_frag` に `fq_scov`・`fq_ccov`（32 → 33。`fq_cov` は scov から作るので外す）。`fl_info[31:0]` = 今と同じ「covered な lane」（scov ≠ 0 の lane）。

### 15.5 SU: helper lane・`mask` operand・SampleMask（`atg_su_exp`、`gsi1model.py`）

- **side-effect の lane は今のまま**: `fl_info[31:0]` = 「どれかの sample が covered な lane」、`mask`（operand 119）= その 32 bit、副作用の lane = EXEC & mask & ~KILLED（design §3.1 の M10、`atg_su_opd`）。helper の lane（quad の中の covered でない lane）は 4x でも `qd`・`texb` のために走り副作用を持たない。**sample の粒度は SU に入れない**（pixel ごとの shading なので、副作用（`sw`・`atom`・`sts`・`exp`）は pixel ごとで正しい）。
- **書き手を分ける**（review 5: 今の `atg_su_exp` は書き手ごとに memory を分けている: `mz` は fl だけ、`m0..m4` は `ex_op` だけ）: (a) **r6 の snoop**は fl だけが書く新しい lane の RAM `mr6`（4 bit、今の `mz` と同じ形）、(b) **`exp rs2, 0x105`（新、SAMPLE_MASK の出力）**の値は `ex_op` だけが書く lane の RAM `m5`（4 bit）と、lane ごとの「書いた」の bit（今の exported の `dw` と同じ FF の vector）。**最後の書き込みが勝つ**（review 4: Vulkan の SampleMask は出力の変数で、最後に書いた値で 1 回 AND。COLOR・DEPTH の exp の上書きとも揃う）。drain の時に smask = mr6 & (書いた ? m5 : 1111)。1x では bit 0 だけ。
- **`zexp`**: lane ごとに「`exp 0x104`（DEPTH）を出したか」の 1 bit（今の exp は exported な depth と rasterized な z を別の word に持ち、どちらを出すかを既に選んでいる。その選びの bit を ROP にも渡す）。
- **exported の定義**: `exp 0x100+c`・`0x104`・**`0x105`** のどれかを出した lane（review 1 の 6、review 2 の 5・6: **compiler の規則**: 全部の fragment program は終わりに、入口の EXEC に戻してから `movi rT, -1` と `exp rT, 0x105`（coverage を変えない。全 1 の整数の特殊 operand は無く、`mone` は −1.0f = 0xBF800000 で下位 4 bit が 0 なので使ってはならない）を出す。これで color の出力の無い depth だけの program も、制御の流れで exp を通らない lane も ROP に届く。**fragment shader の無い pipeline**（Vulkan は fragment の stage を省いた pipeline を許す、記憶）には firmware が同じ 2 命令だけの内蔵の fragment program を当てる。**r3 を `exp 0x104` に出してはならない**: 4x で zexp になり sample ごとの z が失われる。§15.11 の p010 と GHCI §12.11 に書く）。
- **d_s の snoop**: `fl_pw_we` で address 0xFF8〜0xFFB の 4 word を warp の slot ごとに保存（NWARPS × 128 bit の FF。NWARPS 4 で 512 FF、8 で 1024 FF）。**slot の解放（`xr_valid`）と reset で 0 にする**（1x の warp は d_s を送らないので、前の 4x の warp の値が残らないため。1x の ROP は d_s を使わないが `ex_ms` の値を決めておく）。
- **ROP への出力**: 新しい port **`ex_ms[147:0]`** = {d_s[127:0]（warp の値、1x は 0）、zexp[3:0]、smask[15:0]（lane l の sample s が bit 4l+s）}。`ex_mask` = covered かつ exported かつ smask ≠ 0 の lane（SampleMask の出力で全 sample を落とした lane は ROP に出さない）。**port**: 新しい入力 `fl_pw_we`・`fl_pw_addr`・`fl_pw_data`（今の exp には無い、review 11）と出力 `ex_ms` で **35 → 39**（上限 40 に余り 1。これ以上足す時は exp の分割が先）、≈267 → ≈330 行。`atg_su`（wiring、例外）は fl_pw_* を lda と exp の両方に配り、`ex_ms` を出す。
- **`gsi1model.py`**: fragment の warp の入力に r6（と CENTROID の r7〜r9）を足し、`exp 0x105` の AND、`--warps` の出力に smask・zexp を足す。`gsi1asm.py` の export の名前に `smask`（0x105）。
- **sched・opd・RF**: 変えない（RX の fl_* が r6〜r9 を書くのは今の r0〜r5 と同じ道。NREGS は 32 以上なので r9 は常に有る）。
- **decode（`texsz.s`、review 1 の 9、review 2 の 1）**: part F の後の `atg_su_dec_tabc` は imm 0・1・2（`texsz`・`.l`・`.d`）を定義し、uop の op の bit 6（.l）と bit 3（.d）を使う。`texsz.s` は **imm 3** で、MS4（parameter、CAPS[29]）の時だけ定義する（無ければ「optional instruction without its CAPS bit」の fault）。no-rs1 の形（`use1 = 0`）。imm 3 は op の bit 6 と bit 3 が両方立つ形になるので、`atg_tu_addr` が今 `nlevq = opr[6]` だけで `.l` を判定している所を `.s`（両方）と分ける。S を返すのは `atg_tu_addr` の `ta_value`（今の `texsz` の道）で、`atg_su_tex_ret` は変えない。道具（asm・dis・model）は S1、RTL と GHCI §12.6 は S5。

### 15.6 ROP: sample ごとの depth・stencil・color（新しい子 `atg_rop_ms`、`order`・`ds`・`wb` の変更）

- **流れ**: `atg_rop_order`（`ex_ms` を `q_ms` として quad と一緒に順に出す。28 → 30 port）→ **`atg_rop_ms`（新）** → `atg_rop_ds` → `atg_rop_wb` → `atg_rop_blend`。
- **`atg_rop_ms`**（≈220 行、FSM 1 つ: IDLE → Z（16 回の fadd）→ COV → OUT、21 port）:
  - z_s: lane l の sample s の depth = zexp[l] ? 出した depth : clamp01(fadd(z_c[l], d_s))。clamp01 は `atg_rx_frag` の z と同じ（NaN と負は 0、1 より上は 1）。fadd は `atg_rx_fadd`（RX の module を instance。同じ丸め）を 1 本、16 回を pipeline で（1 cycle に 1 つ、≈16 + 8 cycle/quad）。**1x**（`MS_CTRL[3:0]` = 0）は z_0 = 今の z（fadd を通さない、bit で同じ）。
  - **alpha to coverage**（`MS_CTRL[8]`）: lane の COLOR0 の alpha（fp32、`q_color` の lane の [127:96]）から n = 「alpha ≥ 0.125, 0.375, 0.625, 0.875」の数（正の fp32 は bit の整数の比較で足りる。NaN と負は 0）、mask = n に応じ {0000, 0001, 1001, 1011, 1111}（sample の順 0, 3, 1, 2: 0 と 3 は対角）。1x は alpha ≥ 0.5 で bit 0。coverage を `smask & a2c` にする。順は Vulkan の「multisample coverage」（shading の後、depth の前）。この対応は Amaterrace の vendor の選択（Vulkan は「No specific algorithm is specified」）で、ghci.md には「implementation-defined、Amaterrace はこの表」と書く。
  - **alpha to one**（`MS_CTRL[9]`）: a2c の後に COLOR0 の alpha を 1.0 にする（blend の前）。
  - 出力: `o_smask[15:0]`、`o_sdepth[511:0]`（lane × sample の z）、color はそのまま。lane の smask が 0 になれば lane を落とす、全部 0 の quad は捨てる。
  - **direct の道**（DRAW_RAW、`q_dbg`）: v1 は 4x でも lane の bit を 4 sample に広げ、z は lane の z を全 sample に（bring-up の道で Vulkan の道ではない。`dx_*` の port を変えないため）。
- **`atg_rop_ds`**: `q_mask` 4 → `q_smask` 16、`q_depth` 128 → `q_sdepth` 512（port の数は同じ）。行ごとに line を 1 本読み（4x の 1 行 = 2 px × 4 sample × 4 byte = 32 byte、§15.7 の配置で必ず 1 本の line）、`S_TEST` を (lane, sample) の 8 entry に回す（1x は今の 2）。sample s の word の位置 = 行の中の (x·S + s)·4。書き込みの byte enable も sample ごと。合格の bit を `d_smask` で `wb` へ。≈225 → ≈290 行。**stencil**: D24S8 の word の上位の byte が sample ごとの stencil。stencil の op の実装（§15.18）はこの (lane, sample) の回し方の上に乗る。
- **`atg_rop_wb`**: `d_mask` 4 → `d_smask` 16。line の中の位置 = (x·S + s)·ps。blend は sample の番号 s ごとに 1 回（`b_dst` = 4 lane の sample s の画素、`b_mask` = sample s が合格の lane）で 4 回、1x は 1 回。write-combine の line buffer は 2 本（行ごと）のまま（4x では 1 本の line が 1 つの quad の行で埋まる）。≈264 → ≈330 行。
- **順序**: ROP の順序（連番の退かせ方）、MC の優先、deadlock の論（§3.8）は変わらない（ROP の仕事が quad あたり増えるだけで、MC の書き込みの受理だけに依存する事は同じ）。
- **draw の間の MS_CTRL の変更**（版 5.1 で直した。P1 の p030 の設計 §16.8a が見つけた hazard）: 以前の `atg_cp_seq` は RX の範囲の SET_REG を RX か ROP の busy、ROP の範囲を ROP の busy だけで待たせ、ROP の busy は「RX が発行した連番が全部退くまで」（`atg_rop_order`）なので、前の draw が VF・vertex の warp・RX の setup に居て連番を得る前に次の draw の RX・ROP の state（MS_CTRL・SAMPLE_KILL も）が書けた。**RX と ROP の範囲の SET_REG は VF・SU・RX・ROP の全部の busy を待つ**ようにした。同じ種類の hazard（P1 の p030 の review 2 の H3）として **TU の範囲は VF も、program の範囲（0x190〜0x1AF、今まで待ち無し）は VF・SU・RX を、LOAD_CONST の kick は VF・RX も、0x1D0〜0x1DF（ATTR_LIMIT）は VF を待つ**（amaterrace-gpu f1253ec、TB の `.tuwait`・`.progwait`・`.ldconst`・`.attrlimit_wait` は前の規則で FAIL、直した後 PASS）（新しい子 `atg_cp_seq_wait` に待ちの規則を移し、`atg_cp_seq` は 408 → 355 行。amaterrace-gpu p2-p027 7d56c2a、`atg_cp_seq_tb` の `.drawstate` は直す前の RTL で FAIL 3 件、直した後 PASS）。代価: draw ごとに RX・ROP の state を変える列は draw の境で pipeline が空く（v1 は正しさ優先）。未確認: block の間の handoff（VF → vertex の warp → RX）で busy が 1 cycle どれも立たない隙間が無いか（全 pipeline の back-to-back の試験で見る）。

### 15.7 MS の image の memory の配置

- **sample-interleaved の線形**: sample s of pixel (x, y) of layer L at
  `base + L·LAYER_STRIDE + y·P + (x·S + s)·ps`、P（行の byte）= roundup(w, 2)·S·ps、ps = 画素の byte（4 か 2）、S = 4。
- **理由**: (1) 2×2 の quad の 1 行の全 sample = 2·S·ps byte（4x・32 bpp で 32 byte、16 bpp で 16 byte）が、base が 64 byte 揃え・P が 2·S·ps の倍数・x が偶数なら 1 本の line（32 か 64 byte）に必ず入る → `ds` と `wb` の行ごとの line が 1 本のまま。(2) resolve と `texf` で 1 画素の 4 sample が連続。(3) BLT の FILL/COPY は「幅 S 倍の 1x の image」として使える（§15.8）。(4) Vulkan は MS の image の配置を見せない（linear tiling と image ↔ buffer の copy は MS 不可）ので vendor が自由に決めてよい。
- **roundup(w, 2)**: w が奇数の時 P を 2·S·ps の倍数にするため。ROP は driver が書く `RT_STRIDE`/`DS_STRIDE`（= P）を使い、TU は descriptor に行の stride が無いので **samples > 1 の slot では行の texel 数を roundup(w, 2)·S と計算する**（同じ規則を両方が使う）。
- layer の面（P × h）は P3 の規則で 64 byte に丸め、`TEX_LAYER_STRIDE` = 面の byte。MS の image は level 1 つ、4×4 tile にしない（TEX_IMAGE[8] = 0）、view は 2D か 2D array。base の揃えは 64 byte（driver が `VkMemoryRequirements::alignment` に返す）。
- 大きさ: 1920×1080 の 4x の RGBA8 の color は 33.2 MB、D24S8 も 33.2 MB（1x の 4 倍）。
- **幅の上限**: BLT と RX・ROP の座標と TU の幅の field は 16 bit なので、MS の image は roundup(w, 2)·S ≤ 65535（4x で **w ≤ 16382**、review 2 の 10）。Vulkan の `maxFramebufferWidth`・`maxImageDimension2D` の最小 4096 は満たす。p019 は MS の image の幅を 16382 以下に検査する（review 1 の 18）。

### 15.8 resolve（BLT の RESOLVE の op、専用の streaming の道）と clear・copy

**版 5.1（2026-10-25 P2、ws001-p027 の実装の段の最初）**: ユーザーの U44 の回答（§15.20）で、firmware の内蔵の draw の案（版 5 の A）をやめ、**hardware の resolve** にした。比べた 3 つの置き場所と決めた理由:

| 置き場所 | 長所 | 短所 | 判定 |
| --- | --- | --- | --- |
| **BLT の op RESOLVE**（BLT の中に新しい streaming の engine `atg_blt_rsv`） | resolve は「memory の矩形 → memory の矩形」で BLT の形そのもの。GHCI の BLT の STATE（base・stride・xy・size・clip）・`BLIT` の µop・`KICK.BLIT`・STATUS の BLT busy・fault の kind 2/5・MC の client 1 を全部そのまま使える。tile の dst（BLT の 4×4 の式）も同じ engine で書ける。render pass の state（draw の STATE・TU の slot・constant）に触れないので firmware は state を退避も出し直しもしない | BLT の今の 2D の FSM（696 行、U38 の分割が未）に足すと大きくなる → **足さない**: 既存の 2D の engine は名前だけ `atg_blt_2d` に変え（動作は bit で同じ）、resolve は別の子に置き、`atg_blt` は op で振り分ける薄い wrapper にする | **採用** |
| ROP の道（ROP に resolve の walk を足す） | ROP は RT の format を知っている | ROP は SU からの quad を順に退かせる block で、memory の矩形の walk・clip・tile の dst・`vkCmdResolveImage`（render pass の外）の口が全部新しく要る。ROP の AMB の口は ds と wb が既に共有し、STATE の範囲の busy の待ち（RX/ROP）も draw と絡む | 不採用 |
| 新しい block（`atg_rsv`、MC の新しい client） | 独立 | GHCI に新しい µop・KICK の bit・STATUS の busy の bit・STATE の範囲が要り、MC の tree に client が 1 つ増える。中身は BLT の op と同じ | 不採用 |
| （版 5 の A）firmware の内蔵の draw | 新しい RTL 無し | RX の frag の律速で 1080p ≈1.0 s @ 100 MHz、state の退避と出し直し、TU の slot・constant・tile の dst の帯が要る | ユーザーが不採用 |

- **Vulkan の要求（docs.vulkan.org の latest の refpage `vkCmdResolveImage`・`VkImageResolve`、2026-10-25 に WebFetch で読んだ）**: 「If the source format is an integer type, a single sample's value is selected for each pixel」、float・normalized は「implementation-dependent」（sRGB は「should」linear にしてから平均し、書く前に戻す）。`VkImageResolve` の aspectMask は「must only contain VK_IMAGE_ASPECT_COLOR_BIT」（depth/stencil の resolve は `VkImageResolve2` と maintenance10、render pass では 1.2 の depth/stencil resolve で、**Vulkan 1.0 core には無い**）。src は sample ≥ 2、dst は 1、同じ format、dst の format は（maintenance10 の前）`COLOR_ATTACHMENT` の feature、「The union of all source regions, and the union of all destination regions ... must not overlap in memory」。→ v1 は color だけ、整数は sample 0、src と dst の重なりは未定義（検査しない）。
- **GHCI**（draft、`docs/ghci.md` §8.2 と §12.11）:
  - BLT_OP の op を [1:0] から **[2:0]** に広げ、**4 = RESOLVE**（CAPS[29] の時）。5〜7 は fault の kind 2。今の [2] は「無視」で、今の firmware と試験は 0 を書くので互換。RESOLVE と blend（[4]）・reverse（[12]）の組み合わせは kind 2。[9:8] は dst の画素の大きさ（= src の 1 sample の大きさ）。
  - **STATE 0x00B `BLT_RESOLVE`**（BLT の範囲 0x000〜0x01F の空き）: [3:0] src の log2(samples)（v1 は 2 だけ、他は kind 2）、[7:4] 平均の format、[8] dst が 4×4 tile（CAPS[11]）。
  - 平均の format: **0 UNORM8**（画素の全 byte がそれぞれ 8 bit の unsigned normalized: RGBA8・BGRA8、将来の R8・RG8 も同じ code）、**1 UNORM565**（16 bit の [15:11]・[10:5]・[4:0] の 3 field）、**2 SAMPLE0**（sample 0 を写す: 整数の format）、3 SRGB8_A8（byte 0〜2 は sRGB、byte 3 は linear）、4 SFLOAT16（16 bit ごと）、5 SFLOAT32（32 bit ごと）、6〜15 予約（kind 2）。**v1 の Amaterrace は 0〜2**: 3〜5 は render output がその format を書く時に足す（ROP の RT の format が BGRA8・RGBA8・RGB565 だけなので、MS の sRGB・float の image は v1 では作れない）。それまで 3〜5 は kind 2。**p030 への依存（review 3 の 9）**: p030 が RT の format（sRGB・RGBA16F・A2B10G10R10 など、Vulkan 1.0 の必須の color attachment の format の表は p030 が文面で確かめる）を足す時に、BLT の RESOLVE の code 3〜5 の実装、10:10:10:2 の新しい code、8 byte の画素（BLT_OP[9:8] = 2）を同じ Phase で足す。Q1 が p030 の範囲に記録する。
  - **平均**: UNORM は channel ごとに S 個の code の和 Σ を 4 で割り、**最も近い code に、ちょうど半分は偶数へ**（RNE: q = Σ >> 2、r = Σ & 3、q + (r > 2 ‖ (r = 2 ∧ q が奇数))。Σ ≤ 1020 なので桁あふれしない。normalized の値の算術平均を RNE で code にした値と等しい）。SRGB8_A8 は byte 0〜2 を sRGB → linear にして平均し linear → sRGB（RNE）、byte 3 は UNORM。SFLOAT は fp32 で ((s0 + s1) + (s2 + s3)) × 0.25（RNE、FTZ は他の fp と同じ）、SFLOAT16 はその後 fp16 に RNE。
  - src の配置は §15.7（sample-interleaved）: src の画素 (x, y) の sample s は `SRC_BASE + y·SRC_STRIDE + (x·S + s)·ps`。BLT_SRC_XY・BLT_SIZE は画素の単位（×S しない）。SRC_BASE は 64 byte、SRC_STRIDE は 2·S·ps の倍数（§15.7 の P）、tile の dst の base と stride は 16·ps の倍数（§8.2）。RTL は SRC_BASE・SRC_STRIDE の S·ps より下の bit と、dst の ps より下の bit を捨てる（2D と同じく検査しない: review 3 の 10）。dst は linear（`DST_BASE + y·DST_STRIDE + x·ps`）か、[8] で BLT の 4×4 tile の式。clip は他の op と同じく dst に掛かり src が一緒に動く。
- **流れ**（render pass の `pResolveAttachments` と `vkCmdResolveImage` の両方）: firmware（p018）は draw が全部終わり ROP の書き込みが memory に届いてから（**`WAIT_IDLE` の flags = 0（全部の unit）**。ROP の busy は「発行した連番が全部退いたか」だけなので、RX が次の quad を作っている間は 0 になり得て、`WAIT_IDLE` ROP だけでは描きかけの MS の image を読む: review 3 の 1。§15.14）、region ごと・layer ごとに BLT の範囲の SET_REG（OP = RESOLVE | ps、SRC = MS の image の base + layer·LAYER_STRIDE、SRC_STRIDE = P、DST、XY、SIZE、CLIP_MAX = 0、BLT_RESOLVE）と `BLIT` を出す。render pass の resolve は src・dst の XY = renderArea の offset、SIZE = extent。`vkCmdResolveImage` は srcOffset・dstOffset・extent、dst が tile なら [8]。**draw の STATE・TU の slot・constant には触れない**（BLT の範囲だけ）ので、退避も dirty も要らない。後の draw が dst を読む・書く時は今の規則（BLT ↔ ROP の `WAIT_IDLE`、TU で読むなら `INVALIDATE` T$）。BLT は cache を持たないので、src の MS の image の T$ の無効化は resolve には要らない。
- **RTL の形**（module ≤ 400 行・FSM 1 つ・≤ 40 port、§15.16）:
  - `atg_blt`（wrapper、≈120 行、port は今と同じ 22、parameter `MS4`）: BLT_OP[2] を snoop し、kick を `atg_blt_2d`（[2] = 0）か `atg_blt_rsv`（[2] = 1）へ。`MS4` = 0 で [2] = 1 の kick は wrapper が kind 2（kick の次の cycle、2D と同じ時期）。AMB の口: 2 つの engine は同時に動かない（CP の `BLIT` は BLT の busy を待って kick する、`atg_cp_seq`）。idle の engine の `q_valid` は 0 なので **`req_valid` は 2 つの OR**、`req_ready` は両方に配り、request の data は **所有者の register**（kick の時に BLT_OP[2] から取る 1 bit、`own`）で選ぶ（組み合わせの mux を `q_valid` → MC の最悪の path に足さない: review 3 の 7）。**応答は `own` の engine にだけ渡す**（`rsp_valid & own` / `& ~own`。2D の engine は state に関係なく `rsp_*` で `wr_out`・`rd_out` を数えるので、resolve の応答が届くと 4 bit の `wr_out` が wrap して次の COPY が止まる: review 3 の 2）。`own` は kick の時だけ変わり、engine の busy の間（全部の応答を受けるまで）は変わらない。busy・done・error は OR、**error_kind は pulse の出所で選ぶ**（`r_error ? r_kind : w_error ? OPCODE : d_kind`。2D は error の pulse の cycle に IDLE に戻り busy = 0 なので busy では選べない: review 3 の 3）。`MS4` = 0 では resolve の engine を置かず、`own` = 0 に固定（wrapper は 2D の素通しと [2] = 1 の kind 2 だけ）。
  - `atg_blt_2d`: 今の `atg_blt` の module の名前だけを変えた物（2D の動作・時間は bit で同じ。U38 の分割はこの Phase の範囲の外）。
  - **`atg_blt_rsv`**（制御、≈320 行、FSM 1 つ: IDLE → CLIP → MUL → ROW → DRAIN）: 自分の BLT の STATE の写し（OP・DST/SRC の BASE と STRIDE・XY・SIZE・CLIP・RESOLVE）、kick の時の組み合わせの検査（kind 2）、clip、行の起点の乗算（src: SRC_BASE + sy·SRC_STRIDE、dst: linear は DST_BASE + dy·DST_STRIDE、tile は DST_BASE + (dy/4)·DST_STRIDE + (dy%4)·4·ps。2D と同じ shift-and-add で 16 cycle、src と dst を並べて）、行ごとに src の行の line の範囲（first = src_row + sx·S·ps、line0 = first >> LS、off0 = first & (LB−1)、n = ((first + w·S·ps − 1) >> LS) − line0 + 1）を作って行の記述子を `atg_blt_rsv_px` へ、その line を順に読む。次の行: src += SRC_STRIDE、dst は linear なら += DST_STRIDE、tile なら dy%4 = 3 で += DST_STRIDE − 12·ps、他は += 4·ps。**AMB の口を 1 つの request register で持ち**、px の書き込みを読みより先に出す（書き込みが line buffer を空ける）。register は `q_valid && !req_ready` の時だけ止まり、**`!q_valid || q_fire` の cycle に次の request を取る**（2D の「fire の次の cycle に取る」形だと 1 request に 2 cycle かかる: review 3 の 5）。**読みの credit**: 未応答の読み（fire した物）+ px の line の FIFO の数 + request register に居る読み（まだ fire していない物）の和を `held` とし、新しい読みを register に取るのは `held < 2^DEPTH_LOG2` の時だけ（この cycle に fire する読みは「register」から「未応答」に移るだけで和は変わらない。この cycle に応答が push されれば「未応答」から「FIFO」へ移り変わらない。px の pop だけが和を減らす）。応答に ready が無いので、FIFO の場所を register に取る時に取る。応答は client ごとに順（`spec/gpu/mc/atg_mc.md`）なので tag は {7'd0, write} だけ。**error の応答**（review 3 の 4）: `fail` を立て、request register への新しい load を止め、px に `abort` を出す。fail の後と error の応答そのものは line の FIFO に push せず（計数だけ減らす。MC の拒否の error の応答は前の応答を追い越し得る、`atg_mc.md` §4）、px は `abort` の間は書き込みを出さず、FIFO は `rst_n && !abort` で空にする（`am_fifo` に clear の port は無いので、reset の入力に abort を混ぜる）。未応答が 0 になって kind 5。次の kick は空の FIFO と 0 の credit で始まる（spec の §5 で assert）。終わり: 全部の行を出し、px が idle、未応答 0 で `done`。
  - **`atg_blt_rsv_px`**（画素の道、≈320 行、FSM 1 つ: IDLE → ROW → FLUSH）: 行の記述子の FIFO（`am_fifo`、2 entry）と src の line の FIFO（`am_fifo`、2^DEPTH_LOG2 entry × LINE_BYTES·8 bit、distributed RAM）、2 本の line の window（`w0`・`w1`）と byte の位置 `ptr`。1 cycle に 1 つの **group**（dst の連続した n 画素、n ≤ min(4, LB/(S·ps))、行の残り、linear の dst は dst の line の残り、tile の dst は 4 − x%4（tile の行の中））: window から n·S·ps byte を取り（`ptr` は S·ps の倍数なので mux の位置は 2·LB/(S·ps) 個）、`atg_blt_avg` で平均し（register 1 段）、dst の line の組み立ての buffer（1 本、byte enable 付き）の byte の位置に置く。group の dst の line が buffer の line と違えば先に buffer を書き込みとして出す（FLUSH: ctl が request register に取るまで待つ）。**行の記述子に line の本数 n を入れ、px は行ごとにちょうど n 本だけ pop する**（window への load は「この行の残りの本数 > 0」の時だけ。先読みで次の行の最初の line を取らない: review 3 の 6）。行の最後の group が最後の line を使うので、行の終わりに window の line は全部この行の物で、捨ててよい。P や DST_STRIDE が LINE_BYTES の倍数でない時、隣の行が 1 本の line を共有する（src: 同じ line を 2 回読む。dst: 組み立ての buffer の line の番号が同じなら merge する）。最後の行の最後の group の後に buffer を出し idle。`ptr + n·S·ps > LB` で `w1` が無ければ待つ。
  - **`atg_blt_avg`**（組み合わせだけ、≈120 行、FSM 無し）: 入力 4 画素 × 4 sample × ps byte（ps 4: 64 byte、ps 2: 32 byte）、format、ps → 出力 4 画素 × ps byte。UNORM8（byte ごと）・UNORM565（3 field）・SAMPLE0。SRGB8_A8・SFLOAT は code を予約し、足す時はこの module に入れる（入出力の形は同じ）。
- **速さ（推定）**: 4x・32 bpp・LINE_BYTES 64・揃った linear の dst で、dst の 1 line（16 画素）あたり読み 4 本 + 書き 1 本（MC では書き込みは 2 flit、`atg_mc.md` §6）で **口の律速は 6 cycle/dst line**。px は 1 cycle に 1 group（4 画素 = src の 1 line）。16 bpp は group が 4 画素（8 byte）までなので px が律速し、dst の 64 byte = 32 画素に 8 cycle（review 3 の 15）。1080p の 4x: src 33.2 MB（518,400 line）+ dst 8.3 MB（129,600 line）= 648,000 request ≈ 3.9 ms @ 200 MHz（口の律速: 518,400 + 2 × 129,600 cycle）、DDR3 の実効 7.7〜9.6 GB/s で 41.5 MB ≈ 4.3〜5.4 ms → **memory の帯域で律速**。ただし今の AXI master は `OUTSTANDING_LOG2` = 2（同時に 4 つ）なので、読みの往復の待ち（MIG で ≈40〜60 cycle と見て）で ≈4 line/50 cycle に縛られ、v1 は 1080p で ≈30〜40 ms @ 200 MHz（版 5 の draw の案は同じ 200 MHz で ≈0.5 s、≈15 倍）。AXI master の outstanding を深くする時（p025）は `DEPTH_LOG2` も合わせる（3〜4。FIFO は distributed RAM で 64 byte × 16 = 8 kbit）。tile の dst は group が tile の行（4 画素）ごとの別の line で、書き込みは line の 1/4（LINE_BYTES 64・32 bpp）の byte enable になる（正しいが書き込みの効率は 1/4。tile の 4 行を一緒に回す形は p025 の候補）。
- **on-chip（推定、合成していない。review 3 の 8 で直した）**: line の FIFO 4 × 512 bit（RAM32M で ≈0.35k LUT）、window 1 kbit FF、取り出しの mux（512 bit の 8:1）≈0.5k LUT、平均の加算器 ≈0.2k LUT、平均の出力を組み立ての buffer の ps の位置（LB/2 = 32 通り）に置く shifter ≈1k LUT、組み立ての buffer 0.6 kbit FF、request register の wdata 512 FF、STATE の写し ≈350 FF、制御と乗算 ≈0.5k LUT → **≈2.5〜3k LUT・≈3k FF**（KC705 の ≈1.4%）。2D の BLT は見積もり 1.0k に対し実測 2.73k だったので、合成の実測を p024・p025 の確認の項目にする。ZYBO の bitstream 3（47〜56%、R33）に `MS4` = 1 で入れると +≈3k LUT（7010 の ≈17%）なので、ZYBO の構成は `MS4` = 0 を既定にする。ZYBO の BLT を持つ bitstream にも入る（`MS4` = 0 なら外れる）。

- **clear**: `vkCmdClearAttachments`・`loadOp CLEAR`・`vkCmdClearColorImage`/`DepthStencilImage` の MS の image = BLT の FILL を (x·S, y, w·S, h) で（同じ stride）。D24S8 の depth だけの clear（stencil の byte を残す）は MS と無関係の既存の欠け（§15.18）。
- **copy**: `vkCmdCopyImage` の MS ↔ MS（同じ sample 数）= BLT の COPY を (x·S, w·S) で。
- **BLT と ROP の順序**（1x にも共通）: BLT の範囲の SET_REG は BLT の busy だけを待つので、render pass の途中の clear（BLT の FILL）・resolve（BLT の RESOLVE）と前後の draw の間に firmware は `WAIT_IDLE` を挟む（ROP → BLT、BLT → ROP の両方向）。p018 の規則として書く。
- **load/store の op**: LOAD・DONT_CARE は何もしない、STORE は ROP が既に memory に書いている（IMR）。
- **§2.4.4 の表**: `vkCmdResolveImage`（gpu-op 122）は R（BLT の RESOLVE）。Q1 が直した（2026-10-25 05:03）。

### 15.9 TU: `texf` の sample の index と descriptor（P3 の part F と合わせる）

- **descriptor**（P3 の案の TEX_IMAGE[15:12]）: **log2(samples)**（0 = 1 sample、2 = 4、他は予約で 0（1 sample）として読む）。MS の slot は TEX_IMAGE[3:0] = 1 level、[8] = 0、[11:9] = 0（2D）か 1（2D array）。
- **`texf rd, rs1, rs2`（MS の slot）**: rs1 = x、rs1+1 = y（整数）、**rs2 = sample の index**（MS の image は level が 1 つで level の operand が要らないので、同じ operand を sample に使う。新しい命令の形も operand の pass も要らない）。2D array は P3 の「.3」形で rs1+2 = layer、rs2 = sample。address = 線形の (x' = x·S + (s mod S), y)、行の texel 数 roundup(w, 2)·S（§15.7）。座標・sample の範囲外は実装依存（Vulkan も範囲外は保証しない）: v1 は s を mod S、x・y は今の `texf` と同じ扱い。compare と filter は無視（今の `texf` と同じ）。
- **`texsz.s rd`**（**imm 3**、新、`texsz.l` と同じ no-rs1 の形。imm 2 は P3 の part F が `texsz.d`（layer 数・depth）に使った、review 2 の 1）: rd = S（1 か 4）。SPIR-V の `OpImageQuerySamples`。`texsz rd, rs1` は MS でも level 0 の w・h。decode・SU の側の変更は §15.5 の最後。
- **RGB565 の `texf`**（review 1 の 1、review 2 の 4）: TU の texel は今 4 byte だけ（ghci §8.4「Texels are 4 bytes」）。4x の RGB565 の attachment を sample するために（`sampledImageColorSampleCounts` は SAMPLED の color の format の全部に 1|4。resolve は BLT が 565 を直に平均する、§15.8）、S5 で **`texf` に 16 bit の RGB565 の texel**（UNORM、(R, G, B, 1)、**TEX_IMAGE[7:4] = 4**（part F の空き））を足す: `atg_tu_addr`（address = texel の index × 2）、`atg_tu_cache`（line の中の half word の選択、addr[1] を filter へ、565 の border の raw の値）、`atg_tu_filter`（565 → fp32: R・B は c/31、G は c/63 を RNE で。今の 8 bit ÷ 255 の回路と別）。`texl`/`texb` の 565（filter）は §15.18 の format の欠けとして残す（MS の image は fetch でしか読まれないので MSAA には不要）。format の番号は P3 の TEX_IMAGE[7:4] の空きから（P3・Q1 と合わせる）。
- **SPIR-V の対応**（§12.9 の表に足す）: `OpImageFetch` の Sample operand 付き → `texf`（rs2 = Sample）。MS の image への `texl`/`texb`/`texg` は SPIR-V が許さない（compiler は出さない）。
- **P3 との合わせ**（Q1 経由、2026-10-25 に連絡済み）: (1) TEX_IMAGE[15:12] の意味を log2(samples) として予約、(2) `atg_tu_addr` の linear の address の段に x' と行の長さの規則を入れる余地。実装は p027 の段 S5（part F の merge の後）。`atg_tu_addr.v` は今 411 行で part F が分割する見込み（分割の後の module に足す）。
- **`tumodel.py`**: 同じ規則（P3 の part F の後の版に足す）。

### 15.10 GHCI の追加（draft。amaterrace-gpu の `docs/ghci.md` §3.2 の CAPS[29] と §12.11）

- **CAPS[29] MS4**: 4x の multisample（RX の sample の coverage、ROP、MS の `texf`、BLT の RESOLVE）。CAPS[27]（graphics）と TU が有る構成で 1。driver は CAPS[29] = 0 なら sample の数 1 だけを報告（Vulkan 1.0 には合わない、と記録）。**番号**: part F は CAPS[26] を広げ新しい bit を使わなかったので CAPS[29] で確定（ghci.md の「provisional」の注は消した）。
- **STATE 0x05E `MS_CTRL`**（RX の範囲。RX と ROP が読む。CP の sequencer は RX の範囲の SET_REG を RX か ROP が busy の間止めるので、draw の途中で変わらない）: [3:0] log2(samples)（0 = 1、2 = 4、他は 0（1 sample）として読む）、[4] CENTROID（r7〜r9 を書く）、[8] ALPHA_TO_COVERAGE、[9] ALPHA_TO_ONE、他 0。
- **STATE 0x05F `SAMPLE_KILL`**: [3:0] 落とす sample（= ~pSampleMask[0][3:0]）。**反転にした理由**: STATE の reset 値は 0 で、今の試験と firmware は 0x05F を書かないので、0 = 全部残すにする（P3 の maxLod の反転と同じ考え）。1x は bit 0。
- **GSI1 の fragment の入出力**（§12 に初めて書く。今は design §3.4.3 にだけ有る。hardware の coverage が使うのは **RX が書いた r6 の値**（exp の snoop）で、program が後で上書きした r6 ではない）: r0 = b0、r1 = b1、r2 = b2（perspective 補正、元の 3 頂点）、r3 = z（1x は [0, 1] に clamp、4x は clamp しない）、r4 = x + 0.5、r5 = y + 0.5、**r6 = SampleMaskIn**（bit s = sample s、sample mask test の後、helper は 0）、**r7〜r9 = centroid の b0〜b2**（MS_CTRL[4] の時）。export の target: 0x100+c COLOR0、0x104 DEPTH、**0x105 SAMPLE_MASK**（最後に書いた値を coverage と AND。S 以上の bit は無視）。color の出力の無い program は `movi rT, -1; exp rT, 0x105` を出す（r3 を 0x104 に出さない）。**CAPS[29] = 0 の実装では r6 は定義されない**（compiler は SampleMaskIn を 1 とする。Amaterrace は常に書く）。
- ghci.md §12.11 の「image word」は P3 の part F の TEX_IMAGE（merge 済み、§8.4）を指す。
- **BLT の RESOLVE**（§8.2 に足す）: BLT_OP の op [2:0] の 4 = RESOLVE、STATE 0x00B `BLT_RESOLVE`（[3:0] log2(samples)、[7:4] 平均の format 0 UNORM8・1 UNORM565・2 SAMPLE0・3 SRGB8_A8・4 SFLOAT16・5 SFLOAT32、[8] dst が tile）、平均の規則、src の配置（§15.7）、重なりは未定義。CAPS[29] の意味に「BLT の RESOLVE」を足す。詳細は §15.8。
- **`texf` の MS と `texsz.s`**: §15.9。
- 出典の扱い: 標準の位置の値は Vulkan の仕様の表（CC-BY-4.0 の文書の事実の値）。ghci.md の該当の所に「Values referenced: Vulkan specification, Multisampling, standard sample locations (VK_SAMPLE_COUNT_4_BIT)」と書く。文は写さない。

### 15.11 zedBSD の側（p010・p018・p019 への入力。この Phase では書かない）

- **p010（compiler）**: 共有の SPIR-V の front end（`src/drivers/gpu/compiler/spirv.c`、bcm2711・powervr と共有）に BuiltIn SampleMask（入力・出力）と FragDepth、Centroid を IR の補間の印として足す（他の backend は無視してよい形にする: 今の「効果無し」は 1 sample の device では正しい）、`OpImageQuerySamples`。GSI1 の backend: SampleMaskIn = r6、centroid の varying = r7〜r9（使う program の header に flag、§3.4.4 の flags に [5] を足す案）、出力 SampleMask = `exp 0x105`（invocation の最後の値）、**color の出力の無い fragment の program は `movi rT, -1; exp rT, 0x105`**（r3 を DEPTH に出さない）、MS の fetch = `texf` の rs2（IR は「sample as its layer」の約束なので backend が layer の param を rs2 に置く。MS の array は IR の約束の追加が要る）。
- **p018（firmware）**: pipeline の multisample の state → MS_CTRL・SAMPLE_KILL、render pass の MS の attachment（RT/DS の stride = P）、resolve は BLT の RESOLVE（§15.8: `WAIT_IDLE` ROP の後、region ごと・layer ごとに BLT の範囲の SET_REG と `BLIT`。VkFormat → 平均の format の表（UNORM 8 bit の channel の format → 0、R5G6B5 → 1、整数 → 2）、tile の dst は BLT_RESOLVE[8]。CTRL.RESET は BLT の STATE の写しを消すので、`uop.c` の BLT の µop の列（今は 0x000〜0x00A の 11 語）に RESOLVE の時は 0x00B を足し毎回書く。前の draw の全部を `WAIT_IDLE` flags = 0 で待つ。draw の state には触れない）、fragment shader の無い pipeline の内蔵の fragment program（`movi rT, -1; exp rT, 0x105`）、MS の clear・copy の BLT の幅 ×S、BLT と ROP の間の `WAIT_IDLE`、descriptor の TEX_IMAGE[15:12]。p018 の受け入れに firmware の resolve の試験（§15.15 の最後）。
- **p019（`vk/`）**: limit と feature（§15.1 の v1 の列）、format の property（attachment に使える format の `sampleCounts` 1\|4）、MS の image の memory requirements（大きさ、alignment 64、P）、validation（MS は 2D・1 level・optimal・幅 ≤ 16382）、COLOR_ATTACHMENT の image は linear に置く規則。
- **依存の辺**（§8 の図に足した）: p027 → p010（MS の部分）、p027 → p018、p027 → p019。

### 15.12 帯域と on-chip の量（推定）

- **KC705 の DDR3**: 64 bit × 1600 MT/s = **12.8 GB/s**（MIG の AXI 512 bit × ui_clk 200 MHz と同じ）。行の切り替えと read/write の転換で実効は 60〜75% と見て **7.7〜9.6 GB/s**（推定、p024 で測る）。
- **画素あたりの byte**（depth の test と write、blend 無し）。2 つの数え方:
  - **理想（byte だけ、depth の cache が有る時）**: 4x = depth の読み 16 + 書き 16 + color の書き 16 = 48 byte（blend で +16）、1x = 12 byte。
  - **v1 の line の粒度**（review 3）: `atg_rop_ds` は cache を持たず quad の 1 行ごとに line を 1 本読み 1 本書く（byte enable 付き。DDR3 の BL8 は mask が有っても burst の時間を使う [推定]）。KC705 の line は 64 byte なので quad あたり 2 行 × (64 + 64) = 256 byte = **depth は 1x も 4x も 64 byte/画素**。color は `wb` の 2 本の line の write-combine が行の上で効くので 4x 16・1x 4 byte/画素。
  - resolve は最終の画素あたり 16 読み + 4 書き = 20 byte、scanout 4 byte。

| 画面 | 画素/s | 4x 理想（overdraw 2） | 1x 理想 | 4x v1 の line（overdraw 2） | 1x v1 の line |
| --- | --- | --- | --- | --- | --- |
| 1920×1080 @ 60 | 124.4 M | 124.4 M × (2×48 + 20 + 4) = **14.9 GB/s** | 3.5 GB/s | 124.4 M × (2×80 + 24) = **22.9 GB/s** | 124.4 M × (2×68 + 4) = 17.4 GB/s |
| 1280×720 @ 60 | 55.3 M | 6.6 GB/s | 1.5 GB/s | **10.2 GB/s** | 7.7 GB/s |

  → v1 の ROP は 1x でも 720p60 で実効の帯域（7.7〜9.6 GB/s）に届く。depth の line の cache（p015）が無いと 4x と 1x の差は小さく、cache の後は 4x の 1080p60 が peak の 12.8 GB/s を超える。**4x の 1080p60 には depth の cache に加え圧縮（line ごとの「全 sample が同じ」の印、fast clear）か tile の on-chip の buffer が要る** → Future Work（U45）。
- **v1 の速さ（律速は RX）**: `atg_rx_frag` は 1 quad あたり約 200 cycle で 1 つずつ → 100 MHz で ≈0.5 M quad/s ≈ **2 M 画素/s**（720p60 の 55 M 画素/s に 1x でも 27 倍足りない）。4x で RX の frag は r6 で +4 cycle/quad、CENTROID で +60、scan の SAMP は +4/quad。ROP は 1 quad あたり AMB の往復で律速（`atg_rop_ds` が行ごとに読み → 書き → 応答を待つ）で、4x の追加（`S_TEST` の +6 cycle/行、`atg_rop_ms` の ≈24 cycle/quad、blend の 3 回）は往復に比べ小さい（推定）。**v1 の性能の数字は目標にしない**（U45）。
- **on-chip の追加（v1、推定、合成していない）**: RX: `O[e][s]` 576 FF + `es` 144 FF、加算器 3 本（48 bit）と mux と短絡の比較 ≈0.4k LUT、bary の CENTROID と d_s ≈0.3k LUT。SU: exp の `mr6`・`m5`（lane ごとの 4 bit、distributed RAM）と書いた bit、slot ごとの d_s 512 FF（NWARPS 4。8 で 1024）≈0.15k LUT。ROP: `atg_rop_ms` ≈0.7k LUT（fadd 1 本を含む）+ 0.6k FF、`ds` の sample の z 512 FF・+0.2k LUT、`wb` +0.3k LUT。TU ≈0.05k LUT。**合計 ≈ +2.2k LUT・+2.4k FF・BRAM 0・DSP 0**（KC705 の 1%）。BLT の RESOLVE（版 5.1、§15.8）で **+2.5〜3k LUT・+3k FF**、計 ≈ +5k LUT・+5.4k FF（KC705 の ≈2.5%）。**R33**: MSAA の論理は parameter で外さないので、ZYBO の bitstream 3（raster、47〜56%）にも入る（≈+1.8k LUT。7010 の 100 MHz の timing への影響は p007 の再合成の時に見る。ZYBO は目標の道の外）。
- **選ばなかった tile の buffer の量（比較）**: 32×32 px の tile の 4x の color + depth = 32 KiB = BRAM36 × 8（量は入るが、IMR を tile の binning に変える大きな作り直しが要る。§15.19）。

### 15.13 状態遷移の変更（大まかに。spec の §5 に書く）

- `atg_rx_scan`: IDLE → SEQ → WALK →(MS: SAMP 0〜4)→ FQ/Z/EMIT … → FREE → IDLE。1x は SAMP を通らない。
- `atg_rx_frag`: COL → ALLOC → COPY →(MS かつ dz_done = 0: DZ)→（MS: d_s の 4 word）→ quad ごとに BARY（中心）→(CENTROID: BARY（centroid）)→ WR → GO → COL。
- `atg_rx_bary`: IDLE →(start)→ PL → DIV → BC → DONE → IDLE、IDLE →(dz)→ DZ → DONE → IDLE。
- `atg_rop_ms`: IDLE →(quad)→ Z（MS: 16 回、1x: 0）→ COV → OUT →(o_ready)→ IDLE。
- `atg_rop_ds`: IDLE → ROW → RD → TEST（entry 2 か 8）→ WR → … → OUT → IDLE（形は今と同じ）。
- `atg_rop_wb`: LOOKUP → READ? →（sample ごと: BLEND → MERGE）→ … 。
- `atg_blt`（wrapper）: FSM 無し。kick の時の BLT_OP[2] で 2D か resolve の engine を選び、busy の側に AMB の口を渡す。
- `atg_blt_rsv`: IDLE →(kick、受理)→ CLIP →(空)→ IDLE（done）/ →(空でない)→ MUL（16 cycle）→ ROW（行の記述子を px へ、行の line を読む。全部の行の後）→ DRAIN →(px が idle、未応答 0、request 無し)→ IDLE（done、fail なら kind 5）。IDLE →(kick、拒否)→ IDLE（kind 2）。ROW と MUL の中の fail（error の応答）→ DRAIN（px を abort）。
- `atg_blt_rsv_px`: IDLE →(行の記述子)→ ROW（1 cycle に 1 group）→(行の最後の group)→ IDLE か次の行、最後の行の後と line の変わり目で FLUSH →(ctl が書き込みを取る)→ 前の状態。abort で IDLE と空の FIFO。
- 資源の寿命（resolve）: line の FIFO の場所は読みを出す時に取り（credit）、px が window に移す時に返る。組み立ての buffer は書き込みが request register に移る時に空く。行の記述子は ctl が出し px が最後の group で返す。
- 資源の所有と寿命: d_s と smask は warp の slot の寿命（`fl_go` の前の snoop から `xr_valid` の解放まで）、ROP の中では quad の寿命。d_s は「warp = 三角形 1 つ」（v1 の pmap = 0）に頼る（§15.4 の制約）。MS の image の memory は driver の `VkDeviceMemory`（今と同じ）。

### 15.14 失敗と corner case

- **予約の値**: MS_CTRL[3:0] の 1・3・5 以上は 0（1 sample）として読む（fault にしない: STATE の範囲の書き込みは fault の種類を増やさない方針）。TEX_IMAGE[15:12] も同じ。
- **全 sample が落ちた画素**: RX で SAMPLE_KILL により（covered でない、quad の他の lane が covered なら helper）、SU で `exp 0x105` により（ROP に出さない）、ROP で a2c により（書かない）。
- **depth を出す shader**: zexp の lane は sample の全部に出した値（d_s を足さない）。clamp は今の depth の出力と同じ扱い（`atg_depth_u24` の飽和）。
- **color の出力の無い shader**（depth だけの pass）: compiler が `movi rT, -1; exp rT, 0x105` を出す（§15.5）。r3 を `exp 0x104` に出すと 4x で全 sample が中心の z（clamp 無し）になる誤り（GHCI §12.11 で禁止）。
- **MS の image を描いた後に sample する**: firmware は `WAIT_IDLE` + `INVALIDATE` T$ を barrier の後の sample の前に必ず出す（でないと T$ の古い line）。driver の barrier（p019）も同じ。**resolve**（BLT）は cache を通らないので T$ の無効化は要らないが、前の draw の全部を `WAIT_IDLE` flags = 0 で待つ（review 3 の 1）。resolve の dst を後で TU で読む時に `WAIT_IDLE` BLT + `INVALIDATE` T$。
- **resolve の corner case**（§15.8）: src と dst が memory で重なる（Vulkan は禁止）→ 結果は未定義、fault にしない。幅・高さが 0 か clip で空 → memory に触れず `done`。BLT_RESOLVE の samples ≠ 4、format 3〜15、ps と format の不一致（UNORM565 は 16 bit だけ）、blend・reverse との組み合わせ、`MS4` = 0 → kind 2（kick の次の cycle、memory に触れない）。AXI の error の応答 → 新しい request を止め、未応答を drain して kind 5（2D と同じ）。aperture の拒否 → CP が kind 1 を記録して quiesce、BLT は request を持ったまま RESET まで busy（2D と同じ）。quiesce の間は request が待ち、終われば続く。`core_rst_n` で wrapper・2D・resolve の全部が IDLE と空の FIFO に戻る。
- **stride・base の揃えの誤り**（driver の bug）: ROP は行の 2·S·ps byte が line を跨ぐと誤った line を書く（検査しない。`RT_STRIDE` は今も検査していない）。TB は揃った値だけを使う。p019 の validation で守る。
- **1x の互換**: SAMPLE_KILL = 0・MS_CTRL = 0（reset 値）で今の出力と bit で同じ（r6 の書き込みと RX の cycle 数を除く）。既存の scene（raster・shade・tex）の PASS で確かめる。
- **割り込み・DMA**: 新しい割り込み・fault の種類・DMA の道は無い（ROP・TU は今の AMB の client のまま）。quiesce・reset は今の順（§1.3）で、新しい FSM は `core_rst_n` で IDLE に戻る。

### 15.15 model・TB・scene・Verilator の計画（試験は host の iverilog と Verilator だけ。QEMU と VFIO と板はこの Phase に無い）

- **model**: 新しい `tools/msmodel.py`（`rxmodel.py` を import し、sample の coverage・SAMPLE_KILL・centroid の選択・d_s・r6〜r9・ROP の `atg_rop_ms` の z_s・a2c・a2one・sample ごとの ds と wb・BLT の RESOLVE の期待（UNORM8・UNORM565 の RNE、SAMPLE0、linear・tile の dst、clip）。`rxmodel.py` 本体は 1x の関数を変えない（P3 の `tumodel.py` との衝突を避けるため TU の MS は part F の後の `tumodel.py` に小さく足す）。`gsi1model.py` に r6〜r9・`exp 0x105`。
- **自己試験の command**: `python3 -I tools/msmodel.py --selftest` が `PASS msmodel.selftest` を出す（1x の関数が `rxmodel.py` と bit で同じ事、4x の sample の位置・tie・a2c の表の自己検査）。
- **1x の回帰の守り**（review 2 の 8）: 1x の vector を作り直す時、`tools/vec-diff.py`（S1 で書く小さな script）で **87457fa の vector と比べ、差が r6 の書き込みの行と smask・zexp の新しい列だけ**である事を確かめる（`PASS vecdiff.<name>`）。期待値を新しい model だけで作り直して r0〜r5 の誤りを隠さないため。
- **単体 TB の PASS の行**（各 TB は最後に `PASS <module>` も出す。ROP と RX の TB は LINE_BYTES 32 と 64 の両方で流す）:

| TB | 足す PASS の行 |
| --- | --- |
| `atg_rx_cov_tb`（新） | `atg_rx_cov.samples`（4 sample × random の三角形を `msmodel.py` と、edge の上の sample の tie を含む）、`atg_rx_cov.centre`、`atg_rx_cov.skip`（空の quad の短絡が covered な sample を飛ばさない） |
| `atg_rx_scan_tb` | `atg_rx_scan.ms`（fq_scov・fq_ccov・SAMPLE_KILL）、`atg_rx_scan.ms1x`（MS_CTRL = 0 で今の fq_* と同じ） |
| `atg_rx_bary_tb`（新） | `atg_rx_bary.centre`、`atg_rx_bary.offset`、`atg_rx_bary.dz` |
| `atg_rx_frag_tb` | `atg_rx_frag.ms`（r6・r7〜r9・0xFF8〜0xFFB を三角形ごとに 1 回計算し warp ごとに送る・4x の r3 の unclamped） |
| `atg_su_exp_tb` | `atg_su_exp.ms`（`mr6` の snoop、`exp 0x105` の最後の書き込み、zexp、d_s → `ex_ms`、smask = 0 の lane を出さない、slot の解放で d_s が 0） |
| `atg_su_lda_tb` | `atg_su_lda.ms`（0xFF8〜0xFFB を表に書かない） |
| `atg_su_gfx_tb` | `atg_su_gfx.ms`（r6 と `exp 0x105` を `gsi1model.py --warps` と） |
| `atg_su_dec_tb` | `atg_su_dec.texszs`（`texsz.s` = imm 3 の uop、CAPS[29] = 0 で fault） |
| `atg_rop_ms_tb`（新） | `atg_rop_ms.depth`（z_s と clamp、zexp）、`atg_rop_ms.a2c`（alpha の表の境）、`atg_rop_ms.a2one`、`atg_rop_ms.bypass1x`（bit で同じ） |
| `atg_rop_ds_tb` | `atg_rop_ds.ms`（8 つの比較の関数を sample ごと、interleaved の address） |
| `atg_rop_wb_tb` | `atg_rop_wb.ms`（sample ごとの blend と write mask） |
| `atg_blt_avg_tb`（新） | `atg_blt_avg.unorm8`（Σ = 0〜1020 の全部の値で RNE、byte の独立）、`atg_blt_avg.rgb565`（3 field の境と RNE）、`atg_blt_avg.sample0` |
| `atg_blt_rsv_tb`（新、`atg_blt` の wrapper ごと。LINE_BYTES 32 と 64） | `atg_blt_rsv.unorm8`・`.rgb565`・`.sample0`（固定の矩形、Verilog の参照 model と word ごと）、`.offset`（src と dst の x の揃いが違う、line を跨ぐ group）、`.tiled`（tile の dst）、`.clip`、`.random`（seed、format・ps・offset・大きさ・tile・clip を乱数で、応答の遅延と ready の stall も乱数で）、`.stream`（TB の中の AMB の memory の model を遅延 0・ready 常に 1 にし、揃った 4x・32 bpp・LINE_BYTES 64 の dst の 1 line が 7 cycle 以下）、`.rowshare`（SRC_STRIDE と DST_STRIDE が LINE_BYTES の倍数でなく行が line を共有）、`.fault`（kind 2 の組み合わせの全部が memory に触れない、AXI の error で drain の後に kind 5、**その直後の普通の resolve が正しい**）、`.2d`（wrapper を通した FILL・COPY が今の結果と同じ、**2D → resolve → 2D の交互の kick**）、`.nms4`（`MS4` = 0 の instance で [2] = 1 が kind 2）、`.halt`（quiesce の間 request が待ち、終われば続いて正しい）。memory の model は TB の中に持つ（共有の `amb_mem` は変えない） |
| `atg_tu_addr_tb`・`atg_tu_cache_tb`・`atg_tu_filter_tb` | `atg_tu_addr.ms`（x′・行の長さ・s mod S・`texsz.s` の S）、`atg_tu_cache.h16`（half word の選択と 565 の border）、`atg_tu_filter.rgb565`（c/31・c/63 の RNE） |

- **故意の誤り**: RTL に `ifdef MUT_<名前>` の誤り（`MUT_SAMPLE_SWAP`（sample 1 と 2 の offset を入れ替え）、`MUT_A2C_STEP`、`MUT_DZ_SIGN`、`MUT_R3_CLAMP`、`MUT_SMASK_AND`（0x105 を重ねて AND）、`MUT_RSV_RNE`（UNORM の丸めを半分は上に）、`MUT_RSV_SPLIT`（linear の dst の line の残りで group を切らない）、`MUT_RSV_ROWEND`（行の残りが 0 でも次の line を先読みする）、`MUT_RSV_CREDIT`（credit の上限を +1）、`MUT_RSV_RSP`（wrapper が応答を両方の engine に配る））を置き、`iverilog -DMUT_<名前>` で該当の TB の該当の PASS の行が出ず `FAIL` が出る事を確かめる（file を書き換えて戻す手順は使わない）。
- **scene**（新 `sim/tb/atg_top_msaa_tb.v` + `tools/rx-msaa-scene.py`。N=1。**2 つの形: KC705（LINE_BYTES 64）と、TU 付きの ZYBO の形（`atg_top_tex_tb` と同じ HAS_TU(1)、LINE_BYTES 32）**。RT 64×48 と 63×47。各 run は `timeout 600`）: (1) 辺を共有する 2 つの三角形（sample の二重書き・抜けが無い）、(2) depth で交わる 2 つの三角形（sample ごとの z）、(3) alpha の ramp と a2c、(4) `exp 0x105` の出力、(5) centroid の varying を縁の画素で（三角形の中の値）、(6) MS の color を BLT の RESOLVE で 1x の image へ（offset、2 layer の src、tile の dst を含む）、(7) MS の depth の image を `texf` で読む draw、(8) **16 bpp（RGB565）の 4x** と resolve、(9) **奇数の幅**の RT（63×47、P = roundup(w, 2)·S·ps）、(10) **4x の draw の直後に 1x の draw**（MS_CTRL の変更が残りの warp に効かない）、(11) SAMPLE_KILL と CENTROID の組み合わせ、(12) **color の出力の無い depth だけの 4x の draw**（`movi rT, -1; exp rT, 0x105`）、(13) `texsz.s`。PASS の行: `atg_top_msaa.<1〜13 の名前>` と `atg_top_msaa`。**受け入れ**: MS の color・depth の image と resolve の結果が `msmodel.py` と **word ごとに一致**、resolve の PNG（6 倍、`build/review/ws001-p027-msaa.png`）。
- **Verilator**: harness に MSAA の mode（scene の (1)(2)(6)）、`make verilator` の PASS に入れる。
- **S6 の実装での変更**（2026-10-25 P2、q1560-i02）: (a) ZYBO を target から外したので scene は **KC705 の形だけ**（iverilog は LINE_BYTES 64、Verilator は既定の形 LINE_BYTES 32 で同じ scene を流すので 32 byte の line も通る）。(b) 画像は 32×24（奇数の幅は 31×23）、case は 14: 上の (1)〜(13) に **(14) `texf_odd`**（奇数の幅の 4x の image を `texf` で読む。(7) の 32 幅では行の texel 数 roundup(w, 2)·S の誤り（`MUT_TU_MSROW`）が見えなかったため）を足し、(2) に depth 0 の辺を持つ三角形を足した（中心の外の r3 が 0 未満になり、`MUT_R3_CLAMP` が見える）。(c) Verilator の mode は (1)(2)(6) の部分ではなく **scene の全部**（Verilator では数秒）。(d) PASS の行は `atg_top_msaa(kc705).<case>` の 14 行と `atg_top_msaa(kc705).scene`・`atg_top_msaa`。(e) resolve の PNG は Verilator の `build/verilator/msaa.png`（RTL の出力、32×24）。
- **回帰**: `make lint` clean。`make sim` の PASS の行の数が **S1 の開始の commit で数えた数**（S1 の記録に commit と数を書く）より減らない。既存の raster・shade・tex の scene が bit で同じ（今の TB がそのまま PASS）。
- **firmware の resolve の手順**（p018 の受け入れに入れる、review 2 の 18）: p027 の scene の (6) は TB が STATE と `KICK.BLIT` を直に出すので firmware を通らない。p018 の firmware の試験に「render pass の resolve attachment と `vkCmdResolveImage` の region・layer・tile の dst が BLT の RESOLVE の正しい STATE になる」「BLT ↔ ROP の `WAIT_IDLE`」を入れる（§15.11）。

### 15.16 module の分け方（1 module ≤ 400 行・FSM 1 つ・≤ 40 port）

| module | 変更 | 行（推定） | port |
| --- | --- | --- | --- |
| `atg_rx_cov`（新） | sample の offset と 4 lane の coverage | ≈120 | ≈14 |
| `atg_rx_scan` | SAMP の副状態、fq_scov・fq_ccov | 296 → ≈340 | 27 → 28 |
| `atg_rx_bary`（新） | plane・fdiv・barycentric・d_s（`atg_rx_frag` から移す） | ≈220 | ≈16 |
| `atg_rx_frag` | 順序だけ、r6・r7〜r9・DZ | 321 → ≈260 | 32 → 33 |
| `atg_rx` | wiring（例外） | — | 39（`fq_*` は内部） |
| `atg_su_exp` | `mr6`・`m5`、0x105（最後の書き込み）、zexp、d_s、`ex_ms` | 267 → ≈330 | 35 → 39（fl_pw_* 3 本 + `ex_ms`） |
| `atg_su`・`atg_top` | wiring（例外）、`ex_ms` | — | — |
| `atg_rop_order` | `ex_ms` → `q_ms` | 82 → ≈90 | 28 → 30 |
| `atg_rop_ms`（新） | z_s、a2c、a2one、coverage | ≈220 | 21 |
| `atg_rop_ds` | (lane, sample) の 8 entry | 225 → ≈290 | 30（幅だけ） |
| `atg_rop_wb` | sample ごとの blend と merge | 264 → ≈330 | 29（幅だけ） |
| `atg_rop` | wiring（例外）、`atg_rop_ms` | — | 36 → 37 |
| `atg_tu_addr`（part F の後の分割に従う） | x′・行の長さ・16 bit の texel の address・`texsz.s` の S（`ta_value`）と `.l`/`.s` の区別 | +≈30 | 変えない |
| `atg_tu_cache` | half word の選択、565 の border | +≈20 | 変えない |
| `atg_tu_filter` | 565 → fp32（RNE） | +≈30 | 変えない |
| `atg_su_dec_tabc` | `texsz.s`（imm 3、MS4） | +≈8 | 変えない |
| `atg_blt`（wrapper に書き直し） | op の振り分け、AMB の口の mux、parameter `MS4` | ≈120 | 22（変えない） |
| `atg_blt_2d`（今の `atg_blt` の名前を変えただけ） | 変えない | 696 | 22 |
| `atg_blt_rsv`（新） | STATE の写し、検査、clip、乗算、行の walk、読み、AMB の request register、credit | ≈320 | ≈36（行の記述子と px の書き込みはそれぞれ 1 本の bus に詰める: review 3 の 17）。幅: 行の src の byte 数 w·S·ps は 21 bit、行の line 数 n は 17 bit まで（w = 65535・ps 4 の時、review 3 の 18） |
| `atg_blt_rsv_px`（新） | 行と line の FIFO、window、group、組み立て、書き込み | ≈320 | ≈26 |
| `atg_blt_avg`（新） | 平均（UNORM8・UNORM565・SAMPLE0） | ≈120 | 5 |
| `atg_su`・`atg_top`（wiring） | parameter `MS4` | — | — |

### 15.17 実装の段と LW（p027 の中。8 LW ≈ 2〜3 時間）

| 段 | 内容 | 受け入れ | 依存 | LW |
| --- | --- | --- | --- | --- |
| S1 | `msmodel.py`（RX の sample・centroid・d_s、ROP の ms・ds・wb、BLT の RESOLVE）と `--selftest`、`vec-diff.py`、vector の生成、**GSI1 の道具の全部の変更**（`gsi1model.py`・`gsi1asm.py`・`gsi1dis.py` の r6〜r9・`exp 0x105`・`texsz.s`。S3・S5 は道具を変えない: 衝突を避けるため）、spec の更新（§15.16 の module の spec §3〜§8 を先に直す） | `PASS msmodel.selftest`、各 spec の §8 の PASS の一覧が §15.15 の表と一致、各 spec の port の表の行数が spec の「N ports」の行と一致し ≤ 40（wiring の例外を除く）、`make sim` の PASS の行の数を数えて記録 | この設計の review | 5 |
| S2 | RX: `atg_rx_cov`・`atg_rx_bary`（新）、`atg_rx_scan`・`atg_rx_frag`、TB | §15.15 の RX の PASS（LINE_BYTES 32・64）、`PASS vecdiff.rx_frag`、MUT の FAIL、lint | S1 | 7 |
| S3 | SU: `atg_su_exp`・`atg_su`（fl_pw_* を exp に、`ex_ms`）、`atg_su_lda`・`atg_su_gfx` の TB | SU の PASS、MUT の FAIL、lint | S1 | 3 |
| S4 | ROP: `atg_rop_ms`（新）、`order`・`ds`・`wb`、TB | ROP の PASS（LINE_BYTES 32・64）、`.bypass1x`、MUT の FAIL | S1 | 7 |
| S5 | TU と decode: MS の `texf`（x′・行の長さ）、RGB565 の `texf`（`atg_tu_addr`・`atg_tu_cache` の half の選択と border・`atg_tu_filter` の 565 → fp32）、`texsz.s`（`atg_su_dec_tabc` の imm 3、`atg_tu_addr` の `ta_value` が S、`atg_su` に parameter `MS4`（`atg_top` の `MS4` は S7））、`tumodel.py`、GHCI §12.6 | TU と SU の decode の PASS | S1、**p009 part F の merge** | 5 |
| S6 | `atg_top`（`ex_ms`、CAPS[29] = `MS4`）、`atg_top_msaa_tb` と scene、Verilator の mode、README の ROP・RX・TU の行、`docs/ghci.md` §12.11 の確定（draft の印は残す）。実装での変更は §15.15 の「S6 の実装での変更」 | §15.15 の scene の `atg_top_msaa.*` の PASS の全部（2 つの形）、`make lint` clean、`make sim` の PASS の行が S1 の数より減らない、`make verilator` PASS、既存の scene の TB が変えずに PASS | S2〜S5、S7 | 6 |
| S7 | **BLT の RESOLVE**（§15.8）: `atg_blt` を wrapper に、今の物を `atg_blt_2d` に、`atg_blt_rsv`・`atg_blt_rsv_px`・`atg_blt_avg`（新）、`atg_top` の `MS4` を BLT に、spec（`atg_blt.md` を wrapper に、`atg_blt_2d.md`・`atg_blt_rsv.md`・`atg_blt_rsv_px.md`・`atg_blt_avg.md`）、`docs/ghci.md` §8.2 | `atg_blt_avg.*`・`atg_blt_rsv.*` の PASS（LINE_BYTES 32・64）、MUT の FAIL、`atg_top_tb` の `PASS atg_top`（2D が変わらない）、lint | S1 | 8 |
| 計 | | | | **41 LW**（±30%: 29〜53。版 5 の 32 LW に resolve の hardware の S7 の 8 LW と、S1 の BLT の model の +1 LW を足した: review 3 の 19） |

- 順は S1 → S7 → S2 → S3 → S4 → S5 → S6（S7 は S1 の model だけに依り、RX・SU・ROP と重ならないので先に）。S2・S3・S4・S7 は §15 の interface が決まれば並行にできる（別の担当、別の worktree）。衝突する所: `atg_top`・`atg_su`・`atg_rop` の wiring と README（S6 で Q1 が合わせる）、GSI1 の道具（S1 が全部を先に直すので S3・S5 は触らない）、`MS4` の parameter（S7 が `atg_top` に入れて BLT に通し、S5 が `atg_su` に通し、S6 が CAPS に使う: review 3 の 11）。
- 板と timing は対象外（p024・p025）。

### 15.18 見つけた Vulkan 1.0 core の MSAA 以外の食い違い（この Phase の範囲の外。U46）

設計のために読んだ所で見つけた物（MSAA の 4x の受け入れには要らないが、`framebufferStencilSampleCounts` などの limit が意味を持つには要る）:

1. **stencil の op が ROP に無い**（`atg_rop_ds` の comment「Depth only so far」、spec §10）。D24S8 の stencil の test・op・front/back（facing の bit を ROP に）。
2. **D16_UNORM が無い**（ROP・TU）。Vulkan は D16 を必須にしている（format の表で D16_UNORM の行に必須の印。列は未取得）。
3. **stencil の aspect の sample**（TU）→ `sampledImageStencilSampleCounts`。
4. **color attachment が COLOR0 だけ**（`exp 0x100+c` だけ、ROP の RT 1 つ）。Vulkan の `maxColorAttachments` の最小は 4。
5. **RT の format が 3 つだけ**（BGRA8・RGBA8・RGB565）。必須の color attachment の format は他にも有る（R8・RG8・R16G16B16A16_SFLOAT・R32_UINT などの行に印。列は未取得）。
6. **point と line を描かない**（VF は (p,p,p)・(a,b,b) の退化した三角形にし、RX は面積 0 を捨てる）。MS の line（strictLines = FALSE の平行四辺形）もこの上に乗る。
7. **occlusion の query が無い**（core）。MS では sample の数を数える。
8. **SPIR-V の front end が FragDepth と SampleMask を扱わない**（p010 で）。
9. **D24S8 の depth だけの clear・copy**（BLT の FILL・COPY は word 全部を書き stencil を上書きする）。
10. **input attachment が無い**（core。`subpassInputMS` も。design にも `spirv.c` にも無い）。MS の input attachment は `texf` の rs2 = sample に写せる。
11. **TU の 565 の filter**（`texl`/`texb`）。MS の fetch だけは S5 で足す。

### 15.19 選ばなかった案と理由

| 案 | 理由 |
| --- | --- |
| tile の on-chip の buffer（TBR の形で MS の sample を chip の中に持ち tile の終わりに resolve） | 帯域は最良（DDR に MS を書かない）だが、IMR の今の pipeline を binning（primitive の tile への振り分けと parameter buffer）に作り直す大きな変更。Vulkan の `storeOp STORE` の MS の attachment は結局 memory に要る。v1 の正しさ優先の方針に合わない |
| sample-plane の配置（sample s の面を別に） | quad の 1 行が S 本の line に分かれ、`ds` と `wb` の line buffer が S 倍要る。resolve も S 本の stream |
| `MS_CTRL`・SAMPLE_MASK を ROP の範囲に | RX が SAMPLE_MASK を使う（shading の前に落とす Vulkan の順）。RX の範囲の SET_REG は RX と ROP の busy の両方で止まるので、1 つの word を両方が読んで安全 |
| SAMPLE_MASK を正（1 = 残す）で | reset 値 0 で今の試験と firmware が全部の coverage を失う |
| SampleMaskIn を特殊 operand（123 `smask`）に | sched の warp の info を 128 bit 広げ、opd に lane ごとの mux が要る。r6 なら SU の core は変わらず、RX の書き込みの 1 回で済む |
| centroid を compiler が `qd` の微分で外挿（中心 + 微分 × offset） | perspective の b は画面で線形でなく、一次の外挿は三角形の外に出得る（Vulkan の「must also fall within the bounds of the primitive」を守れない） |
| centroid を常に最初の covered な sample に | Vulkan は許すが、中心が中なら中心の方が画質が良く（GL と同じ慣習）、判定は中心の評価 1 回で安い |
| sample ごとの z を RX が lane × 4 で計算して SU に運ぶ | RX の plane の評価が quad あたり +44 cycle、exp の lane ごとの word が +4。warp の定数 d_s 4 つなら RX は warp ごとに 1 回、運ぶのは 128 bit |
| d_s を ord の FIFO で RX → ROP に直接 | ROP の順序の口（RX の直の道と SU の export の合流、§3.8）に「発行した連番ごとの data」の FIFO と、その深さ（同時に未退の連番の数）の上限の論と back-pressure が要る。warp の slot の寿命に乗せる（exp の snoop）なら深さは NWARPS で決まり、順序の口を変えない |
| ROP が quad の lane の z の差から dz/dx を作る | 丸めた値の差で精度が落ち、shader が depth を出した lane で使えない |
| resolve を firmware の内蔵の draw に（版 5 の推し A） | ユーザーが「あるべき論」で不採用（§15.20）。RX の frag の律速（1080p ≈1.0 s @ 100 MHz）、draw の state の退避と出し直し、TU の slot・constant、tile の dst の一時の帯と TILE が要る |
| resolve を ROP の walk に、または新しい block に | §15.8 の比べた表。ROP は quad の順序の block で memory の矩形の walk の口が無い。新しい block は GHCI の µop・KICK・STATUS・MC の client を足すが中身は BLT の op と同じ |
| resolve を今の BLT の 2D の FSM に足す | 2D の FSM は 696 行（U38）で、往復ごとに待つ形（COPY 64 MB/s）。streaming にするには読みの credit と FIFO が要り、2D の測った動作を変える。別の engine にして 2D を bit で保つ |
| resolve を compute の kernel に | `sw` で format の pack を shader が書く（≈20 命令多い）、ROP の format の変換を使えない |
| resolve を ROP の「store の時」に | IMR では後の primitive が sample を変えるので、subpass の終わりまで resolve できない（結局 1 回の全面の pass） |
| sample shading を v1 に（lane = sample） | 任意の feature（U43）。RX が sample ごとに lane を作り、r4・r5・barycentric を sample の位置にし、exp の 1 lane が 1 sample を書く形（ROP は smask の 1 bit）で後から足せる（この設計の port はそのまま使える） |
| MSAA を parameter（`MSAA` = 0 で外す） | 構成が増え lint と試験が倍になる。追加は ≈2k LUT（KC705 の 1%）。ZYBO の raster の bitstream 3 は目標の道の外 |
| 2x・8x も | Vulkan の必須は 1 と 4 だけ。8x は 1080p で帯域が 2 倍 |

### 15.20 U 項目（ユーザーの判断。推し付き）

**回答（2026-10-25 02:32）**: ユーザー「U項目は推しでOKです。ただ、U44はちゃんとあるべき論で実装するのがいいと思います。U46は、N=2でもう１つサブエージェントを立てて、実装しましょう。もし検証が多いなら、N=3でもいいです。」 → U43 = 入れない、U44 = **推しの A を採らず、あるべき形の hardware の resolve**（memory の帯域で streaming する専用の resolve の道、format ごとに正しく平均、整数は 1 つの sample。BLT の RESOLVE の op か ROP の道かは p027 の実装の段の最初に設計を直して決める）、U45 = v1 は正しさだけ、U46 = 新しい Phase [p030](phase030/phase.md)。

| U | 問い | 推し | 他の案 |
| --- | --- | --- | --- |
| **U43** | `sampleRateShading`（任意の feature: SampleId・SamplePosition・Sample の補間・interpolateAt*）を v1 に入れるか | **入れない**（v1 は 0、Future Work。§15.19 の形で後から足せる） | 入れる（RX と exp の lane = sample の道、+≈6 LW） |
| **U44** | resolve の作り方 | **（回答で B を「あるべき論」の形に: BLT の op RESOLVE と専用の streaming の engine、§15.8）**。版 5 の推し: A: firmware の内蔵の draw（新しい RTL 無し、TU と ROP の format の全部に効く。v1 は RX の frag の律速で 1080p の 4x の resolve ≈ 1.0 s @ 100 MHz（720p ≈0.46 s）と遅い。RX の pipeline 化（p015）で全部の draw と一緒に速くなる） | B: BLT の RESOLVE の op（BLT の分割（U38）が先、format ごとの平均の回路。今の BLT の COPY の速さなら 1080p で ≈0.5 s、streaming の後は memory の帯域まで）、C: compute の kernel |
| **U45** | 4x の性能の目標（帯域と律速、§15.12） | **v1（p027）は正しさだけ。性能の数字は RX の frag と ROP の律速（depth の line の cache）を p015 で直した後に決める。1080p60 の 4x は depth の cache に加え圧縮（fast clear・line の印）か tile の buffer の Future Work** | 1080p60 の 4x を今決めて圧縮を p027 か p015 に入れる |
| **U46** | §15.18 の MSAA 以外の Vulkan 1.0 core の食い違い（stencil の op、D16、stencil の sample、MRT 4、format、point/line、occlusion query、FragDepth/SampleMask の front end、depth だけの clear）をどこで扱うか | **新しい Phase「ROP・format・primitive の Vulkan 1.0 core の残り」を p027 の後・p018 の前に**（firmware と driver がこの形に依るため）。Q1 が範囲と LW を見積もる | p016 の前に後回し（Vulkan の conformance は p028 の後） |

### 15.21 license と転記

- この設計と amaterrace-gpu の追加はどちらも Zlib（既存と同じ）。
- Vulkan の仕様（Khronos、**CC-BY-4.0**、Vulkan-Docs の `LICENSE.adoc` で確かめた）: 標準の sample の位置の値（事実）を使い、§15.1 の表の短い引用は出典を明記した。仕様の文・表の構造は写さない。ghci.md と RTL の comment には「Values referenced: Vulkan specification (Multisampling, standard sample locations)」と書く。
- SPIR-V の capability の対応は Vulkan の spirvenv の表の事実。Mesa など他の driver の code は読んでいない・写さない。alpha to coverage の表は自前。

## 16. Vulkan 1.0 core の残り（ROP・format・primitive・query。版 6、ws001-p030 の設計の段）

2026-10-25 P1（ws001-p030、q1559-i01、zedBSD の worktree p1-p030（基点 32b51bf34）、amaterrace-gpu の worktree p1-p030（基点 main 87457fa）を読んだ。P3 の part F（`p3-p009f`、a079acc）と P2 の p027 の draft（`p2-p027`、f393310）は読むだけ）。承認: 2026-10-25 02:32 ユーザー「U項目は推しでOKです。ただ、U44はちゃんとあるべき論で実装するのがいいと思います。U46は、N=2でもう１つサブエージェントを立てて、実装しましょう。もし検証が多いなら、N=3でもいいです。」（[phase030](phase030/phase.md)）。この節は設計だけで、RTL・model・firmware・driver は書かない。review の指摘と対応は [design-review-p030.md](design-review-p030.md)（design-reviewer の 2 回: 1 回目 35 件（Critical 2・High 4・Medium 16・Low 13）、2 回目 23 件（High 4・Medium 5・Low 14）。全部に対応、表は §16.26）。2026-10-25 Q1 の追加の依頼（p027 の U44 の決定で resolve は BLT の RESOLVE の op、`atg_blt_rsv`）: 「BLT RESOLVE の平均の format の code 3〜5（sRGB・SFLOAT16・SFLOAT32）、10:10:10:2 の code、8 byte の画素（BLT_OP[9:8]=2）」を p030 の RT の format の段に足し、RT の format ごとの resolve の code を §16.2 の表に書く（§16.12）。

### 16.0 出典と確認の水準

- **Vulkan の文面**（Khronos の Vulkan-Docs、main、2026-10-25 に raw の adoc と `xml/vk.xml` を取得して読んだ。**CC-BY-4.0**、`LICENSE.adoc` で確かめた）: `chapters/formats.adoc`（Required Format Support の表 7 つ: Sub-Byte、1-3 Byte、4 Byte、10-bit、16-bit、32-bit、64-bit/uneven、Depth/Stencil、BCn）、`chapters/limits.adoc`（Required Limits の表）、`chapters/features.adoc`（occlusionQueryPrecise・pipelineStatisticsQuery など）、`chapters/fragops.adoc`（Depth Bounds Test、Stencil Test、Depth Test の「Depth Clamping and Range Adjustment」、Sample Counting）、`chapters/primsrast.adoc`（Basic Point Rasterization、Basic Line Segment Rasterization と non-strict の parallelogram、Depth Bias Computation）、`chapters/queries.adoc`（Occlusion Queries）、`chapters/capabilities.adoc`（`sampleCounts` の規則）、`vk.xml`（`VK_VERSION_1_0` の Feature requirements = `robustBufferAccess`、`VkFormat` の番号）。表の中の短い句はこれらの引用。**latest の文面から 1.0 の要求を読んだ**: `{core}` の印の値と、`ifdef::VK_BASE_VERSION_1_1` 等の 1.1 以降の追加（例: maintenance1 の TRANSFER の bit、1.2 の `framebufferIntegerColorSampleCounts`）は 1.0 の要求から外した。Roadmap の値（`{limit2022}` 等）は要求でない。
- **読んだ RTL・spec（amaterrace-gpu 87457fa、実測）**: `rtl/gpu/rop/atg_rop_{ds,blend,wb,order}.v`（ds は「Depth only so far」、D24S8 の word = {stencil[31:24], depth[23:0]}、DEPTH[5] D24S8・[6] D32F、行ごとに line を 1 本読み 2 lane を試す。blend は factor 0〜14（`SRC_ALPHA_SATURATE` まで）と op 0〜4（ADD〜MAX）の全部、8 bit の UNORM の 3 段 pipeline、BLEND_CONST は RGBA8、RT_FORMAT は 0 BGRA8・1 RGBA8・2 RGB565）、`spec/gpu/rop/*`、`rtl/gpu/rx/atg_rx_setup.v`（437 行、micro-program の fp32 datapath、VIEWPORT・SCISSOR・CULL・RT_SIZE を持つ。**DEPTH_CLAMP・RAST_MODE は使っていない**）、`spec/gpu/rx/{atg_rx,atg_rx_clip,atg_rx_scan,atg_rx_frag,atg_rx_setup}.md`（near plane は z ≥ 0 の geometric な clip、**far plane は clip せず z を [0, 1] に clamp**、x・y は guard band ±16384 px の飽和だけ）、`rtl/gpu/vf/atg_vf_asm.v`（point = (p, p, p)、line = (a, b, b)、restart と instance の境で strip を切る）、`atg_vf_index.v`（PRIM_RESTART の 0xFFFF/0xFFFFFFFF）、`spec/gpu/vf/atg_vf_{conv,fetch}.md`（format は ATTR_DESC[19:16] の 10 種）、`rtl/gpu/su/atg_su_exp.v`（267 行、target 0x100〜0x104 だけ）、`spec/gpu/su/atg_su_{exp,pt}.md`（point size 0x004 は保存しない）、`spec/gpu/cp/atg_cp_seq.md`（µop 0〜13、14〜63 は reserved、SET_REG の範囲ごとの待ち）、`spec/gpu/blt/atg_blt.md`（bpp 0 = 32・1 = 16、16 bit 単位の walk）、`include/ghci_regs.vh`（RX 0x050〜0x05D、ROP 0x070〜0x07C、VF 0x020〜0x04F と ATTR_DST 0x1C0〜0x1CF、0x1D0〜0x1DF は空き）、`docs/ghci.md`（§3.2 CAPS は [28] まで、§4 の capability は id 9 まで、§7.3、§8.2〜§8.4、§12）、`tools/rxmodel.py` の関数の一覧。
- **part F（P3、a079acc、実装中）**: `docs/ghci.md` §8.4 の新しい TU の descriptor（+0 TEX_BASE、+1 TEX_SIZE、+2 TEX_IMAGE（[3:0] level、[7:4] format: 0 RGBA8・1 BGRA8・2 D24・3 D32F・4 RGB565 の予約、[8] tile、[11:9] view type、[15:12] samples の予約、[31:16] depth/layer）、+3 TEX_LAYER_STRIDE、+4 TEX_SAMPLER、+5 TEX_LOD、**+6〜+15 reserved（`atg_tu_desc` は word 0〜5 だけを持つ）**）、`spec/gpu/tu/atg_tu_{desc,filter,cache}.md`（filter は 8 bit の channel の整数の和 / (255 × 2^32)、depth は D24・D32F、border は format ごとの raw の texel）。
- **p027（P2、f393310 の draft）**: §15 と `docs/ghci.md` §12.11（CAPS[29] MS4、STATE 0x05E MS_CTRL・0x05F SAMPLE_KILL、r6〜r9、`exp 0x105`、`ex_ms[147:0]`、`atg_rop_ms`、sample-interleaved の配置）。U44 の回答で resolve は「あるべき形の hardware の道（BLT の RESOLVE の op か ROP の道かは p027 の実装の段の最初に決める）」に変わった。
- **未確認**（推定・記憶の物）: D24 の c/(2^24 − 1) を fp32 にして ROP の f2u24（RNE）で戻すと c に戻る事（往復の正確さ。S1 の `fmtmodel.py --selftest` で 2^24 の全部を確かめる）、Vulkan の「integer の color attachment に入らない値の書き込みは未定義」（記憶。fragops の文は読んでいない）、fp16 への変換の丸め（Vulkan は RNE を要求しない記憶）、合成の LUT の量（全部推定）。

### 16.1 Vulkan 1.0 core の要求（limit・feature・command）と v1 の値

凡例: **必須** = Vulkan 1.0 core が実装に求める物、**任意** = feature か「Unsupported Limit」の値を返してよい物。「v1（p030 の後）」はこの設計の値、「今」は 87457fa（と part F・p027 の設計）の値。

| 項目 | Vulkan 1.0 の文面の要点 | 今 | v1（p030 の後） | 足りない物と行き先 |
| --- | --- | --- | --- | --- |
| stencil test・op・front/back | core（feature の条件無し）。「back stencil state when processing fragments generated by back-facing polygons, and the front stencil state when ... front-facing polygons or any other primitives」 | **無し**（ROP は stencil の byte を保つだけ） | 有り（§16.5） | ROP `atg_rop_dtest`（新）・`atg_rop_ds` |
| depth の format | D16_UNORM は SAMPLED・BLIT_SRC・DEPTH_STENCIL_ATTACHMENT が必須。DS は「at least one of X8_D24_UNORM_PACK32 and D32_SFLOAT」かつ「at least one of D24_UNORM_S8_UINT and D32_SFLOAT_S8_UINT」。D32_SFLOAT は SAMPLED・BLIT_SRC が必須 | D24S8・D32F（ROP）、D24・D32F（TU） | + D16（ROP・TU）、X8_D24（DS） | §16.6・§16.11 |
| depth bias（constant・slope） | core（`depthBiasEnable`）。「m may be approximated as max(\|∂z/∂x\|, \|∂z/∂y\|)」、r = 2^−n（fixed）か 2^(e−n)（float） | **無し** | 有り（§16.9） | RX `atg_rx_setup`（plane の C に） |
| `depthBiasClamp` | 任意 feature | 無し | **1**（RX の min/max 1 つ） | 同上 |
| far plane の clip と depth の範囲 | clip volume「z_m ≤ z_c ≤ w_c」（`vertexpostproc.adoc`）。`depthClampEnable` で clip を止め [min(n,f), max(n,f)] に clamp | **far を clip せず常に clamp**（= depth clamp が常に on。Vulkan に合わない）、**w < 0 の頂点が z ≥ 0 の near の clip を通る**（reversed-Z の投影のカメラの後ろ） | w ≥ ε を常に、near・far を DEPTH_CLIP の時に geometric に clip（§16.9）、depth clamp は ROP（§16.6） | RX `atg_rx_clip`・`atg_rx_cpoly`、ROP `atg_rop_ms` |
| `depthClamp` | 任意 feature | — | **1** | 同上 |
| x・y の clip（viewport の外） | clip volume −w ≤ x, y ≤ w = viewport の矩形 | **無し**（bbox ∩ scissor ∩ RT。viewport が scissor より小さいと外に描く） | bbox ∩ viewport の矩形（§16.9、RAST_MODE[3]） | RX `atg_rx_setup` |
| draw の間の STATE の変更 | 各 draw は自分の state で描く | **hazard**: `atg_cp_seq.v` の 212〜215 行で ROP の範囲は ROP の busy、RX の範囲は RX か ROP の busy だけを待ち、DRAW は VF の busy だけを待つ（263 行）。ROP の busy = 「発行した連番が全部退いていない」（`atg_rop_order.v` 68 行）なので、前の draw が VF・SU・RX の setup に居て連番を得る前は ROP の範囲の SET_REG が通る | **p027 で直す（p030 の前提、§16.8a）**。TU・program の範囲・LOAD_CONST も同じ種類（review 2 の H3） | CP `atg_cp_seq`（p027） |
| `maxPerStageDescriptorSampledImages` 16（stage ごと） | 16（`limits.adoc`。uniform texel buffer も数える） | TU の 16 slot は STATE の全体で 1 組（vertex と fragment の program の interface の表が同じ slot の空間を使う） | stage ごとの 16 は満たせるが、**1 つの pipeline の全 stage の合計が 16**（vertex 16 + fragment 16 は不可）。「規格に合わない点」として記録し、slot の増設か stage ごとの bank を U60 に（review 2 の M5） | TU・firmware（U60） |
| guard band の外の頂点 | clip volume の中の結果が正しい事 | **座標を飽和**（大きな三角形の形が変わる） | guard band の 4 平面で clip（§16.9） | RX `atg_rx_clip` |
| depth bounds | 任意 feature `depthBounds` | 無し | **1**（ds が stored z を比べる） | ROP |
| blend の op と factor | core: op ADD〜MAX、factor 0〜14 と constant。SRC1_* は `dualSrcBlend`（任意） | 8 bit UNORM で全部（RT 3 format） | 全部の BLEND の format（f32 の道を足す、§16.7） | ROP `atg_rop_fblend`（新） |
| blend constant | `blendConstants[4]`（float） | RGBA8 の 1 word | fp32 × 4（U52） | ROP |
| `independentBlend` | 任意 | — | **1**（RT ごとの BLEND と WRITE_MASK） | ROP |
| `dualSrcBlend`・`logicOp` | 任意 | 無し | 0 | Future Work |
| `maxColorAttachments`・`maxFragmentOutputAttachments`・`maxFragmentCombinedOutputResources` | 4・4・4 | **1** | 4（§16.7） | SU exp、ROP |
| point の描画 | core。「a square with side equal to the current point size」、PointCoord | **描かない** | size 1 の正方形、PointCoord（§16.9） | VF→RX の kind、RX setup |
| `largePoints` / `pointSizeRange` | 任意 / Unsupported (1.0, 1.0) | — | 0 / (1, 1)、granularity 0 | — |
| line の描画 | core。strictLines = FALSE は「a parallelogram surrounding the original line」、「Interpolation occurs as if the parallelogram was decomposed into two triangles where each pair of vertices at each end of the line has identical attributes」 | **描かない** | 幅 1 の parallelogram（MS を含む）、`strictLines` = FALSE（§16.9） | 同上 |
| `wideLines` / `lineWidthRange` | 任意 / Unsupported (1.0, 1.0) | — | 0 / (1, 1)、granularity 0 | — |
| `fillModeNonSolid` | 任意 | — | 0 | Future Work |
| primitive restart | core（strip・fan。list は 1.0 では使えない） | 有り（VF） | 有り | — |
| `fullDrawIndexUint32` | 任意（無ければ maxDrawIndexedIndexValue 2^24 − 1） | 32 bit の index | **1** | — |
| viewport・scissor の数 | `maxViewports` は `multiViewport` 無しで 1 | 1 | 1 | — |
| `viewportBoundsRange` / `maxViewportDimensions` | (−8192, 8191) / (4096, 4096) | guard band ±16384 px | 同じ（§16.9） | — |
| `viewportSubPixelBits` | 0 | — | 0（viewport の矩形を整数に丸める） | — |
| occlusion query | core。「the count of passing samples」、PRECISE が無ければ非 0 なら何でもよい | **無し**（gpu-op 47〜49・127〜131 は X） | sample の数（§16.8） | ROP `atg_rop_occ`（新）、CP µop 14、firmware |
| `occlusionQueryPrecise` | 任意 | — | **1** | — |
| `pipelineStatisticsQuery` | 任意 | — | 0 | — |
| timestamp | `timestampValidBits` は 0（未対応）か 36〜64 | — | 0 | Future Work（64 bit の counter と µop） |
| vertex の format（VERTEX_BUFFER） | §16.2 の列 V | 10 種（ATTR_DESC[19:16]） | 列 V の全部（§16.10） | VF |
| `robustBufferAccess` | **必須の feature**（`vk.xml` の VK_VERSION_1_0 の Feature requirements）。範囲の外の読みは「values from within the memory range(s) bound to the buffer」か 0 か (0,0,0,x)、書きは捨てるか範囲の中 | 無し | vertex の fetch は ATTR_LIMIT（§16.10）。SU の buffer の道は compiler（§16.14、p010） | VF、p010 |
| 必須の format（SAMPLED・FILTER_LINEAR・COLOR_ATTACHMENT・BLEND・DS） | §16.2 | RGBA8・BGRA8・D24・D32F（＋565 の予約） | §16.2 の全部 | TU・ROP |
| image view の component swizzle | core（`VkComponentMapping`） | **無し** | TU の TEX_FORMAT[20:9]（§16.11） | TU |
| input attachment（`subpassInputMS` を含む） | core（`maxPerStageDescriptorInputAttachments` 4） | 無し | compiler の道（§16.14） | p010・p018 |
| storage image・storage texel buffer | core（`maxPerStageDescriptorStorageImages` 4、format の列 S） | 無し | compiler の道（§16.14） | p010・p018・p019（U50） |
| uniform texel buffer | core（`maxTexelBufferElements` 65536、列 U） | 無し | TU の slot（§16.14） | p010・p018（U50） |
| indirect の draw・dispatch | core command（`maxDrawIndirectCount` は 1 でよい） | X | firmware が引数を読む（§16.16） | p018（U50） |
| `drawIndirectFirstInstance` | 任意 | — | 1（firmware） | p018 |
| event、secondary の command buffer、複数の subpass | core command | X | firmware（§16.16） | p018・p019（U50） |
| `maxUniformBufferRange` | 16384 | constant bank 256 word | compiler の道（`lw`）か bank の拡張（§16.14） | p010（U50） |
| `shaderClipDistance`・`shaderCullDistance` | 任意 | 無し | 0 | Future Work |
| 圧縮の texture の format | **1 組は必須**: 「SAMPLED_IMAGE_BIT, BLIT_SRC_BIT and SAMPLED_IMAGE_FILTER_LINEAR_BIT features must be supported in optimalTilingFeatures for all the formats in at least one of: this table [BC], [ETC2], or [ASTC]」（`formats.adoc` の BCn の表の注、版の ifdef の外 = 1.0 の要求。feature の `textureCompression*` はその組の印） | 無し | **p030 では 0**（2026-10-25 ユーザー「圧縮テクスチャはPCIe GPUの実機bringupの後に回します。」。設計の形は §16.11a、U58） | 後の Phase（Q1） |
| `maxVertexOutputComponents`・`maxFragmentInputComponents` | 64・64（`limits.adoc`） | **32**（KC705 の VARY_WORDS 32 word = 32 component。§3.7 の「128」は誤り、S13 で直した）、ZYBO 16 | **64**（S13、U59: PT と primitive table を 64 word に、table の複製を 2 に。§16.22 の「S13 の実装で決めた事」） | SU `atg_su_pt`・`atg_su_lda`、RX `atg_rx_frag`（U59） |
| 他の limit（`maxComputeSharedMemorySize` 16384、`maxPushConstantsSize` 128、`maxBoundDescriptorSets` 4、`maxPerStageDescriptorUniformBuffers` 12・`StorageBuffers` 4、`maxImageDimension2D` 4096、`maxImageArrayLayers` 256） | `limits.adoc` の Required Limits | §3.7（LDS 16 KiB・constant 256 word）、他は firmware と compiler | p030 では扱わない（p010・p018・p019 が §3.7 の表で確かめる） | — |
| `multiViewport`・`sampleRateShading`・`samplerAnisotropy` | 任意 | 無し | 0（sampleRateShading は U43） | Future Work |
| `alphaToOne` | 任意 | — | 1（p027） | — |

### 16.2 必須の format の表（optimalTilingFeatures と bufferFeatures の列）と v1

列: **S** = SAMPLED_IMAGE（と BLIT_SRC）、**F** = SAMPLED_IMAGE_FILTER_LINEAR、**St** = STORAGE_IMAGE（**A** = その ATOMIC）、**C** = COLOR_ATTACHMENT（と BLIT_DST）、**B** = COLOR_ATTACHMENT_BLEND、**D** = DEPTH_STENCIL_ATTACHMENT、**V** = VERTEX_BUFFER、**U** = UNIFORM_TEXEL_BUFFER、**T** = STORAGE_TEXEL_BUFFER（**TA** = その ATOMIC）。表は Vulkan の表の 1.0 の必須の印（{sym1}）だけを写した（{sym3} の `shaderStorageImageExtendedFormats` の行と 1.3 以降の行は外した）。数は `VkFormat` の値（`vk.xml`、事実の値）。

| VkFormat（値） | S | F | St | C | B | D | V | U | T | v1 の担当 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B4G4R4A4_UNORM_PACK16（3） | ✓ | ✓ | | | | | | | | TU f32 |
| R5G6B5_UNORM_PACK16（4） | ✓ | ✓ | | ✓ | ✓ | | | | | TU f32（item 11）、ROP u8 |
| A1R5G5B5_UNORM_PACK16（8） | ✓ | ✓ | | ✓ | ✓ | | | | | TU f32、ROP u8 |
| R8_UNORM（9）・R8G8_UNORM（16） | ✓ | ✓ | | ✓ | ✓ | | ✓ | ✓ | | TU u8、ROP u8、VF |
| R8_SNORM（10）・R8G8_SNORM（17） | ✓ | ✓ | | | | | ✓ | ✓ | | TU f32、VF |
| R8_UINT/SINT（13/14）・R8G8_UINT/SINT（20/21） | ✓ | | | ✓ | | | ✓ | ✓ | | TU int、ROP int、VF |
| R8G8B8A8_UNORM（37） | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | ✓ | TU u8、ROP u8、VF、St/T は compiler |
| A8B8G8R8_UNORM_PACK32（51） | ✓ | ✓ | | ✓ | ✓ | | ✓ | ✓ | ✓ | 同上（memory は 37 と同じ） |
| R8G8B8A8_SNORM（38） | ✓ | ✓ | ✓ | | | | ✓ | ✓ | ✓ | TU f32、VF |
| A8B8G8R8_SNORM_PACK32（52） | ✓ | ✓ | | | | | ✓ | ✓ | ✓ | 同上 |
| R8G8B8A8_UINT/SINT（41/42） | ✓ | | ✓ | ✓ | | | ✓ | ✓ | ✓ | TU int、ROP int、VF |
| A8B8G8R8_UINT/SINT_PACK32（55/56） | ✓ | | | ✓ | | | ✓ | ✓ | ✓ | 同上 |
| R8G8B8A8_SRGB（43）・B8G8R8A8_SRGB（50）・A8B8G8R8_SRGB（57） | ✓ | ✓ | | ✓ | ✓ | | | | | TU f32（LUT）、ROP f32 |
| B8G8R8A8_UNORM（44） | ✓ | ✓ | | ✓ | ✓ | | ✓ | ✓ | | TU u8、ROP u8、VF |
| A2B10G10R10_UNORM_PACK32（64） | ✓ | ✓ | | ✓ | ✓ | | ✓ | ✓ | | TU f32、ROP f32、VF |
| A2B10G10R10_UINT_PACK32（68） | ✓ | | | ✓ | | | | ✓ | | TU int、ROP int |
| R16_UNORM/SNORM（70/71）・R16G16（77/78）・R16G16B16A16（91/92） | | | | | | | ✓ | | | VF |
| R16_UINT/SINT（74/75）・R16G16（81/82） | ✓ | | | ✓ | | | ✓ | ✓ | | TU int、ROP int、VF |
| R16_SFLOAT（76）・R16G16_SFLOAT（83） | ✓ | ✓ | | ✓ | ✓ | | ✓ | ✓ | | TU f32、ROP f32、VF |
| R16G16B16A16_UINT/SINT（95/96） | ✓ | | ✓ | ✓ | | | ✓ | ✓ | ✓ | TU int、ROP int、VF |
| R16G16B16A16_SFLOAT（97） | ✓ | ✓ | ✓ | ✓ | ✓ | | ✓ | ✓ | ✓ | TU f32（8 byte の texel）、ROP f32、VF |
| R32_UINT/SINT（98/99） | ✓ | | ✓ + A | ✓ | | | ✓ | ✓ | ✓ + TA | TU int、ROP int、VF |
| R32_SFLOAT（100） | ✓ | | ✓ | ✓ | | | ✓ | ✓ | ✓ | TU f32、ROP f32（blend 無し）、VF |
| R32G32_*（101〜103）・R32G32B32A32_*（107〜109） | ✓ | | ✓ | ✓ | | | ✓ | ✓ | ✓ | TU（8・16 byte）、ROP、VF |
| R32G32B32_*（104〜106） | | | | | | | ✓ | | | VF |
| B10G11R11_UFLOAT_PACK32（122） | ✓ | ✓ | | | | | | ✓ | | TU f32 |
| E5B9G9R9_UFLOAT_PACK32（123） | ✓ | ✓ | | | | | | | | TU f32 |
| D16_UNORM（124） | ✓ | | | | | ✓ | | | | TU depth、ROP |
| X8_D24_UNORM_PACK32（125） | （任意） | | | | | ✓（片方） | | | | TU depth、ROP |
| D32_SFLOAT（126） | ✓ | | | | | ✓（片方） | | | | TU depth、ROP |
| D24_UNORM_S8_UINT（129） | （任意） | | | | | ✓（片方） | | | | ROP、TU depth/stencil の aspect（任意、item 3） |
| ETC2_R8G8B8・R8G8B8A1・R8G8B8A8 の UNORM・SRGB（147〜152）、EAC_R11・R11G11 の UNORM・SNORM（153〜156） | ✓ | ✓ | | | | | | | | **後の Phase**（1 組の必須。ユーザーの決定で p028 の後、§16.11a、U58） |
| BC（131〜146）・ASTC（157〜184） | （他の組） | | | | | | | | | 0 |

- **v1 は表の必須をちょうど満たし、任意を少しだけ足す**: D24S8 と X8_D24 の SAMPLED（shadow map で D24S8 を sample する道。stencil の aspect は item 3）、D24S8 の DS は stencil 付き、D32F の DS。D32_SFLOAT_S8_UINT は出さない。整数の C の format も 4x を出す（U54。`capabilities.adoc` の SAMPLED の規則が整数の color の format にも sampledImageColorSampleCounts を当てると読めるため。ROP は format に依らず、resolve は SAMPLE0）。
- **resolve の code**（Q1 の依頼。p027 の BLT の RESOLVE、`BLT_RESOLVE`[7:4]）: 4x を出す C の format ごとに次の code と画素の大きさ（§16.12）: R8G8B8A8・B8G8R8A8・A8B8G8R8・R8・R8G8 の UNORM = 0 UNORM8（ps 8・16・32 bit。8 bit は p030 で足す）、R5G6B5 = 1 UNORM565、**A1R5G5B5 = 7 UNORM1555（新）**、**sRGB の 3 つ = 3 SRGB8_A8（Amaterrace で実装）**、**A2B10G10R10_UNORM = 6 UNORM2_10_10_10（新）**、**R16・R16G16・R16G16B16A16_SFLOAT = 4 SFLOAT16（ps 16・32・64 bit）**、**R32・R32G32・R32G32B32A32_SFLOAT = 5 SFLOAT32（ps 32・64・128 bit）**、整数の全部 = 2 SAMPLE0（ps 8〜128 bit）。p027 の「Amaterrace: 0-2; 3-5 are refused」は p030 の S10 で 0〜7 の全部に変わる。
- **St・T・TA の列（storage）と U の列**は TU・ROP の format の土台（§16.4）を使うが、SU の道は compiler（§16.14）。
- **MS の sample の数**（`capabilities.adoc`）:「If usage includes COLOR_ATTACHMENT_BIT and format is a floating- or fixed-point color format, a superset of framebufferColorSampleCounts」→ **C の列の float・UNORM の全部（R32G32B32A32_SFLOAT も）が 4x を要る**。p027 の「quad の 1 行の全 sample が 1 本の line に入る」は 16 byte の format の 4x（2 px × 4 sample × 16 byte = 128 byte）で成り立たない → §16.7 の wb が 1 行を複数の line で回す（**p027 との食い違い 1**）。

### 16.3 決めた事の要約

1. **format の番号 = VkFormat の値**（8 bit。U47）。STATE の新しい field（ROP の RT_FORMATS、TU の TEX_FORMAT、VF の ATTR_DST[31:24]）は VkFormat を書き、**0 は今の field（RT_FORMAT・TEX_IMAGE[7:4]・ATTR_DESC[19:16]）を使う**（既存の試験と firmware 無しの道を壊さない）。
2. **format の変換は 1 つの Verilog の関数の束**（`include/atg_fmt_info.vh`・`atg_fmt_unpack.vh`・`atg_fmt_pack.vh`）と sRGB の表（`include/atg_srgb.vh`、tool で生成）を VF・TU・ROP が共有。driver は **FMT capability（GHCI の新しい extended capability id 10）**で format ごとの VkFormatFeatureFlags を hardware から読む（U48）。
3. **ROP**: stencil（front/back、8 op、mask、reference）、D16、depth bounds、depth clamp（clip と bias は RX）、MRT 4（quad を attachment ごとの **beat** で運ぶ）、全部の C の format の書き込み、BLEND の format の blend（8 bit の今の道 + **fp32 の新しい道**）、fp32 の blend constant、RT ごとの BLEND と WRITE_MASK、occlusion の counter。
4. **RX**: primitive の種類（point・line・triangle）を VF から受ける。point = size 1 の正方形、line = 幅 1 の parallelogram（どちらも 2 つの sub-triangle を同じ plane で）、PointCoord、viewport の矩形での bbox、**常に w ≥ ε、DEPTH_CLIP の時に near と far の geometric な clip**、guard band の x・y の clip（line も）、depth bias の計算、rasterizerDiscard。
4a. **CP の待ち**: RX と ROP の範囲の SET_REG の待ちの hazard（§16.8a）は p027 で直す（Q1）。p030 はそれを前提にする。
5. **VF**: 列 V の全部の format、robust の ATTR_LIMIT。
6. **TU**: 新しい slot の word +6 TEX_FORMAT（VkFormat、stencil の aspect、component swizzle）、1・2・8・16 byte の texel、**fp32 の filter の道**（RGBA8・BGRA8・R8・RG8 の UNORM 以外の全部の format と sRGB）、D16、integer の format。ETC2・EAC は後の Phase（§16.11a）。
7. **BLT**: 32 bit の pixel の KEEP の byte mask（D24S8 の depth だけ・stencil だけの clear と copy）、画素 8・64・128 bit、RESOLVE の平均の code 3〜7（p027 の engine に）。
8. **SU**: export の COLOR1〜3（0x110 + 16(k − 1) + c）、exp の buffer と drain の分割、`ex_aux`（p027 の `ex_ms` を広げる）。
9. **CP**: µop 14 `QUERY`（occlusion の counter を memory へ）、FMT capability。
10. **input attachment・storage image・texel buffer**は RTL を足さず compiler と firmware の道（U50・U51）。interface の表の kind 9〜11 だけ GHCI に足す。

### 16.4 format の共通の土台

- **番号**: STATE の format の field は `VkFormat` の値（Vulkan 1.0 の core は 0〜184 で 8 bit に入る）。GHCI は既に VkCompareOp・VkBlendFactor・VkBlendOp・VkBorderColor の番号を使っているので同じ流儀。hardware は対応しない番号を「format 無し」と読む（TU は (0, 0, 0, 1)、ROP は書かない、VF は (0, 0, 0, 1)）。driver は FMT capability で対応を知るので、対応しない番号を書かない。
- **`atg_fmt_info(fmt)`**（function、≈150 行の case）: {valid、texel の byte の log2（0〜4: 1・2・4・8・16）、component の数、数の型（UNORM・SNORM・UINT・SINT・SFLOAT・SRGB・UFLOAT_B10G11R11・UFLOAT_E5B9G9R9）、channel の並び（bit の位置と幅 × 4）、depth/stencil の印}。FMT capability の feature の ROM（§16.15）もこの表から作る（同じ case の別の出力）ので、hardware の対応と driver の報告が食い違わない。ROM は **固定機能の列（S・F・C・B・D・V と BLIT_SRC/DST）だけ**を答え、parameter（`MS4`、§16.19 の `FMT_FULL`）で作る。compiler と firmware の道の列（St・A・T・TA、U の一部）は driver が CAPS[17]（firmware）と ISA から足す（review 13）。ROM と Vulkan の必須の表を照合する試験は §16.20。
- **`atg_fmt_unpack(raw[127:0], fmt)`** → {c0..c3（fp32 か integer の bit）、is_int}。規則（Vulkan の「Conversion from Normalized Fixed-Point to Floating-Point」の式、値は事実）: UNORM = c / (2^b − 1)、SNORM = max(c / (2^(b−1) − 1), −1)、どちらも fp32 へ RNE で正しく丸める（TU の 8 bit・24 bit と同じ「繰り返しの bit の掛け算」の形を b = 1・2・4・5・6・8・10・16 に）。SFLOAT16 → fp32 は正確（denormal も正規の fp32 に、NaN は 0x7FC00000。`atg_vf_conv` と同じ）。UFLOAT 11・10 bit と E5B9G9R9 は正確に fp32 へ。UINT/SINT は 0 拡張/符号拡張。無い component は (0, 0, 0, 1)（float は 1.0、integer は 1）。sRGB は RGB を `atg_srgb_dec`（256 entry → fp32、正しく丸めた値を tool が生成）、A は UNORM。
- **`atg_fmt_pack(c0..c3, fmt, wm[3:0])`** → {raw[127:0], keep[127:0]（WRITE_MASK で書かない bit）}。NaN と負は UNORM と sRGB で 0（clamp の前、review 28）。UNORM = RNE(clamp01(f) × (2^b − 1))、SFLOAT16 = RNE（overflow は ±inf、NaN は 0x7E00、fp16 の denormal は正しく作る）、UFLOAT は v1 の C に無いので無し、integer = 下位の bit（範囲の外は Vulkan で未定義 [記憶]）。**sRGB の encode** は表の検索（下の `atg_fmt_srgbenc`）。
- **`atg_fmt_srgbenc`**（module、≈90 行、FSM 1 つ）: linear の fp32 x → 8 bit の code = 「閾値 T_c = EOTF((c + 0.5)/255)（c = 0〜254）の x 以下の数」を **255 entry の閾値の ROM の 2 分探索**（8 cycle/channel。正の fp32 の比較は整数の比較）。sRGB 空間で最も近い code（正しく丸めた結果）になる。ROM（255 × 32 bit = BRAM18 1 つか LUTROM）と decode の表は `tools/srgb-tables.py` が sRGB の式（Khronos Data Format の定義の式。値の計算は自前、表は写さない）から有理数の精度で作る。
- **置き場所**: 関数の束は `include/`（`atg_depth.vh` と同じ形）。大きさ: unpack・pack は format の case の組み合わせで、instance ごとに ≈0.6〜1.0k LUT（推定）。instance は VF 1、TU の f32 の道 1、ROP の dst の unpack 1 と pack 1（wb の中）。

### 16.5 ROP: stencil（item 1）

- **STATE**（ROP の範囲、今の 3 word の意味を決める。今は未実装で誰も使っていない）:
  - `DEPTH`（0x076）: [0] depth test、[1] depth write、[4:2] compareOp、[5] D24S8、[6] D32F、**[7] D16（新）**、**[8] stencil test（新）**、**[9] depth bounds test（新）**。format の bit は 1 つだけ立てる（2 つ以上は format 無しとして test しない）。X8_D24 は D24S8 として書き、stencil の test を立てず writeMask を 0 にする（stencil の byte は保たれる）。
  - `STENCIL_FRONT`（0x077）・`STENCIL_BACK`（0x079）: [7:0] reference、[15:8] compareMask、[23:16] writeMask、[26:24] compareOp（VkCompareOp）。
  - `STENCIL_OPS`（0x078）: [2:0] front failOp、[5:3] front passOp、[8:6] front depthFailOp、[18:16] back failOp、[21:19] back passOp、[24:22] back depthFailOp（VkStencilOp の 0〜7: KEEP、ZERO、REPLACE、INCREMENT_AND_CLAMP、DECREMENT_AND_CLAMP、INVERT、INCREMENT_AND_WRAP、DECREMENT_AND_WRAP）。
- **facing**: warp の front（`fl_info[48]` → exp → `ex_aux.front`、§16.13）。point・line は front（Vulkan の「or any other primitives」）。direct の道（DRAW_RAW・DEBUG_COLOR）も front。
- **`atg_rop_dtest`（新、≈220 行、組み合わせだけ、FSM 無し、≈22 port）**: 1 つの (lane, sample) の entry の判定。入力: z_f（fp32）、stored の word（32 bit）と line の中の byte の位置（D16 は 2 byte）、DEPTH・STENCIL_*・DEPTH_BOUNDS_*（§16.6）、front、entry が covered か。出力: pass（coverage を残す）、new の word、byte enable（4 bit）。順は Vulkan の fragment の操作の順（depth bounds → stencil → depth）:
  1. depth bounds（DEPTH[9]、format が有る時）: stored の z_a を fp32 にして（D16・D24 は UNORM の正しい丸め、`atg_depth.vh` に `atg_depth_f16`・`atg_depth_f24` を足す）[MIN, MAX] の外なら pass = 0、stencil も depth も書かない（Vulkan は bounds の後に stencil の op を書かない: 「Samples with depth attachment values outside of the depth bounds will have their coverage set to 0」）。
  2. stencil（DEPTH[8] かつ D24S8）: s_a = stored[31:24]、st = cmp(ref & cmask, s_a & cmask)。失敗なら new_s = op(failOp)、pass = 0。成功なら depth の結果 d で new_s = op(d ? passOp : depthFailOp)、pass = d。書く値 = (s_a & ~wmask) | (new_s & wmask)。byte 3 の enable = (書く値 ≠ s_a)。INCREMENT/DECREMENT は 8 bit の clamp と wrap（「the stencil bits are considered as an unsigned integer」）。
  3. depth（DEPTH[0]）: 今の比較（`atg_depth_pass`）に D16（`atg_depth_u16`、RNE と飽和）を足す。書く: DEPTH[1] かつ pass（stencil も通った時）。
  - stencil の test が無い時（DEPTH[8] = 0 か format に stencil が無い）は stencil は常に通り、書かない（Vulkan の「If there is no stencil attachment」の扱いと同じ）。
- **`atg_rop_ds` の変更**: (lane, sample) の回し方（p027 の 2 か 8 entry）はそのままで、entry の判定を `atg_rop_dtest` に移す。D16 の時の address = 行の中の (x·S + s)·2。書き込みの line の byte enable を entry の出力から合わせる。1 quad の行に書く entry が 1 つでもあれば line を書く（今と同じ）。
- **MS**: stencil は sample ごと（p027 の sample-interleaved の配置の D24S8 の word の byte 3）。`framebufferStencilSampleCounts` 1|4 を満たす。

### 16.6 ROP: depth の format（D16）、depth bounds、depth clamp（`atg_rop_ms`）。depth の範囲の clip は RX（§16.9）

- **D16（item 2）**: DEPTH[7]。2 byte の pixel。D16 は stencil 無し。
- **depth bounds**: `DEPTH_BOUNDS_MIN`（0x08B）・`DEPTH_BOUNDS_MAX`（0x08C）、fp32。§16.5 の 1。
- **depth の範囲の clip は RX の clip の geometric な平面で**（§16.9。版 6 の最初は ROP、review 1 の 8 で RX の frag の sample ごと、review 2 の H1・H2 で geometric に。ROP は clip しない）。
- **ROP の depth の流れ**（p027 の `atg_rop_ms` の z_s の式を置き換える。**p027 との食い違い 2**: p027 は「z_s = zexp ? 出した depth : clamp01(z_c + d_s)」）。sample s of lane l:
  1. z_r = z_c + d_s（4x、p027 の fadd）、1x は z_r = z_c。z_c = r3（RX の plane は bias o を含む、§16.9。`DEPTH_CLAMP`[1] = 1 の時は r3 を clamp しない: U53）。
  2. z_f = zexp ? 出した depth（FragDepth）: z_r。
  3. **depth clamp**（`DEPTH_CLAMP`[0]）: z_f = clamp(z_f, zmin, zmax)（zmin = min(n, f)、zmax = max(n, f)、n = VIEWPORT z_off、f = z_off + z_scale。Vulkan の「z_f is clamped to [z_min, z_max]」）。
  4. **legacy**（`DEPTH_CLAMP`[1] = 0）: p027 のまま clamp01（今の試験と DRAW_RAW の direct の道を変えない）。
  5. UNORM の attachment（D16・D24）は変換で [0, 1] に飽和（今の `atg_depth_u24` と同じ）。D32F は z_f のまま。
- **ROP が読む RX の範囲の STATE**: VIEWPORT[4]・[5]、DEPTH_CLAMP。RX の範囲の SET_REG は §16.8a の待ち（p027 の修正）で draw の途中に変わらない。zmin・zmax は STATE の書き込みの時に `atg_rop_ms` が fadd 1 回で作る（register 2 つ）。
- `atg_rop_ms` の追加: clamp の mux と比較 2 つ、beat（§16.7）。≈220 → ≈260 行。

### 16.7 ROP: color attachment 4 つ（MRT、item 4）・format（item 5）・blend

- **beat**: SU の exp は quad を **attachment ごとの beat** で ROP に出す。warp ごとの `rtw[3:0]`（どれかの lane が attachment k を export した）の k の昇順に 1 beat ずつ、色は今の `ex_color`（4 lane × RGBA × fp32 = 512 bit）のまま。color を 1 つも出さない warp（depth だけ、p027 の `exp 0x105` だけ）は `nocol` の beat を 1 つ。`ex_aux` に {rt[1:0]、qfirst、qlast、nocol} を足す（§16.13）。`ex_last` は warp の最後の quad の最後の beat。
  - **選んだ理由**: 4 attachment × 512 bit = 2048 bit の bus を order → ms → ds → wb に通すと FF と mux が 4 倍。beat なら幅は今のまま、MRT を使わない draw は 1 beat で今と同じ速さ。
- **`atg_rop_order`**: beat をそのまま通す（連番は ex_last で退く、今と同じ）。`q_aux` を広げる。
- **`atg_rop_ms`**: qfirst の beat で coverage・z・clip を計算し（§16.6、p027 の a2c は COLOR0 の alpha = 「Location 0, Index 0」なので rt = 0 の beat を使う。rt 0 を export しない warp の a2c の alpha は未定義（Vulkan と同じ）として最初の beat の alpha を使う）、smask と z を register に持ち、同じ quad の後続の beat に同じ smask を付ける。alpha to one（p027）は**全部の beat**（Vulkan: 「each alpha value is replaced by the maximum representable alpha value」）。
- **`atg_rop_ds`**: qfirst の beat で test と書き込み（§16.5）をし合格の mask（p027 の `d_smask`）を持ち、後続の beat は memory を触らず同じ mask で `wb` に渡す。nocol の beat は test と書き込みの後に wb へ渡さない（occlusion は数える、§16.8）。
- **`atg_rop_wb`（RT ごとの state と format）**: beat の rt で RT k の {BASE、STRIDE、format、BLEND、WRITE_MASK} を選ぶ。STATE:
  - RT0 = 今の RT_BASE（0x070）・RT_STRIDE（0x071）・RT_FORMAT（0x072）。RT1〜3 = **RT1_BASE/STRIDE（0x07E/0x07F）、RT2（0x080/0x081）、RT3（0x082/0x083）**。`RT_SIZE`（0x073）は共有（framebuffer の大きさ）。
  - **`RT_FORMATS`（0x07D）**: [7:0] RT0 の VkFormat（0 = RT_FORMAT[1:0] の今の 3 種）、[15:8] RT1、[23:16] RT2、[31:24] RT3（0 = attachment 無し: その beat を捨てる）。
  - **`WRITE_MASK`（0x07C）**: [3:0] RT0（今と同じ）、[7:4] RT1、[11:8] RT2、[15:12] RT3。0 の RT は書かず、line も読まない。
  - **`BLEND`（0x07A）** は RT0、**BLEND1〜3（0x084〜0x086）**（independentBlend）。bit は今の BLEND と同じ。integer の format と blend の無い format（R32F・RG32F・RGBA32F）では enable を無視（Vulkan は blend を行わない）。
  - **`BLEND_CONST_R/G/B/A`（0x087〜0x08A）**、fp32。`ROP_CTRL`（0x08D）[1] = 1 で使い、0 なら今の 0x07B の RGBA8（U52 を「0 は以前の動作」に合わせた、review 12）。firmware は [1] = 1。
- **pixel の大きさと line**: ps = 1・2・4・8・16 byte。quad の 1 行の byte = 2·S·ps（4x の RGBA32F で 128）、line の数 L = ceil(2·S·ps / LINE_BYTES)（1、2 か 4）。**揃えの規則**（review 11）: RT_BASE・RT1〜3_BASE・DS_BASE は 64 byte の倍数、RT_STRIDE・RT1〜3_STRIDE・DS_STRIDE は **2·S·ps の倍数**（p027 の RESOLVE の src の規則「stride a multiple of 2 x S x ps bytes」と同じ、review 2 の M2。2·S·ps ≤ 128 なので、x が偶数の quad の行の始まりは min(2·S·ps, 64) の倍数で、行はちょうど L 本の line に入る）。driver は `VkMemoryRequirements::alignment` 64 と row pitch をこの規則で作る（p019）。wb は跨ぎを TB の assert で検査する。wb は 1 行を L 本の line に分けて回す（line ごとに find/allocate → (読み) → blend → merge）。2 本の line の write-combine の buffer は今のまま（1 本 = 1 行の 1 部分）。
- **blend の 2 つの道**:
  - **u8 の道**（今の `atg_rop_blend`、4 pixel/cycle）: B8G8R8A8・R8G8B8A8・A8B8G8R8（= R8G8B8A8 の memory）・R8・R8G8 の UNORM と R5G6B5・A1R5G5B5（8 bit の中間で blend して 5/6/1 bit に詰める。今の 565 と同じ）。alpha の無い format（R8・R8G8・R5G6B5）の dst の alpha は 1（DST_ALPHA の factor = 1、Vulkan の「missing components」の規則、review 28）。blend constant は STATE の書き込みの時に clamp01 と RNE で 8 bit にする。
  - **f32 の道（新 `atg_rop_fblend`、≈300 行、FSM 1 つ、≈20 port）**: sRGB（dst を `atg_srgb_dec` で linear に、結果を `atg_fmt_srgbenc` で encode）、A2B10G10R10_UNORM、R16/RG16/RGBA16_SFLOAT。channel ごとに s·Fs と d·Fd（fmul 2 回）と op（fadd/fsub、MIN/MAX は比較、Vulkan の「the blend factors are ignored」）を **fmul 1 本・fadd 1 本の pipeline**で 1 channel/cycle（`atg_rx_fmul`・`atg_rx_fadd` を instance、同じ丸め）。UNORM の target は src・dst・factor を [0, 1] に clamp（Vulkan の fixed-point の規則）。4 pixel × 4 channel ≈ 16 + 12 cycle/beat（推定）。
  - blend しない書き込み（integer、R32F 系、blend 無効）は pack だけ（`atg_fmt_pack`）。
- **write mask**: u8 の道は今の通り、f32 の道と pack は `keep` の bit で旧値を残す（packed の format は bit の単位）。
- **`atg_rop_wb` の分割**（p027 の後 ≈330 行 + 上 → 400 を超える）: **`atg_rop_wb`**（line の buffer、AMB、beat と行と line の順序、≈300）と **`atg_rop_wpix`（新、≈250、FSM 無し）**（line の中の pixel の位置、RT の state の選択、dst の unpack、u8/f32 の道の選択と結果の merge）。
- **S8 の実装で決めた事**（2026-10-25 P1、amaterrace-gpu の spec §10 にも）: (1) `atg_rop_fblend` は `atg_rop_wpix` の子（wb の port を 40 以下に保つため。wb は 32 port、wpix 35）。(2) row が 1 本の line に入る時（2·S·ps ≤ LINE_BYTES）は今の通り 2 行の line を先に揃えて sample ごとの pass、入らない時（4x で 8・16 byte の画素）は行ごと・line ごとに 1 pass（slot = line の中の E = LINE_BYTES/ps 個の (画素, sample)）。(3) 読まずに置いた line は読みの要らない beat にだけ当たる（`erd`）。(4) nocol の beat は `atg_rop_ds` が wb に渡し wb が捨てる（occlusion は `atg_rop` が qfirst の beat の d_smask で数える。§16.7 の「wb へ渡さない」から変えた、結果は同じ）。(5) 1 つの warp の beat は全部同じ `ex_mask`（ある lane が出さなかった attachment の値は未定義、GHCI §12.12 に一文）。(6) `atg_su_exp_drain` は `atg_su_exp` の子（`atg_su` の結線を変えない、exp は 39 port のまま）、warp ごとに FIRST の 1 cycle。(7) pack の道（integer・R32F 系）の結果は `atg_fmt_pack` の keep で旧値と bit の単位で merge。

### 16.8 occlusion query（item 7）

- **`atg_rop_occ`（新、≈60 行、FSM 無し、≈10 port）**: 40 bit の counter。`ROP_CTRL`（0x08D）[0] が 1 の間、`atg_rop_ds` の qfirst の beat の合格の sample の数（p027 の `d_smask` の popcount、1x は lane の数）を足す。Vulkan の「increments by one for each sample with a coverage value of 1 in each fragment that survives all the per-fragment tests, including scissor, sample mask, alpha to coverage, stencil, and depth tests」（scissor・sample mask・a2c・depth の範囲の clip は RX と ms で落ちているので ds の後の mask で数えればよい）。depth・stencil の attachment が無くても数える（ds は test 無しで通す）。nocol の beat も数える。attachment の数に依らず quad ごとに 1 回（qfirst）。
- **`ROP_CTRL`（0x08D）**: [0] occlusion の count、[1] blend constant は fp32 の BLEND_CONST_R〜A（0: 今の 0x07B の RGBA8。U52 を「0 = 以前の動作」の約束に合わせた）。
- **µop 14 `QUERY`**（class 0、payload 1: addr）: 先行の全部の仕事の完了（RESULT と同じ待ち: 全 block idle と fence unit の書き込みの応答）の後、counter を {lo, hi} の 2 word で addr（8 byte 揃え）に書く（fence unit の RESULT の道 `f_op` 1 を status = lo、aux = hi で使う）。flags[0] = 書かずに 0 にする（begin 用。**待たない**: counter は `ROP_CTRL`[0] = 0 の間は動かないので、begin の前に先行の draw を待つ必要が無い。review 35）、flags[1] = 書いた後に 0 にする。`atg_cp_seq` に `occ_count[39:0]`（入力）と `occ_clear`（出力）の 2 port（`atg_cp_seq` は §16.8a で分割する）。
- **firmware**（p018）: `vkCmdBeginQuery` = `QUERY`(flags 1) → `SET_REG ROP_CTRL[0] = 1`。`vkCmdEndQuery` = **`QUERY`(addr = query の slot) を先に**（全 block の idle を待つ = 先行の draw の sample が全部入る）→ `SET_REG ROP_CTRL[0] = 0` → `RESULT`（availability の word）。`vkCmdResetQueryPool` = BLT の FILL 0、`vkCmdCopyQueryPoolResults` = firmware が `WAIT_IDLE` の後に DMA で写す（32/64 bit、WITH_AVAILABILITY、PARTIAL、WAIT の flag を firmware が解く）。`vkGetQueryPoolResults` は driver（D、host の memory を読む）。query pool の memory の配置（slot = {u64 結果, u32 available, u32 0}）は `ghci_layout.h`（p019）。occlusion の query は 1 つの command buffer で同時に 1 つ（Vulkan の active な query の規則）なので counter は 1 本。
- **firmware の内蔵の draw**（blit、clear の draw、resolve の draw を使う時）の前後で `ROP_CTRL`[0] を 0 にして戻す（fragops の Sample Counting が数えるのは draw の command の sample。review 18）。BLT は ROP を通らないので数えない。
- `occlusionQueryPrecise` = 1、`inheritedQueries` = 0。

### 16.8a CP: RX と ROP の範囲の SET_REG の待ち（review 1 の 2 で見つけた hazard。**p027 で直す: p030 の前提**）

- **今の規則**（`atg_cp_seq.v` 212〜215 行）: BLT の範囲は BLT、VF の範囲（0x020〜0x04F と 0x1C0〜0x1CF）は VF、RX の範囲は RX か ROP、ROP の範囲は ROP、TU の範囲は TU か SU か RX の busy を待ち、program の範囲（0x190〜0x1BF）は待たない。DRAW は VF の busy を待ってから kick し（263 行）、その後は待たない。LOAD_CONST は SU だけを待つ（226・265 行）。
- **hazard**: ROP の busy は「発行した連番が全部退いていない」（`atg_rop_order.v` 68 行）、連番は RX の scan/frag が warp ごとに採る。DRAW の直後、前の draw の primitive が VF・SU（vertex の warp）・RX の clip/setup に居て連番を得る前は、ROP の範囲の SET_REG（次の draw の BLEND・DEPTH・STENCIL・RT_*）が通り、前の draw の fragment が次の draw の ROP の state で処理される。RX の範囲も同じ。review 2 の H3: **TU の範囲（VF を待たない）、program の範囲（`atg_su_sched.v` 100〜101 行は VS_BASE・FS_BASE を STATE の書き込みで直に更新し warp の開始で使う）、LOAD_CONST も同じ種類**。
- **2026-10-25 Q1 の決定**: 「`atg_cp_seq` の RX・ROP の範囲の SET_REG の待ちの直し（§16.8a）は p027 の P2 の範囲に移した。p030 の S5 からは外し、§16.8a は『p027 で直す（前提）』と書き換えてください。」→ p030 は、p027 が merge した待ちの規則（RX・ROP の範囲の SET_REG は前の draw の primitive が VF・SU・RX・ROP を抜けるまで待つ）を前提にする。**TU・program の範囲・LOAD_CONST と 0x1D0〜0x1DF（ATTR_LIMIT、review 1 の 6）も同じ修正に入れるよう Q1 に伝えた**（p030 の S2 は ATTR_LIMIT を足すので、0x1C0〜0x1DF を VF 待ちにする 1 行は p027 の修正に無ければ S2 で足す）。
- p030 の試験の `atg_top_core.backtoback`（§16.20 の scene (13)）はこの前提の確認として残す（p027 の修正の後に流す）。
- **代価**: draw ごとに RX・ROP の state を変える列では、前の draw が ROP を退くまで次の draw の state を書けない。速さが要る時は state を 2 面にし draw ごとに版を持つ（p025 の候補、Future Work）。
- `atg_cp_seq` の分割（今 409 行）も p027 の修正と一緒に行うかは Q1 が決める。p030 の S5 は `QUERY` の 2 port（38 → 40）を足すので、分割の後の module に足す（分割が無ければ S5 で `atg_cp_seq_wait` に分ける）。

### 16.9 RX: point と line（item 6）・clip（w・near・far・guard band）・viewport の矩形・depth bias

- **primitive の種類**: VF が `prim_vtx` を 24 → **26 bit**（[25:24] kind: 0 point、1 line、2 triangle）にして渡す（port の数は変わらない。`atg_vf_asm` は topology を知っている）。**選んだ理由**: RX が TOPOLOGY（VF の範囲）を snoop すると、VF の範囲の SET_REG は RX の busy を待たないので、次の draw の TOPOLOGY で前の draw の primitive を読み違える。kind は `cl_tri`（700 → 702 bit）で setup に運ぶ。line の頂点 0・1 は primitive の頂点 0・1（PROVOKING が last の時 VF は (b, a, a) に並べ替える。`atg_vf_asm.md`）。
- **`atg_rx_clip`**（平面は順に、guard band の中で w > 0 の三角形は判定だけで今と同じ cycle 数）:
  1. **w ≥ ε を常に**（ε = 2^−16。review 3: z ≥ 0 だけでは z_c > 0 かつ w_c < 0 の頂点（reversed-Z の投影のカメラの後ろ）が通り、除算で裏返る。clip volume は「z_m ≤ z_c ≤ w_c」で z ≥ 0 と z ≤ w が揃って w ≥ 0 になる）。
  2. **z ≥ 0**（near）と **3. z ≤ w**（far）。`DEPTH_CLAMP`[1] = 1（DEPTH_CLIP）かつ [0] = 0 の時だけ（Vulkan の「Depth clipping is disabled when depthClampEnable is TRUE」）。[1] = 0 は今の動作（near z ≥ 0 だけ、far は clamp）。**far も geometric に切る**（review 2 の H1・H2: 最初の改訂の「frag で sample ごとに試す」は、(1) z が分かる時には quad が warp に入っているので被覆を後から消すと `atg_su_exp` の drain（`dlast` は「次の quad の被覆が 0 なら終わり」）が後ろの quad を落とし、(2) minDepth = maxDepth（z_scale = 0）の viewport では [n, n] を必ず通って far が効かない。geometric な clip はどちらも起きず、副作用の問題（review 1 の 8）も無い）。
  4. **guard band の x・y**（頂点の画面の座標が guard band（16.8 の ±(2^22 − 1)/256 px）を出る primitive だけ）: 平面 x_off·w + x_scale·x_c ≤ 16383·w と x_off·w + x_scale·x_c ≥ −16383·w（除算無し、scale の符号に依らない。review 2 の L12）、y も同じ。clip が VIEWPORT から作る。
  - triangle: Sutherland–Hodgman で多角形（最大 3 + 7 = 10 頂点）、fan で最大 8 三角形。重みは元の 3 頂点に対して（今の near の clip と同じ形）。
  - **line**: 同じ平面を v0–v1 の線分の t の区間で切り（guard band も、review 9）、**常に 1 つ**の primitive (a', b', b') を出す（三角形の形の clip は (a, b, b) から退化した 2 つ目を作り得るので使わない）。
  - **point**: v0 が平面 1〜3 の外なら捨てる（x・y の外は捨てない: 正方形は viewport の矩形で切る）。
  - **ε**（R36）: w ≥ ε の ε = 2^−16 は絶対値で、clip 座標を一様に小さくした（例 10^−6 倍）頂点の全体を切る。Vulkan の結果は一様の倍率に依らないので規格からの小さな逸脱として記録する（相対の ε は平面が線形でなくなる）。
  - **last-use の flag**（review 10）: 1 つの primitive から出る全部（fan の三角形、line・point の 2 つの sub-triangle（setup が作る））のうち **最後の 1 つだけ**が flag を持ち、他は 0。全部 clip された primitive は今の「flag だけの空の三角形」の道。spec の §7 と TB で検査する。
  - `atg_rx_clip` は 287 行 + 上で 400 を超えるので **`atg_rx_clip`（入力・平面の順序・出力の FSM）と `atg_rx_cpoly`（新、多角形の buffer（10 頂点）と 1 平面の切断、≈270 行）**に分ける。
  - **rasterizerDiscardEnable**（1.0 core、review 2 の L14）: `RAST_MODE`[6] DISCARD で clip が全部の primitive を「flag だけの空の三角形」にする（PT は解放、fragment 無し、occlusion は 0）。firmware は vertex の store が無い pipeline（`vertexPipelineStoresAndAtomics` = 0 なら全部）では draw を出さなくてよい。
- **`atg_rx_setup`**（437 行、既に上限を超えている。p030 で分割する）: **`atg_rx_setup`（micro-program の実行と出力、≈300）と `atg_rx_edge`（新: 整数の step = snap、edge、bbox、facing、viewport の矩形、≈250）**。
  - **triangle**: 今の通り + depth bias + **viewport の矩形**（`RAST_MODE`[3] = 1 の時: bbox ∩ [x_off − |x_scale|, x_off + |x_scale|) × [y も同じ)。`viewportSubPixelBits` = 0 なので firmware が viewport の x・y・幅・高さを先に整数に丸めてから scale・offset を作り（p018、review 29）、矩形は整数。MS の sample も画素ごとに矩形の中か外）。DRAW_RAW（raw）は矩形を使わない（今の direct の試験を変えない、review 12）。
  - **line**（幅 1、`strictLines` = FALSE の parallelogram）: 主軸 = |Δx| ≥ |Δy| なら x（等しい時 x、Vulkan の規則）。x 主軸の角 a ± (0, ½)、b ± (0, ½)、y 主軸は ± (½, 0)（15.8 で ±128 subpixel、正確）。**2 つの sub-triangle**（a⁻, b⁻, b⁺）と（a⁻, b⁺, a⁺）の edge を作り、共有の対角の edge は top-left の bias で片方だけが被覆する（今の三角形の規則）。**plane**: 3 点 a、b、c = a + 主軸に垂直な 1 px の点（c の属性 = a の属性）から z・1/w・b0/w・b1/w を解く（Vulkan の「each pair of vertices at each end of the line has identical attributes」の 2 つの三角形の plane は共に、主軸の座標だけに依る同じ plane になる）。b0 = 頂点 0 の重み、b1 = 頂点 1 の重み、b2 ≈ 0。cull しない、front = 1。**長さが 1 subpixel 未満の line**（主軸の差 0）は捨てる（plane が解けない、review 32）。
  - **point**（size 1）: 正方形 (x_f ± ½, y_f ± ½) を 2 つの sub-triangle に。**plane**: z = 頂点の z（A = B = 0）、**1/w = 1**（point の中に perspective は無い）、**b0/w = PointCoord.s の plane**（A = 1、B = 0、s = ½ + (x + ½ − x_f)）、**b1/w = t の plane**（A = 0、B = 1）。すると `atg_rx_frag` の r0・r1 が PointCoord になる（r = 1/(1/w) = 1 は正確、新しい演算無し）。varying は compiler が頂点 0 の値を `lda` で読む（point の pipeline の program は compiler が topology を知って作る、U55）。cull しない、front = 1。
  - 2 つの sub-triangle は順に `sp_*` に出す（last-use の flag は 2 つ目だけ）。
  - **depth bias**（triangle だけ、`RAST_MODE`[0]）: m = max(|A_z|, |B_z|)（A_z・B_z は画素あたりの z の plane の係数、Vulkan の近似の式）、r = `RAST_MODE`[5:4] の format（0 無し → o = 0、1 D16 → 2^−16、2 D24 → 2^−24、3 D32F → 2^(e − 23)、e = その三角形の 3 頂点の window の z の最大の指数）、o = m·SLOPE + r·CONST、`DEPTH_BIAS_CLAMP` が正なら min(o, clamp)、負なら max(o, clamp)、0 なら clamp 無し（Vulkan の式）。o を z の plane の C に足す（FragCoord.z = bias 後）。**e の制限**（review 19）: clip で切られた多角形の fan の三角形ごとに e を求めるので、D32F で e が三角形ごとに違うと o が三角形の間で r の 2 倍まで違い得る（Vulkan の「the range of z values spanned by the primitive」は多角形の全体）。元の 3 頂点で求める案は w ≤ 0 の頂点で使えないので採らない。R35 として記録し、p030 の後に多角形の全頂点の e を clip が求める形を Future Work に（D24・D16 は r が一定なので影響無し）。**format を RX の範囲に持つ理由**: ROP の DEPTH（0x076）は前の draw の RX の setup の途中に変わり得た（§16.8a の修正の後も、RX が読む物は RX の範囲に置く方が規則が単純）。
  - micro-program（`include/atg_rx_setup_uc.vh`、`tools/rx-ucode.py` が生成）に line・point・bias の program を足す（≈+40 の micro-op）。`sp_tri` の [766:765]（今は 0）に kind（幅は 768 のまま）。
- **depth の clip の場所の経緯**: 版 6 の最初は ROP（shading の後）、review 1 の 8 で RX の frag（sample ごと）、review 2 の H1・H2 で clip の geometric な平面（上の 3）に移した。
  - **`DEPTH_CLAMP`**（0x059）: [0] depthClampEnable、**[1] DEPTH_CLIP（新）: 1 = Vulkan の depth の clip（near と far の geometric な平面）と clamp しない r3。0 = 今の動作（near の z ≥ 0 だけ、r3 を [0, 1] に clamp）**（「0 は以前の動作」の約束、review 12）。firmware は Vulkan の pipeline で常に [1] = 1。
  - **`RAST_MODE`**（0x05A）: [0] depth bias enable、[2:1] polygon mode（0 fill だけ。他は fill として読む）、**[3] viewport の矩形で切る**、[5:4] bias の depth の format、**[6] DISCARD**（rasterizerDiscardEnable）。**`DEPTH_BIAS_CONST`（0x060）・`DEPTH_BIAS_SLOPE`（0x061）・`DEPTH_BIAS_CLAMP`（0x062）**、fp32。
- **`atg_rx_frag`**: `DEPTH_CLAMP`[1] = 1 の時に 1x の r3 の clamp を外すだけ（≈+3 行）。point の warp は r0・r1 = PointCoord（plane の結果のまま）。o は SU と ROP に送らない（clip が geometric なので要らない）。
- **`atg_rx_scan`**: 変更無し（sub-triangle は普通の三角形として walk する）。

### 16.10 VF: vertex の format と robust の limit

- **format**: `ATTR_DST[k]`（0x1C0 + k）の **[31:24] = VkFormat**（0 = ATTR_DESC[19:16] の今の 10 種）。属性の大きさ = `atg_fmt_info` の texel の byte（1〜16。R32G32B32 は 12 byte で、`atg_fmt_info` に「12」の特別な値を足す）。変換は `atg_fmt_unpack`（列 V の全部: 8・16・32 bit の UNORM/SNORM/UINT/SINT/SFLOAT、B8G8R8A8_UNORM、A2B10G10R10 の UNORM/UINT）。integer の format は integer の bit を register に書く（compiler が int の入力として読む）。
- **`ATTR_LIMIT[k]`（0x1D0 + k、新）**: [31] 有効、[30:0] ATTR[k]_BASE から有効な byte の数（review 7: 0 を「制限無し」にすると、offset ≥ binding の範囲の時に firmware が計算する 0 が無制限に化ける）。[31] = 0 は制限無し（今と同じ）。[31] = 1 で、属性の offset + 大きさ > [30:0] なら memory を読まず (0, 0, 0, 1)（Vulkan の robustBufferAccess の「(0,0,0,x) vectors, where x is ... 0, 1, or the maximum representable positive integer value」の 1 の形）。firmware は ATTR[k]_BASE = binding の base + offset、ATTR_LIMIT = 0x80000000 | max(0, binding の範囲 − offset) を書く。
- **待ち**: 0x1C0〜0x1DF の SET_REG は VF の busy を待つ（今は 0x1C0〜0x1CF だけ: `atg_cp_seq.v` 215 行の `sidx[8:4]`。§16.8a で直す、review 6）。
- **変更**: `atg_vf_fetch`（大きさの表と limit の比較、332 → ≈360 行）、`atg_vf_conv`（`atg_fmt_unpack` に置き換え、170 → ≈200）、`atg_vf_asm`（kind の 2 bit、393 → ≈400: **上限**。超えるなら primitive の出力を子に分ける）。

### 16.11 TU: format（item 5・11）・D16（item 2）・stencil の aspect（item 3）・swizzle

- **`TEX_FORMAT`（slot の word +6、新。part F の reserved の word）**: [7:0] VkFormat（0 = TEX_IMAGE[7:4] の part F・p027 の code）、[8] stencil の aspect（D24S8 の byte 3 を UINT として読む）、[20:9] component swizzle（r・g・b・a の順に 3 bit の VkComponentSwizzle: 0 IDENTITY、1 ZERO、2 ONE、3 R、4 G、5 B、6 A）、[31:21] 0。`atg_tu_desc` は word 6 の 21 bit を持つ（16 slot × 21 FF）。**part F の reserved の word を使う（part F との合わせ 1）**。
- **texel の大きさ**: ps = 1・2・4・8・16 byte。`atg_tu_addr` の address = texel の index × ps（part F の「Texels are 4 bytes」を一般化。p027 の S5 の 16 bit の texel を含む）。**TEX_BASE と各 level の plane は 64 の倍数**（CAPS[30] の ps ≠ 4 の format、texel が part の境を跨がないため。review 2 の L8）。**4×4 tile は ps = 4 だけ**（driver は他の format を linear に置く。TEX_IMAGE[8] = 1 で ps ≠ 4 は linear として読む）。mip の plane の大きさ（part F の `atg_tu_desc` の P_l = w_l × h_l × 4）を ps に一般化（**part F との合わせ 2**: `atg_tu_desc` の乗算に ps の shift を足す。ETC2 の block の plane は §16.11a）。part F の今の head（fd6b28f、review の時点）で word 6 が reserved のままである事を S9 の最初に確かめる。
- **`atg_tu_cache`**: line の中の texel の取り出しを 1・2・4 byte（32 bit の word に右詰め）に、8・16 byte は **2・4 の part**（連続の word）にする。返す 16 word（4 lane × 4 texel）の割り当て: ps ≤ 4 は今の通り、8 byte の nearest は lane × part、16 byte の nearest は 4 lane × 4 part、**8 byte の bilinear（R16G16B16A16_SFLOAT だけ）は 2 pass**（pass 0 = 行 j0 の 2 texel、pass 1 = 行 j1。part F の pass の仕組み（slice・level の重み）に行の重みを足す）。border の texel は raw でなく「border の印」を返し、値は filter が入れる（下）。
- **2 つの filter の道**:
  - **u8 の道**（今の `atg_tu_filter`）: R8G8B8A8・B8G8R8A8・A8B8G8R8 の UNORM と、新しく R8・R8G8 の UNORM（無い byte を 0、alpha を 255 として渡す: 255/255 = 1.0 で正確）。depth（D24・D32F・**D16**）と compare もここ（`atg_depth.vh` に D16 を足す）。今の vector は bit で同じ。
  - **f32 の道（新 `atg_tu_ffilt`、≈300 行、FSM 1 つ）**: 他の全部の format。texel ごとに `atg_fmt_unpack`（sRGB は LUT、**filter の前に linear に**: Vulkan の sRGB の規則）、bilinear・trilinear・3D の重み（part F の 8 bit の fu・fv・fw と level の重みを fp32 にした物、正確）で Σ w·c を **fmul 1 本・fadd 1 本の pipeline**（1 項/cycle）。nearest は texel 0 の値をそのまま。**integer の format**（UINT・SINT・stencil の aspect）は nearest だけ（Vulkan は integer に FILTER_LINEAR を持たない）、integer の bit をそのまま返す。gather は component を選ぶだけ。≈4 lane × 4 channel × 4 texel = 64 項 + latency ≈ 70 cycle/quad（推定。RX の frag の 200 cycle/quad より短い）。
  - **border**（両方の道）: f32 の道は unpack の後に値を入れる: FLOAT_TRANSPARENT_BLACK (0, 0, 0, 0)、OPAQUE_BLACK (0, 0, 0, 1)、OPAQUE_WHITE (1, 1, 1, 1)、INT の 3 つは integer の format で integer の 0/1。sRGB の border は linear の値（encode しない）。u8 の道は part F の raw の texel のまま。
  - **swizzle**: 最後（border の後、gather の component の選択の前）に TEX_FORMAT[20:9] で並べ替え（両方の道の出口の mux 1 つ）。
  - **RGB565 の filter（item 11）**: f32 の道で（c/31・c/63 の正しい丸め）。p027 の S5 は `texf` の 565（MS の fetch）だけを足すので、p030 の S9 で f32 の道の format の 1 つに統合する（p027 の S5 の 565 の専用の回路は f32 の道の unpack に置き換えてよい: **p027 との合わせ 3**）。
- **stencil の aspect（item 3）**: TEX_FORMAT[8]。D24S8 の image の stencil の view は (s, 0, 0, 1) の integer（`usampler`）。MS の stencil の `texf`（p027 の rs2 = sample）も同じ。`sampledImageStencilSampleCounts` 1|4 を満たす（D24S8 に SAMPLED を出すので）。
- **MS の sample する image**（p027 の `texf` の rs2）: 全部の C の format の 4x を sample できる（ps の一般化で address の式 (x·S + s)·ps がそのまま使える）。
- 速さ: u8 の道の format（RGBA8・BGRA8）と depth は今の速さのまま。

### 16.11a TU: 圧縮の texture（ETC2・EAC。**p030 の範囲の外: PCIe の GPU の board の実機の bring-up の後**）

- **要求**: §16.1・§16.2 のとおり BC・ETC2・ASTC の 1 組の SAMPLED・BLIT_SRC・FILTER_LINEAR が 1.0 の必須（BCn の表の注は版の ifdef の外。review 1 の 1）。
- **2026-10-25 ユーザーの決定**（Q1 経由、原文）「圧縮テクスチャはPCIe GPUの実機bringupの後に回します。」→ **Vulkan 1.0 core の必須だが、p030 では実装しない**。理由: 最初のゴール（KC705 の PCIe の GPU の board で guest の zedBSD から Vulkan、p028）の app（vkdemo・compositor）は圧縮の texture を使わず、decoder（≈1.5k LUT、9 LW 前後）は bring-up の後でも他の module の形を変えない。Q1 が別の Phase として計画する。それまで driver は `textureCompression*` を 0 にし、「規格に合わない点」として記録する（libvulkan の N1・N2 と同じ扱い）。
- **設計の形**（後の Phase の入口）:
  - 組の選択（U58、推し ETC2 + EAC）: ETC2 の組は 10 format（VkFormat 147〜156: RGB8・RGB8A1・RGBA8 の UNORM と SRGB、EAC R11・R11G11 の UNORM と SNORM）、block は 4×4、8 byte（RGB8・RGB8A1・R11）か 16 byte（RGBA8 = 8 bit の alpha の EAC + 色、RG11 = R11 × 2）。BC の組は BC6H・BC7 の mode と partition の表が重く、ASTC は block の大きさと grid が可変で最も重い。
  - decoder `atg_tu_etc`（新、≈350 行、組み合わせ + 2 段の register）: 1 つの block と block の中の (i, j) → その texel の RGBA8 か EAC の 16 bit。色の mode は individual・differential・T・H・planar、RGB8A1 の punch-through は individual mode が無く opaque の bit と透明な index（RGB も 0）が有る。EAC は 8 bit の alpha（base × 1、multiplier 0 の規則）と 11 bit の R11（base × 8 + 4、multiplier 0 は 1/8、UNORM/SNORM の範囲）で規則が違う（review 2 の L10。細部は記憶で、後の Phase の最初に仕様で確かめる）。
  - TU の道: `atg_tu_addr` が block の address（base + (y/4)·row + (x/4)·bb、row = ceil(w/4)·bb）と (x%4, y%4)、`atg_tu_cache` が block を part（2 か 4 word）で返し、`atg_tu_etc` が texel にして f32 の道の unpack の入口へ。**bilinear は pass で**（review 2 の M3）: 16 byte の block の format は texel ごとに 4 pass、8 byte は 2 pass（4 texel が 1〜4 の block に掛かるので、texel ごとに block を読む）。plane は ceil(w_l/4)·ceil(h_l/4)·bb を 64 に丸めた物（part F の `atg_tu_desc` の P_l に block の形）。tile しない。copy は block を 64・128 bit の画素として BLT の COPY で。
  - 出典: ETC2・EAC の bit の配置と decode の規則は Khronos Data Format Specification（CC-BY-4.0）から自前で書く。他の実装の decoder の code と表は写さない。試験は `tools/etcmodel.py`（各 mode の手で作った block と random の block）と `atg_tu_etc_tb`、host に第三者の decoder が有れば試験の時だけ比べる。

### 16.12 BLT: depth だけ・stencil だけ（item 9）、画素の大きさ、RESOLVE の平均の code（Q1 の依頼）

- **前提（2026-10-25 Q1）**: p027 の U44 で resolve は BLT の op RESOLVE（`BLT_OP`[2:0] = 4、STATE 0x00B `BLT_RESOLVE`: [3:0] log2 samples、[7:4] 平均の code（0 UNORM8・1 UNORM565・2 SAMPLE0、3 SRGB8_A8・4 SFLOAT16・5 SFLOAT32 は定義済みで Amaterrace は refused）、[8] tile の dst、専用の engine `atg_blt_rsv`）。P2 の zedBSD agent/p2-p027 c9b95fd96 の design §15.8、amaterrace p2-p027 2803b65 の ghci.md §8.2（2803b65 を読んだ）。**最初の版の BLT_COLOR1〜3 = 0x00B〜0x00D は 0x00B と衝突したので移した**（review 4）。
- **画素の大きさ**（`BLT_OP`[9:8] と新しい [13]）: [9:8] 0 = 32 bit、1 = 16 bit、**2 = 64 bit（8 byte。Q1 の指定）**、**3 = 8 bit**、**[13] = 1 かつ [9:8] = 0 で 128 bit**（他の [13] の組は refused）。FILL・COPY・TILE/UNTILE（32 bit だけ）・RESOLVE が使う。walk の単位は 8 bit（line の中の byte の shifter）に変える。64・128 bit の FILL は `BLT_COLOR`（0x008）を下位、**`BLT_COLOR1〜3`（0x00C〜0x00E、新）**を上位の word にした画素（最初の版の「pattern」の field は画素の大きさで要らなくなったので外した: review 27 の位相の問題も消える）。
- **`BLT_OP`[19:16] KEEP（新）**: 32 bit の画素の書かない byte（FILL と COPY、blend 無し）。D24S8 の depth だけ = 0x8（byte 3 を残す）、stencil だけ = 0x7。AMB の書き込みの byte enable に AND するだけ（読み直し不要）。`vkCmdClearDepthStencilImage` の 1 つの aspect、`vkCmdCopyImage` の D24S8 の 1 つの aspect、render pass の中の `vkCmdClearAttachments` の 1 aspect と load の CLEAR（MS は p027 の幅 ×S と同じ）。
- **RESOLVE の平均の code**（`BLT_RESOLVE`[7:4]。§16.2 の format ごとの表）: 0 UNORM8 は **8 bit の画素（R8_UNORM）も受ける**、**3 SRGB8_A8・4 SFLOAT16（16・32・64 bit）・5 SFLOAT32（32・64・128 bit）を Amaterrace で実装**、**6 UNORM2_10_10_10（新、32 bit: [9:0]・[19:10]・[29:20] は 10 bit、[31:30] は 2 bit の UNORM の code の平均、RNE）**、**7 UNORM1555（新、16 bit: [15] は 1 bit、[14:10]・[9:5]・[4:0] は 5 bit）**、2 SAMPLE0 は 8〜128 bit の全部。p027 の平均の組み合わせの `atg_blt_avg` に 6・7 と 0 の 8 bit を、sRGB（3）と fp（4・5）は `atg_blt_rsv_px` が group ごとに stall（ready を落とす）して逐次に回す形で足す（sRGB の decode の表と BLT 専用の `atg_fmt_srgbenc` 1 つ、fp32 の fadd 1 本: 4 sample の ((s0 + s1) + (s2 + s3)) × 0.25。group あたり sRGB は ≈4 px × 3 ch × 8 cycle、review 2 の M1）。p027 の文の「Amaterrace: 0-2; 3-5 are refused」は S10 で「0-7」に直す。
- firmware が clear の色を format の bit に詰める（RV32 の C、`ghci_layout.h` の隣に format の pack の表。hardware の `atg_fmt_pack` と同じ規則で、p018 の試験は `fmtmodel.py` の pack の参照（UFLOAT・E5B9G9R9・B4G4R4A4・SNORM を含む全部の format、review 2 の L9）と比べる）。
- **S8 の詰めた buffer ↔ D24S8 の stencil の aspect の copy**（`vkCmdCopyImageToBuffer` の stencil）は BLT では出来ない（4 byte → 1 byte）→ firmware の内蔵の compute の kernel（lane が 4 texel を受け持ち `lw`・shift・`sw`。p018）。**行と region の端の word**（幅が 4 の倍数でない時）は region の外の byte を変えないよう `atom` の AND と OR で merge する（review 2 の M4）。
- **順**: BLT（p027 の後は `atg_blt_2d`、696 行）の U38 の分割は p027 の範囲の外で担当が無いので **S10 の最初に行う**（review 2 の H4）。**S10 は p027 の BLT の段の merge の後**（**p027 との合わせ 4**）。

### 16.13 SU: export の COLOR1〜3・`ex_aux`・fragment の入力（item 8 の口）

- **export の target**: COLOR k の component c = **0x100 + 16k + c**（k = 0〜3。k = 0 は今の 0x100〜0x103）。0x104 DEPTH、0x105 SAMPLE_MASK（p027）、0x108〜0x10B は SECOND_COLOR（dual source、予約）。
- **`atg_su_exp`**（p027 の後 ≈330 行 + 16 word の色・rtw・beat → 400 を超える）を **`atg_su_exp`（lane の RAM と snoop と export の書き込み、≈280）と `atg_su_exp_drain`（新: drain の FSM、beat、`ex_*`、≈180）**に分ける。lane の RAM は 4 → 16 の色の word（distributed RAM、NPHYS bank × 16 word × NWARPS·32/NPHYS 行）。
- **`ex_aux`**（p027 の `ex_ms[147:0]` を広げて名前を変える。port の数は変わらない）: [147:0] = p027 の {d_s, zexp, smask}、[148] front、[149] nocol、[150] qfirst、[151] qlast、[153:152] rt。**front は S7（stencil の back face の結線の試験のため）、beat の bit は S8 で足す**（review 17）。o（bias）は depth の範囲の clip が RX に移ったので ROP に運ばない（§16.9）。**p027 との合わせ 5**: p027 の S3 の後に名前を変える（S3 の前なら p027 が最初から `ex_aux` にしてもよい。Q1 が merge の順で決める）。
- **fragment の入力**: point の warp は r0・r1 = PointCoord（§16.9）。他は p027 の r0〜r9 のまま。
- **item 8（FragDepth・SampleMask の front end）**: GSI1 の口は既に有る（`exp 0x104` = FragDepth、`exp 0x105` = SampleMask の出力、r6 = SampleMaskIn）。p010 で `spirv.c` が BuiltIn FragDepth（execution mode DepthReplacing。DepthGreater/Less は最適化の印で無視してよい）と SampleMask を扱い、GSI1 の backend が上に写す。**この Phase では RTL も GHCI も変えない**（記録だけ）。
- **gsi1asm の名前**: `color1.r`〜`color3.a`（0x110〜0x133）。GSI1 の道具の変更は p027 の S1 の後（**p027 との合わせ 6**: S1 が道具を先に直すので、p030 は S1 の merge の後に足す）。

### 16.14 input attachment（item 10）と shader の資源（compiler の道）

- **input attachment は RTL を足さない**（U51）: `subpassLoad` は fragment の自分の画素（と MS では自分の sample か指定の sample）を読むだけなので、compiler（p010）が address = base + y·P + (x·S + s)·ps（x = fcvt(r4 − ½)、y 同じ、P と S は descriptor の word）を作り `lw`（16 byte の format は 4 回）と format の unpack の命令（format は render pass で pipeline の作成の時に分かる）で読む。**理由**: TU の 16 slot は `maxPerStageDescriptorSampledImages` 16 で埋まり、input attachment 4 を足すと 20 slot が要る（descriptor が 16 word × 16 slot = STATE の 0x090〜0x18F の全部）。`lw` の道なら slot も TU の変更も要らない。
  - interface の表の **kind 9 input attachment**（set、binding、kind-specific = constant bank の word: firmware が {base（layer・level を足した）, P, S | ps << 8} を置く）。
  - firmware（p018）: subpass の境と subpass の中の self-dependency の barrier で `WAIT_IDLE(ROP)` + `INVALIDATE D$`（ROP が memory に書き、SU の D$ は coherent でない）。color と input の同じ attachment（feedback loop、GENERAL の layout）もこの barrier で正しい。
  - 4×4 tile の image は input attachment に使わない（COLOR_ATTACHMENT と DEPTH_STENCIL の image は linear に置く今の規則、§15.8）。
- **storage image・storage texel buffer**（core、U50）: SPIR-V の image の format（`shaderStorageImageReadWithoutFormat`・`WriteWithoutFormat` は任意で 0）が compile の時に分かるので、同じく compiler の address と `lw`/`sw`/`atom`（R32 の atomic）。列 St・T の format は全部 4 byte の倍数の texel（RGBA8・RGBA16・R32・RG32・RGBA32）なので byte の store（GSI1 に無い）は要らない。STORAGE の usage の image は linear（driver）。interface の **kind 10 storage image**（{base, P, w | h << 16, layers}）、**kind 11 texel buffer**（{base, 要素の数}）。
- **uniform texel buffer**（core）: format は descriptor の時に決まるので TU の slot（`maxPerStageDescriptorSampledImages` に数える）。2D の image（w = 256 texel、h = ceil(n/256)、行 = 256·ps byte の連続）として TEX_* を firmware が書き、compiler は index を (i & 255, i >> 8) の `texf` に。範囲の外は compiler が要素の数と比べて 0。TEX_BASE は 64 の倍数なので、driver の `minTexelBufferOffsetAlignment` は 256（Vulkan の上限の値、64 の倍数）にする（p019、review 33）。
- **robustBufferAccess の SU の道**（p010）: storage・uniform buffer の読み書きの address を compiler が descriptor の {base, 大きさ} で clamp する（「values from within the memory range bound to the buffer」の形）。constant bank の uniform buffer は bank の中の自分の範囲で clamp。
- **`maxUniformBufferRange` 16384**: constant bank（256 word）は 1 KiB なので、bank に入らない uniform buffer は `lw` の道（storage と同じ）に compiler が回す（p010。U50）。
- これらは p030 の RTL の範囲の外。GHCI の interface の kind 9〜11 だけを draft に書く（§16.15）。

### 16.15 GHCI の追加（draft。amaterrace-gpu の `docs/ghci.md` に書いた）

- **CAPS[30] CORE1**（draft、番号は仮）: §8.5 の Vulkan 1.0 core の固定機能（stencil の op（CAPS[9] は「stencil の attachment が有る」の意味のまま、CAPS[30] は op と front/back。review 25）、D16、depth bias・bounds・clamp と depth の clip、w ≥ ε・viewport の矩形・guard band の clip、point と line、4 つの color attachment と FMT capability の format、fp32 の blend constant、occlusion の counter と `QUERY`、ATTR_LIMIT、rasterizerDiscard）。CAPS[27]（graphics）が有る構成で 1。0 の GPU では driver は今の部分集合だけを使う。CAPS[15:12]（state layout の版）を 2 に上げる案は、新しい field が全部「0 = 以前」なので採らない。**番号の衝突**: p027 の CAPS[29] の次。part F が CAPS の bit を足すなら Q1 が merge で決める。
- **FMT capability（id 10、draft）**: register（capability の offset から）: +0x0 FMT_INDEX（RW、VkFormat）、+0x4 FMT_OPTIMAL（R、index の format の optimal tiling の固定機能の VkFormatFeatureFlags の bit。対応しない format は 0）、+0x8 FMT_LINEAR、+0xC FMT_BUFFER、+0x10 FMT_LIMITS（R、[3:0] color attachment の数、[11:4] 予約）。値の意味は VkFormatFeatureFlagBits の bit の番号（Vulkan 1.0 の bit 0〜12。TRANSFER の bit（1.1）は 0）。shader の道の bit（STORAGE_*、texel buffer の一部）は答えない（§16.4）。driver（p019）は `vkGetPhysicalDeviceFormatProperties` をここから作る。Amaterrace は **0x160〜0x17F** に置く（CPFW_MBOX の後ろ、review 13）。読みは副作用無し（GHCI §2 の規則）、FMT_INDEX の書き込みは RUNNING でも可（host だけの register）。
- **µop 14 `QUERY`**（§7.3）: 上の §16.8。GHCI は「occlusion の sample の counter」の意味だけを決め、counter の幅は vendor（最低 32 bit。Amaterrace 40）。
- **STATE**（新しい §8.5 に RX・ROP・VF の範囲を初めて書く。今の bit は `ghci_regs.vh` と spec の Status 行と design §2.3 の物）: RX 0x059 DEPTH_CLAMP（[1] DEPTH_CLIP）、0x05A RAST_MODE（[3] viewport の矩形）、0x060〜0x062 DEPTH_BIAS_*、ROP 0x076 DEPTH、0x077〜0x079 STENCIL_*、0x07A BLEND、0x07C WRITE_MASK、0x07D RT_FORMATS、0x07E〜0x083 RT1〜3、0x084〜0x086 BLEND1〜3、0x087〜0x08A BLEND_CONST_*、0x08B〜0x08C DEPTH_BOUNDS_*、0x08D ROP_CTRL（[0] occlusion、[1] fp32 の constant）、VF ATTR_DST[31:24]、0x1D0〜0x1DF ATTR_LIMIT（[31] 有効）、TU +6 TEX_FORMAT、BLT_OP の画素の大きさ（[9:8]・[13]）・KEEP と BLT_COLOR1〜3（0x00C〜0x00E）、BLT_RESOLVE の平均 6・7。新しい field は全部「0 = 以前の動作」（GHCI §8.5 の冒頭に例外無しと書いた）。
- **GSI1**: §12.10 の interface の kind 9〜11、新しい §12.12 に export の COLOR1〜3 と point の fragment の入力（r0・r1 = PointCoord）、line の b2 ≈ 0。p027 の §12.11 の後に置く（p027 の branch は §12.11 を足すので、merge では §12.11 → §12.12 の順に並べる）。**p027 の §12.11 の r3 の文**（「with 1 sample clamped to [0, 1]」）は `DEPTH_CLAMP`[1] = 0 の時の物で、[1] = 1 では 1x も clamp しない、と S11 で §12.11 に足す（review 22）。
- 丸めの規則（UNORM・fp16 の RNE、unpack の正しい丸め）は GHCI の標準ではなく「Amaterrace:」の注として書いた（Vulkan は実装に委ねる、review 30）。
- **出典の文**: ghci.md の該当の所に「Values referenced: Vulkan specification, VkFormat, VkStencilOp, VkComponentSwizzle, VkFormatFeatureFlagBits; Depth Bias Computation; Basic Line Segment Rasterization」と書く。文は写さない。

### 16.16 CP・firmware・driver への入力（p010・p018・p019。この Phase では書かない）

- **p010（compiler）**: FragDepth・SampleMask（item 8）、COLOR1〜3 の export（location の写し）、point の pipeline の varying は頂点 0 の `lda`、PointCoord = r0・r1、input attachment・storage image・texel buffer の address と unpack/pack（§16.14）、robustBufferAccess の clamp、uniform buffer の 16 KiB（bank の外は `lw`）、integer の texture の結果は integer の register、`OpImageQuerySamples` は p027。
- **p018（firmware）**: pipeline の rasterization・depth stencil・color blend の state → §16.15 の STATE（RT_FORMATS、BLEND1〜3、BLEND_CONST、STENCIL の 3 word、DEPTH の bit、DEPTH_CLAMP、RAST_MODE（bias の format は render pass の DS の format から）、DEPTH_BIAS_*、DEPTH_BOUNDS_*、ROP_CTRL）、dynamic state（96 line width は 1.0 以外を受けない（feature 0）、97 depth bias、98 blend constants、99 depth bounds、100〜102 stencil の mask・ref。今の §2.4.4 の「読んで捨てる」を改める）、vertex の bind → ATTR_DST[31:24]・ATTR_LIMIT、image view → TEX_FORMAT（swizzle、stencil の aspect）、query pool（§16.8: gpu-op 47〜49、127〜131 を X → R）、clear と copy の BLT の KEEP・画素の大きさ、S8 の buffer copy の内蔵の kernel、内蔵の clear の draw（D24S8 の 1 aspect の render pass の中の clear は BLT の KEEP か ROP の draw）、input attachment の descriptor と subpass の barrier（gpu-op 134 next subpass を R）、indirect（108・109・111: `WAIT_IDLE` + `INVALIDATE` の後に DMA で引数を読み `SET_REG` と `DRAW`/`DISPATCH`）、event（123〜125: set/reset = `WAIT_IDLE` + `RESULT` で memory に、wait = `WAIT_FENCE`）、secondary の command buffer（136: 記録の入れ子を辿る）。
- **p018 の追加**（review 14・18・29）: `vkCmdBlitImage` の dst は **ROP の内蔵の draw**（fragment の program が `texl` で src を読み、ROP が pack と sRGB の encode をする。compute の `sw` は 1・2 byte の画素で lane の書き込みが競合するので使わない）、内蔵の draw の前後で `ROP_CTRL`[0] を 0 にして戻す、viewport の x・y・幅・高さは整数に丸めてから VIEWPORT を作る（`viewportSubPixelBits` 0）、Vulkan の pipeline では `DEPTH_CLAMP`[1] = 1・`RAST_MODE`[3] = 1・`ROP_CTRL`[1] = 1。
- **p019（`vk/`）**: features と limits（§16.1 の v1 の列）、format の properties を FMT capability（固定機能の bit）と CAPS[17]・ISA（shader の道の bit）から、image の memory requirements（ps = 1〜16、alignment 64、row pitch は §16.7 の揃え、tile は ps = 4 だけ、STORAGE と attachment の image は linear、ETC2 は block の行）、query pool の memory の配置、`vkGetQueryPoolResults`、event の host 側（`vkSetEvent` は memory に書く D）、`minTexelBufferOffsetAlignment` 256。

### 16.17 状態遷移・資源の所有と寿命・並行性

- **新しい FSM**: `atg_rop_fblend`（IDLE → MUL/ADD の pipeline の投入（16 channel）→ DRAIN → OUT）、`atg_fmt_srgbenc`（IDLE → SEARCH（8 step）→ DONE）、`atg_tu_ffilt`（IDLE → TERM（項ごと）→ OUT。pass の続きは IDLE へ）、`atg_rx_cpoly`（IDLE → CUT（平面ごと）→ EMIT）、`atg_su_exp_drain`（IDLE → BEAT（quad × attachment）→ RET）。`atg_rop_dtest`・`atg_rop_wpix`・`atg_rop_occ`・`atg_rx_edge`（setup の整数の step を順に呼ばれる組み合わせの部品か小さな FSM）。
- **変わる FSM**: `atg_rop_ds`（IDLE →(qfirst)→ ROW → RD → TEST（entry）→ WR → … → OUT、IDLE →(後続の beat)→ OUT）、`atg_rop_wb`（beat ごとに LOOKUP（line 1〜4）→ READ? → BLEND（u8 か f32）→ MERGE）、`atg_rx_setup`（kind で micro-program の入口を選び、line・point は EDGE を 2 回、OUT を 2 回）、`atg_rx_clip`（kind と guard band の判定で CPOLY へ）。
- **資源の寿命**: front・nocol・rtw は warp の slot の寿命（p027 の d_s と同じ: `fl_go` の前の snoop から `xr_valid` の解放まで、解放と reset で 0）。ROP の中の smask・z・pass の mask は quad の寿命（qfirst から qlast まで）。occlusion の counter は `QUERY` の clear まで。FMT の ROM は定数。
- **並行性**: ROP は 1 quad ずつ（今と同じ）、beat は同じ quad の間に他の quad を挟まない（order は連番ごとに順に出す）。CP の `QUERY` は RESULT と同じ「先行の全部の完了」を待ち、その後に `ROP_CTRL`[0] = 0 を書くので、先行の draw の sample は全部入り、後の draw は数えない。RX・ROP の state は §16.8a の待ちで draw ごとに保たれる。
- **割り込み・DMA**: 新しい割り込み・fault の種類は無い。新しい AMB の client は無い（TU・ROP・VF・BLT の今の port）。`QUERY` の書き込みは fence unit の今の port。quiesce と reset は今の順（§1.3）、新しい FSM は `core_rst_n` で IDLE、counter は reset で 0。

### 16.18 失敗と corner case

- **予約の値**: 対応しない VkFormat は「format 無し」（fault にしない: STATE の書き込みは fault の種類を増やさない方針、p027 と同じ）。STENCIL の op 8 以上は無い（3 bit で 0〜7 の全部）。RAST_MODE の polygon mode 1〜3 は fill として読む。DEPTH の format の bit が 2 つ以上は format 無し。
- **beat の順の誤り**（SU の bug）: ROP は qfirst の無い beat を前の quad の続きとして扱う。TB の assert で検査する（RTL は検査しない）。
- **MRT と MS と 16 byte の format**: 4x の RGBA32F の 1 行 = 128 byte = 2 line（KC705）/4 line（ZYBO の形）。wb は line を順に回す（write-combine の 2 本は行の最初の 2 本で埋まる → 行の残りは置き換えで書き出し。正しさは変わらない、速さは落ちる）。
- **depth の clip と FragDepth**: clip は z_r（rasterize の値）で判定し、FragDepth の値では判定しない（§16.6）。
- **point・line の多くの小さな primitive**: setup は 1 回、sub-triangle は 2 つ。sequence の連番は warp ごと（frag が採る）なので、2 つの sub-triangle の warp は同じ primitive の中で順に退く。
- **clip の後の三角形の数**: 最大 8（7 平面、10 頂点の fan）。PT の entry は元の 3 頂点のまま（重みで表す）。
- **sRGB の encode の境**: x が閾値ちょうどの時は上の code（「以下の数」の定義）。
- **D24 の depth の copy の往復**（BLT の COPY は bit の写しなので往復の問題は無い。f32 で読み書きする内蔵の draw だけの問題）: §16.0 の未確認。
- **robust の ATTR_LIMIT**: limit が小さすぎる（driver の誤り）時は (0, 0, 0, 1) を読む（fault にしない）。比較は 33 bit の和（offset + 大きさ > limit、桁あふれしない。review 2 の L6）。
- **QUERY の addr の揃え**: 8 byte でなければ下位の bit を無視（RESULT と同じ）。aperture の外は fault 種別 1（fence unit の今の道）。
- **長さ 0 の line**（主軸の差が 1 subpixel 未満）は捨てる（§16.9）。**w ≤ ε の頂点**は clip の平面 1 で切る（§16.9）。
- **draw の間の state**（§16.8a）: 前の draw が上流に居る間に RX・ROP の state を書く列を `atg_top_core.backtoback` で試す。
- **R35**: D32F の depth bias の e は clip の fan の三角形ごと（§16.9）。

### 16.19 on-chip の量（推定、合成していない）

| 部分 | LUT | FF | BRAM18 | DSP |
| --- | --- | --- | --- | --- |
| format の unpack × 3（VF、TU f32、ROP dst）と pack × 1 | ≈3.2k | — | — | 0 |
| sRGB の decode の表 × 3（TU、ROP、BLT の resolve）、encode の閾値 × 2（ROP、BLT） | ≈0.3k | ≈0.2k | 5 | 0 |
| ROP: `atg_rop_fblend`（fmul・fadd 各 1）、dtest（stencil・D16・bounds）、occ、wpix、beat | ≈2.6k | ≈1.5k | 0 | ≈4 |
| TU: `atg_tu_ffilt`（fmul・fadd 各 1）、desc の word 6、cache の part、swizzle | ≈1.8k | ≈0.8k | 0 | ≈4 |
| RX: clip の 7 平面（多角形 10 頂点 × 13 word）、setup の line/point/bias、viewport の矩形 | ≈1.6k | ≈1.7k | 0 | 0（今の fp unit を共有） |
| SU exp: 色の word 4 → 16（**SU ごと**: NWARPS 4 で +49 Kbit、NWARPS 8 で +98 Kbit。distributed RAM の書き込み 1・読み 4 lane で ≈1〜2k LUT。review 15） | ≈1.5k × N | ≈0.2k × N | 0（BRAM にするなら SU ごとに BRAM18 × 4） | 0 |
| BLT の RESOLVE の平均 3〜7（fadd 1、sRGB） | ≈0.6k | ≈0.3k | （上の表に含む） | 0 |
| CP: QUERY、`atg_cp_seq` の待ちの mask、FMT の ROM | ≈0.4k | ≈0.1k | 0 | 0 |
| **合計（N = 6）** | **≈21k** | **≈6.3k** | **5** | **≈8** |

- KC705（XC7K325T、204k LUT）の約 10%。§3.6 の N=6 の最後の 146k（72%）に足して ≈167k（82%）。**SU ごとの exp の RAM が最大の項**なので、N=6 が閉じない時は exp の色の RAM を BRAM に（SU ごとに BRAM18 × 4: 16 word × 32 bit の行を 4 lane 同時に読むため bank を 4 つ）するか、MRT の色を 2 attachment ずつの 2 pass にする（p015 の実測で決める）。
- **R34（ZYBO）**: p030 の論理は parameter で外さない（p027 の R33 と同じ考え）と、ZYBO の bitstream 3（raster、SU 無し、47〜56%）に ROP の f32 の blend と format の表 ≈+4k が入り ≈70〜80%。7010 の timing と入るかは p007 の再合成の時に見る。入らなければ parameter `FMT_FULL`（0 で f32 の blend と TU の f32 の道を外し、RT と texture を今の format だけにする。FMT の ROM もこの parameter で作る）を足す（U57）。ZYBO は最初のゴールの道の外。

### 16.20 model・TB・scene・Verilator の計画（試験は host の iverilog と Verilator。QEMU・VFIO・板はこの Phase に無い）

- **試験の道の全体**: (1) host: model の self-test と unit TB（iverilog、各 run `timeout 600`）、(2) Verilator の harness の scene、(3) QEMU: この Phase は RTL だけで QEMU の対象が無い（zedBSD の driver は p006・p019 の Phase で、QEMU の armv7-virt の回帰は T1）、(4) VFIO の実機（KC705 の PCIe、guest の zedBSD の Vulkan）: p028 の受け入れで p030 の機能（stencil、MRT、format、point/line、query）を使う vkdemo の scene を流す（p028 の設計で列挙する）。**QEMU の証拠と実機の証拠はこの Phase では無い**。
- **model**: 新 `tools/fmtmodel.py`（`atg_fmt_*` と sRGB の表と D16/D24 の変換の参照。`--selftest` = UNORM の全部の b の全 code の正しい丸め、sRGB の encode が全 fp32 の [0, 1] の代表（各 code の閾値の前後の 3 値）で sRGB 空間の最近、D24 の往復 2^24 の全部、fp16 の pack の境）、`tools/srgb-tables.py`（`include/atg_srgb.vh` を生成、生成物を commit し、`--check` で再生成と比べる）。`rxmodel.py` に line・point・bias・viewport の矩形・guard band の clip・stencil・D16・bounds・MRT の beat・f32 の blend・occlusion（1x の関数は変えず新しい関数を足す。4x は p027 の `msmodel.py` の上に）。`tumodel.py`（part F の版）に format・swizzle・f32 の filter・stencil の aspect。`vfmodel`（`vf-vectors.py` の中）に format と limit。
- **1x の回帰の守り**: p027 の `tools/vec-diff.py` で、87457fa（と p027 の merge の後の版）の vector との差が「意図した変更」（`ex_aux` の新しい列。`DEPTH_CLAMP`[1] = 0 の既存の vector の r3 は変わらない。w ≥ ε と guard band の clip は無条件なので、既存の vector に w < ε か guard band の外の頂点が有れば差になる: その列を数えて記録する、review 2 の L1）だけである事（`PASS vecdiff.<name>`）。
- **単体 TB の PASS の行**（各 TB は最後に `PASS <module>`。ROP・RX・TU の TB は LINE_BYTES 32 と 64）:

| TB | 足す PASS の行 |
| --- | --- |
| `atg_fmt_tb`（新、関数の束） | `atg_fmt.unpack`（全 format × random の raw を `fmtmodel.py` と。fp16 は Python の `struct` の 'e' を独立の参照に）、`atg_fmt.pack`、`atg_fmt.required`（FMT の ROM の固定機能の bit が `tools/vk-required-formats.txt`（Vulkan の必須の表から写した事実の bit の列、出典つき）の上位集合。同じ case どうしの比べ（review 20）は使わない） |
| `atg_fmt_srgbenc_tb`（新） | `atg_fmt_srgbenc.exhaustive`（全 code の閾値の前後） |
| `atg_vf_conv_tb`・`atg_vf_fetch_tb` | `atg_vf_conv.formats`（列 V の全部）、`atg_vf_fetch.limit`（境の前後）、`atg_vf_fetch.limit0`（[31] = 1 で 0 byte）、`atg_vf_fetch.size12` |
| `atg_rx_clip_tb` | `atg_rx_clip.line`（1 つだけ出す）、`atg_rx_clip.point`、`atg_rx_clip.clampw`、`atg_rx_clip.wneg`（reversed-Z の投影のカメラの後ろの頂点）、`atg_rx_clip.guard`（大きな三角形を model の多角形と）、`atg_rx_clip.guardline`、`atg_rx_clip.lastuse`（flag は最後の 1 つだけ） |
| `atg_rx_setup_tb` | `atg_rx_setup.line`（parallelogram の edge と plane、x/y 主軸と等しい時）、`atg_rx_setup.point`（PointCoord の plane）、`atg_rx_setup.viewport`、`atg_rx_setup.bias`（4 つの format と clamp の符号） |
| `atg_rx_frag_tb` | `atg_rx_frag.r3`（`DEPTH_CLAMP`[1] = 1 で 1x の r3 を clamp しない、0 で今と同じ） |
| `atg_su_exp_tb` | `atg_su_exp.mrt`（COLOR1〜3、rtw、beat の順、nocol）、`atg_su_exp.aux`（front） |
| `atg_rop_dtest_tb`（新） | `atg_rop_dtest.stencil`（8 op × 8 compare × front/back × mask の random を model と）、`atg_rop_dtest.d16`、`atg_rop_dtest.bounds`、`atg_rop_dtest.order`（bounds → stencil → depth） |
| `atg_rop_ds_tb` | `atg_rop_ds.stencil`（今は空の行を中身に）、`atg_rop_ds.beats`、`atg_rop_ds.d16` |
| `atg_rop_ms_tb` | `atg_rop_ms.clamp`、`atg_rop_ms.legacy`（`DEPTH_CLAMP`[1] = 0 で p027 と bit で同じ）、`atg_rop_ms.beats`（a2one を全部の beat に） |
| `atg_rop_fblend_tb`（新） | `atg_rop_fblend.ops`（op 5 × factor 15 × format（sRGB・1010102・16F）の random を model と）、`atg_rop_fblend.srgb` |
| `atg_rop_blend_tb` | `atg_rop_blend.r8rg8`、`atg_rop_blend.const`（fp32 → 8 bit の量子化） |
| `atg_rop_wb_tb` | `atg_rop_wb.mrt`（RT ごとの state）、`atg_rop_wb.ps`（1・2・8・16 byte）、`atg_rop_wb.multiline`（4x の 16 byte）、`atg_rop_wb.int`（integer の pack と write mask） |
| `atg_rop_occ_tb`（新） | `atg_rop_occ.count`（1x・4x・enable の切り替え） |
| `atg_cp_seq_tb` | `atg_cp_seq.query`（先行の draw の完了の後に書く、clear の flag は待たない）（待ちの TB は p027 の修正の側: `ropwait`・`tuwait`・`progwait`・`attrlimit_wait` を Q1 経由で p027 に依頼） |
| `atg_cp_regs_tb` | `atg_cp_regs.fmt`（FMT の register の読みが表と一致） |
| `atg_tu_cache_tb`・`atg_tu_ffilt_tb`（新）・`atg_tu_filter_tb`・`atg_tu_addr_tb` | `atg_tu_cache.parts`（1・2・8・16 byte）、`atg_tu_ffilt.formats`（全 S の format × nearest/bilinear/trilinear/3D を model と）、`atg_tu_ffilt.int`、`atg_tu_ffilt.border`、`atg_tu_ffilt.swizzle`、`atg_tu_ffilt.gather`、`atg_tu_filter.d16`、`atg_tu_addr.ps` |
| `atg_blt_tb`（p027 の分割の後の BLT の TB） | `atg_blt.keep`（D24S8 の 2 つの aspect の FILL と COPY）、`atg_blt.ps`（8・64・128 bit の FILL と COPY）、`atg_blt.resolve_fmt`（平均 3〜7 を model と） |


- **故意の誤り**（p027 と同じ `ifdef MUT_<名前>`）: `MUT_STENCIL_FACE`（front/back を入れ替え）、`MUT_STENCIL_WRAP`（wrap を clamp に）、`MUT_LINE_MAJOR`（等しい時に y 主軸）、`MUT_BIAS_R`（D24 の r を 2^−23 に）、`MUT_FARCLIP`（far の平面を外す）、`MUT_WCLIP`（w の平面を外す）、`MUT_ATTR_LIMIT_GE`（limit の比較を ≥ に）、`MUT_SRGB_ROUND`（閾値を 1 つずらす）、`MUT_BEAT_MASK`（後続の beat に ds の前の mask）、`MUT_OCC_BEAT`（beat ごとに数える）。該当の TB の該当の PASS の行が出ず `FAIL` が出る事を `iverilog -DMUT_<名前>` で確かめる。
- **scene**（新 `sim/tb/atg_top_core_tb.v` + `tools/rx-core-scene.py`、N=1、KC705 の形（LINE_BYTES 64）と TU 付きの ZYBO の形（LINE_BYTES 32）、RT 64×48、各 run `timeout 600`）: (1) stencil の 2 pass（front で INCR_WRAP、back で DECR_WRAP、その後 stencil の EQUAL で色）、(2) D16 の depth、(3) MRT 4（RGBA8・RGBA16F・R32_UINT・RGB565、RT ごとの blend と write mask）、(4) sRGB の RT の blend、(5) point と line（1x と 4x、主軸の等しい line、PointCoord で色）、(6) depth bias（D24・D32F）+ depth clamp + far の clip + scissor より小さい viewport、(7) occlusion の query（1x・4x、`QUERY` の値が model と）、(8) 新しい format の texture（565 の bilinear、RGBA16F の bilinear、R8、R32_UINT の `texf`、stencil の aspect、swizzle）、(9) vertex の format（A2B10G10R10_UNORM、R16G16_SNORM、R8G8B8A8_UINT）と ATTR_LIMIT の外、(10) BLT の depth だけの clear と stencil だけの copy、(11) guard band を出る大きな三角形と line、(12) 4x の stencil + MRT + RGBA32F（1 行が複数の line）、(13) **backtoback**（前の draw の primitive が VF・SU に居る間に次の draw の BLEND・STENCIL・RT_FORMATS・MS_CTRL を変える列）、(14) reversed-Z の投影でカメラの後ろに頂点のある三角形、(15) minDepth = maxDepth の viewport で far の外の三角形（review 2 の H2）、(16) 4x の RGBA16F と sRGB の resolve（BLT の平均 3・4）、(18) 64 varying word（16 location × 4 component、KC705 の形で VARYING_COUNT 64、location 15 の word 60〜63 を含む、S13 で定義し S11 の scene の TB で流す）。(13) は p027 の待ちの修正の後に流す。PASS の行: `atg_top_core.<名前>` と `atg_top_core`。**受け入れ**: 全部の RT・DS の image と query の値が model と word ごとに一致、PNG（6 倍、`build/review/ws001-p030-core.png`）。
- **Verilator**: harness に core の mode（scene の (3)(5)(6)）、`make verilator` の PASS に入れる。
- **回帰**: `make lint` clean。`make sim` の PASS の行の数が **S1 の開始の commit で数えた数**（S1 の記録に commit と数）より減らない。既存の raster・shade・tex・msaa の scene が変えずに PASS（意図した変更は vec-diff の範囲だけ）。
- 試験は T1・T2・T3 に依頼（2026-10-25 ユーザー「検証はT1, T2, T3に依頼して、P1,P2が実装を先に進めていくことにしましょう。」）。実装の担当は unit TB の短い run だけを自分で流し、`make sim` と `make verilator` の全部は T に頼む。

### 16.21 module の分け方（1 module ≤ 400 行・FSM 1 つ・≤ 40 port）

| module | 変更 | 行（推定） | port |
| --- | --- | --- | --- |
| `include/atg_fmt_info.vh`・`atg_fmt_unpack.vh`・`atg_fmt_pack.vh`（新、関数） | format の表と変換 | ≈150・≈250・≈250 | — |
| `include/atg_srgb.vh`（新、生成） | sRGB の decode と閾値 | ≈520（生成の表。手で書く行の規則の外） | — |
| `atg_fmt_srgbenc`（新） | 2 分探索 | ≈90 | ≈8 |
| `atg_rop_dtest`（新） | stencil・depth・bounds の判定 | ≈220 | ≈22 |
| `atg_rop_ds` | dtest を使う、beat、D16 の address | p027 の後 ≈290 → ≈300 | 30（幅だけ） |
| `atg_rop_ms` | clamp・legacy・beat | ≈220 → ≈260 | 21 → 23 |
| `atg_rop_order` | beat の aux を通す | ≈90 | 変えない（幅） |
| `atg_rop_wb` | line の回しと beat | ≈330 → ≈300（pixel の部分を出す） | 29 → 31 |
| `atg_rop_wpix`（新） | pixel の位置、RT の state、unpack、道の選択 | ≈250 | ≈30 |
| `atg_rop_blend` | R8・RG8・1555、fp32 の constant の量子化 | 248 → ≈280 | 11 |
| `atg_rop_fblend`（新） | f32 の blend | ≈300 | ≈20 |
| `atg_rop_occ`（新） | counter | ≈60 | ≈10 |
| `atg_rop` | wiring（例外） | — | 37 → 39（`occ_count`・`occ_clear`） |
| `atg_rx_clip` | kind、line・point、clamp の平面、CPOLY の呼び出し | 287 → ≈300 | 21 |
| `atg_rx_cpoly`（新） | 多角形の切断（7 平面、10 頂点） | ≈270 | ≈14 |
| `atg_rx_setup` | micro-program の入口、line・point の 2 回の出力 | 437 → ≈320 | 13 |
| `atg_rx_edge`（新） | 整数の step（setup から移す）+ viewport の矩形 | ≈250 | ≈20 |
| `atg_rx_frag` | r3 の clamp の切り替え | p027 の後 ≈260 → ≈263 | 33（変えない） |
| `atg_vf_fetch`・`atg_vf_conv`・`atg_vf_asm` | 大きさと limit、unpack、kind | 332 → ≈360、170 → ≈200、393 → ≈400（**上限**: 超えるなら primitive の出力を子に分ける） | 変えない（幅） |
| `atg_su_exp` | 色 16 word、COLOR1〜3、front | ≈330 → ≈280 | 39 → 30（drain の port を子へ） |
| `atg_su_exp_drain`（新） | drain、beat、`ex_*` | ≈180 | ≈26 |
| `atg_tu_desc` | word 6、ps の plane | part F 171 → ≈190 | 16 → 17 |
| `atg_tu_addr` | ps | part F の分割の後 +≈20 | 変えない |
| `atg_tu_cache` | part、border の印 | 201 → ≈240 | 変えない（幅） |
| `atg_tu_filter` | R8・RG8、D16 | part F の後 +≈20 | 変えない |
| `atg_tu_ffilt`（新） | f32 の filter | ≈300 | ≈20 |
| `atg_tu` | wiring | — | 変えない |
| `atg_cp_seq` | QUERY（待ちの修正と分割は p027、§16.8a） | p027 の後 +≈30 | 38 → 40（上限） |
| `atg_cp_fmt`（新） | FMT の register と ROM | ≈80 | ≈10 |
| `atg_blt_2d`（p027 が名前を変えた 696 行） | **分割**（rd・wr・ctl、S10）、画素の大きさ・KEEP・BLT_COLOR1〜3 | 696 → 3 つの ≤ 300 | 各 ≤ 30 |
| `atg_blt_avg`・`atg_blt_rsv_px`（p027） | RESOLVE の平均 3〜7（avg に組み合わせの平均、sRGB と fp の平均は px が group ごとに数 cycle の stall（ready）で回す） | avg ≈120 → ≈250（超えるなら format の群で分ける）、px +≈40 | 変えない |
| `atg_top` | wiring、`ex_aux`、`occ_*`、`prim_vtx` 26 bit | — | — |

### 16.22 実装の段・LW・順（8 LW ≈ 2〜3 時間）

**追加（2026-10-25 04:28、ユーザー「テクスチャ圧縮も含めて、Vulkan 1.0の必須項目を実装してしまいます。」、P1 の案、Q1 の判断）**

| 段 | 内容 | LW | 依存 |
| --- | --- | --- | --- |
| S11 に追加 | Verilator の harness を KC705 の形（64 B の line、512 bit の AXI、VlWide の 16 word の beat、run.sh の各 mode に -G で KC705 の parameter） | +2（S11 = 9） | — |
| S12 | TU の ETC2+EAC（§16.11a）: `tools/etcmodel.py`（5 つの色の mode、punch-through、EAC の alpha と R11/RG11 の UNORM/SNORM、--selftest）、`atg_tu_etc`（新）、`atg_tu_addr` の block の address、`atg_tu_cache` の block の part、bilinear の pass（16 byte の block は 4、8 byte は 2）、`atg_tu_desc` の block の plane、FMT の ROM、`textureCompressionETC2` = 1、scene (17) | 9 | S9 |
| S13 | varying 64 component（U59）: KC705 の SU_VARY_WORDS 32 → 64、PT の entry、`atg_su_lda` の primitive table（複製を NPHYS/4 から 2 にして読みを 2 cycle に、BRAM の対策、S1 の spec で）、`atg_rx_frag` の index、limit の表（§3.7 の「128」の誤りも）、scene (18)、`make oxc-core` の BRAM の数（T）。BRAM が合わなければ N の見直しをユーザーに諮り、この段は uncleared で止める | 7 | S8、p027 の SU・RX の段の merge |
| S14 | TU の slot を stage ごとに 16（U60）: **案 A**（Q1 の判断）: STATE を 1024 index に広げ、0x200〜0x2FF を vertex の stage の 16 slot × 16 word、fragment と compute は今の 0x090〜0x18F、tex の命令は warp の種類で bank を選ぶ、`atg_cp_state` 512 → 1024 word、SET_REG の fault の境 1024、`atg_tu_desc` を 32 slot に、SU → TU の要求に stage の bit。案 B（descriptor を memory の table に置き TU が cache する）は後の拡張の候補 | 6 | S9、p027 の cp_seq・cp_state の merge |

| S15 | shared memory（LDS）の atomic（2026-10-25 07:12 Q1 追加、p010 で見つかった Vulkan 1.0 core の食い違い: Workgroup の OpAtomic*）: GSI1 の命令（`atom` の LDS の形か新しい sub）、`atg_su_lds` の read-modify-write、gsi1asm・gsi1dis・gsi1model、compiler の lowering、TB | 4 | — |
| S16 | TU の row pitch（2026-10-25 08:10 Q1 追加、p018 の P2 の報告: firmware は 1x の attachment の image の各 level の幅を偶数に丸める（ROP の行の規則）ので、奇数の幅の attachment を TU が読み違える）: texture の slot に行の byte 数の word（+7、0 = 詰めた行）を足し、`atg_tu_desc`・`atg_tu_foot`・model・TB を合わせる。`include/ghci_layout.h` と合わせる | 2 | S9・S14 |

計 103 LW（±35%）。S12 は S9 の後、S13 は S8 の後、S14 は S9 の後（S13 と S14 は並行可）。S11（統合）は S2〜S14 の全部の後。

- **S13 の実装で決めた事**（2026-10-25 P1、amaterrace-gpu の spec §10 にも。Vulkan 1.0 の 64 component の原則で）: (1) primitive table は varying の word だけを持つ（position の 4 word は RX が写さず、どの program も読まない）。`lda` の PT word 0〜3 は 0 を読む（旧は書かれない word で不定）。(2) `pw_addr`[5:0] は varying word w（旧は PT word 4 + w で、6 bit では w ≤ 59 しか書けなかった）。`fl_pw_addr` の 12 bit と d_s の 0xFF8〜0xFFB はそのまま。(3) `lda` の immediate の word を [8:2] の 7 bit（PT word 0〜127）に、[31:9] は無視、gsi1asm は 0〜511 の外を拒む。`GSI1_LDA` の mask を 0x7F、`gsi1_isa.h` に `GSI1_VARYING_WORDS` 64。(4) table の複製は min(NPHYS/4, 2)、同期の読み（BRAM の推論）で 1 lane group を NR cycle（NPHYS 4・8 は 1、16 は 2、32 は 4）、x_ready は後の cycle で 0（他の unit の group はその cycle に出てよい）。結果は group を取った cycle から SHORT_LAT で変わらない。lda の速さは NPHYS 16 で半分（fragment の varying の読みは 1 component につき lda 3 つ）。(5) VARYING_COUNT は 32 bit の値を比べて 64 を超えたら 64（旧は [5:0] だけを見て 32 で切っていた）。GHCI: CAPS[30] で 64、無しで 16。(6) compiler の口: `ghci_gsi1_options.varying_words`（GPU の varying word、0 と 64 超は 64）、location の word がそれを超えたら word 無し、clip w の word が超えたら EINVAL。(7) `gsi1model --prims` の file は vertex ごとに 128 word（PT word 0〜127）、lda は 4 ≤ word < 4 + --vary だけ読む。
- **S16 の実装で決めた事**（2026-10-25 P1、Vulkan 1.0 の原則で。amaterrace-gpu の `docs/ghci.md` §8.4・§8.5）: word +7 は行の byte 数ではなく `TEX_ROW`[1:0]（linear の各 level の行 = w_l を 2^n texel の倍数に切り上げ、0 = 詰めた行、1 = attachment の偶数の行）。`ghci_layout.h` は各 level を偶数に丸めるので、1 つの byte 数では level 1 以降と TU が計算する O_l が合わない。tiled・圧縮・multisampled では無視。firmware は `TEX_ROW = attachment ? 1 : 0`。
- **S11 の実装で決めた事**（2026-10-25 P1、Vulkan 1.0 の原則で）: (1) CAPS[30] は `atg_top` が導く CORE1 = VF・RX・ROP・TU・SU が有り `SU_VARY_WORDS` ≥ 64（KC705 の形。既定の形と varying の少ない形は 0）。CORE1 は `atg_cp` の新しい parameter `CORE1`（CAPS[30] と CAPS[9]（stencil、dtest は ROP に常に有る））と `HAS_FMT` へ。MS4 は CAPS[30] の条件に入れない（GHCI の CAPS[30] の定義に multisampling は無く、CAPS[29] が別に言う）。(2) scene は KC705 の形だけ（Q1 の指示。§16.20 の「2 つの形」の ZYBO の形は流さない）、RT は 32×24（一部 16×12。§16.20 の 64×48 は iverilog の時間のため小さくした）、memory 1 MiB・aperture 0x20000〜0xF0000（scene の harness に `MEM_LOG2`・`APER_LIMIT`）、ring 32 KiB。(3) scene の case は 22（§16.20 の (1)〜(18) の全部、depth bounds、vertex の stage の slot と TEX_ROW）、各 case の image を model と word ごとに、加えて FMT capability の 256 format の word（`F` 行）。(4) Verilator の harness は全部の mode を KC705 の形（64 byte の line、512 bit の AXI、VlWide の 16 word の beat、KC705 の SU を -G）で、新しい mode `core`。(5) `GHCI_CAPS_CORE1`・`GHCI_XCAP_FMT`・`GHCI_FMT_*` を `ghci_regs.h`・`.vh` に（zedBSD の写しの header は未更新）。
- **S13 の残り**: (a) 64 component を全部書く vertex program は compiler が出力を最後にまとめて export するので register が 64 を超えて拒まれる（16 location × 4 は regs=64 でも「register が足りない」で拒まれた）。出力を最後の書き込みの後に export する（直線の code）か spill が要る: p010 の compiler の範囲（Q1 に依頼）。host 試験は location 13〜15 だけ書く vertex と 16 location を全部読む fragment。(b) scene (18) は S11 の `atg_top_core_tb` で。(c) KC705 の BRAM の実測（`make oxc-core`）は T。


| 段 | 内容 | 受け入れ | 依存（衝突を避ける順） | LW |
| --- | --- | --- | --- | --- |
| S1 | `atg_fmt_*.vh`、`srgb-tables.py` と `atg_srgb.vh`、`fmtmodel.py --selftest`、`atg_fmt_tb`・`atg_fmt_srgbenc` と TB、Vulkan の必須の表の事実の bit の列（`tools/vk-required-formats.txt`、出典つき）、**全部の p030 の module の spec の §3〜§8 を先に**、GHCI の draft の直し、`make sim` の PASS の行を数えて記録 | `PASS fmtmodel.selftest`、`PASS atg_fmt`、`PASS atg_fmt_srgbenc`、spec の port の表が ≤ 40、lint | この設計の review と **U47〜U59 の回答**。**p027 と並行可**（新しい file だけ） | 6 |
| S2 | VF: format（ATTR_DST[31:24]）、ATTR_LIMIT（[31] 有効、33 bit の比較）、R32G32B32、`prim_vtx` の kind（0x1C0〜0x1DF の VF 待ちが p027 の修正に無ければここで 1 行） | VF の PASS、MUT、lint | S1。**p027 と並行可**（VF は p027 に無い） | 4 |
| S3 | RX clip: kind、w ≥ ε、near・far（DEPTH_CLIP）、line・point、depth clamp、guard band（triangle と line、`atg_rx_cpoly`、10 頂点）、last-use の flag の規則、DISCARD | clip の PASS（32・64）、MUT、lint | S1、S2（kind）。**p027 と並行可**（clip は p027 に無い） | 7 |
| S4 | RX setup: 分割（`atg_rx_edge`）、line・point の sub-triangle と plane、viewport の矩形、depth bias、`sp_tri` の kind（幅は変えない）、`rx-ucode.py` | setup の PASS、`PASS vecdiff.rx_setup`、MUT、lint | S3。**p027 と並行可**（setup は p027 に無い） | 7 |
| S5 | CP: µop 14 `QUERY`、`atg_cp_fmt` と FMT capability（待ちの修正は p027、§16.8a） | CP の PASS（`atg_cp_seq.query`、`atg_cp_regs.fmt`）、MUT | S1、**p027 の `atg_cp_seq` の修正の merge の後**（同じ file） | 3 |
| S6 | ROP: `atg_rop_fblend`、`atg_fmt_pack` の ROP の使い方、`atg_rop_blend` の R8・RG8・1555・fp32 constant（`ROP_CTRL`[1]）、`atg_rop_occ` | fblend・blend・occ の PASS | S1。**p027 と並行可**（blend は p027 に無い。`atg_rop`・`atg_rop_wb` の結線はまだしない） | 6 |
| S7 | ROP depth: `atg_rop_dtest`、`atg_rop_ds`（stencil・D16・bounds）、`atg_rop_ms`（clamp、`DEPTH_CLAMP`[1]）、`atg_rx_frag` の r3 の clamp の切り替え、`ex_aux` の front（exp と ROP の結線） | dtest・ds・ms の PASS、`PASS vecdiff.*`、MUT | S4、S6、**p027 の S2・S3・S4 の merge の後** | 7 |
| S8 | MRT: `atg_su_exp` の分割と COLOR1〜3・beat・`ex_aux` の beat の bit、order・ms・ds の beat、`atg_rop_wb` と `atg_rop_wpix`（RT ごとの state、ps 1〜16、複数の line、揃えの assert）、gsi1 の道具の color1〜3 | exp・wb の PASS、MUT | S7、**p027 の S1・S3・S4・S6 の merge の後** | 11 |
| S9 | TU: TEX_FORMAT、`atg_tu_desc`、`atg_tu_addr` の ps、`atg_tu_cache` の part、`atg_tu_ffilt`、D16、stencil の aspect、swizzle、border、565 の filter（p027 の S5 の 565 を統合） | TU の PASS、MUT | S1、**part F と p027 の S5 の merge の後** | 12 |
| S10 | BLT: **`atg_blt_2d`（p027 が名前だけ変えた 696 行）の分割**（rd・wr・ctl に、U38。担当が無いので S10 に入れた、review 2 の H4）、画素 8・64・128 bit、KEEP、BLT_COLOR1〜3、RESOLVE の平均 3〜7（p027 の `atg_blt_avg` と `atg_blt_rsv_px` に、review 2 の M1）、p027 の ghci.md §8.2 の「Amaterrace: 0-2」「6-15 Refused」を「0-7」「8-15」に | BLT の PASS（`atg_blt.keep`・`.ps`・`.resolve_fmt`）、既存の BLT の TB が変えずに PASS | S1、**p027 の BLT の段の merge の後** | 9 |
| S11 | `atg_top`（結線、CAPS[30]）、`atg_top_core_tb` と scene、Verilator の mode、README の ROP・RX・TU・VF・BLT の行、`docs/ghci.md` の draft の確定（p027 の §12.11 の r3 の文を含む） | §16.20 の scene の全部（2 つの形）、`make lint` clean、`make sim` の PASS の行が S1 の数より減らない、`make verilator` PASS、既存の scene が変えずに PASS | S2〜S10 | 7 |
| 計 | | | | **79 LW**（±35%: 51〜107） |
| （範囲の外）S12 | TU: ETC2・EAC（§16.11a）。2026-10-25 ユーザー「圧縮テクスチャはPCIe GPUの実機bringupの後に回します。」→ Q1 が p028 の後の別の Phase に | — | S9 | （≈9、合計に入れない） |

- **並行**: S2〜S4・S6 は S1 の後に互いに並行でき、p027 の実装（P2）とも並行できる（ユーザーの「N=2でもう１つサブエージェント」）。S5 は p027 の `atg_cp_seq` の修正の後、S7・S8 は p027 の ROP・SU・RX の frag の段の merge の後、S9 は part F と p027 の S5 の merge の後、S10 は p027 の BLT の段の後。循環は無い（p030 は p027 に依るが、p027 は p030 に依らない）。
- **衝突する file**: `include/ghci_regs.vh`・`ghci_regs.h`（STATE の index。行の追加の merge）、`docs/ghci.md`（CAPS の表の [29]・[30] の行、§8.2 の BLT の表、§12.11・§12.12）、`README.md`、`atg_top.v`・`atg_rop.v`・`atg_su.v`（wiring）、`tools/rxmodel.py`・`tumodel.py`・`gsi1asm.py`。Q1 が merge の順で合わせる。
- 板と timing は対象外（p024・p025）。
- **LW の増え方**（版 6 の最初の 68 から 79）: S3 の w・far の平面と line の guard band +1、S8 +2・S9 +2（review 1 の 35 の見積もりの直し）、S10 の BLT の分割 +3 と RESOLVE の平均 +2、S11 +1。S5 の待ちの修正は p027 へ（Q1）、S12 の ETC2 は範囲の外へ（ユーザー）。

### 16.23 選ばなかった案と理由

| 案 | 理由 |
| --- | --- |
| GHCI 独自の format の番号（compact な 6 bit） | firmware に VkFormat → 番号の表が要り、GHCI は既に Vulkan の enum の番号を使う流儀。8 bit で core が入る |
| format の対応を driver の静的な表に（FMT capability 無し） | vendor に依らない driver（§2.1 の「汎用」）にならない。hardware の case と表が食い違う risk（R23 と同じ種類） |
| MRT を 2048 bit の bus で（beat にしない） | order・ms・ds・wb の FF と mux が 4 倍。MRT を使わない draw の速さは同じなので利点が無い |
| MRT を ROP が SU に色を引きに行く（pull） | exp と ROP の間に attachment ごとの要求と応答の handshake が要り、slot の寿命の論（§3.8）が変わる |
| 全部の format を f32 の blend で（u8 の道を外す） | 今の vector が変わり、RGBA8 の速さが 1/8 になる。u8 の道は正確（8 bit の UNORM の blend は 8 bit で足りる） |
| sRGB の encode を多項式・pow の近似で | 正しく丸めた code を保証できない。閾値の 2 分探索は表 255 word と 8 cycle で正確 |
| point・line を VF で 2 つの三角形に展開 | VF は画面の座標を知らない（parallelogram の角は viewport の変換の後に決まる）ので、vertex shader の後でないと作れない。展開した頂点は PT の entry と warp の lane を 2〜4 倍使う。setup で sub-triangle を作れば PT も warp も今のまま |
| line を Bresenham で | Vulkan は non-strict に parallelogram か Bresenham を許すが、MS の line は parallelogram の方が sample の coverage の今の回路（edge 関数）にそのまま乗る |
| PointCoord を新しい register（r10・r11）に | RX の frag に plane の評価が 2 つ増える。b0/w・b1/w の plane を PointCoord にすれば演算も port も増えない。compiler は point の pipeline を知る |
| far を fragment の段で（RX の frag の sample ごとか ROP） | 版 6 の途中の案。RX の frag では z が分かる時に quad が warp に入っていて、被覆を後から消すと exp の drain が後ろの quad を落とす（review 2 の H1）。minDepth = maxDepth の viewport で far が効かない（H2）。ROP では clip の外の fragment が副作用を持つ（review 1 の 8）。geometric な平面 1 つ（多角形 +1 頂点）でどれも起きない |
| far の clip を w ≥ ε 無しで（z ≥ 0 だけ） | z_c > 0 かつ w_c < 0 の頂点が通る（review 3）。clip volume の z ≤ w と z ≥ 0 の組で初めて w ≥ 0 |
| BC か ASTC を必須の圧縮の組に | BC は BC6H・BC7 の mode と partition の表が重く、ASTC は block の大きさと grid が可変で最も重い。ETC2 + EAC は 10 format、decoder ≈1.5k LUT（U58） |
| 64・128 bit の FILL を pattern で（最初の版） | 画素の大きさ 64・128 bit の方が RESOLVE（Q1 の依頼の 8 byte の画素）と COPY と同じ field で済み、位相の問題（review 27）も無い |
| depth bias を ROP で足す | m（plane の係数）と r（3 頂点の z の指数）は RX が持つ。FragCoord.z は bias の後の値なので RX の plane に入れる必要がある |
| RX が TOPOLOGY と ROP の DEPTH を snoop | §16.9: VF・ROP の範囲の SET_REG は RX の busy を待たないので前の draw を読み違える |
| input attachment を TU の slot で | slot が 20 要る（16 + 4）。descriptor の STATE が全部埋まっている |
| storage image に TU の store の道を足す | format が SPIR-V で分かるので compiler の `lw`/`sw` で足りる（列 St の format は 4 byte の倍数） |
| guard band の clip を firmware か driver で | 頂点は SU が計算した後に分かるので host では出来ない。RX の中で行う |
| stencil を STENCIL parameter の外の別の block に | ds は stored の word を既に読んでいるので、byte 3 の判定を足すだけ（別の block は同じ line をもう一度読む） |
| depth だけの clear を ROP の draw だけで | render pass の外（`vkCmdClearDepthStencilImage`）にも要り、BLT の KEEP（byte enable の AND）は小さく速い |
| integer の color attachment を 1 sample だけに（最初の版の U54） | `capabilities.adoc` の SAMPLED の規則が整数の color の format にも sampledImageColorSampleCounts を当てると読める（review 1 の 24）。ROP は format に依らず resolve は SAMPLE0 なので 4x を出す方が安全 |

### 16.24 U 項目（ユーザーの判断。推し付き）

**回答（2026-10-25 04:10）**: ユーザー「U項目は推しでOKです。U57について、ZYBOはもう合成しません。ターゲットから外し、ソースは docs/old/ 以下に移します。」 → U47〜U60 は推し。U57 は無くなった: ZYBO は GPU の target から外し、source は amaterrace-gpu の `docs/old/` へ（[p031](phase031/phase.md)）。

| U | 問い | 推し | 他の案 |
| --- | --- | --- | --- |
| **U47** | STATE の format の番号を VkFormat の値にし、0 を今の field（legacy）にするか | **する**（firmware の表が不要、GHCI の流儀、今の試験が変わらない） | GHCI 独自の 6 bit の番号 |
| **U48** | format の対応を GHCI の FMT capability（id 10、hardware の固定機能の表を driver が読む）で出すか | **出す**（vendor に依らない driver、表と hardware の食い違いを防ぐ。shader の道の bit は driver が足す） | driver の静的な表 |
| **U49** | v1 で出す任意の feature | **depthClamp・depthBiasClamp・depthBounds・independentBlend・occlusionQueryPrecise・fullDrawIndexUint32・drawIndirectFirstInstance・alphaToOne（p027）を 1、他（logicOp・dualSrcBlend・wideLines・largePoints・fillModeNonSolid・multiViewport・shaderClip/CullDistance・pipelineStatisticsQuery・samplerAnisotropy・sampleRateShading（U43）・textureCompression*（ETC2 は後の Phase、U58））は 0。fragmentStoresAndAtomics・vertexPipelineStoresAndAtomics は p010 で決める（depth の clip は geometric なので、どちらでも正しい）** | logicOp も 1（ROP の bit 演算 ≈0.3k LUT） |
| **U50** | p030 の RTL の外の core の欠け（storage image・texel buffer・input attachment の compiler の道、robustBufferAccess の SU の道、uniform buffer 16 KiB、indirect、event、secondary の command buffer、複数の subpass、query の command、内蔵の blit の draw）をどこで扱うか | **p010（compiler）・p018（firmware）・p019（driver）の範囲に足す**（§16.16 の列。Q1 が各 Phase の範囲と LW を直す。p030 の受け入れの item 8・10 は「GHCI の口と記録」まで） | 新しい Phase（「shader の資源と command の core の残り」）を p018 の前に |
| **U51** | input attachment の作り方 | **compiler の `lw` の道**（TU の slot を使わない、RTL 無し） | TU の slot（slot を 20 に増やし descriptor の STATE を広げる） |
| **U52** | blend constant を fp32 × 4（0x087〜0x08A）にし、`ROP_CTRL`[1] で選ぶ（0 = 今の 0x07B の RGBA8） | **する**（f32 の blend の format に要る。0 = 以前の動作で今の試験が変わらない） | 0x07B を消して fp32 だけ（既存の TB を直す） |
| **U53** | depth の clip（near と far）を RX の clip の geometric な平面で行い、`DEPTH_CLAMP`[1] = 1 の時は 1x の r3 も clamp しない（p027 は 1x の clamp を残した）。clamp は ROP | **この形**（Vulkan の clip の正しさ、副作用無し、minDepth = maxDepth でも効く。[1] = 0 は今の動作） | far を fragment の段で落とす（§16.23） |
| **U54** | integer の color attachment の sample の数 | **1\|4**（`capabilities.adoc` の SAMPLED の規則が整数の color の format にも当たると読める。ROP は format に依らず、resolve は SAMPLE0。review 24 で推しを変えた） | 1 だけ |
| **U55** | point と line の幅は 1 だけ、PointCoord は point の warp の r0・r1（b0/w・b1/w の plane）、point の varying は compiler が頂点 0 から読む | **この形** | PointCoord を r10・r11 に（RX の演算が増える） |
| **U56** | guard band の外の x・y の clip を p030 で入れるか | **入れる**（S3。triangle と line。大きな地面の三角形などで形が変わる） | 後に回し、v1 の app は guard band の中だけ |
| **U57** | ZYBO の raster の bitstream に p030 の論理が入らない時 | **今は parameter で外さず、p007 の再合成で入らなければ `FMT_FULL` を足す** | 最初から `FMT_FULL` の parameter |
| **U58** | 1.0 の必須の圧縮の format の組（**実装は p028 の後の別の Phase**: 2026-10-25 ユーザー「圧縮テクスチャはPCIe GPUの実機bringupの後に回します。」） | **ETC2 + EAC**（10 format、decoder ≈1.5k LUT、≈9 LW。§16.11a） | BC（BC6H・BC7 が重い）、ASTC LDR（最も重い） |
| **U59** | varying の 64 component（`maxVertexOutputComponents`・`maxFragmentInputComponents` の最小）。今は KC705 で 32 word | **p030 の外の新しい項目**（PT の entry と primitive table を 4 + 64 word に。KC705 の BRAM が N=6 で ≈+96 BRAM36（§3.6 の 347 → ≈443 / 445）と限界なので、primitive table の複製の削減か N の見直しと一緒に p015 の前に決める）。それまで v1 は「規格に合わない点」として記録 | p030 で PT を 64 word に（BRAM の見積もりと N の決定が先に要る）。**2026-10-25 S13 で実装**: table の複製を 2 に減らして BRAM は増えない（推定 SU ごと −4 BRAM36）、N の見直しは不要の見込み（oxc-core の実測は T） |
| **U60** | TU の 16 slot が pipeline の全 stage で 1 組（vertex 16 + fragment 16 の pipeline は不可。`maxPerStageDescriptorSampledImages` は stage ごと） | **v1 は「規格に合わない点」として記録**し、slot の増設（descriptor の STATE を広げる）か stage ごとの bank を p015 の前に決める（STATE の 0x090〜0x18F が全部埋まっているので GHCI の変更が要る） | p030 で slot を 32 に（STATE の範囲の作り直し） |

### 16.25 license と転記

- この設計と amaterrace-gpu の追加はどちらも Zlib（既存と同じ）。
- Vulkan の仕様（Khronos の Vulkan-Docs、**CC-BY-4.0**、`LICENSE.adoc` で確かめた）: format の必須の表の印、VkFormat・VkStencilOp・VkComponentSwizzle・VkFormatFeatureFlagBits の番号、limit の値、式（depth bias、line の t、PointCoord）、UNORM/SNORM の変換の式は**事実の値**として使い、§16.1・§16.2 の短い引用は出典（章）を明記した。表の構造と文は写さない（§16.2 の表は自前の形に並べ直した）。`vk.xml`（Apache-2.0 OR MIT）からは番号の事実だけを読み、file は取り込まない。
- sRGB の表は sRGB の式から自前の script が計算する（他の実装の表を写さない）。ghci.md と RTL の comment には「Values referenced: Vulkan specification (Required Format Support, VkFormat, Depth Bias Computation, Basic Line Segment Rasterization, Basic Point Rasterization)」と書く。
- Mesa など他の driver の code は読んでいない・写さない。


### 16.26 review の指摘と対応（design-reviewer、2026-10-25、35 件: Critical 2・High 4・Medium 16・Low 13）

全文は [design-review-p030.md](design-review-p030.md)。

| # | 重さ | 指摘（要点） | 対応 |
| --- | --- | --- | --- |
| 1 | Critical | BC・ETC2・ASTC の 1 組の SAMPLED・BLIT_SRC・FILTER_LINEAR は 1.0 の必須（BCn の表の注）なのに「任意・0」 | 確かめて受けた（`formats.adoc` の注は版の ifdef の外）。§16.1・§16.2 を直し、ETC2 + EAC を §16.11a・S12・U58 に |
| 2 | Critical | RX・ROP の範囲の SET_REG の待ちが上流に居る前の draw を守らない（`atg_cp_seq.v` 212〜215・263 行） | 確かめて受けた。§16.8a（VF・SU・RX・ROP を待つ、0x1C0〜0x1DF）、EndQuery は `QUERY` を先に、S5、`atg_top_core.backtoback`、p027 の §15.6 の前提も同じと Q1 に連絡 |
| 3 | High | w ≤ 0 の頂点が z ≥ 0 の near の clip を通る（reversed-Z） | 受けた。clip の平面 1 = 常に w ≥ ε（§16.9）、`atg_rx_clip.wneg` |
| 4 | High | BLT_COLOR1〜3 = 0x00B が p027 の BLT_RESOLVE と衝突、4x の format の resolve の道が無い | 受けた（Q1 の依頼と同じ）。0x00C〜0x00E に移し、画素 8・64・128 bit と平均 3〜7 を §16.12・S10 に、format ごとの code を §16.2 に |
| 5 | High | varying 64 component の limit を満たさず表にも無い | 受けた。§16.1 に行、§3.7 の「128」の誤りを記録、U59（p030 の外、BRAM と N の決定と一緒に） |
| 6 | High | ATTR_LIMIT（0x1D0〜）の SET_REG が VF を待たない | 受けた。§16.8a・§16.10、`atg_cp_seq.attrlimit_wait` |
| 7 | Medium | ATTR_LIMIT = 0 を「制限無し」にすると 0 byte の limit が無制限に化ける | 受けた。[31] 有効の bit（§16.10） |
| 8 | Medium | depth の clip を shading の後に行うと clip の外の fragment が副作用を持つ | 受けた（案 a）。RX の frag で sample ごとに shading の前（§16.9）、ROP は clamp だけ（§16.6）、o を ROP に運ばない |
| 9 | Medium | line に guard band の clip が無い | 受けた。line の t の clip に guard band（§16.9）、`atg_rx_clip.guardline` |
| 10 | Medium | sub-triangle と fan の last-use の flag | 受けた。最後の 1 つだけ（§16.9）、spec の §7 と TB |
| 11 | Medium | base と stride の揃えが ps 8・16 と複数の line に合わない | 受けた。base 64、stride min(2·S·ps, 64) の倍数（§16.7）、GHCI の表 |
| 12 | Medium | 「0 は以前の動作」が direct の道と既存の TB で破れる（depth の clip、viewport の矩形、U52） | 受けた。`DEPTH_CLAMP`[1]、`RAST_MODE`[3]、`ROP_CTRL`[1] の enable の bit、DRAW_RAW は矩形を使わない |
| 13 | Medium | FMT の ROM が hardware に無い機能まで答える、parameter、窓の大きさ | 受けた。固定機能の bit だけ、`MS4`・`FMT_FULL` で作る、0x160〜0x17F（§16.4・§16.15） |
| 14 | Medium | `vkCmdBlitImage` の dst の作り方が無い | 受けた。ROP の内蔵の draw（§16.16） |
| 15 | Medium | SU の exp の色の RAM の量の見積もりが小さい | 受けた。SU ごとに ≈1.5k LUT（N=6 で ≈9k）、BRAM の案（§16.19） |
| 16 | Medium | `atg_cp_seq` は既に 409 行 | 受けた。S5 で `atg_cp_seq_wait` に分割（§16.8a） |
| 17 | Medium | S7 が S8 で作る `ex_aux` を使う | 受けた。front は S7、beat の bit は S8（§16.13・§16.22）。o は不要になった |
| 18 | Medium | 内蔵の draw が occlusion の数に入る | 受けた。前後で `ROP_CTRL`[0] = 0（§16.8・§16.16） |
| 19 | Medium | D32F の bias の e を fan の三角形ごとに求める | 一部受けた。元の 3 頂点の案は w ≤ 0 で使えないので採らず、制限 R35 と Future Work に（§16.9） |
| 20 | Medium | 試験が捕まえない誤り（同じ case の自己照合、同じ人の model、state の競合、w < 0、line の guard band、ATTR_LIMIT の境） | 受けた。Vulkan の必須の表の事実の bit の列との照合、fp16 は Python の `struct` を独立の参照に、`backtoback`・`wneg`・`guardline`・`limit0`、MUT を足した（§16.20） |
| 21 | Medium | item 8・10 に model・TB・scene が無い、他の Phase の範囲 | 受けた。phase.md の受け入れを「item 8・10 は GHCI の口と記録」に直し、移管は U50 と Q1 への依頼 |
| 22 | Medium | p027 の §12.11 の r3 の文、§8.5 の a2c の順 | 受けた。S11 で §12.11 に `DEPTH_CLAMP`[1] の場合を足す、§8.5 の順を直した |
| 23 | Low | A8B8G8R8 の行に STORAGE の必須は無い | 受けた。行を分けた（§16.2） |
| 24 | Low | 整数の format の SAMPLED の 4x の要否 | 受けた。U54 の推しを 1\|4 に変えた |
| 25 | Low | CAPS[9] と CAPS[30] の重なり、state layout の版 | 受けた。意味の分け方と版を上げない理由（§16.15） |
| 26 | Low | GHCI §8.5 の待ちの出典の文 | 受けた。§8.5 の冒頭を本当の規則に |
| 27 | Low | FILL の pattern の位相 | pattern の field を外した（画素の大きさで FILL、§16.12） |
| 28 | Low | R8・RG8 の dst の alpha、NaN・負の pack | 受けた（§16.4・§16.7） |
| 29 | Low | viewport の x・y・幅・高さを整数に丸める | 受けた。firmware（§16.9・§16.16） |
| 30 | Low | 丸めの規則を GHCI の標準で縛っている | 受けた。「Amaterrace:」の注に（ghci.md §8.5） |
| 31 | Low | line の重みは「primitive の頂点 0・1」 | 受けた（§16.9・ghci.md） |
| 32 | Low | 長さ 0 の line | 受けた。捨てる（§16.9・§16.18） |
| 33 | Low | uniform texel buffer の offset の揃え | 受けた。`minTexelBufferOffsetAlignment` 256（§16.14・§16.16） |
| 34 | Low | U47〜の回答が無い | 受けた。S1 の依存に「U47〜U59 の回答」 |
| 35 | Low | LW が楽観的、Begin の `QUERY` の待ち | 受けた。68 → 88 LW（§16.22）、Begin の `QUERY`(flags 1) は待たない（§16.8） |

**2 回目**（design-reviewer、2026-10-25、23 件: High 4・Medium 5・Low 14、Critical 0）と、その間の Q1 の 2 つの決定（CP の待ちの修正は p027 へ、ETC2 は範囲の外へ）:

| # | 重さ | 指摘（要点） | 対応 |
| --- | --- | --- | --- |
| H1 | High | frag で quad の被覆を後から消すと exp の drain（`atg_su_exp.v` 137 行の `dlast`）が後ろの quad を落とす | 受けた（案 a）。far も geometric に clip し、frag の sample ごとの clip を止めた（§16.9） |
| H2 | High | minDepth = maxDepth の viewport で far の clip が効かない | 受けた。同上。scene (15) |
| H3 | High | TU・program の範囲と LOAD_CONST にも同じ待ちの hazard、GHCI の文が言い過ぎ | 受けた。§16.8a に記録し、p027 の修正に入れるよう Q1 に依頼、GHCI の文を絞った |
| H4 | High | S10 が担当の無い BLT の分割を待つ | 受けた。分割を S10 に入れた（+3 LW） |
| M1 | Medium | RESOLVE の変更の場所が p027 の module の構成（`atg_blt_avg`・`atg_blt_rsv_px`）と合わない | 受けた（§16.12・§16.21） |
| M2 | Medium | RESOLVE の src の stride の規則と RT の stride の規則の食い違い | 受けた。stride は 2·S·ps の倍数に揃えた（§16.7・GHCI） |
| M3 | Medium | ETC2 の 16 byte の block の bilinear の道 | 受けた。pass の形を §16.11a に（実装は後の Phase） |
| M4 | Medium | S8 の copy の kernel が region の外の byte を壊す | 受けた。端の word は `atom` の AND・OR で（§16.12） |
| M5 | Medium | TU の 16 slot を stage で分け合う | 確かめた（slot は STATE の全体で 1 組）。§16.1 に行、U60 |
| L1〜L14 | Low | 前の版の名残（§16.3・§8・§16.1・§16.20・§16.21）、§16.23 と U54 の矛盾、fan の数、S10 の依存、ε の絶対値、ATTR_LIMIT の比較の幅、CAPS[30] の ETC2、TEX_BASE の揃え、firmware の pack の照合の相手、EAC と punch-through、GHCI の RESOLVE の参照、guard band の平面の形、host の STATE の書き込みの規則、rasterizerDiscard | 全部直した（ε は R36 として記録、guard band は除算無しの形、DISCARD は RAST_MODE[6]、host の書き込みは p027 の待ちの規則に従うと GHCI に） |

- Q1（2026-10-25）「`atg_cp_seq` の RX・ROP の範囲の SET_REG の待ちの直し（§16.8a）は p027 の P2 の範囲に移した。p030 の S5 からは外し、§16.8a は『p027 で直す（前提）』と書き換えてください。」→ §16.8a・S5。1 回目の表の 2・6・16 の「S5 で」はこの決定で p027 へ移った。
- ユーザー（2026-10-25、Q1 経由）「圧縮テクスチャはPCIe GPUの実機bringupの後に回します。」→ §16.11a・S12 を範囲の外に、合計 88 → 79 LW。1 回目の表の 1 の「S12」は後の Phase へ。

## 17. session の保護（GHCI §11.6、PROT capability。版 7、ws001-p034 の設計の段）

2026-10-25 P1（ws001-p034、q1570-i01、zedBSD の worktree p1-p030（基点 main 485108a30）、amaterrace-gpu の worktree p1-p030b（main 492ff1e を merge した 84eb577 の上、S16 の dc471f9））。承認: 2026-10-25 08:57 ユーザー「了解です。せっかくなので実装してしまってください。」（Q1 が buffer の context ID（GHCI §11.6 の session の保護）は未実装と答えた後）、同日「ゴールまで推しで進んでよいです。判断に迷ったら、Vulkan 1.0の原則論で進めてください。」（[phase034](phase034/phase.md)）。この節は設計だけで、RTL・firmware・driver は書かない（実装の段は Q1 が後で割り当てる）。review の指摘と対応は [design-review-p034.md](design-review-p034.md) と §17.21（1 回目 33 件: Critical 2・High 5・Medium 16・Low 10、2 回目 21 件: Critical 1・High 3・Medium 6・Low 11。全部を本文に反映した）。

### 17.0 出典と確認の水準

- **読んだ物（実測）**: amaterrace-gpu の `docs/ghci.md` §3.4（FAULT_INFO: kind 1 =「aperture の外、または session に許されない」、[11:9] は空き）、§4（PROT は id 9）、§5、§7.1〜§7.3（job tag は dword0[23:16]、class 2 の job tag が session、ring-only の 4 つの gpu-op、µop 0〜14）、§9.1（complete な FENCE）、§10、§11.1〜§11.6（PROT の draft）。`spec/gpu/mc/atg_mc.md`（root が 1 本の AXI の前で aperture と window を検査、assembly buffer は 1 つ、`err_v`、拒否の `rsp_rdata` は「AXI master の最後の read の data」、DC は `ROOT_CLIENT` で優先、外に出す idle は `axi_idle` だけ）、`spec/common/am_amb_to_rt.md`（header の bit 3 は 0、末尾は 0 の余り、header は request の間 入力から作り直す）、`rtl/gpu/top/atg_top.v`（client: 0 CP（ring・fence・dbg を `am_amb_mux`）、1 BLT、CPU、VF、TU、ROP、ATOM、SA、EXT（KC705 の DC）、SU ごとに D$ と I$+定数）、`spec/gpu/cp/atg_cp_seq.md`（ring と UOP_FIFO の µop は同じ sequencer、`fw_active` の間は firmware の物だけ、`inv` 4 bit、fence unit の `f_*`、cmd_active と watchdog）、`atg_cp_seq_wait.md`、`atg_cpu_win.md`（PKT_INFO の JOB_TAG、UOP、DMA_*、sub-bus 0x10〜0x3F、**「µops written outside a packet wait for the next one」**、DONE は FIFO が空になるのを待つ）、`atg_cpu_dma.md`、`spec/gpu/su/atg_su_{dcache,rf,lds,cbank,pt,lda}.md`（D$ は write-through、RF は NWARPS × NREGS × 32 lane で「No reset of the contents」、LDS は KC705 16 KiB・1 word/cycle、cbank 256 word、PT は 64 entry × 68 word の 16 bank、lda の primitive table は KC705 で 2 copy × 6144 word）、`spec/gpu/rop/atg_rop_wb.md`（idle の 16 cycle で dirty を書き空にする）。P2 の firmware（`p2-p018` 2ce0fe6、読むだけ）: `fw/cp/cmd.c`（SESSION_OPEN は flags ≠ 0 を FEATURE_NOT_PRESENT、GRANT/REVOKE は unsupported、MEMORY は frame の中でも受け、object の作成は失敗し得る）、`heap.c`（driver が貸す heap、line 単位の first fit、中身は消さない、FW_SESSIONS 32）、`builtin.c`（heap の先頭に identity buffer・内蔵の GSI1 program・firmware の wait word）、`submit.c`（`fw_wait_units` = WAIT_IDLE + wait word への RESULT を DMA で読んで待つ）、`record.c`・`uop.c`（recording は heap の chunk の µop と inline の data、replay は DMA で読み FIFO へ）、`draw.c`（constant bank の image は recording の data、uniform の words を BLT が image に写し LOAD_CONST が読む。VF が identity buffer を読む）、`image.c`・`pipeline.c`（内蔵の program を I$ が読む、scratch は pipeline の block の後ろ）、`query.c`（`fw_query_copy` は client の dst に `fw_store`）。zedBSD の driver（main 485108a30）: `src/drivers/gpu/ghci/cp.c`（`ghci_cp_submit` は frame の後の FENCE を **session の tag** で作る）、`memory.c`（aperture の base は window の無い時 line_bytes で **4 KiB に揃っていない**）、`ghci.c`、`frame.h`。P3 の `vk/`（`agent/p3-p006` ad7d5b54a、読むだけ）: `vk-memory.c`（GHCI_MEMORY の flags は **[0] HOST_VISIBLE、[1] IMPORTED**、import は importer の frame に IMPORTED の MEMORY）、`vk-program.c`（`place_program` は session の allocation に binary を置き PROGRAM だけを送る）、`vk-relay.c`、`vk.h`（firmware の heap は 16 MiB）。
- **推定**（合成していない・測っていない）: LUT・FF、DDR3 の read の遅れ（KC705 の gclk 200 MHz で 40〜80 cycle と見た）、PLB の miss の率、scrub の cycle、table の RMW の時間。
- **未確認**: DC の FIFO の余裕（PLB の miss の stall に耐えるか、§17.5）、各 unit の busy が自分の MC の応答まで覆うか（確認 C1、§17.6）、記録が自分の要る STATE を全部書くか（確認 C2、§17.7）、Vulkan の app の allocation の頻度。

### 17.1 守る物と範囲（threat model）

- **守る物**: 保護した session（protected）の仕事は、(a) その session が所有する memory、(b) その session に grant された memory、(c) 全部の protected の session に公開した読むだけの firmware の領域（public）の外を読み書きしない。(d) 他の session の仕事が GPU の中に残した data（register・shared memory・定数・varying・cache・firmware の heap の再利用の前の中身）を見ない。
- **相手**: 保護した session の client（user の process）。その client が作れる物は全部疑う: Vulkan の command の引数（address・offset・size）、shader（kernel の compiler が作るが、SPIR-V の未定義の値や未初期化の読みは起き得る）、記録の中の data、host から書ける自分の memory の中身。
- **信じる物**: zedBSD の kernel の driver（ring・frame・staging・result page・fence page は driver の memory で client に map しない）、CP の firmware、hardware。
- **範囲の外**（GHCI §11.6 と同じ）: 他の client の仕事を止める事（違反は fault → device 全体の reset、v1: robustBufferAccess の compiler の漏れも含め、protected の session の範囲の外の access は全部の session の DEVICE_LOST になる。§17.13）、timing の side channel、保護しない session（driver 0 と unprotected の session は検査しない）、DC の scanout、root の NATIVE。

### 17.2 決めた事の要約

1. **所有の表は memory に、検査は MC の root で**: granule（4 KiB、絶対の番号 g = address >> 12）ごとに 1 byte の表（PROT_TABLE、driver が確保し 0 にする）、root の小さな cache（PLB）が引き、grant は root の CAM（PROT_GRANTS 個）が並行に引く（U61）。
2. **session の番号**: job tag を protected の slot（1〜PROT_SLOTS、KC705 31、byte の 6 bit で 63 まで）に CP の表（SLOT_MAP）で写す（U62）。
3. **要求に slot を付ける**: AMB の header に chk・tbl（各 1 bit）と slot（6 bit）。unit は CP の `prot_unit`、firmware の µop と DMA は class 2 の packet の slot。ring の class 0/1 の CP 側の µop（driver の FENCE・RESULT）・ring・debug port・DC は検査しない。
4. **unit は 1 度に 1 つの session**: unit を動かす µop の slot が `prot_unit` と違う時、CP が drain → invalidate → scrub（GPU の中の残りが他の session の物の時だけ）→ `prot_unit` を変える（U63）。
5. **firmware**: firmware の µop は class 2 の slot で検査する。ただし firmware 自身の待ち（wait word への RESULT・WAIT_FENCE）は UOP の window の SELF の bit で検査しない。heap は private・session の可視の slab（確保の前に 0 で埋める）・public（読むだけ）の 3 区分。
6. **拒んだ要求**: 作らない、read の応答の data は 0、fault kind 1、FAULT_INFO[9] = 1、[31:24] = その slot の job tag。
7. **順序**: MEMORY・FREE_MEMORY は表を直して該当の PLB の line を無効化（drain 無し）。GRANT はすぐ効く（drain 無し、U65）。REVOKE・SESSION_CLOSE は drain の後に。
8. **driver**: PROT の有る device では root でない client の session を全部 protected で開く（U64）。表を確保し 0 にし PROT_TABLE を書く。program の allocation は MEMORY の READ_ONLY（flags[2]）、import は ring の GRANT（frame の IMPORTED の MEMORY は表を触らない）、release は REVOKE。

### 17.3 session の slot と所有の表

- **slot**: protected の session ごとに firmware が SESSION_OPEN で 1〜PROT_SLOTS を **round-robin**（直前に閉じた slot を最後に回す）で割り当てる。tag 0 の PROTECTED は拒む（GHCI「Session 0 is the driver's own and is never protected」）。CP の `SLOT_MAP[256]`（6 bit、job tag → slot、0 = 検査しない、**[0] は 0 に固定**）と `SLOT_TAG[64]`（8 bit、slot → job tag）を firmware が書く。CTRL.RESET で 0。PROT_SLOTS は KC705 で 31（firmware の FW_SESSIONS 32 と合わせる、U62）。
- **所有の表（PROT_TABLE）**: 絶対の granule の番号 g（address >> 12）の [G0, G1) について、1 byte: [5:0] owner の slot（0 = どの protected の session も所有しない）、[6] read-only（owner は読むだけ）、[7] public（全部の protected の session が読める。owner は 0）。G0 = floor(APERTURE_BASE / 4096)、G1 = ceil(APERTURE_LIMIT / 4096)、PROT_TABLE_BYTES = G1 − G0 を 4 KiB に切り上げ（4 GiB の aperture で 1 MiB、1 GiB で 256 KiB）。aperture が 4 KiB に揃っていなくても page が granule を跨がない。
  - driver が driver の memory（byte 0 の領域）に **4 KiB に揃えて**確保し、PROT_TABLE（host の register）に書く。書いた時に hardware が G0・G1 を latch する。aperture の register を書くと PROT_TABLE は 0 に戻る（表と aperture の食い違いを防ぐ）。PROT_TABLE は SLOT_MAP の全部が 0（protected の session が 1 つも無い）の間だけ書ける（RUN の中でも。それ以外は kind 7）。0 で埋めるのは driver で、**PROT_TABLE を書く前に**埋める（書く前は表は tbl の規則の外の普通の driver の memory）: 順は APERTURE → RUN → 表の 0 埋め（local memory は BLT（tag 0）、host memory は CPU と §11.4 の cache の clean）→ その FENCE → PROT_TABLE → GHCI_HEAP（firmware が public の byte を書く）→ 最初の PROTECTED の SESSION_OPEN。CTRL.RESET の後の recover も同じ順（`cp.c` の `program_ring` は毎回 APERTURE を書くので PROT_TABLE は 0 に戻る）。
  - 表の書式は vendor の物（GHCI は「PROT_TABLE_BYTES の memory を driver が貸す」だけを決める）。
- **grant の CAM（PROT_GRANTS 個、KC705 64）**: entry = {valid, slot 6 bit, read, write, base（20 bit）と limit（21 bit: G1 = 2^20 を表す）（絶対の granule の番号）}、firmware は session ごとの grant の上限（PROT_GRANTS / 4）も守る（1 つの client が CAM を尽くさない）。firmware が CPU の window の register で書く。同じ範囲の grant が 2 つ有れば entry も 2 つ（REVOKE は 1 つだけ消す）。CTRL.RESET で全部 invalid。PROT_CAPS[31:16] = PROT_GRANTS（U67）。
- **許可の判定**（chk = 1、slot s、granule g、write w）: g ∉ [G0, G1) → 拒む。b = table[g]: `own = b[5:0] == s && !(w && b[6])`、`pub = b[7] && !w`、`grant = ∃e: e.valid && e.slot == s && e.base ≤ g < e.limit && (w ? e.write : e.read)`。許す = own || pub || grant。atomic（ATOM の client）は write として判定。aperture・window の外は今の検査が先に拒む。
- **表を守る**: [PROT_TABLE, +PROT_TABLE_BYTES) への write は header の tbl = 1（CPU の DMA の DMA_GO[18] だけが立てる）の時だけ許す（chk に依らない多重の防御: firmware の DMA が client の address で表を書く誤りを止める）。

### 17.4 要求に slot を付ける道（client ごと）

| client | 何の要求 | chk・slot | 理由 |
| --- | --- | --- | --- |
| 0 CP: ring | ring の読み | 0 | driver の memory |
| 0 CP: fence unit、ring の µop | driver の FENCE・RESULT（session の tag の packet も） | 0 | ring は driver が書く。driver の fence page・result は driver の memory（`cp.c` は frame の後の FENCE を session の tag で作る: 検査すると毎回 fault する）。GHCI の文を「ring の class 0/1 の CP 側の µop は driver の物で検査しない」に直す |
| 0 CP: fence unit、firmware の µop | FENCE・RESULT・WAIT_FENCE・QUERY | chk = 1、slot = class 2 の slot。UOP の window の SELF = 1 の µop packet は 0 | 前者は session の代わり（query pool・event は session の可視の slab）、後者は firmware 自身の待ち（wait word） |
| 0 CP: debug port | DBG_ADDR | 0 | bring-up、driver |
| CPU（firmware の DMA） | heap・frame・result page・表・session の buffer | DMA_GO[17] = 1 の DMA だけ chk = 1、slot = class 2 の slot。DMA_GO[18] = tbl | session の address を読み書きする時だけ（呼び出しごとの表を R6 の受け入れに） |
| BLT・VF・TU・ROP・ATOM・SA・SU の D$・I$+定数 | unit の仕事 | chk = `prot_unit != 0`、slot = `prot_unit` | unit は 1 度に 1 つの session（§17.6） |
| EXT（KC705 の DC） | scanout | 0 | driver の物 |

- header: bit 3 = chk、byte enable の後に tbl（1 bit）と slot（6 bit）（64 B の line で 116 + 7 / 512）。leaf（`am_amb_to_rt`）は入力の chk・tbl・slot を header に入れる。header は request の間 入力から作り直されるので、unit の要求が leaf で待つ間に `prot_unit` が変わらない事を drain が保証する（§17.6）。
- `am_amb_mux` は parameter の幅の side band を足し、CP の client 0 だけが requester ごとの chk・tbl・slot を使う。ROP・VF・SU の中の `am_amb_mux` は 0 を繋ぐ（unit の slot は `atg_top` が client ごとに与える）。

### 17.5 MC の検査（新しい子 `atg_mc_prot` と `atg_mc_grant`、root の中）

- **PLB**: `PROT_PLB` line（KC705 16）、全結合、round-robin。1 line = 表の LINE_BYTES byte = LINE_BYTES 個の granule（64 B の line で 256 KiB、16 line で 4 MiB の reach）。tag = (g − G0) >> log2(LINE_BYTES)（14 bit）。data は byte-lane の LUTRAM。
- **判定は 1 段の pipeline**: chk = 1 の要求は assembly buffer から判定の段（PLB の tag の比較・byte の選択・slot の比較、並行に CAM の比較）を 1 cycle で通り、次の cycle に grant する（chk = 1 の要求に +1 cycle、throughput は 1/cycle）。chk = 0 の要求は判定の段を通らず今と同じ。ただし判定の段か park に要求が有る client の後の要求は chk に依らず待つ（client ごとの順序: CPU の DMA と CP の client 0 は chk の 0 と 1 が混ざる）。判定の段と park は write の data を含む要求の全部を持つ register（≈0.6k FF ずつ）。判定の段の結果は PLB・CAM の変化（fill・無効化・CAM の書き込み）の cycle の後に判定し直す（1 cycle の stall）。R2 の受け入れに 200 MHz の timing（合成の実測）を入れる。
- **miss**: miss の要求を **退避の register（park）**に移し、表の line（PROT_TABLE + (g − G0) の line）を AXI master に読む（内部の要求、client 番号 0xFF の印で応答を root が取り、木に流さない。`axi_idle` と quiesce の drain に数える）。park の間、root は park と別の client の要求（chk = 0 か hit）を grant する。park と同じ client の要求ともう 1 つの miss は唯一の assembly buffer で待ち、木の全部が止まる（流れる client は park の直後に同じ client の要求を出すので、ほぼ毎回止まる）。**DC が止まらないように、HAS_PROT の構成は `ROOT_CLIENT`（DC）を木の最上段の router ではなく root の別の入口（自分の assembly buffer、検査しない、優先）に繋ぐ**（`atg_mc_tree` の変更。DC の要求は木の stall に依らず AXI master に入る）。応答で line を詰め、park を判定し直す。表の read の AXI の error は fault kind 5。
- **無効化**: PROT_INV_G（先頭の granule）と PROT_INV_N（granule の数、32 bit、0 = 全部。書くと始まる）は範囲に重なる PLB の line だけを消す。walk の発行の後に重なる INV が来たら、その応答を捨てて 1 度だけ読み直す。その読み直しの間は次の INV を受けず PROT_INFO[3]（INV の pending）を 1 にし、firmware は PROT_INFO[3] = 0 を待ってから次の INV を書く（window には ready が無いので store では待てない: livelock しない）。flush（CTRL.RESET）で PLB と CAM は空。
- **拒否**: 今の aperture の拒否と同じ道（`grant_bad` → `err_v` → error の応答と `fault`）。**応答の data は 0**（aperture の拒否も 0 にする。今は「最後の read の data」で漏れ得た）。`fault_prot`・`fault_slot` を CP に出す。
- **HAS_PROT = 0**: `atg_mc_prot` が無く、header の chk・tbl は 0 に固定（今の動作、今の試験が変わらない）。

### 17.6 CP: unit の session の切り替え（新しい子 `atg_cp_prot`）

- **持つ物**: SLOT_MAP・SLOT_TAG、`prot_unit`（6 bit）、`known`、`resid`（SU の RAM が今持つ data の持ち主: none・slot（**0 = driver・unprotected も 1 つの持ち主**）・MIXED の 3 種を別の値で。scrub で none、SU の RAM が書かれたら `prot_unit` を足す（違う持ち主が足されたら MIXED）。**reset の値は MIXED**: RAM の中身は CTRL.RESET で消えない）。**PROT_SLOT で slot s を消す時**: resid が s なら MIXED、prot_unit が s なら prot_unit = 0・known = 0（同じ番号の新しい session が前の session の残りを見ない）。
- **µop の slot**: ring の µop は dword0 の tag → SLOT_MAP。firmware の µop は UOP_FIFO の entry ごとの slot（書いた時に latch した「今の class 2 の packet の slot」。packet の外で書いた µop（`atg_cpu_win.md`: 次の packet を待つ）は slot 0 = firmware 自身の物で、firmware はそこに session の address を入れない）と SELF の bit。class 2 の slot は PKT_INFO で packet を取った時に SLOT_MAP[JOB_TAG] を latch し、DONE（v_done）で 0 に戻す。SELF は CP 側の µop（fence unit）だけに効き、SELF の packet の unit の µop は entry の slot で検査する（多重の防御）。CPU の DMA の slot は DMA_GO の時に latch する。
- **sequencer との約束**: `atg_cp_seq` は unit を動かす µop（BLIT・DRAW・DISPATCH・LOAD_CONST・DRAW_RAW と class 1 の全部）の kick の前に、その µop の slot を `atg_cp_prot` に示し `ok` を待つ（`atg_cp_seq_wait`（seq の子）の pre の条件に 1 つ。slot の計算は `atg_cp_prot` に置く: seq は今の µop の tag と fw_active を出し `ok` を受ける 2 port が増える（38 → 40）。host の KICK は slot 0 の µop として同じ道を通る。
- **切り替え**（slot s ≠ `prot_unit` か !known）: (1) **DRAIN**: 全部の unit の busy が 0、unit の client の leaf に待つ要求が無い（`atg_top` が `c_req_valid` の unit の client の OR を `atg_cp` に返す）、木と root に chk = 1 の要求が無い（`atg_mc` の `chk_idle`: leaf が chk = 1 の要求を取ると増え root が grant・拒否すると減る counter）、確認 C1 を満たす事。同じ条件を window の PROT_INFO[2]（drained）に出し、firmware の REVOKE・CLOSE の drain もこれを待つ。(2) **INV**: `inv` = 4'b1111、occlusion の counter の clear。(3) **SCRUB**: s ≠ 0 で resid ∉ {none, s} の時だけ、SU に `scrub`、SU の busy が落ちるまで待つ、resid = none。(4) `prot_unit` = s、known = 1。(5) `ok`。DRAIN の間の watchdog は前の slot の仕事として数える（fault の tag は SLOT_TAG[前の prot_unit]。新しい µop の cmd_active は立てない）。
- **確認 C1**（R1 で）: 各 unit の busy が自分の MC の要求の応答まで覆う事。覆わない unit が有れば、`atg_mc` から unit の client の outstanding の counter を出して DRAIN に足す（port の group が 1 つ増える）。
- **fence unit**: `f_chk`・`f_slot` を足す（ring の µop は 0、firmware の µop は entry の slot と SELF）。
- **CPU の window**（sub-bus 0x10〜0x3F の先、`atg_cp_prot` に置く）: 0x28 PROT_SLOT（W: [7:0] tag、[13:8] slot（0 = 消す））、0x29・0x33 PROT_INV_G・PROT_INV_N、0x2A〜0x2D PROT_GIDX・GBASE・GLIMIT・GCTL、0x2E PROT_INFO（R: [0] HAS_PROT、[1] 表が有る、[2] drained、[3] INV の pending、[13:8] PROT_SLOTS）、0x2F PROT_TBASE（R: 表の address）、0x30 PROT_G0、0x31 PROT_G1、0x32 UOP_SELF（W: 次の µop packet の SELF）、DMA_GO[17] = chk、[18] = tbl。
- **host の register**（`atg_cp_regs`、EXTCAP の PROT の entry、version 1）: +0x0 PROT_CAPS（R: [7:0] PROT_SLOTS、[15:8] 12、[31:16] PROT_GRANTS）、+0x4 PROT_TABLE（RW、4 KiB に揃える、protected の session が有る間は lock、aperture の書き込みで 0）、+0x8 PROT_TABLE_BYTES（R）。
- **FAULT_INFO**（`atg_cp_ctl` が組む）: 保護の拒否は kind 1、[9] = 1、[31:24] = SLOT_TAG[fault_slot]。client 0（fence unit）の保護の拒否も、今の「client 0 の MC の fault は device の fault でない」の例外にせず、MC の `fault_prot` から device の fault にする（fence unit の自分の kind 1 の報告より先）。chk = 0 の unit の fault は `prot_unit` ≠ 0 なら SLOT_TAG[`prot_unit`]、0 なら今の seq の tag のまま。

### 17.7 GPU の中に残る data

| 物 | 残り方 | 扱い |
| --- | --- | --- |
| D$・T$・I$・定数の cache | 前の session の line が hit し得る | 切り替えで invalidate |
| ROP の write-back の line | idle で書いて空 | DRAIN |
| occlusion の counter | GPU に 1 つ | 切り替えで clear |
| SU の RF（KC705: 512 行 × 3 copy） | 未初期化の register の読み | SCRUB（1 行/cycle、3 copy 同時、512 cycle） |
| SU の LDS（16 KiB） | 未初期化の shared memory | SCRUB（1 word/cycle、4096 cycle） |
| SU の lda の primitive table（2 copy × 6144 word） | vertex が書かなかった varying の word | SCRUB（全 copy 同時、6144 cycle。**律速、graphics の session で毎回 dirty**。幅の広い書き込み（bank を並列）で短くする案は R4 で） |
| SU の PT（64 × 68 word、16 bank） | 同上 | SCRUB（約 272 cycle） |
| SU の cbank（256 word） | LOAD_CONST の words の外 | SCRUB |
| SU の export buffer（`atg_su_exp`、NPHYS bank × 18 word × NWARPS·32/NPHYS 行の distributed RAM） | export しない attachment・component は前の warp の値のまま ROP が書く（`atg_su_exp.md` 76〜80 行） | SCRUB（bank 並行、行の数の cycle）。`atg_su_exp` は 39 → 40 port |
| firmware の heap の可視の slab | 前の session の scratch・bank の image | 確保の時に firmware が DMA で 0 にしてから owner を書く（§17.8） |
| STATE | 前の session の address と state | **消さない**（U66）。firmware は前と違う session の class 2 の packet を始める時に STATE の cache を捨てる。確認 C2（R6）: 記録が自分の読む STATE を全部書く事（書かないと B の draw が A の address で fault する = 正当な B の DoS） |
| SA（HAS_SA、KC705 に無い） | accumulator | SA を入れる時に scrub を足す |

scrub の時間（KC705、推定）: 約 6.2k cycle（lda が律速、SU は並行）= 200 MHz で 31 µs。resid が同じ session なら 0（A → driver の blit → A は scrub しない）。

### 17.8 firmware（P2 の `fw/cp/`、実装の段で）

- **SESSION_OPEN**（ring だけ）: PROTECTED: PROT_INFO[0] = 0 → VK_ERROR_FEATURE_NOT_PRESENT、tag 0 → VK_ERROR_FEATURE_NOT_PRESENT、表が無い → VK_ERROR_INITIALIZATION_FAILED、slot が無い → VK_ERROR_OUT_OF_DEVICE_MEMORY。slot を取り PROT_SLOT を書く。
- **MEMORY**（protected の session）: flags[1] IMPORTED は表を触らない（access は driver が ring で先に出す GRANT）。それ以外: 範囲が granule に揃わない → VK_ERROR_INITIALIZATION_FAILED。object を作ってから、範囲の byte を DMA で読み、全部 0 の時だけ owner = slot（flags[2] READ_ONLY なら [6] も）を書く（0 でない byte → object を消して VK_ERROR_INITIALIZATION_FAILED: 他の session の memory を守り、driver の誤りを見つける）。書き込みの応答を待ち、範囲の PROT_INV。1 GiB の allocation は 4096 line の RMW（推定 数 ms、frame の decode を止める）。
- **FREE_MEMORY**: IMPORTED でなければ範囲の byte のうち owner = slot の物を 0 に、PROT_INV（drain 無し: Vulkan は使用中の free を禁じる。違反した session の仕事は fault し、v1 では device 全体の reset）。
- **BUFFER_GRANT**（ring だけ）: protected の session、granule に揃う範囲。drain せず CAM に足す（空きが無ければ OUT_OF_DEVICE_MEMORY、U65）。
- **BUFFER_REVOKE**（ring だけ）: `fw_wait_units`（SELF の µop）の後に PROT_INFO[2] = 1 を待って drain、同じ {session, 範囲} の entry を 1 つ消す（無ければ何もせず VK_SUCCESS）。
- **SESSION_CLOSE**: REVOKE と同じ drain、その session が byte を書いた範囲（memory の object・program・slab の記録）の byte を 0 に、記録が溢れたか byte の書き込みが途中で失敗した session だけ**表の全体から byte の owner = slot を掃く**（firmware の core 100 MHz で 1 MiB を約 10〜20 ms、推定。稀な時だけ）、その slot の CAM の entry を消す、PROT_SLOT で slot を消す（known = 0）、全部の PROT_INV。
- **heap の 3 区分**:
  - (a) **private**（object の record、記録の µop の chunk、pipeline の state、descriptor の写し、firmware の wait word）: byte 0。firmware の DMA（chk = 0）だけ。
  - (b) **session の可視の slab**（scratch、記録の data の chunk = constant bank の image と vkCmdUpdateBuffer の data、query pool、event の word）: session ごとに granule に揃えた slab を持ち、その中を line 単位で貸す（granule ごとに貸すと 16 MiB の共有の heap が 4096 個で尽きる）。slab を取る時に DMA で 0 にし、その後 owner = slot を書く。上限は SESSION_OPEN の heap limit。firmware は中身を信じない（data として読むだけ）。記録は µop の chunk（private）と data の chunk（可視）に分ける（今は同じ chunk に inline）。
  - (c) **public**（identity buffer、内蔵の GSI1 program）: heap を貸された時に byte [7] = 1（全 protected の session が読む、書けない）。今の配置（`fw.h` の FW_BUILTIN_BYTES = 267328、4 KiB の倍数でない）は program 4・wait word・最初の object が同じ granule に入るので、public の部分を 4 KiB に切り上げ、wait word を private の granule に移し、free list を granule の境から始める。slab は line の first fit に granule の整列の確保を足す。
- **µop**: firmware の µop は class 2 の slot で検査される。firmware 自身の待ち（`fw_wait_units` の WAIT_IDLE + RESULT）は UOP_SELF = 1。SELF の packet に session の address を入れない。
- **DMA_GO[17]**: session の address（VkBuffer、indirect の引数、`fw_query_copy` の dst、copy の相手）を読み書きする DMA は 1、line の store と reader の cache は chk を line ごとに持つ。DMA_GO[18] は表の書き込みだけ。全部の DMA の呼び出し（`fw_store`・`fw_copy_in`・`fw_copy_out`・`fw_reader`・`fw_dma_read`）の chk の表を R6 の受け入れにする。
- **sessions**: FW_SESSIONS 32 のまま、PROT_SLOTS 31。

### 17.9 driver（zedBSD の `src/drivers/gpu/ghci/`、実装の段で）

- **attach**: PROT が有れば PROT_CAPS を読み、aperture の base を 4 KiB に揃え（window の無い時の line_bytes を 4 KiB に）、PROT_TABLE_BYTES（APERTURE を書いた後に読む）を 4 KiB に揃えた driver の memory に取る。順は §17.3 のとおり APERTURE → RUN → 表の 0 埋め（local memory は BLT（tag 0）、host memory は CPU と cache の clean）→ その FENCE → PROT_TABLE → GHCI_HEAP → protected の session の open。CTRL.RESET の後の recover も同じ順で 0 にし直す（firmware は session を失う。v1 は全部の session が device lost）。
- **session**: root でない process の session を PROTECTED で開く。slot が尽きたら open は ENOSPC（保護しない session に落とさない）。root の session は保護しない（U64）。
- **FENCE と RESULT**: 今どおり（session の tag の FENCE は ring の class 0 で、検査しない）。
- **memory**: session の allocation は page（4 KiB）単位。program の allocation は driver の合成の identity で MEMORY flags[2] READ_ONLY を frame に入れ、release で FREE_MEMORY。ring・fence page・staging・frame・result page・表は driver の memory（client に map しない）。
- **合成の identity**: program の allocation と storage の blob の MEMORY は予約した名前の空間（client の handle と重ならない範囲）を使い、vk は client の vkFreeMemory・bind のその範囲の handle を拒む。storage の blob（Vulkan の MEMORY を通らない）も作った時に合成の所有の MEMORY を出す。
- **share**（R1 で P3 の `share.c` の alias・hold の寿命を読んで合わせる）: backing の所有の session が importer と違う時だけ、importer の frame（IMPORTED の MEMORY を含む）より前に ring に BUFFER_GRANT(importer の tag、read|write（Vulkan の外部 memory は import した側が全部使える）、address、bytes)。importer が free したら、その frame の後に BUFFER_REVOKE。exporter の free は importer が全部 revoke し fence が過ぎるまで遅らせる。CAM が尽きたら import は VK_ERROR_OUT_OF_DEVICE_MEMORY。
- **relay**: client の stream の GHCI の gpu-op（0x10100〜）は中継しない（今の codec が守る。protected の約束として明記）。
- **fault**: FAULT_INFO の [9] と session を log に出す。

### 17.10 GHCI の変更（draft。R1 で `docs/ghci.md` に書き、R8 で確定）

- §11.6:
  - slot・PROT_TABLE（driver が 4 KiB に揃えて貸し 0 にする memory、書式は vendor の物、aperture を書くと 0 に戻る）・PROT_TABLE_BYTES・PROT_CAPS[31:16] = grants。
  - 検査の対象: unit の仕事、firmware が session のために出す µop と DMA。**ring の class 0/1 の CP 側の µop（driver の FENCE・RESULT）は driver の物で検査しない**（draft の「the fence and result writes of its packets」を直す）。ring の class 0/1 の unit の µop は packet の tag の session で検査する。その代わり **driver は protected の session の packet の class 0/1 の CP 側の µop に client の選んだ address を入れない**（規範。zedBSD は NATIVE が root だけなので守られる）。
  - GPU の中に残る data: protected の session の仕事は、他の session の仕事が残した register・shared memory・定数・varying・cache の data を見ない（規範）。
  - 拒んだ read は 0 を返す。GRANT は後の仕事に効く（前の仕事に早く効いてもよい）、REVOKE・SESSION_CLOSE は前の仕事が終わってから。REVOKE は同じ範囲の grant を 1 つ消し、無ければ何もしない。
  - MEMORY: 範囲が他の session の物、または granule に揃わない → VK_ERROR_INITIALIZATION_FAILED。IMPORTED（flags[1]）は所有を作らない（GRANT が要る）。PROTECTED で表が無い → VK_ERROR_INITIALIZATION_FAILED。tag 0 の PROTECTED → VK_ERROR_FEATURE_NOT_PRESENT。
- §7.2: MEMORY の flags（[0] HOST_VISIBLE、[1] IMPORTED: P3 の今の定義を GHCI に、[2] READ_ONLY）。
- §3.4: FAULT_INFO[9] = session の保護による拒否。
- §4: PROT の register（+0x4 PROT_TABLE、+0x8 PROT_TABLE_BYTES）。

### 17.11 性能（推定）

- **hit**: chk = 1 の要求に +1 cycle（判定の段）、throughput は今と同じ 1/cycle。chk = 0 は今と同じ。
- **miss**: 表の 1 line の read（gclk 40〜80 cycle、推定）。park と同じ client の後続かもう 1 つの miss が来ると木の全部が止まる（流れる client ではほぼ毎回）。DC は root の別の入口なので止まらない。CP の ring・fence も 1 回の miss の間は待つ。line の reach は 256 KiB: 流れる access は 256 KiB に 1 回、texture の random な読みは T$ の miss の一部が PLB の miss になる。
- **切り替え**: drain（仕事しだい。交代が無くても FENCE で待っている時間と重なる）+ 1 cycle + scrub（resid が他の session の時 約 6.2k cycle = 31 µs）。60 fps × 5 session の交代（300 回/s）で ≈9.3 ms/s ≈ 0.9%（driver の presentation の blit（tag 0）を挟んでも、resid が変わらないので scrub は増えない）。
- **表の更新**: MEMORY・FREE_MEMORY は範囲の line の RMW（1 GiB で 4096 line、数 ms）、SESSION_CLOSE は書いた範囲だけを 0 に、表の全体の掃き（firmware の core 100 MHz で 1 MiB を約 10〜20 ms、推定）は記録が溢れた時だけ。
- **REVOKE・CLOSE の drain**: release と close の時だけ。

### 17.12 状態遷移・所有と寿命・並行性

- **`atg_cp_prot`**: IDLE →(unit の µop の slot ≠ prot_unit か !known)→ DRAIN → INV → SCRUB（s ≠ 0 かつ resid ∉ {none, s}）→ IDLE（ok）。PROT_SLOT の消去は resid と prot_unit を §17.6 のとおり直す（どの状態でも、FSM の外の更新）。FAULTED → RESET で SLOT_MAP・SLOT_TAG・prot_unit・known = 0、resid = MIXED。
- **`atg_mc_prot`**: IDLE →(chk の miss)→ WALK → FILL → IDLE（park を判定し直し）。重なる PROT_INV は WALK の結果を 1 度だけ捨てる。
- **所有**: 表は driver の memory、中身は firmware が書く（tbl の DMA だけ）。CAM・SLOT_MAP は firmware が書き、CTRL.RESET で消える。slot の寿命 = SESSION_OPEN〜SESSION_CLOSE、close で表の全体から slot を掃き CAM を消してから round-robin で再利用する。
- **並行**: firmware の表の書き込み（CPU の DMA）と unit の要求は同じ AXI master を通る。firmware は DMA の書き込みの応答の後に PROT_INV を書くので、後の miss は新しい表を読む。class 2 の間は他の packet を取らない（今の約束）、DONE は UOP_FIFO が空になるまで待つ（今の約束）。

### 17.13 失敗と corner case

1. protected の session が他の session の memory を texture・vertex・store・copy・firmware の DMA で触る → fault kind 1、[9]、session の tag、data 0、書き込みは起きない。v1 は device 全体の reset で、全部の session が DEVICE_LOST（robustBufferAccess の compiler（p010）の漏れでも同じ。p010 の robust を R5 の試験に入れる）。
2. 未初期化の register・LDS・varying・cbank の読み → 他の session の残りは scrub で 0。同じ session の前の仕事の値は見える。
3. reset の後の最初の protected の session → resid = MIXED なので scrub する。
4. 表の byte が他の session の物の時の MEMORY → 拒む。object の作成の失敗 → byte を書かない。
5. FREE_MEMORY の後にその memory を使う → fault（自分の規則違反、v1 は device 全体）。
6. REVOKE の前の仕事 → drain（unit の idle・leaf・木の chk = 1 の要求が無い）で終わってから消える。同じ範囲の 2 つの grant の 1 つの REVOKE → 1 つ残る。
7. slot の再利用 → close で書いた範囲を 0 に（溢れた時は表の全体を掃く）、round-robin、resid が その slot なら MIXED・known = 0。
8. PROT_TABLE = 0 で PROTECTED の open → INITIALIZATION_FAILED。aperture を書いた → PROT_TABLE = 0。
9. CTRL.RESET → PLB・CAM・SLOT_MAP・prot_unit が空、driver は表を 0 にし直す。
10. 表の read の AXI の error → fault kind 5。
11. HAS_PROT = 0 → PROT の capability が無く、PROTECTED・GRANT・REVOKE は FEATURE_NOT_PRESENT。
12. ATOM が read-only・public の granule → 拒否。
13. packet の外で書いた µop → slot 0（firmware 自身の物）。次の packet の slot で動かない。
14. DRAIN の間の watchdog → 前の slot の fault。
15. 表への tbl 無しの write → 拒否（kind 1、[9]）。
16. PLB の miss の stall → DC は root の別の入口で止まらない。
17. export しない attachment・component → 他の session の残りは scrub で 0。

### 17.14 on-chip の量（推定、合成していない）

| 物 | LUT | FF |
| --- | --- | --- |
| `atg_mc_prot`: PLB 16 line（tag 14 bit、byte-lane の LUTRAM 64 本）、判定の段と park（要求の全部、≈0.6k FF ずつ）、walker、chk_idle の counter | ≈1.3k | ≈1.6k |
| DC の root の別の入口（assembly buffer 1 つと root の選択） | ≈0.2k | ≈0.6k |
| `atg_mc_grant`: CAM 64 entry | ≈2.5k | ≈3k |
| `atg_cp_prot`: SLOT_MAP（LUTRAM）、SLOT_TAG、FSM、window | ≈0.4k | ≈0.2k |
| UOP_FIFO の entry に 7 bit | 小 | ≈0.1k |
| SU の scrub × N | ≈0.15k × N | ≈0.05k × N |
| header の 8 bit（木の各段） | 小 | 8 × 段 × 2 |
| 計（KC705、N = 6） | ≈5.3k | ≈5.9k |

BRAM は使わない。KC705（203,800 LUT）には余る。

### 17.15 model・TB・試験の計画（host の iverilog・Verilator と firmware の host 試験。QEMU・板はこの Phase に無い。実機は p028 の後）

- `tools/protmodel.py`: 判定の参照（own・pub・grant・ro・表の範囲・tbl）、TB の vector、`--selftest`。
- `sim/tb/atg_mc_prot_tb.v`（新）: group `hit`、`miss`（walk、置き換え、reach の外）、`park`（park の間に別の client の要求が通り、同じ client の後続は chk = 0 でも待つ、同じ client が続けて出す形と miss を 2 つ出す形、DC は別の入口で遅れの上限を受け入れ条件に）、`order`（同じ client の chk の 0 と 1 の混在の順序）、`chkidle`、`inv`（範囲の無効化、walk の途中の INV で 1 度だけ読み直し、2 度目は待つ）、`recheck`（判定の段の中の要求が fill・INV・CAM の後に判定し直される）、`grant`（CAM の境と 1 ずれ、重複の entry）、`ro`・`pub`、`tbl`（表への write）、`range`（[G0, G1) の外、aperture の base ≠ 0）、`bypass`、`refuse`（data 0、fault・client・slot・prot、拒んだ write が AXI に出ない）。MUT: `MUT_PROT_NOCHK`、`MUT_PROT_STALE`、`MUT_PROT_RO`、`MUT_PROT_DATA`、`MUT_PROT_RECHECK`（判定し直しを省く）、`MUT_PROT_LIMIT`（CAM の limit を ≤ に）、`MUT_PROT_TBL`。
- `sim/tb/atg_mc_tb.v`: header の chk・tbl・slot が 2 つの形の木を通る（leaf・mux で落ちない）。今の case は変わらない。
- `sim/tb/atg_cp_prot_tb.v`（新）: SLOT_MAP（[0] は 0）、切り替えの順（busy と leaf の要求が無くなるまで kick しない、inv と occ の clear、scrub は resid が他の時だけ、prot_unit）、known、ring の µop と firmware の µop の slot、FIFO の entry の slot と SELF、packet の外で書いた µop は slot 0、fence unit の chk・slot、DMA_GO[17]・[18]、KICK、DRAIN の watchdog の tag。close → 同じ slot の再利用 → 未初期化の読み = 0（resid）、drained の bit が木の中の chk = 1 の要求で 0。MUT: `MUT_CPPROT_CLOSEKEEP`（slot を消しても resid を触らない）、`MUT_CPPROT_NODRAIN`、`MUT_CPPROT_NOSCRUB`、`MUT_CPPROT_NOINV`、`MUT_CPPROT_RESID0`（resid の reset を none に）、`MUT_CPPROT_DMACHK`（DMA_GO[17] を無視）、`MUT_CPPROT_FCHK`（f_chk を落とす）。
- `atg_su` の group `scrub`: scrub の後に RF・LDS・lda・PT・cbank・export buffer が 0、scrub の間 busy、書いた RAM の印。
- `sim/tb/atg_top_prot_tb.v`（新、KC705 の形、firmware 入り）: ring に driver と同じ形の packet（session の tag の frame と FENCE）。SESSION_OPEN(A, B: PROTECTED)、MEMORY(A: a)、MEMORY(B: b)、A の a の中の copy（成功、FENCE も成功）、vertex index を使う draw と vkCmdBlitImage と indirect の draw（public・可視の slab の道）、A の b → a の copy（fault kind 1、[9]、tag A、a は変わらない）。RESET の後、driver の手順で表を 0 にし直し session を開き直して MEMORY を出し直し、GRANT(A, read, b) → 成功、同じ grant をもう 1 つ → REVOKE 1 つで成功のまま、REVOKE もう 1 つ → fault。unprotected の C は b を読める。A の compute が LDS に書き B の compute が初期化せずに読む → 0、A の draw の後 B の fragment が書かれない varying を読む → 0、A の scratch と bank の image の slab を close の後に B が取って読む → 0、A が export した色を B の fragment が一部の lane で export しない → 0、内蔵の program 4 の granule に private の object が無い、REVOKE の直前に木に A の要求が残る形で正当な仕事が拒まれない、reset の後の別の session の未初期化の読み → 0、aperture の base ≠ 0。Verilator の mode `PROT` も（T に）。
- firmware の host 試験（`fw/cp/tests/fwtest.c`）: MEMORY・FREE_MEMORY・IMPORTED・READ_ONLY・CLOSE の後の表の byte、object の作成の失敗で byte を書かない、CAM（重複）、REVOKE と CLOSE の前の SELF の drain、他の session の granule への MEMORY の拒否、PROTECTED の 4 つの失敗、slab の 0 埋めと owner、public の byte、DMA の呼び出しの chk の表。
- driver: vmunix の build の warning 0。
- 回帰: 今の `make sim` の PASS の数が減らない（HAS_PROT = 0 の形は動作が同じ）。

### 17.16 module の分け方（1 module ≤ 400 行・FSM 1 つ・≤ 40 port、port は group で数える（U38））

| module | 新/変 | 中身 | 推定の行 |
| --- | --- | --- | --- |
| `atg_mc_prot` | 新（`atg_mc` の子） | 判定の段、PLB、park、walker の FSM、拒否の data 0 と grant の振り分け（今の `atg_mc` の root の grant の部分をここへ移す） | ≈330 |
| `atg_mc_grant` | 新（`atg_mc_prot` の子） | CAM と書き込みの port | ≈120 |
| `atg_mc` | 変 | root の grant を `atg_mc_prot` へ移し（−60 行）、header の bit、walk の応答の振り分け | 366 → ≈350 |
| `atg_mc_tree`・`am_amb_to_rt` | 変 | chk・tbl・slot の入力と header、HAS_PROT の時 `ROOT_CLIENT` を木から外し root の別の入口へ | +40 |
| `am_amb_mux` | 変 | requester の side band（parameter の幅） | +15 |
| `atg_cp_prot` | 新（`atg_cp` の子） | SLOT_MAP・SLOT_TAG・prot_unit・resid・切り替えの FSM、µop の slot の計算、window の 0x28〜0x32 | ≈300 |
| `atg_cp_seq_wait`・`atg_cp_seq` | 変 | pre の `ok`。seq は今の µop の tag・fw_active を出し `ok` を受ける（38 → 40 port、374 行に +10） | +25 |
| `atg_cp_fence` | 変 | f_chk・f_slot | +10 |
| `atg_cpu_win`・`atg_cpu_dma` | 変 | UOP_FIFO の entry の 7 bit（DONE で class 2 の slot を 0 に）、DMA_GO[17]・[18] と DMA の slot の latch | +30 |
| `atg_cpu` | 変 | 今 40 port: sub-bus を `atg_cp_prot` へ（5 本）、FIFO の head の slot・SELF、PKT_INFO の時の SLOT_MAP の値、UOP_SELF、DMA の side band を group にまとめる（AMB の group に side band、sub-bus を 1 group） | +20 |
| `atg_cp_ctl` | 変 | FAULT_INFO[9]・保護の拒否の tag、client 0 の保護の拒否を device の fault に、DRAIN の間の watchdog の tag | +25 |
| `atg_cp_regs` | 変 | PROT の EXTCAP と 3 つの register、FAULT_INFO[9] | +40 |
| `atg_cp` | 変 | `atg_cp_prot` の結線（今 429 行: 先に結線の一部を子へ移す） | ≈400 |
| `atg_su` の子（rf・lds・lda・pt・cbank・exp） | 変 | scrub の書き込み、書いた印（`atg_su_exp` は 39 → 40 port） | +20 ずつ |
| `atg_su` | 変 | 今 687 行・109 port（上限を前から超える、group で数える）: scrub の入力と書いた印の出力の 2 port。行は子へ移した結線の分で増やさない | +10 |
| `atg_top` | 変 | HAS_PROT、chk・tbl・slot、CP ↔ MC の PROT の group（PROT_TABLE・G0・G1、INV の G・N・valid、gw_*、fault_prot・fault_slot、chk_idle）、leaf の要求の OR | +60 |

### 17.17 実装の段・LW・順（8 LW ≈ 2〜3 時間）

| 段 | 内容 | 受け入れ | 依存 | LW |
| --- | --- | --- | --- | --- |
| R1 | GHCI の draft（§17.10）、新しい module の spec（§3〜§8）、`protmodel.py --selftest`、確認 C1、MEMORY の flags[2] と import・program の手順の P3（p019）との合意 | selftest PASS、spec の port の group ≤ 40 | この設計の review と U61〜U72 | 3 |
| R2 | MC: header、`atg_mc_prot`・`atg_mc_grant`、root の grant の移し替え、拒否の data 0、DC の別の入口、chk_idle | `atg_mc_prot` の group と MUT、`atg_mc` PASS（今の case が変わらない）、lint、timing の実測（T） | R1 | 12 |
| R3 | CP: `atg_cp_prot`、seq_wait の pre、fence unit、`am_amb_mux`、`atg_cpu_win`・`dma`、`atg_cp_regs`、`atg_cp` の結線の整理 | `atg_cp_prot` の PASS と MUT、`atg_cp_seq`・`atg_cp_regs`・`atg_cpu_dma`・`atg_cpu_win` PASS | R1 | 9 |
| R4 | SU の scrub と書いた印（lda の幅の広い書き込みの検討） | scrub の PASS、`atg_su:+quick` PASS | R1 | 4 |
| R5 | `atg_top` の HAS_PROT と配線、KC705 の parameter、`atg_top_prot_tb`、Verilator の mode、p010 の robust の case | lint、`atg_top` PASS（HAS_PROT = 0 で同じ）、`atg_top_prot` は R6 の後 | R2〜R4 | 5 |
| R6 | firmware: slot（round-robin）・表（書いた範囲の記録と稀な掃き）・CAM（session ごとの上限）・heap の 3 区分（slab と 0 埋め、public の granule の整列、wait word の移動）・drained と INV の pending の待ち・記録の data の chunk・UOP_SELF・DMA_GO[17]/[18] の監査の表・STATE の cache・gpu-op、fwtest | fwtest PASS、DMA の表、確認 C2、`atg_top_prot` PASS（T） | R3、p018 の merge | 13 |
| R7 | driver: aperture の 4 KiB、表、PROTECTED の方針、READ_ONLY の program、import の grant/revoke、fault の log | vmunix の warning 0 | R6、p019 の merge | 5 |
| R8 | GHCI の確定、README の行、`make sim` の数（T） | `make sim` の PASS が減らない（T） | R2〜R7 | 2 |
| 計 | | | | **54 LW**（±35%: 35〜73） |

R2・R3・R4 は R1 の後に並行できる。R6 は P2 の p018 が main に入った後、R7 は P3 の p019 の後。

### 17.18 選ばなかった案と理由

- **要求ごとに session を全部の unit に流す**（drain 無しで session を跨いで重ねる）: block の全部と cache の tag が変わり、scrub も warp ごとになる。session の交代は frame の単位で、drain は FENCE で既に払っている待ちと重なるので、割に合わない。
- **session ごとの範囲の CAM（切り替えで firmware が積む）**: miss が無い。だが 1 session の範囲の数に上限（16〜64）ができ、Vulkan 1.0 の `maxMemoryAllocationCount` ≥ 4096 を protected の session で守れない。
- **granule ごとの 32 bit の bitmask（slot ごとの r/w）**: grant も表で表せるが、表が 4 倍、PLB の reach が 1/4、revoke ごとに重なりの計算。grant は Vulkan 1.0 core の外（外部 memory）で数が少ないので CAM で足りる。
- **firmware の software の検査だけ**: unit の access は firmware を通らない。
- **GPU MMU（address の変換、GHCI の MMU capability）**: page table の walk、TLB、driver の page table の管理と、規模も変更も大きい。後の版の capability。
- **scrub を compute の kernel（software）で**: RF の全部の行を覆う保証が scheduler に依る、PT・lda・cbank に届かない。
- **driver の FENCE を tag 0 に変える**: driver の変更と fault の帰属の作り直しが要る。ring は driver の物なので、ring の CP 側の µop を検査しない方が単純で、守る物は変わらない（NATIVE は root だけ、root は保護しない）。
- **heap の可視の区分を granule ごとに貸す**: 16 MiB の共有の heap が 4096 個で尽き、1 つの session が他を止める。

### 17.19 U 項目（ユーザーの判断。推し付き）

**回答（2026-10-25 10:34 Q1、ユーザー「ゴールまで推しで進んでよいです。判断に迷ったら、Vulkan 1.0の原則論で進めてください。」に従い）**: U61〜U72 は全部推しで決めた。起きた時にユーザーに見せ、直しがあれば受ける。

| U | 問い | 推し | 他の案 |
| --- | --- | --- | --- |
| **U61** | 隔離の方式 | **memory の所有の表（granule 1 byte）+ root の PLB + grant の CAM**（allocation の数に上限が無い、表は小さい、検査は root の 1 か所） | session ごとの範囲の CAM（miss 無し、allocation の数に上限）、GPU MMU |
| **U62** | 同時に開ける protected の session の数 | **31**（firmware の FW_SESSIONS 32 に合わせる。byte の 6 bit で 63 まで広げられる） | 63（firmware の session の表を 64 に） |
| **U63** | GPU の中に残る data の扱い | **session の切り替えで hardware が 0 にする（他の session の残りの時だけ）**（OS の process の隔離の原則。≈31 µs、交代 300 回/s で ≈0.9%） | software の kernel、消さない（GHCI に「保護は memory だけ」） |
| **U64** | どの session を保護するか | **root でない client の session を全部**、root は保護しない（NATIVE の道具）。slot が尽きたら open を断る | root も含め全部、client の申告で選ぶ |
| **U65** | GRANT に drain を入れるか | **入れない**（access を足すだけで隔離は破れない。REVOKE・CLOSE だけ drain） | 入れる（「後の仕事に効く」を正確に） |
| **U66** | STATE を切り替えで消すか | **消さない**（address などの metadata。読んだ address は MC が拒む。firmware は session の変わり目で STATE の cache を捨て、記録の自己完結を確認 C2 で確かめる） | 切り替えで既定の値に戻す |
| **U67** | PROT_CAPS[31:16] の意味 | **grant の数** | 今の文（所有も数える） |
| **U68** | firmware の DMA（session の address）の拒否 | **hardware の検査で fault（v1 は device 全体）** | firmware が先に確かめ、その session だけ DEVICE_LOST |
| **U69** | firmware の内蔵の領域（identity buffer・内蔵の program）の見せ方 | **表の byte の [7] public（全 protected の session が読む）** | CAM の wildcard の entry、固定の PUBLIC_BASE/LIMIT の register |
| **U70** | ring の class 0/1 の CP 側の µop（driver の FENCE・RESULT）を検査するか | **しない**（GHCI の draft の文を直す。driver の今の FENCE の作りのまま） | driver の FENCE を tag 0 にし、文のまま検査 |
| **U71** | grant の CAM の数（compositor が非 root の時、client の window ごとに swapchain の image ≈3） | **64**（KC705、≈20 window） | 128（≈5k LUT） |
| **U72** | robustBufferAccess の漏れが device 全体の fault になる事 | **v1 は受け入れ、p010 の robust を R5 の試験に入れる**（範囲の外の access は compiler が clamp する前提を記録） | MC の拒否をその session だけの error にする（v1 の回復の範囲の外） |

### 17.20 license と転記

- この設計と amaterrace-gpu の追加は Zlib（既存と同じ）。Vulkan の仕様からは `maxMemoryAllocationCount` の最小値（4096、limits.adoc の Required Limits、§16.0 で読んだ物）と「使用中の memory の free の禁止」（vkFreeMemory の valid usage、記憶。文面は未確認）を事実として使う。他の GPU の driver・IOMMU の code は読んでいない・写さない。

### 17.21 review の指摘と対応

全文は [design-review-p034.md](design-review-p034.md)。1 回目（design-reviewer、2026-10-25、33 件: Critical 2・High 5・Medium 16・Low 10）と 2 回目（同日、21 件: Critical 1・High 3・Medium 6・Low 11）の全部を本文に反映した。2 回目の主な変更: slot を消す時に resid を MIXED に（N1）、export buffer の scrub（N2）、表は PROT_TABLE を書く前に driver が 0 にし PROT_TABLE は protected の session が無い間だけ書ける（N3）、内蔵の領域の granule の整列（N4）、DC を root の別の入口に（N5）、同じ client の順序（N6）、drain に木の chk = 1 の要求の counter と window の drained（N7）、INV の pending の bit と 32 bit の数（N8）、share と合成の identity（N9・N15）、module の表の追加（N10）。

### 17.22 実装の段で設計から変えた事（2026-10-25 P1、q1575-i01。amaterrace-gpu p1-p034）

- **確認の結果**: C1 = TU の busy は自分の要求と応答を覆わない、CPU の DMA の write の応答はどの busy にも無い → MC に `unit_idle`（CP と DC 以外の client の、leaf が取ってから応答までの counter、`atg_mc_cnt`）を足し、DRAIN と、PROT に依らず CP の FENCE・WAIT_IDLE（flags に依らず）・RESULT・QUERY の待ち（seq の busy の bit 0）に入れた（Q1 の指示）。C2 = 記録は自己完結（STATE の cache は記録の中の `fw_rstate.emitted` だけ）→ U66 のまま。DC: KC705 の gclk は **100 MHz**（§17.0・§17.7・§17.11 の 200 MHz は誤り。scrub は約 62 µs、交代 300 回/s で ≈1.9%）、pixel FIFO 2048 で 720p に約 2760 cycle の余裕。
- **置き場所**: `atg_cp_prot` は `atg_cp` の子ではなく `atg_top` の中で `atg_cpu` の横（PROT は firmware が要る。`atg_cp` は既に 439 行）。MC は `atg_mc_prot` の他に `atg_mc_plb`・`atg_mc_asm`・`atg_mc_cnt` に分けた（各 400 行以内）。CP の client 0 の side band は `am_amb_mux` を変えずに、mux が選んだ requester が fence unit の時だけ付ける。
- **MC**: 重なる 2 度目の INV も受けて walk をもう一度 stale にする（§17.5 の「受けず」より安全。firmware は PROT_INFO[3] を待つので繰り返さない）。CAM の grant は PLB の miss でも許す（walk 不要）。tbase = 0 の chk の要求と slot 0 の chk（public の read 以外）は拒む。拒んだ read の data は 0 を全部の構成で。
- **CP**: resid の「SU の RAM が書かれた印」は SU から取らず、`atg_cp_prot` が SU を使う µop（BLIT 以外の unit の µop）の kick で数える。SU の scrub は既存の write port に mux で足す（RAM の宣言と読みは不変、P2 の BRAM の点検と重ならないように。Q1 の指示）。PROT_TABLE を lock の間に書くのは無視（kind 7 の fault は出さない、GHCI の文も直す）。CTRL.RESET で PROT_TABLE は 0。
- **firmware（R6、2026-10-25 14:23）**: 範囲の記録（§17.8 の「書いた範囲の記録」）を捨てた: memory の object と可視の block の release が disown し、session ごとの granule の数が close で 0 でない時か表の書き込みが失敗した時だけ表の全体を掃く（DMEM が足りなかった）。slab は 1 line の block だけ、大きい可視の block は専用の granule。記録の data は 4 KiB の可視の data chunk（µop の chunk の marker が名指す）。間接の引数は要る line だけ読む。
- **IMEM**（2026-10-25、ユーザー「IMEM を 128 KiB」）: 保護の firmware で 64 KiB の IMEM が 65520 byte になった。IMEM を 128 KiB（0x0000_0000〜0x0001_FFFF）、DMEM を 0x0002_0000 に移した。§2.4.7 の IMEM の大きさの記述はこれで読み替える。
- **KICK と watchdog**（2026-10-25 14:30、amaterrace 943887c）: host の KICK は切り替えを通さず、units が session 0 の物の時（`prot_unit` = 0 で切り替えの外）だけ受け、それ以外は kind 6（§17.6 の「slot 0 の µop として同じ道」の代わり。register の書き込みは drain を待てない）。DRAW・DISPATCH の KICK は resid に owner 0 を足す。DRAIN の間の watchdog の FAULT_INFO[31:24] は前の `prot_unit` の session（`wdt_tag`）。
- **driver（R7、2026-10-25 14:44、zedBSD 0929425e2）**: §17.9 の「合成の identity」は bit 63 と GPU address（`GHCI_VK_PROT_IDENTITY`）。core の resource（blob）と program の memory（READ_ONLY）は作った時に ring の GHCI_MEMORY（待つ）、消す時に FREE_MEMORY（待たない、ring の順）。import は share_import で BUFFER_GRANT（待つ、read|write）、import の destroy で BUFFER_REVOKE（待たない）。SESSION_CLOSE の後は何も送らない（firmware が全部消す）。表は vk の engine が GHCI_HEAP の直前に CPU で 0 にして PROT_TABLE を書く（reset の後も）。表が取れない・PROT_TABLE が受け取られない GPU は保護しない（log）。aperture の base は保護の時 4 KiB に。slot が尽きた open は ENOSPC。
- **ユーザーの決定（2026-10-25、Q1 経由）**: (a)「全体を共有」→ grant の CAM（64）は全部の session の 1 つの pool で先着、1 つの session が全部を使ってよい（§17.3 の「session ごとの上限 PROT_GRANTS / 4」は捨てた。空きが無ければ OUT_OF_DEVICE_MEMORY → driver は ENOSPC）。(b)「DMEM を広げて増やす」→ KC705 の DMEM を 64 KiB（CPU_DMEM_WORDS 16384、0x0002_0000 から）、firmware の object の表を 512（hash の bucket 128）に（amaterrace 2bf6ef7）。
- **残り（未実施）**: 合成の timing。firmware の object は保護した session の resource・program ごとに 1 つ使う（表は 512）。

## Appendix A. SA の設計の sketch（**延期**。2026-10-23 ユーザー「SAの設計と実装はかなり後に回して、SUがきちんとISAを実装できてからにします。」SU が GSI1 を実装した後に設計し直す。計画の critical path には無い。版 4 の review（§14）の 33 件に対応した時点の案で、**README の 0.8 TOPS/SU（×2）は満たしていない**（1 MAC/PE/cycle）。KC705 の SA 構成の数字も参考のみ）

ユーザー（版 3）:「シェーダISAのレジスタのうち、1つをreservedにできる？このレジスタはFIFOにつながってて、systolic arrayのwavefrontのリードやライトに使えるよ。シェーダユニットはオプションでsystolic array (SA)を持つことができ、SAのPEの横方向にシェーダISAからFIFOでRWアクセスできるよ。SAはSUの中にあるわけではなく、SAとSUはdecoupledなユニットだよ。SAにはMCから重みをストリーミングできるよ。」
ユーザー（版 4、2026-10-23）:「SAを使う場合、KC705ではプロトタイプなのでSUは2個くらいでいいのですが、FP16/INT8 mixed precisionにできそうですか？重みはINT8で、演算はFP16です。あ、そうか、SUがFP16 packedに対応していれば、16 laneでも32x32 SAと釣り合うのか。」「SUには、softmaxやlayer normを、SAから1サイクルずつ出力をフェッチして、トークン1つが全部そろう前に1データずつオンライン処理していって、データがそろったら結果を確定して、SAに折り返しで送り返しで書き込んでいく、というフローに対応させたいです」「了解、SIMD-8はやめましょう。」**「了解です。SUにベクトル命令と投機的オンラインsoftmaxの実装を考えましたが、ハードウェア効率が悪すぎるので、案BでSAに寄せましょう。SUはミニマルな形にしましょう。」**
README（a217bf8、ユーザー）: 「LLM: CP --> VF --> SU --> SA --> SU --> SA -> ... --> SU --> ROP -> MC」「Systolic Array: 32 x 32, 0.8 TOPS/SU @200MHz」→ **U39**（§9.2）。この節の推し: SA は SU に 1 対 1（SU ごとに最大 1 つ）、KC705 の prototype は SU 2 個 + SA 1 つ（SU0 に結ぶ）、VF/RX/TU/ROP は SA 構成に載せない。

版 4（案 B）の要点: (1) KC705 の **SA 構成**（別の bitstream）= SU 2 個（NPHYS 16、`PACKED` は graphics のため、LDS 16 KiB）+ SA **32 × 32**、入力は FP16（block floating point で PE は整数）、重みは INT8 を MC から stream、出力は FP16/FP32。(2) SA は tile の終わりに **1 列/cycle で stream-out**し、**出口の reduction の段**（行 = token ごとに online の softmax の m・s か layer norm の Welford）が 1 列/cycle で統計を進め、生の x は SA の **token buffer** に取っておく。token の行が揃ったら SA が確定（1/s か rstd）し、**入口の normalize の段**が buffer の x を 1 列/cycle で正規化して次の tile の activation に折り返す（softmax: `exp2(x − m)·(1/s)`、LN: `(x − mean)·rstd·γ_j + β_j`）。(3) **SU は指揮だけ**（tile の順、address、tag、確定の合図 = `sactl`）。SU の vector 命令と投機的な online softmax（版 4 の最初の案）は hardware の効率が悪いので取り下げ（ユーザー、§10 の 34）。GSI1 は版 3 の最小の形に戻す（packed の超越は無し、subgroup は optional のまま）。(4) PE は SIMD 1。raster 構成は別の bitstream。

### A.1 ISA の側: register 63 = `rq`（queue register）と `sactl`

- **operand 番号 63 は GPR でなく FIFO の口 `rq`**（GSI1 の全部の実装で予約。GPR は r0〜r62）。dst に書くと push（SU → SA の in-FIFO）、source に読むと pop（SA → SU の out-FIFO）。案 B では attention・LN の経路は SA の中で閉じるので、`rq` は **GEMM の結果を SU が受ける時・activation を SU が作る時だけ**使う。
- **entry = 32 値 × 16 bit（FP16）= 64 byte**（SA の左の口の 1 本の vector: 行 i に 1 値。push では step t の a_0..31(t)、pop では出力の列 j の C[0..31][j]）。lane l は slot 2l・2l+1 を packed（下位 half = slot 2l）で持つ。**32 lane の warp の push/pop は常に 2 entry**（lane 0〜15 = entry A、16〜31 = entry B）。NPHYS 16 で 1 entry/cycle。FIFO の口の幅は NPHYS × 32 bit。発行の時に 2 entry（pop）/ credit 2（push）を確かめ、途中では止めない。FP32 の出力は 1 列 = 2 entry（lane l = slot l）。
- **偶奇の規則**（review 2）: push は A = 偶数の step、B = 奇数。pop は A = 偶数の列、B = 奇数。SA は入出力を entry の対に揃える: `SA_K` は偶数（奇数は `sactl` が拒み `sastat[4]`）、`SA_COLS_USED` が奇数なら SA が最後に PAD の entry（tag PAD、値 0）を足す、FP32 は常に 2 entry、BFP の行の scale は「scale + PAD」の 2 entry、abort の後は FIFO を空にして偶奇を 0 に戻す。
- **使える命令**: `rq` は class a・f の命令の dst・source だけ。class m・t・x の dst に `rq`、暗黙の連続の register が 63 に掛かる命令は ISA の fault。
- **EXEC との関係**: push/pop は EXEC に依らず必ず 2 entry 進める。EXEC の外の lane の push の値は 0、pop の値は捨てる。SA の kernel は EXEC を全部 1 に保つ（規約）。
- **blocking**: pop は out-FIFO に 2 entry 無ければ、push は credit が 2 無ければ、発行の段でその warp だけ止まる。scoreboard の entry は使わない。
- **tag**（6 bit）: [0] FIRST、[1] LAST（tile の最後の列の entry だけ）、[2] TILE_LAST（最後の tile の最後の列の entry だけ）、[3] HI（FP32 の上位）、[4] ABORT、[5] PAD。特殊 operand **122 `qtag`** = この warp が最後に実行した pop の 2 entry の tag（lane 0〜15 = A、16〜31 = B、EXEC に依らず）。
- **所有**: SA は **SU に 1 対 1**（`SA_SU`、build の parameter。KC705 の SA 構成は SU0 だけ）。その SU の **1 つの warp** が持つ: `sactl.ctl 4`（acquire。所有していなくても使える唯一の `sactl`）→ 指揮 → `sactl.ctl 5`（release）。所有していない warp の `rq`・`sactl`・`qstat`・`qtag` は ISA の fault。`DISPATCH` の flags[1] = SA の dispatch の warp だけが acquire できる。SA の無い SU（KC705 の SU1）は普通の compute（量子化、前後の処理）に使う。
- **deadlock**: 「push して pop していない tile ≤ 1 + DBUF」かつ「未読の出力の entry ≤ out-FIFO の深さ 64」。案 B の attention・LN では SU は pop しないので、SA の出力は token buffer か memory（`SA_O_BASE`）に行き、FIFO の規則は要らない。`bar` を持ったまま acquire しない。abort は FAULT・RESET の時だけ（pop は ABORT の entry、push は捨てる）。`HALT` は dispatch を完走させる（watchdog が網）。
- **`sactl`（指揮の命令。custom-3 funct3 110、sub で対象）**: sub 0 `sactl.ctl`（word の形は STATE の `SA_CTRL` と同じ bit + [3:0] の command: 0 なし、1 **start**（tile の列: `SA_TILES` 個。重みと列の scale の stream、BFP なら次の push が行の scale）、2 drain（強制）、3 abort、4 acquire、5 release、6 **finalize**（出口の統計を確定: softmax は r_i = 1/s_i、LN は rstd_i。TILE_LAST の後でだけ。`SA_CTRL.AUTOFIN` なら自動）、7 **feedback**（token buffer の x を入口の normalize の段を通して activation にし、`SA_TILES` 個の tile を回す。重みは `wbase`）、8 **reset**（統計と token buffer を空に）、9 **wait**（SA の今の command が終わるまでこの warp を止める。polling の代わり）、[5] accumulator を 0 に）、sub 1 `sactl.wbase`、sub 2 `sactl.sbase`（列の scale。LN の feedback では γ_j・β_j の列の base）、sub 3 `sactl.k`（偶数、≤ 8192）、sub 4 `sactl.tiles`、sub 5 `sactl.obase`（出力の memory の address `SA_O_BASE`）。値は lane 0（EXEC に依らず）。特殊 operand 121 `sastat`（[0] busy、[1] 重みの stream 中、[2] stream-out 中、[3] この warp が所有、[4] 直前の `sactl` が拒まれた、[5] 裏の accumulator が空いている、[6] 飽和が起きた（sticky）、[7] BFP、[8] 統計が確定済み、[9] token buffer が溢れた（sticky）、[15:8→15:10] 残りの tile）。`exec.save`・`vote`・`ballot`・`sactl`・`qstat`・`qtag`・`sastat` は EXEC に依らず全 lane に書く。

### A.2 SA の unit（`atg_sa`、SU と decoupled、MC の client。版 4 の datapath）

- **配置と段**: `atg_sa` は `atg_top` の兄弟。段は **入口**（in-FIFO か token buffer → normalize（任意）→ BFP の揃え → 配列の左の口）、**配列**（32 × `SA_COLS` の PE、2 組の accumulator）、**出口**（drain → 並べ替え → 変換器 → **reduction（任意）** → out-FIFO か memory の書き込み（`SA_O_BASE`）か token buffer）。MC の client は 2 つ（重み・scale・γ/β の読み、出力の書き込み）。CP からは STATE の `SA_*`、`DISPATCH` の flag、`STATUS[7] SA_BUSY`。無い構成では `CAPS[25]` = 0。
- **PE の配列**: `SA_ROWS` = 32（固定）× `SA_COLS`（parameter。KC705 は 16 → 32、U31）。出力固定（activation は左から右、重みは上から下、PE(i, j) が `acc += a × b`）。skew は SA の中。PE の段数は DSP の PE と LUT の PE で揃える。PE は SIMD 1。
- **mixed precision = block floating point**（Q1 の案）: PE は整数（int12 × int8 → int20、int32 の accumulator、`SA_K` ≤ 8192）。入口で行ごとの共有の指数 E_i（行の scale の FP16 の biased の指数）に揃えた 12 bit の符号付き仮数: `m12 = RNE((1.m) >> (E_i − E))`（右 shift だけ、15 を超えれば 0）。|x| > scale は ±2047 に飽和して `sastat[6]`。subnormal・0 は 0、Inf/NaN は飽和 + sticky。重みは INT8（列の scale s_j は FP16、`SA_S_BASE` から tile ごとに 32 × FP16）。**行の scale の出所**: SU が push する時は SU が作る（A.5 の規約: `fmax2` の列 → `shfl` xor 16 → `fmax2` → push。subgroup が無い構成では `lds` で合わせる）。**feedback の時は normalize の段が作る**（softmax: max P = 1/s_i を scale に、LN: 列の走査の前に y の max を 1 回計算するために buffer を 2 回読む（下））。
- **出口の変換（stream-out）**: 列 j の 32 個の acc を行ごとに `acc × 2^(E_i − 15 − 10) × s_j` で FP32 に（32 個の変換器: 正規化 + FP32 × FP16、乗算は DSP 1 ずつ）、`SA_CTRL.OUT` で FP16（RNE、±65504 に飽和 + sticky）か FP32。精度の上界: 行の max と同じ指数の値は FP16 と同じ、max より 2^-k 小さい値は k bit を失う、内積の絶対誤差 ≤ K · max|a| · max|w| · 2^-11。
- **stream-out の順と deskew**: tile の全部が揃った後（K + 62 step）、行ごとに accumulator を右へ shift（列 31 から順に右の口へ = 降順）→ 2 × 32 entry の並べ替えの buffer（LUTRAM 4 KiB、ping-pong）→ **昇順**（列 0 から、tag FIRST）で 1 列/cycle。遅れ 32 cycle。行き先（`SA_CTRL.ODST`）: 0 out-FIFO（SU が pop）、1 memory（`SA_O_BASE` + 列 × 64 byte、`SA_O_STRIDE`。1 line/cycle = 12.8 GB/s @200 MHz は出力の burst の間だけ。DDR3 が追い付かなければ back-pressure で stream-out が止まる）、2 token buffer（下。reduction と組）。out-FIFO が満なら stream-out は止まり、次の tile は裏の bank で続く。
- **出口の reduction の段（`atg_sa_red`、案 B）**: 行ごと（32 行 = 32 token）の状態の register を持ち、stream-out の列を **1 列/cycle** で受ける。mode（`SA_CTRL.RED`）: **softmax** = m_i（running max）と s_i（rescale した running sum）: m' = max(m, x)、s = s·2^(m − m') + 2^(x − m')（x は変換器の出力 FP32。2^(·) は行ごとに 2 本の exp2（入力 ≤ 0、table 64 entry + 線形補間、FP16 相当の精度、pipeline）、s は FP32（仮数 24 bit × 11 bit の LUT の乗算 + 加算）。mask の列は −65504 として送る（`SA_CTRL.MASK` で列の範囲 `SA_MASK_COL` 以降を mask: causal の attention）。**LN（Welford）** = n_i・mean_i・M2_i（FP32: delta = x − mean、mean += delta × (1/n)（1/n は 1 本の table、n ≤ `SA_BUF_COLS`）、M2 += delta × (x − mean)）。同時に生の x（FP16）を **token buffer** に書く（列 c の 32 値 = 1 行 64 byte）。PAD の列は数えない。statistic は `sactl.ctl 8` で 0 に、`finalize` で確定（softmax: r_i = 1/s_i を 1 本の rcp（Newton、FP32）で 32 行を順に ≈ 40 cycle、LN: rstd_i = rsqrt(M2_i / n_i + eps) を同様に ≈ 48 cycle）。推定: exp2 64 本 × 150 LUT = 9.6k、FP32 の乗算と加算 32 × 150 = 4.8k、Welford の FP32 の FMA 32 × 2 × 150 = 9.6k（softmax と LN で演算器を共有して ≈ 10k）、1/n の table BRAM 1、状態 32 × 3 × 32 bit = 3k FF → **≈ 14k LUT、DSP 0**（乗算の一方が ≤ 11 bit なので LUT。U42）。
- **token buffer（`atg_sa_buf`）**: BRAM、`SA_BUF_COLS` 列 × 32 行 × 16 bit。KC705 は **2048 列 = 128 KiB = BRAM36 32**（U41。raster 構成の BRAM の空きで足りる）。1 列/cycle の書き（出口）と読み（入口）を同時に（2 port）。溢れ（N > `SA_BUF_COLS`）は `sastat[9]` と `SA_CTRL.SPILL` で memory（`SA_O_BASE`）へ 1 line/cycle で退避し、feedback は memory から読む（帯域で遅くなる。v1 は実装するが性能は保証しない）。
- **入口の normalize の段（`atg_sa_norm`、案 B）**: `feedback` の command で token buffer（か memory）の列を **1 列/cycle** で読み、行ごとに **softmax**: `p = 2^(x − m_i) × r_i`（exp2 32 本 + FP32 × FP32 の乗算 32 本 = DSP 32 × 2 = 64（24 bit の仮数）→ r_i を FP16 に落とし 11 × 24 の LUT の乗算にして DSP 0。推し: LUT）、**LN**: `y = (x − mean_i) × rstd_i × γ_c + β_c`（γ_c・β_c は列ごとの FP16 を `SA_S_BASE`（`sactl.sbase`）から stream、行ごとに FP32 の減算 + 乗算 2 + 加算 → 32 × 300 LUT ≈ 9.6k）→ FP16 → BFP の揃え → 配列。**行の scale**: softmax は max p = r_i（既知、`finalize` で作る）、LN は y の max が走査の前に分からないので feedback の最初の pass で y を計算して max だけ取り（1 列/cycle、`SA_BUF_COLS` ≤ 2048 で ≤ 2048 cycle）、2 回目の pass で揃えて流す（`SA_CTRL.TWOPASS`。softmax は 1 pass）。推定: **≈ 12k LUT、DSP 0〜32**。
- **裏の accumulator（DBUF）と stall**: PE は accumulator を 2 組（DSP の PE: bank A = P register、bank B = fabric。LUT の PE: 2 組 fabric）。tile n の drain の間に tile n+1 を積む。tile n+2 が始まる時に bank B が drain 中なら SA 全体を止める。
- **重み・scale・γ/β の stream**: `SA_W_BASE`（INT8、行 32 byte、`SA_W_STRIDE`）、`SA_S_BASE`（列の scale / γ、`SA_S_TILE_STRIDE`。LN の β は `SA_S_BASE` の次の 64 byte）、`SA_K`、`SA_TILES`、`SA_W_TILE_STRIDE`、`SA_O_BASE`/`SA_O_STRIDE`。先読みは BRAM36 × 4（256 bit）。重みの帯域 6.4 GB/s @200 MHz。aperture の外は FAULT 種別 1。
- **大きさ**（推定、325T、U31。p020・p022 の合成で実測）:

| 部分 | 32 × 32（DSP の PE 576 + LUT の PE 448） | 32 × 16（DSP だけ 512） |
| --- | --- | --- |
| 乗算（LUT の PE ≈ 95 LUT） | 43k | 0 |
| accumulator（DSP の PE: bank B 32 FF + mux 16 LUT、LUT の PE: 2 組 + 加算器 48 LUT） | 9k + 22k = 31k | 8k |
| 入口の揃え 1.3k、変換器 5.8k + DSP 32、並べ替え 1k、FIFO 2.2k、制御/skew/tag 10 LUT/PE | 20k | 15k |
| **reduction**（案 B）14k、**normalize** 12k、token buffer の制御 1k | 27k | 27k |
| **合計** | **≈ 121k LUT、DSP 608、FF ≈ 75k、BRAM36 37**（先読み 4 + scale 1 + buffer 32） | **≈ 50k LUT、DSP 544、BRAM36 37** |

  SA 構成の全体（§3.6）: 32 × 32 で ≈ 178k LUT（**87%、配線が閉じない恐れ**）、32 × 16 で ≈ 107k（52%）。**U31 の推し: p020 は 32 × 16、32 × 32 は p022 の後に LUT の PE を減らして（32 × 24: DSP 576 + LUT 192 ≈ 90k → 全体 ≈ 147k、72%）実測**。DSP: 2 × 86 + 1 + 608 = 781（93%）/ 717（85%）。
- **性能（峰）**: 32 × 32 で 1024 MAC/cycle = 0.41 TOPS @200 MHz（MAC = 2 op）。案 B では attention・LN が **SA に律速（≈ 1 列/cycle）**で、A.5 の例は峰の 4〜5 割。
- **状態と fault**: `STATUS[7] SA_BUSY`。HALT・quiesce・RESET は他の block と同じ（MC の client 2 つとも「新しい AR/AW を止め、応答を待つ」。abort は FAULT/RESET だけ）。reset で FIFO・accumulator・統計・token buffer は消える。

### A.3 GHCI での見え方（標準の optional な capability）

- `CAPS[25] SA`、`CAPS[27] GRAPHICS`（VF・RX・ROP が有る。SA 構成は 0: driver は compute の queue family だけ、firmware は draw を拒む）、extended capability `SA`（id 7、0x140〜0x14F）: `SA_CAPS`（[7:0] ROWS = 32、[15:8] COLS、[19:16] 入力の型の mask（[0] FP16 BFP、[1] FP16（FP の PE）、[2] INT8、[3] INT16）、[23:20] 重みの型（[0] INT8、[1] FP16、[2] INT16）、[27:24] log2(FIFO の深さ)、[28] DBUF、[29] tag、[30] reduction/normalize（案 B）、[31] memory の出力）、`SA_CAPS2`（[15:0] `SA_BUF_COLS`、[16] spill）、`SA_SU`（R）。
- STATE の `SA` の範囲（0x1B0〜0x1BF）: 0 `SA_CTRL`（[2:0] 0 停止、1 run、[4:3] 入力の型、[5] acc を 0 に、[6] shader の `sactl` を許す、[7] BFP、[8] DBUF、[10:9] OUT（0 FP16、1 FP32）、[12:11] 重みの型、[14:13] **RED**（0 なし、1 softmax、2 LN）、[16:15] **ODST**（0 out-FIFO、1 memory、2 token buffer）、[17] AUTOFIN、[18] TWOPASS、[19] MASK、[20] SPILL）、1 `SA_W_BASE`、2 `SA_W_STRIDE`、3 `SA_K`、4 `SA_TILES`、5 `SA_W_TILE_STRIDE`、6 `SA_COLS_USED`、7 `SA_S_BASE`、8 `SA_S_TILE_STRIDE`、9 `SA_O_BASE`、10 `SA_O_STRIDE`、11 `SA_MASK_COL`、12 `SA_EPS`（LN の ε、FP32）、13〜15 reserved。
- `DISPATCH` の flags[1] = SA。GSI1 の側: `rq`（63）、`qstat`（120）、`sastat`（121）、`qtag`（122）、`sactl.*`、header の flags[4]。**SA 構成で必須の optional の命令は無い**（案 B。`shfl` は有れば行の scale の合わせに使い、無ければ `lds`）。`CAPS[26]` と header の flags[5] は reserved（版 4 の packed の超越は取り下げ）。
- FP の PE の実装（ASIC）も scale + PAD を受けて捨てる（kernel は同じ）。

### A.4 zedBSD の側（§6.10）

- Vulkan には systolic array の API が無い。`VK_KHR_cooperative_matrix` はこの SA の形では実装できない（版 3 の H8）。**見せ方の推し（U30）**: v1 は GHCI 固有の compute の経路: (b) `GPU_OP_GHCI_NATIVE`（試験の build）で `SET_REG` の `SA_*` + `LOAD_PROGRAM` + `DISPATCH(SA)`、kernel（指揮の `sactl` の列）は `gsi1asm.py`（p020・p022）。製品の経路（p021、WS001 の外）は (c) 独自の拡張 `VK_KEI_systolic_dispatch`（案 B では **指揮だけなので GEMM・attention・LN の全部を拡張の構造体（SA_* の設定の列）で表せる**: FP16 の IR は要らない）。
- compute の use: driver は `CAPS[25]`・`CAPS[27]`・`SA_CAPS/2` を読み、拡張と capset に形と型と reduction の有無を名乗る。

### A.5 案 B の流れ（attention と layer norm）と cycle 数（SA に律速）

**取り下げた案**（記録）: 版 4 の最初の案は SU の packed FP16 の命令（`exp2h2` 等）と `rq` の pop/push で online の softmax/LN を SU の warp が 1 列ずつ処理する物で、1 warp で 25〜28 cycle/列（SA の 1 列/cycle の 1/25）、SU に packed の超越 5k LUT/SU と subgroup が要った。ユーザー「SUにベクトル命令と投機的オンラインsoftmaxの実装を考えましたが、ハードウェア効率が悪すぎるので、案BでSAに寄せましょう。SUはミニマルな形にしましょう。」で SA の段に移した（§10 の 34）。

**SU の kernel（指揮だけ。attention の 1 head、query 32 token の block ごと）**:
```
sactl.ctl 4 (acquire) ; sactl.ctl 8 (reset)
; S = Q·Kᵀ: Q の block を push（64 列 × 2 命令 = 128 命令）… または Q も memory から: ここでは SU が push
SET SA_CTRL = run | BFP | DBUF | RED=softmax | ODST=buffer | MASK ; sactl.wbase K_block ; sactl.sbase K_scale ; sactl.k 64 ; sactl.tiles 4 ; sactl.ctl 1 (start)
push scale+PAD ; push Q の 64 列（tile ごとに同じ Q を 4 回 push: 4 × 64 × 2 命令。または Q を memory から読む mode = v2）
sactl.ctl 9 (wait) ; sactl.ctl 6 (finalize: r_i = 1/s_i)
; O = P·V: feedback
SET SA_CTRL = run | BFP | DBUF | ODST=memory ; sactl.wbase V ; sactl.sbase V_scale ; sactl.k 128 ; sactl.tiles 2 ; sactl.obase O ; sactl.ctl 7 (feedback)
sactl.ctl 9 (wait) ; sactl.ctl 5 (release)
```
約 40 命令。SU の時間は Q の push（4 tile × 64 列 × 2 命令 × 2 cycle ≈ 1,000 cycle）だけで、残りは `wait` で止まっている（他の warp・SU1 は別の仕事を進められる）。

**例 1: attention（1 head、N = 128 token、d = 64。K・V は INT8 + 列の scale、Q は FP16）、query 32 token の block ごと、SA 32 × 32**:
- S の 4 tile: 入力 4 × 64 step、DBUF で重なり、stream-out 4 × 32 列 → **≈ 4 × 64 + 62 + 32 + 3 × 32（drain は 1 列/cycle、tile ごと）≈ 450 cycle**。reduction は stream-out と同じ 1 列/cycle（pipeline の遅れ ≈ 12）。生の x は token buffer に（128 列）。
- finalize: 32 行の rcp ≈ 40 cycle。
- feedback（P × V、128 列の P を normalize の段で作りながら入力、K = 128、出力 64 列 = 2 tile）: 2 × 128 step（P は buffer から 2 回読む）+ 62 + 32 + 32 ≈ **380 cycle**、出力は memory へ（64 line）。
- block ≈ 450 + 40 + 380 ≈ **870 cycle**。4 block ≈ 3,500 cycle ≈ **17 µs @200 MHz（35 µs @100 MHz）**。MAC 2.1 M / 3,500 ≈ **600 MAC/cycle（32 × 32 の峰の 59%）**。32 × 16 では tile の数が倍で ≈ 6,000 cycle（峰 512 の 70%）。
- **遅れ（最後の列から最初の正規化した出力まで）**: S の最後の列が reduction を出て（≈ 12）→ finalize（≈ 40）→ feedback の最初の列が normalize を通って配列に入る（≈ 10）→ 最初の出力の列が右の口に出る（K + 62 = 190）→ 並べ替え（32）→ **≈ 280 cycle**。
**例 2: layer norm（32 token × d = 256。入力は前の段の projection の tile の stream）**: projection 8 tile（K = 256）≈ 8 × 256 + 62 + 32 + 7 × 32 ≈ 2,370 cycle で reduction が Welford を進め x を buffer に；finalize（rsqrt）≈ 48；feedback の TWOPASS: pass 1（y の max、256 列）256 + pass 2（正規化して次の tile の入力か memory へ）256 ≈ 520 → **≈ 2,950 cycle ≈ 15 µs @200 MHz**。遅れ（最後の列 → 最初の y）≈ 12 + 48 + 256（pass 1）+ 10 ≈ 330 cycle（TWOPASS 無し = memory へ出すだけなら ≈ 70）。
**律速**: SA の配列（K step/tile + skew）と 1 列/cycle の段。SU は指揮だけで空く。v2: Q も memory から読む入口（SU の push を無くす）、SU ごとの SA。

### A.6 ASIC の構成（parameter）

- PE = FP16 × FP16 → FP32 の accumulate（`SA_CAPS[19:16]` の [1]。scale + PAD は受けて捨てる）。`SA_ROWS` = 32、`SA_COLS` は parameter（64・128）。reduction・normalize・token buffer は同じ形で幅だけ parameter。SA は SU ごとに 1 つ（README の LLM の流れ）。目標 800 MHz: 32 × 32 で 1.6 TOPS/SA。PE は SIMD 1（SIMD-8 は取り下げ: §10 の 33）。

## 18. DC を GHCI の GPU の一部に（CP の command で制御、present は queue の操作、割り込みは GHCI の IRQ。版 8、ws001-p035 の設計の段）

2026-10-25 P3（ws001-p035、q1574-i01、zedBSD の worktree p3-p006（main 101a2f742 の上）、amaterrace-gpu の worktree p3-p035（main aa78b64 の上））。承認: 2026-10-25 09:02 ユーザー「DCがGPUとは別になってしまっていますが、確かに伝統的にはそういう構成だったように思いますが、Vulkan Displayのcapabilityというような抽象化と考えれば、gpu/に移して、CPへのコマンドで制御可能にしてもいいかもしれません。そうすれば、コピーせずにscanoutするのが自然になるでしょう。GHCIの仕様にDCも入れてしまって、割り込みもGHCIの仕様にしませんか？」（[phase035](phase035/phase.md)）、同日「ゴールまで推しで進んでよいです。判断に迷ったら、Vulkan 1.0の原則論で進めてください。」。この節は設計だけで、RTL・firmware・driver・GHCI の文は書かない（実装の段は Q1 が後で割り当てる）。§4.2・§4.3 の MSI の表・§5・§6.5 の DC の記述は、この節が実装された時に置き換わる（§18.14 の D8）。design-reviewer の review（1 回目 28 件: Critical 2・High 7・Medium 13・Low 6、2 回目 21 件: High 5・Medium 10・Low 6）は全部を本文に反映し、対応の表は §18.15・§18.16。

### 18.0 出典と確認の水準

- **読んだ物（実測）**: amaterrace-gpu（p3-p035、aa78b64 + 398a738）の `docs/ghci.md` §3.1（HCR、IRQ_STATUS は [8:0] まで）、§3.2（CAPS[3] DISP、[10] WAIT_VSYNC）、§3.3（STATUS[7] は空きに見えるが `atg_top.v` 377 行で `sa_busy` が繋がり、この設計の §3.9・Appendix A が SA_BUSY に予約している）、§4（DISP は id 1）、§5（CP の状態と「RUNNING では STATE の alias・KICK は無視して fault kind 6・7」）、§7.3（µop 0〜14、WAIT_IDLE の flags は 8 bit の mask）、§9、§10（「DC は CTRL.RESET で reset しない」）、§13（DISP、DC の単独の device の形）、§15.2（MSI は 1 vector）、§16（minor は追加だけ）。`include/ghci_regs.h`・`ghci_packets.h`（op 14 まで）・`ghci_layout.h`（linear、行は w × ps（attachment は w を偶数に）、image は 64 B に揃う）。`spec/dc/atg_dc.md`・`atg_dc_dma.md`（base と stride は LINE_BYTES に揃える）・`atg_dc_regs.md`（128 B の窓、`w_off[6:0]`）、`rtl/dc/`（7 file、1348 行。`atg_dc_regs.v` は既に `flip_pending` を持ち vsync の `ev_flip && flip_pending` で取る、DC の CTRL.RESET は pending を pulse 無しで消す）、`rtl/gpu/cp/atg_cp_seq.v`（port 38: uop の書き込み（`uop_we`・`uop_idx` 10 bit）、fence の要求（`f_op` 2 bit）、`busy_in` 8 bit）、`atg_cp_seq_wait.v`（`B_ALL = 8'hFE`: bit 7 を含む。FENCE・RESULT・QUERY・WAIT_IDLE(0) の pre）、`atg_cp_ctl.v`（client ≠ 0 の MC の fault は device の fault）、`spec/gpu/cp/atg_cp_fence.md`（FSM 1 つ、WAIT_FENCE は watchdog まで握る、firmware の µop も通る）、`spec/README.md`（1 module 1 clock domain、crossing は `am_afifo`・`am_sync` だけ、port の group は AXI・AMB・HCR snoop だけ）、`boards/kc705/atg_kc705_raster.v`（DC は atg_top の外、`xr_*`、MC の client EXT、`dc_irq` は LED だけ）、`rtl/gpu/top/atg_top.v` の `HAS_DISP`・`EXT_CLIENT`・`ROOT_CLIENT`。zedBSD（p3-p006）: `src/drivers/gpu/ghci/display.c`（820 行: 2 つの driver の frame に BLT で copy、FB_NEXT を host が書いて FLIP_DONE を待つ、BLOB の present は EINVAL、modes は "ATDC" の 2 つを driver が知る、`registers > register_bytes − 0x80` の検査）、`adv7511.c`（246 行）、`ghci.c`（`ghci_cp_start`（RUN）が `ghci_display_attach` より先）、`cp.c`（`IRQ_TAKEN`、`program_ring` が IRQ_STATUS に `IRQ_ALL` を書く）、`include/drivers/gpu/gpu-display.h`（UNGATED と adoption_wait、power/refresh は両方か無し、cursor の 3 つ）、`include/uapi/gpu-scanout.h`（`GPU_PLACEMENT_*` は DMA32・CONTIGUOUS・COHERENT だけ、`GPU_SCANOUT_SHARED`/`COPY`、「the route is selected once for a swapchain, never per presentation」）、`include/uapi/gpu-display.h`（present の BLOB と FIFO、非 BLOB は「呼び出しの後は storage を借りない」、cursor は 64 × 64 まで・BGRA8888 か RGBA8888・premultiplied・呼び出しの間に copy・面が尽きたら EBUSY・device の fault で隠す、adoption の timeout の後の present は EBUSY）、`userland/desktop/libvulkan/wsi-display.c`（present は PRESENT_SYNC（wait_fd）か、worker が producer の完了を確かめてから PRESENT、`display_mutex` を present の間持つ）、§17（DC は EXT、検査しない、root の別の入口）。
- **推定**: LUT・FF・BRAM（合成していない）、flip の遅れ、LW。
- **未確認**: KC705 の ADV7511 の INT（HPD の割り込み）の線が FPGA の pin に来るか（UG810 未読、ADI の kc705 の constraint には無い）、ADV7511 の HPD の register（0x42[6] は programming guide の記憶）と HPD の落ちで設定が消える事（実機 p024）。

### 18.1 目標と範囲（v1 で達する物と達しない物）

- **目標**: (1) DC は GPU の unit の 1 つ（`rtl/gpu/dc/`、`atg_top` の子）。(2) scanout の状態（ENABLE・FB・timing・format）は CP が RUNNING の間 **ring の µop** だけが変える: present は ring の中の FLIP で、ring の順で前の packet の後に置かれ、次の vsync で切り替わる。driver の frame への copy も host の FB_NEXT の write も無い。(3) DC の event（vblank・flip の取り込み・scanout の誤り・hotplug）は **GHCI の IRQ_STATUS** の bit（PCIe の MSI は 1 vector のまま）。(4) display・mode・plane の列挙は GHCI の register（`VK_KHR_display` の display・mode・plane に対応）。(5) DC の条件に合う swapchain は直に scan（SHARED の route）、合わない時は copy の route（ring の BLT の後に FLIP）。(6) cursor の plane。
- **v1 で達しない物（正直に）**: zedBSD の display の core は PRESENT_SYNC の依存（producer の fence）を backend を呼ぶ前に CPU で待ち、libvulkan の PRESENT の道も worker が producer を待つ。だから v1 では「前の draw の完了」を CPU が確かめてから FLIP が ring に入り、producer の完了 → CPU の wake-up → FLIP の間に vsync を逃し得る。GHCI の FLIP は前の仕事を自分で待てる（COMPLETE）ので、core が依存を backend に渡す形にすれば CPU は外れる（U98、後の Phase）。また ring は 1 本で、FLIP は他の session の長い class 2 の packet（firmware の replay）の後ろで待つ: 負荷の下では FIFO の present が vsync を逃し得る（risk §18.13、p028 で「負荷の下の flip の vsync の取り逃し率」を測る。対策の候補は display 用の高い優先の ring（CAPS2[7:0] の rings、後の版））。
- **範囲の外**: overlay の plane（zedBSD の `commit`/`overlay_info`）、scaler、複数の output、programmable な pixel clock（EDID の任意の mode）、tile の image、display の電源と refresh（`GPU_CAP_DISPLAY_CONTROL`、power/refresh は v1 で両方無し）、zedBSD の display の core の変更（U98）。

### 18.2 決めた事の要約

1. **置き場所**: `rtl/dc/` → `rtl/gpu/dc/`、`spec/dc/` → `spec/gpu/dc/`。`atg_top` が `HAS_DISP` で `atg_dc` を子に持つ（pclk・video・I2C の pin は atg_top の port）。DC の MC の client は atg_top の中の `C_DC`（`ROOT_CLIENT`、§17.5 の root の別の入口）。**DC と `C_DC` の root の入口は board の reset（DC と同じ）の domain に置き、CTRL.RESET（core の reset）の「memory client の queue の flush」から外す**（scanout の read は GPU の reset を跨ぐ）。MC は既に board の reset で動くので、domain だけでは足りない: `atg_mc` の `QUIESCE_EXEMPT` に C_DC を入れ（HALTING・HALTED・FAULTED・RS_WAIT の間も scan を止めない）、`axi_idle` を GPU 自身の client の未応答と DC の未応答に分けて数え（HALTED・RESET の待ちが DC の読みの切れ目を待たない）、CTRL.RESET の flush は C_DC の道（root の入口・木の C_DC の枝・応答の道）を残す（DC の要求と応答を捨てると `atg_dc_dma` の `inflight` が戻らず DMA が止まる）。HAS_PROT の構成では DC は §17.5 の root の別の入口を通り、そこも flush から外す。`EXT_CLIENT` は別の外の client のために残し KC705 は 0。単独の DC の parameter `STANDALONE` は消す（使う board が無い。GHCI の「CP の無い DC」の文は残す、U97）。
2. **新しい capability（U99）**: CP の有る GPU の DC は新しい capability **DISP2**（id 11、draft の番号）で名乗る。DISP（id 1）は CP の無い DC だけ（今の register の意味のまま）。今の driver は DISP2 を知らないので display を作らないだけで、RUNNING の中の直の write で fault する事は起きない（GHCI §16 の minor の規則を守る）。
3. **書く者の境（U90）**: DISP2 の register は 4 種。**R**（ID・CAPS・STATUS・FB_BASE・FRAME_COUNT・mode の表・CURSOR_BASE）はいつでも host が読む。**I**（MODE_INDEX）はいつでも host が書く（副作用無し）。**S**（scanout: CTRL・FB_STRIDE・FB_SIZE・timing・SYNC_POL・PCLK_SEL、と FB_NEXT）は CP が RUNNING・HALTING の間は ring の µop だけ。host は IDLE・HALTED・FAULTED で書ける（bring-up・JTAG・recovery・panic の消灯）。RUNNING・HALTING の host の write は**捨てて STATUS[5] BAD_WRITE（sticky）を立てる**（device の fault にしない: DC は CTRL.RESET で戻らないので、reset しても何も直らない）。**C**（cursor の位置と表示: CURSOR_POS・CURSOR_CTRL）と **L**（link: I2C・CONNECTED）と **W**（STATUS の W1C）はいつでも host が書く（memory を指さない。cursor は GPU の負荷に依らず動く）。**排他**: CP の DISP の µop（DISP_SET の書き込み・FLIP の slot への置き込み）は CP が RUNNING・HALTING の時だけ効き、IDLE・HALTED・FAULTED の間は捨てる（その µop は何もせずに終わる。HALTED の STEP の DISP µop も同じ）。だから host と CP が同じ時に S を書く事は無い（HALTED の間に packet の残りの DISP_SET が host の消灯を覆さない）。
4. **command は class 0 の µop（U91）**: **15 DISP_SET**（S の register のうち FB_NEXT を除く物と C の register への (offset, value) の対。flags[0] WAIT_IDLE: 書いた後 DISP の STATUS.idle を待つ（watchdog の対象））、**16 FLIP**（plane、base、record、value。flags[0] COMPLETE）。STATUS の busy の bit と WAIT_IDLE の mask は**使わない**（bit 7 は SA。DC は FENCE・RESULT・QUERY・WAIT_IDLE(0)・FLIP COMPLETE の「全部の unit」に入らない: 点いている DC は idle にならないので入れると全部が止まる）。firmware は要らない（CAPS[17] = 0 の GPU でも動く）。DISP_SET と FLIP は ring の µop だけ（ring は driver だけが書く）: firmware の UOP_FIFO からは fault kind 2。
5. **present = FLIP**: FLIP は（COMPLETE なら FENCE と同じに前の仕事の全部の完了を待って）base を確かめ（aperture の外、MEM の有る GPU で local memory の外、揃いの違反は fault 3）、plane の **待ちの slot** に base と record を置き、ring は先へ進む。DC が取り込むと（plane 0 は次の vsync、ENABLE = 0 の時はすぐ。plane 1 は BRAM に読んだ後の frame の始め。ENABLE の落ち・DC の reset では cancelled ですぐ）、`atg_cp_disp` の record の書き手が `{value, FRAME_COUNT}` を書き、その応答の後に IRQ_STATUS.FLIP。slot は plane ごとに 1 つで、前の record の応答が来るまで次の FLIP を受けない（record は重ならない）。slot に置くのは前の仕事の待ち（COMPLETE）と slot の空きの待ちが**両方済んだ後**（seq の exec の時点、§18.4）で、payload を受けた時点ではない。slot が埋まっている FLIP は seq が待つ（watchdog の対象）が、driver は slot の空きを数えて置くので通常は起きない（§18.8）。
6. **割り込み**: IRQ_STATUS [9] VBLANK、[10] FLIP、[11] DISP_ERROR（scanout の read の誤り・underflow・record の write の誤り。STATUS[1]・[3]・[4] が何かを言う。DC は 1 frame に高々 1 回だけ立てる）、[12] HOTPLUG（CONNECTED の変化）。IRQ_ENABLE も同じ bit。§4.3 の「XDMA の user IRQ 1 = DC」は無くなり MSI は 1 vector。
7. **scanout の誤りは device の fault にしない**: `C_DC` の MC の誤り（aperture の外・AXI の error）は `atg_cp_ctl` の device の fault から外し、DC は誤った line の画素を 0（黒）にして DISP_ERROR を立て、次の frame も同じ base を読む（driver が消灯か別の FB で直す）。record の write の誤りは捨てて STATUS[4] と DISP_ERROR（reset を跨いで再送しない）。
8. **mode と plane の列挙（U96）**: DISP2 に mode の表（MODE_INDEX と 6 つの R）と plane の数（DC_CAPS）。driver は vendor の mode の表を持たない。
9. **image の条件**: format は DC_CAPS[7:4]（Amaterrace: BGRA8・RGBA8・RGB565。SRGB の VkFormat も同じ bit の並び）、1 sample、linear（`ghci_layout.h` の 2D・level 0・layer 0）、base と stride は **LINE_BYTES（KC705 64 B）に揃う**（v1 の 2 mode の行は 2560・5120 B で 64 の倍数、image は 64 B に揃うので足りる。DC の DMA は変えない）、大きさは mode と同じ（scaler も窓も無い）、local memory の中（MEM の LOCAL の範囲。v1 は host memory を scan しない: 720p60 の 221 MB/s の read を PCIe で取ると underflow の risk）。合わない swapchain は copy の route。
10. **cursor の plane（U93）**: plane 1 = 64 × 64 の BGRA8（premultiplied、行は 256 B）。DC は gclk の中で、DMA が出す画素の流れ（pixel FIFO の前）に cursor を合成する（新しい clock の crossing は無い）。
11. **transmitter と hotplug（U92）**: ADV7511 の設定と HPD の監視は**今のまま host の driver**（`adv7511.c`、L の register はいつでも host の物）。HPD は driver の service thread が I2C で 1 s ごとに読み、CONNECTED に書く（→ HOTPLUG。CONNECTED の reset の値は 1 = 不明は接続と見なす）。DC_CAPS[12]（DC が自分で接続を知る）は Amaterrace では 0。
12. **session の保護（U94）**: DC の読みは §17 のとおり検査しない（root）。FLIP は driver の µop で、scan してよい image は driver が確かめる（lease の持ち主の session の allocation、または share で import した物）。driver は scan されている allocation を flip で外れるまで持つ（free を遅らせる）。record の write も chk = 0（driver の memory）。

### 18.3 GHCI の変更（§13 の書き直しの案、draft。実装の段 D1 で `docs/ghci.md` に書き、D8 で確定）

- §3.1 IRQ_STATUS: [9] VBLANK、[10] FLIP、[11] DISP_ERROR、[12] HOTPLUG（DISP2 の event）。IRQ_ENABLE は [12:0]。§3.2 CAPS[3] の文に「DISP or DISP2」。§4 の表に id 11 DISP2。
- §7.3 の µop（WAIT_IDLE の行に「0 = every unit; a display controller is not a unit here」を足す）:

| Op | Name | Payload | Meaning |
| --- | --- | --- | --- |
| 15 | DISP_SET | (offset, value) x n/2 | (DISP2.) Writes DISP2 registers of kinds S (but not FB_NEXT) and C in ring order; it does not wait for earlier work (send WAIT_IDLE first when that matters). flags[0]: afterwards waits until DISP2 STATUS.idle (the watchdog applies). An odd n or another offset: fault 3. From the firmware's micro-op FIFO: fault 2 |
| 16 | FLIP | 4: plane, base, record, value | (DISP2.) flags[0] COMPLETE: first waits as FENCE does for every earlier command to finish and its writes to be answered. base outside the aperture, outside local memory (with a MEM capability), or not aligned (plane 0: the memory line; plane 1: 64 bytes); record not 8-byte aligned: fault 3. Then waits until the plane has no pending flip and no unanswered record (the watchdog applies) and makes base the plane's pending image. When the controller takes it (plane 0: at the next vsync, at once while CTRL.ENABLE is 0; plane 1: once the controller has read the image, between two frames, whether the cursor is shown or not; a pending flip of either plane is taken as cancelled when ENABLE falls or at the controller's reset), the GPU writes {value, FRAME_COUNT} to record (8-byte aligned, the GPU's own write: no session check; record 0: no write) and raises IRQ_STATUS.FLIP after that write's response (at the take when record is 0). A cancelled flip's record has bit 31 of value set (the driver's values use 31 bits); a host write of FB_NEXT also cancels a pending flip of plane 0. DISP_SET and FLIP take effect only while the CP is RUNNING or HALTING (in other states, a STEP included, they do nothing). From the firmware's micro-op FIFO: fault 2 |

- §13 に DISP2 の節（案）を足し、今の §13 は「13.1 DISP: a display controller without a command processor」として残す:

```
13.2 DISP2: a display controller that is a unit of the GPU

A GPU with a command processor names its display controller with a DISP2
capability (ID 11). The command processor changes what it shows, in ring
order, with the micro-ops DISP_SET and FLIP (section 7.3); its events are
IRQ_STATUS bits 9-12 (section 9.2). A display controller is not one of
the units that FENCE, RESULT, QUERY, WAIT_IDLE with flags 0 and FLIP
COMPLETE wait for, and its memory reads are not counted by AXI_IDLE or
stopped by a quiesce. It has its own reset (CTRL.RESET of DISP2) and is not
reset by the GPU's: it keeps scanning through a GPU reset, and a pending
flip is still taken. The GPU writes the record of a flip taken while the
command processor is HALTED, FAULTED or RESETTING, or quiesced, only after
it runs again. An error of a scan-out read is not a device fault: the
controller shows black for the rest of the frame and reports DISP_ERROR.

Registers: a window of 256 bytes at the capability's register offset.
Kinds: R read-only, read by the host in every state. I an index without
side effects, written by the host in every state. S scanout: written by
DISP_SET (FB_NEXT by FLIP only) while the command processor is RUNNING or
HALTING, and by the host in IDLE, HALTED and FAULTED; a host write in
RUNNING or HALTING is ignored and sets STATUS.BAD_WRITE. C cursor, L link
and W (the write-1-to-clear bits of STATUS): written by the host in every
state (C also by DISP_SET). DISP_SET and FLIP do nothing outside RUNNING
and HALTING, so the host and the command processor never write S at the
same time. A write of the timing, FB_STRIDE, FB_SIZE, CTRL.FORMAT or
PCLK_SEL while ENABLE = 1 is ignored and sets BAD_WRITE.

| Offset | Name | Kind | Contents |
| 0x00 | DC_ID | R | FourCC of the controller |
| 0x04 | DC_VERSION | R | [31:16] major, [15:0] minor |
| 0x08 | DC_CAPS | R | [0] VGA, [1] TMDS, [2] external transmitter on the I2C registers, [7:4] formats ([4] BGRA8, [5] RGBA8, [6] RGB565), [8] cursor plane, [11:9] number of modes, [12] the controller senses the connection itself |
| 0x10 | CTRL | S | [0] ENABLE, [1] RESET (W1S), [2] TEST_PATTERN, [5:4] FORMAT (0 BGRA8, 1 RGBA8, 2 RGB565), [6] OUTPUT (0 VGA, 1 HDMI) |
| 0x14 | STATUS | R, W | [0] running, [1] underflow, [2] idle (ENABLE = 0 and no memory access outstanding, the cursor's included), [3] read error, [4] record error, [5] BAD_WRITE ([1], [3]-[5] sticky, W1C; each raises DISP_ERROR at most once a frame), [15:6] reserved, [27:16] current line, [28] CONNECTED, [29] plane 0 flip pending, [30] plane 1 flip pending, [31] a taken flip's record is not written yet |
| 0x20 | FB_BASE | R | The image being scanned out (plane 0) |
| 0x24 | FB_NEXT | S | Plane 0's pending image (FLIP writes it; a host write replaces a pending flip, which is cancelled); taken at the next vsync, at once while ENABLE = 0 |
| 0x28 | FB_STRIDE | S | Bytes per row, a multiple of the memory line |
| 0x2C | FB_SIZE | S | [15:0] width, [31:16] height |
| 0x30..0x4C | H_ACTIVE .. V_BP | S | Timing |
| 0x50 | SYNC_POL | S | [0] hsync, [1] vsync; 1 = active high |
| 0x54 | FRAME_COUNT | R | Vsync count, cleared by the controller's reset (not a time base) |
| 0x58 | PCLK_SEL | S | The mode's clock choice (MODE_FLAGS[7:4]) |
| 0x60..0x68 | I2C_CTRL, I2C_DATA, I2C_STATUS | L | As in DISP |
| 0x6C | CONNECTED | L | [0] the sink is connected (1 after the controller's reset); a write that changes it raises HOTPLUG. Read-only with DC_CAPS[12] |
| 0x70..0x7C | vendor | R | Implementation-defined |
| 0x80 | MODE_INDEX | I | Selects a mode, 0 .. DC_CAPS[11:9] - 1 |
| 0x84 | MODE_H0 | R | [15:0] active pixels, [31:16] sync |
| 0x88 | MODE_H1 | R | [15:0] front porch, [31:16] back porch |
| 0x8C | MODE_V0 | R | [15:0] active lines, [31:16] sync |
| 0x90 | MODE_V1 | R | [15:0] front porch, [31:16] back porch |
| 0x94 | MODE_CLOCK | R | Pixel clock in kHz |
| 0x98 | MODE_FLAGS | R | [0] hsync, [1] vsync active high; [7:4] the PCLK_SEL value |
| 0xA0 | CURSOR_BASE | R | The cursor image shown (plane 1; FLIP sets it) |
| 0xA4 | CURSOR_POS | C | [15:0] x, [31:16] y (signed: the image's top-left corner; parts outside are clipped); taken at the start of the next frame |
| 0xA8 | CURSOR_CTRL | C | [0] shown; taken at the start of the next frame |
| 0xB0, 0xB4 | TAKEN0, TAKEN1 | R | The value of the plane's last taken flip (bit 31: cancelled), kept through a GPU reset |

- An image is scanned as rows of FB_SIZE.width pixels FB_STRIDE bytes
  apart, in linear layout (section 8, ghci_layout.h), one sample, in local
  memory where a MEM capability says there is local memory.
- Plane 1 (DC_CAPS[8]) is a 64 x 64 image of BGRA8 rows 256 bytes apart,
  premultiplied, blended over plane 0 as c + round(p x (255 - a) / 255),
  saturated (red and blue swapped for an RGBA8 plane 0; an RGB565 plane 0
  widened by repeating its top bits and narrowed by rounding). The
  controller reads a newly flipped cursor image once, between the end of a
  frame's reads and the next frame, and shows it from that frame (the
  take). TEST_PATTERN shows no cursor.
- To stop: DISP_SET CTRL.ENABLE = 0 with flags[0] (or the host in IDLE,
  HALTED or FAULTED, then poll STATUS.idle). Clearing ENABLE takes every
  pending flip at once, as cancelled. CTRL is written as a whole word
  (FORMAT and OUTPUT with ENABLE).
- The timing, FB_STRIDE, FB_SIZE, FORMAT and PCLK_SEL change only with
  ENABLE = 0. STATUS.underflow is cleared when ENABLE goes from 0 to 1; a
  frame starts with a vsync after ENABLE.
```

- §15.2 の Interrupts の行に「the events of a DISP2 display controller are bits of IRQ_STATUS: one vector covers them」。
- version: DISP2 は version 1。GHCI_VERSION の minor を上げる（capability・µop・IRQ の bit の追加、§16 に合う）。

### 18.4 RTL: CP の中の道（新しい子 `atg_cp_disp`）

- **持つ物**: plane ごとの待ちの slot `{valid, base, record, value}`（2 つ）、payload の staging、TAKEN0/1（最後に取った value と cancelled）、record の未送の印、**record の書き手**（CP の `am_amb_mux` の新しい leaf（4 つ目、ID_W 2 に入る）、chk = 0・tbl = 0・slot = 0 を §17.4 の side band に繋ぐ（§17 の R3 と D4 のどちらが後に merge しても後の方が繋ぐ。§17.5 の client ごとの順序で、chk = 1 の PLB の miss の後に record が少し待つのは許す）、8 byte を 1 beat で write、応答の後に IRQ の pulse。fence unit とは別: fence unit の FSM は 1 つで、ring と firmware の WAIT_FENCE が watchdog まで握るので、record を遅らせない）、DC の register の内部の bus の調停、host の門、event の集め。**`atg_cp_disp` と DC は board の reset の domain**（CTRL.RESET で slot と未送の record が消えない）。
- **seq との口（D1 で port を確かめる、確認 C3）**: (1) **index**: DISP_SET の対は今の uop の書き込みの port（`uop_we`・`uop_idx` 10 bit）の **0x3C0〜0x3FF**、FLIP の payload の 4 語は staging の 0x3B8〜0x3BB、DISP_SET の flags[0] は擬似の index 0x3BF への書き込み。`atg_cp` は `uop_idx[9:8] == 2'b11` を `atg_cp_state` に渡さず（state の mem は 0x2FF まで、TU への broadcast にも出さない）`atg_cp_disp` に回す。seq は DISP_SET と FLIP の payload を SET_REG の `set_val` の道でなく `pay_wait = 0` の別の枝で書き、offset が 0x100 以上・4 の倍数でない・上位の bit が立つ時は seq が fault 3（`fault_addr` = offset）。(2) **待ち**: 今は使われていない `busy_in[0]`（`atg_cp.v` で 0、`B_ALL = 8'hFE` は bit 0 を含まない）を `disp_busy` にする: staging に FLIP が有る時は「その plane の slot か record が埋まっている」、0x3BF が書かれた後は「DC が idle でない」。FLIP は exec の pre の mask を `(COMPLETE ? B_ALL : 0) | 1`、DISP_SET の flags[0] は post の mask を bit 0 で待つ。「全部の unit」の待ち（FENCE・RESULT・QUERY・WAIT_IDLE(0)）は bit 0 を含まないので DC を待たない。(3) **kick**: `raw_kick`・`lc_kick`・`blt_kick`・`draw_kick`・`cs_kick` を 1 本の kick の valid と 3 bit の code にまとめ、code に `disp`（FLIP）を足す。`atg_cp_disp` は exec の kick の時に staging の FLIP を確かめて（fault 3）slot に置く: 前の仕事と slot の空きの待ちの後。seq の port は今 40（clk・rst_n を含む。spec の「38」は clk・rst_n を除いた数と見られ、D1 で数え方を揃える）→ kick の束ねで −3 → §17 の +2 → 39。seq の行は 374 + §17 の R3 + op 15・16 の decode（`h_need`、HAS_DISP の parameter と無い時の fault 2、`use_fw` の fault 2、対の写像と offset の検査）で 400 を超えるので、D1 で payload の decode を子 `atg_cp_seq_dec` に分ける計画を立てる。
- **取り込みと record**: DC の `taken[p]`（plane 0 は vsync、plane 1 は BRAM への読みの後、どちらも ENABLE の落ちと DC の reset では cancelled）で slot を降ろし、TAKENp を書き、record ≠ 0 なら record の書き手に渡す（STATUS[31] はその間 1）。CP が HALTED・FAULTED・RESETTING・QUIESCED の間は送らず、CP が IDLE か RUNNING に戻ってから送る（§5・§10 の quiesce の約束）。host の FB_NEXT の write で slot が降りる時も cancelled（value の bit 31）。
- **host の門**（窓の decode は `atg_cp_regs`。host の read も `atg_cp_regs` が内部の bus で DC に 1 cycle で読みに行く）: host の write を DISP2 の窓（256 B）と比べ、S なら CP の state が IDLE・HALTED・FAULTED の時だけ通し、他は捨てて BAD_WRITE。C・L・I・W はいつでも通す。seq の DISP の書き込みと kick は逆に RUNNING・HALTING の時だけ通す（§18.2-3 の排他）。門は 1 段の host の write の buffer を持ち、seq の write と同じ cycle でも捨てない（host の bus は止めない）。JTAG の bridge（DBG）の write も同じ門。
- **調停**: 内部の bus の書き手は seq > host の buffer。firmware の道は作らない（U92 で firmware は DC を触らない）。
- **UOP_FIFO の DISP µop**: seq は µop の出どころ（`fw_active`）を知る。FIFO からの 15・16 は fault kind 2。
- **IRQ**: VBLANK・DISP_ERROR・HOTPLUG の DC の pulse と record の応答（FLIP）を `atg_cp_irq` の [12:9] に。
- **MC の fault の扱い**: `atg_cp_ctl` は `mc_fault_client == C_DC` を device の fault にしない（`atg_top` が C_DC の番号を parameter で渡す）。DC の read の誤りは DC が自分で STATUS[3] に。
- **`atg_cp_disp` の fault 3**: `atg_cp_ctl` の fault の源は今 8 つ全部使われている（`NSRC = 8`）ので 9 にする（`SRC_*` の幅と vector）。tag は kick の時に latch した seq の今の µop の tag。

### 18.5 RTL: DC の変更（`rtl/gpu/dc/`）

- **`atg_dc_regs`**（今 280 行）: (a) 窓を 256 B（8 bit の decode）。(b) 今の `flip_pending` に、ENABLE の落ち・DC の reset・ENABLE = 0 の FB_NEXT の write でもすぐ取る形と `taken[0]` の pulse を足す（今の RTL は DC の reset で pending を pulse 無しで消し、ENABLE = 0 の write で古い pending を残す: 直す）。(c) mode の表（parameter の ROM、Amaterrace の 2 mode: 640 × 480 @ 60 = 25,200 kHz、1280 × 720 @ 60 = 74,250 kHz、今の driver の表と同じ値）と MODE_INDEX。(d) CONNECTED（reset で 1、変化の write で pulse）。(e) CURSOR_POS・CURSOR_CTRL（frame の始めに取る）と plane 1 の pending（`taken[1]`）。(f) STATUS の [3]〜[5]・[28]〜[30]、DISP_ERROR の pulse は 1 frame に 1 回まで。(g) DISP2 では IRQ_STATUS/ENABLE を作らず event の pulse を外へ（CP の無い DISP の形は parameter で残すか、STANDALONE と一緒に消す: U97 で消す）。(h) register の bus は内部の bus 1 つ（窓の decode は `atg_cp_regs`、§18.4）。(i) ENABLE = 1 の間の timing・FB_STRIDE・FB_SIZE・CTRL.FORMAT・PCLK_SEL の write は捨てて BAD_WRITE。(j) TAKEN0/1 と STATUS[31]（`atg_cp_disp` から）。行が 400 を超えそうなら mode の表と cursor の register を子 `atg_dc_mode` に分ける。
- **`atg_dc_dma`**: base と stride は LINE_BYTES のまま。変えるのは 2 つ: read の error の応答を `err` の出力に（STATUS[3]。画素は今のとおりその line が 0）、`inflight` と `keep` が自分の応答だけを数えるように `rsp_tag[7:4]` を見る（cursor の読みと AMB の口を共有するので）。
- **`atg_dc` の中の `am_amb_mux`**: DMA（優先）と `atg_dc_cursor` の 2 つの requester を DC の 1 つの AMB の口にまとめる（tag の上位で返事を分ける）。
- **`atg_dc_cursor`（新、gclk だけ、U93）**: DMA の出す画素（`px_valid`・`px_data`、pixel FIFO の前）を通しに受け、行と列を数えて (x, y) を作り、cursor の BRAM（16 KiB、BRAM36 × 4）と CURSOR_POS を比べて合成し pixel FIFO に出す（gclk 100 MHz の 1 px/cycle は 74.25 MHz の pclk より速い）。位置・表示は DMA の frame の始め（`frame_start`）に取る（gclk の中、新しい crossing 無し）。新しい cursor の image は、DMA がその frame の最後の line を読み終えた後から次の `frame_start`（back porch の始め）の前までに読む（256 line、≈600 gclk。窓は垂直の front porch と sync と最後の行の先読みの分: 720p で ≈(5 + 5 + 1.5) 行 × 1650 pclk ≈ 19k pclk ≈ 26k gclk、480p で ≈12 行 × 800 ≈ 13k gclk）。cursor が隠れていても読む。読み終えた次の `frame_start` が取り込み（`taken[1]`）。ENABLE = 0・DC の reset では読まずに cancelled。読みの error は cursor を消し STATUS[3]。RGB565 の primary では DMA の画素を上位 bit の繰り返しで 8 bit に広げて合成し、丸めて 565 に戻す（alpha 0 で元の画素がそのまま残る事を TB で確かめる）。RGBA8 の primary では cursor の R と B を入れ替える。TEST_PATTERN では cursor を出さない。合成は `c + round(p × (255 − a) / 255)` を飽和（BLT の blend と同じ丸め）。STATUS.idle は cursor の読みも数える。
- **`atg_dc`**: 子 `atg_dc_cursor`、`taken[1:0]`・event の pulse・内部の register の bus、`STANDALONE` を消す。port は spec/README の数え方（AMB は 1 group、他は 1 本ずつ）で 40 以下か D1 で確かめ、超えれば video の出力を子 `atg_dc_out` の結線に寄せる。
- **`atg_top`**: `HAS_DISP` で `atg_dc` と `atg_cp_disp` の配線、`C_DC`、pclk・prst_n・pclk_sel・video（tmds・px 4 本）・I2C（4 本）の port。今の `xr_*`・`x_vsync`・`x_req_*` は HAS_DISP の外の DC のための物で、HAS_DISP = 1 では使わない。
- **board の top（`atg_kc705_raster`）**: DC の instance を消し、video と I2C の pin を atg_top へ。`EXT_CLIENT(0)`、`HAS_DISP(1)`。

**module の表**（1 module ≤ 400 行・FSM 1 つ・≤ 40 port、port は spec/README の group で数える）:

| module | 新/変 | 中身 | 推定の行・port |
| --- | --- | --- | --- |
| `atg_cp_disp` | 新（`atg_cp` の子） | slot 2 つ、staging、TAKEN、record の書き手（AMB の leaf、FSM 1 つ）、index の decode と fault、host の門と buffer、排他、event | ≈320 行、≈32 port（AMB 1 group） |
| `atg_cp_seq` | 変 | op 15・16、`busy_in[0]` の待ち、kick の code、payload の decode を子へ | 374 + R3 → 子に分けて ≤ 400、port 39 |
| `atg_cp_seq_dec` | 新（seq の子、D1 で決める） | payload の decode（SET_REG・DISP_SET の対の写像と検査、FLIP の staging） | ≈150 |
| `atg_cp_ctl` | 変 | C_DC の MC の誤りを device の fault から外す、fault の源 9 | +15 |
| `atg_mc`・`atg_mc_tree`・`am_axi_master` | 変 | QUIESCE_EXEMPT に C_DC、axi_idle の分け、flush で C_DC の道を残す | +40 |
| `atg_dc_dma` | 変 | err の出力、自分の tag だけ数える | +10 |
| `atg_cp_regs` | 変 | DISP2 の EXTCAP、窓の decode と門への道 | +30 |
| `atg_cp_irq` | 変 | [12:9] | +10 |
| `atg_cp` | 変（結線） | `atg_cp_disp`（今 436 行の結線の module: 結線の一部を `atg_cp_disp` に寄せて増やさない） | ≈440 |
| `atg_dc_regs` | 変 | §18.5 の (a)〜(h) | 280 → ≈380（超えれば `atg_dc_mode` を分ける） |
| `atg_dc_cursor` | 新（`atg_dc` の子） | 合成、BRAM、読みの FSM | ≈250 行、≈25 port |
| `atg_dc` | 変（結線） | cursor・taken・event・内部の bus | ≈220 |
| `atg_top` | 変（結線） | DC と `atg_cp_disp`、C_DC、video・I2C の port | +60 |
| `atg_kc705_raster` | 変 | DC を消す | −30 |

### 18.6 firmware（`fw/cp/`）

- **変更無し**（U92 で ADV7511 と HPD は host の driver に残す）。firmware は DISP_SET・FLIP を UOP_FIFO に書かない（hardware が fault 2 で止める）。IMEM（61,032 / 65,536 B）に影響しない。

### 18.7 zedBSD の driver（`src/drivers/gpu/ghci/`）

- **attach の順**: `ghci_display_attach`（DISP2 を探し、mode の表を読み、host が直に DC を reset・消灯・CONNECTED を読み、ADV7511 を設定）を `ghci_cp_start`（RUN）の**前**に移す（RUN の後の直の S の write は BAD_WRITE で捨てられる）。DISP2 の version を確かめる。窓の大きさの検査は `registers > register_bytes − 0x100`。
- **lock**: display の lock を新しく（`device->lock` → display の lock → `cp_lock` の順）。host の直の S の write は全部 `cp_lock` の中（recover の RUN の書き込みも `cp_lock` の中なので、「CP が止まっている」と見てから書くまでに RUN にならない）。MODE_INDEX と MODE_* の読みも display の lock の中（共有の index）。DC の CTRL.RESET は I2C も reset するので、I2C の使用（ADV7511・HPD の poll）と CTRL.RESET も display の lock で直列にする。**待ちの規則**: record を待つ者（mode の変更・消灯・adoption_wait）は service thread に頼らず record の page と TAKENp を自分で poll する（service thread が display の lock を待っていても詰まらない）。service thread は lock を持ったまま ring の空きや record を待たない。recover（service thread）は display の lock → `cp_lock` の順に取る（宣言の順と同じ）。
- **点灯と消灯**（ring の packet、tag 0、`cp.c` の native の packet の道）: 点灯 = `DISP_SET(flags[0]; CTRL = FORMAT | OUTPUT)`（ENABLE = 0）→ `DISP_SET(timing, SYNC_POL, PCLK_SEL, FB_STRIDE, FB_SIZE)` → `FLIP(0, base, record, n)`（ENABLE = 0 なのですぐ取る）→ `DISP_SET(CTRL = FORMAT | OUTPUT | ENABLE)` → `FENCE`。消灯 = `DISP_SET(flags[0]; CTRL = FORMAT | OUTPUT)`（pending の flip は cancelled で取られ record が来る）→ `FENCE`。FLIP だけの packet（present・cursor）には FENCE を付けない（`cp.c` に fence 無しの submit を足す: FENCE の `B_ALL` の drain が他の session を止めないように）。CP が RUNNING でない時（attach・recover の間・FAULTED）は host が直に書く。FORMAT の変更（BGRA ↔ RGBA）・mode の変更は点灯のし直し（今の code と同じ）。
- **mode**: DC_CAPS[11:9] と MODE_*（driver の `display_modes[]` を消す）。
- **route（swapchain ごとに 1 度、`gpu_scanout_constraints` の約束。判定は import で）**: `GPU_DISPLAY_CONSTRAINTS` に flags = `GPU_SCANOUT_SHARED | GPU_SCANOUT_COPY`、formats（BGRA8・RGBA8）、stride_alignment = 64、offset_alignment = 64、placement = 0（KC705 の `memory.c` は blob を全部 local memory に置く: scanout の blob を local に置く事を driver が保証し、local が尽きたら ENOMEM）を答える。libvulkan が route を選ぶ:
  - **SHARED**: libvulkan は swapchain の image を `GPU_RESOURCE_IMPORT` の `GPU_IMPORT_SCANOUT` で試す（`wsi-display.c`: 失敗の ENOTSUP・EXDEV で COPY に戻る）。driver の `share.c` の `import_resource` が §18.2 の 9 の条件（local memory・format・大きさ = 今の mode・stride）を確かめ、合わなければ ENOTSUP。present（BLOB）はその GPU address を FLIP（COMPLETE 無し、§18.1 の producer の待ちは core が済ませた）。present の検査（EINVAL）は防御として残す。image の stride か format が点いている FB_STRIDE・CTRL.FORMAT と違う present（mode の変更の後など）は点灯のし直し。
  - **COPY**（非 BLOB の present）: 今の driver の 2 つの frame に BLIT（ring）→ FENCE を待つ（「呼び出しの後は storage を借りない」）→ FLIP。
- **非同期の present**: display の ops に `DRV_GPU_DISPLAY_UNGATED` と `adoption_wait` を足す。present は記録し、plane の slot が空なら FLIP を置き、埋まっていれば driver の queue（深さ 2、U95）に積み、すぐ返す。`GPU_DISPLAY_PRESENT_FIFO` の無い present は queue の未送の最後を置き換える（置き換えられた present の sequence は replacement で adopted）。record は 8 B に揃った 1 回の 64 bit の読みで取る（2 回の 32 bit の読みは裂け得る）。FLIP の IRQ で **service thread**（IRQ の handler でなく）が record の page を読み（非 coherent の platform では §11.4 の DMA の sync の後）、32 bit の record の値を 64 bit の sequence に戻し（fence と同じ wrap の比較）、adopted を進め、queue の次の FLIP を置き、前に scan されていた allocation の **scan の hold** を外し、`poll_notify` する。cancelled の record（value の bit 31。driver の value は 31 bit）は「見せずに外れた」。FRAME_COUNT は DC の reset で 0 に戻るので時刻には使わない。adoption_wait は sequence に届くのを待つ（timeout の後の present は UAPI のとおり EBUSY）。
- **scan の hold**: FLIP を置いた allocation と scan されている allocation は、それが外れる record が来るまで free・reclaim しない（allocation の参照を 1 つ持つ）。lease の終わり・session の close は、`device->lock` の中では「lease を終える」印だけを付け、消灯の packet と record の待ち・hold の解放は display の lock の下で service thread が行う（`device->lock` の中で ring を待たない）。その後片付けが終わるまで新しい claim は EBUSY（後から来る消灯の packet が新しい lease の点灯を消さない）。
- **mode の変更と queue**: mode の変更は queue の未送の present を落とし（replacement で adopted）、slot の分だけ record を待つ（≤ 1 frame、display の lock の中、service thread は record の処理に `device->lock` を取らない）。
- **record の page**: driver の fence page の隣の 64 B（driver の memory、CTRL.RESET で消えない）。plane ごとに 8 B。
- **recover**（CTRL.RESET）: ring の中にまだ取られていない FLIP は ring の作り直しで消える。driver は reset の後の IDLE の間（RUN の前）に STATUS[31]（未送の record）が 0 になるのを待ち（上限 100 ms）、record の page・TAKEN0/1・STATUS[29]・[30] を読み、置いた数と来た数を数え直す（TAKENp が最後に置いた FLIP の value なら取られた、slot が埋まっていればまだ、どちらでもなければ ring の中で消えた）: 消えた FLIP は、その session が生きていれば queue の頭に戻して置き直し、lost なら消灯して replacement で adopted。`program_ring` の `IRQ_STATUS = IRQ_ALL` が record の FLIP の bit を消し得るので、recover の後に record の page を 1 度 poll する。cursor は recover で隠す（UAPI「device の fault で隠す」: host の直の CURSOR_CTRL = 0）。CONNECTED も読み直す（HOTPLUG の bit は reset で消える）。
- **割り込み**: `cp.c` の `IRQ_TAKEN` に FLIP・DISP_ERROR・HOTPLUG。VBLANK は v1 では使わない（power/refresh は無し、present の待ちは record）。DISP_ERROR は DC が 1 frame に 1 回まで: service thread が STATUS[1]・[3]・[4]・[5] を数えて W1C（W はいつでも書ける）、[3] が続けば消灯（scan する image が悪い）、1 s に 30 回を超えたら DISP_ERROR を mask し 1 s 後に戻す（60 回/s の IRQ を続けない）。BAD_WRITE は driver の誤りとして log。`irq_mask` は `irq_lock` の中で変える。
- **hotplug**（U92）: service thread が 1 s ごとに ADV7511 の HPD を I2C で読み（`adv7511.c` に関数を足す）、CONNECTED に書く。HOTPLUG の IRQ で output の connected と topology の sequence を変え（`poll_notify` は service thread から）、つながり直しで output の generation を進め ADV7511 を設定し直す。切れている間の present は ENXIO、DC は点いたまま（害は無い）。
- **cursor**（DC_CAPS[8] で `GPU_DISPLAY_HAS_CURSOR`）: driver の cursor の面 2 つ（64 × 64 × 4、local memory、64 B に揃う）。`cursor_set` は storage を BLIT（ring）で driver の window の中の staging に写し FENCE を待ち、CPU で BGRA への並べ替え（RGBA8888 の時）と 64 × 64 への 0 埋めをして空いている面に書き、FLIP(1)。2 つの面が両方使われている（見せている面と pending の面）時は EBUSY（UAPI の「refresh の後に成功し得る」）。`cursor_move` は host の直の `CURSOR_POS` と `CURSOR_CTRL = 1`、`cursor_hide` は `CURSOR_CTRL = 0`（C の register はいつでも host が書け、ring を待たない）。面は record（取り込み = BRAM に読んだ後）が来てから空きと見なす。消灯中の `cursor_set` は面に書くだけで、FLIP(1) は次の点灯の後に置く。
- **zedBSD の header の写し**（`hcr.h`・`ghci-words.h`）: DISP2 の register・µop 15/16・IRQ の bit。
- **vk/**: 変更無し。

### 18.8 状態遷移・順序・並行性

- **present の順序**: libvulkan の present → core が producer を待つ → driver の present が FLIP を ring に置く（slot が空の時）→ ring の順で seq が FLIP を取り slot に置き次の packet へ → DC が次の vsync で取り込む → record → IRQ.FLIP → service thread が adoption を進め、前の image の hold を外す（Vulkan の acquire がその image を返せる）。
- **slot が埋まっている FLIP**: driver の数え（置いた FLIP − 来た record、recover で数え直す）で通常は起きない。起きても seq は 1 frame（≤ 16.7 ms = 1.67M cycle @100 MHz、watchdog 2^28 より短い）待つ。DC が消灯された（vsync が来ない）場合は ENABLE の落ちが slot をすぐ取るので、待ちは終わる。DISP_SET の flags[0] の待ちも DC の idle で終わる（ENABLE = 0 なら DMA の outstanding が尽きて立つ）。
- **GPU の fault と reset**: DC は reset しないので画面は残る。slot の取り込みは起き、record は CP が動き出してから送る。driver は §18.7 の recover で数え直す。
- **HALT**: HALTING の間に取った FLIP は slot に置いて packet が終わる（その後の vsync での取り込みは DC の仕事で、record は RUNNING に戻ってから）。HALTED では host が直に書ける（debug）。
- **panic・早期の console**: zedBSD は KC705 を PCIe の card として x86 の host（と QEMU の guest）で使い、早期の console と panic の console は host の物（KC705 は console にしない、v1）。KC705 の画面に出す必要がある時の道は GHCI に残る: host が CTRL.HALT を書き、HALTED を待ち（上限 100 ms）、S の register を直に書く（FAULTED なら待たずに書ける）。
- **lease の終わり・detach**: 消灯 → record（pending はすぐ取られる）→ hold を外す → frame を返す。detach は §6.2 の順（CP の停止の前に消灯、DC の idle を待つ）。

### 18.9 失敗と corner case

1. 悪い base（aperture の外・local の外・揃わない）の FLIP → fault 3（driver の誤り）。検査を通った base の read が AXI の error → DISP_ERROR・黒・device の fault は無し、driver が消灯。
2. 悪い record の address → fault 3。write の誤り → 捨てて STATUS[4]、再送しない。
3. DISP_SET の FB_NEXT・範囲の外の offset・奇数の n → fault 3。firmware の FIFO からの DISP µop → fault 2。
4. RUNNING の host の S の write → 捨てて BAD_WRITE（driver の誤りを service thread が log）。
5. pending の flip の間の ENABLE の落ち・DC の reset → cancelled ですぐ取る（record が来る）。隠れた cursor の FLIP(1) は BRAM に読んでから取る（2 回目の review の 6 で直した）。
6. host の FB_NEXT の write（IDLE・HALTED・FAULTED）で pending の flip → cancelled の record。
7. underflow が続く（帯域の不足）→ DISP_ERROR は 1 frame に 1 回まで。
8. scan されている allocation の free・session の lost → hold で free を遅らせ、lost なら消灯の後に hold を外す。
9. 切断の間の present → ENXIO、つながり直しで generation が進む。
10. CTRL.RESET を跨ぐ FLIP → slot のは取られて record、ring の中の未取のは消え driver が置き直す。
11. DC の無い GPU（CAPS[3] = 0）で DISP µop → fault 2（今の未知の op と同じ）。

### 18.10 U 項目（ユーザーの判断。推し付き）

**回答の方針**: 2026-10-25 ユーザー「ゴールまで推しで進んでよいです。判断に迷ったら、Vulkan 1.0の原則論で進めてください。」に従い、Q1 が推しで決めてよい（起きた時にユーザーに見せる）。

| U | 問い | 推し | 他の案 |
| --- | --- | --- | --- |
| **U90** | host と CP の書く境 | **scanout（S）は CP の RUNNING・HALTING の間は ring の µop だけ、IDLE・HALTED・FAULTED は host も。RUNNING の host の write は捨てて BAD_WRITE（device の fault にしない）。cursor の位置（C）・link（L）・読む register はいつでも host** | (a) host は常に書けない（JTAG の bring-up と FAULTED の消灯の道が無い）、(b) host も常に書ける（ring の FLIP と host の FB_NEXT が競う）、(c) RUNNING の host の write を fault 7（STATE の alias と同じ。だが DC は reset で戻らない） |
| **U91** | display の command の形 | **class 0 の µop（DISP_SET・FLIP）を sequencer が実行**（firmware が要らない、flip の遅れが firmware の loop に依らない、ring の順そのもの） | class 2 の gpu-op（firmware が DC を操作。firmware の packet の間 ring が止まり、firmware の無い GPU で display が無い） |
| **U92** | transmitter（ADV7511）の設定と HPD | **今のまま host の driver**（bring-up・RUN の前・firmware の無い構成でも画面が出る、IMEM を使わない） | firmware（board ごとの物を汎用の driver から出せるが、firmware が動かない時に画面が出ない、IMEM の残り 4.5 KiB） |
| **U93** | cursor の plane | **実装する**（64 × 64 BGRA8 premultiplied、gclk で DMA の画素に合成、BRAM36 × 4・≈0.5k LUT。compositor が cursor の移動で再合成しない、GPU の負荷に依らず動く） | 作らない（compositor が software の cursor） |
| **U94** | DC の読みの検査（§17） | **検査しない（root）。FLIP は driver の µop で、driver が image の持ち主を確かめる** | FLIP に session の slot を付け DC の読みを検査（拒否が画面を黒にするだけになるが、MC の検査の入口が DC に要る） |
| **U95** | present の queue | **driver の software の queue（深さ 2）+ hardware の slot 1**（FIFO と mailbox を driver が作る、ring を止めない） | hardware の slot を深く（RTL が増える）、queue 無し（present が flip まで待つ: 今の形） |
| **U96** | mode の列挙 | **GHCI の mode の表（MODE_INDEX と 6 つの R）**（driver が vendor の表を持たない） | driver が DC_ID ごとの表（今）、EDID（programmable な clock が要る、後の版） |
| **U97** | 単独の DC | **GHCI の DISP（CP の無い DC）の文は残し、Amaterrace の RTL の `STANDALONE` は消す**（ZYBO の target は 2026-10-25 に外れた） | 両方残す、両方消す |
| **U98** | producer の待ちを GPU に任せる（zedBSD の display の core の変更） | **後で別の Phase か WS**（core が PRESENT_SYNC の依存を backend に渡す flag。全部の display の driver に関わる。GHCI の FLIP の COMPLETE は今から有る） | この Phase で core を変える |
| **U99** | GHCI の互換 | **新しい capability DISP2（id 11）**（今の driver は DISP2 を知らないので display を作らないだけ。§16 の minor の規則を守る） | DISP の version 2（今の driver が RUNNING で直に書いて誤る）、GHCI の major を上げる |

### 18.11 選ばなかった案と理由

- **DC が record を自分で書く**（DC の AMB の口に write）: DC は read だけの client のままにし、record の書き手は CP の側（IRQ の順序を CP の irq と同じ所で作る）。
- **CP の fence unit が record を書く**: FSM が 1 つで、ring と firmware の WAIT_FENCE が watchdog まで握るので、record が際限なく遅れ得る（review 5）。
- **STATUS の busy の bit に DC**: bit 7 は SA で、WAIT_IDLE の 8 bit の mask に空きが無い。また「全部の unit」に DC が入ると、点いている間 FENCE が終わらない（review 1・2）。
- **host が fence を待って FB_NEXT を書く**（今）: 毎 frame の BLT の copy と host の register の write が要る。
- **列挙も command で**: 読むだけの情報に ring の往復が要る。
- **DC の slot を深く**: driver の queue で足り、1 slot の方が検証が易しい。
- **DC の割り込みを別の MSI の vector に**: GHCI の割り込みは 1 本（§9.2・§15.2）。
- **host memory の scan**: PCIe の read の遅れと帯域で underflow の risk。
- **DC の DMA を 4 byte の揃えに**: v1 の mode の行は 64 B の倍数で、image も 64 B に揃うので要らない（review 15）。行が 64 B の倍数でない mode が出た時に見直す。
- **cursor を pclk で合成**: BRAM が 2 つの clock に跨ぎ、位置の crossing も要る（spec/README の 1 module 1 clock の規則）。gclk で DMA の画素に合成すれば crossing は今の pixel FIFO だけ。
- **ADV7511 を firmware に**: §18.10 U92。

### 18.12 試験の計画（host の iverilog・Verilator、driver の host 試験。QEMU・板はこの Phase に無い。画面は p024・p028）

- `sim/tb/atg_cp_disp_tb.v`（新）: group `set`（0x3C0〜0x3FF の写し、FB_NEXT・範囲の外・奇数の n の fault 3、flags[0] の idle の待ち）、`flip`（base・record の検査の fault 3、slot の空き・埋まり・取り込みで降りる、record の応答まで次を受けない、COMPLETE の待ち（unit の busy と応答。DC は入らない）、record `{value, FRAME_COUNT}` と IRQ.FLIP が write の応答の後、record 0 は IRQ だけ）、`take`（ENABLE の落ち・DC の reset で cancelled ですぐ取る、plane 1 は BRAM の読みの後に取る、隠れた cursor でも同じ）、`excl`（HALTED・FAULTED の間の seq の DISP_SET と FLIP は何もしない、HALTED の host の消灯を packet の残りが覆さない、STEP）、`order`（COMPLETE の FLIP は前の draw の終わりの前に slot に入らない、payload の受けで置かない）、`taken`（TAKEN0/1・STATUS[31]、reset の後の IDLE で record が出る）、`cancel`（host の FB_NEXT で cancelled の record）、`gate`（IDLE・HALTED・FAULTED は通る、RUNNING・HALTING は捨てて BAD_WRITE、C・L・I はいつでも、host の buffer は seq と同じ cycle でも捨てない）、`fifo`（UOP_FIFO の 15・16 は fault 2）、`reset`（slot と record が CTRL.RESET を跨ぐ、HALTED・FAULTED の間は送らない）、`err`（record の write の誤りは捨てて STATUS[4]、再送しない）。MUT: `MUT_DISP_EARLYSLOT`（payload の受けで slot に置く）、`MUT_DISP_NOEXCL`、`MUT_DISP_NOGATE`、`MUT_DISP_EARLYIRQ`（応答の前の IRQ）、`MUT_DISP_NOWAIT`（COMPLETE を無視）、`MUT_DISP_FIFOOK`、`MUT_DISP_NOTAKE`（ENABLE の落ちで取らない）、`MUT_DISP_HALTSEND`（HALTED で record を送る）。
- `sim/tb/atg_cp_seq_tb.v`: DC が点いている間も FENCE・RESULT・QUERY・WAIT_IDLE(0) が終わる（DC が「全部」に入らない）。
- `sim/tb/atg_cp_ctl_tb.v`: C_DC の MC の誤りが device の fault にならない、fault の源 9。
- `sim/tb/atg_mc_tb.v`: quiesce・HALTED の間も C_DC の要求が通る、axi_idle が DC を数えない、CTRL.RESET の flush の後も C_DC の未応答の応答が返る（`atg_dc_dma` の `inflight` が戻る）。
- `sim/tb/atg_dc_dma_tb.v`: 他の tag の応答を数えない、err の出力。
- `sim/tb/atg_dc_regs_tb.v`・`atg_dc_tb.v`: 256 B の窓、pending と taken（vsync・ENABLE の落ち・DC の reset・ENABLE = 0 の write）、mode の表、CONNECTED の reset の値と pulse、STATUS の sticky と W1C、DISP_ERROR は 1 frame に 1 回（underflow が続く形）、read の error で黒と STATUS[3]。
- `sim/tb/atg_dc_cursor_tb.v`（新）: 端の clip（負の位置・右下の外）、alpha 0・255・中間（丸めと飽和）、非 premultiplied の値で飽和、frame の始めでの位置の取り込み（frame の途中の CURSOR_POS の write で frame が裂けない）、新しい image の読みが frame の外に収まる、RGB565 の primary、読みの error。
- `sim/tb/atg_top_disp_tb.v`（新、KC705 の形、firmware 入り）: ring に driver と同じ形の packet: BLIT の fill → FLIP(COMPLETE) → DC が scan した画素（SCAN_SUM）= fill、draw（三角形）→ FLIP → 画素 = 参照、点灯の列、消灯と pending の取り込み、ring の WAIT_FENCE の間の取り込み（record が遅れない）、CTRL.RESET を跨ぐ FLIP。
- **CDC**: 新しい crossing は無い（cursor は gclk）。今の pixel FIFO・`am_sync` の crossing は変えない事を D2・D3 の review で確かめる（iverilog・Verilator は metastability を見ないので、crossing の一覧を spec に書いて目で見る）。
- Verilator: `ghci-e2e` に display の case（driver の display の ops を偽の core から呼び、vkdemo の frame を BLOB で present → FB_BASE がその image の address・record・IRQ、SCAN_SUM が image と一致、COPY の route も）。P1 の harness の KC705 の形（p030 S11）の後。
- driver の host 試験（`ghci-host-test.c`）: 点灯・消灯の packet の列（CTRL の全部の word）、mode の変更と flip の同時（詰まらない）、lease の後片付けの間の claim の EBUSY、queue と mailbox の置き換え、hold の解放、record の wrap、cancelled、recover の数え直し（ring の中の未取の FLIP の置き直し、`program_ring` の後の poll）、cursor の EBUSY と並べ替え、attach の順（RUN の前の直の write）。vmunix の build の warning 0。
- 回帰: `make sim` の PASS の数が減らない（T）。

### 18.13 risk

- **負荷の下の flip の取り逃し**（§18.1）: 1 本の ring で FLIP が長い class 2 の packet の後ろに並ぶ。p028 で測り、多ければ display 用の ring（後の版）か U98。
- **cursor の BRAM**: BRAM36 × 4、≈0.5k LUT（p036 の面積の数字に足す）。
- **seq の port と行**: `busy_in[0]` と kick の束ねで port は 39（§17 の後）。行は `atg_cp_seq_dec` に分けて 400 以内（D1 の確認 C3）。
- **ADV7511 の HPD**: register と設定の消え方が未確認（実機 p024）。
- **P1・P2 との重なり**: `atg_top`・`atg_cp`・`sim/verilator/harness.cpp` は P1（p030 S11）、`atg_cp_seq` は §17 の R3 も触る。実装の段の順は Q1 が決める。

### 18.14 実装の段・LW・順（8 LW ≈ 2〜3 時間）

| 段 | 内容 | 受け入れ | 依存 | LW |
| --- | --- | --- | --- | --- |
| D1 | GHCI の §3.1・§3.2・§4・§7.3・§13.2・§15.2 の draft、`include/ghci_regs.h`・`ghci_packets.h` の番号（draft: id 11、op 15・16、IRQ [12:9]、uop index 0x3B8〜0x3FF。他の draft（p027・p030・p034）の番号と照合）、新しい module と変わる module の spec、確認 C3（seq の port） | spec の port ≤ 40、番号の Q1 の確認 | この設計の review と U90〜U99 | 3 |
| D2 | RTL の移動（`rtl/gpu/dc/`・`spec/gpu/dc/`・`sim/run.sh`・lint の list）、atg_top の子に（board の reset の domain、C_DC）、MC の QUIESCE_EXEMPT・axi_idle の分け・flush で C_DC を残す、board の top の簡素化、`STANDALONE` を消す | 今の DC の TB と `atg_kc705_raster` の TB の PASS、`atg_mc` の新しい group、lint | D1、P1 の S11 の merge | 8 |
| D3 | DC: 窓 256 B、pending と taken の直し、mode の表、CONNECTED、STATUS、DISP_ERROR、BAD_WRITE、TAKEN、内部の bus、DMA の err と tag、DC の中の `am_amb_mux` | `atg_dc_regs`・`atg_dc_dma`・`atg_dc` の TB PASS（新しい group） | D2 | 5 |
| D4 | CP: `atg_cp_disp`（record の書き手・§17 の side band を含む）、seq の op 15・16・`busy_in[0]`・kick の束ね・`atg_cp_seq_dec`、`atg_cp` の index の振り分け、IRQ の [12:9]、host の門と排他、UOP_FIFO の拒否、`atg_cp_ctl` の C_DC と fault の源 9、`XCAP_MASK` の幅と EXTCAP の list の配置 | `atg_cp_disp` の PASS と MUT、`atg_cp_seq`・`atg_cp_ctl`・`atg_cp_regs` PASS | D1（D3 と並行: DC の `taken` は TB の stub）、§17 の R3 との順は Q1 | 12 |
| D5 | cursor の plane `atg_dc_cursor`（U93） | `atg_dc_cursor` PASS | D3 | 5 |
| D6 | `atg_top_disp_tb`、Verilator の display の case | 各 PASS | D2〜D5 | 3 |
| D7 | driver: attach の順、display の lock と待ちの規則、DISP2、ring の点灯・消灯と fence 無しの submit、mode の表、route（SHARED の import の判定・COPY）、UNGATED と adoption_wait、queue と mailbox、hold、claim の EBUSY、record と wrap と 64 bit の読み、recover の数え直し（STATUS[31]・TAKEN）、IRQ の bit と DISP_ERROR の mask、hotplug の poll、cursor、`hcr.h` の写し、license と転記（§17.20 と同じ） | host 試験 PASS、vmunix の warning 0 | D4、p006・p019 の merge | 13 |
| D8 | GHCI の確定、design の §4.2・§4.3・§5・§6.5 の書き換え、README の行、`make sim` の数（T） | `make sim` の PASS が減らない（T） | D2〜D7 | 2 |
| 計 | | | | **51 LW**（±35%: 33〜69） |

D3・D4 は D2 の後に並行できる。D7 は p006・p019 の後。画面の確認は p024（KC705 の板）と p028。

### 18.15 review の指摘と対応（design-reviewer、2026-10-25、28 件: Critical 2・High 7・Medium 13・Low 6）

| # | 重さ | 指摘 | 対応 |
| --- | --- | --- | --- |
| 1 | Critical | DC busy を WAIT_IDLE の bit 7 に入れると `B_ALL` に含まれ、点灯中の FENCE・RESULT・QUERY・firmware の WAIT_IDLE(0)・FLIP COMPLETE が終わらない | DC を busy の bit から外し「全部の unit」に入らないと GHCI に書いた。idle の待ちは DISP_SET の flags[0]（§18.2-4・§18.3・§18.4） |
| 2 | Critical | STATUS[7] は SA（`sa_busy`）と §3.9 の予約 | bit 7 を使わない（同上、§18.0 を直した） |
| 3 | High | ENABLE の落ち・DC の reset で pending の flip が取られず slot が詰まる（ring の deadlock、hold の漏れ）。ENABLE = 0 の write で古い pending が残る | ENABLE の落ち・DC の reset・ENABLE = 0 の write ですぐ取り `taken` を pulse（§18.3・§18.5 (b)、TB の `take`、MUT。cursor の off で取る形は 2 回目の 6 で取り下げた） |
| 4 | High | scanout の read の誤りが device の fault になり reset を繰り返す。record の誤りも reset を跨いで再送 | C_DC の誤りは device の fault にせず黒と DISP_ERROR、FLIP の base を parse で検査（fault 3）、record の誤りは捨てる（§18.2-7・§18.4・§18.9） |
| 5 | High | fence unit は FSM 1 つで WAIT_FENCE が握る、record の深さ、§17 の chk | `atg_cp_disp` に自分の record の書き手（chk = 0）、record の応答まで次の FLIP を受けない（§18.2-5・§18.4・§18.11） |
| 6 | High | ADV7511 を firmware に移すと bring-up・RUN の前・firmware の無い構成で画面が出ない、早期の console が未決 | U92 の推しを host の driver に変えた、CONNECTED の reset の値、早期・panic の console の道（§18.2-11・§18.8・§18.10） |
| 7 | High | reset を跨ぐ時の driver の側（ring の中の未取の FLIP、数え、`program_ring` の IRQ の clear、HALTED の quiesce） | record は CP が動き出してから送る、driver の recover の数え直しと poll（§18.4・§18.7・§18.8、host 試験） |
| 8 | High | host の門の競争と attach の順（RUN の後の直の write）、STEP と host の write の同じ cycle | attach の display の初期化を RUN の前に、直の write は `cp_lock` の中、門の host の buffer、RUNNING の write は fault でなく BAD_WRITE（§18.2-3・§18.4・§18.7、U90） |
| 9 | High | slot と直の FB_NEXT の write の衝突 | FB_NEXT は DISP_SET で書けない（fault 3）、host の write は pending を cancelled の record で降ろす（§18.3・§18.9） |
| 10 | Medium | cursor の module が 2 つの clock に跨ぐ、CURSOR_POS の crossing | gclk で DMA の画素に合成（crossing 無し）、位置は frame の始めに取る（§18.5、§18.11） |
| 11 | Medium | cursor の契約（RGBA、EBUSY、ring の後ろで止まる、丸め、読みの時、fault で隠す） | CPU で並べ替え、両面が使用中は EBUSY、C の register はいつでも host、round と飽和、読みは frame の外で 1 度、recover で隠す（§18.3・§18.5・§18.7） |
| 12 | Medium | placement に local の bit が無い、route は swapchain ごと、非 BLOB の copy の道、power/refresh、FORMAT の変更、32 bit の record | placement 0 と driver の保証、route は SHARED・COPY を libvulkan が 1 度選ぶ、COPY は BLIT + FENCE の後に FLIP、power/refresh は v1 で両方無し、FORMAT は点灯のし直し、record を 64 bit に戻す（§18.1・§18.7） |
| 13 | Medium | DISP v2 は minor の規則に反する | 新しい capability DISP2（U99） |
| 14 | Medium | 窓が 128 B を超える | 256 B と 8 bit の decode、driver の検査（§18.3・§18.5・§18.7） |
| 15 | Medium | 4 byte の揃えは v1 に要らない、1.3% の数字の誤り | DMA を変えない、stride_alignment 64（§18.2-9・§18.11） |
| 16 | Medium | port と行の予算（DISP の group は不可、seq の port、module の表が無い） | seq は今の uop の port を使い +1（kick の束ね）、module の表（§18.4・§18.5） |
| 17 | Medium | lock の順、session の close で ring を待つ、HOTPLUG の通知 | display の lock と順、close は印だけで service thread が行う、mode の変更は queue を落とす、通知は service thread（§18.7） |
| 18 | Medium | underflow の割り込みの嵐、VBLANK の動的な有効と `irq_mask` | DISP_ERROR は 1 frame に 1 回まで、VBLANK は v1 で使わない、`irq_mask` は `irq_lock` の中（§18.2-6・§18.7） |
| 19 | Medium | v1 の present は CPU が producer を待つ、ring の後ろで並ぶ | §18.1 に書き、p028 で測る、U98（§18.1・§18.13） |
| 20 | Medium | hotplug の意味（generation、切断中の present、reset で消える bit） | §18.7 の hotplug、recover で CONNECTED を読み直す |
| 21 | Medium | 段の依存と LW（D7 と firmware、attach、`hcr.h`、license） | firmware の段を無くし（U92）、D7 に足して 12 LW、D4 を 10 LW、D4 の stub（§18.14） |
| 22 | Medium | 試験の計画の抜け | §18.12 に足した（take・FENCE と点灯・誤り・WAIT_FENCE の間の取り込み・cancel・reset・嵐・CDC） |
| 23 | Low | cursor の読みの窓の数字 | 読みの窓を「frame の最後の読みの後から次の frame の始めまで」に直した（§18.5） |
| 24 | Low | 今の RTL は既に `flip_pending` を持つ | §18.0・§18.5 (b) を直し、D3 を 4 LW に |
| 25 | Low | record 0 の IRQ、payload の置き場、落とした文、idle と cursor、MODE_INDEX の共有 | record 0 は取り込みで IRQ だけ、payload は `atg_cp_disp` の index、underflow の clear と OUTPUT の文を戻した、idle は cursor の読みも数える、MODE の読みは display の lock の中（§18.3・§18.4・§18.7） |
| 26 | Low | atg_top の中の DC の reset の domain | board の reset の domain、CTRL.RESET の flush から外す（§18.2-1） |
| 27 | Low | record の page の coherence | §11.4 の DMA の sync の後に読む（§18.7） |
| 28 | Low | window の番号の照合 | firmware の window は使わなくなった。uop の index の番号は D1 で他の draft と照合（§18.14） |

### 18.16 review の指摘と対応（2 回目、design-reviewer、2026-10-25、21 件: High 5・Medium 10・Low 6）

| # | 重さ | 指摘 | 対応 |
| --- | --- | --- | --- |
| 1 | High | FLIP が COMPLETE の待ちの前（payload の受け）で slot に入り得る、DISP_SET の flags[0] が `atg_cp_disp` に見えない | slot に置くのは exec の kick（code `disp`）の時、待ちは pre の mask に `busy_in[0]`（`B_ALL` は bit 0 を含まない）、flags[0] は擬似の index 0x3BF（§18.2-5・§18.4）、TB `order` と MUT |
| 2 | High | MC の quiesce・flush・axi_idle から DC を外す設計と段が無い（`inflight` が戻らず DMA が止まる） | `QUIESCE_EXEMPT`・axi_idle の分け・flush で C_DC を残す（§18.2-1、module の表、D2 に +4 LW、`atg_mc_tb`） |
| 3 | High | recover で「取られたが record が未送」と「ring で消えた」を区別できない | TAKEN0/1 と STATUS[31]、recover は RUN の前の IDLE で未送の record を待ってから読む（§18.3・§18.4・§18.7） |
| 4 | High | HALTED・FAULTED の間も seq が packet を続け、host が直に書いた物を覆す | 排他: seq の DISP µop は RUNNING・HALTING だけ効き、他では何もしない（§18.2-3・§18.3・§18.4、TB `excl`） |
| 5 | Medium〜High | driver の lock の順で待ちが詰まる | 待つ者は record を自分で poll、service thread は lock を持って待たない、recover は display → `cp_lock`（§18.7、host 試験） |
| 6 | Medium | 隠れた cursor の FLIP(1) がすぐ取られ面が再利用される | plane 1 の取り込みは BRAM の読みの後（隠れていても）、ENABLE = 0・reset は cancelled、消灯中の cursor_set は点灯の後に FLIP（§18.3・§18.5・§18.7） |
| 7 | Medium | cursor と DMA が AMB の口を共有すると `inflight`・`keep` が壊れる、「frame の残りを黒」は今の RTL と違う | DC の中の `am_amb_mux`、DMA が自分の tag だけ数える、err の出力、黒は誤った line（§18.2-7・§18.5、D3） |
| 8 | Medium | 0x3xx の index の実装の穴（state の範囲外・TU の broadcast・SET_REG の道・offset の折り返し） | `atg_cp` が 0x3xx を state に渡さない、`pay_wait = 0` の別の枝、offset の検査は seq（§18.4） |
| 9 | Medium | seq の port の起点と変更の見積もり | port は 40（clk・rst_n を含む）から kick の束ねで 39、`atg_cp_seq_dec` に分ける（§18.4・module の表・§18.13） |
| 10 | Medium | `atg_cp_disp` の fault 3 の出口が無い（NSRC 8 は満ち） | fault の源を 9 に（§18.4・module の表） |
| 11 | Medium | STATUS の W1C の kind が無い、BAD_WRITE と IRQ | kind W（いつでも）、BAD_WRITE も DISP_ERROR（1 frame に 1 回）（§18.2-3・§18.3・§18.7） |
| 12 | Medium | SHARED の条件を present の EINVAL にすると COPY に戻れない、FLIP は stride と format を持たない | 判定は import（`GPU_IMPORT_SCANOUT`、ENOTSUP）、present の EINVAL は防御、stride・format が違えば点灯のし直し（§18.7） |
| 13 | Medium | §17 との接続（record の書き手の side band、client の順序、XCAP_MASK の幅と list の配置） | §18.4 の record の書き手、D4 に `XCAP_MASK` と list の配置と §17 の R3 との順 |
| 14 | Medium | lease の後片付けと新しい claim の競合 | 後片付けまで claim は EBUSY（§18.7、host 試験） |
| 15 | Low | cursor の読みの窓の数字（frame_start は back porch の始め） | 720p ≈26k gclk、480p ≈13k gclk に直した（§18.5） |
| 16 | Low | CTRL の word の全体の書き込みで FORMAT・OUTPUT が消える、ENABLE = 1 の間の timing の write | CTRL = FORMAT \| OUTPUT \| ENABLE、ENABLE = 1 の間の write は捨てて BAD_WRITE（§18.3・§18.5 (i)・§18.7） |
| 17 | Low | 8 B の record が裂けて読める、FRAME_COUNT を時刻に | cancelled を value の bit 31 に、64 bit の 1 回の読み、FRAME_COUNT は時刻にしない（§18.3・§18.7） |
| 18 | Low | cursor の合成の細目（RGBA8 の入れ替え、RGB565 の広げ方、TEST_PATTERN） | §18.3・§18.5 に書いた |
| 19 | Low | FLIP ごとに driver の FENCE が付き全部を drain する | FLIP だけの packet は fence 無しの submit（§18.7） |
| 20 | Low | DISP_ERROR の数、窓の decode の場所の食い違い、host の read の道 | 1 s に 30 回で mask、decode と read は `atg_cp_regs`（§18.4・§18.5 (h)・§18.7） |
| 21 | Low | DC の CTRL.RESET は I2C も reset する | I2C の使用と CTRL.RESET を display の lock で直列（§18.7） |

### 18.17 実装の段で設計から変えた事（2026-10-25 P3、q1576-i03。amaterrace-gpu p3-p035）

- **D2b（MC）**: §18.2-1 の「C_DC を QUIESCE_EXEMPT・axi_idle の分け・flush で残す」を `atg_mc` の新しい parameter `ROOT_KEEP`（atg_top: HAS_DISP で 1）にまとめた。ROOT_KEEP は ROOT_CLIENT に root の自分の入口を与える（§17.5 の ROOT_SPLIT を HAS_PROT が無くても使う）。flush は DC の leaf・入口（`asm_d`）・DC の誤りの応答を残す。`axi_idle` は ROOT_KEEP の時「DC 以外の要求が木と root に無い（pend を mask）・DC 以外の AXI への grant が全部応答された（`atg_mc_cnt` の新しい counter ax、rst_n だけで消える）・DC 以外の誤りの応答が無い・応答の flit が木に無い」。merge の解決の誤り 2 つ（MC_UNITS と protection の side band が EXT_CLIENT だけを見て、DC が unit_idle に数えられ chk を付けられた）も直した。
- **D4（CP）**: (1) host の門の 1 段の buffer: host は毎 cycle 書けるので、buffer が埋まっている間 `disp_wait` を立て、seq の次の DISP_SET の書き込みを待たせる（§18.4 の「seq は 2 cycle に 1 回」の前提を置き換え）。(2) FLIP の fault 3 は kick の cycle に組み合わせで出す（`atg_cp_ctl` が seq の次の header より先に FAULTED になる）。(3) kick の code は BLT・DRAW・CS・LC・RAW・PERF_RESET・FLIP・DISP の idle の 8 つ（3 bit に収まる）。seq の使っていない `n_last`・`fw_last` を外して port は 39。(4) record は IDLE・RUNNING・HALTING の時だけ要求し、出した要求は ready まで保つ（RS_WAIT は CP の client を含む `mc_idle` を待つので flush に消されない）。(5) CP は DISP（id 1）を名乗らない: XCAP は 11 bit で DISP2 だけ（list は 10 個まで 0x1C0 の前に入る）。(6) DC の MC の誤りは `atg_cp_ctl` の `DC_CLIENT` で device の fault から外す（protection の拒否は除く）。(7) DISP_SET の対は seq の `sidx` に 0x3C0 + offset / 4 を置き、SET_REG と同じ書き込みの道を通る。
- **D6**: `atg_top_disp_tb` は CPU と firmware を入れない（DISP µop は firmware が要らない）、draw の三角形も入れない（RX・ROP は atg_top_tex と Verilator の e2e）。小さな mode（32 × 4）と 25 MHz の pclk。MC の flush が DC の読みに当たる場合は atg_mc_tb の D・E で確かめる（この TB では稀にしか当たらず `MUT_MC_NOKEEP` で FAIL にならない）。
- **D6 の後半（Verilator の e2e、q1576-i04、amaterrace-gpu e447ecd）**: Q1 の決定（2026-10-25 17:31）どおり、`atg_dc_mode` に parameter `TEST_MODE`（atg_dc の `TEST_MODE`、atg_top の `DC_TEST_MODE`、既定 0）を足した。1 の時、mode の表は 320 × 240（vkdemo の frame、H 320/8/8/8・V 240/2/2/2、1 frame 84,624 pclk、25,000 kHz、PCLK_SEL 0）の 1 つだけで、DC_CAPS[11:9] は 1（`atg_dc_regs` の新しい parameter `MODES`）。`sim/verilator/link-build.sh` だけが `-GHAS_DISP=1 -GDC_HAS_I2C=0 -GDC_TEST_MODE=1` にする（KC705 の板・lint・他の TB は 0 のまま）。`link.cpp` は pclk を gclk の 1/4（gclk が low の間に 2 cycle ごとに反転、edge が重ならない）で回し、`prst_n` を board の reset と一緒に上げ、I2C の入力を 1 にする。driver は変えていない（controller が名乗る mode から最大の物を選ぶ）。zedBSD の `ghci-e2e` は display.c・display-scan.c・adv7511.c を link し、偽の core に display の ioctl（query・mode・claim・release・present（BLOB と非 BLOB、UNGATED の adoption の待ち）・wait）、case `display`（§18.12 の Verilator の display）を足した。
- **D8**: GHCI §13.2 の印を他の draft の節と同じ「Draft (Amaterrace implements it, in simulation)」にした。`GHCI_VERSION` の minor は上げていない（GHCI 全体が 1.0 draft のまま、MSAA・PROT も上げていない。上げるかは Q1 の判断）。

## 19. timing: 目標の Fmax、clock の領域、pipeline の方針、面積の見通し（版 9、ws001-p025 の設計の段）

2026-10-25 P2（q1583、zedBSD の worktree p2-p025、基点 main 05cfe206c。amaterrace-gpu は main e64da02 を読んだだけで変えていない。Vivado は回していない）。[p025](phase025/phase.md) の「P2 の作業の項目」1〜5 の設計。**RTL は変えない**: p037（算術の am_ の module への置き換え、P1・P3・P4 が実行中）の後に p025 の実装の段（§19.10）で行う。

### 19.0 出典と確認の水準

- **測った物（この project の Vivado 2026.1、xc7k325tffg900-2、out-of-context、5 ns、clock 1 つ）**: p036 の 2d2bd25（KC705 の形、NPHYS 8、NSU 1、PK_SHARED 0）の合成と配置配線（[evidence/ooc-kc705-n8-routed-timing_summary.rpt](phase036/evidence/ooc-kc705-n8-routed-timing_summary.rpt)、WNS −34.388 ns は Q1 が report で確かめた。block ごとの最悪の値は P2 の申告で、Q1 は block ごとの report を確かめていない）、p036 の d94076c の合成の LUT 167,293（Q1 が確かめた）、p038 の TU の単体（572ffe1、配線後、P2 の申告）、p024 の板の全体の合成（8040e3d、place で停止、P2 の申告）、2026-10-24 の ROP の blend（WNS −4.207 ns、[p025](phase025/phase.md) の範囲の記録）。**どれも p037 の前の RTL**で、p037 の後に測り直す（§19.10 の T0）。
- **読んだ RTL（e64da02）**: `atg_su`（port）、`atg_su_sb`（短い interlock と `CD_W = 4`）、`atg_su_opd`（i_valid → x_valid 2 cycle、`unit_ready` の戻り）、`atg_su_fpu`・`atg_su_lane`・`atg_su_pk`・`atg_su_alu`（`SHORT_LAT` 6、計算は pipe[0] の前）、`atg_su_pt`（pt_rdata は pt_rd の次の cycle）、`atg_su_dcache`・`atg_tu_cache`（miss は 1 つだけ outstanding）、`atg_rx_clip`（pt_rdata を次の cycle に取る）、`atg_vf_conv`（vl_* を 1 cycle に 1 word、ready 無し）、`atg_top`（graphics の port は SU 0 だけ）、`am_afifo`（gray の pointer を 2 段で同期、相手の pointer は最大 3 cycle 遅れて見える、両側の reset を同時に 3 cycle 以上）、`am_sync`、`boards/kc705/lib/atg_kc705_clk.v`（SYSCLK 200 MHz → MMCM の VCO 1000 MHz、O0 = gclk、O1〜O6 は空き）、`atg_kc705_raster.xdc`（clock は `set_clock_groups -asynchronous` で分けている）、`atg_kc705_mig.v`（gclk → ui_clk 200 MHz は AXI の clock converter）、`atg_kc705_pcie.v`（user_clk = axi_aclk_out 125 MHz）、`docs/ghci.md` の GCLK_HZ（0x01C）と PERF。zedBSD の `src/drivers/gpu/ghci/compiler/gsi1-schedule.c`（register に入らない program だけ、純粋な命令を最初の読み手の前まで沈める。latency の model は無い）。
- **測っていない一般知識（未確認、数字は幅で使う）**: XC7K325T -2 の DSP48E1・BRAM・BUFG・MMCM の上限（DS182・UG472 を読み直していない）、FPGA と ASIC の速さの差（Kuon & Rose, "Measuring the Gap Between FPGAs and ASICs", IEEE TCAD 2007: 90 nm で critical path の遅れが約 3〜4.6 倍）、28 nm → 3 nm の速さの伸び（foundry の公開の値の積み重ねで約 1.8〜2.5 倍）、3 nm の FO4。**ASIC の library で合成した値は無い**。

### 19.1 決めた事の要約（推し。U100〜U109 でユーザーの判断を受ける）

1. **KC705 の目標（U100）**: SU を独立の clock **`sclk` = 200 MHz**、他の block（CP と CPU、VF、RX、TU、ROP、BLT、MC の木と root、DC の memory の側）は **`gclk` = 100 MHz**。p025（1 段目）の受け入れは「gclk 100 MHz の block が OOC の配線後で WNS ≥ 0、SU が単体の OOC で 200 MHz」を目標にし、met しない経路は p032 へ（ユーザーの 3 段の方針）。gclk の 125〜150 MHz は面積が減った後の伸ばし代。
2. **ASIC（U101）**: 3 nm の mobile、**1.0 GHz を基準、1.5 GHz を伸ばし代**。KC705 の 200 MHz の段の深さ（1 段に LUT 約 5 段）は、FPGA と ASIC の差の推定で ASIC の約 1.1〜1.75 GHz に当たるので、**SU は KC705 の 200 MHz の構造でそのまま ASIC の目標に届く見込み**（推定）。gclk の 100 MHz の構造の block は ASIC の約 0.55〜0.9 GHz で、ASIC では gclk を sclk の半分で回すか、もう一度 pipeline を深くする（後の WS）。
3. **clock の領域（U102・U103）**: `sclk`（全部の SU が 1 つの sclk）・`gclk`・既存の `mclk`（MIG の ui_clk）・`uclk`（PCIe）・`pclk`・`tck`・`ref_clk`。sclk と gclk の境は **SU の port の全部**（約 4.3k bit）で、新しい `am_cdc_*` の channel（`am_afifo` の上、parameter `ASYNC`: 0 なら同じ clock の同期 FIFO）。sclk は今の mmcm_g の空いた O1 から作る（MMCM を増やさない）。
4. **SU の pipeline（U104）**: class a と f の **1 本の固定長の pipeline は保つ**（WAW を起こさない今の設計）。`SHORT_LAT` を 6 → **約 10〜12**（FPU の fp32 の FMA を p038 の `atg_tu_fma` と同じ 10 段前後に。数え方は §19.5.2）。ISA と compiler の約束は変わらない（scoreboard の interlock が隠す）。`atg_su_sb` の `CD_W` は `SHORT_LAT` から計算する parameter に。NPHYS 8・NWARPS 4 では、依存の続く命令の最悪の場合でも runnable な warp が 4 つで bus は埋まり、3 つで約 86%（§19.5.2、review L1 で直した近似）。
5. **pipeline の形（U108）**: 止まらない固定の latency の段（valid の bit だけが流れ、datapath の FF に reset と CE を付けない）+ 終わりの skid の FIFO と credit（p038 の `atg_tu_filter` の形）。enable の大きな fanout を作らない。unit が bus を止める `unit_ready` の戻りは、issue の段で決まる予定（PK_SHARED の 2 cycle、`lane` の 2 × G）に置き換える。
6. **面積（U105・U106）**: 板の top に `SU_PK_SHARED = 1` を渡す（2026-10-25 12:41 のユーザーの「後者で合成してみましょう」を板にも）。p037 の後に板の全体を **合成だけ**（P&R はしない）して module ごとの LUT を取り、LUT ≤ 85%（gclk 100 / sclk 200 の目安）に入らなければ、U80・U81・U84 と §19.6 の候補からユーザーが選ぶ。pipeline の FF は +20〜30k（推定）で FF は余る（板で 29%）。LUT は +3〜6%（推定）。**今の見込み（板で約 216k〜223k）では K2 の目安（約 173k）にも K1 の目安（約 183k）にも入らず、U80・U81・RX の pb を全部とっても −7〜10k しか減らない**（review H6）→ **面積の判断（U106）は T2・T3 の pipeline の作業の前提**: T0 の測定の後、T2 に入る前にユーザーの判断を受ける。SU の単体の OOC の 200 MHz は板での証明にならない（板の混雑で崩れ得る）。
7. **GHCI（U107）**: 変えない。`GCLK_HZ` は gclk の Hz のまま、PERF は gclk で数える（SU の busy は同期して gclk で数える）。sclk の Hz は vendor の register（`VEND`）に debug 用として置く。
8. **CDC は別の Phase（U109）**: sclk の領域を作る仕事（T1）は機能の正しさを変える（CP の reset の握手、VF・RX の back-pressure、PT の copy の場所）ので、「met しなくても cleared」の timing の 1 段目と分け、受け入れを scene の TB の word 一致・比の違う clock・`report_cdc` にする。

### 19.2 経路の棚卸し（item 1）

原因の種類: **A** = 1 cycle に演算の全部（FP・address の式）、**F** = fanout（enable・FSM の decode・reset が広い register へ）、**M** = 広い mux・選択、**R** = 配線（logic の段は少ないが混雑で延びる）。段 = Vivado の logic levels（CARRY4 も 1 段と数える）。**2026-10-26 P1（p025 T0）が amaterrace-gpu 8e529b3（p037 の後）で測り直した**: xc7k325tffg900-2、Vivado 2026.1、OOC、flatten の既定（rebuilt）、KC705 の形（NPHYS 8、PK_SHARED 1、MS4 1、PROT は板の値）。SU は単体（`atg_su`）を 6.67 ns で配置配線・5 ns で合成、gclk の block は core 全体（`atg_top`）の 10 ns の合成と、TU・BLT・RX の単体の 10 ns の配置配線。遅れ = logic + 配線（配線の値は、合成では Vivado の見積もり、配線後は実際）。目標の段 = ceil(遅れ / 周期)（**推定**: register の分の時間と、段を切る位置の偏りを数えていない）。単体の配線は板の混雑（LUT 94〜100%、[phase.md](phase025/phase.md) の T0）を含まないので、板では悪くなる見込み。前の値（p036・p038）は最後の列。report は [phase025/evidence/](phase025/evidence/) の t0-*。

| block | 経路（始点 → 終点） | 段 | 遅れ ns = logic + 配線（slack ns、測り方） | 種類 | 目標の段（推定）: sclk 150 / 200 MHz、gclk 100 MHz | 前（p036 2d2bd25・p038 572ffe1、5 ns） |
| --- | --- | --- | --- | --- | --- | --- |
| SU/FPU | `opd/b_warp_reg`（複製）→ opd の operand の選択（`opc` → lane ごとの 32 bit の `u_cl` の加算 → `opl` の mux → `fmod`）→ `atg_su_fpu_op`（FRACT の rint → i2f → fma、PK_SHARED の fp16）→ `fpu/pipe_reg[3]` | 128 | **45.417 = 9.758 + 35.659**（−38.840、配線 6.67 ns）。合成 5 ns: 129 段、42.921 = 9.920 + 33.001（−38.005）。FPU の単体の合成: 112 段、39.780 = 8.693 + 31.087（`k_op_reg` → `pipe_reg[3][0]`）。opd の分は配線後の 45.4 ns の内の最初の約 6〜10 ns | A + M | 7 / 10 | 合成 −31.55 / 114、配線 −33.99 / 118 / 38.6 |
| SU/lane | `opd/b_warp_reg[1]_replica_2` → `lane/pipe_reg[3]`（quad の差の fadd、shfl） | 57 | **30.614 = 5.058 + 25.556**（−24.112、配線 6.67 ns）。合成 5 ns: 59 段、20.100 | A | 5 / 7 | 合成 −23.0 / 75、配線 −30.3 / 70 / 35.1 |
| SU/XU | `xu/li_reg` → `xu/z_reg`（超越の多項式） | 30 | **26.049 = 6.655 + 19.394**（−19.408、配線）。合成 5 ns: 38 段、13.114（`rx_reg` → `z_reg`） | A | 4 / 6 | （無し） |
| SU/PK | `opd/b_warp_reg[0]_rep` → `pk/pipe_reg[0]`（PK_SHARED 1: 整数と pack の残り） | 34 | **24.033 = 2.981 + 21.052**（−17.361、配線、opd の fanout 125）。合成 5 ns: 37 段、14.572 | A + M | 4 / 5 | PK_SHARED 0 で合成 −19.0 / 49、配線 −26.1 / 66 / 31.1 |
| SU/EXP | `sched/wg_x_reg` → DSP（register 無しの乗算、A → P）→ `exp` の LUTRAM の address（fanout 432） | 12 | **23.367 = 6.127 + 17.240**（−16.810、配線）。合成 5 ns: 13 段、11.329 | A + F | 4 / 5（DSP の MREG・PREG と address の複製） | （無し） |
| SU の書き戻し → issue の control | `alu/pipe_reg[5]`（短い結果の valid）→ net `sv`（fanout 542）→ `sched/st`・`dec/u_uop` の R・`sb/e_base` の CE・`opd/a_uop` の CE・`fetch`・`rf` | 15〜18 | **17.983 = 1.102 + 16.881**（sched、−11.341、配線）、sb 17.528、opd 17.888、dec 17.385。合成 5 ns: `wb/inq[0].q/wp_reg` → R・CE（fanout 280）18〜19 段、8.668 = 1.081 + 7.587（−3.929） | F | 段では直らない: valid の複製・decode を 1 cycle 前に・`unit_ready` を issue の予定に（§19.5.1 の 3・7）。最低 3 / 4 | （無し） |
| SU/sb の issue（`atg_su_sb`） | `sb/e_base_reg` → `opd/take`（fanout 116）→ `opd/a_uop` の CE | 10 | **8.643 = 0.898 + 7.745**（−2.236、配線）。合成 5 ns: 11 段、6.480（−1.848）。dec → sb: 10 段、10.885（−4.479、配線） | F | 2 / 2（`take` の複製、比較を 1 cycle 前に） | （無し） |
| SU/opd の operand の選択 | `sched` → `opd/b_warp` → 8 lane × 3 operand の選択。flatten none（p037 の P2）では fanout **2,585** の 1 本、rebuilt では Vivado が `b_warp_reg` を複製して 1 本あたり 125〜131 | — | FPU・lane・PK・ALU・DIV・PT・LDS の経路の始点（ALU: 17 段、16.290 = 1.528 + 14.762、−9.718、配線） | M + F | 1（段 B の出力を register に、§19.5.1 の 4。`OPD_LAT`） | 合成 −31.55（FPU の経路の一部） |
| SU/sched・LDA・exec | `sched/wg_x_reg` → DSP（乗算）→ `sched/fl_s`・`lda` の BRAM の address・`exec` | 11〜15 | sched 15.345 = 6.084 + 9.261（−8.768）、LDA 17.281 = 6.213 + 11.068（−11.089）、exec 16.496（−9.856）、配線 | A | 3 / 4（DSP の register） | 合成 −5.90 / 15（sched → exp） |
| SU/LSU | `lsu/pend_reg` → `lsu/cwd_reg`（coalescer、`lead` の fanout 189） | 11 | **16.019 = 1.260 + 14.759**（−9.377、配線） | F + R | 3 / 4 | 合成 −0.53 / 16、配線 −10.5 / 11 / 15.5 |
| SU のその他 | opd の `b_uop`（複製）・`cr_en` から tex・cbank・div・pt・lds・wb・icache | 2〜13 | tex 15.554 = 0.315 + 15.239（2 段、fanout 803）、div 12.821、pt 13.089、cbank 12.575（fanout 285）、wb 12.260、lds 11.756、icache 11.109（−4.83〜−9.24、配線）。dcache だけ met（+1.267） | F | 2 / 3（enable の複製） | （無し） |
| TU/addr の foot | `addr/k_reg[0]_rep` → `foot/u_lbk` の `ta_addr`（line の address） | 67 | **24.966 = 11.947 + 13.019**（−15.118、TU の単体の配線 10 ns）。core の合成 10 ns: 72 段、28.014 = 12.601 + 15.413（−18.473、`crd` → `foot/u_kp` の DSP） | A | 3 | 配線 −21.448 / 84（TU 全体） |
| TU/addr の tcrd | `addr/k_reg[0]_rep` → `tcrd/u_pw` の DSP の PCIN | 58 | **21.080 = 9.120 + 11.960**（−12.137、配線） | A | 3 | （同じ経路の一部） |
| TU/desc | `desc/cs_reg` → `d_off` の LUTRAM（fanout 440） | 28 | **18.579 = 9.240 + 9.339**（−8.927、配線） | A + F | 2 | 配線 −15.905 / 28 |
| TU/cube | `addr/job_reg` → `cubeu/ns_num`（fanout 215） | 39 | **16.126 = 3.507 + 12.619**（−6.177、配線） | A | 2 | 配線 −11.122 / 33 |
| TU/ffilt | `ffilt/rem_reg` → `front/raw1`（fanout 164） | 7 | 10.526 = 0.656 + 9.870（−0.555、配線） | M + F | 2（index を 1 cycle 前に） | 配線 −4.098 / 7 |
| TU/filter・ffilt の fma | — | 4〜6 | met（filter +2.906、fma +3.992、配線） | — | 1 | 配線 −2.617 / 6 |
| BLT/favg（MS4 1 の時だけ） | `rsv/px/fv/p_reg` → `out_p`（h2f → `atg_su_ffma_p` → f2h、sRGB の encode） | 72 | **26.184 = 6.695 + 19.489**（−16.212、BLT の単体の配線 10 ns）。core の合成: 82 段、28.397（−18.423） | A | 3 | 合成 −23.6 / 84、配線 −30.4 / 94 / 35.4 |
| RX/setup の edge | `setup/edge_u/sv_reg` → `bx1`・`by1`（edge の乗算 `u_m_x1`） | 48 | **14.625 = 6.422 + 8.203**（−4.654、RX の単体の配線 10 ns）。core の合成: 53 段、15.923（−5.949）。frag の bary の fmul −0.434（配線） | A | 2 | 合成 −10.8 / 50、配線 −18.7 / 45 / 23.7（始点・終点は未記録だった） |
| MC の grant → 全部の client | `mc/grant/p_v_reg` → PROT の PLB の `pl_data`（LUTRAM、fanout 194）→ `mc/cnt/unit_n` と、CPU の dma・VF の index・CP の fence・ROP の ds・TU と SU の cache・DC の dma の状態 | 28〜39 | **14.711 = 3.533 + 11.178**（mc/cnt、−4.697、core の合成 10 ns）。client 側: CPU −3.217（36 段、13.231）、VF −3.094、TU cache −2.753、CP −2.780、SU dcache −2.633、ROP ds −2.471、DC dma −1.598（合成） | F + A | 2（grant・PLB の応答を 1 段の register に。CP・CPU・VF・DC・cache が一緒に直る） | MC 合成 −1.15 / 18、配線 −11.7 / 10（p036 の形） |
| ROP/wb の fblend | `wb/wpix/fblend/fmt_reg` → comp の decode（fanout 119）→ LUTRAM | 35 | 13.334 = 3.099 + 10.235（−3.513、core の合成）。blend: 29 段、11.417（−1.443、[blend-stage-split.patch](blend-stage-split.patch) は未適用のまま） | A + M | 2 | 合成 −9.36 / 38、配線 −24.0 / 21 / 29.0（wb）。blend の stage 3 は 2026-10-24 に −4.207（5 ns） |
| VF/conv | `conv/c_vk_reg` → `vl_data`（`atg_fmt_comp`、fanout 165） | 32 | 12.344 = 2.542 + 9.802（−2.370、core の合成）。index は MC の grant から −3.094 | A + F | 2 | 合成 −8.06 / 31、配線 −15.6 / 14 |
| DC | cursor の BRAM → `pixels` の LUTRAM | 17 | 12.348 = 8.121 + 4.227（−2.614、core の合成）。pclk の側は OOC では制約が無い（unconstrained） | A（BRAM の出力の register 無し） | 2（DO_REG） | 合成 −7.79 / 22（p037） |
| CP・CPU | MC の grant から（上の行）。CP の中は u_ctl +0.527 | — | 上の行 | F | MC の行で | 合成 −1.31 / 14・−0.49 / 14 |
| 板の外の IP | MIG（ui_clk 200 MHz）・PCIe（125 MHz）・AXI の converter | — | timing は未測定（板は合成だけ、gclk は p024 の低い値）。面積は phase.md の T0 | — | — | 未測定 |

- **読み**: (1) 合成の段数が大きい物（FPU 114、TU 97 → p038 の後 84、BLT 94、lane 75、PK 49、RX 50）は **A**: 演算の全部を 1 cycle に置いている。(2) 配線後に段の少ない経路（CP 11 段で 18.3 ns、MC 10 段で 16.7 ns）が 10〜12 ns を失うのは **R**: LUT 95% の混雑（p036 の申告）。100 MHz の block の多くは、面積が減れば pipeline を足さずに満たす見込み。(3) **F** と **M** は p038 で幾つか直した（a4e323b の CE の複製、max_fanout 64）。
- **棚卸しの抜け（T0 で埋める）**: SU の XU（超越）・div・LDA・EXP・RF の読み（BRAM の出力の register の有無）・scheduler、RX の始点・終点、DC の pclk の側、板の IP の境。p037 の後の全部の値。

### 19.3 目標の Fmax（item 2）

#### 19.3.1 XC7K325T -2 の部品の上限と、1 段に置ける logic（**一般知識、DS182 は読み直していない**）

| 部品 | 上限の目安 | この設計での意味 |
| --- | --- | --- |
| DSP48E1 | 全部の register（AREG/BREG・MREG・PREG）を使って約 600 MHz 級、MREG 無しでは大きく下がる | 乗算は `am_mul` の `LAT`（p036・p037）で DSP の中の register を使う。200 MHz は余裕。DSP から fabric の経路は 1 段に数える |
| BRAM36 | 出力の register 付きで約 500 MHz 級、無しでは clock → 出力が 2 ns 前後 | RF・PT・LDS・cache の BRAM は出力の register（DO_REG）か直後の FF を付けると 200 MHz は余裕。付けないと読みの後の mux が 1 段に入らない |
| CARRY4 | 4 bit で約 0.1 ns、鎖の出入りに約 0.5 ns | 32〜48 bit の加算は 1 段に入る。CARRY4 は Vivado の「段」に数えられるので、段数だけで判断しない |
| BUFG・MMCM | BUFG は約 600 MHz 級、MMCM の VCO は 600〜1440 MHz（`atg_kc705_clk.v` の comment、未確認） | 200・250 MHz の clock は作れる |

この project の実測から得た 1 段の目安（p038 の TU の配線後: 7 段で 5.3 ns、5 段で 5.3 ns、fanout 160 の 6 段で 7.6 ns）: clock → 出力・setup・jitter で約 1 ns を引き、**LUT 1 段 ≈ 0.7〜0.8 ns**（配線込み、混雑の少ない時）。

| 目標 | 周期 | 1 段の LUT の段（fanout ≤ 64、混雑の少ない時） | 当てはまる物 |
| --- | --- | --- | --- |
| 100 MHz | 10 ns | ≤ 11 | gclk の block（§19.1-1） |
| 125 MHz | 8 ns | ≤ 9 | gclk の伸ばし代 |
| 150 MHz | 6.67 ns | ≤ 7 | sclk の予備の値（§19.10 の T2 で 200 が届かない時） |
| 200 MHz | 5 ns | ≤ 5 | sclk。p038 の `atg_tu_fma`（10 段）は合成 +1.40 ns、配線 −0.105 ns（混雑の分） |
| 250 MHz | 4 ns | ≤ 3〜4 | 推さない（BRAM・DSP の全部の register と、LUT 85% 超の混雑では無理が大きい） |

#### 19.3.2 KC705 の案

| 案 | gclk | sclk | pipeline の仕事 | 面積の条件 | ASIC への繋がり | 判断 |
| --- | --- | --- | --- | --- | --- | --- |
| K1 | 100 | = gclk（1 つの領域） | 小（1 段 ≤ 11） | LUT ≤ 約 90% | SU も 100 MHz の構造 → ASIC の約 0.55〜0.9 GHz | ユーザーの「SU は特に分離」に合わない。予備（ASYNC = 0 の板） |
| **K2（推し）** | **100** | **200** | SU は深く（FMA 約 10 段）、他は小 | LUT ≤ 約 85%（§19.6） | SU は ASIC の 1.1〜1.75 GHz の構造、他は後で | ユーザーの「SU を分ける」と「ASIC で 200 MHz でも足りない」に、仕事の量を抑えて応える |
| K3 | 200 | 200 | 全部の block を深く（address・control も 1 段 ≤ 5） | LUT ≤ 約 75%（NSU 1 の今の形では −60k 以上が要る、§19.6） | 全部が ASIC の目標の構造 | README の「200MHz on KC705」の文字どおり。KC705 では面積の判断（機能を外す）が先に要る。p032・p033 の領域 |
| K4 | 125〜150 | 250 | SU は K2 よりさらに深く | LUT ≤ 約 70% | ASIC の 1.5 GHz に余裕 | 推さない（§19.3.1 の 250 MHz の行） |

- **推しの理由**: (1) 性能の主は SU（fp32 の FMA が SU の throughput）、fixed function の block は 100 MHz で 640×480〜720p に足りる（ROP は 1 quad/cycle で 100 MHz なら 400 Mpixel/s、DC の 720p60 は 221 MB/s）。(2) gclk の block は面積の大半（SU 以外で約 107k LUT、p036 の d94076c: 167.3k − SU 60.3k）で、これを 200 MHz に深くすると FF と LUT が増え、混雑がまた timing を壊す。(3) sclk と gclk を別にすれば、SU の pipeline の仕事は他の block の進みと切り離せる（SU を先に 200 MHz の構造に、他は 100 MHz で板を通す）。
- **K2 の限界（正直に）**: (a) **memory の帯域**: MC の木と root が gclk 100 MHz なので、AMB の 1 line = 64 byte で read の peak は 6.4 GB/s、write は 2 flit で 3.2 GB/s（§4.1）。DDR3-1600 の 64 bit（12.8 GB/s peak、MIG の ui_clk 200 MHz）の半分。640×480 の板の目標では足りるが、p015 で memory が律速なら MC を mclk の領域に移す（§19.12 の 6）。(b) **texture の latency**: TU が gclk なので、texture の往復は sclk で見て約 2 倍の cycle と CDC の分（§19.4.3）。warp の数と scoreboard が隠す範囲を超えると fragment の shader が止まる。(c) **SU の 200 MHz は単体の OOC で測る**: 板の全体の混雑（LUT 85% 前後）の中で SU が 200 MHz を保つかは、板の P&R（p025 の後）まで分からない。届かなければ sclk を MMCM の divider で 171・150 MHz に下げる（RTL は同じ、VCO は §19.4.1）。

#### 19.3.3 ASIC（3 nm、mobile、1.0〜1.5 GHz）の見込み（**推定**、ASIC の library で合成していない）

- **方法 1（FPGA と ASIC の差、主）**: 同じ process で FPGA の critical path は ASIC の約 3〜4.6 倍遅い（Kuon & Rose 2007、90 nm）。KC705 は 28 nm、目標は 3 nm で、その間の速さの伸びを約 1.8〜2.5 倍とすると、**KC705 で f MHz の構造は ASIC で約 5.4f〜11.5f**。→ 100 MHz の構造は約 0.55〜1.15 GHz、150 MHz は約 0.8〜1.7 GHz、200 MHz は約 1.1〜2.3 GHz。幅の中ほどを使い、§19.1 では 100 MHz ≈ 0.55〜0.9 GHz、200 MHz ≈ 1.1〜1.75 GHz と書いた（low voltage の mobile の library で遅くなる側に寄せた）。
- **方法 2（FO4 での確かめ、楽観）**: 3 nm の mobile の電圧で FO4 を約 8〜12 ps とし、flip-flop・clock の skew・jitter・OCV で周期の約 15% を引くと、1.5 GHz で約 47〜71 FO4、1.0 GHz で約 71〜106 FO4 が 1 段の logic。LUT 6 入力の関数を gate 2〜3 段（約 3〜5 FO4）とすれば、KC705 の 100 MHz の段（LUT ≤ 11）は約 33〜55 FO4 で、**ASIC の 1.5 GHz にも入る**。ただし ASIC の配線・合成の効率を数えていない（方法 1 の差の大半はそこ）ので楽観。
- **2 つの方法の差は約 2 倍**。安全側（方法 1）で計画する: **SU は KC705 の 200 MHz の構造**（どちらの方法でも ASIC の 1.0〜1.5 GHz に入る）、gclk の block は KC705 の 100 MHz の構造（方法 2 では入るが方法 1 では 1.0 GHz に届かない）→ ASIC では gclk = sclk/2 の 2 つの領域のまま（fixed function の throughput は足りる: ROP 1 quad/cycle で 500 MHz なら 2 Gpixel/s）か、後の WS でもう一度深くする。
- **ASIC で FPGA と変わる所**: (1) **SRAM**: KC705 の BRAM は 200 MHz で上限の半分以下だが、ASIC の小さな 2 port の SRAM は 1.5 GHz で 1 周期のほとんどを使う（推定）→ RF の読みは ASIC で 2 cycle になり得る。`atg_su_opd` の段の数を parameter（`OPD_LAT`）にし、`atg_su_sb` の interlock の定数（今の G + 1）もそこから計算する（§19.5.2）。(2) **配線**: block の間の長い bus（SU ↔ RX・TU・ROP の 500〜850 bit）は ASIC で register の slice が要る。MC の木は 1 hop に 1 段の register を既に持つ（§4.1）。`am_cdc_*` の channel は同期の形（ASYNC = 0）でも register の slice として残せる。(3) **retiming**: ASIC の合成は register を自動で動かせるので、RTL の段の境は「段の数が足りる事」が大事で、境の位置の最適化は ASIC で詰める。am_ の module の `LAT` と `SHORT_LAT` を parameter に保つ。**ASIC で FMA を 4〜5 段に戻せるのは方法 2（楽観）が当たる場合だけ**で、方法 1 では 4〜5 段（KC705 の 100 MHz の構造）は ASIC の 1.0 GHz に届かないので、ASIC でも 10 段前後のまま（library で合成して決める、review M7）。
- **README との食い違い**: amaterrace-gpu の README は「800 MHz is the goal on ASIC processes」（c840a0a）。2026-10-25 04:52 のユーザーの発言は「3nmのASICでmobile向けの1.0-1.5GHzくらい」。後の発言を使った。README の直しはユーザーの判断（U101）。

### 19.4 clock の領域（item 3）

#### 19.4.1 領域の表（KC705、推し）

| 領域 | 周波数（推し） | 源 | 中身 |
| --- | --- | --- | --- |
| `sclk`（新） | 200 MHz（予備 171・150） | mmcm_g の **CLKOUT1**（VCO を 1000 → **1200 MHz**（MULT 6）にし、`SCLK_DIVIDE` 6 = 200、7 = 171、8 = 150。CLKOUT1 は整数の分周だけなので VCO 1000 MHz では 150 MHz が作れない、review L4）、BUFG | 全部の SU（`atg_su` × NSU）。SU の中の I$・D$・LDS・RF・PT・primitive table・cbank・XU・div |
| `gclk` | 100 MHz（伸ばし代 120・150） | mmcm_g の CLKOUT0（VCO 1200 MHz / `GCLK_DIVIDE` 12 = 100、10 = 120、8 = 150。今の placeholder 50 = 20 MHz を置き換え、`GCLK_HZ` も VCO から計算する） | CP（`atg_cp`・`atg_cpu`・firmware の IMEM/DMEM）、VF、RX、TU、ROP、BLT、MC の木と root（PROT の PLB・grant を含む）、DC の DMA・register・cursor の合成（§18 で gclk） |
| `mclk` | 200 MHz（MIG の ui_clk、DDR3 の 4:1） | MIG の中の MMCM | MIG の AXI。gclk ↔ mclk は今の AXI の clock converter（`atg_kc705_axi_cc`、512 bit） |
| `uclk` | 125 MHz（PCIe の axi_aclk_out） | PCIe の core | BAR0 → `am_axi_cdc` → gclk、BAR2 と GPU → host は AXI の converter（今のまま） |
| `pclk` | 25.185 / 74.22 MHz | pll_a / mmcm_b → BUFGMUX | DC の timing generator と出力（今のまま） |
| `tck` | ≤ 30 MHz | BSCANE2 | JTAG の bridge（`am_jtag_regs` の握手、今のまま） |
| `ref_clk` | 200 MHz | SYSCLK の BUFG | MIG の system clock・IDELAYCTRL（今のまま） |

- **MMCM と BUFG の数**: sclk は mmcm_g の空いた出力を使うので clock の管理の部品は増えない。今の使用は MMCM 約 4（mmcm_g・mmcm_b・MIG・PCIe の pipe clock）と PLL 約 2（pll_a・MIG）で、325T の 10 + 10 に対して余る（MIG・PCIe の中の数は IP の生成物で確かめていない）。BUFG は sclk で 1 つ増え、32 に対して 15 前後（推定）。
- **gclk と sclk の比**: 同じ VCO の 2 つの出力なので位相は揃うが、**関係の無い clock として扱う**（`am_afifo` で渡し、Vivado の timing では同期の関係を使わない）。2:1 の同期の設計（§19.12 の 2）は選ばない: gclk・sclk の値を別々に動かせなくなる（予備の 167 MHz、gclk の 125 MHz）。
- **ASIC**: sclk・gclk は別の PLL（または 1 つの PLL の 2 出力）と DVFS の単位。`ASYNC = 0` の時は同じ clock の 1 つの領域になる（mobile の ASIC で GPU 全体を 1 つの clock にする判断も残せる、§19.12 の 7）。

#### 19.4.2 sclk ↔ gclk の境の channel（SU の port の全部。KC705 では graphics の port は SU 0 だけ、SU 1〜は compute の port だけ）

| # | channel（`atg_su` の port） | 向き | 幅（bit、推定） | 今の handshake | 境での形 | RTL の変更 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | command: STATE の broadcast（`st_we/idx/wdata`）、`cs_kick`・`lc_kick`、`inv`、`scrub` | g → s | 約 48 | 書きっ放し（ready 無し） | **1 本の順序付きの FIFO**（STATE の書き込みの後の cs・lc の kick が必ず後に着く）。CP 側の credit で満杯を避ける。**DRAW の warp は SU を通らない**（`draw_kick` は gclk で VF へ、`atg_top.v` 474・890、`atg_cp_seq` の DRAW は VF の idle と inv だけを待つ）ので、VF・RX の warp の要求（ch.3・4）が ch.1 の STATE・inv（LOAD_PROGRAM の I$ の無効化を含む）を追い越し得る（review H1）→ **CP の DRAW・DRAW_RAW は「ch.1 に送った数 == SU が適用した数」（ch.2 の status の word）を待ってから draw_kick を出す**（draw ごとに往復 約 60 ns） | `atg_cp_state`・`atg_cp_seq` に ready（credit）と DRAW の前の適用の待ち。別案: ch.1・3・4 を gclk の側で 1 本の FIFO に合わせて因果の順を保つ（VF と RX の書き込みの throughput を分け合う）、または warp の要求に epoch を付ける |
| 2 | status: `busy`・`fault`・`fault_addr`・`scrub_busy` と、ch.1・3・4 の仕事の数 | s → g | 約 1 + 1 + 32 + 1 + 3 × 8 | busy・scrub_busy は level、**`fault` は 1 cycle の pulse**（`atg_su_sb.v` 291、`fault_addr` は組み合わせの `u_pc`、review H2） | **1 つの status の word**（`{busy_x, scrub_busy, 適用した ch.1 の数, 終えた vertex の warp の数, 終えた fragment の warp の数}`）を 4 相の握手（`am_cdc_hs`）で丸ごと渡す（bit ごとの同期では busy と数が別の cycle に解けて偽の idle になる、review H3 (a)）。`busy_x` は「pop したがまだ効果が見えない item」も含む。**fault は sclk の側で sticky に latch**（fault と addr を保ち、CP の ack か reset で消す）し、event で渡す | `atg_su_cdc` に status の word の組み立てと fault の latch。CP 側の idle = 送った数 == 終えた数（ch.1・3・4 の全部）かつ `busy_x` = 0（§19.7） |
| 3 | VF → SU の vertex の warp: `vl_req/gnt/slot/ptbase`、`vl_we/reg/lane/data/go/mask` | g ↔ s | 要求 約 2、許可 約 12、書き込み 約 76 | `vl_req` は許可まで保つ level（`atg_vf_asm.v` 229）、`vl_gnt` は組み合わせの pulse（`atg_su_sched.v` 170〜173）で pt_take も起こす。許可の後は書きっ放し | **要求 1 件 = g → s の FIFO の 1 entry**（wrapper が level の立ち上がりで 1 回だけ積む）、**許可 1 件 = s → g の event の FIFO の 1 entry**（ch.6 と同じ FIFO）。level を同期すると sclk の側が許可の戻りの間に同じ要求を何度も許可し、PT の block と warp の slot が漏れる（review H4）。書き込みは g → s の FIFO | **`atg_vf_conv` に `vl_ready`（back-pressure）を足す**（1 warp で最大 32 lane × 64 register の word は FIFO に入らない） |
| 4 | RX → SU の fragment の warp: `fl_req/gnt/slot`、`fl_we/reg/lane/data`、`fl_pw_*`、`fl_go/mask/info` | g ↔ s | 要求・許可 約 4、書き込み 約 185 | 同上（`fl_req` も level） | ch.3 と同じ方式（要求の entry と許可の event） | **`atg_rx_frag`・`atg_rx_bary` に back-pressure** |
| 5 | RX の PT の読み: `pt_rd/idx/word` → `pt_rdata` | g → s、s → g | 15 / 32 | 1 cycle の同期の読み。**読み手は 2 つ**（`atg_rx.v` 82〜85: `atg_rx_frag` の copy が優先、`atg_rx_clip` は `pt_busy` で待つ）。frag は読んだ word を次の cycle にそのまま `fl_pw_data` で SU の primitive table へ書き戻す（`atg_rx_frag.v` 188〜197、SU → RX → SU の 1 cycle 固定の環） | **frag の copy（PT → primitive table）は SU の中の command にする**（RX は「entry e の頂点 v の varying を primitive table の slot へ」を ch.4 に積み、SU が中で写す。境を越えず、速い。review H5）。**clip の読みだけ**が要求の FIFO と応答の FIFO（順序どおり、読み手は 1 つ） | `atg_rx_frag` の copy を command に、`atg_su_pt`・`atg_su_lda` の側に copy の FSM、`atg_rx_clip` の読みを streaming に（要求を続けて出し応答を順に取る） |
| 6 | `pt_free/pt_free_idx`（RX → SU）、`pt_done[7:0]`（SU → VF・RX） | g → s、s → g | 9 / 8 | pulse / level | pt_free は FIFO（RX の側の 1 本）。**pt_done は level の同期にしない**: `atg_su_pt` は block を新しい vertex の warp が取る時（pt_take、vl_gnt と同じ時）に done を 0 にし、warp の終わりで 1 にする。bit ごとの `am_sync` では、gclk の側が古い 1 を見たまま新しい warp の許可（channel 3）を先に受け、RX が終わっていない block を読む順序の誤りが起き得る。→ **vl_gnt（slot・ptbase）と「block b の done」を 1 本の s → g の event の FIFO に入れ、gclk の側が done の写しを持つ**（許可の受け取りでその block の写しを 0、done の event で 1） | `atg_top` の `prim_ok` は gclk の写しを見る。VF の許可の握手（channel 3 の要求・許可）はこの event の FIFO に合わせる |
| 7 | TU: `tx_*` | s → g | 約 686 | valid/ready | `am_afifo`（**深さ 16**: pointer の往復は約 5 gclk で、深さ 4 では 1 cycle に 1 つを出せない。RAM32M は 32 深まで LUT の数が同じ、review M5） | 無し |
| 8 | TU: `tr_*` | g → s | 約 529 | valid/ready | 同上（深さ 16） | 無し |
| 9 | ROP: `ex_*` | s → g | 約 847 | valid/ready | 同上（深さ 16） | 無し |
| 10 | ROP: `ex_next`（次に退かせる連番） | g → s | 16 | level（1 ずつ増える） | gray の符号で `am_sync`（FIFO の pointer と同じ） | `atg_su_exp_drain` は等しい時だけ出すので、古い値は遅れるだけ。ただし **warp ごとに export が直列になる**（次の warp は ROP が退かせて ex_next が戻る往復 約 60 ns を待つ: warp ごとに約 6 gclk の泡、review M6）→ 性能の残件（§19.5.2、p032 の論点 8: ex_next の代わりに受け取れる範囲の窓） |
| 11 | D$ の AMB（`d_req_*`・`d_rsp_*`） | s → g、g → s | 611 / 522 | 要求は valid/ready、**応答は ready 無し** | 要求 FIFO と応答 FIFO。SU 側の credit で要求を止める。**credit = 応答 FIFO の深さ − 3**（書き側の満杯の判断は読みの pointer を最大 3 cycle 遅れて見るので、pop の直後に credit を戻すと満杯に見えて応答を落とし得る、review M4） | 今の D$ は outstanding 1。`am_afifo` は DEPTH_LOG2 ≥ 2 なので深さ 4（credit 1）か 8 |
| 12 | I$ の AMB（`i_req_*`・`i_rsp_*`） | 同上 | 約 35（read だけ: wdata と be を渡さない）/ 522 | 同上 | 同上 | wrapper が I$ の wdata・be を落とす |
| 13 | atomic（`at_*`） | s → g、g → s | 98 / 33 | valid/ready、応答は ready 無し | 同上（credit） | 無し |
| 14 | SA（`sa_*`、予約） | — | — | — | 今は tie-off。SA を足す時は SA を sclk に置く（SU と 1 対 1） | 無し |

- **合計**: SU 0 で約 4.3k bit、compute だけの SU で約 1.9k bit。`am_afifo` の記憶は LUTRAM（RAM32M = 4 LUT で 32 深 × 6 bit）で、**SU 0 で約 3〜4k LUT、他の SU で約 1.5k LUT**（ch.7〜9 を深さ 16 にしても RAM32M の数は同じ）（gray の pointer と credit を含む、推定。325T の約 1.7% と 0.7%）。BRAM の FIFO（72 bit 幅で 512 深）にすると 612 bit の channel に BRAM36 が 9 つで、割合で LUTRAM より高い（§19.12 の 3）。
- **新しい common の module**（p037 の規則に合わせ、算術は am_ の module で）: `am_cdc_fifo`（`am_afifo` + `ASYNC` parameter: 0 なら同じ clock の `am_fifo` で同じ深さ・同じ port）、`am_cdc_credit`（ready の無い応答のための credit の counter と FIFO の組、credit = 深さ − 3）、`am_cdc_hs`（4 相の握手）、`am_cdc_gray`（単調な counter を gray で渡す）、`am_rst_cdc`（§19.7 の reset の握手）。`atg_su_cdc`（新しい wrapper: `atg_su` の外側で channel 1〜13 を並べる、`atg_top` の `g_su` の中に置く）。
- **置き場所の判断**: CDC は `atg_su` の外の wrapper に置き、`atg_su` の中は 1 つの clock のまま（SU の TB はそのまま使える）。MC の木の leaf（`am_amb_to_rt`）は gclk に置き、CDC は SU の AMB の口と leaf の間（MC の木は全部 gclk）。

#### 19.4.3 境の遅れ（推定）

- `am_afifo` は書き側 1 cycle（pointer の更新）+ 読み側 2 段の同期（空・満杯の比較は組み合わせ）で、**片道 ≈ 書き側の 1 周期 + 読み側の 2〜3 周期**（以下は 3 周期で数えた上限）。gclk 100 MHz・sclk 200 MHz で s → g ≈ 5 + 30 = 35 ns、g → s ≈ 10 + 15 = 25 ns、往復 ≈ 60 ns ≈ **sclk の 12 cycle**。
- 効く所: D$ の miss（outstanding 1）の往復は今の MC の木（KC705 で 5 hop × 2）+ AXI の converter + MIG に約 60 ns 増える（推定 +20〜25%）。I$ の miss も同じ。texture は往復 + TU の pipeline（gclk の cycle で数え sclk では 2 倍）。export は片道で、ROP の順序の待ち（`ex_next`）は gclk → sclk の片道の遅れが足される。STATE の書き込みと kick は片道 + CP の credit の往復。
- 隠し方: 長い命令（class m・t・x）は scoreboard と他の warp が隠す（§3.1.1）。D$ の outstanding 1 は throughput の限界で、p015（複数の SU、PERF）の課題として残す（timing の範囲の外）。

#### 19.4.4 制約（XDC）と道具

- **今の XDC の弱さ**: 全部の領域の間を `set_clock_groups -asynchronous` にしているので、`am_afifo` の gray の pointer の bus の skew も timing の対象から外れる。2 段の同期は「pointer の bit の到着の差が 1 周期より小さい」事を前提にする（gray なので 1 bit ずつ変わる前提が崩れる）。LUT 85% 前後の混雑で配線が数 ns に延びると前提が崩れ得る（今の 20〜100 MHz では余裕だったが、200 MHz の sclk で詰まる）。
- **推し**: gclk ↔ sclk は clock group ではなく、gray の pointer に `set_max_delay -datapath_only`（速い方の周期）と `set_bus_skew`（速い方の周期）、`am_sync` の 1 段目に `ASYNC_REG`（既に有る）と **d → s1 の `set_max_delay -datapath_only`**（clock group を外すと ASYNC_REG だけでは同期の path が普通に timing される、review M9）、status の word のような握手で渡す multi-bit の値も `-datapath_only`。`report_cdc` の Critical が 0 である事を T1 の受け入れに入れる。**既存の境（mclk・uclk・pclk・tck）の制約の直しは p025 の範囲の外**（Q1 の判断、同じ弱さを持つので Future Work か p024 の板の build で）。LUTRAM の非同期の読み（am_afifo の記憶 → 読み側）も `set_max_delay -datapath_only`。制約は module の名前で書く（`-hier -filter {REF_NAME == am_afifo}` の形、実装の段で Vivado の版で確かめる）。
- **OOC の tcl**: `tools/vivado-ooc.tcl` は port `clk` の 1 つの clock だけを作る。`atg_top` の OOC には `sclk` の port の clock を足す引数（例 `CLOCKS=clk:10,sclk:5`）を足す。SU の単体の OOC は今のまま（`clk` を 5 ns）。

### 19.5 pipeline の方針（item 4）

#### 19.5.1 経路の種類ごとの段の入れ方

1. **FP の datapath（SU の FPU・PK の残り・lane の fadd・XU の多項式、TU の filter（済み）、ROP の fblend、BLT の favg、RX の fadd/fmul（4 段済み）と fdiv（1 bit/cycle の 27 cycle の逐次）、VF・fmt の変換）**: p038 の `atg_tu_fma` を型に、**1 つの fp32 の FMA の pipeline module を共有の部品にする**（p037 の P1 の `atg_su_ffma` の module を、`LAT` parameter を持つ段付きの形にする）。段の目安（200 MHz）: (1) operand の register（opd の段 B の出力）、(2) unpack・flush・special・n/a、(3〜5) 仮数の積（`am_mul` の LAT 3: DSP の AREG/BREG・MREG・PREG）、(6) 指数の差と alignment の shift（`am_shift` を 2 段の mux に）、(7) 加算（48 bit、CARRY4）、(8) LZC と正規化、(9) 丸めと pack、(10) 後処理（sat・min/max の選択・Boolean・fp16 の半分の pack）。(1) は `atg_su_opd` の段 B の出力の register で、bus（x_valid）の後の最初の段なので `SHORT_LAT` に入る（`OPD_LAT` は issue → bus の段で別）。100 MHz の block では隣の 2 段ずつを 1 つにする（`LAT` で）。**結果は今と bit で同じ**（`tools/gsi1fp.py`・`tumodel.py` の model と比べる）。
2. **address の計算（TU の addr・desc・cube、ROP の wpix の offset、VF の fetch、SU の LSU の coalescer、MC の PLB の overlap）**: (a) 式を段に（乗算は `am_mul` の LAT、加算の木の間に register）、(b) **draw・descriptor の単位で決まる値を前計算**（例: TU の level の offset と pitch を descriptor の書き込みの時に表に置き、quad ごとの道から外す。ROP の attachment の base と stride の積も同じ）。(b) は算法の置き換えで、p032 の Fable の論点（§19.5.4）。
3. **fanout・control（TU の cache・filter の enable、addr → cache の handshake、FSM の decode が広い register へ）**: 次の状態の decode を 1 cycle 前に register に、flag の複製（`max_fanout` を RTL の attribute で、p038 と同じ）、広い datapath の register は CE を付けず毎 cycle load して valid の bit で区別、datapath の FF に reset を付けない（control set を減らす: 板の build で 2,930）。
4. **広い mux・選択（SU の opd の operand の選択、TU の ffilt の lane・texel の 128 bit の選択、ROP の wb の line への書き込み、BLT）**: 選択の index（one-hot）を 1 cycle 前に register に、mux の木の中ほどに register（2 段の選択）。SU の opd は段 B の出力を register にして FPU の前に 1 段（今は opd の mux → FPU が 1 つの経路、§19.2 の最悪の経路）。
5. **memory（BRAM・LUTRAM）**: BRAM の読みの直後に register（DO_REG か FF）、BRAM → logic → BRAM を 1 cycle に置かない。LUTRAM の非同期の読みを組み合わせの深い経路の始点にしない（TU の desc の d_off）。RF の BRAM に DO_REG を付けると opd の段が 2 → 3 になる: `OPD_LAT` の parameter と interlock の定数を合わせる。
6. **配線（R）**: 面積を減らす（§19.6）のが先。次に floorplan（SU を pblock に、sclk の領域を 1 つの clock region の列にまとめる）。block の間の長い bus に register の slice（`am_cdc_fifo` の ASYNC = 0 で同じ形）。
7. **止め方（U108）**: pipeline の中で止めない（valid の bit が流れるだけ）。下流が止まり得る所は、入口で credit を見て送り、出口の skid の FIFO（深さ = pipeline の段の数 + 余り）が受ける（p038 の `atg_tu_filter`: 出力の FIFO 4 と credit）。止める信号を pipeline の全段の CE に配らない。**SU の bus を unit が止める `unit_ready` は 13 本の unit から来る**（`atg_su.v` 263〜267: PK_SHARED の high の半分の cycle、`lane` の shfl の 2 × G cycle、LSU・XU・TEX の `x_ready = st == IDLE`、div・LDS・cbank・EXP、NPHYS 16 の LDA。`x_end` も依る、review M8）。**決まった予定の物（PK_SHARED・lane・LDA）は issue の段（`atg_su_sb`・`opd`）が uop から予定を作る形に、長い unit（LSU・XU・TEX・div・LDS・cbank・EXP）は issue の段が unit の busy を credit で見る形に**して、unit から段 B の hold（3 × 256 bit + uop）と RF の `r_en` への組み合わせの戻りを無くす。残す場合は enable の複製と RF の DO_REG の REGCE を明記する。

#### 19.5.2 latency が与える影響

**SU（scoreboard・ISA・性能）**

- `SHORT_LAT` は class a と f の結果が bus の後に戻るまでの cycle（今 6）。FPU を §19.5.1-1 の 10 段（operand の register と後処理を含む）にすると、書き戻しの段を入れて **約 10〜12**（T2 で決める）。ALU・lane・LDA・PK の結果も同じ長さに遅らせる（1 本の固定長の pipeline、§3.1.1 の WAW を起こさない形）。遅らせる register は SRL（LUT の shift register）で安い。
- **`atg_su_sb` の `CD_W = 4`**: 短い書き手の countdown は `SHORT_LAT + 1` まで数えるので、今の幅では `SHORT_LAT ≤ 14`。`CD_W = clog2(SHORT_LAT + 2)` にし、`{28'd0, c_cnt…}`（243 行）の幅も合わせる。**短い書き手の数 `NSH = SHORT_LAT + 2`（83 行）も 8 → 12〜14 に増え**、`hz_short` の比較と `c_slot` の優先の encoder が issue の組み合わせの道（`u_ready`、276〜280 行）で伸びる（review L3）: これ自体が 200 MHz の timing の経路の候補で、T0 の棚卸しに入れ、必要なら hazard の判定を 1 cycle 前に register にする。
- **ISA**: 変わらない。latency は scoreboard の interlock（読み手は書き手の countdown が G + 1 以下になるまで待つ）が隠し、GSI1 の binary は NPHYS・`SHORT_LAT` に依らず動く（§3.1）。`docs/gsi1.md` §3.4.2 の「f（DSP の pipeline、4〜6）」は「実装が決める」に直す（文書だけ）。
- **compiler**: zedBSD の `gsi1-schedule.c` は register に入らない program だけ純粋な命令を最初の読み手の直前に沈め、それ以外は parser の順のまま（latency の model が無い）。依存の続く命令が隣り合えば latency はそのまま stall になる。latency を見て独立の命令を間に挟む list scheduling は性能の改善で、正しさには要らない（Future Work の候補、Q1 が登録を判断）。
- **性能の見積もり**（`atg_su_sb` の 243・388 行と `opd` の 2 cycle からの近似: 同じ warp の依存する次の命令は約 `SHORT_LAT + 2` cycle 後（review L1 で + 1 から直した）、1 命令は bus を G = 32/NPHYS cycle 使う。NPHYS 8 で G = 4。全部の命令が直前に依存する最悪の場合、bus の使用率 ≈ min(1, k × G / (SHORT_LAT + 2))、k = runnable な warp の数。**TB で測って直す**。比較の基準「SHORT_LAT 6 で 100 MHz」は、今の RTL を K1 で 100 MHz に通した仮の形）:

| SHORT_LAT | k = 1 | k = 2 | k = 3 | k = 4 | 1 秒の group の数（k = 2）、sclk |
| --- | --- | --- | --- | --- | --- |
| 6（今、100 MHz の仮の基準） | 50% | 100% | 100% | 100% | 100 M（100 MHz） |
| 8 | 40% | 80% | 100% | 100% | — |
| 10 | 33% | 67% | 100% | 100% | 133 M（200 MHz） |
| 12（推しの見込みの上） | 29% | 57% | 86% | 100% | **114 M（200 MHz）** |
| 14（今の CD_W の上限） | 25% | 50% | 75% | 100% | 100 M（200 MHz） |

  → **200 MHz で SHORT_LAT ≤ 12 なら、k ≥ 1 のどこでも 100 MHz で SHORT_LAT 6 より遅くならない**（k = 1 で 57 M 対 50 M）。**ただし T2 の後、T1（sclk）の前で止めると、SU は gclk の 100 MHz のまま SHORT_LAT が伸びるので、k = 1 で 29% 対 50% と今より遅い**（review L6）。NWARPS 4 の KC705（fragment の予約 2）で、長い命令の待ちで runnable が 2 以下になると使用率が下がる。NWARPS 8 は BRAM が要る（§3.5 の構成 D）ので v1 では変えない。

**他の block**

| block | 増える latency | 効く所 | 対処 |
| --- | --- | --- | --- |
| TU | p038 で quad ごとの drain（nearest 14.6 → 28.4 cycle など） | fragment の texture の待ち（scoreboard が隠す範囲）と、quad の throughput | p032 の論点: 次の quad を drain の前に入れる（pass の重ね）。gclk 100 MHz で sclk から見ると 2 倍 |
| ROP | blend の LAT 3 → 4（patch）、fblend・wb の段 | 同じ line の続く quad の読み書きの依存（wb の 2 line の entry の間） | LAT の parameter で wb の待ちが合う事を TB で確かめる（`atg_rop_*` の TB と `atg_top_msaa`） |
| RX | setup の microcode の FP の latency | primitive ごとの setup の cycle（小さな三角形の throughput） | `tools/rx-ucode.py` が fadd/fmul/fdiv の latency を前提に schedule を作る → LAT を変える時は生成し直す |
| VF・BLT | 段の分 | stream の throughput は変わらない、最初の結果が遅れるだけ | 無し |
| CP・CPU・MC | 100 MHz では変えない見込み | — | — |
| CDC | §19.4.3 | D$・I$ の miss、texture、export の順序 | §19.4.3 |

#### 19.5.3 p025 の 1 段目でしない事

- 算法の置き換え・近似（例: FMA を別の形に、TU の LOD の近似）は p032 の Fable の助言の後（ユーザーの 3 段の方針）。p025 は「同じ結果のまま段を入れる」と「fanout・選択の register 化」だけ。
- 面積を減らす機能の判断（U80・U81・U84 など）はユーザーの判断で、p025 は測って選択肢を示す。

#### 19.5.4 p032（Fable 5.1 High の助言）に渡す論点

1. TU の address: descriptor の書き込みの時の前計算（level の offset・pitch の表）で quad ごとの道から乗算を外せるか。cube の面の選択と除算の準備を `rcp` の table + 1 段にできるか（Vulkan の精度の要求の中で）。
2. SU の FMA の段数と ASIC: 200 MHz の KC705 で 10 段、ASIC の 1.0〜1.5 GHz で 4〜5 段に戻す `LAT` の分け方。`SHORT_LAT` を class f と a で分ける（2 つの latency と書き戻しの衝突の調停）価値があるか。
3. TU の drain: 次の quad を重ねる形と、fragment の warp の数・scoreboard の entry で texture の latency を隠せる範囲。
4. RX の setup: microcode の datapath（fadd・fmul・fdiv が 1 つずつ）の段と、primitive の setup の throughput（小さな三角形）。
5. ROP の blend の 8 bit の道と f32 の道を 1 つにできるか（面積）、throughput（RGBA8 は 1 quad/cycle）を保つ条件。
6. BLT の favg（RESOLVE の fp・sRGB の平均）を shader（compute）に移す価値（§15.8 の決定の見直しになる）。
7. 繰り返しの指針: 各回に何を測り（block の OOC の合成と配線、段数、LUT・FF）、どこで打ち切るか。
8. export の順序（`ex_next`）が境の往復で warp ごとに直列になる件（§19.4.2 の 10）: ROP が受け取れる連番の窓を SU に渡す形など。

#### 19.5.5 FP の演算器の共通化と target 別の実装（2026-10-26 ユーザーとの相談、Phase は [p042](phase042/phase.md)）

- **RTL の階層**（ユーザー「rtl/ bsp/ --> JTAGとか library/ gpu/ みたいなのがいいと思いました」）: `rtl/bsp/`（FPGA の family・process に依存する primitive。`xilinx7/`・`generic/`・将来の `asic/` を file list で選ぶ。今の am_jtag_regs の BSCANE2 など）、`rtl/library/`（`arith/` = 整数の演算 am_add・am_sub・am_addsub・am_shift・am_mul・am_div・am_msb、`fp/` = 共通の FP の演算器、`bus/` = AXI・AMB・FIFO・CDC・同期）、`rtl/gpu/`（今のまま）。板に固有の top・XDC・IP・clock は `boards/<板>/` のまま。arith-lint の規則は「rtl/library/arith と fp の外は 0」に。
- **重複をまとめる**: fp32 の加算（`atg_su_fadd` 組合せ、`atg_rx_fadd` 4 段）、乗算（`atg_rx_fmul`）、FMA（`atg_su_ffma`・`atg_su_ffma_p`、`atg_tu_fma` 10 段、BLT が `atg_su_ffma_p` を使う）、fp16 → fp32（`atg_su_h2f`・`atg_fmt_h2f`）を `rtl/library/fp/` の 1 つずつに（段数は parameter）。
- **約束**: (1) target の版は同じ module の名前と port で、`ifdef` を散らさず file list で選ぶ（小さな違いだけ `ifdef`）。(2) 各 module が `localparam LAT`（段数）を公開し、呼び出し側（SU の `SHORT_LAT`・scoreboard、RX・TU の valid）はその値で合わせる（U104・U108）。(3) どの target でも結果は GSI1 の規則で bit 単位で同じ。generic と各 target を等価の harness（旧 p037 の function と module の比較の形）で比べる回帰。(4) datapath の module（FMA など）は `STAGES` の parameter を持ち、段の位置を module の中で決める（KC705 は少ない段、ASIC は多い段）。
- **FMA の構造**（2026-10-26 の相談）: FPGA では乗算は DSP48E1 のまま（MREG・PREG に段）で、肝は桁合わせ・正規化・丸めの段の分け方。ASIC では積を carry-save のまま加数と 3:2 で足し CPA を 1 回にする FMA 用の乗算（`am_mul_csa` の案、`rtl/library/fp/` か `arith/`）、桁合わせを乗算と並行、LZA、sticky の先回り、fp16×2・int8 への木の分割。KC705 は今の `am_mul` + `am_addsub` に戻せる形にする。
- **外部の部品**（Future Work [fw-amaterrace-asic-flow](../future-work.md)）: Synopsys DesignWare（`ifdef USE_DESIGNWARE`）、Xilinx UNIMACRO（`ifdef USE_UNIMACRO`、推論で DSP の register に入らない時の保険）、open-source の FPnew・HardFloat・FloPoCo は、ASIC の流れ（商用か OpenROAD か）が決まった時に `rtl/bsp/` と `rtl/library/fp/` の target の版として検討する。

### 19.6 面積の見通し（item 5）

| 時点・構成 | LUT | FF | BRAM36 | DSP | 出所 |
| --- | --- | --- | --- | --- | --- |
| p036 d94076c、OOC の core（NPHYS 8、PK_SHARED 1、NSU 1、MIG・PCIe・DC 無し） | 167,293（82%） | 78,371 | 106.5 | 146 | Q1 が report で確かめた（LUT）、他は P2 の申告 |
| p024 8040e3d、板の全体（PK_SHARED 0、p038 の TU、MIG・PCIe・DC・AXI の converter 込み） | 215,131 combined（105%）・247,510 total（**place の指標で、上の行の合成の Slice LUTs（LUT as Memory 6,434 を含む）と同じ指標かは確かめていない**、review M11: T0 で両方を opt_design の後の report_utilization の Slice LUTs で揃える） | 120,230（29%） | 127 + 19/2 | 183 | P2 の申告、place で停止 |
| 差（板 − core）の内訳の推定 | +48k = PK_SHARED 0（+約 8k）+ MIG・PCIe・AXI の 512 bit の converter と crossbar・DC（+約 35〜40k、IP の内訳は未測定）+ p038 の TU（LUT −約 2k、FF +6.7k） | | | | 推定 |

**p025 の後の見込み（板、NSU 1、推定）**:

| 項目 | LUT の増減 | 根拠 |
| --- | --- | --- |
| 板の top に `SU_PK_SHARED = 1`（U105） | −約 8k | p036 の OOC: PK + FPU 31.4k → 23.7k（PK だけでは 14,459 → 2,953 だが FPU が shared の形で増える） |
| p037（算術の am_ の module） | 未知（±数 k） | p036 で共有は済み。置き換えは同じ回路の書き直しが主。T0 で測る |
| sclk ↔ gclk の CDC（§19.4.2） | +3k〜+4k | LUTRAM |
| pipeline の register と control（SU・TU・ROP・RX・BLT・VF） | +6k〜+12k（LUT）、+20k〜+30k（FF） | p038 の TU で LUT −1.9k・FF +6.7k（28,631 / 8,281 → 26,754 / 14,948、filter の重複を除いた分を含む）。SU の 8 lane × 約 6 段 × 約 150 bit ≈ 7k FF など |
| **合計の見込み** | **約 216k〜223k（106〜110%）** | 入らない |

- **timing に要る空き**: 7 series で LUT 85% を超えると配線の混雑が timing を大きく壊す（p036 の配線後: 95% で短い経路も 10〜12 ns を失った）。K2（gclk 100 / sclk 200）の目安は **LUT ≤ 85%（約 173k）**、K3（全部 200）は **≤ 75%（約 153k）**。→ K2 で **約 −43k〜−50k** が要る。
- **減らす手（推定、Vulkan への影響つき。ユーザーの判断は U106 で、測った後に）**:

| 手 | LUT の効果（推定） | Vulkan・性能への影響 | 状態 |
| --- | --- | --- | --- |
| U81 SUBGROUP 1 → 0 | −約 2〜4k（p036 の SU 単体: NPHYS 8 で P1S1 69.1k と P0S0 52.8k の差 16.3k から、PK packed の約 14k を引いた残り。**測り直す**） | Vulkan 1.1 の subgroup の機能が無くなる（1.0 には要らない） | 未決（p036） |
| U80 PACKED 1 → 0（PK_SHARED 1 の上） | −約 3k（PK shared 2,953 + decode） | fp16 の算術の命令が無くなる（1.0 は求めない）。fp16 の packed の速さの利点（§3.6 の 2026-10-24 の案）が無くなる | 未決 |
| U84 fp32 の FPU を一部の lane に（例 8 → 4） | −約 10k（FPU 20.8k の半分） | fp32 の throughput が半分 | 未決（保留） |
| SU_NPHYS 8 → 4（新しい案、推さない） | −約 15〜20k（FPU・lane・opd・RF の bank） | SU の throughput が半分、U82 の決定の見直し | 案だけ |
| TU の 8 bit の filter と fp32 の filter を 1 つに（p036 の範囲 4 の案） | −約 5〜8k | 8 bit の texture の throughput が下がり得る | p032 の論点 |
| BLT の favg を shader に（§19.5.4 の 6） | −約 5〜8k | RESOLVE の fp・sRGB の format が shader の dispatch に（firmware の変更） | p032 の論点 |
| RX の cpoly の pb を BRAM に（p036 の候補） | −約 2〜3k | 無し（clipper の作り直し） | 候補 |
| ROP の 8 bit と f32 の blend を 1 つに | −約 5〜10k | RGBA8 の throughput の条件（§19.5.4 の 5） | p032 の論点 |
| 板の DC・PCIe を外した timing の確かめ用の build | −約 20〜30k | 最初のゴール（PCIe の GPU）には使えない。timing の測定だけ | 推さない（測定は OOC で足りる） |

- **FF・BRAM・DSP**: FF は +20〜30k で約 35〜37%、BRAM は CDC を LUTRAM にするので増えない、DSP は FMA の段で変わらない（183 / 840）。**律速は LUT だけ**。
- **NSU > 1**: KC705 で 1 SU が 85% に入らない間は、U83（NSU の目標 4〜6 → 当面 1、未決）の推しのまま。

### 19.7 状態遷移・資源の所有と寿命・並行性（CDC で変わる所）

- **CTRL.RESET の順（§1.3）**: 今は quiesce の後に core の reset を **1 cycle**。握手の対象は SU・境の全部の FIFO・credit の counter・status の word・gray の counter（ch.10）・gclk の側の done の写しと event の FIFO。`am_afifo` は reset の間も `w_ready` が 1 なので、**reset されない側（MC の leaf は領域 (b)）が書くと data が黙って捨てられる** → `am_rst_cdc` は reset の間、reset されない側の `w_valid`・`r_ready` を止める（review M3）。sclk の領域と境の FIFO は「両側を同時に、遅い clock の 3 cycle 以上」の reset が要る（`am_afifo` の約束）。→ `atg_cp_ctl` の reset を **握手**に: `am_rst_cdc` が gclk で reset を立て、sclk に同期して SU と境の FIFO の両側を reset し、sclk の側が reset を見た印を gclk に返し、両側で最小の cycle を満たしてから下ろし、CP は「両側が解けた」印の後に `RESET` の bit を落とす。watchdog の FAULT → HALT → quiesce → driver の RESET も同じ。**SU が止まった（hang）まま、境の FIFO が満杯でも、両側を同時に reset するので正しく空になる**（FIFO の内容は捨てる: reset の意味どおり）。
- **quiesce**: MC の木は gclk のままなので AXI の quiesce は変わらない。SU の AMB の要求は境の FIFO の中に残り得る → **境の要求 FIFO は leaf の待ち行列と同じ扱い**: `axi_idle` には入れず（入れると HALT が root の新しい発行を止めているので空にならず RESET が永久に待つ、review M1）、core の reset と flush で捨てる。発行済みの要求の応答は必ず返り、credit で境の応答 FIFO に入る。
- **PROT の session の切り替え（§17.6）**: session の tag は leaf で付く（`atg_top.v` の `c_req_slot = prot_unit`）ので、前の session の SU の要求が境の FIFO に残ったまま `drain_ok` が成り立つと新しい session の tag で出る（review M2）→ `drain_ok` に「境の要求 FIFO が両側から見て空、かつ SU の側に未完の AMB の要求が無い」を足す。D$・atomic は scoreboard が応答まで busy を保つので今も安全、**I$ が SU の busy = 0 の間に要求を出すか（先読み）は未確認**で T1 で確かめる。
- **WAIT_IDLE(SU)・FENCE・LOAD_CONST と偽の idle（§19.4.2 の 2）**: CP が kick を送った直後、SU の busy の同期はまだ 0。仕事を運ぶ g → s の channel は ch.1 だけでなく ch.3（vl_go）・ch.4（fl_go）もある（VF の busy が落ちた後、SU の busy がまだ見えない間がある: vertex だけの draw など）。→ gclk の側は ch.1・3・4 に送った item の数を数え、SU は **終えた**数と `busy_x` を 1 つの status の word で返す（握手で丸ごと、bit ごとの同期をしない）。idle = 全部の送った数 == 終えた数 かつ `busy_x` = 0（同じ word の値）。PROT の `drain_ok`（`atg_top.v` 724〜725 の `units_busy`）と session の切り替えの scrub（§17.6）も同じ word を使う（review H3）。
- **順序**: STATE の書き込みと kick は 1 本の FIFO で順を保つ。vertex の warp の許可と PT の block の done は 1 本の s → g の event の FIFO（§19.4.2 の 6: done を level で同期すると、block の取り直しの後に古い done を見て RX が早く読む）。VF の vertex の書き込みと `vl_go` も 1 本の FIFO。RX の fragment の書き込み・primitive table の書き込み・`fl_go` も 1 本。RX の PT の読み（channel 5）と pt_free（channel 6）は別の FIFO なので、RX は pt_free を出す前に、その primitive の読みの応答を全部受け取る（今も読みの後に free するので変えない）。
- **所有**: 境の FIFO は `atg_su_cdc` が持ち、寿命は core の reset の領域と同じ。

### 19.8 失敗と corner case

| 場合 | 振る舞い |
| --- | --- |
| sclk の MMCM が lock しない、または sclk が止まる | sclk の reset は `mmcm_g` の LOCKED（gclk と同じ MMCM）で解けるので、gclk が動けば sclk も動く。sclk だけ止まる事は板では無い。SU が応答しなければ watchdog（gclk）→ FAULT → RESET の握手は sclk の reset の印が返らず止まる → **`am_rst_cdc` に gclk の timeout を付け、来なければ STATUS に印**（driver は PCIe の reset に上げる。§1.3 の AXI_STUCK と同じ扱い） |
| 境の FIFO が満杯で、SU が止まった | 上流（CP・VF・RX・TU・ROP）は ready で待つ。watchdog が切れ、reset の握手で両側を空にする |
| ASYNC = 0（同じ clock） | `am_cdc_fifo` は同期の FIFO。境の遅れは 1〜2 cycle に減る。TB は同じ（cycle の数だけ変わる） |
| gclk と sclk の比が変わる（150・167 MHz） | RTL は比に依らない（TB を比 1:1・1:2・2:1・5:7 で流す、§19.9） |
| gray の pointer の skew が制約されていない | §19.4.4 の制約で防ぐ。Vivado の report_cdc で確かめる（実装の段） |
| ex_next の同期が遅い | export が遅れるだけ（等しい時だけ出す） |
| D$ の応答が境の FIFO に入らない | credit が要求を止めるので起きない（credit = FIFO の深さ − 3） |
| SU の ISA の fault の pulse（1 sclk） | sclk の側で sticky に latch し event で渡すので落ちない（§19.4.2 の 2） |
| DRAW の直前の STATE・LOAD_PROGRAM | DRAW は ch.1 の適用の数を待ってから draw_kick（§19.4.2 の 1） |

### 19.9 試験の計画（host の iverilog・Verilator と Vivado の OOC。QEMU・VFIO・板はこの Phase に無い）

- **CDC の module**: `am_cdc_fifo`・`am_cdc_credit`・`am_cdc_hs`・`am_cdc_gray`・`am_rst_cdc` の TB を 2 つの clock の比（1:1・1:2・2:1・5:7・7:5、位相をずらす）で、乱数の valid・ready、reset を流している途中で両側に入れる場合、ASYNC = 0 の場合。
- **`atg_su_cdc` と `atg_top`**: 既存の scene の TB（`atg_top_core`・`atg_top_tex`・`atg_top_msaa`・`atg_top_prot`・`atg_top_disp`・`atg_top_fw`）を sclk ≠ gclk（比 2:1 と 5:7）と ASYNC = 0 で流し、結果が今と word で同じ（vec-diff）。cycle の数は変わる（期待しない）。reset の握手の TB（SU が hang の時の RESET、watchdog）。
- **SU の pipeline**: `atg_su_fpu`・`pk`・`lane`・`lda`・`alu`・`sb` の TB を新しい `SHORT_LAT` で、`gsi1model.py` と bit で同じ。`atg_su_gfx`・`atg_su` の +quick。interlock の性能（§19.5.2 の表）を TB で数える（依存の続く命令の列を k = 1〜4 の warp で）。
- **CDC の競合を sim で出す**（review M10）: iverilog・Verilator の 2 段の同期は決まった遅れで動き、順序の誤り（§19.4.2 の 1・3・6、偽の idle）は同期の ±1 cycle の揺れで初めて出る → sim 用に `am_sync`・`am_afifo` の同期を乱数で 2 段か 3 段にする model（`ifdef`、seed を記録）。足す TB: DRAW の直前の STATE と LOAD_PROGRAM（H1）、fault の pulse（H2）、kick の直後の FENCE と WAIT_IDLE（H3）、vertex の warp の要求の連続（H4）、frag の copy（H5）、PROT の session の切り替えの最中に境に要求が残る場合（M2）、reset の間の reset されない側の書き込み（M3）。Vivado の `report_cdc`・`report_methodology` を T1 の受け入れに。
- **Verilator**: `make verilator`、fw-run、ghci-e2e（Q1・T が流す）。Verilator は 2 つの clock を TB の C++ で回す。
- **timing**: Vivado の OOC（`tools/vivado-ooc.sh`、lock `/tmp/zedbsd-vivado.lock`）で block ごとに 5 ns（SU）と 10 ns（gclk の block）の合成と配置配線、段数、LUT・FF・DSP・BRAM の前後。`atg_top` は 2 つの clock の OOC。**板の P&R は回さない**（2026-10-25 20:35 ユーザー「20MHzも低すぎます。その段階でP&Rをやっても、あとでひっくり返るので、無駄になりそうです」、20:36 の順「p037 → p025 → board の P&R と bitstream → p024 → p028」）。板の全体の **合成だけ**を T0 で（U105）。
- 試験の流し方は AGENTS.md の方針: 実装の担当は変えた module の TB と build（warning 0）まで、make sim の全部と Verilator は T に回す。

### 19.10 実装の段と受け入れ（LW は 8 LW ≈ 2〜3 時間の単位）

ユーザーの「タイミング調整に使える作業時間をコントロールしたい」（2026-10-25 01:08）に合わせ、**どの段の後でも止められる順**にした（T2 の後は ASYNC = 0 の 1 つの clock の板、T3 の後は gclk 100 MHz の板が作れる）。

| 段 | 中身 | 受け入れ | LW |
| --- | --- | --- | --- |
| T0 | p037 の merge の後の基準: block ごとの OOC（5 ns と 10 ns、合成と配線）、§19.2 の表の更新と抜けの経路（`atg_su_sb` の issue の道を含む）、板の全体の合成だけ（`SU_PK_SHARED = 1`、hierarchy の utilization、指標を揃える。U105 の判断の後） | 表と report が `plan/ws001/phase025/evidence/` に。**ここで U106（面積）の判断を受けてから T2 へ** | 4 |
| T2 | SU の pipeline: FPU（共有の段付きの FMA）、PK の残り、lane の fadd、LDA・ALU の遅れ、opd の段 B の register と `OPD_LAT`、`sb` の `CD_W`、`unit_ready` の予定化（§19.5.1 の 7） | SU の TB が bit で同じ、SU の単体の OOC で 5 ns の WNS（met しなければ申し送り）、§19.5.2 の表を TB で測った値に | 20 |
| T3 | gclk の block を 10 ns に: TU の addr・desc・cube・cache、ROP の blend の patch・fblend・wb、RX、BLT の favg、VF の conv、CP・MC・CPU の確かめ | 各 TB が今と同じ、block の OOC で 10 ns の WNS（met しなければ申し送り） | 16 |
| T1（**U109 の推しでは別の Phase**） | CDC: `am_cdc_*`・`am_rst_cdc` と TB、`atg_su_cdc`、VF・RX の back-pressure、要求の entry と許可の event（ch.3・4・6）、frag の copy の SU の中への移し、clip の読みの streaming、command の FIFO と CP の credit・DRAW の前の待ち、status の word と idle の数え方、fault の latch、`atg_cp_ctl` の reset の握手、`atg_kc705_clk` の VCO 1200 MHz と O1、XDC（§19.4.4）、OOC の tcl の 2 つの clock、sim の乱数の同期の model | §19.9 の CDC と scene の TB（word 一致、比の違う clock、乱数の同期の seed を複数）、`report_cdc` の Critical 0、2 つの clock の `atg_top` の OOC | 28 |
| T4（伸ばし代） | gclk の block の FP の datapath を 5 ns の構造に（ASIC 向け）、gclk 125 MHz の試し | 時間が余った時だけ | 8 |
| T5 | p032 への申し送りの表（経路・WNS・段・試した事・理由）、T への依頼の取りまとめ | p025 の受け入れ（ユーザーの 3 段の方針: met しない経路が残っても cleared） | 4 |

- 合計 **72 LW（T4 を除く。T1 の 28 を別の Phase にすれば p025 は 44）、±40%**。止める所ごとの板の形: T2 の後で T1 の前に止めると、SU は gclk のまま `SHORT_LAT` だけ伸びて今より遅い（§19.5.2）ので、T2 は T1 と組にするか、`SHORT_LAT` を parameter で 6 に戻せる形（100 MHz の時は FMA の LAT を浅く）にする。T2 は p037 の P1 の FPU の module（`atg_su_ffma` など）が main に入った後に始める。T1 は T2・T3 と別の file が多いので並べられる（`atg_top`・`atg_cp_ctl`・VF・RX は T3 と重なる: 担当を分ける時は Q1 が file の所有を決める）。
- **p025 の受け入れ（phase.md と同じ、目標の値を U100 で直す）**: gclk の block と SU の目標の周波数で OOC の WNS ≥ 0 になった経路と、ならなかった経路の申し送りの表。sim の TB は全部 PASS のまま（T）。met しない経路が残っても cleared。

### 19.11 GHCI・driver・firmware への影響

- **GHCI**: 変えない（U107）。`GCLK_HZ` は gclk の Hz。watchdog（`WDT_CYCLES`）と PERF は gclk で数える（SU の busy は同期した level を gclk で数える。PERF の「SU busy cycles」の意味は「gclk の cycle の内 SU が busy だった数」で今と同じ）。sclk の Hz は amaterrace の vendor の register（`VEND` の空き、`docs/ghci.md` の vendor の節に 1 行）。
- **driver**（zedBSD `src/drivers/gpu/ghci/`）: 変更無し（`gclk_hz` を読むだけ）。timestamp は今も無い（`timestampComputeAndGraphics` = FALSE）。
- **firmware**（`fw/cp/`）: CPU は gclk のまま。STATE の書き込みと kick の順序は hardware の FIFO が保つので変更無し。`GCLK_HZ` を使う timeout は gclk の値で正しい（板の top の `GCLK_HZ` を `GCLK_DIVIDE` から計算している）。
- **compiler**: 正しさの変更無し。latency を見る scheduling は Future Work の候補（§19.5.2）。

### 19.12 選ばなかった案と理由

1. **全部を 1 つの clock で 200 MHz（K3）**: README の文字どおりだが、KC705 の今の形（NSU 1 で LUT 105%）では −60k 以上の機能の判断が先に要り、fixed function の block の深い pipeline は FF・LUT と混雑を増やす。p032・p033 の領域として残す。
2. **sclk = 2 × gclk の同期の関係（同じ MMCM、CDC 無しの 2:1 の多 cycle の path）**: 境の遅れが小さい（1〜2 cycle）が、gclk と sclk を別に動かせない（予備の 167 MHz・gclk 125 MHz）、ASIC の DVFS と合わない（2:1 の同期なら Vivado は 5 ns で普通に timing するので制約は増えないが、gclk 側の path が sclk の周期で詰まる）。ASYNC = 0 の形で「同じ clock」は残す。
3. **境の FIFO を BRAM（FIFO36E1）に**: LUT を使わないが、612 bit の channel に BRAM36 が 9 つ（325T の 2%）で、LUTRAM の約 400 LUT（0.2%）より割合で高い。LUT が律速の今でも、境の LUT は合計 3〜4k なので LUTRAM のまま。
4. **SU と TU を 1 つの shader の cluster の領域に（NVIDIA の SM・Mali の shader core の形）**: SU ↔ TU の境（約 1.2k bit）が無くなり texture の latency が減るが、TU の address の経路（配線後 −21 ns @ 5 ns）を 200 MHz にする仕事が要り、TU の MC の口が境を越える。v1 は SU だけ（ユーザーの「SU は特に」）。U102 の別案として残す。
5. **CDC を `atg_su` の中（各子 module の口）に**: 境の bit が増え（RF・LDS は中）、SU の TB が 2 つの clock を要る。外の wrapper の方が SU の中を 1 つの clock に保てる。
6. **MC の木と root を mclk（MIG の 200 MHz）に**: memory の帯域が gclk に縛られなくなる（K2 の限界 (a)）が、全部の client（CP・BLT・VF・TU・ROP・DC）の leaf に境が要り、PROT の root（§17）も跨ぐ。p015 で memory が律速なら見直す。
7. **mobile の ASIC で GPU 全体を 1 つの clock に（Kepler 以降の形、hot clock を使わない）**: 電力の効率は良い（深い pipeline と高い電圧を shader だけに使わない）。ASIC の判断は後で、`ASYNC = 0` で RTL はどちらにもなる。KC705 では 2 つの領域が面積と仕事の量で有利。
8. **class a と f で別の latency（a は短く 2〜3、f は長く 10〜12）**: 整数の依存の列が速いが、書き戻しの bus で a と f の結果が同じ cycle に重なる（2 本の書き込み port か予約が要る）、WAW の規則が増える。v1 は 1 本の固定長（§3.1.1）。p032 の論点 2。
9. **FPU を pipeline にせず DSP を複数 cycle で使い回す**: ユーザーの決定（2026-10-25 12:51「SUはパイプラインにしましょう。ということは、FPUもパイプライン化がひつようですね。」）で取らない。

### 19.13 U 項目（ユーザーの判断。推し付き）

**判断（2026-10-25 23:46 ユーザー）**:「U100-U109ですが、推しで良さそうです。ただ周波数は、いったんp034, p037がマージ後に、合成結果のFmaxを見て、目標を設定しましょう。」→ U100〜U109 は推しで承認。U100・U101 の周波数の数値だけは保留し、p037 の merge の後の合成の Fmax を見て決める（構成の SU を sclk に分けることは承認）。

**判断（2026-10-26 02:10 ユーザー）**:「それで行きましょう」→ KC705 の目標は gclk 100 MHz、sclk 150 MHz（200 MHz は stretch）。U101 は推しのまま。

| # | 問い | 推し | 理由・影響 |
| --- | --- | --- | --- |
| **U100** | KC705 の目標の Fmax | **K2: sclk（SU）200 MHz、gclk（他）100 MHz**。p025 の 1 段目はこの値で、met しない経路は p032 へ。gclk の 120〜150 MHz は面積が減った後の伸ばし代、sclk の予備は 171・150 MHz（MMCM の VCO 1200 MHz、§19.4.1） | §19.3.2。K1（全部 100）・K3（全部 200）・K4（125〜150 / 250）は理由とともに表に |
| **U101** | ASIC の目標の扱い | **1.0 GHz を基準、1.5 GHz を伸ばし代**。KC705 の 200 MHz の構造の SU は ASIC の約 1.1〜1.75 GHz（推定）、100 MHz の構造の block は ASIC で sclk の半分の clock か後の WS で深く。amaterrace-gpu の README の「800 MHz is the goal on ASIC processes」を 1.0〜1.5 GHz（3 nm、mobile）に直すかはユーザー（README はユーザーの file） | §19.3.3。ASIC の library の数字は無い（推定の幅は約 2 倍） |
| **U102** | clock の領域の分け方 | **sclk = 全部の SU だけ**。TU・RX・VF・ROP・BLT・CP（CPU を含む）・MC・DC の memory の側は gclk。mclk・uclk・pclk・tck・ref_clk は今のまま | §19.4.1。別案: SU + TU の cluster（§19.12 の 4） |
| **U103** | 境の形 | **全部の境を `am_afifo` の上の `am_cdc_*` の channel（ASYNC parameter で同期の形にもなる）**、XDC は gray の pointer に max_delay と bus_skew（clock group だけにしない） | §19.4.2・§19.4.4。2:1 の同期は §19.12 の 2 |
| **U104** | SU の短い命令の latency | **class a と f の 1 本の固定長の pipeline を保ち、`SHORT_LAT` を約 11〜12 に**（整数の ALU の結果も同じ長さ）。ISA は変えない、`docs/gsi1.md` の latency の記述は「実装が決める」に | §19.5.2 の表: 200 MHz なら k ≥ 1 のどこでも今より遅くならない（推定）。別案は §19.12 の 8 |
| **U105** | 板の top の `SU_PK_SHARED` と、板の全体の合成 | **板に `SU_PK_SHARED = 1` を渡す**（2026-10-25 12:41「後者で合成してみましょう」を板にも）。p037 の後に板の全体を **合成だけ**（P&R はしない）して module ごとの LUT を取る | §19.6。今の板の top は既定 0（fp16 を 2 つ同時）のまま |
| **U106** | 面積の目標と減らす手の選び方（**T2・T3 の前提**） | **K2 の目安は板の LUT ≤ 85%**。T0 の測定の後、**T2 に入る前に**判断する。今の見込みでは U80・U81・RX の pb を全部とっても −7〜10k で、残り約 33〜43k は U84（fp32 の lane を半分）・NPHYS 4・p032 の算法の論点（TU・ROP・BLT の統合）に頼る。推し: (1) T0 で測る、(2) 入らなければ U84 を先に（fp32 の throughput は半分だが、SU の 200 MHz で今の 100 MHz 相当を保つ）、次に p032 の算法の論点、(3) それでも入らなければ目安を緩め（gclk 100 / sclk 150、LUT ≤ 90%）、OOC の値は「構造の確認」とする。U80・U81・U83・U84 は p036 のまま未決 | 測る前に機能を外さない。今の見込みでは K2 の目安に入らない（review H6）。U81 の効果は測り直すと小さい見込み（約 2〜4k） |
| **U107** | GHCI の clock の報告 | **GHCI は変えない**（`GCLK_HZ` = gclk、PERF・watchdog は gclk）。sclk の Hz は vendor の register に debug 用 | §19.11 |
| **U109** | sclk の領域（CDC、T1）を p025 から別の Phase に分けるか | **分ける**（Q1 が番号を付ける）。受け入れ: scene の TB の word 一致・比の違う clock・乱数の同期・`report_cdc`。p025 は T0・T2・T3・T5（timing の 1 段目、met しなくても cleared） | T1 は機能の正しさの変更（CP の reset の握手、VF・RX の back-pressure、PT の copy の場所）で、「met しなくても cleared」と性質が違う（review L7） |
| **U108** | pipeline の止め方 | **止まらない固定の latency の段 + 出口の skid の FIFO と credit**、datapath の FF に reset と CE を付けない、unit から bus への `unit_ready` は issue の段の予定に置き換える | §19.5.1 の 3・7。p038 の `atg_tu_filter` で確かめた形 |

### 19.14 license と転記

- amaterrace-gpu・zedBSD とも zlib（`SPDX-License-Identifier: Zlib`）。この節は amaterrace-gpu の RTL（e64da02）を読んで設計を書いただけで、code は写していない（module・port・parameter の名前は事実として引いた）。
- Xilinx の DS182・UG472 の値は部品の事実として引く（この節の値は一般知識の幅で、版を読み直していない。実装の段で使う値は文書の版を書いて引き直す）。Kuon & Rose（IEEE TCAD 2007）は結論の数字だけを一般知識として引いた（文は写していない）。foundry の速さの伸びは公開の発表の一般知識の積み重ね（版・出典の文は写していない）。
- 新しい RTL（実装の段）は amaterrace-gpu の規則（`docs/style.md`、p037 の算術の規則）で書く。Xilinx の IP の生成物は repository に入れない（§4.1、今のまま）。

### 19.15 review の指摘と対応（design-reviewer、2026-10-25、24 件: High 6・Medium 11・Low 7、Critical 0）

全部を受けた（H1・H2・H5 は P2 が RTL の行を確かめた: `atg_top.v` 474・890 の draw_kick、`atg_su_sb.v` 291 の fault の pulse、`atg_rx.v` 82〜85 と `atg_rx_frag.v` 188〜197 の PT の 2 つの読み手、`atg_rx_fdiv.v` の 27 cycle）。

| # | 重さ | 指摘（要点） | 対応 |
| --- | --- | --- | --- |
| H1 | High | DRAW の warp は SU を通らず VF へ直に kick され、ch.3・4 の要求が ch.1 の STATE・inv を追い越す | §19.4.2 の 1: DRAW・DRAW_RAW は ch.1 の適用の数を待つ。別案を併記。TB を §19.9 に |
| H2 | High | SU の fault は 1 cycle の pulse、fault_addr は組み合わせ | §19.4.2 の 2: sclk の側で sticky に latch、event で渡す |
| H3 | High | 「受け取った数 + busy の同期」でも偽の idle（別の同期の解け方、ch.3・4 の漏れ、PROT の drain_ok） | §19.4.2 の 2・§19.7: 1 つの status の word（終えた数 + busy_x）を握手で丸ごと、ch.1・3・4 を数える |
| H4 | High | level の req と pulse の gnt を同期すると二重に許可、ch.3 と ch.6 の方式が食い違う | §19.4.2 の 3・4・6: 要求 1 件 = FIFO の entry、許可 1 件 = event、1 つの方式に |
| H5 | High | PT の読み手は clip と rx_frag の 2 つ、frag の copy は 1 cycle の環 | §19.4.2 の 5: copy を SU の中の command に、clip だけ要求・応答の FIFO |
| H6 | High | 推しの K2 も今の見込みでは面積に入らない | §19.1-6・U106: 面積の判断は T2・T3 の前提、T0 の後に判断、受け入れの文に「単体の OOC は板の証明でない」 |
| M1 | Medium | axi_idle に境の FIFO を入れると HALT で止まる | §19.7: leaf の待ち行列と同じ扱い（axi_idle に入れず reset で捨てる） |
| M2 | Medium | session の tag は leaf で付く、境に前の session の要求が残る | §19.7: drain_ok に境の FIFO の空と SU の未完の無いことを、I$ の先読みは T1 で確かめる（未確認） |
| M3 | Medium | reset の握手の対象の抜け、reset されない側が書くと捨てられる | §19.7: 対象を列挙、am_rst_cdc が reset されない側を止める |
| M4 | Medium | credit = 深さは書き側の遅れを考えていない、深さ 2 は作れない | §19.4.2 の 11: credit = 深さ − 3、深さ 4 か 8 |
| M5 | Medium | 深さ 4 では 1 cycle に 1 つを出せない | ch.7〜9 を深さ 16（LUT は同じ） |
| M6 | Medium | export が warp ごとに直列 | §19.4.2 の 10、§19.5.4 の 8 |
| M7 | Medium | ASIC の FMA を 4〜5 段に戻せる、は方法 1 と矛盾 | §19.3.3: 方法 2 が当たる場合だけ、と直した |
| M8 | Medium | unit_ready は 13 本の unit から | §19.5.1-7: 予定の物は issue の段の予定、長い unit は credit |
| M9 | Medium | am_sync の 1 段目の制約が無い、既存の境の直しは範囲の外 | §19.4.4: d → s1 の datapath_only、report_cdc を受け入れに、既存の境は範囲の外と明記 |
| M10 | Medium | CDC の競合を sim で出せない | §19.9: 乱数の同期の model、足す TB、report_cdc・report_methodology |
| M11 | Medium | LUT の指標が合っていない | §19.6: 未確認と明記、T0 で指標を揃える |
| L1 | Low | 依存の間隔は SHORT_LAT + 2 | §19.5.2 の表を直した（SHORT_LAT 12・k 3 で 86%）、§19.1-4 も |
| L2 | Low | SHORT_LAT の二重の数え | §19.5.1-1・§19.5.2: (1) は SHORT_LAT に、OPD_LAT は別、約 10〜12 |
| L3 | Low | NSH の増加と issue の道 | §19.5.2: 棚卸しに入れ、hazard の判定の register 化を候補に |
| L4 | Low | CLKOUT1 は整数の分周、VCO 1000 MHz で 150 MHz は作れない | §19.4.1: VCO 1200 MHz |
| L5 | Low | fdiv は 27 cycle の逐次、am_afifo の比較は組み合わせ、SU 以外は約 107k、gsi1-schedule は register に入らない program だけ | 4 つとも直した |
| L6 | Low | LW の見出し、T1 の前で止めた時の性能、T0 の U105 への依存 | §19.10 を直した |
| L7 | Low | T1 は機能の変更で別の Phase に、§19.12-2 の制約の記述 | U109 を足した、§19.12-2 を直した |
