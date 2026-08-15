// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_akiko_cmdstream -- end-to-end CD32 command stream: guest queues commands
// into the TX ring, Akiko DMAs them into the command buffer, the host drains
// them exactly the way akiko_cd32.cpp does (pop count decided by the OPCODE,
// not by how many bytes the RTL actually holds), with an unsolicited media
// announce injected concurrently.
//
// Hunting the 2026-08-14 field signature:
//   REJECT cksum n=3 expected=3 sum=76 bytes=75 01 00
//   REJECT cksum n=2 expected=2 sum=00 bytes=00 00   x ~50
// i.e. the host is handed ZEROS -- bytes the TX DMA never fetched from a
// guest-written ring position.
//
// Two direct detectors, both of which would be invisible on real hardware:
//   pop_beyond : host popped a buffer slot at or past cdrom_command_length
//   runaway    : cdcomtxinx advanced when it had already reached cdcomtxcmp

`timescale 1ns / 1ps

module tb_akiko_cmdstream;

initial begin
	#20000000 $fatal(1, "tb_akiko_cmdstream: watchdog timeout");
end

logic clk = 0;
initial forever #5 clk = ~clk;

logic        reset = 1;
logic        cs    = 0;
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

wire        hps_cmd_pending;
wire  [7:0] hps_cmd_byte;
logic       hps_cmd_pop  = 0;
logic       hps_cmd_done = 0;

akiko #(.NATIVE_CD32(1)) u_dut (
	.clk(clk), .reset(reset),
	.cs(cs), .rd(1'b0), .wr(wr),
	.lds(lds), .uds(uds),
	.addr(addr), .din(din), .dout(dout),
	.akiko_irq(irq),
	.dma_req(dma_req), .dma_we(dma_we),
	.dma_baddr(dma_baddr), .dma_wbyte(dma_wbyte),
	.dma_rbyte(dma_rbyte), .dma_ack(dma_ack), .dma_arm(dma_arm),
	.hps_cmd_pending(hps_cmd_pending), .hps_cmd_byte(hps_cmd_byte),
	.hps_cmd_pop(hps_cmd_pop), .hps_cmd_done(hps_cmd_done),
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

// ------------------------------------------------------------------ guest bus
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

task automatic set_misc_base(input [23:0] base);
	bus_write_word(5'b01010, {8'h00, base[23:16]});
	bus_write_word(5'b01011, base[15:0]);
endtask

task automatic set_config(input [31:0] flags);
	bus_write_word(5'b10010, flags[31:16]);
	bus_write_word(5'b10011, flags[15:0]);
endtask

task automatic write_txcmp(input [7:0] v); bus_write_byte_lo(5'b01110, v); endtask
task automatic write_rxcmp(input [7:0] v); bus_write_byte_lo(5'b01111, v); endtask

// ------------------------------------------------------------------- chip RAM
logic [7:0] mem [65536];
logic       bfm_in_xfer = 1'b0;
int         bfm_latency = 0;
int         bfm_cnt     = 0;

initial begin
	dma_ack   = 0;
	dma_arm   = 0;
	dma_rbyte = 8'h00;
	for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
end

// chipdma_arb latches address, direction and write data at the arm instant
// (ak_addr_w / ak_rw_w / ak_wr_data_w are all `arm_now ? live_... : held`), so
// the BFM must too. Sampling them at ack time instead lets a later busy-flag
// change re-point the transfer, which fabricates duplicated bytes that the real
// arbiter cannot produce.
logic [23:0] lat_baddr;
logic        lat_we;
logic  [7:0] lat_wbyte;

always @(posedge clk) begin
	dma_ack <= 0;
	dma_arm <= 0;
	if (bfm_in_xfer) begin
		if (bfm_cnt != 0) begin
			bfm_cnt <= bfm_cnt - 1;
		end else begin
			if (lat_we) mem[lat_baddr[15:0]] <= lat_wbyte;
			else        dma_rbyte            <= mem[lat_baddr[15:0]];
			dma_ack     <= 1'b1;
			bfm_in_xfer <= 1'b0;
		end
	end else if (dma_req && !dma_ack) begin
		bfm_in_xfer <= 1'b1;
		dma_arm     <= 1'b1;
		bfm_cnt     <= bfm_latency;
		lat_baddr   <= dma_baddr;
		lat_we      <= dma_we;
		lat_wbyte   <= dma_wbyte;
	end
end

// ---------------------------------------------------------------- host tables
function automatic int host_total(input [7:0] b0);
	int pl;
	case (b0[3:0])
		4'h0: pl = 1;  4'h1: pl = 2;  4'h2: pl = 1;  4'h3: pl = 1;
		4'h4: pl = 12; 4'h5: pl = 2;  4'h6: pl = 1;  4'h7: pl = 1;
		4'h8: pl = 4;  4'h9: pl = 1;  4'ha: pl = 2;
		default: pl = -1;
	endcase
	host_total = (pl < 0) ? 32 : pl + 1;
endfunction

// ------------------------------------------------------------------ detectors
int pop_beyond;
int runaway_hits;
byte unsigned last_txinx;

always @(posedge clk) begin
	if (!reset) begin
		// The host popping at or past cdrom_command_length hands it a buffer
		// slot the TX DMA never wrote -- zeros on real silicon.
		if (hps_cmd_pop && (u_dut.g_cd.hps_cmd_rd_ptr >= u_dut.g_cd.cdrom_command_length))
			pop_beyond++;
		if (u_dut.g_cd.cdcomtxinx != last_txinx)
			if (last_txinx == u_dut.g_cd.cdcomtxcmp) runaway_hits++;
		last_txinx <= u_dut.g_cd.cdcomtxinx;
	end
end

// ---------------------------------------------------------------- host drainer
int  host_frames;
int  host_bad;
byte unsigned rx_frame [32];
bit  host_enabled;
int  host_delay;

task automatic host_service();
	int total, i;
	logic [31:0] sum;
	if (!hps_cmd_pending) return;
	repeat (host_delay) @(posedge clk);
	if (!hps_cmd_pending) return;

	// Exactly akiko_drain_command(): read byte 0, decide the count from its
	// opcode, then pop that many regardless of what the RTL holds. Each spi_w
	// both samples the presented byte and advances the read pointer, so sample
	// first and pop after -- and sample past the NBA region so hps_cmd_byte
	// reflects the pointer the DUT actually settled on.
	i     = 0;
	total = 1;
	while (i < total) begin
		#1;
		rx_frame[i] = hps_cmd_byte;
		if (i == 0) total = host_total(rx_frame[0]);
		hps_cmd_pop <= 1'b1;
		@(posedge clk);
		hps_cmd_pop <= 1'b0;
		i++;
	end
	hps_cmd_done <= 1'b1;
	@(posedge clk);
	hps_cmd_done <= 1'b0;
	@(posedge clk);

	host_frames++;
	sum = 0;
	for (i = 0; i < total; i++) sum += rx_frame[i];
	if ((sum & 32'hff) != 32'hff) begin
		host_bad++;
		if (host_bad <= 3)
			$display("    host REJECT n=%0d bytes=%02h %02h %02h",
			         total, rx_frame[0], rx_frame[1], rx_frame[2]);
	end
endtask

// ---------------------------------------------------------------- frame maker
// Real CD32 frame: counter in the high nibble (never 0), opcode 5, one payload
// byte, then a checksum making the total 0xff.
function automatic byte unsigned chk(input byte unsigned a, input byte unsigned b);
	chk = 8'hff - (a + b);
endfunction

localparam byte unsigned ANN [3] = '{8'h0a, 8'h01, 8'hf4};

// ---------------------------------------------------------------------- runner
task automatic run_case(input int n_cmds, input int lat, input int hdelay,
                        input int ann_delay, input bit tear_base);
	int i, k, guard;
	byte unsigned b0, b1;
	reset <= 1;
	@(posedge clk); @(posedge clk); @(posedge clk);
	reset <= 0;
	@(posedge clk);

	bfm_latency  = lat;
	host_delay   = hdelay;
	host_frames  = 0;
	host_bad     = 0;
	pop_beyond   = 0;
	runaway_hits = 0;
	last_txinx   = 8'd0;

	for (i = 0; i < 65536; i++) mem[i] = 8'h00;

	// Guest lays n_cmds three-byte frames into the TX ring at misc|0x200.
	for (k = 0; k < n_cmds; k++) begin
		b0 = 8'h05 | (((k % 7) + 1) << 4);
		b1 = 8'h01;
		mem[16'h0200 + 3*k + 0] = b0;
		mem[16'h0200 + 3*k + 1] = b1;
		mem[16'h0200 + 3*k + 2] = chk(b0, b1);
	end

	bus_write_word(5'b00100, 16'hFF00);
	bus_write_word(5'b00101, 16'h0000);
	set_misc_base(24'h010000);
	for (i = 0; i < 3; i++) u_dut.g_cd.cdrom_result_buffer[i] = ANN[i];
	set_config(CFG_TXD | CFG_RXD);

	// Guest queues every command up front, the way a driver with a ring does.
	write_txcmp(8'(3 * n_cmds));

	fork
		begin : announce
			repeat (ann_delay) @(posedge clk);
			u_dut.g_cd.cdrom_receive_length = 6'd3;
			u_dut.g_cd.cdrom_receive_offset = 6'd0;
			write_rxcmp(8'd3);
		end
		begin : rebase
			// The ext ROM re-programs the ring base as a pair of word writes.
			// Between them the latched base is torn.
			if (tear_base) begin
				repeat (ann_delay + 4) @(posedge clk);
				bus_write_word(5'b01010, 16'h0002);
				repeat (6) @(posedge clk);
				bus_write_word(5'b01011, 16'h0000);
			end
		end
		begin : drain
			guard = 0;
			while (guard < 40000 && host_frames < n_cmds) begin
				host_service();
				@(posedge clk);
				guard++;
			end
		end
	join

	checks++;
	if (host_bad != 0 || pop_beyond != 0 || runaway_hits != 0) begin
		errs++;
		$display("  FAIL n=%0d lat=%0d hd=%0d ann=%0d tear=%0d : frames=%0d bad=%0d pop_beyond=%0d runaway=%0d txinx=%02h txcmp=%02h",
		         n_cmds, lat, hdelay, ann_delay, tear_base,
		         host_frames, host_bad, pop_beyond, runaway_hits,
		         u_dut.g_cd.cdcomtxinx, u_dut.g_cd.cdcomtxcmp);
	end
endtask

initial begin
	int lat, hd, ann;
	$display("tb_akiko_cmdstream starting");
	@(posedge clk);

	$display("--- sweep: dma latency x host delay x announce offset ---");
	for (lat = 0; lat <= 6; lat = lat + 2)
		for (hd = 0; hd <= 6; hd = hd + 3)
			for (ann = 0; ann < 40; ann = ann + 3)
				run_case(6, lat, hd, ann, 0);

	$display("--- sweep: same, with a torn ring-base rewrite ---");
	for (lat = 0; lat <= 6; lat = lat + 2)
		for (ann = 0; ann < 40; ann = ann + 6)
			run_case(6, lat, 0, ann, 1);

	$display("");
	$display("checks=%0d errs=%0d", checks, errs);
	if (errs == 0) $display("RESULT: PASS - command stream stayed intact everywhere");
	else           $display("RESULT: FAIL - command stream corrupted");
	$finish;
end

endmodule
