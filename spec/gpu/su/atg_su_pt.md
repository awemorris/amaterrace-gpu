# atg_su_pt

RTL: `rtl/gpu/su/atg_su_pt.v`.  Parent: atg_su.  Implemented in: p009 (split off atg_su_exp in part B).

## 1. Purpose and place

The post-transform buffer (PT): vertex warps' exports of the position and the varyings, read by the RX word by word; the allocator of 32-entry blocks for vertex warps, and the "block ready" bits that let the RX read a block's primitives.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32. |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS) (1 for NPHYS 32). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `PT_ENTRIES` | `64` | PT vertices: a multiple of 32, at most 256 (two warps of 32 with the default 64). |
| `VARY_WORDS` | `16` | Varying words per vertex, at most 64 (KC705 64). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Issued instruction (from atg_su_opd; only exp of vertex warps is taken)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group. |
| `x_uop` | in | UOP_W | The decoded instruction (unit, the exp target in the immediate). |
| `x_b` | in | NPHYS*32 | exp's data (rs2). |
| `x_mask` | in | 2*NPHYS | [2*NPHYS-1:NPHYS] side-effect lanes are written. |
| `x_info` | in | 32 | [17:16] warp kind (0 vertex). |
| **PT read port (atg_rx)** | | | |
| `pt_rd` | in | 1 | Read. |
| `pt_idx` | in | 8 | Vertex entry. |
| `pt_word` | in | 7 | Word: 0-3 position, 4 + w varying word w. |
| `pt_rdata` | out | 32 | Data, the cycle after pt_rd (held until the next read). |
| `pt_free` | in | 1 | Return a vertex entry (one-cycle pulse). |
| `pt_free_idx` | in | 8 | Its index. |
| **Allocation (atg_su_sched, the VF)** | | | |
| `pt_ok` | out | 1 | A whole block (32 entries) is free (to atg_su_sched). |
| `pt_take` | in | 1 | The vertex grant (atg_su's vl_gnt): take the block of pt_base. |
| `pt_warp` | in | WARP_W | The granted slot (atg_su's vl_slot, with pt_take). |
| `pt_base` | out | 8 | First entry of the lowest free block (to the VF through vl_ptbase, valid with pt_take). |
| `vl_go` | in | 1 | The VF starts the granted warp. |
| `vl_mask` | in | 32 | Its lanes that some primitive uses (with vl_go). |
| `pt_done` | out | 8 | Bit b: the vertex warp that took block b has ended (its exports are in the PT); 0 for absent blocks. |
| **Warp ends (atg_su_exec)** | | | |
| `wc_end` | in | 1 | A warp ended. |
| `wc_warp` | in | WARP_W | Warp. |

24 ports.

## 4. Behaviour

- Vertex warp (x_info kind 0) exp: target 0x000+k (POS component k, PT word k) and 0x010+v
  (varying word v < VARY_WORDS, PT word 4+v) write the side-effect lanes of the group into entry
  base + lane, base the warp's block × 32.  Other targets (point size 0x004, beyond the varyings,
  fragment targets) and other warp kinds are not stored.
- pt_rd: pt_rdata = word pt_word of entry pt_idx the next cycle (pt_word < 4 + VARY_WORDS).
- Allocator (WS288 p009, Q1's decision): one count per block of 32 entries.  pt_ok when some
  block's count is 0; pt_base = 32 × the lowest such block.  pt_take sets its count to 32, records
  the slot as its owner and the slot's block, clears pt_done for it.  vl_go subtracts the lanes
  outside vl_mask (vl_mask 0 returns the whole block).  pt_free subtracts 1 from the block of
  pt_free_idx.  wc_end of the slot that still owns its block sets pt_done (an earlier owner whose
  block was retaken does not).  The VF asks for the next grant only after vl_go (atg_su_sched has one
  vertex grant outstanding), so vl_go always belongs to the latest take.
- atg_top lets a primitive from the VF reach the RX only while pt_done of its block is set (the
  vertex shader's results must be in the PT before the RX reads them, design §3.8).

## 5. State machine

None (counters and flags).

## 6. Latency and throughput

One lane group per cycle in (NPHYS banks, bank = entry mod NPHYS, 4 + VARY_WORDS words per entry); one word per cycle out, one cycle latency (block RAM).

## 7. Corner cases and errors

- Simultaneous take, go and free on one block add up in one cycle.
- A count never goes below 0 when the VF and the RX keep the rule "each entry of a lane in vl_mask is freed exactly once" (atg_vf_asm §4).

## 8. What the TB checks

`sim/tb/atg_su_pt_tb.v` prints, in this order:

- `PASS atg_su_pt.pt` — vertex exports land in PT and read back through pt_*; other targets and kinds are not stored
- `PASS atg_su_pt.alloc` — pt_ok/pt_base/pt_take, vl_go (also vl_mask 0) and pt_free accounting per block, pt_done (and not from a stale owner)
- `PASS atg_su_pt` at the end.

## 9. References

design §3.4.3, §3.5 (PT), §3.8 (PT reservation, deadlock); spec atg_vf_asm.md §4, §7; atg_su_exp.md.

## 10. Status

Implemented in WS288 p009 part B1 (P1, branch p1-su-gfx), split off atg_su_exp (its PT part).  New ports against the earlier atg_su_exp: `pt_warp`, `vl_go`, `vl_mask`, `pt_done` (Q1's allocator decision of 2026-10-24 and the PT-ready rule); atg_su has the new output `pt_done`.

Varying 64 components (Vulkan 1.0's limit): pt_word is 7 bits (PT words up to 67 with VARY_WORDS 64; was 6), VARY_WORDS at most 64 (exp targets 0x010-0x04F).  KC705 (NPHYS 16, PT_ENTRIES 64): 16 banks of 4 × 68 words, one BRAM18 each as before (estimate).

Session protection (2026-10-25): `scrub` writes 0 to every word through the write port, one word per cycle (`atg_su_scrub`), `scrub_busy` meanwhile; the RAM's declaration and read are unchanged.  Checked by `sim/tb/atg_su_scrub_tb.v`.
