# am_fifo

RTL: `rtl/common/am_fifo.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

A synchronous first-word-fall-through (FWFT) FIFO of 2^`DEPTH_LOG2` entries of `W` bits in distributed RAM, one clock. Parent today: `am_axi_master` (two instances, `wq` and `rq`, which hold the user bits of the outstanding writes and reads). Children: none.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `W` | 8 | Entry width in bits | ≥ 1 |
| `DEPTH_LOG2` | 2 | log2 of the number of entries | ≥ 1 (the read index is `rp[DEPTH_LOG2-1:0]`; 0 does not elaborate) |

## 3. Ports

| Name | Dir | Width | Domain | Meaning, handshake, timing |
| --- | --- | --- | --- | --- |
| `clk` | in | 1 | — | Clock |
| `rst_n` | in | 1 | `clk` | Synchronous, active low: empties the FIFO (pointers to 0; the RAM is not cleared) |
| `in_valid` | in | 1 | `clk` | Push request. A push happens in a cycle with `in_valid && in_ready` |
| `in_ready` | out | 1 | `clk` | "Not full" (`count != 2^DEPTH_LOG2`). Combinational from the pointers only, not from `in_valid` or `out_ready` |
| `in_data` | in | `W` | `clk` | Entry written at the push |
| `out_valid` | out | 1 | `clk` | "Not empty" (`count != 0`) |
| `out_ready` | in | 1 | `clk` | Pop request. A pop happens in a cycle with `out_valid && out_ready` |
| `out_data` | out | `W` | `clk` | The oldest entry, valid while `out_valid` (asynchronous read of the RAM at the read pointer) |
| `count` | out | `DEPTH_LOG2+1` | `clk` | Number of entries, `wp - rp` |

## 4. Behaviour

Pointers `wp`, `rp` of `DEPTH_LOG2+1` bits; the extra bit tells full from empty. A push writes `mem[wp]` and increments `wp` at the edge; a pop increments `rp`. A push and a pop in the same cycle are both done when both are possible. Entries come out in push order.

## 5. State machine

None (two counters and a RAM).

## 6. Latency and throughput

A push into an empty FIFO is visible on `out_valid`/`out_data` one cycle later (no bypass from `in_data` to `out_data`). One push and one pop per cycle sustained.

## 7. Corner cases and errors

- Full: `in_ready` = 0 even when a pop happens in the same cycle (no "push through when popping"). A user that needs a full-rate FIFO at depth N must size it N+1.
- Empty: `out_data` shows a stale entry; ignore it while `out_valid` = 0. A pop when empty is not done (`out_valid` = 0), so a broken user cannot underflow it.
- Reset does not clear `mem`; only the pointers.

## 8. What the TB checks

There is no `sim/tb/am_fifo_tb.v`. It is exercised through `am_axi_master_tb` (`PASS am_axi_master`: user bits of 2000 random requests come back in order, in the ZYBO and KC705 shapes) and every TB that contains `am_axi_master` (`atg_mc_tb`, `atg_top_tb`). Not checked on its own: full/empty with simultaneous push and pop, depths other than 4.

## 9. References

- design.md §7.3 (RTL rules), §4.1 (`am_axi_master`, outstanding 4 + 4).
- `docs/style.md`.
- Related specs: `spec/common/am_axi_master.md`, `spec/common/am_afifo.md` (the two-clock version).

## 10. Status

Implemented (70aaff5, p002; unchanged at a217bf8). 66 lines, 9 ports, no state machine, one clock domain: within U38. No difference between RTL and this spec. Residual: a unit TB of its own would be cheap if a later module relies on the full/empty corner cases.
