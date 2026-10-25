# atg_mc_cnt

RTL: `rtl/gpu/mc/atg_mc_cnt.v`.  Parent: `atg_mc` (instance `cnt`).  Split out of `atg_mc`
(2026-10-25).

## 1. Purpose and place

The MC's request counters.

## 2. Parameters

`NCLIENT`, `UNIT_MASK` (as atg_mc).

## 3. Ports

Domain `clk`.  12 ports: `clk`, `rst_n`, `flush`; per client `take` (valid and ready of its AMB
port), `take_chk` (its request has chk), `rsp` (its response); `done`, `done_chk` (a request left
the root, with chk); `pend_zero`, `chk_idle`, `unit_idle`.

## 4. Behaviour

- pend: requests taken by the leaves and not yet granted or refused (`axi_idle` needs 0).
- chk: those with chk (`chk_idle`; session protection's drain).
- unit: requests of `UNIT_MASK`'s clients without their response yet (`unit_idle`; the CP's
  FENCE, WAIT_IDLE, RESULT and QUERY wait for it).

## 5. State machine

None: three counters (8, 8 and 10 bits).

## 6. Latency and throughput

The counts change at the clock edge after the events.

## 7. Corner cases and errors

rst_n and flush clear them (flush comes when the MC is idle).

## 8. What the TB checks

`sim/tb/atg_mc_tb.v` checks `unit_idle` every cycle; `sim/tb/atg_mc_prot_tb.v` checks `chk_idle`.

## 9. References

`spec/gpu/mc/atg_mc.md`.

## 10. Status

Implemented.  About 80 lines.
