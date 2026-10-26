<!-- awesome-plan project=amaterrace-gpu record=ws001-q1-decisions-20261025 -->

# WS001 の Q1 の自走中の判断（2026-10-25 夜〜、ユーザーが起きた時に報告する）

承認: 2026-10-25 05:49 ユーザー「ゴールまで推しで進んでよいです。判断に迷ったら、Vulkan 1.0の原則論で進めてください。あなたが自分で判断した内容はあとで起きたときに教えてください。修正が必要ならそのとき伝えるので、安心して推しで進めてください。テストはT1からT4まで４つ並列にしても負荷的には問題なさそうです。また、ソフトウェアのコーディングと違って、Verilogは確認のために関連ソースコードを読み取る必要性が低いのかもしれませんね、思ったよりトークンを消費していないです。N=3で、P3を立ててOKです。」

方針: 推しで進め、迷ったら Vulkan 1.0 の原則。Q1 が自分で決めた事をここに 1 行ずつ足す（新しい物を下に）。

| 時刻 | 判断 | 理由・根拠 |
| --- | --- | --- |
| 2026-10-25 05:49 | 担当の分け方: P3（新）= p030 の TU・BLT の系統（S9・S10・S12・S14）、P2 = p027 S6 の後に p010（compiler の backend、zedBSD の isa/gsi1）、P1 = p030 の RX・ROP・CP の系統（S3〜S8）。S13・S11 は 2 系統の後 | N=3 の許可。p010 は RTL と別の tree で並行できる。先にユーザーが決めた「p030 の TU・BLT を P2 に」は、P3 が増えたので P3 に移した |
| 2026-10-25 05:49 | 試験は T1〜T4 で並列（detached の worktree ごと） | ユーザーの許可 |
| 2026-10-25 05:35 頃 | T1-760 の Verilator の FAIL（atg_su の ex_ms が未接続）は途中の commit だけの物で、後の commit で直っているので対応しない | T1-761・T1-762 で verilator PASS |
| 2026-10-25 05:2x | S14 は案 A（STATE を 1024 index に、vertex の stage の 16 slot）。案 B（descriptor を memory の表）は後の拡張 | P1 の推し |
| 2026-10-25 05:1x | depth の 4 format に FILTER_LINEAR を立て、TU で compare 無しの depth の linear も入れる | Vulkan では FILTER_LINEAR の bit を立てると raw の depth の linear も許される |
| 2026-10-25 03:0x | cp_seq の待ちの不具合の直しを p027 に入れた（p030 から移した） | p027 が先に main に入るため |
| 2026-10-25 05:56 | p010（compiler）を P2 に並行で開始（p030 の RTL と別の tree）。compiler は GHCI の draft の仕様（p027・p030 の口）に合わせ、RTL の完成を待たない | N=3、ユーザーの順は p030 の後だが、並行できる物は先に進める（推しで進める許可） |
| 2026-10-25 06:22 | p027 を cleared にした（T1-764 の make sim が試験の担当の 30 分の上限で途中で止まり、残り 12 本を別に流して合計 86 PASS） | 全部の TB が PASS、MSAA の 14 case が model と一致 |
| 2026-10-25 06:30 | P3 の S9: TEX_FORMAT = 0 の時は今の動作のまま（depth の compare 無しは nearest）。driver は常に VkFormat を書くので、FILTER_LINEAR の bit との食い違いは起きない | 既存の試験の vector を変えないため。driver（p006・p019）は TEX_FORMAT を必ず書く規則にする |
| 2026-10-25 06:58 | P2 の p010 の判断を受け入れた: skip の block を分岐にしない（正しさ優先、速さは後）、noperspective・FragCoord.w は余分の varying、VertexIndex・InstanceIndex は interface kind 13 で firmware が届ける | 正しさ優先。分岐の最適化は後で |
| 2026-10-25 07:12 | p010 を cleared にした。vmunix への link は GHCI の driver の config が無いので p006 へ、texture の実行は p011 へ | 名指しの object の build は warning 0、host 試験 29/29 |
| 2026-10-25 07:12 | shared memory の atomic が GSI1 v1 に無い（Vulkan 1.0 core の必須）→ p030 に段 S15（ISA・RTL・compiler）を足した | Vulkan 1.0 の原則 |
| 2026-10-25 07:12 | P3 の S10: TILE・UNTILE は 16・32 bit を受ける（GHCI を「16 and 32」に）、KEEP は RESOLVE・TILE・blend では断る、fp の平均は ((s0+s1)+(s2+s3))×0.25 を fma で | 既存の試験と互換、Vulkan の resolve は平均の方法を実装に任せる |
| 2026-10-25 07:36 | P1 が rm を 1 回打ち security の判定で止められた（build/blend2.before、回避なし）。消すのは Q1 が代わりに行った（担当が頼んだ削除で、止められた操作の代行ではない） | AGENTS.md の rm の規則。担当の起動の指示に rm の禁止は書いてある |
| 2026-10-25 07:37 | S13（varying 64）を P1 に（S8 の後）。S11（統合）は S12〜S15 の後に別に | P1 の系統が空いた |
| 2026-10-25 07:50 | p006 を KC705 の PCIe（amd64）向けに書き直して P3 に（p018・p019 と並行）。ZYBO の branch の汎用の部分だけを取り込む。`GPU_OP_GHCI_NATIVE` の番号と `ghcictl` の名前は推しのまま | ZYBO は target から外した。並行できる物は先に（推しで進める許可） |
| 2026-10-25 08:00 | p006: 共有の build の file（Makefile・pci.drivers・amd64 の vmunix.mk・pcat.c）の既定 off の最小の追加を P3 に許した。DDR の窓は GHCI §15.2 の BAR2（design §6.2 を直した）。capset・COMMAND は executor（p019）ができるまで出さない | Vulkan 1.0 の原則（executor 無しに Vulkan の device を見せない） |
| 2026-10-25 08:10 | p018: KC705 の CP の CPU の memory を IMEM 64 KiB・DMEM 32 KiB に広げる（firmware の object model が入らない） | design §2.4.7 が IMEM 64 KiB まで許す。KC705 の BRAM に余裕がある |
| 2026-10-25 08:10 | p018: 新しい gpu-op GHCI_HEAP 0x10108、record の時の µop への翻訳、compiler の bank_first、共有の ghci_layout.h を受け入れた | Vulkan 1.0 では bind を変えると command buffer は無効になるので、record の時の翻訳は許される |
| 2026-10-25 08:10 | TU の奇数の幅の attachment の読み違いを p030 S16（row pitch の word）として足した | Vulkan 1.0 の原則（attachment を sample して正しく読める） |
| 2026-10-25 08:17 | compiler に spill を入れる（scratch は firmware が warp ごとに割り当てる global の memory、GHCI §12.10 の新しい interface の kind）。その前に純粋な命令を使用の近くへ沈める scheduling | Vulkan 1.0 の原則（正しい shader を拒まない）。LDS は warp ごとの base が無く使えない |
| 2026-10-25 08:32 | scratch の案（GHCI §12.10 の kind 14、§12.3 の warp の番号の定義）を承認し P2 に転送。fragment の helper・killed lane の値も spill できるよう、side mask の代わりに EXEC を使う scratch 用の lw・sw の modifier を ISA に足す（P1、RTL は atg_su_dec と lsu の最小の変更） | Vulkan 1.0 の原則（正しい fragment program を拒まない） |
| 2026-10-25 08:46 | p006 を cleared にした（実機・QEMU は p028）。DC の割り込みが PCIe の MSI に届くかは GHCI §13・§15.2 に書く（書くのは p019 か p028 の担当、driver は poll で両方に対応） | 受け入れの host 試験・build・規約を満たす |
| 2026-10-25 08:50 | T3 が試験の打ち切りの後に pkill を打ち、権限の判定で拒まれた（回避なし）。Q1 が残りの process が無いことを確かめ、対応は不要とした | 権限の判定の回避をしない規則のとおり。ユーザーに報告する |
| 2026-10-25 08:59 | p018: firmware は CAPS を読めないので、driver が GHCI_HEAP の 3 語目で resident の warp の数を渡す（P2 の判断を受け入れ） | atg_cpu の窓に HCR の読みが無い |
| 2026-10-25 08:59 | copy しない scanout（swapchain の image を DC の条件で確保し FB_NEXT で flip）を p019 の範囲に足した | ユーザーの問いへの答え、DC の hardware は対応済み |
| 2026-10-25 09:00 | GHCI に標準の HCR の register RESIDENT_WARPS（NSU×NWARPS）を足す（P2 が RTL と GHCI、P3 の driver が読んで GHCI_HEAP の 3 語目に渡す）。vendor の register の読みは使わない | 汎用の driver に vendor の code を入れない（GHCI の汎用の原則） |
| 2026-10-25 09:13 | S16 は「行の byte 数」でなく行の丸めの規則（TEX_ROW [1:0] = 切り上げの texel 数の log2）にする P1 の案を受け入れ、P2 の firmware に伝えた | level ごとに行の byte 数が違い、1 つの word では表せない（P1 の指摘） |
| 2026-10-25 09:43 | KC705 の core（1 SU）が yosys の数で LUT 245k と容量 203.8k を超える → p036（面積）を p024 の前に新設して P2 に。機能を変えない削減は P2、形を変える案（NPHYS・FPU の lane など）は U 項目でユーザーに | 最初のゴールに板が要る。Vivado の実測を先に |
| 2026-10-25 10:00 | p019 を cleared にし、P3 の決定（codec の再利用・timeline・中継・spec constant）を受け入れた | host 試験と build を満たす |
| 2026-10-25 10:00 | GHCI に lane あたりの register の数の標準の field を足す（次に RTL を触る担当に）。未知の pNext は読み飛ばす | GHCI の汎用の原則（vendor の code 無しで driver が読める）、libvulkan の振る舞い |
| 2026-10-25 10:07 | P3 の指摘で、GHCI §11.3 の MEM の capability（XCAP 8）を RTL に足す（atg_cp_regs の parameter、既定 0）。lane あたりの register の数を RESIDENT_WARPS の [23:16] に。両方 P3 が p011 の中で | discrete の KC705 を driver が正しく扱うのに要る、GHCI の汎用の原則 |
| 2026-10-25 10:18 | P3 の判断: KC705 の LOCAL_BASE を 0x8000_0000（MIG の 1 GiB の alias）にして 2 GiB 未満を PCIe の host の bus address に残す、を受け入れた | p029（host の memory だけ）と両立する |
| 2026-10-25 10:34 | p034 の U61〜U72（所有の表 + PLB + CAM、protected の session 31、hardware の scrub、root でない session を全部保護、GRANT は drain しない、STATE は消さない、PROT_CAPS[31:16] は grant の数、firmware の DMA の拒否は fault、内蔵の領域は public、ring の CP 側の µop は検査しない、CAM 64、robustBufferAccess の漏れの device 全体の fault を v1 は受け入れる）を全部推しで決めた | ユーザーの推しで進める許可。最初のゴールの道の外なので、実装は空いた担当に |
| 2026-10-25 10:58 | p011 の端から端の harness で見つかった driver の CPFW の RUN の書き忘れと、atg_cpu_win の packet の取り直しの不具合を、P3 の推しの形で直させた | 端から端の試験の目的どおりの発見 |
| 2026-10-25 11:01 | Vivado の実測で KC705 の 1 SU の core が LUT 422k（容量の 207%）。機能を変えない削減を P2 に続けさせ、形を変える削減（U80〜）はユーザーに諮る。最初のゴールの板（p024）の前の最大の課題として報告する | 推しで決めてよい範囲を超える（製品の形の判断） |
| 2026-10-25 11:20 | firmware の end render pass は常に WAIT_IDLE + INVALIDATE（P3 の判断を受け入れ） | Vulkan 1.0 の原則（過剰な同期は許される）、firmware は subpass dependency を持たない |
| 2026-10-25 11:32 | p011 を cleared にした（vkdemo の 1 frame が Verilator の上で oracle と一致）。vkQueueSubmit を待たずに返す firmware の直し（再生の前に結果を書く）を次の担当に | Vulkan の submit は仕事を待たない原則 |
| 2026-10-25 12:04 | P1 が見つけた「TU・CPU の DMA の MC の outstanding が busy に入っていない」を、保護に限らず CP の WAIT_IDLE の条件にも入れる直しにした | WAIT_IDLE・INVALIDATE の正しさ（Vulkan の barrier の意味） |
| 2026-10-25 12:21 | p036 の U80〜U84 は、ユーザーの前の決定（PACKED を持つ、FP32 は全 lane、NSU 4〜6）を覆すので推しで決めずユーザーに諮る。U85（GHCI §8.5 が既に求める整列に ROP を合わせる）だけは仕様どおりなので P2 の推しで進めてよいと判断 | 推しで進める許可は、ユーザーが明示した決定の見直しまでは含まないと解釈した |
| 2026-10-25 12:41 | p035 の U90〜U99 を推しで決めた（RUNNING の間の host の write は捨てて BAD_WRITE、class 0 の µop、ADV7511 と HPD は host の driver、cursor を実装、DC の読みは検査しない、driver の queue 深さ 2 と hardware の slot 1、GHCI の mode の表、単独の DC は RTL の STANDALONE を消す、display の core の変更は後で、互換は DISP2） | ユーザーの推しで進める許可 |
| 2026-10-25 12:41 | P3 の firmware の submit の直し（RESULT を先に、DONE は replay の後）を受け入れた | DONE の後は CP が driver の FENCE に進むので、replay を DONE の後にすると fence が早すぎる |
- 2026-10-25 12:47 p035 の順（P3 の案を採用）: D1 → D2a（rtl/dc を rtl/gpu/dc へ、MC は触らない）→ D3 → D5 を先に。D2b（MC）と D4（cp_seq など）は P1 の p034 の MC・seq の変更が amaterrace の main に入ってから。atg_cp_seq の busy_in を 9 bit にし、bit 8 を DC の待ち（disp_wait、B_ALL と WAIT_IDLE の 8 bit の mask の外）にする（design §18.4 の busy_in[0] は P1 の B_MEM と衝突するため）。
- 2026-10-25 12:52 p034 の R6（CP の firmware）は、P3 の 398a738（submit の直し、fw/cp）が T1-788 を通って amaterrace の main に入ってから、その上で始める（衝突を避ける）。それまで P1 は R5 の残り。
- 2026-10-25 13:28 p035 の D7（zedBSD の driver の側、RTL に依らない部分: DISP2 の発見・mode の表・attach の順・hcr.h の写し・host 試験）を P3 が D2b・D4 の待ちの間に先に進める。zedBSD の hcr.h は P3 が DISP2・IRQ・DC の define だけを足し、P1 の R7 が PROT の名前（GHCI_PROT_RANGES → GHCI_PROT_GRANTS）を直す。vk/ は P3 の持ち物で、P1 は Q1 を通して聞いてから触る。
- 2026-10-25 17:31 p035 の D6 の後半（Verilator の e2e で画面を点ける）の mode: atg_dc_mode に試験だけの小さな mode の parameter を足し、link-build（Verilator の e2e）でだけその mode を名乗らせる（driver は変えない。hardware が名乗る mode から driver が選ぶ、という Vulkan・GHCI の原則のまま）。720p は Verilator で 1 frame 約 124 万 pixel clock で重すぎるため。
- 2026-10-25 17:31 GHCI の minor の version は D8 で上げない（MSAA・PROT と同じく、release の時にまとめて）。
- 2026-10-25 19:21 KC705 の板の bring-up の gclk は 20 MHz（Fmax の見積もり約 23〜25 MHz に余裕を持たせる。ユーザーの「合成できて640x480などの小さな画面で出力できたら、それでよし」。50 MHz は p025 の pipeline の後）。
- 2026-10-25 20:35 取り消し: KC705 の bring-up の gclk 20 MHz（ユーザー「20MHzも低すぎます」）。
