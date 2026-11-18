# am_afifo

RTL: `rtl/library/bus/am_afifo.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

An asynchronous first-word-fall-through FIFO of 2^`DEPTH_LOG2` entries of `W` bits between two clock domains: `gclk` and `mclk` when they differ (KC705 MIG), the PCIe `user_clk` and the JTAG clock (design §1.3). Pointers cross in Gray code through two flops each; storage is distributed RAM written in the write domain and read asynchronously in the read domain. Parent: none yet (planned in p012 between `gclk` and the KC705's MIG `ui_clk`, and in the PCIe/JTAG bridges). Children: none.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `W` | 8 | Entry width | ≥ 1 |
| `DEPTH_LOG2` | 3 | log2 of the number of entries | ≥ 2 (the full test uses pointer bits `P-1:P-2` and `P-3:0`, `P = DEPTH_LOG2+1`) |

## 3. Ports

| Name | Dir | Width | Domain | Meaning, handshake, timing |
| --- | --- | --- | --- | --- |
| `w_clk` | in | 1 | — | Write clock |
| `w_rst_n` | in | 1 | `w_clk` | Synchronous active-low reset of the write side (see §7) |
| `w_valid` | in | 1 | `w_clk` | Push request; a push in a cycle with `w_valid && w_ready` |
| `w_ready` | out | 1 | `w_clk` | "Not full", computed with the read pointer seen up to three `w_clk` cycles late (conservative: may say full when there is room, never the reverse) |
| `w_data` | in | `W` | `w_clk` | Entry written at the push |
| `r_clk` | in | 1 | — | Read clock |
| `r_rst_n` | in | 1 | `r_clk` | Synchronous active-low reset of the read side |
| `r_valid` | out | 1 | `r_clk` | "Not empty", with the write pointer seen late (conservative) |
| `r_ready` | in | 1 | `r_clk` | Pop request; a pop in a cycle with `r_valid && r_ready` |
| `r_data` | out | `W` | `r_clk` | The oldest entry while `r_valid` (asynchronous read of the RAM) |

## 4. Behaviour

Each side keeps a binary and a Gray pointer of `P = DEPTH_LOG2+1` bits and synchronises the other side's Gray pointer through two `ASYNC_REG` flops. Empty: read Gray pointer equals the synchronised write Gray pointer. Full: write Gray pointer equals the synchronised read Gray pointer with its two top bits inverted. The entry being read is stable: the write pointer that made it visible passed the synchroniser after the write.

## 5. State machine

None (two pointer pairs, two synchronisers, a RAM).

## 6. Latency and throughput

A word pushed at a `w_clk` edge becomes visible on `r_valid` after the Gray pointer update (1 `w_clk`) plus two to three `r_clk` edges. Each side can do one transfer per own cycle; with `DEPTH_LOG2` = 3 the round trip of about six cycles keeps a stream going in the TB.

## 7. Corner cases and errors

- Reset: both resets must be asserted together for at least three cycles of the slower clock, and the FIFO must be idle on both sides meanwhile. Resetting one side alone loses (or duplicates) the contents. The module does not check this.
- `w_ready` and `r_valid` are conservative (late), never optimistic.
- `r_data` is stale while `r_valid` = 0.
- No count output (a count across domains would not be exact).

## 8. What the TB checks

`sim/tb/am_afifo_tb.v` → `PASS am_afifo`: depth 8, 16-bit words; 3000 words with a 10 ns writer and a 7.3 ns reader (writer 90% valid, reader 30% ready: fills up), then 3000 more with the clock periods and pressures swapped; every word comes out once and in order, `w_ready` falls at least once (full seen), empty at the end. Seeds: `+seed` (p002 also ran `SEED=42`). Not checked: the reset protocol, depths other than 8, related (integer-ratio) clocks, metastability (not modelled by a simulator).

## 9. References

- design.md §1.3 (domains, `gclk` ≠ `mclk` on the KC705), §7.3.
- `docs/style.md` (CDC only through `am_sync` and `am_afifo`).
- Related specs: `spec/library/bus/am_fifo.md`, `spec/library/bus/am_sync.md`.

## 10. Status

Implemented (70aaff5, p002; unchanged at a217bf8). 111 lines, 10 ports, no state machine. It is one of the two allowed clock-domain crossings, so its two clocks are the intended exception to "one clock domain" in U38. No difference between RTL and this spec. Residual: first real use and a CDC timing constraint (`set_max_delay -datapath_only` on the Gray buses) come with the KC705 top in p012; the constraint is not written yet.
