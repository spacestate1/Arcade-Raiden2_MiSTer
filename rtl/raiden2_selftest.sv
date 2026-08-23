//============================================================================
//  Raiden II - core self-test page renderer
//
//  Draws a 40x30 character pass/fail page over the core's 320x240 raster, so a
//  bring-up run on real hardware reports what worked instead of showing a black
//  screen. This exists because the SDRAM controller, the ROM loader and both
//  fetch handshakes in Raiden2.sv have NO simulation coverage at all -- the
//  sim harness tops out at raiden2_main and serves ROM combinationally.
//  Those are exactly the blocks most likely to fail silently on hardware.
//
//  The page is deliberately independent of the game's video path: it reads only
//  the font and page ROMs, so it still renders correctly when the tilemap
//  engine, the COP or SDRAM are completely dead.
//
//  Raiden2.sv forces no_rotate while this page is showing. The cabinet monitor
//  is vertical, so without that the text would come out running up the side of
//  the screen after screen_rotate.
//
//  Layout constants below are printed by tools/make_selftest_page.py and MUST
//  match the generated raiden2_selftest_page.sv. Re-run that script and copy
//  them across if the page changes.
//============================================================================

module raiden2_selftest #(
    parameter int H_TOTAL = 512      // must match raiden2_video_timing
) (
    input  logic        clk,
    input  logic        ce_pix,

    input  logic  [9:0] hcnt,
    input  logic  [8:0] vcnt,
    input  logic  [8:0] next_line,   // vcnt+1, wrapped -- from the timing block

    // Two bits per check: 0 WAIT, 1 BUSY, 2 PASS, 3 FAIL. Check i is at
    // chk_state[2*i+1 : 2*i], in the same order as the page's label list.
    input  logic [43:0] chk_state,

    // Row offset for scrolling the page, 0 = top.
    input  logic  [5:0] scroll,

    // Shown on the detail line only when the SDRAM check has failed.
    input  logic        bad_valid,
    input  logic  [2:0] bad_ch,      // SDRAM channel number (1..4) that failed
    input  logic [23:0] bad_addr,

    // Overrides the title row's "II" with "DX" when Raiden DX is loaded --
    // the page ROM itself is generated and stays untouched.
    input  logic        game_dx,

    // The first COP DMA mode the engine rejected. Naming it turns "COP MODES
    // KNOWN failed" from a dead end into a work item.
    input  logic        mode_valid,
    input  logic [11:0] bad_mode,

    // Build date/time, ddhhmmss. Displayed so a stale bitstream is obvious --
    // MiSTer's own build id is date-only and cannot tell two builds on the
    // same day apart, which cost a round trip to discover.
    input  logic [31:0] build_stamp,

    // Main CPU fetch address, latched at vblank so it is readable rather than
    // a blur. A frozen game and a running one look the same on a pass/fail
    // list; this says whether the CPU is spinning and where.
    input  logic [19:0] cpu_addr,

    output logic [23:0] rgb
);

    // Page layout comes from the generator that builds the page ROM, so the
    // two cannot drift. Hand-copied constants here previously went stale when
    // a check was added.
    `include "raiden2_selftest_layout.vh"

    localparam logic [1:0] ST_WAIT = 2'd0;
    localparam logic [1:0] ST_BUSY = 2'd1;
    localparam logic [1:0] ST_PASS = 2'd2;
    localparam logic [1:0] ST_FAIL = 2'd3;

    // Character codes are ascii-0x20.
    localparam logic [5:0] C_SPACE = 6'd0;
    localparam logic [5:0] C_DOT   = 6'd14;   // '.'
    localparam logic [5:0] C_ZERO  = 6'd16;   // '0'
    localparam logic [5:0] C_A     = 6'd33;   // 'A'

    //------------------------------------------------------------------
    // Fetch position.
    //
    // The character cell is fetched one cell AHEAD of the pixel being drawn,
    // which gives the two registered ROM reads a full character time (64 clocks
    // at ce_pix = clk/8) to settle. At the last pixel of a line the lookahead
    // wraps to column 0 of the next line, so it has to follow next_line rather
    // than vcnt -- otherwise the leftmost cell of every line would be drawn
    // with the previous line's font row.
    //------------------------------------------------------------------
    wire        last_h = (hcnt == H_TOTAL[9:0] - 10'd1);
    wire  [8:0] fv     = last_h ? next_line : vcnt;
    wire  [6:0] fcol   = last_h ? 7'd0 : (hcnt[9:3] + 7'd1);
    // Scrolled by `scroll` rows. The page is 30 rows and the check list has
    // grown to fill nearly all of it, so on a display with any overscan the
    // last lines can sit off the bottom. Up/down on the joystick shifts the
    // whole page; the top-level clamps the range.
    wire  [5:0] frow   = fv[8:3] + scroll;
    wire  [2:0] fsub   = fv[2:0];

    //------------------------------------------------------------------
    // Static page text
    //------------------------------------------------------------------
    logic [5:0] page_ch;

    raiden2_selftest_page page (
        .clk (clk),
        // The page ROM is 64x32 and blank outside the 40x30 page, so both
        // indices are clamped into it rather than allowed to alias: fcol
        // reaches 64 in the last few pixels of a line, and frow reaches 35
        // during vertical blanking.
        .col (fcol[6]        ? 6'd63 : fcol[5:0]),
        .row (frow > 6'd31   ? 5'd31 : frow[4:0]),
        .ch  (page_ch)
    );

    //------------------------------------------------------------------
    // Which dynamic field, if any, this cell belongs to. Computed from the
    // fetch position and registered so it lines up with page_ch.
    //------------------------------------------------------------------
    // chk_index must be wide enough for EVERY check, not just the first 16.
    // It was truncated to 4 bits, so once the list passed 16 entries the last
    // rows aliased back onto rows 0..n and displayed those verdicts instead of
    // their own -- the sound checks read PASS while showing PLL LOCK and ROM
    // LOAD's results. Sized from N_CHECKS so it cannot silently break again.
    localparam int IDX_W = (N_CHECKS <= 16) ? 4 : (N_CHECKS <= 32) ? 5 : 6;
    wire            is_chk_row  = (frow >= CHK_ROW0) && (frow < CHK_ROW0 + 6'(N_CHECKS));
    wire      [5:0] chk_index6  = frow - CHK_ROW0;
    wire [IDX_W-1:0] chk_index  = is_chk_row ? chk_index6[IDX_W-1:0] : '0;
    wire        is_result   = is_chk_row && (fcol >= RESULT_COL) && (fcol < RESULT_COL + 7'd4);
    wire  [1:0] result_pos  = fcol[1:0] - RESULT_COL[1:0];

    wire        is_count   = (frow == SUMMARY_ROW) && (fcol >= COUNT_COL) && (fcol < COUNT_COL + 7'd2);
    wire        count_lo   = (fcol == COUNT_COL + 7'd1);

    wire        is_mode_row = (frow == MODE_ROW);
    wire        is_mode_hex = is_mode_row && (fcol >= MODE_HEX_COL) && (fcol < MODE_HEX_COL + 7'd3);
    wire  [2:0] mode_pos    = fcol[2:0] - MODE_HEX_COL[2:0];
    wire  [2:0] mode_idx    = (mode_pos > 3'd2) ? 3'd0 : (3'd2 - mode_pos);
    wire  [3:0] mode_nib    = bad_mode[mode_idx * 4 +: 4];

    wire        is_build_row = (frow == BUILD_ROW);
    wire        is_build_hex = is_build_row && (fcol >= BUILD_HEX_COL) && (fcol < BUILD_HEX_COL + 7'd8);
    wire        is_pc_hex    = is_build_row && (fcol >= PC_COL) && (fcol < PC_COL + 7'd5);
    wire  [2:0] pc_pos       = fcol[2:0] - PC_COL[2:0];
    wire  [2:0] pc_idx       = (pc_pos > 3'd4) ? 3'd0 : (3'd4 - pc_pos);
    wire  [3:0] pc_nib       = cpu_addr[pc_idx * 4 +: 4];
    wire  [2:0] build_pos    = fcol[2:0] - BUILD_HEX_COL[2:0];
    wire  [2:0] build_idx    = 3'd7 - build_pos;
    wire  [3:0] build_nib    = build_stamp[build_idx * 4 +: 4];

    wire        is_detail_row = (frow == DETAIL_ROW);
    wire        is_port  = is_detail_row && (fcol == DETAIL_PORT_COL);

    // The title row's "II" sits at cols 10-11 (page ROM cells 74/75). When DX
    // is loaded those two fetches become 'D' and 'X'. frow includes the page
    // scroll, so a scrolled-off title never triggers these.
    wire        is_dx_d  = game_dx && (frow == TITLE_ROW) && (fcol == 7'd10);
    wire        is_dx_x  = game_dx && (frow == TITLE_ROW) && (fcol == 7'd11);
    wire        is_hex   = is_detail_row && (fcol >= DETAIL_HEX_COL) && (fcol < DETAIL_HEX_COL + 7'd6);
    wire  [2:0] hex_pos  = fcol[2:0] - DETAIL_HEX_COL[2:0];

    wire  [1:0] chk_st = chk_state[2*chk_index +: 2];

    // Result text, 4 characters per state.
    function automatic [5:0] result_char(input logic [1:0] st, input logic [1:0] i);
        case ({st, i})
            4'h0: result_char = 6'd55;  // W
            4'h1: result_char = 6'd33;  // A
            4'h2: result_char = 6'd41;  // I
            4'h3: result_char = 6'd52;  // T
            4'h4: result_char = 6'd34;  // B
            4'h5: result_char = 6'd53;  // U
            4'h6: result_char = 6'd51;  // S
            4'h7: result_char = 6'd57;  // Y
            4'h8: result_char = 6'd48;  // P
            4'h9: result_char = 6'd33;  // A
            4'hA: result_char = 6'd51;  // S
            4'hB: result_char = 6'd51;  // S
            4'hC: result_char = 6'd38;  // F
            4'hD: result_char = 6'd33;  // A
            4'hE: result_char = 6'd41;  // I
            4'hF: result_char = 6'd44;  // L
        endcase
    endfunction

    function automatic [5:0] hex_char(input logic [3:0] v);
        hex_char = (v < 4'd10) ? (C_ZERO + {2'd0, v}) : (C_A + {2'd0, v} - 6'd10);
    endfunction

    // Pass count, for the summary line.
    logic [5:0] pass_count;
    always_comb begin
        pass_count = 6'd0;
        for (int i = 0; i < N_CHECKS; i++)
            if (chk_state[2*i +: 2] == ST_PASS) pass_count = pass_count + 6'd1;
    end
    // Two-digit decimal for the whole 0..39 range. The old form only handled
    // 0..19, so once the list grew past 19 the summary printed nonsense --
    // which is what first showed the aliasing bug above.
    wire [5:0] pc6 = pass_count;   // already 6 bits
    wire [3:0] count_tens = (pc6 >= 6'd30) ? 4'd3 :
                            (pc6 >= 6'd20) ? 4'd2 :
                            (pc6 >= 6'd10) ? 4'd1 : 4'd0;
    wire [5:0] count_rem  = (pc6 >= 6'd30) ? (pc6 - 6'd30) :
                            (pc6 >= 6'd20) ? (pc6 - 6'd20) :
                            (pc6 >= 6'd10) ? (pc6 - 6'd10) : pc6;
    wire [3:0] count_ones = count_rem[3:0];

    // hex_pos is only meaningful on the six hex cells; clamp so the part-select
    // stays inside bad_addr everywhere else on the line.
    wire [2:0] hex_idx = (hex_pos > 3'd5) ? 3'd0 : (3'd5 - hex_pos);
    wire [3:0] hex_nib = bad_addr[hex_idx * 4 +: 4];

    //------------------------------------------------------------------
    // Character select. page_ch is one clock behind the fetch position, so
    // every decision made from that position is registered to match.
    //------------------------------------------------------------------
    logic [5:0] dyn_ch;
    logic       dyn_sel;
    logic       blank_cell;
    logic [1:0] cell_st;
    logic       cell_is_result, cell_is_title, cell_is_detail, cell_is_hint;
    logic [2:0] sub_d;

    always_ff @(posedge clk) begin
        sub_d <= fsub;

        dyn_sel <= is_result | is_count | is_port | is_hex | is_mode_hex | is_build_hex | is_pc_hex | is_dx_d | is_dx_x;
        // The whole detail line stays blank until the SDRAM check has actually
        // failed, so a healthy board does not show a stray "CH0 @ 0x000000".
        // Each detail line is blanked entirely unless it has something to say.
        blank_cell <= (is_detail_row & ~bad_valid) | (is_mode_row & ~mode_valid);

        if (is_dx_d)       dyn_ch <= 6'd36;   // 'D'
        else if (is_dx_x)  dyn_ch <= 6'd56;   // 'X'
        else if (is_result) dyn_ch <= result_char(chk_st, result_pos);
        else if (is_count) dyn_ch <= C_ZERO + {2'd0, (count_lo ? count_ones : count_tens)};
        else if (is_port)     dyn_ch <= C_ZERO + {3'd0, bad_ch};
        else if (is_mode_hex) dyn_ch <= hex_char(mode_nib);
        else if (is_build_hex)dyn_ch <= hex_char(build_nib);
        else if (is_pc_hex)   dyn_ch <= hex_char(pc_nib);
        else                  dyn_ch <= hex_char(hex_nib);

        cell_st        <= chk_st;
        cell_is_result <= is_result;
        cell_is_title  <= (frow == TITLE_ROW);
        cell_is_detail <= is_detail_row | is_mode_row;
        cell_is_hint   <= (frow == HINT_ROW);
    end

    wire [5:0] ch = blank_cell ? C_SPACE : (dyn_sel ? dyn_ch : page_ch);

    //------------------------------------------------------------------
    // Font lookup
    //------------------------------------------------------------------
    logic [7:0] font_bits;

    raiden2_font8x8 font (
        .clk  (clk),
        .code (ch),
        .row  (sub_d),
        .bits (font_bits)
    );

    //------------------------------------------------------------------
    // Colour for the cell, resolved at the same time as its glyph.
    //------------------------------------------------------------------
    localparam logic [23:0] COL_BG     = 24'h000010;
    localparam logic [23:0] COL_TITLE  = 24'hFFFFFF;
    localparam logic [23:0] COL_LABEL  = 24'hB0B8C0;
    localparam logic [23:0] COL_DOT    = 24'h303840;
    localparam logic [23:0] COL_WAIT   = 24'h606060;
    localparam logic [23:0] COL_BUSY   = 24'hFFC000;
    localparam logic [23:0] COL_PASS   = 24'h30E040;
    localparam logic [23:0] COL_FAIL   = 24'hFF3030;
    localparam logic [23:0] COL_DETAIL = 24'hFF8080;
    localparam logic [23:0] COL_HINT   = 24'h4090A0;

    logic [23:0] fg;
    always_comb begin
        if (cell_is_result) begin
            case (cell_st)
                ST_WAIT: fg = COL_WAIT;
                ST_BUSY: fg = COL_BUSY;
                ST_PASS: fg = COL_PASS;
                default: fg = COL_FAIL;
            endcase
        end else if (cell_is_title)  fg = COL_TITLE;
        else if (cell_is_detail)     fg = COL_DETAIL;
        else if (cell_is_hint)       fg = COL_HINT;
        else if (ch == C_DOT)        fg = COL_DOT;
        else                         fg = COL_LABEL;
    end

    //------------------------------------------------------------------
    // Latch the finished cell as the last pixel of the previous cell is drawn,
    // then shift out one pixel at a time. Font rows are MSB-left.
    //------------------------------------------------------------------
    logic  [7:0] cur_bits;
    logic [23:0] cur_fg;

    always_ff @(posedge clk) begin
        if (ce_pix && hcnt[2:0] == 3'd7) begin
            cur_bits <= font_bits;
            cur_fg   <= fg;
        end
    end

    assign rgb = cur_bits[7 - hcnt[2:0]] ? cur_fg : COL_BG;

endmodule
