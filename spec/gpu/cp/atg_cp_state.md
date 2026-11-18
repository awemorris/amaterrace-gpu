# atg_cp_state

RTL: `rtl/gpu/cp/atg_cp_state.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

The state register file STATE[0..511] (one BRAM): written through the host alias and the SET_REG µop, broadcast to the blocks, read back by the host and by the CP's CPU.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Host alias (from atg_cp_regs)** | | | |
| `alias_we` | in | 1 | Whole-word host write. |
| `alias_idx` | in | 10 | Index. |
| `alias_wdata` | in | 32 | Data (hcr_wdata). |
| `alias_ridx` | in | 10 | Read index (combinational). |
| `alias_rdata` | out | 32 | STATE[alias_ridx] one cycle later (BRAM read). |
| **SET_REG and µop payloads (from atg_cp_seq)** | | | |
| `uop_we` | in | 1 | Write from the sequencer; always accepted. |
| `uop_idx` | in | 10 | Index. |
| `uop_wdata` | in | 32 | Data. |
| **Locks (from atg_cp_ctl and the blocks)** | | | |
| `open` | in | 1 | 1 in IDLE and HALTED: host alias writes allowed. |
| `blt_busy` | in | 1 | The blitter runs: host writes to 0x000-0x01F are refused. |
| `lock_fault` | out | 1 | One-cycle pulse: a host alias write was refused (fault kind 7, LOCKED). |
| **Broadcast to the blocks** | | | |
| `st_we` | out | 1 | Write strobe of every accepted write (host or µop). |
| `st_idx` | out | 10 | Index. |
| `st_wdata` | out | 32 | Value. |
| **CPU read port (atg_cpu window)** | | | |
| `cpu_ridx` | in | 10 | Read index. |
| `cpu_rdata` | out | 32 | STATE[cpu_ridx] one cycle later. |
| **Replay after RESET (from atg_cp_ctl)** | | | |
| `replay` | in | 1 | One-cycle pulse (the RESET pulse, `mc_flush`): broadcast STATE again. |
| `replay_busy` | out | 1 | 1 while the replay runs (513 cycles from the cycle after `replay`). |

20 ports.

## 4. Behaviour

- Accepted writes go to the RAM and out on `st_*` in the same cycle.  A µop write and a host write
  never meet (the host can write only in IDLE/HALTED, when the sequencer is idle); if they do, the µop
  write wins and the host write is refused with `lock_fault`.
- Two read ports: host (`alias_*`) and CPU (`cpu_*`).  **The RAM is duplicated** (two BRAM18 with
  the same writes): copy A answers the host alias, copy B the CPU port and the replay.
- **Replay (bug 1 of p023, fixed in p004):** design §2.6 keeps STATE over CTRL.RESET, but the blocks'
  copies (fed by `st_*`) are cleared by the core reset.  On `replay` the module reads STATE[0..511]
  from copy B and broadcasts each word on `st_*`, one per cycle, from the second cycle after the
  pulse; `replay_busy` is 1 for 513 cycles from the cycle after the pulse and atg_cp_ctl stays in
  RESETTING until it falls (5.1 µs at 100 MHz).  During the replay `cpu_rdata` is undefined (the CPU
  is held in RESETTING) and no write is expected (nothing is open, the sequencer is reset).
- Vendor area 0x1E0-0x1FF (Amaterrace): 0x1E0-0x1E8 DRAW_RAW's 9 words, 0x1E9-0x1EB DISPATCH gx/gy/gz,
  0x1EC-0x1EE LOAD_CONST region/address/words, 0x1FF DBG_MARK.  The sequencer writes these with
  `uop_we` before its kick pulse; the blocks read them from the broadcast like any STATE word.

## 5. State machine

None.

## 6. Latency and throughput

One write per cycle; reads 1 cycle.

## 7. Corner cases and errors

- Reset does not clear the RAM (design §2.6: STATE is kept over RESET).

## 8. What the TB checks

`sim/tb/atg_cp_state_tb.v` prints, in this order:

- `PASS atg_cp_state.write` — host and µop writes appear on st_* and read back
- `PASS atg_cp_state.lock` — host write while !open or to the BLT range while blt_busy: no write, lock_fault
- `PASS atg_cp_state.cpu` — the CPU port reads what was written
- `PASS atg_cp_state.replay` — a replay broadcasts the 768 words in order in 769 cycles
- `PASS atg_cp_state` at the end.

## 9. References

design §2.3 (STATE map), §2.4.3 (µops), §2.4.7 (CPU reads STATE, writes only through UOP_FIFO), the inline STATE code in `rtl/gpu/cp/atg_cp.v`.

## 10. Status

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)).  117 lines, no FSM (a replay counter).  Spec changes in p004: the `replay` /
`replay_busy` ports and the duplicated RAM (both above).  A µop write in the same cycle as a host
write wins and the host write gets `lock_fault`.

2026-10-25 (CAPS[30]): STATE has 0x000-0x2FF (0x200-0x2FF the vertex stage's texture slots, docs/ghci.md §8.1, §8.5); STATE indices are 10 bits.  The RAM has 768 words (each copy).
