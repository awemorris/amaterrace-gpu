# am_mul

RTL: `rtl/library/arith/am_mul.v`. Written for the shared arithmetic (docs/style.md, "Arithmetic", 2026-10-25).

## 1. Purpose and place

An AW x BW multiplier for DSP48E1 slices: `p = a * b`, both signed (`SIGNED = 1`, two's complement) or both unsigned, the full AW + BW bits.
In generic / simulation mode (`ifndef SYNTH_KINTEX7`), written with standard Verilog `*` and pipeline registers.
Under `SYNTH_KINTEX7`, fully implemented using `DSP48E1` primitive instantiations and `PCOUT -> PCIN` cascade across all operand widths.

## 2. Parameters

- `AW` (16): input `a` bit width.
- `BW` (16): input `b` bit width.
- `SIGNED` (0): 1 if signed, 0 if unsigned.
- `LAT` (0): pipeline latency (0 to 3 cycles).

## 3. Ports

- `clk`: clock
- `rst_n`: active-low reset
- `en`: stage enable
- `a` [AW-1:0]: operand a
- `b` [BW-1:0]: operand b
- `p` [AW+BW-1:0]: product output

## 4. Behaviour

`p = a * b` after `LAT` cycles enabled by `en`.

## 5. Latency and throughput

Throughput is 1 operation per cycle. Latency is `LAT` cycles.
