# atg_dc_i2c

RTL: `rtl/gpu/dc/atg_dc_i2c.v`.  Parent: atg_dc.  Implemented in: p012.

## 1. Purpose and place

A small I2C master for the KC705's ADV7511 HDMI transmitter configuration (I2C_CTRL/DATA/STATUS of design §5.1).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `CLK_DIV` | `250` | gclk cycles per quarter SCL period (100 MHz → 100 kHz). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_we` | in | 1 | Register write. |
| `i_idx` | in | 2 | Register. |
| `i_wdata` | in | 32 | Data. |
| `i_rdata` | out | 32 | Read data of i_idx (combinational). |
| `scl_t` | out | 1 | 1: release SCL (pull-up), 0: drive low. |
| `scl_i` | in | 1 | SCL level (clock stretching). |
| `sda_t` | out | 1 | 1: release SDA, 0: drive low. |
| `sda_i` | in | 1 | SDA level. |

10 ports.

## 4. Behaviour

CTRL: [0] START, [1] STOP, [2] WRITE byte, [3] READ byte, [4] ACK on read; DATA [7:0]; STATUS [0] busy, [1] NACK.  One byte operation per command.

- i_idx 0 CTRL, 1 DATA, 2 STATUS (3 reads 0).  A CTRL write while idle runs, in order: START
  (a repeated START when the bus is held), the byte (WRITE sends DATA[7:0] MSB first and takes
  the acknowledge into STATUS.NACK; READ shifts a byte into DATA[7:0] and answers ACK if [4] = 1,
  else NACK; WRITE wins if both are set), STOP.  A CTRL with none of the bits does nothing.
- A CTRL or DATA write while busy is ignored.  CTRL reads back the last command [4:0].
- Between commands without STOP the master holds the bus with SCL low.
- SCL period = 4 × CLK_DIV cycles.  A quarter in which SCL is released does not count while the
  synchronised SCL is still low (clock stretching and rise time).  SDA changes only while SCL is
  low (except START/STOP); it is sampled at the end of the second high quarter.
- scl_i/sda_i go through am_sync (reset value 1).

## 5. State machine

IDLE → START → BIT×8 → ACK → (STOP) → IDLE.

## 6. Latency and throughput

100 kHz.

## 7. Corner cases and errors

- Unconnected I2C: HAS_I2C 0 in atg_dc ties this off.
- No arbitration (single master) and no timeout: a slave that stretches SCL forever keeps the
  master busy until the DC reset (CTRL.RESET resets atg_dc_i2c through g_rst_n).

## 8. What the TB checks

`sim/tb/atg_dc_i2c_tb.v` prints, in this order:

- `PASS atg_dc_i2c.write` — a write transaction against an I2C slave model (`sim/models/i2c_slave.v`,
  0x39 with clock stretching, and a second slave at 0x74, the KC705's mux)
- `PASS atg_dc_i2c.read` — a read with ACK/NACK, repeated START, a wrong address (NACK), writes
  while busy ignored
- `PASS atg_dc_i2c` at the end.

## 9. References

design §5.1, Values referenced: UG810 (ADV7511 address and mux, unread: design U7).  The KC705's
I2C pins (IIC_SCL_MAIN K21, IIC_SDA_MAIN L21, IIC_MUX_RESET_B P23) are from the Vivado 2026.1
board file kc705/1.7 part0_pins.xml (see the board top's XDC).

## 10. Status

Implemented in WS288 p012 part A (TB `atg_dc_i2c_tb` PASS).  No port change; §4 spelled out.
