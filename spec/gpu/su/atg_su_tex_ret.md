# atg_su_tex_ret

RTL: `rtl/gpu/su/atg_su_tex_ret.v`.  Parent: atg_su_tex.  Implemented in: p009 (split off atg_su_tex in part C).

## 1. Purpose and place

The return half of atg_su_tex: a FIFO of the records of the lane groups sent to the TU and, for the oldest record, the gathering of its returned quads into the group's long beats to atg_su_wb.  Children: `am_fifo`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS) (1 for NPHYS 32). |
| `SBE_W` | `2` | log2(SB_ENTRIES). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Records from the send half (one per lane group, when it is taken)** | | | |
| `rq_valid` | in | 1 | Push a record. |
| `rq_ready` | out | 1 | The FIFO has room (atg_su_tex takes a group only then). |
| `rq_warp` | in | WARP_W | Warp. |
| `rq_grp` | in | GRP_W | Lane group. |
| `rq_rd` | in | 7 | Destination register. |
| `rq_sbe` | in | SBE_W+1 | Scoreboard entry. |
| `rq_last` | in | 1 | The instruction's last group. |
| `rq_sz` | in | 1 | texsz (one register). |
| `rq_qmask` | in | NPHYS/4 | The quads sent to the TU (those with EXEC lanes). |
| `rq_lanes` | in | NPHYS | The group's EXEC lanes. |
| **Returned quads from the TU (in request order)** | | | |
| `tr_valid` | in | 1 | A quad. |
| `tr_ready` | out | 1 | Taken. |
| `tr_data` | in | 512 | 4 lanes × RGBA fp32 (texsz: lane word 0). |
| **Long result to atg_su_wb** | | | |
| `l_valid` | out | 1 | A beat. |
| `l_ready` | in | 1 | Taken. |
| `l_warp` | out | WARP_W | Warp. |
| `l_grp` | out | GRP_W | Group. |
| `l_rd` | out | 7 | rd + beat. |
| `l_data` | out | NPHYS*32 | Channel `beat` of each lane. |
| `l_lanes` | out | NPHYS | The record's EXEC lanes. |
| `l_wr` | out | 1 | 1. |
| `l_last` | out | 1 | The last beat of a record with rq_last. |
| `l_sbe` | out | SBE_W+1 | The scoreboard entry. |
| `l_cls` | out | 3 | Class t. |

26 ports.

## 4. Behaviour

Records go into a 4-entry FIFO (`am_fifo`).  The oldest is taken in HEAD; its returned quads are the next ones from the TU, one per set bit of rq_qmask in increasing quad order (the TU answers in request order and the send half sends in this order).  When all are in, the beats go out: rd, rd+1, rd+2, rd+3 with channel 0-3 of each lane (lane 4j + l of the group = lane l of quad j), or rd only for texsz; l_last on the last beat when rq_last.  A record without sent quads writes its beats at once (its lanes are 0).

## 5. State machine

HEAD →(a record)→ GATHER (quad q; a quad not sent is skipped) →(the last quad)→ BEAT (beat c) →(the last beat taken)→ HEAD; HEAD →(a record without quads)→ BEAT.

## 6. Latency and throughput

A beat per cycle while l_ready; a returned quad per cycle while gathering; HEAD costs a cycle per record.

## 7. Corner cases and errors

- The FIFO full holds the send half (x_ready 0).
- Lanes of a sent quad outside EXEC carry whatever the TU returned (0); l_lanes excludes them.

## 8. What the TB checks

No unit testbench of its own: `sim/tb/atg_su_tex_tb.v` (`PASS atg_su_tex.ret`) checks it through atg_su_tex.

## 9. References

`spec/gpu/su/atg_su_tex.md`, design §3.4.1 (tex*), §3.1.1 (scoreboard).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu), split off atg_su_tex (one state machine per module).  144 lines.
