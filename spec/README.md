Module specifications
=====================

One Markdown file per RTL module: `spec/<path>/<module>.md` mirrors `rtl/<path>/<module>.v`
(`rtl/gpu/su/atg_su_sb.v` ↔ `spec/gpu/su/atg_su_sb.md`); board tops are
`spec/boards/<board>/<top>.md`.  A spec says *what* a module does; WS288's design
(zedBSD `plan/ws288/design.md`) says *why* and how the whole fits.  When the RTL and its
spec disagree, the RTL is fixed (or the spec is changed first, with Q1's agreement); when
the design and a spec disagree, the design is fixed first.

How the tree was made (WS288 p023)
----------------------------------

The GPU was split top-down into modules.  Each module that did not exist got an empty
Verilog module with its parameters and full port list (every output tied to 0, every input
collected in `unused_ok`) and is instantiated and wired in its parent, so the whole tree
elaborates and `tools/lint.sh` checks the connections.  Blocks that a build does not have
are present in `atg_top` behind parameters (`HAS_CPU`, `NSU`, `HAS_VF`, ...; the defaults
are the smallest GPU: CP, BLT and MC).  In `atg_cp` and `atg_mc`, which already work, the new
children run beside the existing inline logic as a scaffold: they are wired to the real
inputs and their outputs feed only the new ports.  The implementation Phase moves the inline
logic into them.

Implementing a module: read its spec and its parent's spec, write the body of the `.v`, and
make `sim/tb/<module>_tb.v` print every `PASS` of §8.  Ports and parameters do not change
without a spec change proposed to Q1 first.

Rules (design §7.6, U38)
------------------------

- One module ≤ 400 lines of Verilog, one state machine, one clock domain (crossings only
  through `am_afifo`/`am_sync`), ≤ 40 ports.  A module that would exceed these is split.
- The line count leaves out the instances of the shared arithmetic modules of `rtl/library/arith/`
  (`am_add`, `am_sub`, `am_addsub`, `am_mul`, `am_div`, `am_shift`; docs/style.md,
  Arithmetic): the rest of the module stays within 400 lines (user, 2026-10-25).
- Counting ports: one standard AXI or AXI-Lite interface, one AMB client port (the 12
  `req_*`/`rsp_*` signals) and one HCR snoop port (`hcr_*`) each count as **one port group**
  (Q1, 2026-10-23).  A packed vector of N copies of a port (`c_req_valid[N-1:0]` ...) counts
  as that port.
- Exemption: **wiring modules** (no logic of their own beyond a few `assign`s that join or
  split buses: `atg_top`, `atg_cp`'s scaffold, `atg_cpu`, `atg_su`, `atg_vf`, `atg_rx`,
  `atg_tu`, `atg_rop`, `atg_dc`, the board tops) may exceed the port and line limits; their
  spec says so.  The limits are about the leaves that a single implementation session writes.
- A stub may switch off Verilator's unused-parameter warning around its parameter list when
  it has string parameters (file names) that it cannot reference; nothing else is switched
  off.

Template
--------

Every spec has these sections, in this order:

1. **Purpose and place** (1-3 sentences; parent and children).
2. **Parameters** (name, default, meaning, values).
3. **Ports**: name, direction, width, clock/reset domain, meaning, **handshake and timing**
   (valid/ready, one-cycle pulse, level, "read data the next cycle", ...).
4. **Behaviour** (inputs to outputs, ordering promises, relation to other modules).
5. **State machine** (roughly: the states and the conditions of the transitions, as
   "IDLE →(start)→ RUN →(done)→ IDLE").
6. **Latency and throughput** targets (cycles, work per cycle, clock target).
7. **Corner cases and errors** (empty/full, simultaneous requests, reset in the middle,
   aperture, EXEC = 0, ...).
8. **What the TB checks**: the `PASS <name>` lines of `sim/tb/<module>_tb.v`.
9. **References** (design §, other specs, "Values referenced:" for values from outside
   documents).
10. **Status**: empty / implemented (commit) / differences between the RTL and the spec.

Shared conventions
------------------

- **AMB client port** (design §4.1, `atg_mc`): `req_valid/ready`, `req_write`, `req_line`
  (address >> LINE_SHIFT), `req_be`, `req_wdata`, `req_tag[7:0]`; `rsp_valid` (one cycle, no
  back-pressure, one per request), `rsp_write`, `rsp_tag`, `rsp_rdata`, `rsp_error`.  A client
  that shares one MC port among several users puts them behind `am_amb_mux`.
- **HCR snoop port** (`atg_cp_regs`): `hcr_we/widx/wdata/wmask` for writes to 0x000-0xFFC and
  `hcr_ridx` for reads; each module takes the writes of its own registers and returns
  `hcr_rdata` for its own indices (0 otherwise; the parent ORs them).
- **STATE broadcast** (`atg_cp_state`): `st_we/st_idx/st_wdata`; a block keeps the words of its
  STATE range (design §2.3).  µop payloads go through the vendor STATE words 0x1E0-0x1EE
  (DRAW_RAW, DISPATCH, LOAD_CONST) followed by a one-cycle kick.
- **Fault report**: `fault` (pulse), `fault_kind[3:0]` (FAULT_INFO kind), `fault_addr`,
  `fault_tag` (JOB_TAG), collected by `atg_cp_ctl`.
- **SU micro-op** (`include/atg_su_uop.vh`): the decoded GSI1 instruction that travels from
  `atg_su_dec` to the execution units.
