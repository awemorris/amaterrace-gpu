# GHCI の ghci.md（amaterrace-gpu 8035b4a）の driver から見た疑問（2026-10-27 P1）

- 対象: `git -C /home/awe/amaterrace-gpu show 8035b4a:docs/ghci.md`（2358 行、Version 1.0、2026-10-27）。正本は ghci.md だけ。header（`include/ghci_cmd.h`・`ghci_regs.h`）は食い違いを確かめるためだけに grep した。RTL・driver_qa は読んでいない。
- 視点: zedBSD の kernel の driver（Vulkan の executor が PSO・descriptor・`CMD_*` を組む、表示は DISP2）。試験は host の model。
- 確かめた原則: 「MMU の内部（段・PTE・walker・TLB）は driver から不可視、driver は session・VM_MAP/UNMAP・BUFFER_GRANT の保護だけを扱う」は §11.2 の冒頭（IMPORTANT の囲み、1171〜1174 行）に書かれている。ただし CTRL.TLB_FLUSH（§3.3）が残る（M12）。版は §16 で 1.0 だけと書かれているが、§7.5 に「GHCI 1.1」が残る（M08）。

## 要約

- 疑問 58 件: **C 17・H 17・M 19・L 5**。
- C（その部分の driver が書けない）の中心は 4 つ: (1) §7 の opcode 表と payload が未定義・自己矛盾（M37〜M39・M41・M43・M44・M54）、(2) 番地の空間（packet の番地・HOST_LIMIT・session の VA・scanout）の定義が二通り（M16・M29・M55）、(3) fault と session の回復が三通り（M20・M21）、(4) §7.5・§11.6 が廃止済みの旧 model（gpu-op・aperture・job tag）のまま（M08・M27・M32）。加えて CAPS・CAPS2 の register の場所が無い（M01）、fence の幅が 32/64 bit で食い違う（M15）、二次 command buffer の権限が無い（M31）。
- header は opcode（0x26 SET_DYNAMIC_STATE、0x2D LOAD_CONST）と size（SET_VIEWPORT 7・SET_SCISSOR 5）が一貫している。ghci.md の §7.2 の表のほうが壊れている。ただし header の legacy の定義（`GHCI_CAPS2 0x024`＝RING_BASE_LO、`GHCI_WDT_CYCLES 0x044`、`GHCI_APERTURE_BASE 0x060`＝TIMESTAMP_HI）は ghci.md の §3.1 の map と衝突する。

## GHCI の担当へ送る疑問

重さ: C＝その部分の driver が書けない、H＝その部分を書く前に答えが要る、M＝仮の扱いで進められるが答えが要る、L＝文書の整理。

