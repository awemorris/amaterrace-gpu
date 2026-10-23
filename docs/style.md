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
  and `rtl/common/xilinx/`.
- Register offsets and fields come from `include/ghci_regs.vh`, never as
  bare numbers.
- Lint clean: `tools/lint.sh` reports no warning.  An unavoidable warning
  (an unused bit of a bus, a constant truncated on purpose) is silenced
  locally: unused bits are collected in a wire named `unused_ok` (Verilator
  ignores names with "unused"), a deliberate truncation is wrapped in
  `verilator lint_off` / `lint_on` for that line only.
- Indentation with tabs; lines up to about 100 columns.

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
