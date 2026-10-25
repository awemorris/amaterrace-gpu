# atg_rx_i2f

RTL: `rtl/gpu/rx/atg_rx_i2f.v`.  Parents: atg_rx_bary (W 21, F 3: the lane's i and j in eighths), atg_rx_scan (W 17, F 0: i, j of the depth plane), atg_rx_frag (W 17, F 0: 2 x + 1, 2 y + 1).

## 1. Purpose and place

A small signed integer over 2^F to fp32, exact, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the functions `i2f8` (atg_rx_bary) and `i2f` (atg_rx_scan, atg_rx_frag).

## 2. Parameters

`W` (17, the input bits, sign included, at most 23), `F` (0, the fraction bits of the input).

## 3. Ports

`v` (W) / `f` (32): 2 ports.

## 4. Behaviour

0 gives +0.  Else the sign of v, |v| (am_addsub) normalised to bit W − 1 (am_shift by the leading zeros lz), the exponent 127 + W − 1 − F − lz (am_sub), the bits below the leading one as the fraction.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

v = −2^(W−1) is outside the range (|v| does not fit); the callers never give it.

## 8. What the TB checks

`sim/tb/atg_rx_scan_tb.v`, `sim/tb/atg_rx_frag_tb.v` (through their parents); the parents' former and new versions compared on 200,000 random cycles (2026-10-25).

## 9. References

`spec/gpu/rx/atg_rx_bary.md`, `spec/gpu/rx/atg_rx_scan.md`, `spec/gpu/rx/atg_rx_frag.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25).
