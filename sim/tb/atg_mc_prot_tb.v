/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_mc_prot_tb: session protection at the MC's root (atg_mc with
 * HAS_PROT: atg_mc_prot, atg_mc_grant; spec/gpu/mc/atg_mc_prot.md).  Five
 * clients on one axi_mem: 0..3 run the requests of sim/vec/prot.txt
 * (tools/protmodel.py: a protection table with owners, read-only and
 * public granules, four grants, requests with and without chk, writes into
 * the table with and without tbl, requests outside the aperture; client 3's
 * reads are judged as writes), client 4 is the DC on its own root entry and
 * reads all the time without chk.
 *
 * Checked, group by group (each prints PASS atg_mc_prot.GROUP):
 *   vec     every response against the model: an error exactly for a
 *           refusal, refused reads return 0, granted reads the memory's data;
 *           the faults per client and kind (protection or aperture) as many
 *           as the model's refusals; fault_slot is the request's
 *   order   every client's requests leave the root (granted or refused) in
 *           the order they were taken, chk or not
 *   park    while a request waits in the park for its walk, other clients'
 *           requests are granted; chk_idle is 0 while J or P hold one
 *   dc      the DC's request waits at most DC_WAIT cycles for its ready
 *   mem     at the end every line a client wrote holds its data and the
 *           table is unchanged (a refused write reaches no memory; a write
 *           into the table with tbl and no byte enabled changes nothing)
 *   inv     an owner changed in the table takes effect after PROT_INV
 *   race    an invalidation that overlaps a walk in flight: the walk's line
 *           is read again (inv_pending meanwhile), the new owner counts
 *   recheck a grant removed while the request is in the judge stage: the
 *           request is judged again and refused
 *   walkerr a table read with an AXI error refuses the request (fault_mem)
 *
 * Mutations (each must FAIL): MUT_PROT_NOCHK, MUT_PROT_STALE, MUT_PROT_RO,
 * MUT_PROT_DATA, MUT_PROT_RECHECK, MUT_PROT_LIMIT, MUT_PROT_TBL.
 */

`timescale 1ns / 1ps
`default_nettype none

