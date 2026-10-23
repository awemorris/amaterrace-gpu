# atg_su_rf

RTL: `rtl/gpu/su/atg_su_rf.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

The SU's register file: NWARPS × NREGS × 32 lanes × 32 bits in block RAM, three copies for three reads per cycle (design §3.5), one write port (from atg_su_wb), banked per physical lane.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
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
| `r_en` | in | 1 | Read three registers of one lane group. |
| `r_warp` | in | WARP_W | Warp. |
| `r_grp` | in | GRP_W | Group. |
| `r_reg1` | in | 6 | Register for port 1. |
| `r_reg2` | in | 6 | Register for port 2. |
| `r_reg3` | in | 6 | Register for port 3. |
| `r_data1` | out | NPHYS*32 | Data, the cycle after r_en. |
| `r_data2` | out | NPHYS*32 | Data. |
| `r_data3` | out | NPHYS*32 | Data. |

17 ports.

## 4. Behaviour

Each copy is written with every write.  A read of the register written in the same cycle returns the old value (no bypass: the short pipeline's interlock covers it, design §3.1.1).  Address = {warp, reg, grp}.

## 5. State machine

None.

## 6. Latency and throughput

1 write and 3 reads per cycle, read latency 1.  BRAM36 at NREGS 32, NWARPS 4, NPHYS 8: 12 (design §3.5 table A).

## 7. Corner cases and errors

- No reset of the contents.

## 8. What the TB checks

`sim/tb/atg_su_rf_tb.v` prints, in this order:

- `PASS atg_su_rf.rw` — random writes with lane enables, three-port reads compare with a model
- `PASS atg_su_rf.same` — read and write of one register in one cycle returns the old value
- `PASS atg_su_rf` at the end.

## 9. References

design §3.5 (register file, U12), README (register file shape).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/atg_su_rf_tb.v` with NPHYS 8/16/32 and NREGS 64/NWARPS 8).  One simple dual-port RAM per lane and copy; r_data holds while r_en is 0 (atg_su_opd relies on it under back-pressure).
