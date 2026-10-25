/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * axi_id_data.vh: the data of sim/models/axi_id_slave.v (included inside a
 * module that has D_W): beat b of the burst at address a of source k, a
 * 32-bit pattern repeated over the bus.
 */

function [D_W-1:0] axi_id_data;
	input integer k;
	input [31:0] a;
	input integer b;
	integer j;
	reg [31:0] w;
	begin
		w = a ^ (b << 20) ^ (k << 28) ^ 32'h05A5_0F0F;
		for (j = 0; j < D_W / 32; j = j + 1)
			axi_id_data[j*32 +: 32] = w ^ j;
	end
endfunction
