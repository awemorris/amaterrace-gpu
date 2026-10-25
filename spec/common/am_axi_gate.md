# am_axi_gate

RTL: `rtl/common/am_axi_gate.v`.  Parent: atg_kc705_raster (the PCIe BAR2 path to the MIG's second port).  Children: four `am_add` (the write count, the W lead, the read count, the closed read's beat).  Written in WS288 p040 (2026-10-25; the user's decision of that day: the MEM capability's window enable bit, GHCI §11.1).

## 1. Purpose and place

An AXI4 path that a level input opens and closes.  Open, the transactions go from `s_*` to `m_*` unchanged; closed, they are answered here and `m_*` sees nothing (a write is dropped with OKAY, a read returns zeros with OKAY).  Vendor-free; the data width, the IDs and the clock are not changed.  On the KC705 it sits between the PCIe bridge's BAR2 master and the MIG's second port, with `en` = the GPU's WINDOW_CTRL.ENABLE (atg_top `win_en`, synchronised to user_clk by `am_sync`).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `A_W` | 32 | Address bits | |
| `D_W` | 128 | Data bits | 8 or more (8-bit strobes) |
| `ID_W` | 4 | ID bits | |
| `CNT_W` | 4 | Transactions in flight per direction < 2^CNT_W (open); the W lead is CNT_W + 1 bits, two's complement | ≥ 2 |
| `OPEN_AT_RESET` | 1 | The mode of both directions after `rst_n` | 0, 1 |

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | One clock; synchronous active-low reset (the master and the slave are reset with it) |
| `en` | in | 1 | 1 open, 0 closed; synchronous to `clk` (a level from another clock goes through `am_sync` first) |
| `s_*` | | | AXI4 slave: AW {id, addr, len, size, burst}, W {data, strb, last}, B {id, resp}, AR (as AW), R {id, data, resp, last} |
| `m_*` | | | AXI4 master, the same fields |

3 ports and 2 AXI groups.  No AxCACHE, AxPROT, AxLOCK, AxQOS, AxREGION, user signals.

## 4. Behaviour

- **Modes.** Each direction (write, read) has its own mode, open or closed.  It follows `en` only while that direction is idle: no transaction in flight (taken, response not given back), no AW/AR or W offered on `m_*` and not yet taken, no W burst begun ahead of its AW.  A request that finds the mode different from `en` waits (`s_awready`/`s_arready` 0) until the earlier ones are answered and the mode has changed; so the responses of the one mode never pass those of the other, and the slave never sees a part of a transaction.
- **Open.** AW, W, B, AR and R pass through combinationally.  While `en` has fallen and the mode is still open (transactions in flight), an AW still goes on if its beats already went on before it, and a valid already offered on `m_*` is kept until taken (AXI); no new AW, AR or W burst begins.  W may go before its AW while `en` is 1 (a slave may wait for WVALID before AWREADY).
- **Closed.** One transaction per direction at a time: an AW is taken, then its beats, then B OKAY with its ID after WLAST.  An AR is taken and answered with AxLEN + 1 beats of zeros, OKAY, its ID, RLAST on the last.  `m_*` stays idle.  W is not taken before its AW.
- B and R keep their payload while not ready (open: the slave's; closed: registered).

## 5. State machine

Per direction: the mode bit; the write side's count of transactions in flight, the W lead (bursts begun less AWs taken), the burst-in-progress bit, the hold bits of AW and W, the closed write's ID and B-pending bit; the read side's count, the hold bit of AR, the closed read's ID, AxLEN, beat count and busy bit.

## 6. Latency and throughput

Open: no added cycle; up to 2^CNT_W − 1 transactions per direction in flight.  Closed: a write takes AW, its beats and B (one per cycle each); a read one beat per cycle.  A mode change waits for the round trips in flight.

## 7. Corner cases and errors

- `en` going up and down while traffic flows: each transaction is wholly open or wholly closed (the mode at its AW/AR).
- A master that keeps more than 2^CNT_W W bursts ahead of its AWs overflows the lead (not checked).
- Open, the responses are the slave's (any RESP); closed, always OKAY.

## 8. What the TB checks

`sim/tb/am_axi_gate_tb.v` → `PASS am_axi_gate`: two shapes (a slow slave; a fast slave that waits for WVALID before AWREADY), 1500 writes and 1500 reads each with 4 IDs, 1-4 beats, W sometimes before its AW, random B/R ready, `en` up or down for 20-400 cycles at a time (`sim/models/axi_id_slave.v`).  Checked: open bursts reach the slave with their data (the slave checks data and WLAST, and AW/AR/W stable while not ready), closed ones do not (the slave's AWs, ARs and W beats against the open ones), responses in request order with the request's ID and OKAY, closed reads all zeros with RLAST on beat AxLEN, open reads the slave's data, B/R stable while not ready, a mode changes only with nothing in flight, both modes used in both directions, W not taken before its AW while closed.  Mutation (iverilog `-D`): `MUT_GATE_NOWAIT` (the mode follows `en` at once) fails (the slave's write-data errors and the response checks).  The axi_id_slave model does not take W before its AW, so the open W-ahead path (the lead counter) is exercised only as offered, not as taken.  Also through `sim/tb/atg_kc705_pcie_tb.v` (`PASS atg_kc705_pcie.window`).

## 9. References

docs/ghci.md §11.1 (the local window, WINDOW_CTRL), §11.3 (the MEM capability), `spec/boards/kc705/atg_kc705_raster.md`, `spec/common/am_sync.md`, `spec/common/am_add.md`.  AXI4: VALID kept until READY, W before or after AW, same-ID ordering.
