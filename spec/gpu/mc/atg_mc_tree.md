# atg_mc_tree

RTL: `rtl/gpu/mc/atg_mc_tree.v`.  Parent: `atg_mc`.  Implemented in WS288 p023 milestone 4
(P1, 2026-10-23).

## 1. Purpose and place

The MC's client tree, wiring only: one `am_amb_to_rt` leaf per client and a binary tree of
`atg_rt` routers built with `generate` from `NCLIENT`; its top connects to atg_mc's root.
Children: `am_amb_to_rt`, `atg_rt`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NCLIENT`, `HIGH_MASK` | 2, 0 | As atg_mc |
| `HAS_ROOT`, `ROOT_CLIENT` | 0, 0 | A client one hop from the root |
| `TREE_L` | 1 | Levels of the tree of the other clients: clog2(`NCLIENT` − `HAS_ROOT`) |
| `RW` | 1 | Route bits: max(1, `TREE_L` + `HAS_ROOT`) |
| `ADDR_W`, `LINE_BYTES`, `LINE_SHIFT`, `VRAM_AW`, `VRAM_BASE` | | As atg_mc |

## 3. Ports

Domain `clk`.  The packed client ports of atg_mc (request in, per-client response out) and the
root's request and response channels; `rsp_idle` (no response flit in any router).

## 4. Behaviour

- The clients other than `ROOT_CLIENT` are numbered j = 0 … NT−1 in client order and sit at the
  leaves of a complete binary tree of 2^TREE_L leaves; unused leaves are idle (no request,
  responses taken and dropped — none come).  Routers are numbered as a heap: node 1 is the top,
  node i has the children 2i (child 0) and 2i+1 (child 1), leaf j is node 2^TREE_L + j.
- With `HAS_ROOT`, one more router is on top: child 0 is `ROOT_CLIENT`'s leaf, child 1 is node 1.
- Routes: bit 0 is the top router's choice (with `HAS_ROOT`: 0 for the root client, 1 for the
  others), then one bit per level; tree client j takes at level l the bit TREE_L−1−l of j.  The
  router at node i reads response bit `10 + HAS_ROOT + floor(log2 i)`.
- Priority comes from `HIGH_MASK` (each leaf's `PRIO`).

## 5. State machine

None (wiring).

## 6. Latency and throughput

`TREE_L` hops (+1 with `HAS_ROOT`) each way.  Routers: 2^TREE_L − 1 (+1); with the KC705's
22 clients and the DC as the root client, 31 + 1 routers in 5 + 1 levels.

## 7. Corner cases and errors

- `TREE_L` = 0 (one tree client): no router; the leaf is node 1.
- Unbalanced use: idle leaves cost the routers above them (their registers stay, the arbitration
  of the idle side is removed by synthesis).

## 8. What the TB checks

Covered by `sim/tb/atg_mc_tb.v` (3 clients in 2 levels with an idle leaf; 5 clients with a root
client and 2 levels).

## 9. References

design.md §4.1; `spec/gpu/mc/atg_rt.md`, `spec/common/am_amb_to_rt.md`, `spec/gpu/mc/atg_mc.md`.

## 10. Status

Implemented (WS288 p023 milestone 4).  About 220 lines of wiring.
