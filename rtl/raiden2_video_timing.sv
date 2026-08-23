//============================================================================
//  Raiden II - video timing generator
//
//  From MAME src/mame/seibu/raiden2.cpp:
//      screen.set_raw(32MHz/4, 512, 0, 320, 282, 0, 240)   // ROT270
//
//  Pixel clock 8 MHz, H total 512 (320 visible), V total 282 (240 visible),
//  giving 8e6 / (512*282) = 55.42 Hz. Measured on a real PCB: VSync 55.4859 Hz,
//  HSync 15.5586 kHz. Our H rate is 8e6/512 = 15.625 kHz, about 0.4% fast
//  against that measurement -- MAME's raw numbers are what we model, and the
//  discrepancy is left documented rather than fudged, since nothing here has
//  been verified against hardware.
//
//  Sync positions are NOT given by set_raw. The values below are placed inside
//  the blanking intervals and are a guess; they affect how the MiSTer scaler
//  frames the image, not what the game renders.
//
//  The monitor is vertical, so sys/ needs screen_rotate for normal displays.
//
//  line_start pulses at the beginning of every line and asks the tilemap
//  engine to fill the NEXT line into the opposite buffer bank. That gives the
//  fill a full line (512 pixel-times = 4096 clocks at clk_sys/8) rather than
//  just the 1536 clocks of hblank, which measurement shows it needs: a line
//  fill costs ~2400 clocks with a zero-latency ROM and ~2900 at 4 clocks of
//  ROM latency.
//============================================================================

module raiden2_video_timing #(
    parameter int H_TOTAL  = 512,
    parameter int H_VIS    = 320,
    parameter int V_TOTAL  = 282,
    parameter int V_VIS    = 240,
    // Sync POSITION centres the picture; MAME's set_raw only fixes the totals
    // and the active area, so these were ours to choose and were not centred.
    //
    // A monitor begins its sweep at the sync pulse, so the BACK porch (sync end
    // to the next active pixel) decides how far right/down the image sits. The
    // old values gave a 16-pixel front porch against a 128-pixel back porch,
    // which started active video 28% into the horizontal sweep and left a black
    // band down the LEFT of the screen. Vertically 10 against 29 did the same
    // thing, seating the picture high.
    //
    // Splitting the blanking evenly either side of the sync pulse centres both
    // axes: H (512-320-48)/2 = 72, V (282-240-3)/2 = 19.
    parameter int HS_START = 392,   // 320 + 72 front porch
    parameter int HS_END   = 440,   // 48-pixel sync, leaving 72 back porch
    parameter int VS_START = 259,   // 240 + 19 front porch
    parameter int VS_END    = 262,  // 3-line sync, leaving 20 back porch
    parameter int CLK_DIV  = 8        // clk_sys 64 MHz -> 8 MHz pixel clock
) (
    input  logic       clk,
    input  logic       reset,

    // OSD "Refresh Rate" option. The pixel clock and the 512-pixel line are
    // untouched (H stays 15.625 kHz); only the vertical total shrinks,
    // 282 -> 260 lines, giving 8e6/(512*260) = 60.10 Hz for CRTs that will
    // not hold 55.4 Hz. Both render engines fill line buffers within each
    // line, so fewer blanking lines change nothing they depend on -- but the
    // vblank IRQ comes 8.4% sooner, so the GAME RUNS THAT MUCH FASTER. This
    // is the same trade every 60 Hz core option makes; it is labelled, not
    // hidden. The 17 blanking lines split 8/3/9 around the sync pulse, the
    // same centring rule as the native values above.
    input  logic       rate_60,

    output logic       ce_pix,
    output logic [9:0] hcnt,
    output logic [8:0] vcnt,

    output logic       hsync,
    output logic       vsync,
    output logic       hblank,
    output logic       vblank,
    output logic       vblank_rise,   // one clk pulse, drives the CPU's single IRQ

    output logic       line_start,    // pulse: begin filling next_line
    output logic [8:0] next_line
);

    // Runtime-selected vertical totals. H never changes, so H_TOTAL et al stay
    // parameters; these three are the only values the 60 Hz option touches.
    wire [8:0] v_total  = rate_60 ? 9'd260 : V_TOTAL[8:0];
    wire [8:0] vs_start = rate_60 ? 9'd248 : VS_START[8:0];
    wire [8:0] vs_end   = rate_60 ? 9'd251 : VS_END[8:0];

    logic [3:0] divcnt;

    always_ff @(posedge clk) begin
        ce_pix      <= 1'b0;
        line_start  <= 1'b0;
        vblank_rise <= 1'b0;

        if (reset) begin
            divcnt <= 4'd0;
            hcnt   <= 10'd0;
            vcnt   <= 9'd0;
        end else begin
            if (divcnt == CLK_DIV[3:0] - 4'd1) begin
                divcnt <= 4'd0;
                ce_pix <= 1'b1;

                if (hcnt == H_TOTAL[9:0] - 10'd1) begin
                    hcnt <= 10'd0;
                    // >= rather than ==: switching 282 -> 260 mid-frame can
                    // leave vcnt above the new total, and an == would then
                    // only wrap after the 9-bit counter ran to 511.
                    if (vcnt >= v_total - 9'd1) vcnt <= 9'd0;
                    else                        vcnt <= vcnt + 9'd1;

                    // Start of a new line: queue the fill for the line after it.
                    line_start <= 1'b1;

                    if (vcnt == V_VIS[8:0] - 9'd1) vblank_rise <= 1'b1;
                end else begin
                    hcnt <= hcnt + 10'd1;
                end
            end else begin
                divcnt <= divcnt + 4'd1;
            end
        end
    end

    // next_line wraps so the last visible line's fill doesn't run off the end.
    assign next_line = (vcnt >= v_total - 9'd1) ? 9'd0 : vcnt + 9'd1;

    assign hblank = (hcnt >= H_VIS[9:0]);
    assign vblank = (vcnt >= V_VIS[8:0]);
    assign hsync  = (hcnt >= HS_START[9:0]) && (hcnt < HS_END[9:0]);
    assign vsync  = (vcnt >= vs_start) && (vcnt < vs_end);

endmodule
