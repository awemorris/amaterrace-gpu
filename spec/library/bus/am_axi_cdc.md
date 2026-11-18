# am_axi_cdc

RTL: `rtl/library/bus/am_axi_cdc.v`.  Parent: atg_kc705_top (the PCIe BAR0 into atg_top's register port).  Written in WS288 p013 (2026-10-25).

## 1. Purpose and place

An AXI4 slave in one clock passed on as an AXI4 master in another: the five channels each cross through an `am_afifo`.  The fields are those of atg_top's `s_*` port (AW {addr, id}, W {data, strb, last}, B {id, resp}, AR {addr, id, len}, R {data, id, resp, last}).

## 2. Parameters

`A_W` (17), `ID_W` (4), `LEN_W` (8), `D_W` (32), `DEPTH_LOG2` (2: the FIFOs' depth).

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `s_clk`, `s_rst_n` | in | 1 | The slave side's clock and synchronous reset. |
| `s_*` | | | AXI4 slave (the fields above), in s_clk. |
| `m_clk`, `m_rst_n` | in | 1 | The master side's clock and reset. |
| `m_*` | | | AXI4 master, in m_clk. |

4 ports and 2 AXI groups.

## 4. Behaviour

Every handshake on one side becomes one on the other, in order per channel; bursts, outstanding transactions and their order pass unchanged (the FIFOs hold up to 2^DEPTH_LOG2 entries per channel).  Each side is in reset while either reset input is (am_sync of the other side's input), so both sides of every FIFO are emptied together (am_afifo's rule); each reset input is held for at least 4 cycles of the slower clock.  A transaction in a FIFO at a reset is lost.

## 5. State machine

None.

## 6. Latency and throughput

A few cycles of each clock per crossing (am_afifo's Gray pointers, 2 flops); one transfer a cycle per channel.

## 7. Corner cases and errors

A reset during a transaction loses it: the host's access times out (PERST#, or the GPU's reset).

## 8. What the TB checks

Through `sim/tb/atg_kc705_pcie_tb.v` (BAR0 reads and writes of the register window).

## 9. References

`spec/library/bus/am_afifo.md`, `spec/library/bus/am_sync.md`.

## 10. Status

Implemented (2026-10-25, p013).
