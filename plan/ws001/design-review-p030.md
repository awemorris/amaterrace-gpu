<!-- awesome-plan project=amaterrace-gpu record=ws001-p030-design-review -->

# WS001 p030 の設計（design.md 版 6 §16）の敵対的 review

- 対象: [design.md](design.md) §16（Vulkan 1.0 core の残り）、§8 の p030 の行、amaterrace-gpu の worktree p1-p030 の `docs/ghci.md` の draft（CAPS[30]、FMT capability、µop 14 QUERY、§8.5、§12.10 の kind 9〜11、§12.12）。
- review 1: 2026-10-25 design-reviewer（subagent）。草稿（zedBSD 9b463b516、amaterrace 3f313e0）を読んだ。file は変えていない。build・試験・QEMU は走らせていない。他の branch は読むだけ（p3-p009f の head fd6b28f、p2-p027 の head 2803b65）。Vulkan の文面は Vulkan-Docs の raw の adoc と `vk.xml`（CC-BY-4.0 / Apache-2.0 OR MIT）。
- 対応: P1 が同日に全部を確かめて §16 に反映した（対応の表は design §16.26）。Critical 1（圧縮の format の必須）は `formats.adoc` の BCn の表の注、Critical 2（SET_REG の待ち）は `atg_cp_seq.v` の 212〜215・263 行、High 3 は `vertexpostproc.adoc` の clip volume、High 5 は `limits.adoc` と `atg_su_pt.v` で P1 も確かめた。
- review 2: 2026-10-25 design-reviewer。改訂（zedBSD ba0d912de、amaterrace d1d3f2e）を読んだ（p2-p027 は head 191913c、part F は fd6b28f）。23 件（High 4・Medium 5・Low 14）。P1 が反映（design §16.26 の 2 つ目の表）。

## review 1 の指摘（35 件: Critical 2・High 4・Medium 16・Low 13）

要点だけを写す（全文は design-reviewer の返事。根拠の行番号は review の時点の file）。

### Critical

1. **圧縮の texture の format が「任意」になっているが、1.0 の必須**（§16.1・§16.2・U49）。`formats.adoc` の BCn の表の注「The VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT, VK_FORMAT_FEATURE_BLIT_SRC_BIT and VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT features must be supported in optimalTilingFeatures for all the formats in at least one of: this table, formats-mandatory-features-etc, or formats-mandatory-features-astc.」は版の ifdef の外。{sym2} は「どれか 1 組が必須」。修正案: ETC2 + EAC の 10 format を必須として足し、TU に block の decoder、段と LW と試験。
2. **RX と ROP の範囲の SET_REG の待ちが上流の前の draw を守らない**（§16.6・§16.8・§16.9、GHCI §8.5）。`atg_cp_seq.v` 212〜215 行（ROP の範囲は ROP、RX の範囲は RX・ROP だけ）、263 行（DRAW は VF だけを待つ）、`atg_rop_order.v` 68 行（ROP の busy = 発行した連番が退いていない）。前の draw の primitive が連番を得る前に次の draw の ROP・RX の state が書ける。EndQuery の `OCC_CTRL = 0` も数え漏らす。87457fa に既に有る hazard（p027 の §15.6 も同じ前提）。修正案: RX・ROP の範囲は VF・SU・RX・ROP を待つ、EndQuery は `QUERY` を先に、TB。

### High

3. **far を geometric に切らないので w ≤ 0 の頂点が除算に入る**（reversed-Z の投影のカメラの後ろは z_c > 0 で near を通る）。修正案: 常に w ≥ ε を clip、`atg_rx_clip.wneg`。
4. **BLT の STATE の 0x00B が p027 の BLT_RESOLVE と衝突**、p030 で 4x になる format の hardware の resolve の道が無い。修正案: BLT_COLOR1〜3 を移し、RESOLVE を全部の 4x の C の format に。
5. **varying の limit 64 component を満たさず表にも無い**（KC705 の VARY_WORDS 32）。修正案: 表に行、行き先を決める。他の limit の出典も書く。
6. **ATTR_LIMIT（0x1D0〜0x1DF）の SET_REG が VF を待たない**（`atg_cp_seq.v` 215 行の `sidx[8:4]` は 0x1C0〜0x1CF だけ）。

