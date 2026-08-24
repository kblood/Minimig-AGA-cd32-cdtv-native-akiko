// Chipset bus trace — 1024-deep ring buffer of Agnus register writes.
//
// Compile-time gated by CHIPSET_TRACE param in agnus.v. When the gate is 0,
// the instantiation lives inside a `generate if` block that Quartus
// dead-code-eliminates, producing a bit-identical RBF to the no-trace build.
//
// One entry = 64 bits, drained as 8 bytes LSB-first over a dedicated UIO
// sub-channel. Layout (bit numbering MSB-first as packed into the entry):
//
//   [63:48] data[15:0]
//   [47:40] reg_addr[7:0]   (i.e., reg_address_out[8:1])
//   [39:37] src[2:0]        (000=CPU, 001=cop, 010=blt, 011=spr,
//                             100=bpl, 101=dsk, 110=aud, 111=refresh)
//   [36:26] vpos[10:0]
//   [25:17] hpos[8:0]
//   [16]    dbwe (true write to chip RAM, only valid for CPU/blt sources)
//   [15:0]  reserved (0)
//
// Drain protocol (matches akiko_bus_trace pattern):
//   byte 0: data[7:0]
//   byte 1: data[15:8]
//   byte 2: reg_addr (8 bits, includes [7:0] of reg_address)
//   byte 3: {dbwe, src[2:0], vpos[10:8]} - high context byte
//   byte 4: vpos[7:0]
//   byte 5: hpos[7:0]
//   byte 6: {7'b0, hpos[8]}
//   byte 7: 0xFF normal entry
//           0xFE GAP entry -- data[15:0] is the number of events dropped
//                because the ring was full; vpos/hpos are the beam position
//                at which the ring recovered. src/reg_addr/dbwe are 0.
//           0x00 ring empty -> userspace stops
//
// OVERFLOW POLICY -- read this before analysing any capture.
//
// This ring originally advanced wr_ptr with NO full check, so it silently
// overwrote. Three separate defects fell out of that, and all three were
// invisible in the drained CSV:
//   (1) silent loss -- a drain returned (pending mod 1024) entries, so an
//       exact multiple returned ZERO rows and looked like an idle bus;
//   (2) reordering -- once wr_ptr lapped rd_ptr the returned run mixed laps;
//   (3) tearing -- the writer could overwrite ring[rd_ptr] while the drain
//       was fetching it one byte at a time, yielding a record whose fields
//       came from two different events.
// Consequence: "first point of divergence" analysis over such a capture is
// meaningless, because consecutive rows are not consecutive in time and
// nothing in the file says so.
//
// It is now DROP-ON-FULL with explicit accounting. wr_ptr never advances
// into rd_ptr, which removes (2) and (3) outright -- the writer can no
// longer touch a slot the drain has not yet released. Events arriving while
// full increment drop_cnt instead of overwriting. The first entry written
// after space frees up is a GAP entry carrying drop_cnt, so (1) becomes an
// explicit, countable record in the stream rather than a silent hole. Note
// the event that triggers the recovery is itself counted as dropped (it is
// spent emitting the marker), so drop_cnt is exact, not an estimate.
//
// Usable depth is therefore 1023, not 1024.
//
// Capture trigger (`write_strobe`): the user wires this from a filtered
// combinational block (see chipset-trace-plan.md). The module itself does
// no filtering; it just commits to the ring when write_strobe is high.

module chipset_bus_trace
(
	input             clk,
	input             reset,

	// Snoop inputs
	input             write_strobe,   // 1-cycle pulse: commit one entry
	input       [7:0] reg_addr,       // chipset register address (word index)
	input      [15:0] data,           // value being written
	input       [2:0] src,            // bus source id (see header)
	input      [10:0] vpos,           // vertical beam position
	input       [8:0] hpos,           // horizontal beam position
	input             dbwe,           // chip-RAM write enable (Agnus.dbwe)

	// UIO drain port — pulses uio_rd to advance one byte per access.
	input             uio_cs_trace,
	input             uio_rd,
	output reg  [7:0] uio_dout
);

