/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_vf_asm_tb: atg_vf_asm with models of its neighbours: an index stream
 * of unique vertex numbers (restart markers, instance changes, random
 * gaps), atg_vf_fetch/conv (vb taken at random, conv_done some cycles after
 * vb_last), the SU (a grant after a random delay into a free block of a
 * 64-entry PT: two blocks of 32) and the RX (prim_ready random).  The
 * primitives are checked in order against a reference assembly computed
 * here without warps from the Vulkan vertex orders of each topology
 * (provoking vertex first or last, rotated into v0); prim_last only on the
 * draw's last one.  PT ownership: a grant takes its block's 32 entries, the
 * lanes outside vl_mask are returned at vl_go, and each prim_free bit
 * returns one entry; an entry named after its return, returned twice, or
 * still taken when the draw ends is an error ("free").  Also checked: the
 * lanes of a warp are 0..n-1 in order with vb_last on the last, vb_index =
 * vertex + VERTEX_OFFSET for indexed draws, vb_inst.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_vf_asm_tb;
	reg clk = 1'b0;
	reg rst_n = 1'b0;
	always #5 clk = !clk;

	reg st_we = 1'b0;
	reg [8:0] st_idx = 0;
	reg [31:0] st_wdata = 0;
	reg iv_valid = 1'b0;
	reg [31:0] iv_index = 0, iv_inst = 0;
	reg iv_restart = 1'b0, iv_last = 1'b0;
	reg vb_ready = 1'b0, conv_done = 1'b0, vl_gnt = 1'b0, prim_ready = 1'b0;
	reg [7:0] vl_ptbase = 0;
	wire iv_ready, vb_valid, vb_last, vl_req, vl_go, prim_valid, prim_last, busy;
	wire [31:0] vb_index, vb_inst, vl_mask;
	wire [4:0] vb_lane;
	wire [23:0] prim_vtx;
	wire [2:0] prim_free;

	atg_vf_asm dut (.clk(clk), .rst_n(rst_n), .st_we(st_we), .st_idx(st_idx),
		.st_wdata(st_wdata), .iv_valid(iv_valid), .iv_ready(iv_ready), .iv_index(iv_index),
		.iv_inst(iv_inst), .iv_restart(iv_restart), .iv_last(iv_last),
		.vb_valid(vb_valid), .vb_ready(vb_ready), .vb_index(vb_index), .vb_inst(vb_inst),
		.vb_lane(vb_lane), .vb_last(vb_last), .conv_done(conv_done),
		.vl_req(vl_req), .vl_gnt(vl_gnt), .vl_ptbase(vl_ptbase), .vl_go(vl_go),
		.vl_mask(vl_mask), .prim_valid(prim_valid), .prim_ready(prim_ready),
		.prim_vtx(prim_vtx), .prim_free(prim_free), .prim_last(prim_last), .busy(busy));

	localparam MAXI = 2048, MAXP = 8192;
	integer tot = 0;
	integer seed, i, e_prim, e_free, e_vb, s_errs, ni, ip, np, gp, tmo, dl;
	reg [2:0] topo;
	reg prov, ind;
	reg [31:0] voff;
	/* the stream */
	reg [31:0] it_v [0:MAXI-1];
	reg [31:0] it_inst [0:MAXI-1];
	reg it_rst [0:MAXI-1];
	/* expected primitives (vertex numbers, slot order) */
	reg [31:0] x0 [0:MAXP-1];
	reg [31:0] x1 [0:MAXP-1];
	reg [31:0] x2 [0:MAXP-1];
	/* PT model */
	reg [63:0] taken;
	reg [31:0] pt_v [0:63];	/* the vertex of each entry */
	reg [31:0] seg [0:MAXI-1];

	task st_put;
		input [8:0] i_;
		input [31:0] val;
		begin
			st_we <= 1'b1;
			st_idx <= i_;
			st_wdata <= val;
			@(posedge clk);
			st_we <= 1'b0;
		end
	endtask

	task xput;
		input [31:0] a, b, c;
		begin
			x0[np] = a;
			x1[np] = b;
			x2[np] = c;
			np = np + 1;
		end
	endtask

	/* Reference: the primitives of the stream, segment by segment. */
	task reference;
		integer j, n, t;
		reg [31:0] pinst;
		begin
			np = 0;
			n = 0;
			pinst = 32'hFFFFFFFF;
			for (j = 0; j < ni; j = j + 1) begin
				if (it_rst[j] || (n != 0 && it_inst[j] != pinst))
					n = 0;
				if (!it_rst[j]) begin
					seg[n] = it_v[j];
					pinst = it_inst[j];
					n = n + 1;
					case (topo)
					3'd1:
						if (n % 2 == 0) begin
							if (prov)
								xput(seg[n - 1], seg[n - 2], seg[n - 2]);
							else
								xput(seg[n - 2], seg[n - 1], seg[n - 1]);
						end
					3'd2:
						if (n >= 2) begin
							if (prov)
								xput(seg[n - 1], seg[n - 2], seg[n - 2]);
							else
								xput(seg[n - 2], seg[n - 1], seg[n - 1]);
						end
					3'd3:
						if (n % 3 == 0) begin
							if (prov)
								xput(seg[n - 1], seg[n - 3], seg[n - 2]);
							else
								xput(seg[n - 3], seg[n - 2], seg[n - 1]);
						end
					3'd4:
						if (n >= 3) begin
							t = n - 3;	/* triangle t: Vulkan's orders */
							if (prov)
								xput(seg[t + 2], seg[t + t % 2], seg[t + 1 - t % 2]);
							else
								xput(seg[t], seg[t + 1 + t % 2], seg[t + 2 - t % 2]);
						end
					3'd5:
						if (n >= 3) begin
							t = n - 3;
							if (prov)
								xput(seg[t + 2], seg[0], seg[t + 1]);
							else
								xput(seg[t + 1], seg[t + 2], seg[0]);
						end
					default:
						xput(seg[n - 1], seg[n - 1], seg[n - 1]);
					endcase
				end
			end
		end
	endtask

	/* iv driver */
	always @(posedge clk) begin
		if (iv_valid && iv_ready)
			ip = ip + 1;
		if (iv_valid && !iv_ready) begin
			/* hold */
		end else if (ip < ni && ($random(seed) & 3) != 0) begin
			iv_valid <= 1'b1;
			iv_index <= it_v[ip];
			iv_inst <= it_inst[ip];
			iv_restart <= it_rst[ip];
			iv_last <= ip == ni - 1;
		end else
			iv_valid <= 1'b0;
	end

	/* fetch/conv model: vb in order, conv_done after vb_last */
	reg [5:0] nlane;
	reg [7:0] base;
	integer cd;
	reg [31:0] vv;
	always @(posedge clk) begin
		conv_done <= 1'b0;
		if (vb_valid && vb_ready) begin
			vv = ind ? vb_index - voff : vb_index;
			if (vb_lane != nlane[4:0] || nlane == 6'd32 || vb_inst !== 77 + vv / 1000 ||
				vv % 1000 >= 200) begin
				$display("FAIL atg_vf_asm: vb lane %0d vertex %0d inst %0d, want lane %0d",
					vb_lane, vv, vb_inst, nlane);
				e_vb = e_vb + 1;
			end
			pt_v[base + vb_lane] = vv;
			nlane = nlane + 6'd1;
			if (vb_last)
				cd = 1 + ($unsigned($random(seed)) % 10);
		end
		if (cd > 0) begin
			cd = cd - 1;
			if (cd == 0)
				conv_done <= 1'b1;
		end
		vb_ready <= ($random(seed) & 3) != 0;
	end

	/* SU model: grant into a free block; return the lanes outside vl_mask at vl_go */
	integer k;
	reg [31:0] gm;
	always @(posedge clk) begin
		vl_gnt <= 1'b0;
		if (vl_go) begin
			gm = vl_mask;
			for (k = 0; k < 32; k = k + 1)
				if (!gm[k])
					taken[base + k] = 1'b0;
			if (gm >= (32'd1 << nlane) && nlane != 6'd32) begin
				$display("FAIL atg_vf_asm: vl_mask %h has lanes beyond %0d", gm, nlane);
				e_free = e_free + 1;
			end
		end
		if (vl_req && !vl_gnt && dl == 0)
			dl = 1 + ($unsigned($random(seed)) % 6);
		if (dl > 0) begin
			dl = dl - 1;
			if (dl == 0) begin
				if (taken[31:0] == 32'd0) begin
					base = 8'd0;
					taken[31:0] = 32'hFFFFFFFF;
					vl_gnt <= 1'b1;
					vl_ptbase <= 8'd0;
					nlane = 6'd0;
				end else if (taken[63:32] == 32'd0) begin
					base = 8'd32;
					taken[63:32] = 32'hFFFFFFFF;
					vl_gnt <= 1'b1;
					vl_ptbase <= 8'd32;
					nlane = 6'd0;
				end else
					dl = 1;
			end
		end
	end

	/* RX model */
	integer s;
	reg [7:0] en;
	always @(posedge clk) begin
		if (prim_valid && prim_ready) begin
			for (s = 0; s < 3; s = s + 1) begin
				en = prim_vtx[8 * s +: 8];
				if (en > 8'd63 || !taken[en]) begin
					$display("FAIL atg_vf_asm: prim %0d names entry %0d, not taken", gp, en);
					e_free = e_free + 1;
				end
			end
			if (gp >= np) begin
				$display("FAIL atg_vf_asm: prim %0d beyond %0d", gp, np);
				e_prim = e_prim + 1;
			end else if (pt_v[prim_vtx[7:0]] !== x0[gp] || pt_v[prim_vtx[15:8]] !== x1[gp] ||
				pt_v[prim_vtx[23:16]] !== x2[gp] || prim_last !== (gp == np - 1)) begin
				$display("FAIL atg_vf_asm: prim %0d (%0d %0d %0d) last %b, want (%0d %0d %0d) %b",
					gp, pt_v[prim_vtx[7:0]], pt_v[prim_vtx[15:8]], pt_v[prim_vtx[23:16]],
					prim_last, x0[gp], x1[gp], x2[gp], gp == np - 1);
				e_prim = e_prim + 1;
			end
			for (s = 0; s < 3; s = s + 1)
				if (prim_free[s]) begin
					en = prim_vtx[8 * s +: 8];
					if (en <= 8'd63 && !taken[en]) begin
						$display("FAIL atg_vf_asm: prim %0d frees entry %0d twice", gp, en);
						e_free = e_free + 1;
					end
					if (en <= 8'd63)
						taken[en] = 1'b0;
				end
			gp = gp + 1;
			tot = tot + 1;
		end
		prim_ready <= ($random(seed) & 3) != 0;
	end

	/* One draw: n vertices in ninst instances, restarts with probability rp/16. */
	task draw;
		input [2:0] t;
		input integer n, ninst, rp;
		integer j, m;
		reg [31:0] r;
		begin
			topo = t;
			prov = $random(seed);
			ind = $random(seed);
			voff = ind ? $random(seed) : 32'd0;
			st_put(9'h020, {29'd0, t});
			st_put(9'h022, {30'd0, ind, 1'b0});
			st_put(9'h028, ind ? voff : $random(seed));
			st_put(9'h05D, {31'd0, prov});
			ni = 0;
			for (m = 0; m < ninst; m = m + 1)
				for (j = 0; j < n; j = j + 1) begin
					r = $random(seed);
					it_rst[ni] = ($unsigned(r) % 16) < rp;
					it_v[ni] = 1000 * m + j;
					it_inst[ni] = 77 + m;
					ni = ni + 1;
				end
			reference;
			ip = 0;
			gp = 0;
			tmo = 0;
			@(negedge clk);
			while ((ip < ni || busy || gp < np || iv_valid) && tmo < 200000) begin
				@(negedge clk);
				tmo = tmo + 1;
			end
			repeat (20) @(negedge clk);
			if (tmo >= 200000 || gp != np || busy) begin
				$display("FAIL atg_vf_asm: draw topo %0d n %0d: %0d of %0d items, %0d of %0d prims",
					t, n, ip, ni, gp, np);
				e_prim = e_prim + 1;
			end
			if (taken != 64'd0) begin
				$display("FAIL atg_vf_asm: draw topo %0d n %0d: PT entries left %h", t, n, taken);
				e_free = e_free + 1;
				taken = 64'd0;
			end
		end
	endtask

	task section;
		input [8*8-1:0] name;
		begin
			$display("atg_vf_asm: %0d primitives checked so far", tot);
			if (e_prim + e_vb + e_free == s_errs)
				$display("PASS atg_vf_asm.%0s", name);
			s_errs = e_prim + e_vb + e_free;
		end
	endtask

	initial begin
		if (!$value$plusargs("seed=%d", seed))
			seed = 1;
		e_prim = 0;
		e_free = 0;
		e_vb = 0;
		s_errs = 0;
		ni = 0;
		ip = 0;
		np = 0;
		gp = 0;
		dl = 0;
		cd = 0;
		taken = 64'd0;
		nlane = 6'd0;
		base = 8'd0;
		repeat (3) @(posedge clk);
		rst_n <= 1'b1;
		@(posedge clk);

		/* triangle, line and point lists over several warps */
		for (i = 0; i < 4; i = i + 1) begin
			draw(3'd3, 1 + ($unsigned($random(seed)) % 200), 1, 0);
			draw(3'd1, 1 + ($unsigned($random(seed)) % 100), 1, 0);
			draw(3'd0, 1 + ($unsigned($random(seed)) % 100), 1, 0);
		end
		draw(3'd3, 30, 1, 0);
		draw(3'd3, 31, 1, 0);
		draw(3'd3, 2, 1, 0);
		draw(3'd1, 33, 1, 0);
		draw(3'd0, 64, 1, 0);
		section("list");

		/* strips and fans across warp boundaries */
		for (i = 0; i < 4; i = i + 1) begin
			draw(3'd4, 1 + ($unsigned($random(seed)) % 150), 1, 0);
			draw(3'd5, 1 + ($unsigned($random(seed)) % 150), 1, 0);
			draw(3'd2, 1 + ($unsigned($random(seed)) % 100), 1, 0);
		end
		draw(3'd4, 32, 1, 0);
		draw(3'd4, 33, 1, 0);
		draw(3'd4, 34, 1, 0);
		draw(3'd5, 63, 1, 0);
		draw(3'd2, 32, 1, 0);
		section("strip");

		/* restart (and instances) */
		for (i = 0; i < 6; i = i + 1) begin
			draw(3'd4, 1 + ($unsigned($random(seed)) % 120), 1, 3);
			draw(3'd5, 1 + ($unsigned($random(seed)) % 120), 1, 3);
			draw(3'd2, 1 + ($unsigned($random(seed)) % 80), 1, 4);
			draw(3'd3, 1 + ($unsigned($random(seed)) % 80), 1, 2);
		end
		draw(3'd4, 40, 3, 1);
		draw(3'd5, 20, 4, 2);
		draw(3'd3, 7, 5, 0);
		draw(3'd4, 5, 2, 15);
		section("restart");

		/* every topology, mixed: the PT accounting above */
		s_errs = e_prim + e_vb;
		for (i = 0; i < 24; i = i + 1)
			draw($unsigned($random(seed)) % 8, 1 + ($unsigned($random(seed)) % 160),
				1 + ($unsigned($random(seed)) % 3), $unsigned($random(seed)) % 4);
		if (e_free == 0 && e_prim + e_vb == s_errs)
			$display("PASS atg_vf_asm.free");

		if (e_prim + e_vb + e_free == 0)
			$display("PASS atg_vf_asm");
		$finish;
	end

	initial begin
		#200000000;
		$display("FAIL atg_vf_asm: timeout");
		$finish;
	end
endmodule

`default_nettype wire
