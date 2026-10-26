# atg_mc

RTL: `rtl/gpu/mc/atg_mc.v`.  First written from the RTL at a217bf8 (WS288 p023 part 2, P2);
rewritten for the router tree (WS288 p023 milestone 4, P1, 2026-10-23).  The RTL is
authoritative.

## 1. Purpose and place

The memory controller: `NCLIENT` blocks share one AXI master through the Amaterrace memory bus
(AMB), a line-wide request/response port per client.  The clients reach the root through a tree
of 2-way routers (user, 2026-10-23: 「2分岐くらいのルーター（RT）を配置できませんか？N乗の規模の
セレクタを入れるよりも合成しやすく、ASICでもルーティングしやすいからです。」「ルートがMCで、DCが根元に
あって優先される必要がありますね。」).  The root assembles each request, checks it against the
aperture and the VRAM window, gives it to the AXI master or refuses it, and sends the responses
back down the tree.  Parent: `atg_top` (instance `mc`).  Children: `atg_mc_tree` (the leaves and
routers), `atg_mc_asm` (the root's assembly buffers), `atg_mc_prot` (the grant: the aperture check and,
with `HAS_PROT`, session protection), `atg_mc_cnt` (the request counters), `am_axi_master`.  The atomic unit `atg_mc_atom` is
a client of its own in `atg_top`.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `NCLIENT` | 2 | AMB clients | 2..32 (`fault_client` is 8 bits) |
| `HIGH_MASK` | 0 | Clients that send with the priority bit | `atg_top`: the CP and the outside client (DC) |
| `QUIESCE_EXEMPT` | 0 | Clients whose leaves `quiesce` does not hold (WS288 p004) | `atg_top`: the CP (client 0) and, with `HAS_DISP`, the DC (`C_DC`) |
| `ROOT_CLIENT` | -1 | The client placed one hop from the root (child 0 of the top router); -1: none | `atg_top`: `C_EXT` with `EXT_CLIENT` or `C_DC` with `HAS_DISP` (the KC705's DC) |
| `ROOT_KEEP` | 0 | With `ROOT_CLIENT`: that client has its own entry at the root (as with `HAS_PROT`), `flush` does not empty its leaf, its entry or its refusal's response, and `axi_idle` does not wait for its requests (design §18.2) | `atg_top`: 1 with `HAS_DISP` |
| `ADDR_W` | 32 | Address width | 32 |
| `LINE_BYTES` | 32 | Line size | 32, 64 |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |
| `DATA_W` | 64 | AXI data width | 64, 512 |
| `OUTSTANDING_LOG2` | 2 | Passed to `am_axi_master` | 2 |
| `VRAM_AW` | 32 | Address bits carried in the tree (the VRAM window is 2^VRAM_AW bytes) | `LINE_SHIFT` < `VRAM_AW` ≤ 32; 64 MiB: 26 |
| `VRAM_BASE` | 0 | The window's base, aligned to its size; the root adds it | e.g. 0x1C000000 |
| `LOCAL_BASE`, `LOCAL_BYTES` | 0, 0 | Local memory (the MEM capability, docs/ghci.md §11.2): its accesses go out with AXI ID 0, all others (host) with ID 1; `LOCAL_BYTES` 0: one ID, 0 | KC705: 0x8000_0000, 1 GiB |
| `UNIT_MASK` | 0 | Clients that `unit_idle` counts | `atg_top`: all but the CP and the DC |
| `HAS_PROT` | 0 | Session protection (docs/ghci.md §11.6, `atg_mc_prot`) | 0, 1 |
| `RMW_MASK` | 0 | Clients whose reads are judged as writes | `atg_top`: the atomic unit |
| `PROT_PLB`, `PROT_PLB_W`, `PROT_GRANTS`, `PROT_GIDX_W` | 4, 2, 8, 3 | PLB lines, grant entries, and their clog2 | KC705 16, 4, 64, 6 |

Derived (localparams): `HAS_ROOT`, `TREE_L` = clog2(`NCLIENT` − `HAS_ROOT`), `RW` (route bits) =
max(1, `TREE_L` + `HAS_ROOT`), the header layout of `spec/library/bus/am_amb_to_rt.md`.

## 3. Ports

Client vectors are packed, client 0 in the low bits.  Domain `clk` for all.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (board reset, not the CP's core reset) |
| `c_req_valid` / `c_req_ready` | in / out | `NCLIENT` | Per-client request handshake (the client's leaf takes it when its last flit enters the tree; several clients can be taken in one cycle).  Hold valid and payload until ready |
| `c_req_write`, `c_req_line`, `c_req_be`, `c_req_wdata`, `c_req_tag` | in | per client | The request (as before) |
| `c_req_chk`, `c_req_tbl`, `c_req_slot` | in | per client 1, 1, 6 | Session protection: check the request for the slot; a write of the protection table.  Held with the request.  Ignored without `HAS_PROT` |
| `rsp_valid` | out | `NCLIENT` | One-cycle pulse to the answered client; no back-pressure.  Several clients may get a response in the same cycle |
| `rsp_write`, `rsp_tag`, `rsp_rdata`, `rsp_error` | out | `NCLIENT` × 1, 8, `LINE_BYTES*8`, 1 | **Per client** (changed in p023: each leaf drives its own client's fields), valid with that client's `rsp_valid` |
| `quiesce` | in | 1 | Level from the CP: the leaves outside `QUIESCE_EXEMPT` start no new packet; the tree drains |
| `dc_urgent` | in | 1 | (ws001-p039) Urgent watermark from DC: holds all leaves except `ROOT_CLIENT` |
| `dc_panic` | in | 1 | (ws001-p039) Panic watermark from DC: holds all leaves except `ROOT_CLIENT` and suppresses non-DC grant at root for zero-bubble preemption |
| `flush` | in | 1 | One-cycle pulse (with `quiesce` held): empties the tree and the root and drops a pending refusal's response (with `ROOT_KEEP`: not `ROOT_CLIENT`'s leaf, entry or refusal) |
| `aperture_base`, `aperture_limit` | in | `ADDR_W` | Allowed range [base, limit) |
| `axi_idle` | out | 1 | `am_axi_master.idle`, no refusal pending and no response flit in the tree.  With `ROOT_KEEP`, without `ROOT_CLIENT`'s requests: the other clients' requests granted to the AXI master (and the protection walks) are all answered (`atg_mc_cnt`'s `ax`), no refusal of theirs is pending, no response flit in the tree, none of theirs in the tree or the root |
| `fault`, `fault_client`, `fault_addr`, `fault_write` | out (reg) | 1, 8, `ADDR_W`, 1 | One-cycle pulse when a request was refused, with the client (from the header), the line address (VRAM_BASE + the window offset) and the direction |
| `fault_prot`, `fault_slot`, `fault_mem` | out (reg) | 1, 6, 1 | With `fault`: refused for protection (FAULT_INFO[9]) and the request's slot; a protection table read had an AXI error (kind 5) |
| `chk_idle` | out | 1 | No request with chk is in the tree or the root (taken from a leaf and not yet granted or refused) |
| `unit_idle` | out | 1 | Every request of `UNIT_MASK`'s clients taken by a leaf has had its response |
| `prot_tbase`, `prot_inv_valid`, `prot_inv_g`, `prot_inv_n`, `prot_inv_pending`, `prot_gw_valid`, `prot_gw_idx`, `prot_gw_data` | in, out | | The CP's protection registers (`spec/gpu/mc/atg_mc_prot.md`; one port group) |
| `m_*` | — | — | The AXI master ports of `am_axi_master` (one port group), with 1-bit `m_awid`/`m_arid` (0 local, 1 host) and `m_bid`/`m_rid` |

## 4. Behaviour

- Tree (`atg_mc_tree`): each client's AMB port becomes flit packets in its leaf
  (`am_amb_to_rt`): a header flit (priority, write, outside-the-window, tag, client, route, window
  offset, byte enables) and for a write one data flit.  2-way routers (`atg_rt`) merge them toward
  the root, one register stage per hop; a packet with the priority bit wins at every router, the
  others take turns per router.  Responses are one flit (write, error, tag, route, line) and go
  down by the route bits, one register stage per hop.
- Root: an assembly buffer takes the header flit and, for a write, the data flit.  The complete
  request goes to `atg_mc_prot`, which grants it when `!err_v`: inside the aperture and the window
  (and, with `HAS_PROT`, allowed by session protection) → to `am_axi_master` when it is ready;
  else refused (`bad`): next cycle `err_v` holds the refusal and `fault` pulses.  The buffer takes
  the next flit in the cycle the request leaves it.  With `HAS_PROT` and a `ROOT_CLIENT` (the DC)
  that client has its own assembly buffer at the root (the tree's `ROOT_SPLIT`), first in the
  grant, and its responses (route bit 0 = 0) go straight to its leaf.
- A protection table read (atg_mc_prot's walk) goes to the AXI master with client 0xFF; its
  response goes back to atg_mc_prot, not into the tree.  It counts for `axi_idle` (its request is
  in `pend`, its read in the AXI master).
- Responses: the AXI master's first (its user bits carry route, client and tag); a pending
  refusal goes out in the first cycle without one, with `rsp_error` = 1.  While `err_v` nothing
  is granted.  The tree always takes a response (the leaves always do, every hop has room when
  the next one has), which the AXI master's responses need.
- Order per client: one path, so a client's requests reach the root in order and its responses
  come back in order; reads in order and writes in order (am_axi_master); a read is not ordered
  after an earlier write.  **A refusal's error response may overtake the client's earlier
  requests' responses** (the CP treats it as a device fault).
- Destinations (ws288 p039): after the grant, a request (a walk too) whose line is in
  [`LOCAL_BASE`, + `LOCAL_BYTES`) gets AXI ID 0, every other ID 1; the board routes by the same
  address range (`am_axi_split`).  The two destinations answer in any order relative to each
  other; `am_axi_master` keeps each client's order (its key is the client, 0xFF for a walk): a
  request of a client with requests of the same direction outstanding at the other destination
  waits at the root (`g_ready` 0) until they are answered.  The DC's own root entry is granted
  first, so it waits only for its own requests.  Quiesce, `flush`, `axi_idle` and `unit_idle`
  are as before (`am_axi_master`'s `idle` covers both IDs; `flush` comes after `axi_idle`).
- Priority and fairness: with the priority bit a client wins every router on its path, so it
  waits at most for the packets already in the registers of its path (one per hop, plus a write's
  data flit).  The others take turns per router, which halves a client's share at each level
  (with all clients always busy, a leaf at depth d gets 1/2^d of the root's packets; a balanced
  tree is fair when all clients are equally busy).  `ROOT_CLIENT` is one hop from the root.
- Watermark Preemption (ws001-p039):
  When `dc_urgent` or `dc_panic` is asserted, `atg_mc` holds all non-DC leaves (`tree_hold` sets bit 1
  for non-DC clients), preventing 3D clients from starting new flit packets into the tree.
  When `dc_panic` is asserted, `grant` suppresses non-DC requests at the root (`.a_valid(a_full && !(HAS_DC != 0 && dc_panic))`),
  immediately freeing the AXI master pipeline for DC's upcoming reads and eliminating head-of-line blocking
  to achieve zero-bubble preemption.
- `flush`: the routers, leaves and the root buffer drop what they hold (the CP's RESET resets the
  clients in the same cycle: their requests are void).  Granted requests are already answered:
  RESET waits for `axi_idle` first.

## 5. State machine

The root has the assembly buffer (`a_hdr`: a write header waits for its data, `a_full`: the
request is offered) and the refusal register `err_v` (none →(`grant_bad`)→ pending →(`err_out`)→
none).  `flush`/`rst_n` → empty, none.  The routers and leaves have their own small states.

## 6. Latency and throughput

- Request: a read reaches the AXI master `TREE_L` (+1 with `ROOT_CLIENT`) cycles after the
  client's valid (one register per router; the leaf and the root buffer add none for a read; a
  write's data flit follows one cycle later).  Previously 0 (combinational arbiter).
- Response: `TREE_L` (+1) cycles from the AXI master to the client.
- Throughput: one read per cycle at the root; a write needs two flits, so writes alone reach one
  per two cycles (a 64-bit AXI3 HP port takes a 32-byte line in 4 beats anyway; on the KC705's 512-bit
  MIG port this halves the peak write rate — a later option is a wider request flit).
- Refusal: `fault` 1 cycle after the grant, the error response 1 cycle after the grant at the
  earliest, then `TREE_L` (+1) hops.

## 7. Corner cases and errors

- Outside the aperture (including the empty aperture after reset) or outside the VRAM window:
  refused.  For a request outside the window `fault_addr` is VRAM_BASE + its low bits (the high
  bits are not carried).
- Two refusals: the second waits (`err_v` blocks grants) until the first's response is out.
- Under `quiesce` the leaves of the clients outside `QUIESCE_EXEMPT` start no new packet (a write
  whose header is in the tree still sends its data flit); the packets already in the tree are
  granted (drained).  `axi_idle` comes when no request is in the tree or the root (`pend`, the
  requests taken from the clients and not yet granted), every granted request is answered and its
  response has left the tree.  **WS288 p004:** `atg_top` sets `QUIESCE_EXEMPT` to client 0, the CP,
  so that its debug port works in HALTED and FAULTED (and a ring line or fence it requested
  completes) while the blocks are held.  **WS288 p035 (design §18.2):** with `HAS_DISP` the DC is
  in `QUIESCE_EXEMPT` too and `ROOT_KEEP` is 1: its scan-out reads go on through HALTED, FAULTED
  and the RESET order, `axi_idle` does not wait for them, and `flush` keeps its path (dropping a
  DC request or response would leave `atg_dc_dma`'s outstanding count stuck).  A refusal of the DC
  in the flush cycle is kept, one of another client dropped.
- `rsp_rdata` of a refusal is 0 (session protection: a refused read returns zeros; before, it
  was the AXI master's last read data).
- The header must fit a line (`20 + RW + VRAM_AW − LINE_SHIFT + LINE_BYTES` ≤ `LINE_BYTES*8`:
  83 of 256 bits with 32-byte lines and 16 clients, 116 of 512 on the KC705 with 32 and a root client).

## 8. What the TB checks

`sim/tb/atg_mc_tb.v` → `PASS atg_mc`, two shapes at once, each with its own `axi_mem`:
(A) 3 clients (client 0 with the priority bit), 2-level tree; (B) 5 clients, client 4 as
`ROOT_CLIENT`, clients 0 and 4 with the priority bit, `VRAM_AW` 20.  Each client × 600 random
reads and byte-masked writes on its own lines: data against a reference, tags in order per
direction (a response routed to the wrong client fails the receiver's data or order check);
about 1/40 refused (outside the aperture; in B half of them alias a good line through the 1 MiB
window and only the window check refuses them) with an error response and a fault naming the
client, line and direction; nothing refused reaches AXI; random quiesce: no request of a held client is taken
under it and `axi_idle` comes within a bound; every client granted; fault count = refused count.
Every cycle `unit_idle` against the requests outstanding; a refused read's data is 0.  (C) is
shape B with `HAS_PROT` and no chk (the DC on its own root entry): the same checks.  (D) is shape
B with `ROOT_KEEP` (client 4 quiesce-exempt, one refusal in 4) and (E) the same with `HAS_PROT`:
during each quiesce that reached `axi_idle`, `flush` in about half of the cycles; client 4 goes on
and loses no response, the others' checks as before, and `axi_idle` must come at least once
while client 4 has requests out.  The mutation `MUT_MC_NOKEEP` (the root leaf flushed) fails (D)
and (E).  Session
protection itself: `sim/tb/atg_mc_prot_tb.v` (`spec/gpu/mc/atg_mc_prot.md`).
The router's priority, turn-taking, packet locking and response demux are checked by
`sim/tb/atg_rt_tb.v`.  Also covered by `atg_top_tb` and the Verilator harness.  Not checked:
`flush` without `ROOT_KEEP` (through the CP's RESET in `atg_top_tb`), `NCLIENT` > 5, starvation bounds.
(F, p039) is shape B with `HAS_PROT`, `VRAM_AW` 32 and two destinations: local memory
[0x2_0000, 0x4_0000) behind `am_axi_split`'s m0 and the rest on m1, each on its own `axi_mem`
(the local one with `READ_EARLY`, slow writes), half of each client's lines local: every client's
responses stay in order per direction with the right data, and each memory sees only its own ID.
`-DMUT_AXI_NOKEY` (am_axi_master without the key check) fails case F.

## 9. References

- design.md §4.1 (AMB, the tree, priority, aperture), §1.3 (quiesce, flush).
- `spec/gpu/mc/atg_mc_tree.md`, `spec/gpu/mc/atg_rt.md`, `spec/library/bus/am_amb_to_rt.md`,
  `spec/gpu/mc/atg_mc_aper.md`, `spec/library/bus/am_axi_master.md`.

## 10. Status

2026-10-25 (p039): `LOCAL_BASE`/`LOCAL_BYTES`, the AXI IDs per destination and the order
key; about 382 lines (the am_axi_master instance written compactly).


Implemented: p002 (70aaff5), the router tree in WS288 p023 milestone 4 (P1).  The flat arbiter
(and `atg_mc_arb`) is gone.  Session protection (2026-10-25): the grant moved to `atg_mc_prot`,
the assembly buffer to `atg_mc_asm`, the counters to `atg_mc_cnt`; about 395 lines; ports over 40
only by the AXI group and the protection group.  Synthesis of
the tree is not measured yet (a Vivado run is pending: each hop costs about `LINE_BYTES*8` + 30
flip-flops per direction).  **WS288 p035 D2b (2026-10-25):** `ROOT_KEEP` (the DC through the GPU's
reset): about 385 lines (the AXI master's instance packed).