// 1024-entry ring, 10-bit pointers. Usable depth 1023 -- one slot is spent
// distinguishing full from empty, which is what makes drop-on-full possible.
reg [63:0] ring [0:1023];
reg  [9:0] wr_ptr;
reg  [9:0] rd_ptr;
wire       empty = (wr_ptr == rd_ptr);
wire       full  = ((wr_ptr + 10'd1) == rd_ptr);

// Saturating count of events dropped since the last GAP entry was emitted.
reg [15:0] drop_cnt;

// Per-entry sentinel byte, stored alongside the entry so the drain does not
// have to re-derive it: 8'hFF normal, 8'hFE gap.
reg [7:0] tag [0:1023];

// Capture: commit one entry per pulse of write_strobe, unless the ring is
// full, in which case count the loss instead of overwriting unread data.
always @(posedge clk) begin
	if (write_strobe) begin
		if (full) begin
			// Saturate rather than wrap -- a wrapped count would understate
			// the loss and read as a small gap.
			if (drop_cnt != 16'hFFFF) drop_cnt <= drop_cnt + 16'd1;
		end
		else if (drop_cnt != 16'd0) begin
			// Space has freed up but we still owe a gap record. Spend this
			// slot on the marker; this event is dropped too, hence the +1.
			ring[wr_ptr] <= {(drop_cnt == 16'hFFFF) ? drop_cnt
			                                        : (drop_cnt + 16'd1),
			                 8'h00,                 // reg_addr
			                 3'b000,                // src
			                 vpos,                  // beam pos at recovery
			                 hpos,
			                 1'b0,                  // dbwe
			                 16'h0000};
			tag[wr_ptr] <= 8'hFE;
			wr_ptr   <= wr_ptr + 1'b1;
			drop_cnt <= 16'd0;
		end
		else begin
			ring[wr_ptr] <= {data,                  // [63:48]
			                 reg_addr,              // [47:40]
			                 src,                   // [39:37]
			                 vpos,                  // [36:26]
			                 hpos,                  // [25:17]
			                 dbwe,                  // [16]
			                 16'h0000};             // [15:0] reserved
			tag[wr_ptr] <= 8'hFF;
			wr_ptr <= wr_ptr + 1'b1;
		end
	end

	if (reset) begin
		wr_ptr   <= 0;
		drop_cnt <= 0;
	end
end

// Drain: byte_idx walks 0..7 across the entry; rd_ptr advances after byte 7.
reg [2:0] byte_idx;

always @(*) begin
	if (empty) begin
		uio_dout = 8'h00;
	end else begin
		case (byte_idx)
			3'd0: uio_dout = ring[rd_ptr][55:48];                    // data lo
			3'd1: uio_dout = ring[rd_ptr][63:56];                    // data hi
			3'd2: uio_dout = ring[rd_ptr][47:40];                    // reg_addr
			3'd3: uio_dout = {ring[rd_ptr][16],                      // dbwe
			                  ring[rd_ptr][39:37],                   // src[2:0]
			                  1'b0,                                  // pad
			                  ring[rd_ptr][36:34]};                  // vpos[10:8]
			3'd4: uio_dout = ring[rd_ptr][33:26];                    // vpos[7:0]
			3'd5: uio_dout = ring[rd_ptr][24:17];                    // hpos[7:0]
			3'd6: uio_dout = {7'b0, ring[rd_ptr][25]};               // hpos[8]
			3'd7: uio_dout = tag[rd_ptr];                            // 0xFF normal, 0xFE gap
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
			if (byte_idx == 3'd7) begin
				rd_ptr   <= rd_ptr + 1'b1;
				byte_idx <= 0;
			end else begin
				byte_idx <= byte_idx + 1'b1;
			end
		end
	end
	else if (!uio_cs_trace) begin
		// Reset byte index outside a transaction so a partial read doesn't
		// leave us mid-entry.
		byte_idx <= 0;
	end
end

endmodule