| ID | 重さ | 疑問 | 根拠（ghci.md） |
| --- | --- | --- | --- |
| **識別・capability** | | | |
| M01 | C | `CAPS`・`CAPS2`・`ISA_ID` は MMIO のどの offset か。§3.1 の map に無いのに、CAPS[17]・[19]・[24]〜[30]、CAPS2[15:8]〜[31:28] が判定に使われている。DEVICE_CAPS と重なる bit（CAP_FP16[6] と CAPS[28]、CAP_MSAA[31] と CAPS[29]）はどちらを見るか。 | §3.1・§11.5.1・§12.1・§12.5・§12.9〜12.12・§16・App. A step 2 |
| M02 | H | GHCI_MAGIC は `"GHCI"`（0x47484349）と `"GHC1"`（0x47484331）のどちらか。両方を受けるのか。 | §3.1 0x000、§14、§15.1 |
| M03 | H | EXT_CAP_FEATURE の VA_BITS[3:0]・PA_BITS[7:4] は 4 bit で、値 32〜40・40〜48 を入れられない。符号化は何か（例: 値−32）。 | §3.2.2 |
| M04 | M | UMA の判定は DEVICE_CAPS.CAP_UMA[0] と MEM の LOCAL_SIZE（「MEM が無ければ unified」）のどちらが正か。食い違う時は。CAP_DUAL_SOURCE も DEVICE_CAPS[5] と EXT_CAP_FEATURE[8] の二か所にある。 | §3.2.1・§3.2.2・§11.3 |
| M05 | M | 色の attachment の最大数の出所が三つ: EXT_CAP_FEATURE.MAX_MRT（1〜8）、FMT_LIMITS[3:0]、§12.12 の export（k＝0〜3）。maxColorAttachments は何か。 | §3.2.2・§4.1 FMT・§8.6・§12.12 |
| M06 | M | EXTCAP の list の entry は 0x100〜0x10F と 0x180〜0x1BF にあると言うが、VEND の register も 0x180〜0x19F で重なる。driver は list を辿るのか、§4.1 の固定 offset を使ってよいか。ID 5（MMU）・6（CPFW）は list に出るか、出たら driver は何をするか。 | §4・§4.1 |
| M07 | M | FMT: FILTER_LINEAR を「bit 1」と書くが Vulkan では bit 12（bit 1 は STORAGE_IMAGE）。EXT_CAP_FMT0（0x080）の bit の割当、表の Guard の `CAP_BC` の bit が未定義。§8.5.1 の表と FMT の register が食い違う時、どちらが正か。 | §4.1 FMT・§3.1 0x080・§8.5.1 |
| M08 | C | §7.5（class 2 の gpu-op、firmware、`INIT` を「GHCI 1.1 Mandatory」）は 1.0 の driver に要るのか。要るなら gpu-op（0x10100〜）を ring にどう載せるか（header の opcode は 8 bit、header に `GHCI_GPU_OP_VM_MAP 0x10110` がある）、CP の firmware の load の手順、INIT の word 9（期待の commit hash）を driver はどこから知るか。§16 は 1.1 は無いと言う。 | §7.5・§12.10・§16 |
| **register と初期化** | | | |
| M09 | M | SCRATCH は 0x044（§3.1）か 0x048（§14、ここは WDT_CYCLES）か。 | §3.1・§14 |
| M10 | H | 「IDLE/RUNNING/HALTING/HALTED」の lifecycle の状態を driver はどの register で知るか。CP_STATE=0（IDLE）は「doorbell 待ち」でもあり、RUN=1 で ring が空の時と RUN=0 の時を区別できない。RING_BASE・CP_HEAP の書き込みの可否、DISP2 の S の register の可否がこの状態で決まる。 | §3.3・§5.1・§5.2・§13.2「Who writes」 |
| M11 | M | CTRL.RESET の後に CTRL.WDT_EN・IRQ_GLOBAL、WDT_CYCLES、CP_HEAP_BASE/LIMIT は残るか（§5.2 の保持・消去の一覧に無い）。IRQ_GLOBAL[6] は §9.2 の式（OR(IRQ_STATUS & IRQ_ENABLE)）に入らない: 線の条件に入るのか。HALT=0 で RUNNING と IDLE のどちらに戻るか。 | §3.3・§5.2・§9.2 |
| M12 | M | CTRL[4] TLB_FLUSH は「driver は TLB を操作しない」の原則と食い違う。driver は使わないでよいか（廃止か）。 | §3.3・§11.2 冒頭 |
| M13 | L | 「19 本、0x000〜0x048、76 byte」と書くが §3.1 の表は 0x084 まで約 29 本。App. A の PIPE_FSM（0x07C）は map に無い。64 bit の一度の access は 0x024（RING_BASE_LO）・0x01C（FAULT_ADDR_LO）が 8 byte 境界に無いので成り立たない。TIMESTAMP_LO/HI の読む順（LO で HI を latch するか）。 | §1.2・§2・§3・§3.1・App. A |
| M14 | M | WDT_CYCLES の reset の値と単位。「一つの command」とは packet か draw か。WAIT_FENCE や FLIP の待ち（pending の flip の take 待ち）も数えるか。WDT_EN=0 の時の quiesce の上限（4×WDT_CYCLES）は何か。 | §3.1・§10 Watchdog・Quiesce |
| **ring・doorbell・fence・IRQ** | | | |
| M15 | C | fence の値は 32 bit（§9.1、int32 の比較、2^31 の前に畳む）か 64 bit（§7.3 CMD_FENCE・WAIT_FENCE、int64 の比較）か。 | §7.3 0x33・0x34、§9.1 |
| M16 | C | packet の番地はどの空間か: fence_addr（「host PCIe DMA or local DRAM address」）、WAIT_FENCE（「host/GPU address」）、WRITE_TIMESTAMP（「GPU VA or host memory」、どう区別するか）、EXECUTE_COMMANDS の secondary_ring_va、PSO・descriptor の VA。VA なら、どの session の変換か（BIND_SESSION の今の値、session 0）。 | §6.1・§7.3・§9.1 |
| M17 | M | §6.2 の framing の誤り「GHCI_FAULT_BAD_HEADER, kind 2」は表では kind 2＝KICK_ABSENT、kind 3＝BAD_REG。KICK は廃止: kind 2 は今何か（capability の無い unit への command か）。 | §3.5・§6.2 |
| M18 | M | CMD_FENCE の flags[1]「writeback cache before IRQ」: §9.1 は fence を常に complete とする。flags[1]=0 の意味は。fence の memory は host だけ（§9.1）か local も可（§7.3）か。 | §7.3 0x33・§9.1 |
| M19 | M | IRQ_DISP[3]（summary）と bit 9〜12 の関係: 同時に立つか、[3] は何で clear するか。IRQ_RESULT[7]・IRQ_RETIRE[8] を立てる command は何か（RETIRE は全 packet か）。debug port が廃止なら IRQ_DBG_DONE[4] は残るか。 | §3.4・§13.2 Events・§14 |
| **fault・watchdog・reset** | | | |
| M20 | C | session の fault の扱いが三通り: §3.3（K03）と §10 Recovery は「その session だけ止め、FAULTED は立てず走り続ける」、§10 の Faults の行は「FAULTED を立て、CP は FAULTED へ」、§11.6 Violations は「version 1 の回復は device 全体、一つの session の越境が全 session を止める」。どれが正か。 | §3.3・§10・§11.6 |
| M21 | C | session の fault の後: ring に残るその session の packet（BIND_SESSION の後の draw）は捨てられるか実行されるか。後ろの CMD_FENCE（CP が実行）は書かれるか。driver はどの fence が来ないかをどう知るか。FAULT_INFO は「最初の fault」だけを latch する: 他の session の fault が続いたら失われるか。W1C はどの bit に何を書くか。 | §3.3・§3.5・§10 |
| M22 | H | session の番号と数: FAULT_INFO[15:8]（0..15）、§3.3 は i∈[1,15]、§1.4 は 31 sessions、§11.6 は FAULT_INFO[31:24] の job tag と FAULT_INFO[9]（UNIT の field の中）。SESSION_ACTIVE（0x058）の bit の割当が未定義。 | §1.4・§3.1・§3.5・§11.6 |
| M23 | H | fault の kind の食い違い: ISA の fault を kind 8（表では MMU_OOM）、保護の違反を「kind 1 ＋ FAULT_INFO[9]」（表では kind 6 PROT_FAULT）、EXECUTE_COMMANDS の入れ子を `GHCI_FAULT_BAD_PROGRAM`（表に無い）。ISA の fault の FAULT_ADDR＝PC はどの空間の値か。 | §3.5・§7.3 0x32・§11.6・§12.6 |
| M24 | H | MMU_OOM の回復: 「CP_HEAP_LIMIT を広げて再試行」とあるが、CP_HEAP は IDLE でしか書けない（§5.2）。止まる「呼んだ session」は VM_MAP の対象の session か、VM_MAP を出した側（driver＝session 0）か。 | §5.2・§10・§11.2 |
| M25 | H | reset と session: K08（§5.2・§10）は page table などの host の RAM が残ると言い、§11.6 は「reset で全 session を失う、driver が開き直す」。reset の後に driver がやり直す事（SESSION_OPEN、全 VM_MAP、CP_HEAP の中身の再利用か 0 にするか）は何か。 | §5.2・§10・§11.6 |
| M26 | L | App. A の「ring を作り直す」と §5.2 の「ring の pointer を 0 にするだけ」。HALT が「今の packet の後」なら、今の packet が WAIT_FENCE や FLIP の take 待ちの時に HALTED に入れるか（panic console）。 | §5.2・§13.2・App. A |
| **session と VM_MAP** | | | |
| M27 | C | session と VM の packet: SESSION_OPEN/CLOSE（0x12/0x13）が §7.2 の表に無い。SESSION_OPEN は 4 dw だが引数は 2 語。VM_MAP の「6 dw」の形は未定義。ring の packet には返事が無い: §11.6 の VkResult（FEATURE_NOT_PRESENT・OUT_OF_DEVICE_MEMORY・INITIALIZATION_FAILED）を driver はどこで受け取るか。 | §7.2・§11.2 の表・§11.6 |
| M28 | H | VM_MAP/UNMAP の規則: gpu_va・iova・size の align（4 KiB か）と上限、既に map 済みの範囲への map、部分の unmap、未 map の unmap。flags の COHERENT・WC は §11.4（GPU は coherence を外さない）とどう両立するか。CAP_HW_WALKER=0 の GPU（VM_MAP が無い）では番地は何か（VA＝物理か）。CAP_PROT=0 の「flat physical mode」と walker の関係。 | §3.2.1・§7.2・§11.2・§11.4 |
| M29 | C | 番地の model が二つ: §11.2 は session ごとの VA（VM_MAP）、§11.3 の HOST_LIMIT・LOCAL_BASE と §11.6（「driver は一つの flat な GPU の番地を持つ」）と §12.8（「aperture の中の 32 bit の番地」）は flat。HOST_LIMIT・LOCAL_BASE は VA か物理か。VM_FLAG_LOCAL の iova_or_phys は LOCAL_BASE からの offset か絶対の番地か。 | §11.2・§11.3・§11.6・§12.8 |
| M30 | H | session 0（driver の物）の番地の空間: identity か、VM_MAP が要るか。BIND_SESSION の前（reset の直後）の packet はどの session で走るか。 | §7.2 0x14・§11.2・§11.6 |
| M31 | C | ring を書くのは誰か: §6.0 は「UMD か KMD が共有の ring に記録」。user が書く二次 command buffer（EXECUTE_COMMANDS）の中で禁止の packet（BIND_SESSION・VM_MAP/UNMAP・SESSION_*・DISP_SET・FLIP・FENCE・WAIT_FENCE）は何か、二次はどの session で走るか。無ければ kernel が user の command を受けられない。 | §6.0・§7.3 0x32・§11.6「The driver does not put an address…」 |
| M32 | C | §11.6（保護）は旧 model のまま: BUFFER_GRANT/REVOKE・MEMORY・FREE_MEMORY は gpu-op、PROT_TABLE の手順は APERTURE_BASE/LIMIT（廃止）と HEAP に依る。1.0 の ring でどの opcode か。session ごとの VA（VM_MAP）があるのに grant は要るか（同じ物理を二つの session に VM_MAP するのが共有か）。 | §3・§11.2・§11.6 |
| M33 | M | CP_HEAP: 32 bit の「GPU physical address」は local か host か（discrete で host の 4 GiB より上は不可か）。session・map あたりの必要量の目安、align、0 で埋める必要。 | §3.1・§11.2 Firmware Heap |
| M34 | L | VM_UNMAP の完了: §11.2 は「TLB の無効化の後で RPTR が進む」、§6.4 は「RPTR は引数を写した時に進み、参照する memory は fence で守る」。page を再利用してよいのは fence の後でよいか。 | §6.4・§11.2 |
| **resource と memory（host と local）** | | | |
| M35 | H | image の memory の配置: texture descriptor の flags[0] Tiled の tile の形、mip level 1 以降の位置（descriptor は level 0 の base と pitch だけ）、D24S8・D32S8 の stencil の置き場、FB_STRIDE や scratch の「memory line」の byte 数（1.0 の register に無い）。 | §8.3・§8.5.2・§12.10・§13.2 |
| M36 | H | 転送の command: buffer↔image の copy（vkCmdCopyBufferToImage/ImageToBuffer）、image の clear、update buffer に当たる command が無い。COPY_IMAGE・BLIT・RESOLVE_IMAGE の payload、COPY_BUFFER の flags と align が未定義。CAP_BLT=0 の discrete の GPU は upload をどうするか。 | §7.2 0x40〜0x44・§7.3・§11.3 |
| **PSO・descriptor・CMD_\*** | | | |
| M37 | C | §7.2 の opcode 表が自己矛盾: 0x21〜0x26・0x2A・0x30・0x31・0x37 が二つの名前、0x43・0x44 が二行、size が §7.3 と違う（SET_VIEWPORT 5 と 7、SET_SCISSOR 3 と 5）、0x26 は表で BIND_INDEX_BUFFER・§7.3 で SET_DYNAMIC_STATE、LOAD_CONST の opcode が無い。header（0x26 SET_DYNAMIC_STATE、0x2D LOAD_CONST、VIEWPORT 7・SCISSOR 5）が正か。 | §7.2・§7.3・§8.4 |
| M38 | C | payload の未定義: DRAW_MESH_TASKS、BEGIN_QUERY/END_QUERY（表は 3 と 2 or 5、header は両方 3）と query の結果の形、WAIT_IDLE（opcode が定まらない）、LOAD_CONST、単一の BIND_VERTEX_BUFFER（5 dw）。 | §7.2・§7.3・§8.4 |
| M39 | C | `GhciRenderPassDesc`（64 byte）の中身（attachment の VA・format・pitch、load/store op、clear の値、resolve の先、depth/stencil）が無い。clear_flags の bit の割当も。 | §7.3 0x2B |
| M40 | H | DRAW_INDIRECT の 8 dw の形には flags の dword が無い: indexed か否か、count buffer の形であることはどう示すか（header の flags か）。buffer・count の align。 | §7.3 0x29 |
| M41 | C | PSO の field の符号化（topology・cull・polygon mode・compare op・blend factor・blend op・write mask の値）が無い。PSO に無い state: stencil の fail/pass/depthFail op と front/back の別、attachment ごとの blend と write mask、logic op の種類、MSAA（sample 数・sample mask・alpha to coverage、MS_CTRL は廃止の SET_REG で書く）、VARYING_COUNT、line width・point size、task と mesh で共有の ms_code_va。どこで指定するか。 | §8.2・§12.10・§12.11 |
| M42 | H | vertex の stride: PSO の vertex_strides は 8 bit × 4 binding だけ、limit の表は「12 bit、4095」と 16 binding、BIND_VERTEX_BUFFERS は binding ごとに 32 bit の stride を持つ。どれが効くか。 | §7.3 0x21・§8.2・§8.6 |
| M43 | C | PSO の vs/fs/cs_code_va は GSI1 の program の header（16 語＋interface table）を指すのか、code を指すのか。§12.10 の PROGRAM gpu-op は 1.0 で要るか。program の検査の失敗（INITIALIZATION_FAILED）はどこで知るか。CP が確保する scratch はどの memory から取るか。 | §8.2・§12.10 |
| M44 | C | resource の bind の model が二つ: §8.4 は shader 命令が descriptor table を直に引く（`tex ld`・`gsi1_load`・`SAMPLE r0, r1, r2, s0` は GSI1 に無い）、§12.10 は interface table で CP が slot と bank を埋める。どちらか。§8.4 の table は型の混在の時の descriptor_size_bytes、combined sampler の index の組はどの table を指すか、binding ごとの配列（descriptorCount>1）、dynamic offset。 | §8.4・§12.5・§12.10 |
| M45 | H | push constant と constant bank: LOAD_CONST の payload、bank の大きさ（§8.4 は c[0..511]、GSI1 の operand は c0〜c31、header は CAPS2 から）、LOAD_CONST と CP が interface table から書く bank の語の順と重なり。 | §8.4・§8.6・§12.3・§12.10 |
| M46 | H | bind point: BIND_PIPELINE は graphics と compute で一つか。compute の PSO を bind すると graphics の PSO・descriptor table は消えるか（Vulkan は bind point ごとに別）。 | §7.3 0x20・0x23・0x30 |
| M47 | M | descriptor の field: texture・buffer の format は VkFormat の値か（sRGB の flag は重複）、sampler の compare_op の値、border color は RGBA8 だけ（Vulkan の int・float の border）、filter と mipmap の値の範囲。 | §8.3 |
| M48 | H | cache の無効化: §11.5 は DRAW・LOAD_PROGRAM・INVALIDATE（1.0 に無い）で無効化と言う。1.0 で host が同じ VA の code・PSO・descriptor を書き換えた時、何が I cache・texture・data cache・PSO の cache を無効にするか（BARRIER の INVAL_L1 だけか）。CP は PSO を VA で cache するか。 | §7.3 0x31・§8.1・§11.5 |
| M49 | M | CAP_INDIRECT_DRAW は indirect dispatch も含むと言うが、indirect dispatch の command が無い。 | §3.2.1・§7.2 |
| **Vulkan の limit・format・feature** | | | |
| M50 | M | limit の食い違いと欠け: program の workgroup size は 8 bit × 3（最大 255）だが maxComputeWorkGroupSize は {256,256,64}。maxComputeSharedMemorySize 16384 と KC705 の 4096（Vulkan の最小は 16384）: 実際の値をどこで読むか。timestampPeriod は固定 10 ns か GCLK_HZ からか。表に無い limit（maxViewports、maxFramebufferWidth/Height/Layers、各 sampleCounts、minUniform/StorageBufferOffsetAlignment、bufferImageGranularity、nonCoherentAtomSize、maxDrawIndirectCount、maxFragmentOutputAttachments、point size・line width の範囲）の値。 | §8.6・§12.10 word 8・§3.2.3 |
| M51 | M | §8.5.1 は Vulkan 1.0 の必須を満たすと言うが、必須の format（A2B10G10R10_UNORM_PACK32、B10G11R11_UFLOAT_PACK32、A8B8G8R8_*_PACK32、R16 の UNORM/UINT/SINT 系、R32G32_UINT/SINT、vertex 用の R32G32B32_SFLOAT など）が表に無い。sRGB の attachment は Path 1 が要るが Path 1 の capability が無い。 | §8.5.1・§12.12 |
| M52 | M | MSAA の sample 数: CAP_MSAA は 2x/4x、§12.11 は 1 か 4、descriptor は 1・2・4。2x はあるか。判定は DEVICE_CAPS[31] と CAPS[29] のどちらか。 | §3.2.1・§8.3・§8.5.2・§12.11 |
| M53 | M | shader の global memory は 32 bit の番地（lw/sw）: VA_BITS=40 の GPU で 4 GiB より上の buffer に shader は届くか。 | §3.2.2・§11.2・§12.8 |
| **表示（DISP2）** | | | |
| M54 | C | DISP_SET（2+2×N）と FLIP（4 dw）の payload が無い（§13.2 は §7.3 を指すが、§7.3 に無い）: DISP_SET の register の指し方と flags[0]（idle を待つ）、FLIP の plane・image の番地・値（31 bit）・record の番地、FLIP の待ち。 | §7.2 0x50・0x51・§13.2 |
| M55 | H | scanout の番地（FB_BASE・FB_NEXT・CURSOR_BASE、32 bit）はどの空間か（物理・bus か session の VA か）。UMA で host の 4 GiB より上の image は出せないか。 | §11.6「Not checked: … scanout」・§13.2 |
| M56 | M | DISP2 の S の register の書き手の規則は M10 の lifecycle の状態に依る。DISP2 は「Draft」、§1.4 は display を Approved と言う: どちらか。mode は MODE の表だけか（sink の EDID を読む経路は無いか、I2C は外部の transmitter 用）。 | §1.4・§13.2 |
| M57 | L | boot の framebuffer の引き継ぎ（§13.3）は local memory と local window が前提: UMA（MEM が無い）の時の手順。 | §11.1・§13.3 |
| **全体** | | | |
| M58 | L | 文書の整理: §1.4 の「Approved」と FMT・DISP2・§12.11・§12.12 の「draft」、§2 の 128 KiB と §15.1 の「64 KiB でも可」、§15.2 DMA の「aperture is set」（廃止）、CAP_IOMMU（platform の IOMMU が active かを GPU は知り得ない）、GCLK_HZ が 0x064 と VEND+0x10 の二か所、minor の版が 0 でない時の扱い。 | §1.4・§2・§3.2.1・§4.1・§15・§16 |

