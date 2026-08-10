// SPDX-License-Identifier: GPL-3.0-or-later

module cpu_trace #(
	parameter CAPTURE_ENABLE = 1'b1,
	parameter [9:0]  WIN_LEN   = 10'd500,
	parameter [23:0] HB_RELOAD = 24'd2800000
)(
	input             clk,
	input             reset,

	input             cpu_clkena,
	input             cpu_stopped,
	input      [31:0] cpu_addr,
	input       [1:0] cpustate,
	input             skipFetch,
	input             supervisor,
	input       [2:0] chip_ipl,
	input             int2_pending,

	input             uio_cs_trace,
	input             uio_rd,
	output reg  [7:0] uio_dout
);

reg [127:0] ring [0:511];
reg   [8:0] wr_ptr;
reg   [8:0] rd_ptr;
wire        empty = (wr_ptr == rd_ptr);

reg  [31:0] tstamp;
always @(posedge clk) tstamp <= reset ? 32'b0 : tstamp + 1'b1;

reg cpu_stopped_d;
always @(posedge clk)
	if (reset)           cpu_stopped_d <= 1'b0;
	else if (cpu_clkena) cpu_stopped_d <= cpu_stopped;
wire stop_enter = cpu_clkena &  cpu_stopped & ~cpu_stopped_d;
wire stop_exit  = cpu_clkena & ~cpu_stopped &  cpu_stopped_d;

reg is_l2_d;
wire is_l2 = (chip_ipl == 3'b101);
always @(posedge clk)
	if (reset)           is_l2_d <= 1'b0;
	else if (cpu_clkena) is_l2_d <= is_l2;

reg       armed;
reg [9:0] win;
always @(posedge clk) begin
	if (reset) begin
		armed <= 1'b1;
		win   <= 10'd0;
	end else begin
		if (armed & stop_exit) begin
			armed <= 1'b0;
			win   <= WIN_LEN;
		end else if (win != 10'd0) begin
			if (cpu_clkena) win <= win - 1'b1;
		end else if (~armed & empty) begin
			armed <= 1'b1;
		end
	end
end

wire window_ev = (win != 10'd0) & cpu_clkena;

reg [23:0] hb;
reg        hb_pending;
wire       heartbeat_ev = hb_pending & cpu_clkena & (win == 10'd0);
always @(posedge clk) begin
	if (reset) begin
		hb         <= HB_RELOAD;
		hb_pending <= 1'b0;
	end else begin
		if (hb == 24'd0) begin
			hb         <= HB_RELOAD;
			hb_pending <= 1'b1;
		end else begin
			hb <= hb - 1'b1;
		end
		if (heartbeat_ev) hb_pending <= 1'b0;
	end
end

wire [3:0] ev_type =
	stop_exit    ? 4'h2 :
	stop_enter   ? 4'h1 :
	heartbeat_ev ? 4'h4 :
	window_ev    ? 4'h5 : 4'h0;

wire cap_en = CAPTURE_ENABLE & (window_ev | heartbeat_ev | stop_enter | (armed & stop_exit));

wire [7:0] byte8 = {ev_type, cpu_stopped, supervisor, cpustate};
wire [7:0] byte9 = {chip_ipl, int2_pending, skipFetch, 2'b00, is_l2_d};
wire [15:0] byte10 = {6'd0, win};

wire [127:0] entry = {
	32'd0,
	byte10,
	byte9,
	byte8,
	cpu_addr,
	tstamp
};

always @(posedge clk) begin
	if (reset) begin
		wr_ptr <= 9'b0;
	end
	else if (cap_en) begin
		ring[wr_ptr] <= entry;
		wr_ptr       <= wr_ptr + 1'b1;
	end
end

reg [3:0] byte_idx;

always @(*) begin
	if (empty) begin
		uio_dout = 8'h00;
	end else begin
		case (byte_idx)
			4'h0: uio_dout = ring[rd_ptr][  7:  0];
			4'h1: uio_dout = ring[rd_ptr][ 15:  8];
			4'h2: uio_dout = ring[rd_ptr][ 23: 16];
			4'h3: uio_dout = ring[rd_ptr][ 31: 24];
			4'h4: uio_dout = ring[rd_ptr][ 39: 32];
			4'h5: uio_dout = ring[rd_ptr][ 47: 40];
			4'h6: uio_dout = ring[rd_ptr][ 55: 48];
			4'h7: uio_dout = ring[rd_ptr][ 63: 56];
			4'h8: uio_dout = ring[rd_ptr][ 71: 64];
			4'h9: uio_dout = ring[rd_ptr][ 79: 72];
			4'hA: uio_dout = ring[rd_ptr][ 87: 80];
			4'hB: uio_dout = ring[rd_ptr][ 95: 88];
			4'hC: uio_dout = ring[rd_ptr][103: 96];
			4'hD: uio_dout = ring[rd_ptr][111:104];
			4'hE: uio_dout = ring[rd_ptr][119:112];
			4'hF: uio_dout = ring[rd_ptr][127:120];
		endcase
	end
end

always @(posedge clk) begin
	if (reset) begin
		byte_idx <= 0;
		rd_ptr   <= 0;
	end
	else if (uio_cs_trace && uio_rd) begin
		if (!empty) begin
			if (byte_idx == 4'hF) begin
				rd_ptr   <= rd_ptr + 1'b1;
				byte_idx <= 0;
			end else begin
				byte_idx <= byte_idx + 1'b1;
			end
		end
	end
	else if (!uio_cs_trace) begin
		byte_idx <= 0;
	end
end

endmodule
