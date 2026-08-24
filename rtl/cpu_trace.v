// SPDX-License-Identifier: GPL-3.0-or-later

module cpu_trace #(
	parameter CAPTURE_ENABLE = 1'b1
)(
	input             clk,
	input             reset,

	input             cpu_clkena,
	input             cpu_stopped,
	input             cap_ev,
	input      [31:0] cpu_addr,
	input      [15:0] cpu_data,
	input       [1:0] cpustate,
	input             supervisor,
	input       [2:0] chip_ipl,
	input             tg68k_sel,

	input             uio_cs_trace,
	input             uio_rd,
	output reg  [7:0] uio_dout
);

reg [127:0] ring [0:511];
reg   [8:0] wr_ptr;
reg   [8:0] rd_ptr;
reg   [9:0] avail;
reg   [3:0] byte_idx;
wire        empty = (avail == 10'd0);

reg  [31:0] tstamp;
always @(posedge clk) tstamp <= reset ? 32'b0 : tstamp + 1'b1;

reg cpu_stopped_d;
always @(posedge clk)
	if (reset)           cpu_stopped_d <= 1'b0;
	else if (cpu_clkena) cpu_stopped_d <= cpu_stopped;
wire stop_enter = cpu_clkena &  cpu_stopped & ~cpu_stopped_d;

reg is_l2_d;
wire is_l2 = (chip_ipl == 3'b101);
always @(posedge clk)
	if (reset)           is_l2_d <= 1'b0;
	else if (cpu_clkena) is_l2_d <= is_l2;

reg [23:0] stop_len;
always @(posedge clk) begin
	if (reset) begin
		stop_len <= 24'd0;
	end else if (cpu_clkena) begin
		if (cpu_stopped) begin
			if (stop_len != 24'hFFFFFF) stop_len <= stop_len + 1'b1;
		end else begin
			stop_len <= 24'd0;
		end
	end
end

reg cs_d;
always @(posedge clk) cs_d <= uio_cs_trace;
wire cs_rise = uio_cs_trace & ~cs_d;

wire cap_en = CAPTURE_ENABLE & ~uio_cs_trace & (cap_ev | stop_enter);

wire [3:0] ev_type = stop_enter ? 4'h1 : 4'h5;

wire [7:0] byte8 = {ev_type, cpu_stopped, supervisor, cpustate};
wire [7:0] byte9 = {chip_ipl, tg68k_sel, 3'b000, is_l2_d};
wire [15:0] byte10 = stop_len[23:8];

wire [127:0] entry = {
	16'd0,
	cpu_data,
	byte10,
	byte9,
	byte8,
	cpu_addr,
	tstamp
};

always @(posedge clk) begin
	if (reset) begin
		wr_ptr <= 9'b0;
		rd_ptr <= 9'b0;
		avail  <= 10'd0;
	end else begin
		if (cap_en) begin
			ring[wr_ptr] <= entry;
			wr_ptr       <= wr_ptr + 1'b1;
		end
		if (cs_rise) begin
			rd_ptr <= wr_ptr;
			avail  <= 10'd512;
		end
		else if (uio_cs_trace && uio_rd && !empty && (byte_idx == 4'hF)) begin
			rd_ptr <= rd_ptr + 1'b1;
			avail  <= avail - 1'b1;
		end
	end
end

reg [127:0] rd_data;
always @(posedge clk) rd_data <= ring[rd_ptr];

always @(*) begin
	if (empty) begin
		uio_dout = 8'h00;
	end else begin
		case (byte_idx)
			4'h0: uio_dout = rd_data[  7:  0];
			4'h1: uio_dout = rd_data[ 15:  8];
			4'h2: uio_dout = rd_data[ 23: 16];
			4'h3: uio_dout = rd_data[ 31: 24];
			4'h4: uio_dout = rd_data[ 39: 32];
			4'h5: uio_dout = rd_data[ 47: 40];
			4'h6: uio_dout = rd_data[ 55: 48];
			4'h7: uio_dout = rd_data[ 63: 56];
			4'h8: uio_dout = rd_data[ 71: 64];
			4'h9: uio_dout = rd_data[ 79: 72];
			4'hA: uio_dout = rd_data[ 87: 80];
			4'hB: uio_dout = rd_data[ 95: 88];
			4'hC: uio_dout = rd_data[103: 96];
			4'hD: uio_dout = rd_data[111:104];
			4'hE: uio_dout = rd_data[119:112];
			4'hF: uio_dout = rd_data[127:120];
		endcase
	end
end

always @(posedge clk) begin
	if (reset) begin
		byte_idx <= 0;
	end
	else if (uio_cs_trace && uio_rd) begin
		if (!empty) byte_idx <= byte_idx + 1'b1;
	end
	else if (!uio_cs_trace) begin
		byte_idx <= 0;
	end
end

endmodule
