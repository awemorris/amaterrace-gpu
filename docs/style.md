RTL and script style
====================

The rules for this repository's Verilog, testbenches and scripts.

Verilog
-------

- Verilog-2005, the subset that Icarus Verilog (`-g2005`), Verilator
  (`--lint-only -Wall`) and Vivado all accept.  No SystemVerilog in
  `rtl/` or `boards/`.
- `timescale 1ns / 1ps` and `default_nettype none` at the top of each
  file, `default_nettype wire` at the end.
- One module per file, the file named after the module.  Prefixes:
  `atg_` for the GPU's blocks (`atg_cp`, `atg_blt`, `atg_mc`, ...), `am_`
  for shared parts (`am_fifo`, `am_afifo`, `am_axi_regs`, ...).
- Each file starts with the license header and a comment that says what
  the module does, its interfaces and their rules (who waits for whom,
  what is in order, what happens on error and under quiesce).
- ANSI port lists, one port per line, `input wire` / `output wire` /
  `output reg`.  Parameters with defaults; a parameter derived from
  another (`LINE_SHIFT = log2(LINE_BYTES)`) is passed explicitly.
- Synchronous resets, active low (`rst_n`), on every register that holds
  control state.  Clock domain crossings only through `am_sync` (single
  slow bits) and `am_afifo` (data).
- `always @(posedge clk)` with non-blocking assignments for registers,
  `always @(*)` with blocking assignments for combinational logic,
  `assign` for simple wires.  No latches.
- Valid/ready handshakes: a source does not drop valid or change its
  payload before ready.  Responses without ready are named as such.
- Vendor primitives (PS7, BUFG, MMCME2, BSCANE2, ...) only in `boards/`
  and `rtl/bsp/xilinx7/`.
- Register offsets and fields come from `include/ghci_regs.vh`, never as
  bare numbers.
- Lint clean: `tools/lint.sh` reports no warning.  An unavoidable warning
  (an unused bit of a bus, a constant truncated on purpose) is silenced
  locally: unused bits are collected in a wire named `unused_ok` (Verilator
  ignores names with "unused"), a deliberate truncation is wrapped in
  `verilator lint_off` / `lint_on` for that line only.
- Indentation with tabs; lines up to about 100 columns.

Arithmetic
----------

User decision (2026-10-25): every multiplier, divider, adder, subtractor
and shifter is a shared module of `rtl/library/arith/`, instantiated where it is
needed, so that a design has only the arithmetic it really needs and each
kind maps to the FPGA's best cell (a multiplier to DSP slices, an adder to
a carry chain) where it can be checked once.

- Signal arithmetic -- `+`, `-` (also unary), `*`, `/`, `%`, and a shift
  (`<<`, `>>`, `>>>`) by an amount that is a signal -- is written only
  inside the modules of `rtl/library/arith/`.  Every other module instantiates
  them:

  | Module | What | Cells (7 series) |
  | --- | --- | --- |
  | `am_add` | `{co, s} = a + b + ci` | CARRY4 chain |
  | `am_sub` | `d = a - b - bi`, borrow out | CARRY4 chain |
  | `am_addsub` | `a + b` or `a - b` chosen by `sub` | CARRY4 chain and the XOR of b |
  | `am_mul` | `a * b`, signed or unsigned, 0-n registers | DSP48E1 (`SYNTH_KINTEX7` cascade, generic otherwise) |
  | `am_div` | unsigned `a / b` and `a % b`, one bit per cycle | LUTs and a CARRY4 chain (one subtractor) |
  | `am_shift` | `a << n`, `a >> n`, `a >>> n` | LUTs (log2(W) levels of multiplexers) |

- `*` is written only in `am_mul.v` (generic `ifndef SYNTH_KINTEX7`).  Under `SYNTH_KINTEX7`,
  `am_mul.v` instantiates `DSP48E1` primitives directly with `PCOUT -> PCIN` cascade.
- Adders and shifters remain mapped to fabric (`CARRY4` and LUTs).
- Floating-point operators are unified in `rtl/library/fp/` (`am_fp_*`).
- Operations of one module that are never needed in the same cycle share
  one instance, with their operands selected in front of it.
- Not covered (constants, wiring): parameter and localparam expressions and
  any expression that is a constant after elaboration (a width, an index of
  a generate or for loop, a function called only with constants); a shift
  by a constant amount, and `*`, `/` or `%` by a constant power of two;
  testbenches and `sim/`.  The comparisons (`<`, `==`, ...) are not
  arithmetic in this rule.
- `tools/arith-lint.py` counts the signal arithmetic outside `rtl/library/arith/`
  in the elaborated design (Verilator); it reports 0 when the rule holds.
  A file that must keep its arithmetic is listed in the script's exception
  table with the reason, and here.

Board clocking
--------------

- Never make a clock by dividing in logic (a counter, a toggling flip-flop
  or anything else on fabric routing).  A clock of another rate comes from
  a PLL/MMCM output divider: those outputs ride the dedicated clock
  network (user, 2026-10-26).
- An IP block's clock inputs follow the vendor reference's input path.
  The KC705's MIG takes SYSCLK straight from the clock-capable pin's
  IBUFDS into its PLL, as the MIG's own input buffer does in the
  reference.  With a BUFG in front of the MIG's PLL the calibration
  depended on the build: the board's build failed every time, a build
  with the MIG's debug ports passed; with the direct path both builds
  (Debug on and off) calibrated 50 times out of 50 (ws288 p024).  The same IBUFDS may also drive a BUFG
  for the fabric's clock managers, and the MIG's IDELAYCTRL reference
  (clk_ref_i, which the MIG's own MMCM makes into 400 MHz) comes from
  that BUFG.  The PCIe bridge takes its reference from IBUFDS_GTE2.

Board builds
------------

- A board bitstream records the Vivado version and build (2026.1, SW
  Build 6511674 for the KC705 now), the strategy (Default unless the
  record says otherwise) and the commit it was built from.
- A board fault that goes away when debug cores or ports are added is a
  warning sign, not a fix: the netlist changed, so placement and routing
  changed.  Find the cause in the build without them.

Testbenches
-----------

- `sim/tb/NAME_tb.v` with top module `NAME_tb`; run by `sim/run.sh`.  A
  testbench prints `PASS NAME` at the end when it found no error and
  `FAIL ...` for each error; it has a timeout.
- Testbenches may use behavioural Verilog-2005 (tasks, `$random`,
  hierarchical references).  Shared models live in `sim/models/`, shared
  tasks in `sim/tb/*.vh`.
- Random tests take a seed and check against a reference model, not
  against values copied from a run.

Scripts
-------

- POSIX `sh` unless a tool needs bash (Vivado's `settings64.sh`).
- A comment at the top: what it does, usage, outputs, time limits.
- Outputs go to `build/` (ignored by git).  Vivado projects, IP output
  products and bitstreams are never committed.
- Every long run has a timeout.
