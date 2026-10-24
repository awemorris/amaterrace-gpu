# atg_su_sb

RTL: `rtl/gpu/su/atg_su_sb.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

The issue stage with the per-warp scoreboard (design §3.1.1): checks the operand ranges of an instruction against the warp's outstanding long operations, the wait counters, rq and write-back stalls; issues to atg_su_opd with an entry, or replays.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `SB_ENTRIES` | `4` | Scoreboard entries per warp (KC705 8). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From atg_su_dec** | | | |
| `u_valid` | in | 1 | Instruction. |
| `u_ready` | out | 1 | Taken (issued or replayed). |
| `u_warp` | in | WARP_W | Warp. |
| `u_pc` | in | 16 | pc. |
| `u_uop` | in | UOP_W | Micro-op. |
| **To atg_su_opd** | | | |
| `i_valid` | out | 1 | Issue. |
| `i_ready` | in | 1 | Taken (all of its groups will follow). |
| `i_warp` | out | WARP_W | Warp. |
| `i_pc` | out | 16 | pc. |
| `i_uop` | out | UOP_W | Micro-op. |
| `i_sbe` | out | (SBE_W)+1 | Entry taken (all ones: none). |
| **To atg_su_sched** | | | |
| `fb_valid` | out | 1 | Feedback. |
| `fb_warp` | out | WARP_W | Warp. |
| `fb_kind` | out | 2 | 0 issued, 1 issued and wait for warp control (unit EXEC), 2 replay. |
| `wake` | out | NWARPS | Entry or counter released for the warp. |
| **Releases (from atg_su_wb)** | | | |
| `rel_valid` | in | 1 | A long instruction finished. |
| `rel_warp` | in | WARP_W | Warp. |
| `rel_sbe` | in | (SBE_W)+1 | Entry (all ones: none). |
| `rel_cls` | in | 3 | Counter to decrement. |
| `wb_stall` | in | 1 | atg_su_wb needs this cycle's write port: do not issue. |
| `rq_empty` | in | 1 | No entry to pop. |
| `rq_full` | in | 1 | No room to push. |
| `busy` | out | 1 | Any entry or counter is not zero. |
| `fault` | out | 1 | ISA fault pulse (uop ILL issued). |
| `fault_pc` | out | 16 | Its pc. |

27 ports.

## 4. Behaviour

- Entry: {valid, dst base, width (1 or 4), class}.  Hazard: any used source (rs1, rs2, rs3, rs1+1
  for PAIR, rs3 + 1 for a texture .3 form with Dref) or the destination range overlaps a valid entry's range → replay.
- Counters per warp: cm (stores/atomics outstanding), ct, cx.  `wait` (CTL) replays until the
  counters are ≤ its limits; `fence` (CTL) replays until cm = 0 (global) and then issues to the LSU
  for its D$ invalidate (acquire); `end` waits for all counters 0 (design §3.1.1).
- Long instructions (classes m, t, x with lanes) take an entry when they write a register (ndst > 0)
  and always increment their class counter; no free entry → replay.  EXEC all 0 (known from the
  operand stage: atg_su_opd suppresses the work and still sends an l_last completion) — v1 issues
  them normally; the unit reports completion without requests.
- rq: a source 63 with rq_empty, or rd 63 with rq_full → replay (design §3.9.1, v1 never sees it).

## 5. State machine

None (per-warp entry and counter registers, combinational check).

## 6. Latency and throughput

One check per cycle; the overlap check is about 400 LUT at 8 entries × 5 operands (design §3.1.1).

## 7. Corner cases and errors

- A release and an allocation of the same entry in one cycle: the release first.
- ILL: issue nothing, pulse fault, feedback 1 (the warp stops; the CP faults the device).

## 8. What the TB checks

`sim/tb/atg_su_sb_tb.v` prints, in this order:

- `PASS atg_su_sb.raw` — a read of a pending destination replays until the release
- `PASS atg_su_sb.waw` — a write over a pending texture rd..rd+3 replays; a texture .3 form with Dref whose rs1+3 (rs3 + 1) is in it replays, the same form without .3 issues
- `PASS atg_su_sb.full` — entries full: long instruction replays; other warps issue
- `PASS atg_su_sb.wait` — wait/fence/end with counters
- `PASS atg_su_sb.fault` — ILL gives fault with the pc
- `PASS atg_su_sb` at the end.

## 9. References

design §3.1.1 (scoreboard), §3.4.2 (classes), §3.9 (rq).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/atg_su_sb_tb.v`).  Spec change made in p008 (the spec lacked the short-result interlock of design §3.1.1): parameters `NPHYS` and `SHORT_LAT`, input `x_end` (the last group of an instruction leaves atg_su_opd: `x_valid && x_last && unit_ready[unit]`, wired in atg_su).  Issued instructions are listed in order until x_end; a short writer (class a/f with rd < 63) then counts SHORT_LAT+1 cycles.  A reader of its rd is held (u_ready 0, not replayed) while the writer is before the bus or the count is above 32/NPHYS + 1; a long writer of that rd is held until the count ends.  nop and a satisfied wait are consumed without issue (feedback 0).  Counters are 6 bits; a long instruction whose counter is at the maximum replays.  Feedback 1 for branches, end and bar.

2026-10-25 (p009 part F, P3): a fifth source for the texture .3 forms with Dref (`texl.3.c`, `texb.3.c`, `texg.3.c`): rs3 + 1 = rs1+3, checked like the others (`src5`: TEX unit, the uop's sub[4] and TEX op bit 2).
