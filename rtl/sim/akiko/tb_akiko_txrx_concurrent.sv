// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_akiko_txrx_concurrent -- a guest command in flight while an unsolicited
// drive->host frame is delivered. That is exactly what inserting a disc at the
// CD32 no-disc animation does: the ROM is polling with commands when the bridge
// pushes the 0a 01 media announce.
//
// Field evidence being chased (2026-08-14 reject capture):
//   CMD    op=0x05 n=3 bytes=55 01 a9
//   REJECT cksum n=3 expected=3 sum=76 bytes=75 01 00   <- last byte zeroed
//   REJECT cksum n=2 expected=2 sum=00 bytes=00 00      x ~50
// i.e. the command buffer is fed ZEROS, and a long run of them.
//
// The bench sweeps the RX injection point across the whole TX transfer and
// checks, for every offset, that the TX ring delivered exactly its 3 bytes and
// that cdcomtxinx landed on cdcomtxcmp instead of running past it.

`timescale 1ns / 1ps

module tb_akiko_txrx_concurrent;

initial begin
	#2000000 $fatal(1, "tb_akiko_txrx_concurrent: watchdog timeout");
end

logic clk = 0;
initial forever #5 clk = ~clk;

logic        reset = 1;
logic        cs    = 0;
logic        rd    = 0;
logic        wr    = 0;
logic        lds   = 0;
logic        uds   = 0;
logic [5:1]  addr  = 0;
logic [15:0] din   = 0;
wire  [15:0] dout;
wire         irq;

wire        dma_req;
wire        dma_we;
wire [23:0] dma_baddr;
wire  [7:0] dma_wbyte;
logic [7:0] dma_rbyte;
logic       dma_ack;
logic       dma_arm;

akiko #(.NATIVE_CD32(1)) u_dut (
	.clk(clk), .reset(reset),
	.cs(cs), .rd(rd), .wr(wr),
	.lds(lds), .uds(uds),
	.addr(addr), .din(din), .dout(dout),
	.akiko_irq(irq),
	.dma_req(dma_req), .dma_we(dma_we),
	.dma_baddr(dma_baddr), .dma_wbyte(dma_wbyte),
	.dma_rbyte(dma_rbyte), .dma_ack(dma_ack), .dma_arm(dma_arm),
	.hps_cmd_pending(), .hps_cmd_byte(),
	.hps_cmd_pop(1'b0), .hps_cmd_done(1'b0),
	.hps_result_push(1'b0), .hps_result_byte(8'h00), .hps_result_done(1'b0),
	.hps_sec_req(), .hps_sec_status(),
	.hps_sec_push(1'b0), .hps_sec_word(16'h0000), .hps_sec_done(1'b0),
	.hps_rx_busy(),
	.hps_nvr_addr(10'd0),
	.hps_nvr_dout(), .hps_nvr_clear_dirty(1'b0), .hps_nvr_dirty(),
	.nvr_load_addr(10'd0), .nvr_load_din(8'h00), .nvr_load_we(1'b0)
);

localparam [31:0] CFG_TXD = 32'h40000000;
localparam [31:0] CFG_RXD = 32'h20000000;

int checks = 0;
int errs   = 0;

task automatic bus_write_word(input [5:1] a, input [15:0] data);
	@(posedge clk);
	cs <= 1; wr <= 1; lds <= 1; uds <= 1; addr <= a; din <= data;
	@(posedge clk);
	cs <= 0; wr <= 0; lds <= 0; uds <= 0;
endtask

task automatic bus_write_byte_lo(input [5:1] a, input [7:0] data);
	@(posedge clk);
	cs <= 1; wr <= 1; lds <= 1; uds <= 0; addr <= a; din <= {8'h00, data};
	@(posedge clk);
	cs <= 0; wr <= 0; lds <= 0;
endtask

task automatic bus_write_long(input [5:1] a_hi, input [31:0] data);
	bus_write_word(a_hi,        data[31:16]);
	bus_write_word(a_hi + 5'd1, data[15:0]);
endtask

logic [7:0] mem [65536];

logic bfm_in_xfer = 1'b0;

initial begin
	dma_ack   = 0;
	dma_arm   = 0;
	dma_rbyte = 8'h00;
	for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
end

always @(posedge clk) begin
	dma_ack <= 0;
	dma_arm <= 0;
	if (bfm_in_xfer) begin
		if (dma_we) mem[dma_baddr[15:0]] <= dma_wbyte;
		else        dma_rbyte            <= mem[dma_baddr[15:0]];
		dma_ack     <= 1'b1;
		bfm_in_xfer <= 1'b0;
	end else if (dma_req && !dma_ack) begin
		bfm_in_xfer <= 1'b1;
		dma_arm     <= 1'b1;
	end
end

task automatic do_reset;
	reset <= 1;
	@(posedge clk); @(posedge clk); @(posedge clk);
	reset <= 0;
	@(posedge clk);
endtask

task automatic set_misc_base(input [23:0] base);
	bus_write_long(5'b01010, {8'h00, base});
endtask

task automatic set_config(input [31:0] flags);
	bus_write_long(5'b10010, flags);
endtask

task automatic write_txcmp(input [7:0] v); bus_write_byte_lo(5'b01110, v); endtask
task automatic write_rxcmp(input [7:0] v); bus_write_byte_lo(5'b01111, v); endtask

// The real frame from the reject capture.
localparam byte unsigned CMD [3] = '{8'h75, 8'h01, 8'h89};
// The unsolicited media announce the bridge pushes on a disc insert.
localparam byte unsigned ANN [3] = '{8'h0a, 8'h01, 8'hf4};

// ------------------------------------------------------------ runaway monitor
// cdcomtxinx must never advance once it has reached cdcomtxcmp.
int  runaway_hits;
byte unsigned last_txinx;
always @(posedge clk) begin
	if (!reset) begin
		if (u_dut.g_cd.cdcomtxinx != last_txinx) begin
			if (last_txinx == u_dut.g_cd.cdcomtxcmp) runaway_hits++;
		end
		last_txinx <= u_dut.g_cd.cdcomtxinx;
	end
end

int bad_offsets;

task automatic run_offset(input int delay_cycles, input bit quiet);
	int i;
	bit ok;
	do_reset();
	bus_write_long(5'b00100, 32'hFF000000);
	set_misc_base(24'h010000);

	// TX ring at misc|0x200; the rest of the ring is zero, standing in for the
	// unwritten ring memory a runaway would fetch.
	for (i = 0; i < 256; i++) mem[16'h0200 + i] = 8'h00;
	for (i = 0; i < 3;   i++) mem[16'h0200 + i] = CMD[i];
	for (i = 0; i < 32;  i++) mem[16'h0000 + i] = 8'h00;

	u_dut.g_cd.cdrom_command_length = 6'd0;
	u_dut.g_cd.cdcomtxinx           = 8'd0;
	u_dut.g_cd.cdcomrxinx           = 8'd0;
	for (i = 0; i < 3; i++) u_dut.g_cd.cdrom_result_buffer[i] = ANN[i];

	runaway_hits = 0;
	last_txinx   = 8'd0;

	set_config(CFG_TXD | CFG_RXD);
	write_txcmp(8'd3);

	// The announce lands `delay_cycles` into the guest's command transfer.
	repeat (delay_cycles) @(posedge clk);
	u_dut.g_cd.cdrom_receive_length = 6'd3;
	u_dut.g_cd.cdrom_receive_offset = 6'd0;
	write_rxcmp(8'd3);

	repeat (400) @(posedge clk);

	ok = 1;
	for (i = 0; i < 3; i++)
		if (u_dut.g_cd.cdrom_command_buffer[i] !== CMD[i]) ok = 0;
	if (u_dut.g_cd.cdcomtxinx !== 8'd3)                  ok = 0;
	if (u_dut.g_cd.cdrom_command_length !== 6'd3)        ok = 0;
	if (runaway_hits != 0)                               ok = 0;
	// The announce itself must land in the RX ring intact.
	for (i = 0; i < 3; i++)
		if (mem[16'h0000 + i] !== ANN[i]) ok = 0;

	checks++;
	if (!ok) begin
		bad_offsets++;
		errs++;
		$display("  FAIL delay=%0d: cmdbuf=%02h %02h %02h  txinx=%02h txcmp=%02h cmdlen=%0d runaway=%0d  rxmem=%02h %02h %02h",
		         delay_cycles,
		         u_dut.g_cd.cdrom_command_buffer[0],
		         u_dut.g_cd.cdrom_command_buffer[1],
		         u_dut.g_cd.cdrom_command_buffer[2],
		         u_dut.g_cd.cdcomtxinx, u_dut.g_cd.cdcomtxcmp,
		         u_dut.g_cd.cdrom_command_length, runaway_hits,
		         mem[16'h0000], mem[16'h0001], mem[16'h0002]);
	end else if (!quiet) begin
		$display("  ok   delay=%0d: cmdbuf=%02h %02h %02h txinx=%02h", delay_cycles,
		         u_dut.g_cd.cdrom_command_buffer[0],
		         u_dut.g_cd.cdrom_command_buffer[1],
		         u_dut.g_cd.cdrom_command_buffer[2],
		         u_dut.g_cd.cdcomtxinx);
	end
endtask

initial begin
	int d;
	$display("tb_akiko_txrx_concurrent starting");
	@(posedge clk);

	$display("--- announce injected at every offset across the command transfer ---");
	bad_offsets = 0;
	for (d = 0; d < 48; d++) run_offset(d, 1);

	$display("");
	$display("offsets tested = 48, failing = %0d", bad_offsets);
	$display("checks=%0d errs=%0d", checks, errs);
	if (errs == 0) $display("RESULT: PASS - concurrent announce never corrupted the command stream");
	else           $display("RESULT: FAIL - concurrent announce corrupts the command stream");
	$finish;
end

endmodule
