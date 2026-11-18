# am_sync

RTL: `rtl/library/bus/am_sync.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

A two-flop synchroniser for `W` independent, slowly changing level signals (resets, enables, status bits) entering the `clk` domain. A bus whose bits must arrive together does not use it (use `am_afifo` or a handshake). Parent: any block that takes a level signal from another clock domain (design §1.3: the reset releases of each domain, `tck` → `gclk` on the KC705). Children: none. Today no module of the tree instantiates it.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `W` | 1 | Number of independent bits | ≥ 1 |
| `RESET_VALUE` | all 0 | Value of `q` (and both flops) while `rst_n` = 0 | any `W`-bit value |

## 3. Ports

| Name | Dir | Width | Domain | Meaning, handshake, timing |
| --- | --- | --- | --- | --- |
| `clk` | in | 1 | — | Destination clock |
| `rst_n` | in | 1 | `clk` | Synchronous, active low. While 0 both flops hold `RESET_VALUE` |
| `d` | in | `W` | any (asynchronous) | Level inputs. Each bit is sampled on its own; no relation between bits is kept |
| `q` | out | `W` | `clk` | `d` two `clk` edges later (the second flop) |

## 4. Behaviour

`s1 <= d; s2 <= s1; q = s2` on every rising edge of `clk`; both flops carry `ASYNC_REG = "TRUE"` so that Vivado places them together. A change of `d` appears on `q` after two or three edges, depending on where it falls relative to the edge. No glitch filtering, no pulse stretching: a pulse on `d` shorter than one `clk` period may be lost.

## 5. State machine

None (two registers per bit).

## 6. Latency and throughput

2 `clk` cycles (up to 3 counting the sampling uncertainty). Meant for signals that stay stable for many cycles.

## 7. Corner cases and errors

- Bits of `d` that change together may appear on `q` in different cycles (one bit can resolve one cycle later than another).
- A pulse on `d` shorter than a `clk` period may be missed; a short pulse needs a toggle or a handshake.
- During `rst_n` = 0 `q` is `RESET_VALUE` whatever `d` is.

## 8. What the TB checks

There is no `sim/tb/am_sync_tb.v`. The module is only linted (`tools/lint.sh`, `am_sync` as its own top: clean). Not checked: anything about its timing; no user instantiates it yet.

## 9. References

- design.md §1.3 (clock domains and reset releases), §7.3 (CDC only through `am_sync` and `am_afifo`).
- `docs/style.md` (Verilog rules, CDC).
- Related specs: `spec/library/bus/am_afifo.md`.

## 10. Status

Implemented (amaterrace-gpu 70aaff5, WS288 p002; unchanged at a217bf8). 43 lines, 4 ports, no state machine, one clock domain: within U38. No difference between RTL and this spec.
