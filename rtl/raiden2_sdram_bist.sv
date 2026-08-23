//============================================================================
//  Raiden II - SDRAM built-in self test
//
//  Checksums every word as the HPS downloads it, then reads the whole image
//  back through BOTH read paths and compares. This is the one block in the core
//  with no simulation coverage whatsoever -- the sim harness tops out at
//  raiden2_main and answers ROM requests combinationally, so the controller,
//  the loader and both fetch handshakes have never executed anywhere. A silent
//  fault here looks exactly like "the game does not boot".
//
//  Four sweeps, one per port, because the ports differ in ways that can fail
//  independently:
//    ch3  16-bit read/write port, one word per request  -- the CPU's path
//    ch1  32-bit read-only port, two words per request  -- the tile path,
//         whose half-word ordering is called out as unvalidated in Raiden2.sv
//    ch2  64-bit read-only port, four words per request -- the sprite path
//    ch4  64-bit read-only port, four words per request -- the OKI path
//
//  ch2 and ch4 were originally not swept at all: SPRITE FETCH CH2 and OKI ROM
//  FETCH only count that fetches HAPPENED, and SPRITE DECRYPT checksums the
//  inbound download stream, so a fault on either port's return path passed all
//  the checks -- for ch4 that meant bad sound over a fully green page. They
//  were also the two next-tightest hold paths in the failing seed-8 build,
//  which is exactly the kind of fault a data sweep catches and a fetch counter
//  does not.
//
//  sdram.sv returns the word at the request address in dout[15:0] and its
//  successors upward (burst length 4, sequential). The bursts wrap inside an
//  aligned four-word group, so an EVEN word address always gets addr and
//  addr+1 in order, and an 8-BYTE ALIGNED address gets addr..addr+3 in order.
//  The ch1 sweep steps 4 bytes and the ch2/ch4 sweeps step 8, so every request
//  is aligned and the words fold into the checksum in download order -- which
//  is precisely what validates each port's word ordering.
//
//  The download decrypts sprites inline, and the checksummed stream is the
//  POST-decrypt data (dl_acc_data in Raiden2.sv), i.e. what actually landed in
//  SDRAM -- so the sprite region compares clean over every port.
//
//  Sweep order matters: ch3 and ch1 run first. The sprite renderer is held off
//  ch2 while the BIST owns it, but a fetch already in flight when busy rises
//  must drain before the ch2 sweep starts issuing -- the two full-image sweeps
//  ahead of it are hundreds of ms of margin.
//
//  Localisation is per 64 KB block: a checksum per block is kept in a 512-entry
//  table, so a failure reports the base address of the first bad block rather
//  than just "somewhere". Whole-image granularity would say almost nothing.
//
//  ASSUMPTION: the download is contiguous from address 0, which is what the MRA
//  produces (tools/build_rom.py packs the regions with no gaps). If it ever is
//  not, the sweep would read addresses that were never written and fail for the
//  wrong reason -- so the word count is checked against the address span and
//  reports BAD_GAP rather than a misleading address.
//============================================================================

