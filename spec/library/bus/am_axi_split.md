# am_axi_split

RTL: `rtl/library/bus/am_axi_split.v`.  Parent: atg_kc705_top (the GPU's memory port to the DDR3 and to the host).  Children: two `am_axi_idtrack` (`wtr`, `rtr`), two `am_fifo` (`wq`, `eb`), two `am_arb3` (`barb`, `rarb`), one `am_sub`.  Written in WS288 p039 (2026-10-25; the user's decision of that day: a generic part, not KC705's, that sends one AXI to two).

## 1. Purpose and place

One AXI4 slave to two AXI4 masters by address: a burst whose start address is in range 0 goes to `m0_*`, else one in range 1 to `m1_*`, any other is answered here with DECERR.  Vendor-free; the data width, the IDs and the clock pass unchanged (a width or clock change is the user's, around it).  On the KC705 the MC's port is split into the MIG's GPU port (local memory) and the PCIe bridge's AXI -> PCIe port (the host).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `A_W` | 32 | Address bits | |
| `D_W` | 64 | Data bits | 32 or more (8-bit strobes) |
| `ID_W` | 1 | ID bits (2^ID_W IDs are tracked) | small (each ID has its counters) |
| `BASE0`, `SIZE0` | 0, 0 | Range 0: [BASE0, BASE0 + SIZE0); SIZE0 = 0: none | 4 KiB aligned |
| `BASE1`, `SIZE1` | 0, 0 | Range 1, tried after range 0 | 4 KiB aligned |
| `CNT_W` | 3 | Transactions in flight per ID and direction < 2^CNT_W | ≥ 1 |
| `WQ_LOG2` | 2 | log2 of the AWs whose beats are owed (and of the DECERR writes waiting for their B) | ≥ 1 |

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | One clock; synchronous active-low reset (the slaves are reset with it: a reset with bursts in flight breaks AXI) |
| `s_*` | | | AXI4 slave: AW {id, addr, len, size, burst, cache, prot}, W {data, strb, last}, B {id, resp}, AR (as AW), R {id, data, resp, last} |
| `m0_*`, `m1_*` | | | AXI4 masters, the same fields |

5 ports and 3 AXI groups.  No AxLOCK, AxQOS, AxREGION, user signals.

## 4. Behaviour

- **Routing** by the burst's start address (range 0 first).  A burst must stay inside its range: with ranges on 4 KiB boundaries this is AXI's own rule.
- **Order per ID (AXI)**: all transactions of one ID and direction in flight go to one destination (m0, m1 or the DECERR responder).  A request whose ID has transactions in flight elsewhere is not taken (`s_awready`/`s_arready` 0) until they are answered; so each ID's responses come back in request order.  Writes and reads are tracked separately.
- **AW and AR** each pass through a register stage, taken from `s_*` when the stage is empty or leaving in that cycle; the stage holds valid and payload until its master takes it.
- **W** follows the AWs' order: taking an AW from `s_*` puts its destination in `wq`; the beats go there, also before that master took the AW (AXI allows a slave to wait for WVALID before AWREADY).  A write's beats are not taken before its AW was taken from `s_*`.
- **DECERR**: a write outside both ranges takes its beats and, after WLAST, answers B with DECERR (queue `eb`); a read outside answers AxLEN + 1 beats of zeros with DECERR and RLAST on the last (one such read at a time).
- **Responses**: B from m0, m1 and the DECERR queue, in turn (`am_arb3`); R one burst at a time, the source kept from its first beat to its RLAST, so the R bursts on `s_*` never interleave.  B and R keep their payload while not ready.

## 5. State machine

None encoded: the two stages (empty / full), the DECERR read (idle / answering, `er_left` beats to go), the per-ID counters and the two arbiters' hold (`am_arb3`).

## 6. Latency and throughput

AW/AR: one cycle (the stage); a new one each cycle while the masters take them.  W, B, R: combinational (no added cycle).  A request of an ID that switches destination waits for the round trip of the earlier ones.

## 7. Corner cases and errors

- A full per-ID counter (2^CNT_W − 1 in flight) or a full `wq` holds the next request.
- A response from a master with an ID that has nothing in flight (a broken slave) is passed on; the counter is not decremented below its value only if the slave is right (not checked here).
- Two ranges that overlap: range 0 wins.

## 8. What the TB checks

`sim/tb/am_axi_split_tb.v` → `PASS am_axi_split`: two shapes (slave 0 slow and slave 1 fast; slave 1 waiting for WVALID before AWREADY), 1500 writes and 1500 reads each with 4 IDs, random destinations (both ranges and DECERR), 1-4 beats, W sometimes before its AW, random ready on all sides (`sim/models/axi_id_slave.v`).  Checked: each burst reaches the right slave with its data (the slaves check the write data and WLAST), responses per ID in order with the right RESP and data (zeros with DECERR), no R interleaving, RLAST, B/R stable while not ready, all answered.  Mutations (iverilog `-D`): `MUT_SPLIT_NOWAIT` (no per-ID wait) fails the order check, `MUT_SPLIT_NOHOLD` (R source not kept) fails the interleaving check, `MUT_SPLIT_WAFTER` (W only after the master took the AW) deadlocks against the slave that waits for W (timeout).  Also through `sim/tb/atg_mc_tb.v` (case D: the MC's two destinations) and the KC705 board testbenches.

## 9. References

docs/ghci.md §11.2 (local and host addresses), `spec/gpu/mc/atg_mc.md` (the MC's IDs per destination), `spec/library/bus/am_axi_idtrack.md`, `spec/library/bus/am_arb3.md`, `spec/library/bus/am_fifo.md`.  AXI4: same-ID ordering, W after or before AW, no write interleaving.

## 10. Status

Implemented (2026-10-25, p039).  Not synthesised yet.