## 詳細

### 識別・capability（M01〜M08）

- M01: driver の feature の判定（subgroup、packed、TU_FULL、MS4、CORE1、firmware の有無、native ISA）と limit（LDS、tex slot、const words、attributes）は CAPS・CAPS2 に依るが、§3.1 の map に CAPS・CAPS2・ISA_ID が無い。header は `GHCI_CAPS2 0x024`（今は RING_BASE_LO）を残す。App. A の step 2 も CAPS・CAPS2 を読めと言う。
- M02: 二つの値を受けるなら、"GHC1" の時の違いがあるか。
- M03: 4 bit では 32/40 も 40/48 も表せない。今の driver は VA_BITS で 32 bit と 40 bit の VA の扱いを変える（packet の hi の語、shader の番地）ので必要。
- M04・M05: 判定の出所が重複していて、食い違った時の正が無い。
- M06: list の entry と VEND の register が 0x180 で重なると list を辿れない。
- M07: FMT の bit 1 を filter linear として読むと storage image を誤って報告する。
- M08: 1.0 は「構造化した ring の packet」だけのはずが、§7.5 は旧 firmware の gpu-op（INIT・HEAP・MEMORY・PROGRAM・FRAME・BUFFER_GRANT）を「Mandatory」と書き、§11.6・§12.10 がそれに依る。どれを driver が実装するかで driver の形が変わる。

