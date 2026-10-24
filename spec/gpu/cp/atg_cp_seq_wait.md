# atg_cp_seq_wait

RTL: `rtl/gpu/cp/atg_cp_seq_wait.v`.  Parent: atg_cp_seq.  Children: none.

## 1. Purpose and place

The waits of the µop sequencer, combinational: for the payload dword in hand, whether and where it writes STATE and which busy bits hold it; for the µop, which busy bits it waits for before its act and after its kick.  Split out of `atg_cp_seq` for the line limit.

## 2. Parameters

None.

## 3. Ports

All combinational.  Busy bits in STATUS order: [1] BLT, [2] VF, [3] RX, [4] ROP, [5] TU, [6] SU.

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `vendor` | in | 1 | The µop is class 1. |
| `op` | in | 6 | Its op. |
| `flags` | in | 8 | Its flags. |
| `p` | in | 8 | Payload dwords taken so far. |
| `set_val` | in | 1 | The dword is a SET_REG value. |
| `sidx` | in | 9 | The SET_REG index of the pair. |
| `pay_we` | out | 1 | The dword writes STATE. |
| `pay_idx` | out | 9 | At this index. |
| `pay_wait` | out | 8 | Busy bits that hold the dword. |
| `pre` | out | 8 | Busy bits the µop waits for before its act. |
| `pre_f` | out | 1 | It also waits for the fence unit. |
| `post` | out | 8 | Busy bits it waits for after its kick. |

12 ports.

## 4. Behaviour

- SET_REG: the BLT range waits for the BLT; the VF's (0x020-0x04F, 0x1C0-0x1DF: ATTR_DST and ATTR_LIMIT) for the VF; the RX range (0x050-0x06F) and the ROP range (0x070-0x08F) for the VF, the SUs, the RX and the ROP (work that will read that state may still be upstream of the ROP's sequence numbers); the TU range (0x090-0x18F) for the VF, the SUs, the RX and the TU; the program range (0x190-0x1AF: the SU takes VS_BASE, FS_BASE and the rest when a warp starts) for the VF, the SUs and the RX; the others (0x1B0-0x1BF, the vendor words through SET_REG) do not wait.
- DRAW_RAW's 9 words go to 0x1E0-0x1E8 and wait for the RX; DBG_MARK's word to 0x1FF; DISPATCH's 3 to 0x1E9-0x1EB and LOAD_CONST's 3 to 0x1EC-0x1EE wait for the SUs.
- pre/post: BLIT pre BLT, post BLT when flags[0]; DRAW pre VF; FENCE pre all; WAIT_IDLE pre flags (0: all); LOAD_CONST pre VF, SU and RX (the constants of a draw upstream are read by its warps), post SU; RESULT pre all and the fence unit; DRAW_RAW pre RX.

## 5. State machine

None.

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

- `-DMUT_SEQ_DRAWSTATE` restores the earlier rules (RX/ROP only for those ranges, the TU without the VF, no wait for the program range, LOAD_CONST after the SUs only, 0x1C0-0x1CF only) for the TB's mutation check.

## 8. What the TB checks

Through `sim/tb/atg_cp_seq_tb.v` (`spec/gpu/cp/atg_cp_seq.md` §8): `.drawstate`, `.tuwait`, `.progwait`, `.ldconst`, `.attrlimit_wait` in particular.

## 9. References

design §2.4.3 (µops), §3.8 (DRAW order), §15.6 (state between draws).

## 10. Status

Implemented (moved out of `atg_cp_seq`; the RX and ROP ranges' wait widened at the same time).

2026-10-25 (CAPS[30]): QUERY (op 14) has RESULT's pre-wait (every block, and f_busy 0) unless flags[0] (clear only: no wait).