module atg_mc_prot_client #(
	parameter ID = 0,
	parameter MAXQ = 512
) (
	input wire clk,
	input wire rst_n,
	input wire start,
	output reg req_valid,
	input wire req_ready,
	output reg req_write,
	output reg [26:0] req_line,
	output reg [31:0] req_be,
	output reg [255:0] req_wdata,
	output reg [7:0] req_tag,
	output reg req_chk,
	output reg req_tbl,
	output reg [5:0] req_slot,
	input wire rsp_valid,
	input wire rsp_write,
	input wire [7:0] rsp_tag,
	input wire [255:0] rsp_rdata,
	input wire rsp_error,
	output reg finished,
	output integer errors,
	output integer n_prot,	/* the model's refusals of each kind */
	output integer n_aper
);
	reg q_w [0:MAXQ-1];
	reg q_chk [0:MAXQ-1];
	reg q_tbl [0:MAXQ-1];
	reg [5:0] q_slot [0:MAXQ-1];
	reg [31:0] q_addr [0:MAXQ-1];
	integer q_exp [0:MAXQ-1];
	integer nq;

	/* The data of this client's lines (1 MiB = 32 K lines). */
	reg [255:0] ref [0:32767];
	reg written [0:32767];
	integer pend [0:32767];

	/* Outstanding requests by tag[6:0]. */
	reg o_v [0:127];
	reg o_w [0:127];
	reg o_bad [0:127];
	reg o_direct [0:127];
	reg [255:0] o_data [0:127];
	reg [14:0] o_ln [0:127];
	integer seq, answered, issued, last_good_r, last_good_w;

	/* A directed request's result. */
	reg d_done, d_err;
	reg [255:0] d_rdata;

	integer fd, r, c, w, ch, tb, sl, ex, i, k, dk;
	reg [31:0] ad;
	reg [8*8-1:0] kind;
	integer seed;

	initial begin
		req_valid = 1'b0;
		req_write = 1'b0;
		req_line = 0;
		req_be = 0;
		req_wdata = 0;
		req_tag = 0;
		req_chk = 0;
		req_tbl = 0;
		req_slot = 0;
		finished = 1'b0;
		errors = 0;
		n_prot = 0;
		n_aper = 0;
		seq = 0;
		answered = 0;
		issued = 0;
		last_good_r = -1;
		last_good_w = -1;
		seed = 17 + ID;
		d_done = 1'b0;
		for (i = 0; i < 32768; i = i + 1) begin
			ref[i] = 256'd0;
			written[i] = 1'b0;
			pend[i] = 0;
		end
		for (i = 0; i < 128; i = i + 1)
			o_v[i] = 1'b0;
		nq = 0;
		fd = $fopen("sim/vec/prot.txt", "r");
		if (fd == 0) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot: no sim/vec/prot.txt");
		end else begin
			r = $fscanf(fd, "%s", kind);
			while (r == 1 && kind != "E") begin
				if (kind == "R") begin
					r = $fscanf(fd, "%h %h %h %h %h %h %h", c, w, ch, tb, sl, ad, ex);
					if (c == ID && nq < MAXQ) begin
						q_w[nq] = w;
						q_chk[nq] = ch;
						q_tbl[nq] = tb;
						q_slot[nq] = sl;
						q_addr[nq] = ad;
						q_exp[nq] = ex;
						if (ex == 1)
							n_aper = n_aper + 1;
						if (ex == 2)
							n_prot = n_prot + 1;
						nq = nq + 1;
					end
				end else begin
					/* Skip the rest of the line. */
					c = $fgetc(fd);
					while (c != 10 && c != -1)
						c = $fgetc(fd);
				end
				r = $fscanf(fd, "%s", kind);
			end
			$fclose(fd);
		end
	end

	/* The memory's data the TB expects at a line (the table's lines from the top). */
	function [255:0] expect_of;
		input [14:0] ln;
		begin
			if (atg_mc_prot_tb.in_table({ln, 5'd0}))
				expect_of = atg_mc_prot_tb.table_line({ln, 5'd0});
			else
				expect_of = ref[ln];
		end
	endfunction

	task issue;
		input wr, chk, tbl;
		input [5:0] slot;
		input [31:0] addr;
		input bad;
		input direct;
		input [31:0] be;
		reg [255:0] data;
		reg [14:0] ln;
		begin
			ln = addr[19:5];
			while (pend[ln] != 0 || o_v[seq % 128])
				@(posedge clk);
			data = {$random(seed), $random(seed), $random(seed), $random(seed),
				$random(seed), $random(seed), $random(seed), $random(seed)};
			o_v[seq % 128] = 1'b1;
			o_w[seq % 128] = wr;
			o_bad[seq % 128] = bad;
			o_direct[seq % 128] = direct;
			o_ln[seq % 128] = ln;
			o_data[seq % 128] = wr ? 256'd0 : expect_of(ln);
			pend[ln] = pend[ln] + 1;
			if (wr && !bad && be != 0 && !direct) begin
				ref[ln] = data;
				written[ln] = 1'b1;
			end
			req_valid <= 1'b1;
			req_write <= wr;
			req_line <= addr[31:5];
			req_be <= be;
			req_wdata <= data;
			req_tag <= {wr, seq[6:0]};
			req_chk <= chk;
			req_tbl <= tbl;
			req_slot <= slot;
			@(posedge clk);
			while (!req_ready)
				@(posedge clk);
			req_valid <= 1'b0;
			seq = seq + 1;
			issued = issued + 1;
		end
	endtask

	/* A directed request from the top: waits for its response. */
	task direct;
		input wr, chk, tbl;
		input [5:0] slot;
		input [31:0] addr;
		input [31:0] be;
		begin
			d_done = 1'b0;
			issue(wr, chk, tbl, slot, addr, 1'b0, 1'b1, be);
			dk = 0;
			while (!d_done && dk < 5000) begin
				@(posedge clk);
				dk = dk + 1;
			end
			if (!d_done) begin
				errors = errors + 1;
				d_err = 1'bx;
				$display("FAIL atg_mc_prot: client %0d directed request not answered", ID);
			end
		end
	endtask

	always @(posedge clk) begin
		if (rst_n && rsp_valid) begin
			k = rsp_tag[6:0];
			answered = answered + 1;
			if (!o_v[k] || o_w[k] != rsp_write || rsp_tag[7] != rsp_write) begin
				errors = errors + 1;
				$display("FAIL atg_mc_prot: client %0d response tag %h not outstanding", ID,
					rsp_tag);
			end else begin
				o_v[k] = 1'b0;
				pend[o_ln[k]] = pend[o_ln[k]] - 1;
				if (rsp_error && !rsp_write && rsp_rdata !== 256'd0) begin
					errors = errors + 1;
					$display("FAIL atg_mc_prot: client %0d refused read data not 0", ID);
				end
				if (o_direct[k]) begin
					d_err = rsp_error;
					d_rdata = rsp_rdata;
					d_done = 1'b1;
				end else begin
					if (rsp_error != o_bad[k]) begin
						errors = errors + 1;
						$display("FAIL atg_mc_prot: client %0d line %h %s: error %b, expected %b",
							ID, {o_ln[k], 5'd0}, rsp_write ? "write" : "read", rsp_error,
							o_bad[k]);
					end
					if (!rsp_error && !rsp_write && rsp_rdata !== o_data[k]) begin
						errors = errors + 1;
						$display("FAIL atg_mc_prot: client %0d line %h read data", ID,
							{o_ln[k], 5'd0});
					end
				end
			end
		end
	end

	initial begin
		@(posedge start);
		for (i = 0; i < nq; i = i + 1)
			issue(q_w[i], q_chk[i], q_tbl[i], q_slot[i], q_addr[i], q_exp[i] != 0, 1'b0,
				atg_mc_prot_tb.in_table(q_addr[i]) ? 32'd0 : 32'hFFFFFFFF);
		while (answered != issued)
			@(posedge clk);
		finished = 1'b1;
	end

	/* The lines this client wrote must hold its data at the end. */
	task check_mem;
		integer n, b;
		reg [255:0] m;
		begin
			for (n = 0; n < 32768; n = n + 1)
				if (written[n]) begin
					for (b = 0; b < 32; b = b + 1)
						m[b*8 +: 8] = atg_mc_prot_tb.mem.mem[n * 32 + b];
					if (m !== ref[n]) begin
						errors = errors + 1;
						$display("FAIL atg_mc_prot.mem: client %0d line %h", ID, n * 32);
					end
				end
		end
	endtask
endmodule

module atg_mc_prot_tb;
	localparam N = 5;
	localparam DC = 4;
	localparam DC_WAIT = 4;
	localparam [31:0] WBASE = 32'h000F0000;	/* the walk error test's table */

	reg clk = 1'b0;
	reg rst_n = 1'b0;
	reg start = 1'b0;
	always #5 clk = !clk;

	integer errors = 0;
	integer gerr;

	/* The scenario. */
	reg [31:0] ap_base, ap_limit, tbase;
	reg [7:0] tab [0:4095];
	reg inv_valid = 1'b0;
	reg [19:0] inv_g = 20'd0;
	reg [31:0] inv_n = 32'd0;
	reg gw_valid = 1'b0;
	reg [2:0] gw_idx = 3'd0;
	reg [49:0] gw_data = 50'd0;

	function in_table;
		input [31:0] a;
		begin
			in_table = a >= tbase && a < tbase + 32'd4096;
		end
	endfunction

	function [255:0] table_line;
		input [31:0] a;
		integer b;
		begin
			for (b = 0; b < 32; b = b + 1)
				table_line[b*8 +: 8] = tab[(a - tbase) / 32 * 32 + b];
		end
	endfunction

	wire [N-1:0] c_req_valid, c_req_ready, c_req_write, c_req_chk, c_req_tbl;
	wire [N*27-1:0] c_req_line;
	wire [N*32-1:0] c_req_be;
	wire [N*256-1:0] c_req_wdata;
	wire [N*8-1:0] c_req_tag;
	wire [N*6-1:0] c_req_slot;
	wire [N-1:0] rsp_valid, rsp_write, rsp_error;
	wire [N*8-1:0] rsp_tag;
	wire [N*256-1:0] rsp_rdata;
	wire axi_idle, fault, fault_write, fault_prot, fault_mem, chk_idle, unit_idle, inv_pending;
	wire [7:0] fault_client;
	wire [5:0] fault_slot;
	wire [31:0] fault_addr;

	wire [31:0] awaddr, araddr;
	wire [7:0] awlen, arlen;
	wire [2:0] awsize, arsize, awprot, arprot;
	wire [1:0] awburst, arburst, bresp, rresp;
	wire [3:0] awcache, arcache;
	wire awvalid, awready, wlast, wvalid, wready, bvalid, bready;
	wire arvalid, arready, rlast, rvalid, rready;
	wire [63:0] wdata, rdata;
	wire [7:0] wstrb;

	atg_mc #(
		.NCLIENT(N), .HIGH_MASK(5'b10001), .ROOT_CLIENT(DC), .UNIT_MASK(5'b01110),
		.HAS_PROT(1), .RMW_MASK(5'b01000), .PROT_PLB(2), .PROT_PLB_W(1),
		.PROT_GRANTS(8), .PROT_GIDX_W(3)
	) dut (
		.clk(clk), .rst_n(rst_n),
		.c_req_valid(c_req_valid), .c_req_ready(c_req_ready), .c_req_write(c_req_write),
		.c_req_line(c_req_line), .c_req_be(c_req_be), .c_req_wdata(c_req_wdata),
		.c_req_tag(c_req_tag), .c_req_chk(c_req_chk), .c_req_tbl(c_req_tbl),
		.c_req_slot(c_req_slot), .rsp_valid(rsp_valid), .rsp_write(rsp_write),
		.rsp_tag(rsp_tag), .rsp_rdata(rsp_rdata), .rsp_error(rsp_error),
		.quiesce(1'b0), .flush(1'b0),
		.aperture_base(ap_base), .aperture_limit(ap_limit),
		.axi_idle(axi_idle), .fault(fault), .fault_client(fault_client),
		.fault_addr(fault_addr), .fault_write(fault_write), .fault_prot(fault_prot),
		.fault_slot(fault_slot), .fault_mem(fault_mem), .chk_idle(chk_idle),
		.unit_idle(unit_idle),
		.prot_tbase(tbase), .prot_inv_valid(inv_valid), .prot_inv_g(inv_g),
		.prot_inv_n(inv_n), .prot_inv_pending(inv_pending), .prot_gw_valid(gw_valid),
		.prot_gw_idx(gw_idx), .prot_gw_data(gw_data),
		.m_awid(), .m_bid(1'b0), .m_arid(), .m_rid(1'b0),
		.m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize), .m_awburst(awburst),
		.m_awcache(awcache), .m_awprot(awprot), .m_awvalid(awvalid), .m_awready(awready),
		.m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid),
		.m_wready(wready), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
		.m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize), .m_arburst(arburst),
		.m_arcache(arcache), .m_arprot(arprot), .m_arvalid(arvalid), .m_arready(arready),
		.m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast), .m_rvalid(rvalid),
		.m_rready(rready)
	);

	axi_mem #(.DATA_W(64), .MEM_BYTES(1 << 20), .ERR_BASE(WBASE), .READ_EARLY(1),
		.SEED(5)) mem (
		.clk(clk), .rst_n(rst_n),
		.awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
		.awvalid(awvalid), .awready(awready), .wdata(wdata), .wstrb(wstrb),
		.wlast(wlast), .wvalid(wvalid), .wready(wready), .bresp(bresp),
		.bvalid(bvalid), .bready(bready), .araddr(araddr), .arlen(arlen),
		.arsize(arsize), .arburst(arburst), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
	);

	wire [3:0] fin;
	wire [31:0] cerr [0:3];
	wire [31:0] cprot [0:3];
	wire [31:0] caper [0:3];

	genvar g;
	generate
		for (g = 0; g < 4; g = g + 1) begin : cl
			atg_mc_prot_client #(.ID(g)) c (
				.clk(clk), .rst_n(rst_n), .start(start),
				.req_valid(c_req_valid[g]), .req_ready(c_req_ready[g]),
				.req_write(c_req_write[g]), .req_line(c_req_line[g*27 +: 27]),
				.req_be(c_req_be[g*32 +: 32]), .req_wdata(c_req_wdata[g*256 +: 256]),
				.req_tag(c_req_tag[g*8 +: 8]), .req_chk(c_req_chk[g]),
				.req_tbl(c_req_tbl[g]), .req_slot(c_req_slot[g*6 +: 6]),
				.rsp_valid(rsp_valid[g]), .rsp_write(rsp_write[g]),
				.rsp_tag(rsp_tag[g*8 +: 8]), .rsp_rdata(rsp_rdata[g*256 +: 256]),
				.rsp_error(rsp_error[g]), .finished(fin[g]), .errors(cerr[g]),
				.n_prot(cprot[g]), .n_aper(caper[g])
			);
		end
	endgenerate

	/* ------------------------------------------------ the DC */

	reg dc_valid = 1'b0;
	reg [26:0] dc_line = 27'h3000;	/* 0x60000 */
	reg [7:0] dc_tag = 8'd0;
	integer dc_wait = 0, dc_max = 0, dc_n = 0, dc_rsp = 0;
	reg dc_run = 1'b0;

	assign c_req_valid[DC] = dc_valid;
	assign c_req_write[DC] = 1'b0;
	assign c_req_line[DC*27 +: 27] = dc_line;
	assign c_req_be[DC*32 +: 32] = 32'd0;
	assign c_req_wdata[DC*256 +: 256] = 256'd0;
	assign c_req_tag[DC*8 +: 8] = dc_tag;
	assign c_req_chk[DC] = 1'b0;
	assign c_req_tbl[DC] = 1'b0;
	assign c_req_slot[DC*6 +: 6] = 6'd0;

	always @(posedge clk) begin
		if (rst_n) begin
			if (rsp_valid[DC]) begin
				dc_rsp = dc_rsp + 1;
				if (rsp_error[DC]) begin
					errors = errors + 1;
					$display("FAIL atg_mc_prot.dc: the DC's read was refused");
				end
			end
			if (dc_valid && c_req_ready[DC]) begin
				dc_valid <= 1'b0;
				dc_line <= 27'h3000 + (dc_line + 1) % 64;
				dc_tag <= dc_tag + 1'b1;
				dc_n = dc_n + 1;
				if (dc_wait > dc_max)
					dc_max = dc_wait;
				dc_wait = 0;
			end else if (dc_valid) begin
				dc_wait = dc_wait + 1;
			end else if (dc_run && dc_n - dc_rsp < 4) begin
				dc_valid <= 1'b1;
			end
		end
	end

	/* ------------------------------------- order, park, chk_idle */

	integer last_seq [0:N-1];
	integer n_done [0:N-1];
	integer park_pass = 0, walks = 0, n_fault_prot [0:N-1], n_fault_aper [0:N-1];
	integer n_fault_mem = 0, oerr = 0, perr = 0;
	reg [7:0] d_client, d_tag;
	integer k;
	initial for (k = 0; k < N; k = k + 1) begin
		last_seq[k] = -1;
		n_done[k] = 0;
		n_fault_prot[k] = 0;
		n_fault_aper[k] = 0;
	end

	always @(posedge clk) begin
		if (rst_n) begin
			if (dut.grant.done) begin
				if (dut.grant.g_valid && dut.grant.g_ready && !dut.grant.sel_w) begin
					d_client = dut.grant.g_user[15:8];
					d_tag = dut.grant.g_user[7:0];
				end else begin
					d_client = dut.grant.bad_head[19:12];
					d_tag = dut.grant.bad_head[11:4];
				end
				if (d_client < N) begin
					/* The DC's tags count all bits, the others' the low 7. */
					if (d_client == DC ? d_tag != (last_seq[DC] + 1) % 256 :
					    d_tag[6:0] != (last_seq[d_client] + 1) % 128) begin
						oerr = oerr + 1;
						$display("FAIL atg_mc_prot.order: client %0d tag %h after %h", d_client,
							d_tag, last_seq[d_client]);
					end
					last_seq[d_client] = d_client == DC ? d_tag : d_tag[6:0];
					n_done[d_client] = n_done[d_client] + 1;
					if (dut.grant.p_v && dut.grant.p_walk && d_client != dut.grant.p_client)
						park_pass = park_pass + 1;
				end
			end
			if (dut.grant.g_valid && dut.grant.g_ready && dut.grant.sel_w)
				walks = walks + 1;
			if ((dut.grant.j_v || dut.grant.p_v) && chk_idle) begin
				perr = perr + 1;
				$display("FAIL atg_mc_prot.park: chk_idle with a request in J or P");
			end
			if (fault) begin
				if (fault_mem)
					n_fault_mem = n_fault_mem + 1;
				else if (fault_client < N && fault_prot)
					n_fault_prot[fault_client] = n_fault_prot[fault_client] + 1;
				else if (fault_client < N)
					n_fault_aper[fault_client] = n_fault_aper[fault_client] + 1;
				if (fault_prot && fault_slot != 0 && fault_slot != fault_client) begin
					errors = errors + 1;
					$display("FAIL atg_mc_prot.vec: fault slot %0d for client %0d", fault_slot,
						fault_client);
				end
			end
		end
	end

	task group;
		input [8*8-1:0] name;
		input integer before;
		begin
			if (errors == before)
				$display("PASS atg_mc_prot.%0s", name);
			else
				$display("FAIL atg_mc_prot.%0s: %0d errors", name, errors - before);
		end
	endtask

	/* ------------------------------------------------ directed */

	task inv;
		input [19:0] gg;
		input [31:0] nn;
		begin
			@(negedge clk);
			inv_valid = 1'b1;
			inv_g = gg;
			inv_n = nn;
			@(negedge clk);
			inv_valid = 1'b0;
			while (inv_pending)
				@(negedge clk);
		end
	endtask

	task set_byte;
		input [19:0] gg;
		input [7:0] v;
		begin
			tab[gg - ap_base[31:12]] = v;
			mem.mem[tbase + gg - ap_base[31:12]] = v;
		end
	endtask

	/* A directed request of client c; expect bad = 1 for a refusal. */
	task dreq;
		input integer c;
		input wr, chk;
		input [31:0] addr;
		input bad;
		input [8*8-1:0] name;
		reg e;
		begin
			case (c)
			1: begin cl[1].c.direct(wr, chk, 1'b0, chk ? 6'd1 : 6'd0, addr, 32'hFFFFFFFF);
				e = cl[1].c.d_err; end
			2: begin cl[2].c.direct(wr, chk, 1'b0, chk ? 6'd2 : 6'd0, addr, 32'hFFFFFFFF);
				e = cl[2].c.d_err; end
			default: begin cl[0].c.direct(wr, 1'b0, 1'b0, 6'd0, addr, 32'hFFFFFFFF);
				e = cl[0].c.d_err; end
			endcase
			if (e != bad) begin
				errors = errors + 1;
				$display("FAIL atg_mc_prot.%0s: client %0d %h error %b, expected %b", name, c,
					addr, e, bad);
			end
		end
	endtask

	integer fd, r, i, b, before;
	reg [31:0] x0, x1, x2, x3, x4, x5;
	reg [8*8-1:0] kind;
	reg race_pend;

	initial begin
		ap_base = 0;
		ap_limit = 0;
		tbase = 0;
		for (i = 0; i < 4096; i = i + 1)
			tab[i] = 8'd0;
		repeat (4) @(posedge clk);
		rst_n <= 1'b1;
		fd = $fopen("sim/vec/prot.txt", "r");
		if (fd == 0) begin
			$display("FAIL atg_mc_prot: no sim/vec/prot.txt");
			$finish;
		end
		r = $fscanf(fd, "%s", kind);
		while (r == 1 && kind != "E") begin
			if (kind == "A") begin
				r = $fscanf(fd, "%h %h", x0, x1);
				ap_base = x0;
				ap_limit = x1;
			end else if (kind == "T") begin
				r = $fscanf(fd, "%h", x0);
				tbase = x0;
			end else if (kind == "B") begin
				r = $fscanf(fd, "%h %h", x0, x1);
				tab[x0] = x1;
				mem.mem[tbase + x0] = x1;
			end else if (kind == "G") begin
				r = $fscanf(fd, "%h %h %h %h %h %h", x0, x1, x2, x3, x4, x5);
				@(negedge clk);
				gw_valid = 1'b1;
				gw_idx = x0;
				gw_data = {x5[20:0], x4[19:0], x3[0], x2[0], x1[5:0], 1'b1};
				@(negedge clk);
				gw_valid = 1'b0;
			end else begin
				x0 = $fgetc(fd);
				while (x0 != 10 && x0 != -1)
					x0 = $fgetc(fd);
			end
			r = $fscanf(fd, "%s", kind);
		end
		$fclose(fd);
		repeat (4) @(posedge clk);
		dc_run <= 1'b1;
		start <= 1'b1;
		wait (fin == 4'b1111);
		repeat (20) @(posedge clk);

		/* vec: the clients' checks and the fault counts. */
		before = errors;
		for (i = 0; i < 4; i = i + 1) begin
			errors = errors + cerr[i];
			if (n_fault_prot[i] != cprot[i] || n_fault_aper[i] != caper[i]) begin
				errors = errors + 1;
				$display("FAIL atg_mc_prot.vec: client %0d faults %0d prot %0d aperture, model %0d %0d",
					i, n_fault_prot[i], n_fault_aper[i], cprot[i], caper[i]);
			end
		end
		if (n_fault_mem != 0) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.vec: %0d memory faults", n_fault_mem);
		end
		group("vec", before);
		before = errors;
		errors = errors + oerr;
		group("order", before);
		before = errors;
		errors = errors + perr;
		if (park_pass == 0 || walks == 0) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.park: %0d walks, %0d grants past the park", walks,
				park_pass);
		end
		if (!chk_idle) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.park: no chk_idle at the end");
		end
		group("park", before);
		before = errors;
		if (dc_max > DC_WAIT || dc_n < 100) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.dc: %0d reads, longest wait %0d cycles", dc_n, dc_max);
		end
		group("dc", before);
		before = errors;
		for (i = 0; i < 4096; i = i + 1)
			if (mem.mem[tbase + i] !== tab[i]) begin
				errors = errors + 1;
				$display("FAIL atg_mc_prot.mem: table byte %h", i);
			end
		cl[0].c.check_mem;
		cl[1].c.check_mem;
		cl[2].c.check_mem;
		cl[3].c.check_mem;
		for (i = 0; i < 4; i = i + 1)
			errors = errors + cerr[i];
		group("mem", before);

		/* The directed groups run without the DC, so that the AXI master is ready. */
		dc_run <= 1'b0;
		repeat (40) @(posedge clk);

		/* inv: granule 0x50 to slot 1, then to slot 2. */
		before = errors;
		set_byte(20'h50, 8'd1);
		inv(20'h50, 32'd1);
		dreq(1, 0, 1, 32'h00050020, 0, "inv");
		dreq(2, 0, 1, 32'h00050040, 1, "inv");
		set_byte(20'h50, 8'd2);
		inv(20'h50, 32'd1);
		dreq(1, 0, 1, 32'h00050020, 1, "inv");
		dreq(2, 0, 1, 32'h00050040, 0, "inv");
		group("inv", before);

		/* race: the owner changes (2 -> 1) while the walk is out. */
		before = errors;
		inv(20'h0, 32'd0);
		race_pend = 1'b0;
		fork
			dreq(1, 0, 1, 32'h00050020, 0, "race");
			begin
				b = 0;
				while (!(arvalid && arready &&
				    araddr[31:5] == tbase[31:5] + ((20'h50 - ap_base[31:12]) >> 5)) &&
				    b < 2000) begin
					@(posedge clk);
					b = b + 1;
				end
				@(negedge clk);
				set_byte(20'h50, 8'd1);
				inv_valid = 1'b1;
				inv_g = 20'h50;
				inv_n = 32'd1;
				@(negedge clk);
				inv_valid = 1'b0;
				race_pend = inv_pending;
			end
		join
		if (!race_pend) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.race: no inv_pending while the walk was out");
		end
		if (inv_pending) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.race: inv_pending stays");
		end
		group("race", before);

		/* recheck: a grant of granule 0x51 to slot 2, removed while in J. */
		before = errors;
		@(negedge clk);
		gw_valid = 1'b1;
		gw_idx = 3'd7;
		gw_data = {21'h52, 20'h51, 1'b0, 1'b1, 6'd2, 1'b1};
		@(negedge clk);
		gw_valid = 1'b0;
		dreq(2, 0, 1, 32'h00051040, 0, "recheck");
		fork
			dreq(2, 0, 1, 32'h00051040, 1, "recheck");
			begin
				@(negedge clk);
				b = 0;
				while (!dut.grant.j_v && b < 2000) begin
					@(negedge clk);
					b = b + 1;
				end
				gw_valid = 1'b1;
				gw_data = 50'd0;
				@(negedge clk);
				gw_valid = 1'b0;
			end
		join
		group("recheck", before);

		/* walkerr: a table at an address that answers SLVERR. */
		before = errors;
		tbase = WBASE;
		inv(20'h0, 32'd0);
		dreq(1, 0, 1, 32'h00050020, 1, "walkerr");
		if (n_fault_mem != 1) begin
			errors = errors + 1;
			$display("FAIL atg_mc_prot.walkerr: %0d memory faults", n_fault_mem);
		end
		group("walkerr", before);

		repeat (20) @(posedge clk);
		errors = errors + mem.errors;
		$display("atg_mc_prot: %0d walks, %0d grants past the park, DC wait up to %0d of %0d reads",
			walks, park_pass, dc_max, dc_n);
		if (errors == 0)
			$display("PASS atg_mc_prot");
		else
			$display("FAIL atg_mc_prot: %0d errors (%0d walks, %0d past the park, DC wait %0d)",
				errors, walks, park_pass, dc_max);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL atg_mc_prot: timeout");
		$finish;
	end

	wire unused_ok = &{1'b0, axi_idle, fault_write, fault_addr, unit_idle, gerr};
endmodule

`default_nettype wire
