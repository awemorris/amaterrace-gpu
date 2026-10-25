# atg_rx_f2fix

RTL: `rtl/gpu/rx/atg_rx_f2fix.v`.  Parent: atg_rx_edge (the snap of the window coordinates and of the viewport's rectangle).

## 1. Purpose and place

fp32 to 15.8 fixed point, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the function `f2fix` of atg_rx_edge.

## 2. Parameters

None.

## 3. Ports

`f` (32, fp32) / `q` (24, two's complement 15.8): 2 ports.

## 4. Behaviour

NaN and values with an exponent below 94 give 0; |f| ≥ 2^15 (exponent ≥ 142) or a rounded magnitude above 2^22 − 1 saturates to ±(2^22 − 1); else RNE(|f| × 2^8) with f's sign: 1.f shifted right by 142 − e (am_sub, am_shift), rounded (am_add), negated for a negative value (am_addsub).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_rx_setup_tb.v` (through atg_rx_setup and atg_rx_edge); atg_rx_edge's former and new versions compared on 300,000 random cycles (2026-10-25).

## 9. References

`spec/gpu/rx/atg_rx_edge.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
