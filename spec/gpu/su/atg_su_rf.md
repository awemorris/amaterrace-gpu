# atg_su_rf

RTL: `rtl/gpu/su/atg_su_rf.v`.  Parent: atg_su.  Implemented in: p008, optimized in: ws001-p013.

## 1. Purpose and place

The SU's register file: NWARPS × NREGS × 32 lanes × 32 bits in block RAM, two copies (m1, m2) for two reads concurrently per cycle alongside one writeback port (ws001-p013 BRAM halving), banked per physical lane.
Operands for 3-operand instructions (FMA, SEL, PAIR) are time-multiplexed across 2 cycles by the operand collector (`atg_su_opd`).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `NREGS` | `32` | GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Write (from atg_su_wb)** | | | |
| `w_en` | in | 1 | Write one register of one lane group. |
| `w_warp` | in | WARP_W | Warp. |
| `w_grp` | in | GRP_W | Group. |
| `w_reg` | in | 6 | Register 0..NREGS-1. |
| `w_data` | in | NPHYS*32 | Data. |
| `w_lanes` | in | NPHYS | Lane enables. |
| **Read (from atg_su_opd)** | | | |
| `r_en` | in | 1 | Read two registers of one lane group. |
| `r_warp` | in | WARP_W | Warp. |
| `r_grp` | in | GRP_W | Group. |
| `r_reg1` | in | 6 | Register for port 1. |
| `r_reg2` | in | 6 | Register for port 2. |
| `r_data1` | out | NPHYS*32 | Data, the cycle after r_en. |
| `r_data2` | out | NPHYS*32 | Data. |
| **Scrub (session protection)** | | | |
| `scrub` | in | 1 | Clear contents. |
| `scrub_busy` | out | 1 | Scrub in progress. |

15 ports.

## 4. Behaviour

Each copy is written with every write.  A read of the register written in the same cycle returns the old value (no bypass: the short pipeline's interlock covers it, design §3.1.1).  Address = {warp, reg, grp}.

## 5. State machine

None.

## 6. Latency and throughput

1 write and 2 reads per cycle, read latency 1.
BRAM36 consumption is reduced by 33% to 50%+ (e.g. 8 BRAM36s per SU at NPHYS=4, NWARPS=4, NREGS=32).

## 7. Corner cases and errors

- No reset of the contents.

## 8. What the TB checks

`sim/tb/atg_su_rf_tb.v` prints, in this order:

- `PASS atg_su_rf.rw` — random writes with lane enables, dual-port reads compare with a model (NPHYS 4, 8, 16, 32; NPHYS 16 also with NREGS 64 and NWARPS 8, NPHYS 4 also with NREGS 64)
- `PASS atg_su_rf.same` — read and write of one register in one cycle returns the old value
- `PASS atg_su_rf` at the end.

`sim/tb/atg_su_rf_opt_tb.v` verifies:
- `PASS atg_su_rf_opt.fma_alu` — mixed consecutive 3-operand FMA and 2-operand ALU instructions under time-multiplexed operand collection.
- `PASS atg_su_rf_opt.rw_hazard` — concurrent writeback port activity and read-during-write correctness across NPHYS 4, 8, 16, 32.
- `PASS atg_su_rf_opt` at the end.

## 9. References

design §3.5 (register file, U12), README (register file shape), ws001-p013.

## 10. Status

Implemented in WS288 p008; optimized in ws001-p013 (2-copy dual-port Block RAM architecture halving SU BRAM count). One dual-port RAM per lane and copy with `(* ram_style = "block" *)`; r_data holds while r_en is 0 (atg_su_opd relies on it under back-pressure).

Session protection (2026-10-25): `scrub` writes 0 to every word through the write port, one word per cycle (`atg_su_scrub`), `scrub_busy` meanwhile; the RAM's declaration and read are unchanged.  Checked by `sim/tb/atg_su_scrub_tb.v`.
