/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * atg_top_prot_tb.vh: the driver's side of atg_top_prot_tb (included in
 * the module): the bring-up in the driver's order, the ring's packets
 * (the ring-only gpu-ops, GHCI_FRAME, the FENCE with a session's tag) and
 * the staged records of a frame.  Uses the module's mem, host_* tasks,
 * wp, sp, fence_value, errors and its localparams.
 */

/* Waits until STATUS.STATE reads `state` (2000 polls at most). */
task wait_state;
	input [3:0] state;
	reg [31:0] got;
	integer polls;
	begin
		polls = 0;
		host_read(GHCI_STATUS, got);
		while (got[19:16] != state && polls < 40000) begin
			host_read(GHCI_STATUS, got);
			polls = polls + 1;
		end
		if (got[19:16] != state) begin
			errors = errors + 1;
			$display("FAIL atg_top_prot: STATUS %h, waiting for state %0d", got, state);
		end
	end
endtask

/* Waits until a register's masked bits read `want`. */
task wait_reg;
	input [16:0] reg_off;
	input [31:0] want;
	input [31:0] mask;
	input integer polls;
	reg [31:0] got;
	integer n;
	begin
		n = 0;
		host_read(reg_off, got);
		while ((got & mask) != (want & mask) && n < polls) begin
			host_read(reg_off, got);
			n = n + 1;
		end
		if ((got & mask) != (want & mask)) begin
			errors = errors + 1;
			$display("FAIL atg_top_prot: reg %h stays %h, waiting for %h", reg_off, got, want);
		end
	end
endtask

/*
 * The driver's order (design §17.3): APERTURE (not at 0), the ring, RUN
 * and the firmware, the table zeroed by the CPU, PROT_TABLE, then
 * GHCI_HEAP (its result at RING_RESULT + 56).  Also after CTRL.RESET.
 */
task bring_up;
	integer i;
	begin
		wp = 0;
		host_write(GHCI_APERTURE_BASE, APERTURE);
		host_write(GHCI_APERTURE_LIMIT, 32'h00100000);
		host_write(GHCI_RING_BASE, RING);
		host_write(GHCI_RING_SIZE, 32'd10);
		host_write(GHCI_IRQ_STATUS, 32'h1FF);
		mem.poke32(FENCES, fence_value);
		host_write(GHCI_FENCE_LAST, fence_value);
		host_write(GHCI_CPFW_CTRL, 32'd1 << GHCI_CPFW_CTRL_RUN);
		wait_reg(GHCI_CPFW_STATUS, 32'h0201, 32'hFF09, 20000);
		host_write(GHCI_CTRL, 32'd1 << GHCI_CTRL_RUN);
		for (i = 0; i < 1024; i = i + 1)
			mem.poke32(TABLE + i * 4, 32'd0);
		host_write(prot[16:0] + GHCI_PROT_TABLE, TABLE);
		for (i = 0; i < 16; i = i + 1)
			mem.poke32(RING_RESULT + i * 4, NO_RESULT);
		ring_put({2'b10, 6'd0, 8'd0, 16'd8});
		ring_put(32'h00010108);	/* GHCI_HEAP */
		ring_put(32'd2);
		ring_put(RING_RESULT + 56);
		ring_put(HEAP);
		ring_put(32'd0);
		ring_put(HEAP_BYTES);
		ring_put(32'd0);
		ring_put(32'd4);
		ring_doorbell;
		if (mem.peek32(RING_RESULT + 56) != 32'd0) begin
			errors = errors + 1;
			$display("FAIL atg_top_prot: GHCI_HEAP %h", mem.peek32(RING_RESULT + 56));
		end
	end
endtask

task ring_put;
	input [31:0] value;
	begin
		mem.poke32(RING + wp * 4, value);
		wp = (wp + 1) % RING_N;
	end
endtask

/* The driver's FENCE after a packet, with the session's tag (class 0: not checked). */
task ring_fence;
	input [7:0] tag;
	begin
		fence_value = fence_value + 1;
		ring_put({2'b00, 6'd5, tag, 8'd1, 8'd2});
		ring_put(FENCES);
		ring_put(fence_value);
	end
endtask

/* A FENCE, the doorbell, and the wait for the fence. */
task ring_doorbell;
	begin
		ring_fence(8'd0);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 40000);
	end
endtask

/* GHCI_SESSION_OPEN of a tag with flags; its result at RING_RESULT + slot * 8. */
task ring_open;
	input [7:0] tag;
	input [31:0] flags;
	input integer slot;
	begin
		ring_put({2'b10, 6'd0, tag, 16'd7});
		ring_put(32'h00010100);
		ring_put(32'd2);
		ring_put(RING_RESULT + slot * 8);
		ring_put({24'd0, tag});
		ring_put(flags);
		ring_put(32'h00040000);	/* heap limit */
		ring_put(32'd0);
		ring_doorbell;
	end
endtask

/* GHCI_BUFFER_GRANT(tag, read, the area): its result at RING_RESULT + slot * 8. */
task ring_grant;
	input [7:0] tag;
	input [31:0] base;
	input integer slot;
	begin
		ring_put({2'b10, 6'd0, 8'd0, 16'd9});
		ring_put(32'h00010106);
		ring_put(32'd2);
		ring_put(RING_RESULT + slot * 8);
		ring_put({24'd0, tag});
		ring_put(32'd1);	/* GHCI_GRANT_READ */
		ring_put(base);
		ring_put(32'd0);
		ring_put(AREA_BYTES);
		ring_put(32'd0);
		ring_doorbell;
	end
endtask

/* GHCI_BUFFER_REVOKE(tag, the area): its result at RING_RESULT + slot * 8. */
task ring_revoke;
	input [7:0] tag;
	input [31:0] base;
	input integer slot;
	begin
		ring_put({2'b10, 6'd0, 8'd0, 16'd8});
		ring_put(32'h00010107);
		ring_put(32'd2);
		ring_put(RING_RESULT + slot * 8);
		ring_put({24'd0, tag});
		ring_put(base);
		ring_put(32'd0);
		ring_put(AREA_BYTES);
		ring_put(32'd0);
		ring_doorbell;
	end
endtask

/* GHCI_FRAME of the staging's first sp words, with the session's tag. */
task ring_frame;
	input [7:0] tag;
	input integer records;
	begin
		ring_put({2'b10, 6'd0, tag, 16'd8});
		ring_put(32'h00010105);
		ring_put(32'd2);
		ring_put(FRAME_RESULT);
		ring_put(STAGING);
		ring_put(32'd0);
		ring_put(sp * 4);
		ring_put(RESULTS);
		ring_put(records);
	end
endtask

/* Runs the staged frame, then the session's FENCE, and waits for it. */
task frame_run;
	input [7:0] tag;
	input integer records;
	begin
		ring_frame(tag, records);
		ring_fence(tag);
		host_write(GHCI_RING_WPTR, wp);
		wait_reg(GHCI_FENCE_LAST, fence_value, 32'hFFFFFFFF, 40000);
	end
endtask

/* An empty staging and result page. */
task frame_begin;
	integer i;
	begin
		sp = 0;
		for (i = 0; i < 64; i = i + 1)
			mem.poke32(RESULTS + i * 4, NO_RESULT);
		mem.poke32(FRAME_RESULT, NO_RESULT);
	end
endtask

/* 1 when the frame and each of its records succeeded (a recorded command has no result). */
function results_ok;
	input integer records;
	integer i;
	reg [31:0] r;
	begin
		results_ok = mem.peek32(FRAME_RESULT) == 32'd0;
		for (i = 0; i < records; i = i + 1) begin
			r = mem.peek32(RESULTS + i * 8);
			if (r != 32'd0 && r != NO_RESULT)
				results_ok = 1'b0;
		end
	end
endfunction

/* The table's byte of an address's granule. */
function [31:0] table_byte;
	input [31:0] address;
	reg [31:0] word;
	reg [31:0] at;
	begin
		at = TABLE + (address >> 12) - (APERTURE >> 12);
		word = mem.peek32(at & 32'hFFFFFFFC);
		table_byte = (word >> ((at & 3) * 8)) & 32'hFF;
	end
endfunction

task st;
	input [31:0] value;
	begin
		mem.poke32(STAGING + sp * 4, value);
		sp = sp + 1;
	end
endtask

task st64;
	input [63:0] value;
	begin
		st(value[31:0]);
		st(value[63:32]);
	end
endtask

/* A record's envelope: [number][REPLY][result index]. */
task rec;
	input [31:0] number;
	input [31:0] index;
	begin
		st(number);
		st(32'd1);
		st(index);
	end
endtask

/* A recorded command's envelope (no result). */
task cmd;
	input [31:0] number;
	begin
		st(number);
		st(32'd0);
		st(NO_RESULT);
	end
endtask

/* GHCI_MEMORY of an area (flags [1] IMPORTED). */
task memory;
	input [31:0] index;
	input [63:0] id;
	input [31:0] base;
	input [31:0] flags;
	begin
		rec(32'h00010102, index);
		st64(id);
		st64(base);
		st64(AREA_BYTES);
		st(flags);
	end
endtask

/* CREATE_BUFFER of 0x2000 bytes and BIND_BUFFER_MEMORY: records index and index + 1. */
task buffer;
	input [31:0] index;
	input [63:0] id;
	input [63:0] memory_id;
	input [63:0] offset;
	begin
		rec(32'd50, index);
		st64(64'h1);
		st64(64'h1);
		st(32'd12);
		st64(64'h0);
		st(32'd0);
		st64(64'h2000);
		st(32'h3);
		st(32'd0);
		st(32'd0);
		st64(64'h0);
		st64(64'h0);
		st64(64'h1);
		st64(id);
		rec(32'd28, index + 1);
		st64(64'h1);
		st64(id);
		st64(memory_id);
		st64(offset);
	end
endtask

/* CREATE_COMMAND_POOL. */
task pool;
	input [31:0] index;
	input [63:0] id;
	begin
		rec(32'd85, index);
		st64(64'h1);
		st64(64'h1);
		st(32'd39);
		st64(64'h0);
		st(32'd0);
		st(32'd0);
		st64(64'h0);
		st64(64'h1);
		st64(id);
	end
endtask

/* ALLOCATE_COMMAND_BUFFERS of one from pool 0x300 and BEGIN (one-time): records index, index + 1. */
task begin_cb;
	input [31:0] index;
	input [63:0] cb;
	begin
		rec(32'd88, index);
		st64(64'h1);
		st64(64'h1);
		st(32'd40);
		st64(64'h0);
		st64(64'h300);
		st(32'd0);
		st(32'd1);
		st64(64'h1);
		st64(cb);
		rec(32'd90, index + 1);
		st64(cb);
		st64(64'h1);
		st(32'd42);
		st64(64'h0);
		st(32'd1);
		st64(64'h0);
	end
endtask

/* END_COMMAND_BUFFER and QUEUE_SUBMIT: records index, index + 1. */
task submit_cb;
	input [31:0] index;
	input [63:0] cb;
	begin
		rec(32'd91, index);
		st64(cb);
		rec(32'd18, index + 1);
		st64(64'h9);
		st(32'd1);
		st64(64'h1);
		st(32'd4);
		st64(64'h0);
		st(32'd0);
		st64(64'h0);
		st64(64'h0);
		st(32'd1);
		st64(64'h1);
		st64(cb);
		st(32'd0);
		st64(64'h0);
		st64(64'h0);
	end
endtask

/* A command buffer that fills a buffer's 0x2000 bytes: records index to index + 4. */
task fill;
	input [31:0] index;
	input [63:0] cb;
	input [63:0] buf_id;
	input [31:0] data;
	begin
		begin_cb(index, cb);
		cmd(32'd118);	/* CMD_FILL_BUFFER */
		st64(cb);
		st64(buf_id);
		st64(64'h0);
		st64(64'h2000);
		st(data);
		submit_cb(index + 3, cb);
	end
endtask

/* A command buffer that copies 0x1000 bytes between buffers: records index to index + 4. */
task copy;
	input [31:0] index;
	input [63:0] cb;
	input [63:0] src;
	input [63:0] dst;
	begin
		begin_cb(index, cb);
		cmd(32'd112);	/* CMD_COPY_BUFFER */
		st64(cb);
		st64(src);
		st64(dst);
		st(32'd1);
		st64(64'h1);
		st64(64'h0);
		st64(64'h0);
		st64(64'h1000);
		submit_cb(index + 3, cb);
	end
endtask
