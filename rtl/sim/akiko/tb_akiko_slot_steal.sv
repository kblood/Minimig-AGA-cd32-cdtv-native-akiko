// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_akiko_slot_steal -- does chipdma_arb still sample chip_in_rd after the
// chipset has taken the slot back mid-transaction?
//
// chipdma_arb arms on c_7m_rise while minimig_idle (= chip_in_dma & chip_in_rw),
// latches the address, and then counts slot_cnt 0..3 in S_DRIVE before capturing
// chip_in_rd. But it only DRIVES the bus while arb_drive = arb_request &
// minimig_idle. If minimig_idle deasserts during those four cycles the address
// comes off the bus while the counter keeps running, and the capture at
// slot_cnt==3 takes whatever the chipset's own cycle left on chip_in_rd.
//
// The bench preloads the three bytes of a real CD32 command frame (75 01 89,
// from the 2026-08-14 reject capture) and reads them back, with and without a
// chipset access injected at each cycle offset after the arm.

`timescale 1ns / 1ps

module tb_akiko_slot_steal;

initial begin
	#500000 $fatal(1, "tb_akiko_slot_steal: watchdog timeout");
end

logic clk = 0;
initial forever #5 clk = ~clk;

logic c_7m = 0;
logic [1:0] c_7m_div = 0;
always @(posedge clk) begin
	c_7m_div <= c_7m_div + 2'd1;
	if (c_7m_div == 2'd1) begin
		c_7m <= ~c_7m;
		c_7m_div <= 2'd0;
	end
end

logic reset = 1;

logic        akiko_dma_req   = 0;
logic        akiko_dma_we    = 0;
logic [23:0] akiko_dma_baddr = 0;
logic  [7:0] akiko_dma_wbyte = 0;
wire   [7:0] akiko_dma_rbyte;
wire         akiko_dma_ack;
wire         akiko_arm;

logic [24:1] chip_in_addr = 0;
logic        chip_in_l    = 1;
logic        chip_in_u    = 1;
logic        chip_in_rw   = 1;
logic        chip_in_dma  = 1;
logic [15:0] chip_in_wr   = 0;

wire  [24:1] chip_out_addr;
wire         chip_out_l;
wire         chip_out_u;
wire         chip_out_rw;
wire         chip_out_dma;
wire  [15:0] chip_out_wr;
wire  [15:0] chip_in_rd;

chipdma_arb u_dut (
	.clk             (clk             ),
	.reset           (reset           ),
	.c_7m            (c_7m            ),

	.chip_in_addr    (chip_in_addr    ),
	.chip_in_l       (chip_in_l       ),
	.chip_in_u       (chip_in_u       ),
	.chip_in_rw      (chip_in_rw      ),
	.chip_in_dma     (chip_in_dma     ),
	.chip_in_wr      (chip_in_wr      ),

	// Held low: this bench is about the post-arm window, not the arm gate, and
	// tying it off makes the patched module behave exactly like upstream here.
	.cpu_chip_slot_req(1'b0           ),

	.akiko_dma_req   (akiko_dma_req   ),
	.akiko_dma_we    (akiko_dma_we    ),
	.akiko_dma_baddr (akiko_dma_baddr ),
	.akiko_dma_wbyte (akiko_dma_wbyte ),
	.akiko_dma_rbyte (akiko_dma_rbyte ),
	.akiko_dma_ack   (akiko_dma_ack   ),
	.akiko_arm       (akiko_arm       ),

	.cdtv_dma_req    (1'b0            ),
	.cdtv_dma_we     (1'b0            ),
	.cdtv_dma_baddr  (24'h000000      ),
	.cdtv_dma_wbyte  (8'h00           ),
	.cdtv_dma_rbyte  (                ),
	.cdtv_dma_ack    (                ),

	.chip_out_addr   (chip_out_addr   ),
	.chip_out_l      (chip_out_l      ),
	.chip_out_u      (chip_out_u      ),
	.chip_out_rw     (chip_out_rw     ),
	.chip_out_dma    (chip_out_dma    ),
	.chip_out_wr     (chip_out_wr     ),
	.chip_in_rd      (chip_in_rd      ),

	.z2ram_ena       (1'b0            ),
	.z3ram_base0     (5'h00           ),
	.z3ram_ena0      (1'b0            ),
	.z3ram_base1     (4'h0            ),
	.z3ram_ena1      (1'b0            ),

	.ddr_out_addr    (                ),
	.ddr_out_l       (                ),
	.ddr_out_u       (                ),
	.ddr_out_we      (                ),
	.ddr_out_cs      (                ),
	.ddr_out_wr      (                ),
	.ddr_in_ack      (1'b0            ),
	.ddr_in_rd       (16'h0000        )
);

// ---------------------------------------------------------------- chip memory
localparam int LATENCY = 1;

logic [7:0] mem [65536];

logic [15:0] rd_pipe [3];
logic        rd_valid_pipe [3];
logic [15:0] chipRD_r;

assign chip_in_rd = chipRD_r;

wire [15:0] hi_idx = {chip_out_addr[15:1], 1'b0};
wire [15:0] lo_idx = {chip_out_addr[15:1], 1'b1};

logic c_7m_d_stub;
always @(posedge clk) c_7m_d_stub <= c_7m;
wire c_7m_rise_stub = c_7m & ~c_7m_d_stub;

always @(posedge clk) begin
	rd_pipe[2]       <= rd_pipe[1];
	rd_pipe[1]       <= rd_pipe[0];
	rd_valid_pipe[2] <= rd_valid_pipe[1];
	rd_valid_pipe[1] <= rd_valid_pipe[0];
	rd_pipe[0]       <= 16'h0000;
	rd_valid_pipe[0] <= 1'b0;

	if (c_7m_rise_stub & (~chip_out_dma | ~chip_out_rw)) begin
		if (chip_out_rw) begin
			rd_pipe[0][15:8] <= chip_out_u ? 8'h00 : mem[hi_idx];
			rd_pipe[0][7:0]  <= chip_out_l ? 8'h00 : mem[lo_idx];
			rd_valid_pipe[0] <= 1'b1;
		end else begin
			if (~chip_out_u) mem[hi_idx] <= chip_out_wr[15:8];
			if (~chip_out_l) mem[lo_idx] <= chip_out_wr[7:0];
		end
	end

	if (rd_valid_pipe[LATENCY]) chipRD_r <= rd_pipe[LATENCY];
end

// ---------------------------------------------------------------- scoreboard
int checks = 0;
int errs   = 0;

// The TX ring bytes of a real CD32 command frame. Everything else in mem is
// zero, standing in for the blank chip RAM a bitplane fetch would return during
// the insert-disc animation.
localparam int unsigned TXBASE = 24'h000400;
localparam byte unsigned FRAME [3] = '{8'h75, 8'h01, 8'h89};

// A blank address for the chipset to read while it holds the slot.
localparam [24:1] BLANK_WADDR = 24'h008000 >> 1;

task automatic akiko_read_byte(input [23:0] baddr, output [7:0] got,
                               input int steal_at);
	int timeout;
	int since_arm;
	bit armed;
	@(posedge clk);
	akiko_dma_req   <= 1'b1;
	akiko_dma_we    <= 1'b0;
	akiko_dma_baddr <= baddr;
	akiko_dma_wbyte <= 8'h00;
	timeout   = 200;
	since_arm = 0;
	armed     = 0;
	while (!akiko_dma_ack && timeout > 0) begin
		@(posedge clk);
		timeout--;
		if (armed) begin
			// Chipset reclaims the slot `steal_at` cycles after the arm and
			// runs its own read out of blank memory.
			if (since_arm == steal_at && steal_at >= 0) begin
				chip_in_dma  <= 1'b0;
				chip_in_rw   <= 1'b1;
				chip_in_addr <= BLANK_WADDR;
				chip_in_u    <= 1'b0;
				chip_in_l    <= 1'b0;
			end
			if (since_arm == steal_at + 4 && steal_at >= 0) begin
				chip_in_dma <= 1'b1;
				chip_in_u   <= 1'b1;
				chip_in_l   <= 1'b1;
			end
			since_arm++;
		end
		if (akiko_arm) armed = 1;
	end
	if (timeout == 0) begin
		$display("FAIL: timeout waiting for ack (t=%0t)", $time);
		errs++;
		got = 8'hxx;
	end else begin
		got = akiko_dma_rbyte;
	end
	akiko_dma_req <= 1'b0;
	chip_in_dma   <= 1'b1;
	chip_in_rw    <= 1'b1;
	chip_in_u     <= 1'b1;
	chip_in_l     <= 1'b1;
	@(posedge clk);
	@(posedge clk);
endtask

logic [7:0] got;
int corrupt_offsets;

initial begin
	int ii, k, off;
	for (ii = 0; ii < 65536; ii++) mem[ii] = 8'h00;
	for (ii = 0; ii < 3; ii++) begin
		rd_pipe[ii] = 16'h0000;
		rd_valid_pipe[ii] = 1'b0;
	end
	chipRD_r = 16'h0000;
	for (ii = 0; ii < 3; ii++) mem[TXBASE + ii] = FRAME[ii];

	repeat (8) @(posedge clk);
	reset <= 1'b0;
	repeat (8) @(posedge clk);

	// ---- Control: bus stays idle for the whole transaction ----
	$display("--- control: no chipset access during the slot ---");
	for (k = 0; k < 3; k++) begin
		akiko_read_byte(TXBASE + k, got, -1);
		checks++;
		if (got !== FRAME[k]) begin
			$display("FAIL control byte %0d: expected 0x%02h got 0x%02h", k, FRAME[k], got);
			errs++;
		end else begin
			$display("  ok  byte %0d = 0x%02h", k, got);
		end
	end

	// ---- The scenario: chipset takes the slot back mid-transaction ----
	$display("--- steal: chipset reads blank memory N cycles after the arm ---");
	corrupt_offsets = 0;
	for (off = 0; off < 6; off++) begin
		akiko_read_byte(TXBASE + 2, got, off);
		$display("  steal_at=%0d: akiko read 0x%02h (correct = 0x%02h)%s",
		         off, got, FRAME[2], (got === FRAME[2]) ? "" : "   <== CORRUPT");
		if (got !== FRAME[2]) corrupt_offsets++;
	end

	$display("");
	$display("corrupted at %0d of 6 steal offsets", corrupt_offsets);
	if (corrupt_offsets != 0) begin
		$display("RESULT: chipdma_arb CAN return a byte it never fetched.");
	end else begin
		$display("RESULT: arbiter held its data across every steal offset.");
	end
	$display("checks=%0d errs=%0d", checks, errs);
	$finish;
end

endmodule
