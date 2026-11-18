# atg_rop_occ

RTL: `rtl/gpu/rop/atg_rop_occ.v` (new).  Parent: atg_rop.

## 1. Purpose and place

The occlusion counter: counts the samples that pass every per-sample test while ROP_CTRL[0] is 1; the command processor's QUERY micro-op reads and clears it.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `st_we` | in | 1 | STATE broadcast: one-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index. |
| `st_wdata` | in | 32 | STATE value; the module keeps ROP_CTRL[0] (0x08D). |
| `inc_valid` | in | 1 | One cycle: a quad's first beat left the depth/stencil test. |
| `inc_n` | in | 5 | Its passing samples (popcount of the mask after atg_rop_ds: lanes × samples, 0-16). |
| `clear` | in | 1 | One cycle, from atg_cp_seq (QUERY flags[0] or flags[1]). |
| `count` | out | 40 | The counter (to atg_cp_seq for QUERY); registered. |

9 ports.

## 4. Behaviour

count <= (clear ? 0 : count) + (inc_valid && ROP_CTRL[0] ? inc_n : 0): a clear and an increment in the same cycle leave the increment.  The counter wraps at 2^40 (never reached in practice).  ROP_CTRL[0] takes effect on the STATE write (the CP's waiting rules make the write come between draws).

## 5. State machine

None.

## 6. Latency and throughput

One increment per cycle; count is the value after the last cycle's update.

## 7. Corner cases and errors

- Reset clears the counter.
- A quad with no colour attachment (a nocol beat) still counts: atg_rop_ds passes it on and atg_rop gives inc_valid for the first beat of every quad.

## 8. What the TB checks

`sim/tb/atg_rop_occ_tb.v` prints:

- `PASS atg_rop_occ.count` — random increments against a model with ROP_CTRL[0] switched, clears alone and with an increment
- `PASS atg_rop_occ` at the end.

`MUT_OCC_BEAT` (in atg_rop: count every beat) is checked by `sim/tb/atg_rop_beat_tb.v` (`PASS atg_rop_beat.occ`), not here.

## 9. References

docs/ghci.md §7.3 (QUERY), §8.5 (ROP_CTRL), design §16.8.  Values referenced: Vulkan specification, Occlusion Queries, Sample Counting.

## 10. Status

Implemented 2026-10-25: every PASS of §8.  Wired in atg_rop (inc_valid = atg_rop_ds's d_valid and d_ready of a first beat, d_beat[0]; inc_n its d_smask's popcount) and to atg_cp_seq's QUERY through atg_top.