### Medium

7. ATTR_LIMIT = 0 を「制限無し」にすると 0 byte の limit が無制限に化ける。
8. depth の clip を shading の後（ROP）で行うと、clip の外の fragment も store・atomic の副作用を持つ。案 a: RX で sample ごとに shading の前に。
9. line に guard band の clip が無い。
10. line・point の sub-triangle と guard band の fan の last-use の flag の規則が無い。
11. base と stride の揃えの規則が ps 8・16 と複数の line に合わない。
12. 「0 は以前の動作」の約束が direct の道（DRAW_RAW）と既存の TB で破れる（depth の clip、viewport の矩形、U52）。
13. FMT capability の ROM が hardware に無い機能（shader の道）まで答える。parameter 化が無い。FMT_LIMITS が 0x170 で窓と食い違う。
14. `vkCmdBlitImage` の dst（C の全部の format）の作り方が無い（compute の `sw` は 1・2 byte の画素で競合）。
15. SU の exp の色の RAM の量の見積もりが小さい（SU ごとに ≈1〜2k LUT）。
16. `atg_cp_seq` は既に 409 行で上限を超えている。
17. 段の順: S7 が S8 で作る `ex_aux` を使う。
18. firmware の内蔵の draw（resolve・clear・blit）が occlusion の数に入る。
19. D32F の depth bias の e を clip の後の sub-triangle ごとに求めると継ぎ目で o が変わる。
20. 試験が捕まえない誤り: FMT の ROM と表を同じ case から作った物どうしで比べる、model と RTL の共通の誤り、state の競合・w < 0・line の guard band・長さ 0 の line・ATTR_LIMIT の境の試験が無い。
21. item 8・10 に model・TB・scene が無く phase.md の受け入れを満たせない。他の Phase の範囲と LW を直していない。
22. GHCI の文の食い違い: p027 の §12.11 の r3 の文（1x は clamp）が U53 と矛盾、§8.5 の alpha to coverage の位置が Vulkan の順と逆に読める。

### Low

23. §16.2 の A8B8G8R8_* に STORAGE_IMAGE の必須は無い（行を分ける）。
24. 整数の C の format の SAMPLED の 4x の要否（`capabilities.adoc` の SAMPLED の規則の読み）。
25. CAPS[9] と CAPS[30] の stencil の重なり、CAPS[15:12] の版を上げる案との比較が無い。
26. GHCI §8.5 の待ちの出典の文（§7.3 は待ちを定義していない）。
27. FILL の pattern の位相が design と GHCI で食い違う。
28. R8・RG8 の u8 の道の dst の alpha、NaN・負の値の pack。
29. `viewportSubPixelBits` = 0 なら firmware が viewport を整数に丸めるべき。
30. GHCI の丸めの規則（RNE）は Vulkan が実装に委ねる範囲を縛っている。「Amaterrace:」の注に。
31. line の重みは「primitive の頂点 0・1」（PROVOKING が last の時の並べ替え）。
32. 長さ 0 の line は plane が解けない。
33. uniform texel buffer の TEX_BASE の 64 の揃えと `minTexelBufferOffsetAlignment`。
34. U47〜の回答がまだ無い。S1 の依存に。
35. LW が楽観的（S8・S9、圧縮、待ちの修正）。Begin の `QUERY` が全 block を待つ必要は無い。

scope の 11 項目の確認（review 1）: item 1〜4・6・7・9・11 は設計と試験が有る。item 5 は圧縮と varying の limit が欠け、item 8 は記録だけ、item 10 は RTL と試験が無い。license: CC-BY-4.0 の短い引用と事実の値、`vk.xml`、sRGB の式の扱いに問題は無い。GHCI の差分に WS・Phase の番号、`plan/` の path、絶対 path は無い。

## review 1 の後の追加の依頼（2026-10-25 Q1）