### register と初期化（M09〜M14）

- M10: §5.2 の表の状態は driver の手順の前提（RING_BASE は IDLE で、DISP2 の S は IDLE・HALTED・FAULTED で host が書く）。STATUS の RUNNING[0]・HALTED[1]・FAULTED[2]・CP_STATE だけでは IDLE（RUN=0）と「RUN=1 で doorbell 待ち」を分けられない。CTRL.RUN を読み返して判定してよいか、も含む。
- M11: reset の後に IRQ が来ない・watchdog が外れる、を防ぐのに必要。
- M14: driver の timeout（自分の watchdog）を決めるのに要る。

### ring・fence・IRQ（M15〜M19）

- M15: fence の比較と folding の規則が幅で変わる。WAIT_FENCE（GPU 側の待ち）と driver の待ちが同じ幅でないと合わない。
- M16: zedBSD の driver は fence・timestamp を kernel の memory に置く。番地が session の VA なら kernel の memory を各 session に map するか、session 0 に切り替えるかが要る。
- M19: 割込みの handler が clear すべき bit を決めるのに要る。

### fault・watchdog・reset（M20〜M26）

- M20・M21: driver の fault の handler の形（device 全体の reset か、session だけ閉じるか）と、Vulkan の device lost を誰に返すかが決まらない。session の fault の後の fence の扱いが無いと、他の client の待ちが止まらない保証が無い。
- M22: session を driver の table に持つための数と番号の範囲。
- M25: reset の後の再構築の範囲が決まらない（host の RAM が残るなら VM_MAP をやり直す必要が無い、session を失うなら全部やり直す）。

