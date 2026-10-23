# atg_su_wb

RTL: `rtl/gpu/su/atg_su_wb.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

Write-back arbitration: one RF write port shared by the short pipeline (one result per cycle), the long units' beats, and the VF/RX input writes; pushes rq results; releases scoreboard entries.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `NS` | `6` | Short sources (alu, fpu, pk, lane, lda, exec). |
| `NL` | `6` | Long sources (lsu, lds, cbank, tex, xu, div). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Short results (packed, source 0 in the low bits; at most one valid per cycle)** | | | |
| `s_valid` | in | NS | Valid. |
| `s_warp` | in | NS*WARP_W | Warp. |
| `s_grp` | in | NS*GRP_W | Group. |
| `s_rd` | in | NS*7 | rd. |
| `s_data` | in | NS*NPHYS*32 | Data. |
| `s_lanes` | in | NS*NPHYS | Lanes. |
| **Long results (packed)** | | | |
| `l_valid` | in | NL | Valid. |
| `l_ready` | out | NL | Taken. |
| `l_warp` | in | NL*WARP_W | Warp. |
| `l_grp` | in | NL*GRP_W | Group. |
| `l_rd` | in | NL*7 | rd. |
| `l_data` | in | NL*NPHYS*32 | Data. |
| `l_lanes` | in | NL*NPHYS | Lanes. |
| `l_wr` | in | NL | Write. |
| `l_last` | in | NL | Last beat. |
| `l_sbe` | in | NL*(SBE_W+1) | Entry. |
| `l_cls` | in | NL*3 | Class. |
| **Input writes (0 VF, 1 RX: one lane word per cycle)** | | | |
| `in_we` | in | 2 | Write. |
| `in_warp` | in | 2*WARP_W | Slot. |
| `in_reg` | in | 12 | Register, 6 bits each. |
| `in_lane` | in | 10 | Lane 0-31, 5 bits each. |
| `in_data` | in | 64 | Data, 32 bits each. |
| **Outputs** | | | |
| `w_en` | out | 1 | RF write. |
| `w_warp` | out | WARP_W | Warp. |
| `w_grp` | out | GRP_W | Group. |
| `w_reg` | out | 6 | Register. |
| `w_data` | out | NPHYS*32 | Data. |
| `w_lanes` | out | NPHYS | Lanes. |
| `rel_valid` | out | 1 | Release (to atg_su_sb). |
| `rel_warp` | out | WARP_W | Warp. |
| `rel_sbe` | out | (SBE_W)+1 | Entry. |
| `rel_cls` | out | 3 | Class. |
| `rq_push` | out | 1 | Push (rd 63) to atg_su_rq. |
| `rq_data` | out | NPHYS*32 | Data. |
| `wb_stall` | out | 1 | Ask atg_su_sb not to issue next cycle (a long beat waits). |

37 ports.

## 4. Behaviour

- Priority (design §3.5): (1) the short result of this cycle; (2) input writes (only to slots that
  are not running; they have no back-pressure, so they wait in a 16-entry FIFO per source and raise
  wb_stall while waiting); (3) long beats, round-robin over the sources, in cycles without (1) or
  (2) — a beat waiting more than 4 cycles raises wb_stall so a free cycle comes SHORT_LAT cycles
  later.  A long beat without data (l_wr 0) is taken in any cycle.
- rd 63 → rq_push instead of the RF.  l_last → rel_* (also for l_wr 0).

## 5. State machine

None (a round-robin pointer and the wait counter).

## 6. Latency and throughput

One RF write per cycle.

## 7. Corner cases and errors

- Two short results in one cycle cannot happen (one issue per cycle, fixed latency); the TB checks the assertion.

## 8. What the TB checks

`sim/tb/atg_su_wb_tb.v` prints, in this order:

- `PASS atg_su_wb.prio` — short beats always win; long beats get free cycles; wb_stall after 4 cycles
- `PASS atg_su_wb.release` — l_last gives exactly one release, also without data
- `PASS atg_su_wb.input` — VF/RX lane writes become lane-masked group writes
- `PASS atg_su_wb` at the end.

## 9. References

design §3.5 (write port arbitration), §3.1.1.

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/atg_su_wb_tb.v`).  Differences from §4 (spec corrected here): the input writes have no back-pressure, so they go before long beats (short > input > long) and wait in a 16-entry FIFO per source while short results hold the port; a waiting input also raises wb_stall.  A long beat with l_wr = 0 (a store's completion) is taken in any cycle (it needs no port).  The VF/RX input path is exercised only by this TB until p009.
