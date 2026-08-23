//============================================================================
//  Raiden II - SEI252 sprite generator
//
//  Renders one scanline of sprites into a double-banked line buffer, the same
//  shape sei0200 uses for the tilemaps, so the two drop into the same raster.
//
//  Ground truth: MAME src/mame/seibu/sei25x_rise1x_spr.cpp (BSD-3-Clause) and
//  the Raiden II configuration in raiden2.cpp. The reference model is
//  tools/render_sprites.py -- that was written FIRST and this is diffed
//  against it per pixel, which is what made sei0200 exact.
//
//  Sprite entry, 8 bytes, 512 of them, latched from work RAM by a write to
//  0x68E (see RESEARCH.md 2.5a):
//
//    w0  [15] flipY  [14:12] height-1  [11] flipX  [10:8] width-1
//        [7:6] priority  [5:0] colour
//    w1  tile code
//    w2  [12] ext bank (UNUSED on Raiden II)  [8:0] X
//    w3  [8:0] Y
//
//  Details that are wrong-by-default if you do not read the reference:
//
//   * A tile code of ZERO means the slot is empty and is skipped entirely --
//     it does not mean "draw tile 0". That is how the list terminates, and why
//     COP DMA mode 0x118 zero-fills the tail of sprite RAM.
//   * Sub-tiles are emitted COLUMN-MAJOR: the code increments DOWN each column
//     (for ax { for ay { code++ } }), not across each row. Transposing this
//     renders every multi-tile sprite subtly scrambled.
//   * X and Y are 9-bit and wrap into negatives at 0x180.
//   * Raiden II registers no x/y offset and no gfxbank callback.
//   * Transparent pen is 15.
//   * Entry 0 wins overlaps. MAME gets that by drawing BACK TO FRONT (last
//     entry first) and letting later draws overwrite; this walks the list
//     FRONT TO BACK with first-writer-wins instead -- identical output on any
//     line that completes (first opaque pixel front-to-back IS the last one
//     back-to-front), but when a line runs over budget and is truncated (see
//     the plotter's restart note) the sprites lost are now the BACK-most,
//     not the front-most. The game orders its list front-first -- the player,
//     bullets, bonus items -- and real hardware's per-line limit also starves
//     the back of the list, so a truncated line keeps the sprites that
//     matter. Under the old order a heavy line silently dropped exactly the
//     front sprites, which on screen read as "enemy passes BEHIND the
//     scenery" (github issue #4's report is level 2 DX, the sprite-heaviest
//     scene measured).
//
//  Output encoding matches MAME's draw_raw, which is what the SEI360 mixer
//  consumes: {opaque, priority[1:0], colour[5:0], pen[3:0]}.
//
//  Graphics are 16x16x4 PACKED LSB -- 8 bytes per row, low nibble is the even
//  pixel. This is NOT the plane/x-order layout the tilemaps use; the two
//  graphics paths genuinely differ and conflating them yields noise.
//
//  UNIMPLEMENTED, deliberately: per-scanline sprite limits. Real hardware has
//  them, they are undocumented, and MAME ignores them too. A line here renders
//  every sprite that intersects it, so heavy scenes will differ from the PCB in
//  ways that show as sprites NOT dropping out.
//============================================================================

