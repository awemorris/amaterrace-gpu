# atg_mc_asm

RTL: `rtl/gpu/mc/atg_mc_asm.v`.  Parent: `atg_mc` (instances `asm_a`, the tree's, and `asm_d`,
the DC's own entry with session protection).  Split out of `atg_mc` (2026-10-25).

## 1. Purpose and place

An assembly buffer of the MC's root: one request, assembled from its header flit and, for a
write, its data flit.

## 2. Parameters

`LINE_BYTES` (32): the flit width is a line.

## 3. Ports

Domain `clk`.  11 ports: `clk`, `rst_n`, `flush`; from the tree `t_valid` / `t_ready`, `t_data`,
`t_last`; to the grant `full`, `head`, `data` (held) / `take`.

## 4. Behaviour

A flit is taken when the buffer is empty or its request is taken in the same cycle.  A header
with `t_last` (a read) completes the request; a write's header waits for its data flit.

## 5. State machine

empty → (read header) full; empty → (write header) header → (data) full; full → (take) empty.

## 6. Latency and throughput

No added cycle: a request taken every cycle reads one per cycle, writes one per two.

## 7. Corner cases and errors

rst_n and flush empty it.

## 8. What the TB checks

Through `sim/tb/atg_mc_tb.v` and `sim/tb/atg_mc_prot_tb.v`.

## 9. References

`spec/gpu/mc/atg_mc.md`.

## 10. Status

Implemented.  About 60 lines.