p027 の U44 の決定で resolve は BLT の op RESOLVE（`BLT_OP`[2:0] = 4、STATE 0x00B `BLT_RESOLVE`、専用の engine `atg_blt_rsv`）。「BLT RESOLVE の平均の format の code 3〜5（sRGB・SFLOAT16・SFLOAT32）、10:10:10:2 の code、8 byte の画素（BLT_OP[9:8]=2）」を p030 の RT の format の段に足し、RT の format ごとの resolve の code を §16 の表に。→ design §16.2（format ごとの code）と §16.12（画素 8・64・128 bit、平均 3〜7）、S10。

## review 2 の指摘（23 件: High 4・Medium 5・Low 14）

- **H1** depth の範囲の clip を RX の frag で quad の被覆を後から消すと、`atg_su_exp.v` 137 行の drain（`dlast` = 次の quad の被覆が 0）が後ろの quad を落とす。案: far を geometric に clip。
- **H2** minDepth = maxDepth（z_scale = 0）の viewport で frag の範囲の判定は必ず通り、far が効かない。案: far を `atg_rx_cpoly` で geometric に。
- **H3** §16.8a の修正は RX・ROP の範囲だけで、TU の範囲（VF を待たない）、program の範囲（待ち無し、`atg_su_sched.v` 100〜101 行）、LOAD_CONST（SU だけ）に同じ hazard。GHCI の一般の文が言い過ぎ。
- **H4** S10 が担当の無い BLT の U38 の分割を待つ（p027 は `atg_blt_2d` に名前を変えただけ、696 行）。
- **M1** RESOLVE の追加の場所が p027 の `atg_blt_avg`（組み合わせ）・`atg_blt_rsv_px` の構成と合わない。逐次の fadd と 2 分探索の stall の handshake が要る。
- **M2** p027 の RESOLVE の src の stride（2·S·ps の倍数）と p030 の RT の stride（min(2·S·ps, 64)）が食い違う。
- **M3** ETC2 の 16 byte の block の bilinear の取り出しが無い（FILTER_LINEAR は 10 format 全部に必須）。
- **M4** S8 の buffer ↔ D24S8 の stencil の copy の kernel の word の `sw` が region の外の byte を書き換える。
- **M5** TU の 16 slot を VS と FS が分け合うなら per-stage の 16 を満たさない（推測）。
- **L1〜L14**: 前の版の名残（§16.3、§8 の行、§16.1 の bias の行き先、§16.20 の `aux`（o）・`ropwait`、§16.21 の o・port、vec-diff の「意図した変更」）、§16.23 の integer の 4x の行と U54 の矛盾、fan の最大数の食い違い、S10 の依存（`atg_fmt_srgbenc` は S1）、w ≥ ε の ε が絶対値、ATTR_LIMIT の比較の桁あふれ、CAPS[30] が ETC2 を無条件に約束、ps ≠ 4 と block の TEX_BASE の揃え、firmware の clear の色の pack の照合の相手（UFLOAT 等）、EAC と punch-through の規則、GHCI の RESOLVE の参照と「6-15 Refused」、guard band の平面の形（除算と scale の符号）、host の STATE の書き込みの規則、rasterizerDiscardEnable の扱い。

確かめられた事（review 2）: LW の和、段の名前、ROP_CTRL への統一、bias の ROP への転送と pattern の名残の無さ、STATE の index と `ghci_regs.vh` の整合、`atg_cp_seq` の port（38 + 2 = 40）、§16.2 の表と `formats.adoc` の行、RESOLVE の code 6・7 の bit の配置、GHCI の文に WS・Phase の番号と path が無い事。

## review 2 の間の決定（Q1、2026-10-25）

- 「`atg_cp_seq` の RX・ROP の範囲の SET_REG の待ちの直し（§16.8a）は p027 の P2 の範囲に移した。p030 の S5 からは外し、§16.8a は『p027 で直す（前提）』と書き換えてください。ETC2+EAC の S12 は了解」
- ユーザーの決定（原文）「圧縮テクスチャはPCIe GPUの実機bringupの後に回します。」→ S12 を p030 の範囲の外に（設計の形は design §16.11a に残す）。