module raiden2_sdram_bist (
    input  logic        clk,
    // Power-on reset ONLY. Deliberately not the OSD/user reset: the download
    // checksums cannot be rebuilt without another download, so clearing them on
    // a user reset would leave the SDRAM check permanently unable to run and it
    // would report FAIL on a perfectly good board. SDRAM contents survive a user
    // reset, so the previous verdict stays valid.
    input  logic        reset,

    // ROM download stream (ioctl, index 0)
    input  logic        dl_active,
    input  logic        dl_wr,
    input  logic [24:0] dl_addr,      // byte address, always even
    input  logic [15:0] dl_data,

    // ch3: 16-bit read/write port
    output logic [24:0] ch3_addr,
    output logic        ch3_req,
    input  logic [15:0] ch3_dout,
    input  logic        ch3_rdy,

    // ch1: 32-bit read-only port
    output logic [24:0] ch1_addr,
    output logic        ch1_req,
    input  logic [31:0] ch1_dout,
    input  logic        ch1_rdy,

    // ch2: 64-bit read-only port (sprites)
    output logic [24:0] ch2_addr,
    output logic        ch2_req,
    input  logic [63:0] ch2_dout,
    input  logic        ch2_rdy,

    // ch4: 64-bit read-only port (OKI)
    output logic [24:0] ch4_addr,
    output logic        ch4_req,
    input  logic [63:0] ch4_dout,
    input  logic        ch4_rdy,

    output logic        dl_complete,  // download finished and checksummed
    output logic        busy,         // hold the core in reset while high
    output logic        done,
    output logic        pass,
    output logic        bad_valid,
    output logic  [2:0] bad_ch,       // SDRAM channel number of the failure
    output logic [23:0] bad_addr
);

    // Sentinel reported when the download itself was not contiguous, so a
    // loader problem is never mistaken for a memory fault.
    localparam logic [23:0] BAD_GAP = 24'hFFFFFF;

    //------------------------------------------------------------------
    // Order-sensitive mixer. Not a CRC -- it only has to catch dropped,
    // duplicated, reordered and corrupted words, which is what the failure
    // modes here look like.
    //------------------------------------------------------------------
    function automatic [31:0] mix(input logic [31:0] s, input logic [15:0] d);
        mix = {s[30:0], s[31] ^ s[21]} ^ {d[7:0], d[15:8], d};
    endfunction

    //------------------------------------------------------------------
    // Per-64KB-block checksum table, written during download and read back
    // during the sweeps.
    //------------------------------------------------------------------
    logic  [8:0] blk_wr_addr, blk_rd_addr;
    logic [31:0] blk_wr_data, blk_rd_data;
    logic        blk_we;

    dualport_ram #(.widthad(9), .width(32)) blk_ram (
        .clock_a   (clk),
        .address_a (blk_wr_addr),
        .data_a    (blk_wr_data),
        .wren_a    (blk_we),
        .q_a       (),
        .clock_b   (clk),
        .address_b (blk_rd_addr),
        .data_b    (32'd0),
        .wren_b    (1'b0),
        .q_b       (blk_rd_data)
    );

    //------------------------------------------------------------------
    // Download side: accumulate a running checksum, flushing it into the table
    // whenever the block index changes and at end of download.
    //------------------------------------------------------------------
    logic [31:0] dl_sum;
    logic  [8:0] dl_blk;
    logic        dl_seen;
    logic [24:0] last_addr;
    logic [24:0] dl_words;
    logic        dl_done;
    logic        busy_run;      // set with dl_done; cleared by reset/restart

    assign dl_complete = dl_done;

    wire [8:0] this_blk = dl_addr[24:16];

    // A word arriving after a completed run means a new image is being loaded,
    // so the run re-arms. Keying that off the word rather than off a dl_active
    // edge matters: the first ioctl_wr can land in the same cycle dl_active
    // rises, and a separate clear branch would swallow word 0 -- which then
    // shows up as a bogus "non-contiguous download" on a perfectly good load.
    wire restart    = dl_wr & dl_done;
    wire first_word = dl_wr & (~dl_seen | dl_done);

    always_ff @(posedge clk) begin
        blk_we <= 1'b0;

        if (reset) begin
            dl_sum    <= 32'd0;
            dl_blk    <= 9'd0;
            dl_seen   <= 1'b0;
            last_addr <= 25'd0;
            dl_words  <= 25'd0;
            dl_done   <= 1'b0;
            busy_run  <= 1'b0;
        end else if (dl_wr) begin
            if (first_word) begin
                dl_sum   <= mix(32'd0, dl_data);
                dl_words <= 25'd1;
                dl_done  <= 1'b0;
                busy_run <= 1'b0;      // a new image re-arms the sweep
            end else if (this_blk != dl_blk) begin
                // Block boundary: commit the finished block, start the next.
                blk_wr_addr <= dl_blk;
                blk_wr_data <= dl_sum;
                blk_we      <= 1'b1;
                dl_sum      <= mix(32'd0, dl_data);
                dl_words    <= dl_words + 25'd1;
            end else begin
                dl_sum   <= mix(dl_sum, dl_data);
                dl_words <= dl_words + 25'd1;
            end
            dl_blk    <= this_blk;
            dl_seen   <= 1'b1;
            last_addr <= dl_addr;
        end else if (dl_seen && !dl_active && !dl_done) begin
            // Download finished: flush the final, possibly partial, block.
            blk_wr_addr <= dl_blk;
            blk_wr_data <= dl_sum;
            blk_we      <= 1'b1;
            dl_done     <= 1'b1;
            busy_run    <= 1'b1;   // same cycle as dl_done -- no reset glitch
        end
    end

    // Every word downloaded must account for exactly one address step of 2.
    wire contiguous = (dl_words == (last_addr >> 1) + 25'd1);

    //------------------------------------------------------------------
    // Sweep engine
    //------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE, S_START, S_REQ, S_WAIT, S_CHECK, S_NEXT, S_DONE
    } state_t;
    state_t state;

    logic  [1:0] phase;          // sweep 0 = ch3, 1 = ch1, 2 = ch2, 3 = ch4
    logic [24:0] addr;           // byte address of the next word to read
    logic [31:0] run_sum;
    logic  [8:0] run_blk;
    logic  [1:0] pend_cnt;       // words from this request still to fold in
    logic [47:0] pend;           // those words, next one in [15:0]

    // One word per ch3 request, two per ch1, four per ch2/ch4.
    wire [24:0] addr_step = (phase == 2'd0) ? 25'd2 :
                            (phase == 2'd1) ? 25'd4 : 25'd8;
    wire [24:0] next_addr = addr + addr_step;

    // The current phase's port, seen through one pair of muxes so the fold
    // logic below is written once. Unused upper words are zero for the narrow
    // ports and never folded (pend_cnt gates them).
    wire        rd_rdy  = (phase == 2'd0) ? ch3_rdy :
                          (phase == 2'd1) ? ch1_rdy :
                          (phase == 2'd2) ? ch2_rdy : ch4_rdy;
    wire [63:0] rd_dout = (phase == 2'd0) ? {48'd0, ch3_dout} :
                          (phase == 2'd1) ? {32'd0, ch1_dout} :
                          (phase == 2'd2) ? ch2_dout : ch4_dout;

    // How many words beyond the first this request contributes: the port's
    // width, clipped at the end of the downloaded image.
    wire [1:0] port_extra = (phase == 2'd0) ? 2'd0 :
                            (phase == 2'd1) ? 2'd1 : 2'd3;
    wire [1:0] this_extra = (addr + 25'd6 <= last_addr) ? port_extra :
                            (addr + 25'd4 <= last_addr) ? ((port_extra > 2'd2) ? 2'd2 : port_extra) :
                            (addr + 25'd2 <= last_addr) ? ((port_extra > 2'd1) ? 2'd1 : port_extra) :
                                                          2'd0;

    // "this request is the last one", not "this address is the last word" --
    // the ch1 sweep covers two words per request, so testing the address alone
    // would run one request past the end of the image.
    wire last_word = next_addr > last_addr;

    // A block's checksum is compared when the sweep leaves it, or when the
    // sweep ends. cmp_mismatch has to be visible combinationally: a fault in
    // the FINAL block is discovered in the same cycle the verdict is latched,
    // so deriving pass from the registered bad_valid would read its old value
    // and report PASS on a bad board.
    wire cmp_now      = last_word || (next_addr[24:16] != run_blk);
    wire cmp_mismatch = cmp_now && (run_sum != blk_rd_data);

    assign ch3_addr = addr;
    assign ch1_addr = addr;
    assign ch2_addr = addr;
    assign ch4_addr = addr;

    // busy must rise in the SAME cycle dl_done does, not one cycle later when
    // the state machine has left S_IDLE. Otherwise the core reset -- which is
    // rom_load_busy | busy -- deasserts for exactly one clock between the end
    // of the download and the start of the sweep. In that clock the CPU fetch
    // logic can issue an sdr_cpu_req, and because the ch3 mux still selects the
    // CPU while busy is low, that stray request reaches the controller. Its
    // ready pulse then lands while the BIST is waiting on its own first read,
    // which corrupts block 0's checksum and reports a memory fault on a
    // perfectly good board.
    //
    // It must ALSO be cheap combinationally. busy selects the 25-bit ch3/ch1
    // address mux that feeds the SDRAM controller, and that mux sits on the
    // clk_sys -> clk_ram path to the SDRAM address pins, which is the design's
    // critical path. Deriving busy from the state encoding cost 0.76 ns and
    // pushed clk_ram to -0.394 ns: the two worst paths were literally
    // bist|dl_done -> sdram|SDRAM_A[11] and bist|state.S_IDLE -> the same pin.
    //
    // So it is one AND of two registers instead. busy_run is set in the same
    // cycle dl_done is (single driver, in the download block below), and done
    // is the sweep's own registered output, which preserves the timing that
    // the anti-glitch property needs.
    assign busy = busy_run & ~done;

    always_ff @(posedge clk) begin
        ch3_req <= 1'b0;
        ch1_req <= 1'b0;
        ch2_req <= 1'b0;
        ch4_req <= 1'b0;

        if (reset || restart) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            pass       <= 1'b0;
            bad_valid  <= 1'b0;
            bad_ch     <= 3'd0;
            bad_addr   <= 24'd0;
            phase      <= 2'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (dl_done) begin
                        if (!contiguous) begin
                            // Loader problem, not a memory problem. Say so.
                            done      <= 1'b1;
                            pass      <= 1'b0;
                            bad_valid <= 1'b1;
                            bad_addr  <= BAD_GAP;
                            state     <= S_DONE;
                        end else begin
                            phase <= 2'd0;
                            state <= S_START;
                        end
                    end
                end

                S_START: begin
                    addr     <= 25'd0;
                    run_sum  <= 32'd0;
                    run_blk  <= 9'd0;
                    pend_cnt <= 2'd0;
                    state    <= S_REQ;
                end

                S_REQ: begin
                    case (phase)
                        2'd0: ch3_req <= 1'b1;
                        2'd1: ch1_req <= 1'b1;
                        2'd2: ch2_req <= 1'b1;
                        2'd3: ch4_req <= 1'b1;
                    endcase
                    blk_rd_addr <= run_blk;
                    state       <= S_WAIT;
                end

                S_WAIT: begin
                    if (rd_rdy) begin
                        // First word now; the rest of the burst is parked in
                        // pend and folded one per cycle in S_CHECK, clipped to
                        // the words actually inside the downloaded range.
                        run_sum  <= mix(run_sum, rd_dout[15:0]);
                        pend     <= rd_dout[63:16];
                        pend_cnt <= this_extra;
                        state    <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    if (pend_cnt != 2'd0) begin
                        run_sum  <= mix(run_sum, pend[15:0]);
                        pend     <= {16'd0, pend[47:16]};
                        pend_cnt <= pend_cnt - 2'd1;
                    end else begin
                        state <= S_NEXT;
                    end
                end

                S_NEXT: begin
                    // Compare when the next address leaves this block, or when
                    // the sweep has consumed the last word.
                    if (cmp_now) begin
                        if (cmp_mismatch && !bad_valid) begin
                            bad_valid  <= 1'b1;
                            // The literal channel number, for the detail line.
                            bad_ch     <= (phase == 2'd0) ? 3'd3 :
                                          (phase == 2'd1) ? 3'd1 :
                                          (phase == 2'd2) ? 3'd2 : 3'd4;
                            // Block base as a byte address. The image tops out
                            // at 14 MB, so run_blk never exceeds 8 bits here.
                            bad_addr   <= {run_blk[7:0], 16'd0};
                        end
                        run_sum <= 32'd0;
                        run_blk <= next_addr[24:16];
                    end

                    if (last_word) begin
                        if (phase != 2'd3) begin
                            phase <= phase + 2'd1;   // ch3 -> ch1 -> ch2 -> ch4
                            state <= S_START;
                        end else begin
                            done  <= 1'b1;
                            pass  <= ~(bad_valid | cmp_mismatch);
                            state <= S_DONE;
                        end
                    end else begin
                        addr  <= addr + addr_step;
                        state <= S_REQ;
                    end
                end

                default: ;   // S_DONE: latch and stay
            endcase
        end
    end

endmodule
