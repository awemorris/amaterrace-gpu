# atg_mc_cnt

RTL: `rtl/gpu/mc/atg_mc_cnt.v`.  Parent: `atg_mc` (instance `cnt`).  Split out of `atg_mc`
(2026-10-25).

## 1. Purpose and place

The MC's request counters.

## 2. Parameters

`NCLIENT`, `UNIT_MASK` (as atg_mc); `KEEP_MASK` (0): the clients `pend` does not count (atg_mc's
`ROOT_KEEP` client, the DC).

## 3. Ports

Domain `clk`.  16 ports: `clk`, `rst_n`, `flush`; per client `take` (valid and ready of its AMB
port), `take_chk` (its request has chk), `rsp` (its response); `done`, `done_chk` (a request left
the root, with chk), `done_keep` (that request was a `KEEP_MASK` client's); `ax_inc` (the root
granted a request to the AXI master), `ax_dec` (the AXI master answered one); `pend_zero`,
`chk_idle`, `unit_idle`, `ax_zero`.

## 4. Behaviour

- pend: requests taken by the leaves and not yet granted or refused (`axi_idle` needs 0).
- chk: those with chk (`chk_idle`; session protection's drain).
- unit: requests of `UNIT_MASK`'s clients without their response yet (`unit_idle`; the CP's
  FENCE, WAIT_IDLE, RESULT and QUERY wait for it).
- ax: requests in the AXI master (`ax_zero`; atg_mc's `axi_idle` with `ROOT_KEEP`, where the
  caller leaves the DC's grants and responses out).  One `am_add`: n + {8{dec}} + inc.

## 5. State machine

None: four counters (8, 8, 10 and 8 bits).

## 6. Latency and throughput

The counts change at the clock edge after the events.

## 7. Corner cases and errors

rst_n and flush clear pend, chk and unit (flush comes when the MC is idle); ax only rst_n: flush
does not empty the AXI master.

## 8. What the TB checks

`sim/tb/atg_mc_tb.v` checks `unit_idle` every cycle; `sim/tb/atg_mc_prot_tb.v` checks `chk_idle`.

## 9. References

`spec/gpu/mc/atg_mc.md`.

## 10. Status

Implemented.  About 80 lines.  `KEEP_MASK` and ax (WS288 p035 D2b, 2026-10-25).