module sei252 #(
    parameter int SCREEN_W = 320
) (
    input  logic        clk,
    input  logic        reset,

    // Line fill request, same protocol as sei0200
    input  logic  [8:0] line,
    input  logic        start,
    output logic        busy,

    // SEI252's latched copy of sprite RAM (filled by the 0x68E write).
    // 512 entries x 4 words.
    output logic [10:0] spr_addr,
    input  logic [15:0] spr_data,

    // Sprite ROM. 32-bit words at a byte address, held until rom_valid so a
    // real SDRAM path can stall us without corrupting the line.
    output logic [22:0] rom_addr,
    output logic        rom_req,
    input  logic [63:0] rom_data,   // a whole 8-byte tile row per request
    input  logic        rom_valid,

    // Line buffer, double-banked exactly like sei0200's.
    // {opaque, pri[1:0], colour[5:0], pen[3:0]}
    output logic        fill_bank,
    input  logic        lb_rd_bank,
    input  logic  [8:0] lb_rd_x,
    output logic [12:0] lb_out
);

    localparam logic [3:0] TRANSPEN = 4'd15;

    //------------------------------------------------------------------
    // Line buffer: 2 banks x 512 pixels x 13 bits
    //------------------------------------------------------------------
    logic [12:0] lbuf [0:1023];
    logic  [9:0] lb_wa;
    logic [12:0] lb_wd;
    logic        lb_we;

    always_ff @(posedge clk) begin
        if (lb_we) lbuf[lb_wa] <= lb_wd;
        lb_out <= lbuf[{lb_rd_bank, lb_rd_x}];
    end

    //------------------------------------------------------------------
    // Sprite entry fields, as fetched
    //------------------------------------------------------------------
    logic [15:0] w0, w1, w2;
    wire         e_flipy  = w0[15];
    wire   [3:0] e_sizey  = {1'b0, w0[14:12]} + 4'd1;
    wire         e_flipx  = w0[11];
    wire   [3:0] e_sizex  = {1'b0, w0[10:8]} + 4'd1;
    wire   [1:0] e_pri    = w0[7:6];
    wire   [5:0] e_colour = w0[5:0];
    wire  [15:0] e_code   = w1;

    // 9-bit coordinates, sign-extended at 0x180 as MAME does.
    wire signed [10:0] e_x = (w2[8:0] >= 9'h180) ? {2'b11, w2[8:0]} : {2'b00, w2[8:0]};
    logic signed [10:0] e_y;

    // Row of this sprite that the requested line falls on.
    wire signed [10:0] dy      = $signed({2'b00, line}) - e_y;
    wire        [10:0] dy_u    = dy[10:0];
    wire               row_hit = !dy[10] && (dy_u < {3'd0, e_sizey, 4'd0});  // 0 <= dy < sizey*16

    // Which sub-tile row, and which pixel row inside it, honouring flipY.
    wire  [2:0] ay_raw = dy_u[6:4];
    wire  [3:0] ty_raw = dy_u[3:0];
    wire  [2:0] ay     = e_flipy ? (e_sizey[2:0] - 3'd1 - ay_raw) : ay_raw;
    wire  [3:0] ty     = e_flipy ? (4'd15 - ty_raw) : ty_raw;

    //------------------------------------------------------------------
    // Scanner-side copies of the row test and the address arithmetic
    //------------------------------------------------------------------
    // The candidate's row test. Same expression as row_hit, off the entry the
    // scanner is reading rather than the one being plotted.
    wire   [3:0] c_sizey  = {1'b0, c_w0[14:12]} + 4'd1;
    wire signed [10:0] c_dy = $signed({2'b00, line}) - c_ey;
    wire        [10:0] c_dy_u = c_dy[10:0];
    wire         c_row_hit = !c_dy[10] && (c_dy_u < {3'd0, c_sizey, 4'd0});

    // Address of COLUMN 0 of the queued sprite, for the cross-sprite prefetch.
    // ax is 0 there, so the ax*sizey term drops out entirely and this costs an
    // adder rather than a second multiplier.
    wire         p_flipy   = p_w0[15];
    wire   [3:0] p_sizey   = {1'b0, p_w0[14:12]} + 4'd1;
    wire signed [10:0] p_dy = $signed({2'b00, line}) - p_ey;
    wire        [10:0] p_dy_u = p_dy[10:0];
    wire   [2:0] p_ay_raw = p_dy_u[6:4];
    wire   [3:0] p_ty_raw = p_dy_u[3:0];
    wire   [2:0] p_ay     = p_flipy ? (p_sizey[2:0] - 3'd1 - p_ay_raw) : p_ay_raw;
    wire   [3:0] p_ty     = p_flipy ? (4'd15 - p_ty_raw) : p_ty_raw;
    wire  [15:0] p_sub_code = p_w1 + {13'd0, p_ay};
    wire  [22:0] p_row_addr = {p_sub_code, 7'd0} + {16'd0, p_ty, 3'd0};

    //------------------------------------------------------------------
    // Sequencer
    //------------------------------------------------------------------
    // Two cooperating sequencers.
    //
    // The single FSM this replaces spent, per row-hit sprite, ~10 clocks
    // reading the entry, then ~27 waiting for the tile row, then 16 plotting --
    // strictly in series, ~54 clocks. Measured on the real 130-sprite attract
    // list, 68.5% of sprites are 1x1 and the worst line was 109 columns from
    // 109 sprites, so a prefetch that looked ahead only WITHIN a sprite could
    // never help: the latency has to be hidden ACROSS sprites.
    //
    // The scanner owns the sprite-RAM port, which the plotter leaves idle for
    // the whole of S_FETCHW/S_PLOT, so the next sprite's entry read costs
    // nothing. The plotter owns the ROM port. A one-entry queue (p_*, p_valid)
    // joins them. Per sprite the cost becomes max(round trip, plot) ~= 28.
    typedef enum logic [3:0] {
        S_IDLE, S_CLR, S_WAITSPR, S_START0,
        S_FETCH, S_FETCHW, S_PLOT, S_NEXTCOL, S_PFWAIT, S_DRAIN
    } state_t;
    state_t st;

    // A line_start arriving mid-fill used to be IGNORED, so an over-budget
    // line cost the WHOLE of the next line: no fill happened at all and the
    // raster showed the previous line's pixels. Truncating the overrunning
    // line instead loses only the sprites not yet plotted, which is both far
    // less visible and closer to the PCB -- real hardware bounds per-line
    // sprite work and ours deliberately does not (see the header note). The
    // list is walked front to back, so what a truncated line loses is its
    // BACK-most sprites -- the same end of the list a real per-line limit
    // starves -- while the front sprites (player, bullets, bonus items) have
    // already landed.
    //
    // The abort cannot be immediate when a ROM request is in flight. The ch2
    // bridge is single-outstanding and latches at request time, so an
    // abandoned reply would be taken by the next line's S_FETCHW as if it
    // were its own -- silently drawing one sprite's pixels with another
    // sprite's row. S_DRAIN absorbs that one reply first. This is the same
    // hazard that made #77 so hard to see.
    wire rom_outstanding = pf_busy || (st == S_FETCHW);
    logic line_restart;              // one-cycle pulse: a new line was accepted

    typedef enum logic [3:0] {
        SC_IDLE, SC_E0, SC_E0W, SC_E1, SC_E1W, SC_E2, SC_E2W, SC_E3, SC_E3W,
        SC_COL0, SC_HOLD, SC_DONE
    } scan_t;
    scan_t sc;

    logic  [8:0] idx;        // sprite entry index, walked 0 -> 511 (front to back)
    logic  [2:0] ax;         // current sub-tile column
    logic  [2:0] fetch_ax;   // column the OUTSTANDING request is for (may be ax+1)

    // Candidate being read by the scanner, before the row test.
    logic [15:0] c_w0, c_w1;
    logic signed [10:0] c_ey;

    // The one-entry queue: a row-hit sprite the scanner has found and the
    // plotter has not taken yet. The scanner MUST hold these stable while
    // p_valid is set -- the cross-sprite prefetch addresses off them.
    logic [15:0] p_w0, p_w1, p_w2;
    logic signed [10:0] p_ey;
    logic        p_valid;
    logic        p_consume;  // one-cycle pulse: plotter took the queued sprite

    // Second buffered sprite. With a one-deep queue the scanner sat idle in
    // SC_HOLD while the plotter worked, then had to search from scratch after
    // every consume -- 594 clocks per line of the plotter waiting. Banking one
    // more entry during that idle time lets the scanner run ahead through the
    // sparse stretches of the list; its total work (~1,682 clocks) fits inside
    // the plotter's (~3,450) comfortably, it was only the burstiness that hurt.
    logic [15:0] q_w0, q_w1, q_w2;
    logic signed [10:0] q_ey;
    logic        q_valid;

    // Prefetch of the next tile row needed, issued under the current column's
    // 16-cycle plot. Only ONE request is ever outstanding, which is all the
    // ch2 bridge supports (sdr_spr_busy in Raiden2.sv is a single flag).
    // pf_for_next selects WHOSE row: the next column of the current sprite, or
    // column 0 of the sprite sitting in the queue.
    logic        pf_busy;    // prefetch issued, data not back yet
    logic        pf_have;    // prefetched row captured and waiting to be used
    logic        pf_for_next;
    logic [31:0] pf_lo, pf_hi;
    logic  [1:0] word_sel;   // which 32-bit half of the 8-byte tile row
    logic [31:0] row_lo, row_hi;
    logic signed [10:0] col_x;
    logic  [3:0] px_i;
    logic  [8:0] clr_x;

    // First-writer-wins occupancy, one bit per visible pixel of the line
    // being filled. The front-to-back walk means the first opaque write at an
    // x is the front-most sprite there, so later (further back) sprites must
    // not overwrite it -- this mask is what enforces that without a
    // read-modify-write on the line buffer BRAM. Cleared in one assignment
    // when a new line is accepted; the 320-cycle S_CLR that follows keeps any
    // plot hundreds of cycles away from that clear.
    logic [SCREEN_W-1:0] drawn;

    assign spr_addr = {idx[8:0], word_sel};
    assign busy     = (st != S_IDLE);

    // Sub-tile code. COLUMN-MAJOR: fetch_ax selects a column of sizey tiles.
    //
    // This indexes fetch_ax, NOT ax, because a prefetch asks for the NEXT
    // column's row while ax still names the column being plotted. fetch_ax is
    // loaded with ax for an ordinary fetch and with ax+1 for a prefetch, and
    // is registered alongside rom_req so the address is valid on exactly the
    // cycle the request goes high -- which is when the ch2 bridge latches it.
    wire [15:0] sub_code = e_code + {8'd0, fetch_ax} * {12'd0, e_sizey} + {13'd0, ay};

    // 128 bytes per 16x16 tile, 8 bytes per row.
    wire [22:0] tile_row_addr = {sub_code, 7'd0} + {16'd0, ty, 3'd0};

    // Pixel within the tile row, honouring flipX, and its 4-bit pen.
    wire  [3:0] pen_x = e_flipx ? (4'd15 - px_i) : px_i;
    wire [31:0] pen_w = pen_x[3] ? row_hi : row_lo;
    wire  [2:0] pen_b = pen_x[2:0];
    // packed LSB: byte n holds pixels 2n (low nibble) and 2n+1 (high nibble).
    // rom_data arrives as a little-endian 32-bit word covering 4 bytes.
    wire  [7:0] pen_byte = pen_w[{2'd0, pen_b[2:1]} * 8 +: 8];
    wire  [3:0] pen      = pen_b[0] ? pen_byte[7:4] : pen_byte[3:0];

    // Screen x of the pixel being plotted. Kept out of the always_ff: Quartus
    // 17.0 is unreliable with `automatic` variables inside procedural blocks.
    wire signed [10:0] plot_x = col_x + {7'd0, px_i};
    wire               plot_ok = !plot_x[10] && (plot_x < SCREEN_W);

    //------------------------------------------------------------------
    // Scanner: walk the list, hand the plotter one row-hit sprite at a time
    //------------------------------------------------------------------
    // Runs from the moment the line starts, so the 512-entry walk and the
    // 320-cycle S_CLR overlap instead of running back to back. Timing mirrors
    // the FSM this came from exactly: the sprite RAM has one cycle of latency,
    // so every address change is followed by one wait state, and an empty slot
    // still costs two clocks because the TILE CODE is read first.
    always_ff @(posedge clk) begin
        // ---- promote q into p ------------------------------------------
        // Placed before the case so SC_COL0's write to q wins in the cycle the
        // two coincide: p then takes the OLD q (correct, it is older) and q
        // takes the new hit.
        if (!reset && !line_restart) begin
            if (p_consume) begin
                if (q_valid) begin
                    p_w0 <= q_w0; p_w1 <= q_w1; p_w2 <= q_w2; p_ey <= q_ey;
                    q_valid <= 1'b0;
                end else begin
                    p_valid <= 1'b0;
                end
            end else if (!p_valid && q_valid) begin
                p_w0 <= q_w0; p_w1 <= q_w1; p_w2 <= q_w2; p_ey <= q_ey;
                p_valid <= 1'b1;
                q_valid <= 1'b0;
            end
        end

        if (reset) begin
            sc      <= SC_IDLE;
            p_valid <= 1'b0;
            q_valid <= 1'b0;
        end else if (line_restart) begin
            // Driven by the plotter when it actually begins a line, rather
            // than off `start` directly: a start that arrives mid-fill is now
            // deferred through S_DRAIN, and the scanner must restart with the
            // plotter, not one abort earlier.
            //
            // Handled HERE, ahead of the case, so it is accepted from any
            // scanner state -- including SC_DONE.
            //
            // Gating it on SC_IDLE instead deadlocks the module: the plotter
            // reaches S_IDLE one cycle BEFORE the scanner leaves SC_DONE (the
            // scanner's exit tests st == S_IDLE, so it lands a cycle later), and
            // a start arriving in that window is taken by the plotter and
            // missed by the scanner. The plotter then waits in S_WAITSPR for a
            // sprite that will never be queued, busy stays high, and every
            // subsequent line_start is dropped -- the whole sprite layer dies.
            // Neither bench can catch it: both idle for hundreds of cycles
            // before restarting, while hardware fires line_start every 4096
            // clocks whatever the engine is doing.
            idx      <= 9'd0;        // front to back -- see the header note
            word_sel <= 2'd1;        // tile code first
            p_valid  <= 1'b0;
            q_valid  <= 1'b0;
            sc       <= SC_E0W;
        end else begin
            case (sc)
                SC_IDLE: ;   // waiting for the next line start, handled above

                SC_E0:  begin word_sel <= 2'd1; sc <= SC_E0W; end

                // Priming cycle. The address {idx,1} is presented now and its
                // data lands next cycle, so idx starts running one step AHEAD
                // of the entry being examined. From here on:
                //
                //     spr_data in SC_E1  ==  word1 of entry (idx - 1)
                //
                // That one-ahead skew is what makes an empty slot cost ONE
                // clock instead of two: previously the loop went back through
                // SC_E0W every slot purely to absorb the sprite RAM's 1-cycle
                // latency. Get the -1 wrong and the scanner reads one entry's
                // tile code with another entry's attributes.
                SC_E0W: begin
                    idx <= idx + 9'd1;
                    sc  <= SC_E1;
                end

                SC_E1: begin
                    if (spr_data != 16'd0) begin
                        // Non-empty: the code belongs to idx-1, so wind idx
                        // back onto that entry before reading its other words.
                        idx      <= idx - 9'd1;
                        c_w1     <= spr_data;
                        word_sel <= 2'd0;
                        sc       <= SC_E1W;
                    end else if (idx == 9'd0) begin
                        // idx wrapped past 511, so the entry just examined WAS
                        // entry 511 -- the list is finished.
                        sc <= SC_DONE;
                    end else begin
                        // Empty slot: keep the pipeline running, one per clock.
                        idx <= idx + 9'd1;
                    end
                end
                SC_E1W: sc <= SC_E2;
                SC_E2:  begin c_w0 <= spr_data; word_sel <= 2'd3; sc <= SC_E2W; end
                SC_E2W: sc <= SC_E3;
                SC_E3: begin
                    c_ey <= (spr_data[8:0] >= 9'h180) ? {2'b11, spr_data[8:0]}
                                                      : {2'b00, spr_data[8:0]};
                    word_sel <= 2'd2;
                    sc       <= SC_E3W;
                end
                // The row test needs only sizey (from c_w0) and y (from c_ey),
                // both of which are already latched here -- so decide BEFORE
                // paying two clocks to read the x word. Most live sprites are
                // not on any given line (130 live, ~24 on the worst line), so
                // this skips the read for the ~106 that miss.
                SC_E3W: begin
                    if (c_row_hit) begin
                        sc <= SC_COL0;
                    end else if (idx == 9'd511) begin
                        sc <= SC_DONE;
                    end else begin
                        idx      <= idx + 9'd1;
                        word_sel <= 2'd1;
                        sc       <= SC_E0W;
                    end
                end

                // Row already known to hit, so queue straight from spr_data
                // rather than latching x and spending another state on it.
                // Every hit lands in q first; the promote block above moves it
                // into p as soon as p is free. Writing one slot uniformly
                // avoids racing the promote in the cycle they coincide.
                SC_COL0: begin
                    q_w0    <= c_w0;
                    q_w1    <= c_w1;
                    q_w2    <= spr_data;
                    q_ey    <= c_ey;
                    q_valid <= 1'b1;
                    sc      <= SC_HOLD;
                end

                // Wait only until q has been promoted, NOT until the plotter
                // consumes -- that is the whole point of the second slot. The
                // scanner keeps hunting while the plotter is still drawing.
                SC_HOLD: begin
                    if (!q_valid) begin
                        if (idx == 9'd511) sc <= SC_DONE;
                        else begin
                            idx      <= idx + 9'd1;
                            word_sel <= 2'd1;
                            sc       <= SC_E0W;
                        end
                    end
                end

                SC_DONE: begin
                    if (st == S_IDLE) sc <= SC_IDLE;
                end

                default: sc <= SC_IDLE;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        lb_we     <= 1'b0;
        rom_req   <= 1'b0;
        p_consume <= 1'b0;

        // ---- prefetch service, runs underneath whatever the FSM is doing ----
        //
        // Placed BEFORE the case so an ordinary S_FETCH/S_FETCHW assignment
        // still wins; the two never contend anyway, because S_NEXTCOL routes a
        // column with a prefetch outstanding to S_PFWAIT rather than S_FETCH,
        // so pf_busy is always 0 while the FSM sits in S_FETCHW.
        //
        // The hold/drop pattern is deliberately identical to the fixed
        // S_FETCHW: assert while waiting, and DO NOT re-assert on the cycle
        // rom_valid is consumed. Re-asserting is what created the phantom
        // fetch of #77, and a prefetch that did it would reintroduce exactly
        // the same skew one column further ahead.
        if (pf_busy) begin
            if (rom_valid) begin
                pf_lo   <= rom_data[31:0];
                pf_hi   <= rom_data[63:32];
                pf_busy <= 1'b0;
                pf_have <= 1'b1;
            end else begin
                rom_req <= 1'b1;
            end
        end

        line_restart <= 1'b0;
        // The pulse was set on the transition into S_CLR; plotting is at
        // least the 320-cycle clear away, so clearing here cannot race a set.
        if (line_restart) drawn <= '0;

        if (reset) begin
            st          <= S_IDLE;
            fill_bank   <= 1'b0;
            fetch_ax    <= 3'd0;
            pf_busy     <= 1'b0;
            pf_have     <= 1'b0;
            pf_for_next <= 1'b0;
            drawn       <= '0;
        end else if (start && st != S_IDLE && rom_outstanding) begin
            // Overrun with a fetch in flight: absorb the reply, then restart.
            st <= S_DRAIN;
        end else if (start && st != S_IDLE) begin
            // Overrun with the bus quiet: truncate and restart immediately.
            fill_bank    <= ~fill_bank;
            clr_x        <= 9'd0;
            pf_have      <= 1'b0;
            pf_for_next  <= 1'b0;
            line_restart <= 1'b1;
            st           <= S_CLR;
        end else begin
            case (st)
                S_IDLE: begin
                    if (start) begin
                        fill_bank    <= ~fill_bank;
                        clr_x        <= 9'd0;
                        line_restart <= 1'b1;
                        st           <= S_CLR;
                    end
                end

                // Wait out the one reply that is already in flight, discard
                // it, then begin the new line. pf_busy is cleared by the
                // service block above on the same rom_valid.
                S_DRAIN: begin
                    if (rom_valid) begin
                        fill_bank    <= ~fill_bank;
                        clr_x        <= 9'd0;
                        pf_have      <= 1'b0;
                        pf_for_next  <= 1'b0;
                        line_restart <= 1'b1;
                        st           <= S_CLR;
                    end
                end

                // Blank the bank before filling it. Without this, a pixel left
                // by the line drawn two scanlines ago (same bank) survives
                // wherever this line is transparent -- which showed up as
                // sprite edges smearing to the right as the shape receded.
                S_CLR: begin
                    // fill_bank has ALREADY flipped -- it was assigned on the
                    // transition into this state, so the new value is live
                    // here. Clearing ~fill_bank wiped the bank the raster was
                    // displaying, blanking sprites on hardware while leaving
                    // the offline sim (which reads back the bank it just
                    // filled) looking perfect.
                    lb_wa <= {fill_bank, clr_x};
                    lb_wd <= 13'd0;                 // bit 12 clear = transparent
                    lb_we <= 1'b1;
                    if (clr_x == SCREEN_W[8:0] - 9'd1) begin
                        st <= S_WAITSPR;
                    end else begin
                        clr_x <= clr_x + 9'd1;
                    end
                end

                // ---- take the next row-hit sprite from the scanner ----
                // By the time the clear finishes the scanner has usually
                // already queued one, so this is normally a single cycle.
                S_WAITSPR: begin
                    if (p_valid) begin
                        w0        <= p_w0;
                        w1        <= p_w1;
                        w2        <= p_w2;
                        e_y       <= p_ey;
                        ax        <= 3'd0;
                        p_consume <= 1'b1;
                        st        <= S_START0;
                    end else if (sc == SC_DONE && !q_valid) begin
                        st <= S_IDLE;
                    end
                end

                // One cycle for the commit above to land, since col_x and the
                // address arithmetic read w0/w2/e_y as registers.
                //
                // Any prefetch outstanding here is necessarily the cross-sprite
                // one for THIS sprite's column 0: a next-column prefetch is
                // consumed by S_NEXTCOL and never reaches S_WAITSPR.
                S_START0: begin
                    st <= (pf_busy || pf_have) ? S_PFWAIT : S_FETCH;
                end

                // ---- fetch the whole 8-byte tile row in ONE request ----
                // ch2 returns 64 bits, and the four 16-bit words come from a
                // single SDRAM burst, so the extra three are nearly free while
                // a second request would pay full latency again. Two requests
                // per row put the worst line over the 4096-clock budget as
                // soon as fetch latency passed about 4 cycles.
                S_FETCH: begin
                    rom_req     <= 1'b1;
                    fetch_ax    <= ax;   // ordinary fetch: this column
                    pf_for_next <= 1'b0; // ... of the CURRENT sprite
                    st          <= S_FETCHW;
                end
                // rom_req must DROP on the cycle rom_valid is consumed. It is
                // a registered level: re-asserting it here left it high for
                // the first S_PLOT cycle, and the ch2 bridge (newly un-busy on
                // the same ack) read that trailing cycle as a NEW request --
                // a phantom fetch of the just-consumed address. The phantom
                // then swallowed the next real S_FETCH (bridge busy, address
                // ignored), and its stale data was consumed as the next
                // column's row: every back-to-back fetch ran one fetch behind
                // until an idle gap resynced it. That skew is invisible to any
                // bench that samples the address at serve time -- only a
                // request-time-latched model (tb_sei252_paced, or the board)
                // shows it. Symptom: sprite corruption in heavy scenes (#77).
                S_FETCHW: begin
                    if (!rom_valid) rom_req <= 1'b1;
                    if (rom_valid) begin
                        row_lo   <= rom_data[31:0];
                        row_hi   <= rom_data[63:32];
                        px_i     <= 4'd0;
                        col_x    <= e_flipx
                                  ? (e_x + {{4{1'b0}}, (e_sizex - 4'd1 - {1'b0, ax})} * 11'sd16)
                                  : (e_x + {{4{1'b0}}, {1'b0, ax}} * 11'sd16);
                        st       <= S_PLOT;
                    end
                end

                // ---- one pixel per clock into the line buffer ----
                S_PLOT: begin
                    // drawn[] is only meaningful under plot_ok, which also
                    // bounds the index into it.
                    if (pen != TRANSPEN && plot_ok && !drawn[plot_x[8:0]]) begin
                        lb_wa <= {fill_bank, plot_x[8:0]};
                        lb_wd <= {1'b1, e_pri, e_colour, pen};
                        lb_we <= 1'b1;
                        drawn[plot_x[8:0]] <= 1'b1;
                    end

                    // Ask for the next row needed, on the first plot cycle.
                    // The bridge is free here by construction: S_FETCHW just
                    // consumed rom_valid, which is the same edge the bridge
                    // clears sdr_spr_busy on.
                    //
                    // "Next row" is the next column of this sprite if it has
                    // one, otherwise column 0 of whatever the scanner has
                    // queued. The second case is the whole point of the split:
                    // it is what hides the round trip on a list of 1x1 sprites,
                    // where there is no next column to hide it behind.
                    //
                    // If the queue is empty the scanner has not found the next
                    // row-hit sprite yet, so no request is issued and S_WAITSPR
                    // falls back to a plain S_FETCH. A request is therefore
                    // never left in flight with nothing to consume it -- which
                    // matters, because the bridge is single-outstanding and an
                    // orphaned reply would be taken by the next S_FETCHW as if
                    // it were its own, exactly the class of skew #77 was.
                    if (px_i == 4'd0 && !pf_busy && !pf_have) begin
                        if ({1'b0, ax} != e_sizex - 4'd1) begin
                            fetch_ax    <= ax + 3'd1;
                            pf_for_next <= 1'b0;
                            rom_req     <= 1'b1;
                            pf_busy     <= 1'b1;
                        end else if (p_valid) begin
                            pf_for_next <= 1'b1;
                            rom_req     <= 1'b1;
                            pf_busy     <= 1'b1;
                        end
                    end

                    if (px_i == 4'd15) st <= S_NEXTCOL;
                    else               px_i <= px_i + 4'd1;
                end

                S_NEXTCOL: begin
                    if ({1'b0, ax} == e_sizex - 4'd1) begin
                        // Done with this sprite. Any prefetch outstanding is
                        // the cross-sprite one, and S_START0 consumes it.
                        st <= S_WAITSPR;
                    end else begin
                        ax <= ax + 3'd1;
                        // The row for this column was requested under the plot
                        // we just finished, so consume it rather than issuing
                        // a second request for the same address.
                        st <= (pf_busy || pf_have) ? S_PFWAIT : S_FETCH;
                    end
                end

                // Prefetched row: already in flight or already here. Same
                // hand-off S_FETCHW performs, but the wait is only whatever is
                // left of the round trip after 16 plot cycles instead of all
                // of it.
                S_PFWAIT: begin
                    if (pf_have) begin
                        row_lo  <= pf_lo;
                        row_hi  <= pf_hi;
                        pf_have <= 1'b0;
                        px_i    <= 4'd0;
                        col_x   <= e_flipx
                                 ? (e_x + {{4{1'b0}}, (e_sizex - 4'd1 - {1'b0, ax})} * 11'sd16)
                                 : (e_x + {{4{1'b0}}, {1'b0, ax}} * 11'sd16);
                        st      <= S_PLOT;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // 8-byte aligned: one request covers the entire tile row.
    //
    // Muxed at REQUEST time, which is the only time it matters: the ch2 bridge
    // latches the address on the cycle it accepts the request (sdr_spr_addr_r
    // in Raiden2.sv), so p_* moving on afterwards cannot corrupt an in-flight
    // cross-sprite fetch.
    assign rom_addr = pf_for_next ? p_row_addr : tile_row_addr;

endmodule
