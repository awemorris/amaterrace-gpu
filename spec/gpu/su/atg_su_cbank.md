# atg_su_cbank

RTL: `rtl/gpu/su/atg_su_cbank.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

The constant bank: 256 words loaded by LOAD_CONST (DMA from memory), read as c0-c31 operands (atg_su_opd's port) and by lwc (long beats).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `CONST_WORDS` | `256` | Size in words. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction; this unit acts only when the uop's unit field is its own. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group (lanes x_grp*NPHYS .. +NPHYS-1). |
| `x_last` | in | 1 | Last group of the instruction. |
| `x_sbe` | in | (SBE_W)+1 | Scoreboard entry of the instruction (all ones = none). |
| `x_pc` | in | 16 | Instruction index (branches, faults). |
| `x_uop` | in | UOP_W | The decoded instruction (include/atg_su_uop.vh). |
| `x_a` | in | NPHYS*32 | Operand rs1 per lane (modifiers applied). |
| `x_b` | in | NPHYS*32 | Operand rs2. |
| `x_c` | in | NPHYS*32 | Operand rs3 (or rs1+1 for the PAIR instructions). |
| `x_mask` | in | 2*NPHYS | [NPHYS-1:0] EXEC lanes of the group, [2*NPHYS-1:NPHYS] side-effect lanes (EXEC & coverage & ~KILLED). |
| `x_info` | in | 32 | x_info [15:0] fragment sequence number, [17:16] warp kind (0 vertex, 1 fragment, 2 compute), [18] front facing, [31:19] 0. |
| `x_ready` | out | 1 | This unit can take a group of its own this cycle (atg_su_opd waits otherwise). |
| **Long result to atg_su_wb (any time; wb may refuse with l_ready = 0)** | | | |
| `l_valid` | out | 1 | A result beat: one register of one lane group, or a completion without data. |
| `l_ready` | in | 1 | Taken by atg_su_wb. |
| `l_warp` | out | WARP_W | Warp. |
| `l_grp` | out | GRP_W | Group. |
| `l_rd` | out | 7 | Register written (texture: rd..rd+3 one beat each). |
| `l_data` | out | NPHYS*32 | Data. |
| `l_lanes` | out | NPHYS | Lanes written. |
| `l_wr` | out | 1 | 1: write the register; 0: completion only (stores, atomics without rd). |
| `l_last` | out | 1 | Last beat of the instruction: release its scoreboard entry and counter. |
| `l_sbe` | out | (SBE_W)+1 | The scoreboard entry (from x_sbe). |
| `l_cls` | out | 3 | Class (m, t or x) whose counter falls with l_last. |
| **c-operand read port (atg_su_opd)** | | | |
| `cr_en` | in | 1 | Read. |
| `cr_idx` | in | 15 | Three 5-bit indices. |
| `cr_data` | out | 96 | Three words, next cycle. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| `lc_kick` | in | 1 | LOAD_CONST: region/address/words in STATE 0x1EC-0x1EE. |
| `inv` | in | 1 | INVALIDATE[2]: drop the bank's contents (reads give 0 until reloaded). |
| `busy` | out | 1 | Loading. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

47 ports; 36 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

lc_kick → read CONST_WORDS ≤ 256 words from the address into the bank (region 0 only in v1); busy until done.  lwc reads word rs1 + imm (uniform or per lane).  The AMB port shares the I$'s through am_amb_mux (requester 1).

## 5. State machine

IDLE →(lc_kick)→ LOAD (line requests and fills) → IDLE.

## 6. Latency and throughput

c-operands every cycle; lwc 2 cycles.

## 7. Corner cases and errors

- A load error leaves the bank partly written; the MC has raised the fault.

## 8. What the TB checks

`sim/tb/atg_su_cbank_tb.v` prints, in this order:

- `PASS atg_su_cbank.load` — LOAD_CONST from a memory model
- `PASS atg_su_cbank.read` — c-operands and lwc
- `PASS atg_su_cbank` at the end.

## 9. References

design §3.2 (c0-c31), §2.4.3 (LOAD_CONST), §3.5 (constant bank).

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/atg_su_cbank_tb.v`).  The c operands come from a 32-word copy of the bank's first words (three reads per cycle); lwc reads the bank one lane per cycle (NPHYS + 2 cycles per group, not 2).  LOAD_CONST of a region other than 0 loads nothing; a word count above CONST_WORDS loads CONST_WORDS; an error response ends the load.  A lc_kick that comes while a lwc group is in progress waits until the group is done (x_ready is 0 while a load is pending or running).
