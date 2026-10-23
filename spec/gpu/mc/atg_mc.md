# atg_mc

RTL: `rtl/gpu/mc/atg_mc.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

The memory controller: `NCLIENT` blocks share one AXI master through the Amaterrace memory bus (AMB), a line-wide request/response port per client. It arbitrates, checks every request against the aperture, routes responses back, and implements quiesce/flush toward the CP. Parent: `atg_top` (instance `mc`; client 0 = CP, client 1 = BLT, `HIGH_MASK` = 01). Children: `am_axi_master` (instance `axi`). The planned split (design §7.6) is `atg_mc_arb`, `atg_mc_aper`, `atg_mc_atom` and `atg_mc` as wiring; today all of it is in this module.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `NCLIENT` | 2 | Number of AMB clients | 1..32 (design §4.1; `fault_client` is 8 bits, the client number must fit in the 8-bit user field) |
| `HIGH_MASK` | 0 | Clients with fixed priority (lowest number first) over the others | `atg_top`: 2'b01 (the CP) |
| `ADDR_W` | 32 | Address width | 32 |
| `LINE_BYTES` | 32 | Line size | 32, 64 |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |
| `DATA_W` | 64 | AXI data width | 64, 512 |
| `OUTSTANDING_LOG2` | 2 | Passed to `am_axi_master` | 2 |

## 3. Ports

Client vectors are packed, client 0 in the low bits. Domain `clk` for all.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (board reset; **not** the CP's core reset) |
| `c_req_valid` / `c_req_ready` | in / out | `NCLIENT` | Per-client request handshake. At most one `c_req_ready` bit is 1 per cycle (the grant), combinational from this cycle's valids. A client must hold valid and payload until ready |
| `c_req_write` | in | `NCLIENT` | 1 write, 0 read |
| `c_req_line` | in | `NCLIENT*(ADDR_W-LINE_SHIFT)` | Line address |
| `c_req_be` | in | `NCLIENT*LINE_BYTES` | Write byte enables |
| `c_req_wdata` | in | `NCLIENT*LINE_BYTES*8` | Write data |
| `c_req_tag` | in | `NCLIENT*8` | Client's tag, returned on `rsp_tag` |
| `rsp_valid` | out | `NCLIENT` | One-hot one-cycle pulse to the answered client; **no back-pressure** |
| `rsp_write`, `rsp_tag`, `rsp_rdata`, `rsp_error` | out | 1, 8, `LINE_BYTES*8`, 1 | Shared response fields, valid with `rsp_valid` |
| `quiesce` | in | 1 | Level from the CP: nothing new is granted |
| `flush` | in | 1 | One-cycle pulse (with `quiesce` held): returns the arbiter and the refusal/fault registers to reset |
| `aperture_base`, `aperture_limit` | in | `ADDR_W` | Allowed range [base, limit) in bytes; low `LINE_SHIFT` bits ignored |
| `axi_idle` | out | 1 | Level: `am_axi_master.idle` and no refusal response pending |
| `fault` | out (reg) | 1 | One-cycle pulse when a request was refused (outside the aperture) |
| `fault_client`, `fault_addr`, `fault_write` | out (reg) | 8, `ADDR_W`, 1 | The refused request's client, byte address (line-aligned) and direction; held until the next refusal or flush |
| `m_*` | — | — | The AXI master ports of `am_axi_master`, passed through (29 signals; see `spec/common/am_axi_master.md`) |

## 4. Behaviour

- Selection (combinational): the lowest-numbered client in `HIGH_MASK` with valid; else round-robin among the others, starting at `rr_next`. `rr_next` moves to the client after the granted one when a non-high client is granted.
- Grant: `may_grant = sel_any && !quiesce && !err_v`. Inside the aperture the request is passed to `am_axi_master` and granted when it is ready (`grant_ok`). Outside, it is granted at once without reaching AXI (`grant_bad`): next cycle `err_v` holds the refusal and `fault` pulses with client, address, direction.
- Responses: the AXI master's response first; a pending refusal goes out in the first cycle without one (`err_out`, `rsp_error` = 1, `rsp_tag` the refused tag, `rsp_write` its direction). While `err_v` nothing is granted.
- Order per client: reads in order, writes in order (inherited from `am_axi_master`); a read is not ordered after an earlier write — a client that reads what it wrote waits for the write's response first. **A refusal's error response may overtake the client's earlier requests' responses** (the CP treats it as a device fault).
- `flush` resets the arbiter state; the MC has no queue of its own, outstanding AXI bursts stay in `am_axi_master` until answered.

## 5. State machine

No encoded FSM. State: `rr_next` (round-robin pointer) and the refusal register `err_v`: none →(`grant_bad`)→ refusal pending →(`err_out`)→ none. `flush`/`rst_n` → none.

## 6. Latency and throughput

- 0 added cycles on the request path: selection, aperture check and grant are combinational into `am_axi_master`'s request port (this is the critical path at 100 MHz on the ZYBO: BLT `q_valid` → arbiter → AXI master `w_buf` enable, WNS +0.190 ns in p003).
- One grant per cycle at most; the AXI master's own limits apply (one write line per `BEATS+1` cycles, one AR per 2 cycles).
- Refusal: `fault` 1 cycle after the grant, error response 1 cycle after the grant at the earliest.

## 7. Corner cases and errors

- Aperture outside (including an empty aperture, the reset value base = limit = 0): refused, error response, fault pulse. The CP ignores faults of client 0 (its debug port: DBG_STATUS.error only).
- Two refusals: the second waits (`err_v` blocks grants) until the first's response is out.
- Under `quiesce` a client's request just waits; `axi_idle` comes when every granted request is answered.
- **The CP's exception (WS288 p004):** atg_cp lowers `quiesce` while its client 0 has a request valid. Since client 0 is in `HIGH_MASK`, the selection then offers only client 0, so the CP's own requests (the debug port in HALTED and FAULTED, a ring line or fence already requested) are granted while the blocks stay frozen. `HIGH_MASK` must keep client 0 alone at the top for this.
- `rsp_rdata` of a refusal is the AXI master's last read data (meaningless).
- Atomics (ATOM port, design §4.1) are not implemented.

## 8. What the TB checks

`sim/tb/atg_mc_tb.v` → `PASS atg_mc`: three clients (0 fixed priority, 1 and 2 round-robin) × 600 random reads and byte-masked writes on their own lines against one `axi_mem`; data against a reference, tags in order per direction; about 1/40 of requests outside the aperture get an error response without reaching AXI, and the fault pulse names client, line and direction; random quiesce: no grant under it, `axi_idle` within a bound; never two grants in one cycle; every client granted; fault count = refused count. Seeds: `+seed` (p003 also 3, 42). Also covered by `atg_top_tb` and the Verilator harness. Not checked: `flush` alone (only through the CP's RESET in `atg_top_tb`), `NCLIENT` > 3, starvation bounds.

## 9. References

- design.md §4.1 (AMB, client count, priority groups, aperture), §1.3 (quiesce, flush, AXI_IDLE counts only GPU clients), §3.6 (MC 0.17k LUT measured in p002).
- `docs/ghci.md` §7 (faults, quiesce), §13 (memory model, aperture).
- Related specs: `spec/common/am_axi_master.md`, `spec/gpu/cp/atg_cp.md`, `spec/gpu/top/atg_top.md`.

## 10. Status

Implemented (70aaff5, p002; overtaking note 655f1f2; unchanged at a217bf8). 279 lines, no FSM, one clock. **U38: 52 ports > 40** (29 of them the AXI master interface). Proposed split (design §7.6, not done here): `atg_mc_arb` (selection, `rr_next`, grant vector; about 80 lines, ports: valids, ready, `HIGH_MASK`, quiesce, select), `atg_mc_aper` (line range check and the refusal/fault register; about 70 lines), `atg_mc_atom` (later, SU), and `atg_mc` as wiring with the AXI ports — which still exceeds 40 unless the AXI interface counts as one group (same decision as `am_axi_master`). Differences from design.md §4.1: priority groups are a single `HIGH_MASK` level (design: three groups DC / CP fence+ROP / round-robin); no atomic port; the response carries no `write` in design's list but the RTL has `rsp_write`. Measured on the ZYBO (p003): 173 LUT including the AXI master (156), 853 FF.

**WS288 p023 (P1)**: a scaffold at the end of the RTL instantiates `atg_mc_arb` and
`atg_mc_aper` (stubs, spec/gpu/mc/) with the real signals; the inline arbiter and aperture check
still decide.  The atomic unit `atg_mc_atom` is a separate MC client placed in `atg_top` (it
needs its own AMB port for the read-modify-write), not a child of this module.