### session と VM_MAP（M27〜M34）

- M27: 返事の無い packet で失敗をどう知るか（FAULT_INFO か、結果の record か）が無いと、SESSION_OPEN・VM_MAP の失敗を Vulkan に返せない。
- M29: 1.0 の §11.2 と、旧 model の §11.3・§11.6・§12.8 が同居している。driver が使う番地の空間が決まらないと resource の割当ができない。
- M31: zedBSD では kernel の driver が PSO・descriptor・`CMD_*` を組むので、ring は kernel だけが書く。それでも二次 command buffer を user の memory に置くなら、その中で禁止の packet の規則が要る。
- M32: §11.6 は APERTURE・job tag・MEMORY の ownership で書かれていて、1.0 の VM_MAP との関係が無い。

### resource と memory（host と local）（M35〜M36）

- M35: tiled の形が無いと、optimal tiling の image は linear で作るしかない（その時 FMT_OPTIMAL の意味が変わる）。mip の位置が無いと mip のある texture を作れない。
- M36: discrete の GPU では texture の upload に buffer→image の copy が要る。

### PSO・descriptor・CMD_\*（M37〜M49）

- M37・M38: header は一貫しているので、header を正とする答えなら M37 は文書の修正で済む。
- M41: PSO の 128 byte に Vulkan の graphics pipeline の state の多くが入っていない。入らない state を dynamic の command で送るのか、別の構造体か、が要る。
- M43・M44: shader と resource の繋ぎ方（interface table か、descriptor の直の index か）が二通りで、compiler と driver の両方の形が決まらない。
- M46: Vulkan の command buffer の中で draw と dispatch を交互に記録すると、bind の再送が要るかが決まる。

### Vulkan の limit・format・feature（M50〜M53）

- M50: KC705 の LDS 4096 byte は Vulkan 1.0 の最小（16384）を下回る。driver が compute を報告できるかが変わる。
- M51: FMT の register を正として報告すれば足りるなら、§8.5.1 の表は目安として扱う（M07 と同じ問い）。

### 表示（M54〜M57）

- M54: DISP_SET・FLIP の payload が無いので、DISP2 の mode の設定と present を書けない。
- M55: scanout は保護の検査の外（§11.6）なので、番地は kernel が決めて検査する必要がある。どの空間かが要る。
