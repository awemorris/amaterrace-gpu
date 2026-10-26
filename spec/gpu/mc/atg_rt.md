# atg_rt

RTL: `rtl/gpu/mc/atg_rt.v`.  Parent: `atg_mc_tree`.  Implemented in WS288 p023 milestone 4
(P1, 2026-10-23), after the user's request (「atg_rtという名前でモジュールを作って、インスタンスを並べる
のがいいかなあと思います。…本格的なNoCじゃなくて、そのエッセンスを採用したルーティングですね。」).

## 1. Purpose and place

A 2-way router of the MC's client tree: two child ports and one parent port, each with a request
channel (towards the MC) and a response channel (towards the clients).  A binary tree of these
replaces the MC's N-input selector (easier to synthesise and to route in an ASIC).  Children:
none.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `FW` | 256 | Request flit width | `LINE_BYTES*8` in atg_mc_tree |
| `RFW` | 266 | Response flit width | `LINE_BYTES*8 + 10 + RW` |
| `RBIT` | 10 | The response flit's bit that names the child | `10 + level` (+1 under a root client) |

## 3. Ports

Domain `clk`.  25 ports; 4 port groups of the same shape (request in ×2, request out, response
in, response out ×2).

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock, synchronous reset |
| `flush` | in | 1 | Synchronous clear of both stages (the MC's flush) |
| `c0_req_valid`/`ready`/`data`/`last`, `c1_req_*` | in/out/in/in | 1, 1, FW, 1 | Child request channels: valid/ready, a flit, `last` on a packet's last flit.  A child keeps its packet's flits in order and does not drop valid or change the flit before ready |
| `p_req_valid`/`ready`/`data`/`last` | out/in/out/out | 1, 1, FW, 1 | Parent request channel, from the output register |
| `p_rsp_valid`/`ready`/`data` | in/out/in | 1, 1, RFW | Parent response channel (one-flit packets) |
| `c0_rsp_valid`/`ready`/`data`, `c1_rsp_*` | out/in/out | 1, 1, RFW | Child response channels, from the output register |
| `rsp_idle` | out | 1 | The response register is empty |

## 4. Behaviour

- Request: the first flit of a packet is its header; bit 0 of the header is the priority bit.
  When no packet is passing, the router picks a child with a flit: if both have one and exactly
  one header has the priority bit, that one; otherwise the child that did not win the last pick
  (turns).  The pick holds (`lock`, `owner`) until the packet's `last` flit is taken, so packets
  are never interleaved; flits of the locked packet that are late (a write's data flit) just
  leave a gap.
- One output register: a child's `ready` = (the register is empty or is taken by the parent this
  cycle) and the child is the pick.  Full throughput, one flit per cycle; the ready path is
  combinational through the hops (no skid buffer: half the registers; at the MC's depth of ≤ 6
  hops this meets 100 MHz on the 7010 and 200 MHz on the 325T — to be measured).
- Response: bit `RBIT` of the incoming flit names the child; one register stage; `p_rsp_ready` =
  the register is empty or its child takes it.
- Order: per child, packets leave in arrival order; responses for one child leave in order.

## 5. State machine

Request side only: FREE (pick at the next header) ↔ LOCKED (owner fixed until `last`); the turn
bit `last_won` changes at each packet start.  The response side is a register stage.

## 6. Latency and throughput

1 cycle per hop in each direction; 1 flit per cycle per port.

## 7. Corner cases and errors

- Equal priority and both waiting: strict alternation.  A child that always has priority packets
  starves the other at this router (by design: the DC's place).
- Flush in the middle of a packet: the packet is dropped; its client is reset in the same cycle
  (atg_mc's RESET order).
- The response channel never back-pressures in atg_mc (the leaves always take); the router still
  honours `ready`.

## 8. What the TB checks

`sim/tb/atg_rt_tb.v` → `PASS atg_rt`: 2 × 2000 random packets of 1-3 flits with random gaps and
random parent ready; no interleaving, per-child order, every packet complete; at each packet
start with both children waiting, a priority header beats a plain one and equal priority
alternates; a phase where child 1 always has priority; 4000 responses with random child ready
reach their child in order; `rsp_idle` at the end.  Mutations checked by hand on 2026-10-23
(priority inverted, turns inverted, lock removed, response sent to both children): each fails.

## 9. References

design.md §4.1; `spec/gpu/mc/atg_mc_tree.md` (where the routers sit), `spec/library/bus/am_amb_to_rt.md`
(the flit formats).

## 10. Status

Implemented (WS288 p023 milestone 4).  About 130 lines, one clock, 25 ports.
