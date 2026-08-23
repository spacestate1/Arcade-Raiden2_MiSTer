//============================================================================
//  Arcade: Raiden II (Seibu Kaihatsu, 1993) - MiSTer core
//
//  Port list and sys/ are from Arcade-IremM92_MiSTer (Martin Donlon,
//  wickerwaka), GPL-2.0, which is also where nec_core, sdram.sv and the RAM
//  primitives come from. The Seibu-specific RTL is ours; MAME's seibu driver
//  sources (LGPL-2.1+, Olivier Galibert, Angelo Salese, David Haywood,
//  Tomasz Slanina et al.) are the behavioural reference throughout.
//
//  STATUS: tilemaps, sprites (SEI252), the SEI360 mixer, sprite ROM decryption
//  in the loader, and the Seibu sound section (Z80 + YM2151 + 2x OKI6295) are
//  all in place. Coins arrive through the sound CPU, so credits depend on that
//  Z80 running. See RESEARCH.md for what is still missing.
//============================================================================

module emu
(
    //Master input clock
    input         CLK_50M,

    //Async reset from top-level module.
    //Can be used as initial reset.
    input         RESET,

    //Must be passed to hps_io module
    inout  [48:0] HPS_BUS,

    //Base video clock. Usually equals to CLK_SYS.
    output        CLK_VIDEO,

    //Multiple resolutions are supported using different CE_PIXEL rates.
    //Must be based on CLK_VIDEO
    output        CE_PIXEL,

    //Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
    //if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,    // = ~(VBlank | HBlank)
    output        VGA_F1,
    output [1:0]  VGA_SL,
    output        VGA_SCALER, // Force VGA scaler
    output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
    // Use framebuffer in DDRAM (USE_FB=1 in qsf)
    // FB_FORMAT:
    //    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
    //    [3]   : 0=16bits 565 1=16bits 1555
    //    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
    //
    // FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
    output        FB_EN,
    output  [4:0] FB_FORMAT,
    output [11:0] FB_WIDTH,
    output [11:0] FB_HEIGHT,
    output [31:0] FB_BASE,
    output [13:0] FB_STRIDE,
    input         FB_VBL,
    input         FB_LL,
    output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
    // Palette control for 8bit modes.
    // Ignored for other video modes.
    output        FB_PAL_CLK,
    output  [7:0] FB_PAL_ADDR,
    output [23:0] FB_PAL_DOUT,
    input  [23:0] FB_PAL_DIN,
    output        FB_PAL_WR,
`endif
`endif

    output        LED_USER,  // 1 - ON, 0 - OFF.

    // b[1]: 0 - LED status is system status OR'd with b[0]
    //       1 - LED status is controled solely by b[0]
    // hint: supply 2'b00 to let the system control the LED.
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,

    // I/O board button press simulation (active high)
    // b[1]: user button
    // b[0]: osd button
    output  [1:0] BUTTONS,

    input         CLK_AUDIO, // 24.576 MHz
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
    output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

    //ADC
    inout   [3:0] ADC_BUS,

    //SD-SPI
    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

    //High latency DDR3 RAM interface
    //Use for non-critical time purposes
    output        DDRAM_CLK,
    input         DDRAM_BUSY,
    output  [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input  [63:0] DDRAM_DOUT,
    input         DDRAM_DOUT_READY,
    output        DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output  [7:0] DDRAM_BE,
    output        DDRAM_WE,

    //SDRAM interface with lower latency
    output        SDRAM_CLK,
    output        SDRAM_CKE,
    output [12:0] SDRAM_A,
    output  [1:0] SDRAM_BA,
    inout  [15:0] SDRAM_DQ,
    output        SDRAM_DQML,
    output        SDRAM_DQMH,
    output        SDRAM_nCS,
    output        SDRAM_nCAS,
    output        SDRAM_nRAS,
    output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
    //Secondary SDRAM
    //Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
    input         SDRAM2_EN,
    output        SDRAM2_CLK,
    output [12:0] SDRAM2_A,
    output  [1:0] SDRAM2_BA,
    inout  [15:0] SDRAM2_DQ,
    output        SDRAM2_nCS,
    output        SDRAM2_nCAS,
    output        SDRAM2_nRAS,
    output        SDRAM2_nWE,
`endif

    input         UART_CTS,
    output        UART_RTS,
    input         UART_RXD,
    output        UART_TXD,
    output        UART_DTR,
    input         UART_DSR,

    // Open-drain User port.
    // 0 - D+/RX
    // 1 - D-/TX
    // 2..6 - USR2..USR6
    // Set USER_OUT to 1 to read from USER_IN.
    input   [6:0] USER_IN,
    output  [6:0] USER_OUT,

    input         OSD_STATUS
);

///////// Outputs this core does not drive /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;

// Debug trace to the HPS UART. sys_top feeds UART_TXD into the HPS serial
// peripheral, so this is readable on the board as /dev/ttyS1 -- one line per
// frame, which beats rebuilding to read a single hex value off the screen.
// Write-streamer replaces the per-frame line for this diagnostic build: every
// write to the shortlist of game-state variables (handler guard B166, state
// byte 9FD2, frame-wait counter 9FBA, tick pair 9EC4/9EC6, flag 9F62, watchdog
// 9D92/9D94) streams out with the writing PC. One capture shows the guard's
// death in real time -- including the last thing the full path wrote before it
// wedged, which is the datum every single-address watch has failed to produce.
// Declared here rather than with the other dbg wires further down: this
// instantiation precedes them, and an undeclared name would become an
// implicit 1-bit net and silently truncate.
wire  [2:0] dbg_stall_src;
wire [15:0] dbg_es;   // ES/DS1 from the V30, for the pool-init probe
// Declared with dbg_stall_src, above the probe instantiation: declaring it
// further down (with the other video wires) would make this an implicit
// 1-bit net here and silently break the counter.
// Must precede the uart_stream instantiation below: `BUILD_STAMP is used
// there, and with the include further down the macro was undefined at the
// point of use -- Quartus did not error, it silently produced 0x00000000.
`include "raiden2_build_stamp.vh"

wire        vblank_rise;

// #65 decision table, streamed as FFD2/FFD4/FFD6/FFD8. Declared HERE rather
// than beside the sound block below, because a forward reference would create
// an implicit 1-bit net instead -- the same silent failure as the dangling
// sprprot_cs in #61.
wire snd_oki_write, snd_z80_intack, snd_latch_rd, snd_bank_exec;
// Declared HERE, before the uart_stream instantiation below: a forward
// reference would create a 1-bit IMPLICIT NET and silently truncate this
// 16-bit counter -- the same failure class as the dangling sprprot_cs in #61.
wire        tm_busy;
reg  [15:0] tm_drop_cnt;
// sei252 has the SAME latent bug as sei0200: `start` is only accepted in
// S_IDLE, so a line whose sprite fill has not finished is silently dropped and
// the sprite line buffer keeps stale pixels. It has no per-scanline sprite
// limit by design ("renders every sprite that intersects the line"), so the
// fill time grows without bound with sprite count -- which is exactly
// "distortion when a lot of things come on screen at once". Measured, not
// assumed. Declared here: a forward ref would truncate these to 1 bit (#61).
// #73 beam probe. 0x0205 is the object position-update the plasma beam's
// segments ride on; MAME issues it ~2.6x more often than we do. Per-FRAME
// counts so the board's rate is directly comparable with MAME's, rather than
// a cumulative total that saturates and tells us nothing (the FFE4 mistake).
wire        dbg_cmd_any, dbg_cmd_0205;
reg  [15:0] cop_any_cnt, cop_0205_cnt;
wire        spr_busy;
reg  [15:0] cram_hash_pub;   // declared early: forward ref truncates to 1 bit (#61)
reg  [15:0] spr_drop_cnt;
reg  [15:0] spr_fill_max;
reg  [15:0] tm_fill_max;   // declared early: forward ref would truncate to 1 bit
wire [15:0] snd_z80_pc;
wire snd_rst18_ack, snd_pending_rd;

raiden2_uart_stream uart_stream
(
    .clk(clk_sys), .reset(sys_reset),
    .wr(dbg_wram_we), .waddr(dbg_wram_addr),
    .es(dbg_es),
    .wdata(dbg_wram_wdata), .wcop(dbg_wram_cop),
    .pc(dbg_pc),
    .stall_src(dbg_stall_src),
    .vbl_pulse(vblank_rise),
    .chk_state(chk_state), .build_stamp(`BUILD_STAMP),
    .ch4_req(sdr_ch4_req_wide), .ch4_rdy(sdr_oki_rdy), .coin_seen(coin_seen),
    .snd_oki_write(snd_oki_write), .snd_intack(snd_z80_intack),
    .snd_latch_rd(snd_latch_rd),   .snd_bank_exec(snd_bank_exec),
    .snd_z80_pc(snd_z80_pc), .snd_rst18_ack(snd_rst18_ack),
    .snd_pending_rd(snd_pending_rd),
    .joy_sample(joystick_0[15:0]),
    .tm_drop(tm_drop_cnt), .tm_fill_max(tm_fill_max),
    .spr_drop(spr_drop_cnt), .spr_fill_max(spr_fill_max),
    .paused({15'd0, paused}), .cram_hash(cram_hash_pub),
    .cop_any(cop_any_cnt), .cop_0205(cop_0205_cnt),
    .unknown_mode(dbg_unknown_mode), .unknown_valid(dbg_unknown_valid),
    .txd(UART_TXD)
);
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM2_A, SDRAM2_BA, SDRAM2_DQ, SDRAM2_nCS, SDRAM2_nCAS, SDRAM2_nRAS, SDRAM2_nWE, SDRAM2_CLK} = 'Z;

assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign FB_FORCE_BLANK = 0;

// Seibu sound: Z80 + YM2151 + 2x OKI6295. Mono on the board, so both
// channels get the same mix. Signed samples.
assign AUDIO_L = snd_audio;
assign AUDIO_R = snd_audio;
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// Vertical monitor (MAME ROT270), so the native picture is 240x320.
wire [1:0] ar = status[122:121];
// MAME runs this game ROT270, which is a CCW (TATE) rotation. The core
// previously exposed only a vertical/horizontal toggle and left rotate_ccw
// tied to an unused status bit, so it could only ever rotate clockwise -- a
// 180 degree error, which is why the picture came out upside down. Matches
// the option layout of the reference Raiden core.
wire [1:0] rotate_sel = status[3:2];
wire       no_rotate  = (rotate_sel == 2'd2);
wire       rotate_ccw = (rotate_sel == 2'd0);   // default
wire       video_rotated;

// The self-test page defaults to ON, because this core has never run on real
// hardware and a black screen otherwise says nothing about why.
//
// The page is drawn in raster order, so it must NOT go through screen_rotate --
// the cabinet monitor is vertical and the text would come out running up the
// side of the screen. Rotation and aspect are both forced flat while it shows.
// 0 check page (default), 1 synthetic sprite test, 2 game sprites with the
// tilemaps suppressed, 3 full game video.
//
// Mode 2 exists to isolate: it runs the real sprite path -- game list, ch2
// fetch, decrypted ROM -- but with nothing else drawn, so "sprites missing"
// and "sprites hidden behind a tilemap" cannot be confused for each other.
wire [1:0] test_mode      = status[7:6];
// 60 Hz OSD option -- see the CONF_STR note and raiden2_video_timing.
wire       rate_60        = status[8];
// Index 0 is OFF (play the game); the diagnostics follow. Keep this in step
// with the CONF_STR "Self test" line above -- they are positional.
wire       show_checks    = (test_mode == 2'd1);
wire       show_sprtest   = (test_mode == 2'd2);
wire       show_spronly   = (test_mode == 2'd3);
// Only the raster-order pages bypass rotation; mode 2 is real game video.
wire       selftest_show  = show_checks | show_sprtest;
wire       eff_no_rotate  = no_rotate | selftest_show;

assign VIDEO_ARX = (!ar) ? (eff_no_rotate ? 12'd4 : 12'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (eff_no_rotate ? 12'd3 : 12'd4) : 12'd0;

`include "build_id.v"
// Date+time of this compile, regenerated by tools/make_build_stamp.sh before
// every quartus run. Shown on the self-test page: MiSTer's own build_id is
// date-only, so it cannot tell two builds on the same day apart -- which is
// exactly the ambiguity that cost a hardware round trip.
localparam CONF_STR = {
    "Raiden2;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    // NOTE: a stale "O[3],Rotation,CW,CCW;" line used to sit here. It claimed
    // bit 3, which O[3:2] above ALSO owns, so the two OSD entries overwrote
    // each other and the Rotate option appeared to do nothing. Leftover from
    // when rotation was a single vertical/horizontal toggle. Do not re-add a
    // second menu item over bits another one already claims.
    "O[3:2],Rotate,CCW (TATE),CW,None;",
    "O[5:4],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
    // Native timing is 282 lines -> 55.42 Hz, which some 15 kHz CRTs will not
    // hold (github issue #1). 60Hz trims vertical blanking to 260 lines
    // (60.10 Hz, H rate unchanged); the vblank IRQ then comes 8.4% sooner and
    // the game runs that much faster -- accuracy traded for a stable picture.
    "O[8],Refresh Rate,55.4Hz Native,60Hz;",
    // "Off" MUST stay first. MiSTer's status word powers up at 0, so index 0
    // is what a user gets on a fresh core load -- and with "Checks" first the
    // core booted into the diagnostic page instead of the game.
    "O[7:6],Self test,Off,Checks,Sprite test,Sprites only;",
    "-;",
    "DIP;",
    "-;",
    "T[0],Reset;",
    "R[0],Reset and close OSD;",
    // The four "-" are NOT cosmetic. MiSTer assigns joystick bits by POSITION
    // in this list, starting at bit 4, and every arcade core places Start at
    // bit 10 and Coin at bit 11 -- the MRA's
    // names="Fire,Bomb,-,-,-,-,Start,Coin" encodes exactly that, and so does
    // the reference core (Arcade-Raiden_MiSTer/Raiden.sv:241).
    // Without the placeholders Start/Coin landed on bits 6/7, which nothing
    // ever drives, so no coin could be inserted and no game could be started
    // while Fire/Bomb (bits 4/5) worked perfectly -- i.e. "no input does
    // anything". Keep this list and the MRA in step.
    "J1,Fire,Bomb,Auto Fire,-,-,-,Start,Coin,Service,Pause;",
    "V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire [1:0]   buttons;
wire [127:0] status;
wire [10:0]  ps2_key;
wire [21:0]  gamma_bus;
wire [31:0]  joystick_0, joystick_1;
wire [15:0]  joystick_l_analog_0;

wire         ioctl_download;
wire         ioctl_wr;
wire [26:0]  ioctl_addr;
wire [15:0]  ioctl_dout;
wire [15:0]  ioctl_index;

// Held high while a downloaded word is still waiting on the SDRAM controller,
// so the HPS cannot outrun it. Driven by the loader further down.
reg          rom_wr_pending;

// MRA index 254 delivers the DIP switch bytes, already in the polarity the
// CPU reads them (active low -- the MRA default is FF,FF). hps_io runs in
// WIDE mode, so both bytes arrive together in the single 16-bit word at
// ioctl_addr 0; ioctl_addr[0] is always 0 and cannot be used to index them.
// Game select. The MRA supplies a single byte at ioctl index 1:
//   <rom index="1"><part>00</part></rom>  -> Raiden II
//   <rom index="1"><part>01</part></rom>  -> Raiden DX
// Latched once at download and held; it gates the banking, the CRTC
// register swap and the SDRAM layout, all of which differ between the two.
reg [7:0] game_mod = 8'd0;
always @(posedge clk_sys) begin
    // The game select MUST be latched BEFORE the index-0 ROM data arrives, so
    // both MRAs list <rom index="1"> FIRST. This is not cosmetic ordering:
    // sprites are decrypted inline as they stream past (see SPR_BASE below),
    // and the decrypt window is per-game. Latching the select after the data,
    // as this used to, meant every DX load decrypted with Raiden II's map --
    // tile data run through the sprite cipher, sprites keyed at the wrong
    // offset, and the top 2.5 MB left as raw ciphertext.
    //
    // There is deliberately NO clear-on-index-0 any more: it would wipe the
    // select that index 1 has just set. Both shipped MRAs state the game
    // explicitly (Raiden II sends 00, Raiden DX sends 01), so switching
    // between them cannot leave a stale value. An MRA that omits index 1
    // entirely would inherit the previous game's map -- ours never do.
    if (ioctl_wr && ioctl_index == 8'd1) game_mod <= ioctl_dout[7:0];
end
wire      game_dx = game_mod[0];
wire [3:0] dx_prg_bank;   // 0x470 top nibble, DX program bank

reg [7:0] dsw_bytes[2];
always @(posedge clk_sys) begin
    if (ioctl_wr && ioctl_index == 8'd254 && !ioctl_addr[26:1]) begin
        dsw_bytes[0] <= ioctl_dout[7:0];
        dsw_bytes[1] <= ioctl_dout[15:8];
    end
end

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
    .clk_sys(clk_sys),
    .HPS_BUS(HPS_BUS),
    .EXT_BUS(),
    .gamma_bus(gamma_bus),

    .forced_scandoubler(forced_scandoubler),
    .buttons(buttons),
    .status(status),
    .status_menumask(0),

    .ioctl_download(ioctl_download),
    .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr),
    .ioctl_dout(ioctl_dout),
    .ioctl_index(ioctl_index),
    .ioctl_wait(dl_busy),

    .joystick_0(joystick_0),
    .joystick_l_analog_0(joystick_l_analog_0),
    .joystick_1(joystick_1),
    .ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////
//
// clk_sys 64 MHz: verified to close timing (Fmax 79.76 MHz at the slow
// corner). The whole design is clock-enabled off it -- 8 MHz pixel clock via
// /8, and a 32 MHz tick that the V30's two-phase CE halves to 16 MHz.
//
// clk_ram 96 MHz drives the SDRAM controller.
//
// It used to be 128 MHz, chosen as 2x clk_sys so the req/ready handshake stayed
// synchronous rather than a true CDC. That does not close timing: sdram.sv's own
// state machine -> command decode tops out around 118 MHz in this device, so
// 128 MHz left only +0.210 ns at first and went negative (-0.844 ns) as soon as
// the design grew. 96 MHz gives the controller 10.4 ns instead of 7.8 ns and
// closes with room to spare.
//
// 96/64 is a 3:2 ratio, NOT an integer multiple, so the crossing is no longer
// implicitly safe and two things are needed -- do not remove either:
//
//   1. Pulse widening in both directions (see the SDRAM section below).
//      sdram.sv asserts ch*_ready for a single clk_ram cycle; at 96 MHz that is
//      10.4 ns against a 15.6 ns clk_sys period, so it can be missed entirely.
//   2. The multicycle exceptions in Raiden2.sdc, because the clocks realign only
//      every 31.25 ns and the tightest edge pair is 5.2 ns.
//
// UNVALIDATED ON HARDWARE: the controller's refresh timing came from a core that
// clocks it at 120 MHz, and none of this crossing has ever run on real silicon --
// which is what the on-screen self test exists to check.

wire clk_sys, clk_ram, pll_locked;
pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(clk_ram),
    .outclk_1(clk_sys),
    .locked(pll_locked)
);

// dl_busy keeps this asserted while the sprite decryptor drains its last
// dword: ioctl_download drops as soon as the HPS has handed over the final
// word, but that word is still two SDRAM writes away from landing.
wire dl_busy;
wire rom_load_busy = (ioctl_download && (ioctl_index == 0)) | dl_busy;
wire signed [15:0] snd_audio;

// Declared here rather than with the rest of the SDRAM plumbing because the
// core reset below depends on bist_busy, and a forward reference would be
// implicitly declared as a 1-bit net and then clash with the real declaration.
wire [24:0] bist_ch3_addr, bist_ch1_addr, bist_ch2_addr, bist_ch4_addr;
wire        bist_ch3_req,  bist_ch1_req,  bist_ch2_req,  bist_ch4_req;
wire        bist_dl_complete, bist_busy, bist_done, bist_pass;
wire        bist_bad_valid;
wire  [2:0] bist_bad_ch;
wire [23:0] bist_bad_addr;

// Two resets. The video timing must keep running while the SDRAM self test
// sweeps memory, or there would be no picture to show the "BUSY" line on; the
// game logic must not, because the BIST owns both SDRAM read channels for the
// duration.
wire sys_reset = RESET | status[0] | buttons[1] | ~pll_locked;
wire reset     = sys_reset | rom_load_busy | bist_busy;

///////////////////////   SDRAM   ////////////////////////////////
//
// Layout matches the flat image tools/build_rom.py produces, which is also
// what the MRA assembles:
//
//   0x000000  maincpu   1 MB     0x120000  chars    128 KB
//   0x100000  audiocpu  128 KB   0x140000  copx     256 KB
//   0x180000  oki1      256 KB   0x1C0000  oki2     256 KB
//   0x200000  tiles     4 MB     0x600000  sprites  8 MB   (loaded, not yet used)
//
// Channels: ch1 is the 32-bit port, which is exactly the width sei0200 wants
// for a tile row. ch3 is the only read/write channel, so it carries both CPU
// program fetches and the ROM download. ch2/ch4 are reserved for sprites and
// PCM once those exist.

// SDRAM layout. Raiden II's offsets are LEFT EXACTLY AS THEY WERE -- they are
// verified end to end and its MRA encodes them -- and Raiden DX gets its own
// map, because DX has a 2 MB program ROM (vs 1 MB) and 1 MB OKI regions (vs
// 256 KB), which will not fit Raiden II's layout at any offset.
//
//            Raiden II            Raiden DX
//  maincpu   000000  1 MB         000000  2 MB
//  audio     100000  128 K        200000  128 K
//  chars     120000  128 K        220000  128 K
//  copx      140000  256 K        240000  256 K
//  oki1      180000  256 K        280000  1 MB
//  oki2      1C0000  256 K        380000  1 MB
//  tiles     200000  4 MB         480000  4 MB
//  sprites   600000  8 MB         880000  8 MB
//            = 14 MB              = 16.5 MB
localparam [24:0] SDR_MAINCPU = 25'h000000;      // same base for both
wire [24:0] SDR_CHARS   = game_dx ? 25'h220000 : 25'h120000;
wire [24:0] SDR_TILES   = game_dx ? 25'h480000 : 25'h200000;
wire [24:0] SDR_SPRITES = game_dx ? 25'h880000 : 25'h600000;
wire [24:0] SDR_OKI1    = game_dx ? 25'h280000 : 25'h180000;
wire [24:0] SDR_OKI2    = game_dx ? 25'h380000 : 25'h1C0000;

wire [31:0] sdr_gfx_dout;
wire [24:0] sdr_gfx_addr;

// ch2: the sprite ROM fetch. 64 bits wide, which is exactly one 8-byte tile
// row per request -- SEI252 used to take two 32-bit reads per row and that put
// the worst scanline over its 4096-clock budget once fetch latency passed
// about 4 cycles. The four 16-bit words come from one SDRAM burst, so the
// extra three are nearly free.
wire [63:0] sdr_spr_dout;
wire [24:0] sdr_spr_addr;
wire        sdr_spr_rdy;
reg         sdr_spr_req;

// ch4: OKI6295 sample fetch. Both ADPCM channels stream sequentially and the
// sound module caches a whole 8-byte line per fetch, so this port sees very
// little traffic.
wire [63:0] sdr_oki_dout;
wire [24:0] sdr_oki_addr;
wire        sdr_oki_rdy;
wire        sdr_oki_req;
wire        sdr_gfx_rdy;
reg         sdr_gfx_req;

wire [63:0] sdr_cpu_dout;
wire [24:0] sdr_cpu_addr;
wire        sdr_cpu_rdy;
wire        sdr_cpu_req = sdr_cpu_req_w;

// ---- Crossing the clk_ram -> clk_sys boundary ------------------------
//
// clk_ram is 96 MHz and clk_sys is 64 MHz, so clk_ram is NOT an integer
// multiple of clk_sys. That matters more than it looks:
//
// sdram.sv drives ch*_ready for exactly ONE clk_ram cycle (it clears them
// unconditionally at the top of its always block). At 96 MHz that pulse is
// 10.4 ns, while clk_sys samples every 15.6 ns -- so a ready pulse can fall
// entirely between two clk_sys edges and be lost. The core would then wait
// forever on a fetch that had already completed. No SDC constraint can fix
// this; a multicycle path relaxes WHEN a signal must be stable, it cannot make
// a pulse shorter than the sampling period observable.
//
// (This is why the design previously required clk_ram = 2 x clk_sys, where
// every clk_sys edge coincides with a clk_ram edge and the pulse is always
// caught. Dropping clk_ram alone to 96 MHz silently breaks that.)
//
// So: stretch to two clk_ram cycles (20.8 ns) HERE, in the clk_ram domain,
// which guarantees at least one clk_sys edge sees it; then rising-edge detect
// on the clk_sys side so a pulse that happens to span two clk_sys edges is
// still consumed exactly once. Stretching in our own file rather than editing
// the vendored controller keeps sdram.sv untouched.
//
// The request direction needs no such treatment: ch*_req is a one-clk_sys
// pulse (15.6 ns) against a 10.4 ns clk_ram period, so it is always sampled.
reg  sdr_gfx_rdy_d, sdr_cpu_rdy_d, sdr_spr_rdy_d, sdr_oki_rdy_d;
always @(posedge clk_ram) begin
    sdr_gfx_rdy_d <= sdr_gfx_rdy;
    sdr_cpu_rdy_d <= sdr_cpu_rdy;
    sdr_spr_rdy_d <= sdr_spr_rdy;
    sdr_oki_rdy_d <= sdr_oki_rdy;
end
wire sdr_gfx_rdy_wide = sdr_gfx_rdy | sdr_gfx_rdy_d;
wire sdr_cpu_rdy_wide = sdr_cpu_rdy | sdr_cpu_rdy_d;
wire sdr_spr_rdy_wide = sdr_spr_rdy | sdr_spr_rdy_d;
wire sdr_oki_rdy_wide = sdr_oki_rdy | sdr_oki_rdy_d;

// Same single-flop rule as the request direction in sdram.sv: *_rdy_wide is a
// combinational OR of two clk_ram flops, and comparing it directly against its
// clk_sys history gave the crossing net two destinations. Under the
// multicycle-2 relaxation the two can settle on different clk_sys edges and
// the ack edge is lost -- the transaction completed but nobody hears it. One
// sampling flop first, then edge-detect between registered stages. The
// 2-clk_ram stretch (20.8 ns) still guarantees the sampler sees every ready.
reg  sdr_gfx_rdy_s, sdr_cpu_rdy_s, sdr_spr_rdy_s, sdr_oki_rdy_s;
reg  sdr_gfx_rdy_wide_d, sdr_cpu_rdy_wide_d, sdr_spr_rdy_wide_d, sdr_oki_rdy_wide_d;
always @(posedge clk_sys) begin
    sdr_gfx_rdy_s <= sdr_gfx_rdy_wide;  sdr_gfx_rdy_wide_d <= sdr_gfx_rdy_s;
    sdr_cpu_rdy_s <= sdr_cpu_rdy_wide;  sdr_cpu_rdy_wide_d <= sdr_cpu_rdy_s;
    sdr_spr_rdy_s <= sdr_spr_rdy_wide;  sdr_spr_rdy_wide_d <= sdr_spr_rdy_s;
    sdr_oki_rdy_s <= sdr_oki_rdy_wide;  sdr_oki_rdy_wide_d <= sdr_oki_rdy_s;
end
// One clk_sys pulse per completed transaction. Every consumer uses these.
wire sdr_gfx_ack = sdr_gfx_rdy_s & ~sdr_gfx_rdy_wide_d;
wire sdr_cpu_ack = sdr_cpu_rdy_s & ~sdr_cpu_rdy_wide_d;
wire sdr_spr_ack = sdr_spr_rdy_s & ~sdr_spr_rdy_wide_d;
wire sdr_oki_ack = sdr_oki_rdy_s & ~sdr_oki_rdy_wide_d;

// ch3 is shared: the loader owns it while a download is in progress.
reg  [24:0] sdr_rom_addr;
reg  [15:0] sdr_rom_din;
reg         sdr_rom_req;

// The self-test sweeps all four read channels once the download is done, and
// owns them exclusively: the core is held in reset for the duration, so
// sdr_cpu_req, sdr_gfx_req and sdr_oki_req are parked low by their own reset
// branches, and the sprite fetch FSM is gated on ~bist_busy (sei252 only
// resets on sys_reset). Its wires are declared up with the reset logic, which
// depends on bist_busy.
//
// Muxing sdr_ch3_req is only safe because all three sides are one-clock pulses
// that idle low: with toggle-encoded requests the mux would step from one level
// to the other when rom_load_busy falls and fake a request out of nothing.
wire [24:0] sdr_ch3_addr = rom_load_busy ? sdr_rom_addr
                         : bist_busy     ? bist_ch3_addr : sdr_cpu_addr;
wire [15:0] sdr_ch3_din  = sdr_rom_din;
wire  [1:0] sdr_ch3_be   = 2'b11;
wire        sdr_ch3_rnw  = ~rom_load_busy;      // the BIST only ever reads
wire        sdr_ch3_req  = rom_load_busy ? sdr_rom_req
                         : bist_busy     ? bist_ch3_req : sdr_cpu_req;
wire        sdr_ch3_rdy;
assign      sdr_cpu_rdy  = sdr_ch3_rdy;

// Same for the 32-bit port. Only the BIST and the tile fetcher use it, and they
// are never active at the same time.
wire [24:0] sdr_ch1_addr_mux = bist_busy ? bist_ch1_addr : sdr_gfx_addr;
wire        sdr_ch1_req_mux  = bist_busy ? bist_ch1_req  : sdr_gfx_req;

// And the two 64-bit ports. The OKI side is in reset (jt6295 and the cache
// both sit on `reset`, which includes bist_busy) so it is parked low; the
// sprite renderer only resets on sys_reset -- it keeps rastering the self-test
// backdrop -- so its fetch FSM below is explicitly gated on ~bist_busy, and
// the BIST orders the ch2 sweep after two full-image sweeps so anything in
// flight at the handover has long since drained.
wire [24:0] sdr_ch2_addr_mux = bist_busy ? bist_ch2_addr : sdr_spr_addr;
wire        sdr_ch2_req_mux  = bist_busy ? bist_ch2_req  : sdr_spr_req;
wire [24:0] sdr_ch4_addr_mux = bist_busy ? bist_ch4_addr : sdr_oki_addr;
wire        sdr_ch4_req_mux  = bist_busy ? bist_ch4_req  : sdr_oki_req;

// ---- Crossing clk_sys -> clk_ram --------------------------------------
// The mirror of the ready stretch above. A one-clk_sys request pulse is 15.6 ns
// and would in fact always be sampled by a 10.4 ns clk_ram period -- but the
// multicycle exceptions in Raiden2.sdc relax the crossing to two clk_ram
// periods (20.8 ns), which is longer than the pulse. Rather than rely on real
// routing delay being nowhere near the relaxed bound, widen the request to two
// clk_sys cycles (31.25 ns) so it is unambiguously wider than the window the
// constraint permits.
//
// sdram.sv latches on the RISING EDGE (`ch3_req & ~ch3_req_1`), so a two-cycle
// request still produces exactly one transaction. The mux above stays safe for
// the same reason it always was: every source idles low.
reg  sdr_ch3_req_d, sdr_ch1_req_d, sdr_ch2_req_d, sdr_ch4_req_d;
always @(posedge clk_sys) begin
    sdr_ch3_req_d <= sdr_ch3_req;
    sdr_ch1_req_d <= sdr_ch1_req_mux;
    sdr_ch2_req_d <= sdr_ch2_req_mux;
    sdr_ch4_req_d <= sdr_ch4_req_mux;
end
wire sdr_ch3_req_wide = sdr_ch3_req    | sdr_ch3_req_d;
wire sdr_ch1_req_wide = sdr_ch1_req_mux | sdr_ch1_req_d;
wire sdr_ch2_req_wide = sdr_ch2_req_mux | sdr_ch2_req_d;
wire sdr_ch4_req_wide = sdr_ch4_req_mux | sdr_ch4_req_d;

sdram sdram
(
    .init(~pll_locked),
    .clk(clk_ram),
    .doRefresh(1'b1),

    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),

    .ch1_addr(sdr_ch1_addr_mux[24:1]), .ch1_dout(sdr_gfx_dout),
    .ch1_req(sdr_ch1_req_wide), .ch1_ready(sdr_gfx_rdy),

    .ch2_addr(sdr_ch2_addr_mux[24:1]), .ch2_dout(sdr_spr_dout),
    .ch2_req(sdr_ch2_req_wide), .ch2_ready(sdr_spr_rdy),

    .ch3_addr(sdr_ch3_addr[24:1]), .ch3_din(sdr_ch3_din), .ch3_dout(sdr_cpu_dout),
    .ch3_be(sdr_ch3_be), .ch3_rnw(sdr_ch3_rnw),
    .ch3_req(sdr_ch3_req_wide), .ch3_ready(sdr_ch3_rdy),

    // ch4 re-enabled: the stall it triggered was request/ack edges being lost
    // at the clk_sys<->clk_ram crossing (see the single-flop notes here and in
    // sdram.sv), not arbitration -- ch4 is lowest priority and merely refit
    // the design onto less lucky routing.
    .ch4_addr(sdr_ch4_addr_mux[24:1]), .ch4_dout(sdr_oki_dout),
    .ch4_req(sdr_ch4_req_wide), .ch4_ready(sdr_oki_rdy)
);

// ---- ROM download -> SDRAM, decrypting sprites on the way through -------
// hps_io runs in WIDE mode, so ioctl_dout is a 16-bit word and ioctl_addr
// counts bytes in steps of 2 -- the same units the SDRAM word address uses.
//
// sdram.sv latches a request on a RISING EDGE of ch*_req (`ch3_req & ~ch3_req_1`),
// so a request must be a ONE-CLOCK PULSE. A toggle only produces a rising edge
// every other time, which silently drops half the transfers.
//
// The address must also be held until the controller services the request:
// it samples ch3_addr at service time, not at request time, and a request can
// sit queued behind ch1/ch2 or a refresh. ioctl_wait keeps the HPS from
// clocking in the next word until this one has landed.
//
// Sprites arrive from the MRA still encrypted -- an MRA can interleave and
// byte-swap but cannot run an arbitrary transform, so this is the first point
// at which the data can be put right. raiden2_r2crypt works on 32-bit dwords
// while the download is 16-bit words, so words inside the sprite region are
// paired up: the low half is stashed and writes nothing, the high half fires
// the decryptor and then writes both halves back to back. Total SDRAM writes
// are unchanged, just bursty.
//
// NOTE this assumes the MRA hands over RAW ROM data. Feeding it an image whose
// sprites were already decrypted offline (build_rom.py without --encrypted)
// would decrypt them a second time and produce garbage.

// PER-GAME, and it has to be: the sprite region sits at a different address in
// each map (Raiden II 0x600000, Raiden DX 0x880000) and the decrypted index is
// the dword offset WITHIN the region, so a fixed window decrypts the wrong
// bytes with the wrong key. Both regions are 8 MB, so only the base moves.
// game_dx is valid here because the MRA sends index 1 before index 0.
wire [24:0] SPR_BASE = SDR_SPRITES;
wire [24:0] SPR_END  = SDR_SPRITES + 25'h0800000;

wire        dl_word = ioctl_wr && (ioctl_index == 0);
wire [24:0] dl_a    = ioctl_addr[24:0];
wire        dl_spr  = (dl_a >= SPR_BASE) && (dl_a < SPR_END);
// Subtract first, then shift. The region spans 0x600000..0xDFFFFF, so bit 23
// is live inside it and a bit-select of the raw address would lose half of it.
wire [24:0] dl_off  = dl_a - SPR_BASE;
wire [20:0] dl_dw   = dl_off[22:2];                  // dword index in-region

reg  [31:0] crypt_din;
reg  [20:0] crypt_idx;
reg         crypt_go;
wire [31:0] crypt_dout;
wire        crypt_rdy;

raiden2_r2crypt sprite_decrypt
(
    .clk(clk_sys),
    .idx(crypt_idx), .din(crypt_din), .in_valid(crypt_go),
    .dout(crypt_dout), .out_valid(crypt_rdy)
);

localparam DL_IDLE = 3'd0, DL_WAIT = 3'd1, DL_DEC = 3'd2,
           DL_LO   = 3'd3, DL_LOW  = 3'd4, DL_HI  = 3'd5, DL_HIW = 3'd6;

reg  [2:0]  dl_st;
reg  [15:0] dl_lo;
reg  [24:0] dl_lo_addr;
reg  [31:0] dl_dec;

// One place where a word is accepted for SDRAM. The BIST taps this rather than
// ioctl_wr so it checksums what actually lands in memory -- checksumming the
// encrypted stream and comparing against decrypted readback would fail on a
// perfectly healthy board.
reg         dl_acc;
reg  [24:0] dl_acc_addr;
reg  [15:0] dl_acc_data;

assign dl_busy = (dl_st != DL_IDLE);

always @(posedge clk_sys) begin
    sdr_rom_req <= 1'b0;
    crypt_go    <= 1'b0;
    dl_acc      <= 1'b0;

    if (~pll_locked) begin
        dl_st          <= DL_IDLE;
        rom_wr_pending <= 1'b0;
    end else begin
        case (dl_st)
        DL_IDLE:
            if (dl_word) begin
                if (!dl_spr) begin
                    sdr_rom_addr   <= dl_a;
                    sdr_rom_din    <= ioctl_dout;
                    sdr_rom_req    <= 1'b1;
                    rom_wr_pending <= 1'b1;
                    dl_acc         <= 1'b1;
                    dl_acc_addr    <= dl_a;
                    dl_acc_data    <= ioctl_dout;
                    dl_st          <= DL_WAIT;
                end else if (!dl_a[1]) begin
                    // low half of a dword: nothing to write yet, no stall
                    dl_lo      <= ioctl_dout;
                    dl_lo_addr <= dl_a;
                end else begin
                    crypt_din <= {ioctl_dout, dl_lo};
                    crypt_idx <= dl_dw;
                    crypt_go  <= 1'b1;
                    dl_st     <= DL_DEC;
                end
            end

        DL_WAIT:
            if (sdr_cpu_ack) begin
                rom_wr_pending <= 1'b0;
                dl_st          <= DL_IDLE;
            end

        DL_DEC:
            if (crypt_rdy) begin
                dl_dec <= crypt_dout;
                dl_st  <= DL_LO;
            end

        DL_LO: begin
            sdr_rom_addr   <= dl_lo_addr;
            sdr_rom_din    <= dl_dec[15:0];
            sdr_rom_req    <= 1'b1;
            rom_wr_pending <= 1'b1;
            dl_acc         <= 1'b1;
            dl_acc_addr    <= dl_lo_addr;
            dl_acc_data    <= dl_dec[15:0];
            dl_st          <= DL_LOW;
        end

        DL_LOW:
            if (sdr_cpu_ack) begin
                rom_wr_pending <= 1'b0;
                dl_st          <= DL_HI;
            end

        DL_HI: begin
            sdr_rom_addr   <= dl_lo_addr + 25'd2;
            sdr_rom_din    <= dl_dec[31:16];
            sdr_rom_req    <= 1'b1;
            rom_wr_pending <= 1'b1;
            dl_acc         <= 1'b1;
            dl_acc_addr    <= dl_lo_addr + 25'd2;
            dl_acc_data    <= dl_dec[31:16];
            dl_st          <= DL_HIW;
        end

        DL_HIW:
            if (sdr_cpu_ack) begin
                rom_wr_pending <= 1'b0;
                dl_st          <= DL_IDLE;
            end

        default: dl_st <= DL_IDLE;
        endcase
    end
end

// ---- decrypted sprite checksum ----------------------------------------
// Rolls a checksum over exactly the words the loader writes into the sprite
// region, and compares it against the value tools/r2crypt.py computes for the
// same ROM set. sim/tb_r2crypt.cpp already proves the decryptor matches the
// oracle for 200k vectors, but only on a board does this also cover the dword
// pairing, the address arithmetic and the write ordering around it.
//
// PER ROM SET. The checksum covers the DECRYPTED sprite region, so each game
// has its own value and a fixed constant makes the other game report a failure
// that says nothing about the hardware. Raiden DX read FAIL here purely for
// that reason before this was split.
//
// Regenerate with:  python3 tools/sprite_crc.py <raiden2|raidendx> <dir-or-zip>
// That tool mirrors the rolling checksum below and is validated by reproducing
// the Raiden II value, so a new number is only as trustworthy as that check.
// A different revision of either set will still read FAIL, as before.
localparam [31:0] SPRITE_CRC_R2 = 32'hD50A780F;
localparam [31:0] SPRITE_CRC_DX = 32'hB3517D70;
wire       [31:0] SPRITE_CRC    = game_dx ? SPRITE_CRC_DX : SPRITE_CRC_R2;

reg  [31:0] spr_crc;
reg         spr_crc_done, spr_crc_pass;
reg         dl_active_d;

wire acc_spr = dl_acc && (dl_acc_addr >= SPR_BASE) && (dl_acc_addr < SPR_END);
wire [31:0] spr_crc_nxt = {spr_crc[30:0], spr_crc[31]} + {16'd0, dl_acc_data};

always @(posedge clk_sys) begin
    dl_active_d <= rom_load_busy;

    if (~pll_locked) begin
        spr_crc      <= 32'd0;
        spr_crc_done <= 1'b0;
        spr_crc_pass <= 1'b0;
    end else begin
        // Re-arm on a fresh download so a second load does not accumulate on
        // top of the first and read FAIL on a healthy board.
        if (rom_load_busy & ~dl_active_d) begin
            spr_crc      <= 32'd0;
            spr_crc_done <= 1'b0;
        end else if (acc_spr) begin
            spr_crc <= spr_crc_nxt;
        end

        // The last sprite word is accepted well before rom_load_busy falls, so
        // spr_crc is final by here.
        if (~rom_load_busy & dl_active_d) begin
            spr_crc_done <= 1'b1;
            spr_crc_pass <= (spr_crc == SPRITE_CRC);
        end
    end
end

// ---- SDRAM self test --------------------------------------------------
// Checksums the download stream, then reads the whole image back through both
// channels and compares. Gated on the loader's own accept condition rather than
// on ioctl_wr alone, so the BIST checksums exactly the words that reached the
// controller -- if the two ever disagreed, the check would be meaningless.
wire bist_dl_wr = dl_acc;

// Power-on reset only -- see the note on the module's reset port. An OSD reset
// must not wipe the download checksums, or the SDRAM check could never run
// again and would read FAIL on a healthy board.
wire por_reset = RESET | ~pll_locked;

raiden2_sdram_bist bist
(
    .clk(clk_sys), .reset(por_reset),

    .dl_active(rom_load_busy),
    .dl_wr(bist_dl_wr),
    .dl_addr(dl_acc_addr),
    .dl_data(dl_acc_data),

    .ch3_addr(bist_ch3_addr), .ch3_req(bist_ch3_req),
    .ch3_dout(sdr_cpu_dout[15:0]), .ch3_rdy(sdr_cpu_ack),

    // Raw controller output, NOT the byte-swapped gfx_be: the point is to check
    // the controller's own half-word ordering against the download order.
    .ch1_addr(bist_ch1_addr), .ch1_req(bist_ch1_req),
    .ch1_dout(sdr_gfx_dout), .ch1_rdy(sdr_gfx_ack),

    // The sprite and OKI return paths, raw for the same reason. Their acks are
    // the same edge detects the fetch logic uses; while the BIST owns the bus
    // the core is in reset, so nothing else consumes them.
    .ch2_addr(bist_ch2_addr), .ch2_req(bist_ch2_req),
    .ch2_dout(sdr_spr_dout), .ch2_rdy(sdr_spr_ack),
    .ch4_addr(bist_ch4_addr), .ch4_req(bist_ch4_req),
    .ch4_dout(sdr_oki_dout), .ch4_rdy(sdr_oki_ack),

    .dl_complete(bist_dl_complete),
    .busy(bist_busy), .done(bist_done), .pass(bist_pass),
    .bad_valid(bist_bad_valid), .bad_ch(bist_bad_ch),
    .bad_addr(bist_bad_addr)
);

// ---- CPU program fetch ------------------------------------------------
// raiden2_main stalls whenever rom_ready is low, so a fetch simply drops
// ready until the word arrives. sdr_cpu_addr holds for the whole fetch, which
// the controller needs (see the note on the loader above).
//
// ch3 returns a 4-word burst, but the burst is SEQUENTIAL and wraps inside its
// aligned 4-word group, and sdram.sv puts the first returned word -- the one
// at ch3_addr -- in dout[15:0]. The upper halves are therefore the following
// neighbours, not a selectable window, so the word we asked for is always
// [15:0]. Indexing by cpu_fetch_addr[2:1] returned a neighbouring word for any
// address that was not 8-byte aligned.
//
// ready must also fall in the same cycle a new address appears rather than one
// cycle later, or the CPU can sample the previous fetch's data as if it were
// fresh -- today that is covered by the V30 needing two more CE steps before
// it latches, which is a coincidence, not a handshake.
// ---- 4-word line cache (2026-08-06) ------------------------------------
// sdram.sv fills all 64 bits of ch3_dout (four words, sdram.sv:181-184); this
// used to keep only [15:0] and discard the other three. Instruction fetch is
// overwhelmingly sequential, so the next three words the CPU asks for were
// exactly the three just thrown away, each costing another ~12-cycle round
// trip. Measured in sim/tb_sdmain.cpp, 60 M clk_sys through the real
// controller (`make -C sim sdmain-run`):
//
//                        discard 3      keep all 4
//   SDRAM fetches        2,387,649       1,224,836   -49%
//   CPU stalled on fetch     54.9%           25.0%
//   IRQ handler max     1.56 frames     0.96 frames
//   nested vblanks               1               0   <- matches MAME
//
// That last row is the point. The handler runs its full path with interrupts
// enabled (sti at A1AC9) and relies on the B166 guard to make a nested vblank
// harmless; MAME's reference never nests at all (HANDOFF 7d). At 55% stall the
// fade's handler pass ran 1.56 frames and a vblank landed inside it. Keeping
// the burst puts the worst pass back under one frame.
//
// Coherency: rom_addr is the POST-banking physical address
// (raiden2_addr_decode.sv:71 folds prg_bank into bit 17), so the tag
// distinguishes banks. ch3 is only written during the ROM download, and both
// that and the BIST hold `reset`, which invalidates the line.
//
// The burst is sequential and wraps inside its aligned 4-word group, so the
// word in dout[16k+15:16k] belongs at group offset (fetch_addr[2:1] + k).
// This is the first consumer of the upper 48 bits of ch3_dout; their ordering
// is checked every fetch by the harness's FETCH CHECK (0 mismatches in 1.2 M
// fetches) rather than assumed.
wire [20:0] cpu_rom_addr;   // 21 bits: Raiden DX banks past 1 MB
wire        cpu_rom_req;
wire [15:0] cpu_rom_data;
wire        cpu_rom_ready;
wire        cpu_fetch_pending;
wire        cpu_fetch_done;
wire        sdr_cpu_req_w;

raiden2_cpu_fetch cpu_fetch (
    .clk(clk_sys), .reset(reset),
    .base(SDR_MAINCPU),
    .line_cache_en(1'b1),
    .cpu_addr(cpu_rom_addr), .cpu_req(cpu_rom_req),
    .cpu_data(cpu_rom_data), .cpu_ready(cpu_rom_ready),
    .sdr_addr(sdr_cpu_addr), .sdr_req(sdr_cpu_req_w),
    .sdr_dout(sdr_cpu_dout), .sdr_ack(sdr_cpu_ack),
    .fetch_done(cpu_fetch_done), .fetch_pending(cpu_fetch_pending)
);

// ---- Tile / char fetch for sei0200 ------------------------------------
wire [22:0] gfx_addr;
wire        gfx_is_char, gfx_req;
reg  [31:0] gfx_data;
reg         gfx_valid;
reg         gfx_pending;

assign sdr_gfx_addr = (gfx_is_char ? SDR_CHARS : SDR_TILES) + {2'd0, gfx_addr};

// The ROM image is little-endian 16-bit words, but MAME's gfx bit numbering
// is MSB-first across the 4 bytes of a tile row, so the 32-bit word has to be
// byte-swapped into big-endian before sei0200 indexes it.
// VALIDATED 2026-08-07 (#48 closed, no bug). sdram.sv loads data_ready_delayN
// at the top bit and shifts RIGHT, so bits fire [4],[3],[2],[1] and the FIRST
// burst word lands in the LOW half:
//     if(data_ready_delay1[4]) ch1_dout[15:00] <= dq_reg;   // word 0
//     if(data_ready_delay1[3]) ch1_dout[31:16] <= dq_reg;   // word 1
// ch3 uses the identical pattern over four words and its ordering is proven
// against the ROM by the harness FETCH CHECK (0 mismatches in 1.2 M fetches),
// so ch1 inherits a validated convention: [15:0] is the lower-addressed word.
// With the ROM little-endian, the bytes in address order are dout[7:0],
// [15:8], [23:16], [31:24]; the swap below therefore puts the LOWEST address
// in the most significant position, which is MAME's MSB-first tile-row bit
// numbering. Reordering the halves would INTRODUCE a bug, not fix one.
wire [31:0] gfx_be = { sdr_gfx_dout[7:0],   sdr_gfx_dout[15:8],
                       sdr_gfx_dout[23:16], sdr_gfx_dout[31:24] };

always @(posedge clk_sys) begin
    sdr_gfx_req <= 1'b0;                // one-clock pulse, never a toggle

    if (reset) begin
        gfx_pending <= 1'b0;
        gfx_valid   <= 1'b0;
    end else if (!gfx_pending && !gfx_valid) begin
        if (gfx_req) begin
            sdr_gfx_req <= 1'b1;
            gfx_pending <= 1'b1;
        end
    end else if (gfx_pending && sdr_gfx_ack) begin
        gfx_data    <= gfx_be;
        gfx_valid   <= 1'b1;
        gfx_pending <= 1'b0;
    end else if (gfx_valid && !gfx_req) begin
        gfx_valid <= 1'b0;              // consumer took it
    end
end

///////////////////////   CORE   /////////////////////////////////

wire        ce_pix;
wire [9:0]  hcnt;
wire [8:0]  vcnt;
wire        hsync, vsync, hblank, vblank, line_start;
wire [8:0]  next_line;

// sys_reset, not reset: the raster has to keep running through the ROM download
// and the SDRAM sweep so the self-test page is visible while they happen.
raiden2_video_timing timing
(
    .clk(clk_sys), .reset(sys_reset), .rate_60(rate_60),
    .ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt),
    .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
    .vblank_rise(vblank_rise),
    .line_start(line_start), .next_line(next_line)
);

//--------------------------------------------------------------------------
// Keyboard, and the analog stick, folded into player 1's joystick word
//--------------------------------------------------------------------------
// Layout follows the arcade convention MAME uses, so muscle memory carries
// over: arrows move, Ctrl fires, Alt drops a bomb, 5 inserts a coin, 1 starts.
//
// ps2_key is {toggle, pressed, extended, code[7:0]}; the toggle bit flips on
// every key event, which is what makes a repeated press visible. The arrow
// keys share their codes with the keypad, so the extended bit is deliberately
// ignored -- either one works, exactly as the reference cores do it.
reg key_up = 0, key_down = 0, key_left = 0, key_right = 0;
reg key_ctrl = 0, key_alt = 0, key_1 = 0, key_5 = 0, key_space = 0;

always @(posedge clk_sys) begin
    reg old_state;
    old_state <= ps2_key[10];
    if (old_state != ps2_key[10]) begin
        case (ps2_key[7:0])
            8'h75: key_up    <= ps2_key[9];
            8'h72: key_down  <= ps2_key[9];
            8'h6B: key_left  <= ps2_key[9];
            8'h74: key_right <= ps2_key[9];
            8'h14: key_ctrl  <= ps2_key[9];   // fire
            8'h11: key_alt   <= ps2_key[9];   // bomb
            8'h16: key_1     <= ps2_key[9];   // start 1
            8'h2E: key_5     <= ps2_key[9];   // coin
            8'h29: key_space <= ps2_key[9];   // auto fire (both games; see
                                              // the auto fire block below)
            default: ;
        endcase
    end
end

// Analog stick as a fifth d-pad. The pad reports signed -128..127 per axis;
// a third of full deflection is far enough to be deliberate and close enough
// to be comfortable, and it leaves a wide dead zone so a resting stick never
// creeps. Y is inverted because the pad's positive Y points DOWN.
localparam signed [7:0] ANA_TH = 8'sd48;
wire signed [7:0] ana_x = joystick_l_analog_0[7:0];
wire signed [7:0] ana_y = joystick_l_analog_0[15:8];
wire ana_right = ana_x >  ANA_TH;
wire ana_left  = ana_x < -ANA_TH;
wire ana_down  = ana_y >  ANA_TH;
wire ana_up    = ana_y < -ANA_TH;

// One merged word per player. Everything downstream indexes these instead of
// joystick_0/1 directly, so a new input source only has to be added here.
wire [15:0] j0 = joystick_0[15:0]
               | {4'd0, key_5, key_1, 3'd0, key_space, key_alt, key_ctrl,
                  ana_up | key_up, ana_down | key_down,
                  ana_left | key_left, ana_right | key_right};
wire [15:0] j1 = joystick_1[15:0];

// Raiden II auto fire. THIS IS THE ONE BEHAVIOUR IN THIS CORE THAT THE ARCADE
// BOARD DOES NOT HAVE, and it is deliberate: Raiden DX's program repeats the
// shot itself while BUTTON3 is held, Raiden II's program never reads BUTTON3
// at all, so on Raiden II the button is wired to nothing and pressing it does
// nothing. Synthesising the repeat here gives the two games the same control
// layout. Raiden DX is excluded (~game_dx) because doubling its own repeat up
// with this one would fight the game's timing rather than help it.
//
// The game samples its inputs once per frame, so a frame counter is the only
// rate that means anything; vblank_rise is one pulse per frame. Two frames
// held and two released is 55.4078/4 = 13.85 Hz, the closest a frame-aligned
// divider gets to the ~15 Hz the DX program produces.
//
// The counter is cleared while the button is up, so ~cnt[1] is already true on
// the frame the button goes down and the first shot leaves on that frame
// rather than up to two frames later. One counter per player, so player 2
// pressing does not restart player 1's phase.
reg [1:0] p1_af_cnt = 2'd0, p2_af_cnt = 2'd0;
always @(posedge clk_sys) if (vblank_rise) begin
    p1_af_cnt <= j0[6] ? p1_af_cnt + 1'd1 : 2'd0;
    p2_af_cnt <= j1[6] ? p2_af_cnt + 1'd1 : 2'd0;
end
wire p1_autofire = ~game_dx & j0[6] & ~p1_af_cnt[1];
wire p2_autofire = ~game_dx & j1[6] & ~p2_af_cnt[1];

// Inputs are active low on the board. MiSTer joystick bits are
// 0=right 1=left 2=down 3=up, then the buttons named by the CONF_STR "J1,..."
// list from bit 4 up -- INCLUDING its "-" placeholders, so Fire=4, Bomb=5,
// Start=10, Coin=11, Service=12.
//
// P1_P2 layout is MAME's: P1 in bits 6:0 and P2 in 14:8, with bits 7 and 15
// unused. The gap bits are not optional padding -- leaving them out made the
// concatenation 18 bits wide, and truncating it to 16 shifted every player 2
// input down by two positions while player 1 looked perfectly fine.
// Bits 6 and 14 are BUTTON3, which only Raiden DX has (INPUT_PORTS_START
// raidendx adds PORT_BIT 0x0040 / 0x4000). On export DX sets the game holds
// it as a ~15 Hz auto-shot -- the rate lives in the game code, not here.
// Bit 6 was originally part of a 2'd0 gap, which left player 1's auto-fire
// permanently released while player 2's worked; both are wired now.
// Raiden II never reads them, so wiring them unconditionally is harmless
// and saves a second input path.
wire [15:0] p1p2_in = ~{
    1'd0, j1[6],                                                      // 15:14
    j1[5], j1[4] | p2_autofire,                                       // 13:12
    joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3],       // 11:8
    1'd0, j0[6],                                                      //  7:6
    j0[5], j0[4] | p1_autofire,                                       //  5:4
    j0[0], j0[1], j0[2], j0[3]                                        //  3:0
};

// SYSTEM is START1, START2, unused, SERVICE1 -- it carries no coin inputs.
// Coins reach the game through the sound CPU at 0x4013 (see snd_coin_in), so
// wiring them here put player 2's coin on the SERVICE1 line, which would have
// dropped the board into service mode on a coin press.
// Bit numbers come from the CONF_STR positions above: Fire=4, Bomb=5,
// four unused, Start=10, Coin=11, Service=12. Confirmed against the reference
// core, which documents "10=Start" and "Coin button (joy[11])".
wire [15:0] system_in = ~{
    12'd0,
    j0[12],                             // [3] service (test switch)
    1'b0,                               // [2] unused
    j1[10], j0[10]                      // [1] start 2, [0] start 1
};
// Not inverted: unlike the joysticks above, MRA switch bytes are already in
// the board's active-low form.
wire [15:0] dsw_in = {dsw_bytes[1], dsw_bytes[0]};

// DSW bit 15 is the board's TEST MODE switch, SW2:8 -- MAME raiden2:
//   PORT_SERVICE( 0x8000, IP_ACTIVE_LOW ) PORT_DIPLOCATION("SW2:!8")
// and raidendx inherits it through PORT_INCLUDE. It reaches the game as an
// ordinary DSW bit, so both MRAs simply expose it and nothing here has to
// decode it.
//
// It used to be squatted on by a headless auto coin/start injector, added to
// investigate #66 on the strength of "bit 15 is undefined in the MRA and
// passes through". That was true of the MRA at the time and never true of the
// hardware, so arming test mode would also have shoved a coin in 30 s later.
// The injector is removed rather than moved: #66 no longer reproduces (a board
// with 8 coins registered reports SPRITE FETCH CH2 PASS, 2026-08-10), and it
// is in git history if it is ever wanted again.
wire [15:0] system_gated = system_in;


wire [12:0] map_addr;
wire [15:0] map_data;
wire [10:0] cram_addr;
wire [15:0] cram_data;
wire [10:0] cram2_addr;
wire [15:0] cram2_data;
wire [10:0] sprram_addr;
wire [15:0] sprram_data;

// CPU register window, routed to the blocks that answer it.
wire [19:0] reg_addr;
wire [15:0] reg_dout;
wire  [1:0] reg_be;
wire        reg_we, reg_rd;
// Two blocks answer reads in the register window now: the video registers and
// the Seibu mailbox at 0x700-0x71F. They never overlap, so a simple mux is
// enough -- but reg_din_oe must be the OR, or an unclaimed read would return 0
// and the game would see a mailbox that never replies.
wire [15:0] vr_reg_din;
wire        vr_reg_din_oe;
wire  [7:0] snd_main_dout;
wire        snd_din_oe = sound_cs & reg_rd;
wire [15:0] reg_din    = snd_din_oe ? {8'd0, snd_main_dout} : vr_reg_din;
wire        reg_din_oe = vr_reg_din_oe | snd_din_oe;

wire cop_cs, copbank_cs, crtc_cs, sprite_cs, sprbuf_cs;
wire sprprot_cs, tilebank_cs, copsort_cs, sound_cs, sprprot_rd_cs;

// Self-test taps off the CPU subsystem.
wire [19:0] dbg_addr;
wire        dbg_mem_rd, dbg_intack, dbg_dma_unknown, dbg_cmd_unknown;
// COP 0x7e05 (Raiden DX) writes the tile bank register itself.
wire        cop_bank_we;
wire  [7:0] cop_bank_data;
wire        dbg_mem_wr;
wire [15:0] dbg_data;
wire        dbg_wram_we, dbg_wram_cop;
wire [15:0] dbg_wram_addr, dbg_wram_wdata;

// Watchpoint on 0x9EC4, the per-frame counter the game's timer routine bumps
// (`incw (%bx)` at 0x9814D). Hardware shows 0x9EC6 -- the seconds counter it
// rolls into -- is NEVER written, while MAME writes it every 60 frames. This
// says whether the routine runs at all, since 0x9EC4 is hit on every call.
// Watchpoint on 0x9F62, on the work-RAM WRITE PORT rather than the CPU bus:
// the COP DMA writes work RAM through its own channel, and a CPU-bus watch is
// blind to it. MAME never writes this flag at all through a full coin+start,
// so the first write caught here IS the anomaly. H's top hex digit carries the
// source: 0 = CPU (watch_pc names the instruction), 8 = COP DMA.
localparam [15:0] WATCH_WORD = 16'h4FB1;   // 0x9F62 >> 1
reg [19:0] watch_pc;
reg [15:0] watch_val;
reg  [3:0] watch_cnt;
reg        watch_src;
wire       watch_hit = dbg_wram_we && (dbg_wram_addr == WATCH_WORD);
always @(posedge clk_sys) begin
    if (watch_hit) begin
        watch_pc  <= dbg_wram_cop ? 20'hCCCCC : dbg_pc;
        watch_val <= dbg_wram_wdata;
        watch_src <= dbg_wram_cop;
        watch_cnt <= watch_cnt + 4'd1;
    end
end

wire [19:0] dbg_pc;
wire        dbg_dma_busy;
wire  [8:0] dbg_unknown_mode;
wire        dbg_unknown_valid;

// 32 MHz tick; raiden2_main's two-phase CE halves it to the V30's 16 MHz.
// ---- Pause (debug aid) ------------------------------------------------
// Freezes the GAME by withholding the CPU clock enable while leaving video
// scanning out, so the offending frame stays on screen and its state can be
// read off the UART at leisure instead of racing a live capture. Sound keeps
// running deliberately -- silence would be a second variable.
// Button index 9 in the J1 list above => joystick bit 13 (Fire=4 ... Pause=13).
wire pause_btn = j0[13] | j1[13];
reg  pause_btn_d, paused;
always @(posedge clk_sys) begin
    if (reset) begin
        paused      <= 1'b0;
        pause_btn_d <= 1'b0;
    end else begin
        pause_btn_d <= pause_btn;
        if (pause_btn && !pause_btn_d) paused <= ~paused;   // toggle on press
    end
end

reg cpu_ce_raw;
always @(posedge clk_sys) cpu_ce_raw <= reset ? 1'b0 : ~cpu_ce_raw;
wire cpu_ce = cpu_ce_raw & ~paused;

raiden2_main cpu
(
    .game_dx        (game_dx),
    .dx_prg_bank    (dx_prg_bank),
    .clk(clk_sys), .reset(reset), .cpu_ce(cpu_ce),
    .vblank(vblank_rise),

    .rom_addr(cpu_rom_addr), .rom_req(cpu_rom_req),
    .rom_data(cpu_rom_data), .rom_ready(cpu_rom_ready),

    .dsw(dsw_in), .p1p2(p1p2_in), .system(system_gated),

    .reg_addr(reg_addr), .reg_dout(reg_dout), .reg_be(reg_be),
    .reg_we(reg_we), .reg_rd(reg_rd),
    .reg_din(reg_din), .reg_din_oe(reg_din_oe),

    .cop_cs(cop_cs), .copbank_cs(copbank_cs), .crtc_cs(crtc_cs),
    .sprite_cs(sprite_cs), .sprbuf_cs(sprbuf_cs), .sprprot_cs(sprprot_cs),
    .tilebank_cs(tilebank_cs), .copsort_cs(copsort_cs),
    .sound_cs(sound_cs), .sprprot_rd_cs(sprprot_rd_cs),

    // Taps feed the self-test checks; they were previously left open.
    .dbg_wram_we(dbg_wram_we), .dbg_wram_addr(dbg_wram_addr),
    .dbg_wram_wdata(dbg_wram_wdata), .dbg_wram_cop(dbg_wram_cop),
    .dbg_addr(dbg_addr), .dbg_pc(dbg_pc), .dbg_es(dbg_es), .dbg_data(dbg_data), .dbg_mem_rd(dbg_mem_rd), .dbg_mem_wr(dbg_mem_wr),
    .dbg_intack(dbg_intack), .dbg_dma_busy(dbg_dma_busy), .dbg_dma_unknown(dbg_dma_unknown),
    .dbg_stall_src(dbg_stall_src),
    .dbg_cmd_unknown(dbg_cmd_unknown),
    .cop_bank_we(cop_bank_we), .cop_bank_data(cop_bank_data),
    .dbg_unknown_mode(dbg_unknown_mode), .dbg_unknown_valid(dbg_unknown_valid),

    .vram_rd_addr(map_addr), .vram_rd_data(map_data),
    .cram_rd_addr(cram_addr), .cram_rd_data(cram_data),
    .cram_rd2_addr(cram2_addr), .cram_rd2_data(cram2_data),
    .sprram_rd_addr(sprram_addr), .sprram_rd_data(sprram_data),
    .dbg_cmd_any(dbg_cmd_any), .dbg_cmd_0205(dbg_cmd_0205)
);

// sprram_addr is driven by the sei252 instance further down.

wire        fill_bank;
wire [11:0] lb_bg, lb_mid, lb_fg, lb_txt;

// CRTC scroll / layer enable / tile banks, captured off the register window.
wire [15:0] bg_scroll_x, bg_scroll_y;
wire [15:0] mid_scroll_x, mid_scroll_y;
wire [15:0] fg_scroll_x, fg_scroll_y;
wire  [2:0] bg_bank, mid_bank, fg_bank, tx_bank;
wire  [4:0] layer_enable;

raiden2_video_regs video_regs
(
    .game_dx       (game_dx),
    .dx_prg_bank   (dx_prg_bank),
    .clk(clk_sys), .reset(reset),

    .reg_addr(reg_addr), .reg_dout(reg_dout), .reg_be(reg_be),
    .reg_we(reg_we), .reg_rd(reg_rd),
    .crtc_cs(crtc_cs), .tilebank_cs(tilebank_cs), .copbank_cs(copbank_cs),
    .cop_bank_we(cop_bank_we), .cop_bank_data(cop_bank_data),
    .reg_din(vr_reg_din), .reg_din_oe(vr_reg_din_oe),

    .bg_scroll_x(bg_scroll_x),   .bg_scroll_y(bg_scroll_y),
    .mid_scroll_x(mid_scroll_x), .mid_scroll_y(mid_scroll_y),
    .fg_scroll_x(fg_scroll_x),   .fg_scroll_y(fg_scroll_y),
    .bg_bank(bg_bank), .mid_bank(mid_bank), .fg_bank(fg_bank), .tx_bank(tx_bank),
    .layer_enable(layer_enable)
);

// ---- Per-frame scroll latch -------------------------------------------
// sei0200 samples the scroll registers WHILE it renders, so a CPU write that
// lands mid-frame moves the tilemaps part-way down the screen: the top of the
// picture is drawn with the old value and the bottom with the new one. The
// game writes scroll from its vblank handler, and that handler's duration
// varies a lot here (FFF4 ranges from 0x36 to 0x3A8, and historically past a
// whole frame -- see #40/#45), so the write lands at a different raster
// position every frame. On screen that is a background that WOBBLES while the
// sprites, which are drawn from a list rather than sampled against a live
// register, stay rock steady.
//
// MAME draws each frame with a single scroll value, and so should we. Latch
// once at the top of active display, so a frame is always internally
// consistent regardless of when the CPU got round to writing.
// sei0200 fills line N+1 while line N is displayed, so the fill for display
// line 0 is queued at the START of the last vblank line (line_start with
// next_line wrapping to 0). Latching there gives the vblank handler almost the
// whole blanking period to write, and the values apply from line 0 of the very
// next frame -- no added lag. Derived from line_start/next_line rather than a
// vcnt literal so it cannot drift out of step with V_TOTAL.
wire frame_start = line_start && (next_line == 9'd0);

reg [15:0] bg_sx_l, bg_sy_l, mid_sx_l, mid_sy_l, fg_sx_l, fg_sy_l;
always @(posedge clk_sys) begin
    if (reset) begin
        bg_sx_l  <= 16'd0; bg_sy_l  <= 16'd0;
        mid_sx_l <= 16'd0; mid_sy_l <= 16'd0;
        fg_sx_l  <= 16'd0; fg_sy_l  <= 16'd0;
    end else if (frame_start) begin
        bg_sx_l  <= bg_scroll_x;  bg_sy_l  <= bg_scroll_y;
        mid_sx_l <= mid_scroll_x; mid_sy_l <= mid_scroll_y;
        fg_sx_l  <= fg_scroll_x;  fg_sy_l  <= fg_scroll_y;
    end
end

// sei0200 only accepts `start` in its IDLE state, so if a line's fill has not
// finished when the next line_start arrives, THAT LINE'S FILL IS SILENTLY
// DROPPED and the line buffer keeps the previous line's pixels -- including
// its horizontal offset. On screen that is a background that wobbles side to
// side while sprites stay perfect, because sprites are ch2 (the HIGHEST
// priority SDRAM channel) and tiles are ch1, so tiles are what loses the race.
// Counted here rather than assumed; streams as FFE4.
// PER-FRAME, not cumulative. The first cut was a saturating total and it
// pinned at FFFF within seconds, which cannot tell "improved a lot" from
// "no change" -- the probe's dynamic range WAS the limitation, not the data.
// A per-frame count is 0..282 and directly comparable between builds.
reg [15:0] tm_drop_acc;
always @(posedge clk_sys) begin
    if (reset) begin
        tm_drop_acc <= 16'd0;
        tm_drop_cnt <= 16'd0;
    end else begin
        if (frame_start) begin
            tm_drop_cnt <= tm_drop_acc;      // publish last frame's count
            tm_drop_acc <= 16'd0;
        end else if (line_start && tm_busy && !(&tm_drop_acc)) begin
            tm_drop_acc <= tm_drop_acc + 16'd1;
        end
    end
end

reg [15:0] cop_any_acc, cop_0205_acc;
always @(posedge clk_sys) begin
    if (reset) begin
        cop_any_acc <= 16'd0; cop_any_cnt <= 16'd0;
        cop_0205_acc <= 16'd0; cop_0205_cnt <= 16'd0;
    end else if (frame_start) begin
        cop_any_cnt  <= cop_any_acc;   cop_any_acc  <= 16'd0;
        cop_0205_cnt <= cop_0205_acc;  cop_0205_acc <= 16'd0;
    end else begin
        if (dbg_cmd_any  && !(&cop_any_acc))  cop_any_acc  <= cop_any_acc  + 16'd1;
        if (dbg_cmd_0205 && !(&cop_0205_acc)) cop_0205_acc <= cop_0205_acc + 16'd1;
    end
end

reg [15:0] spr_drop_acc, spr_fill_run;
reg        spr_busy_d;
always @(posedge clk_sys) begin
    if (reset) begin
        spr_drop_acc <= 16'd0; spr_drop_cnt <= 16'd0;
        spr_fill_run <= 16'd0; spr_fill_max <= 16'd0; spr_busy_d <= 1'b0;
    end else begin
        if (frame_start) begin
            spr_drop_cnt <= spr_drop_acc;
            spr_drop_acc <= 16'd0;
        end else if (line_start && spr_busy && !(&spr_drop_acc)) begin
            spr_drop_acc <= spr_drop_acc + 16'd1;
        end
        // Restart the run at every line_start, not only on the busy edge.
        // sei252 now truncates an over-budget line and goes straight back to
        // S_CLR without passing through S_IDLE, so `busy` can stay high across
        // several lines -- and this counter then reported their SUM as one
        // fill. A startup capture read 40,522 that way, which is not a fill
        // time at all. Per-line is what the 4,096 budget is measured against.
        spr_busy_d <= spr_busy;
        if (line_start)                    spr_fill_run <= spr_busy ? 16'd1 : 16'd0;
        else if (spr_busy)                 spr_fill_run <= spr_fill_run + 16'd1;
        if (!spr_busy && spr_busy_d)
            if (spr_fill_run > spr_fill_max) spr_fill_max <= spr_fill_run;
    end
end

// How long does a line fill ACTUALLY take on hardware? The sim says 3810
// clocks at a modelled latency of 12 against a 4096 budget, but the drops
// persist, so the real ch1 latency under sprite/CPU contention must be higher.
// Measure it instead of inferring it: worst-case fill duration, in clk_sys.
reg [15:0] tm_fill_run;
reg        tm_busy_d;
always @(posedge clk_sys) begin
    if (reset) begin
        tm_fill_run <= 16'd0; tm_fill_max <= 16'd0; tm_busy_d <= 1'b0;
    end else begin
        // Same per-line restart as the sprite counter above, and for the same
        // reason: a run measured across line boundaries is not a fill time.
        tm_busy_d <= tm_busy;
        if (line_start)                 tm_fill_run <= tm_busy ? 16'd1 : 16'd0;
        else if (tm_busy)               tm_fill_run <= tm_fill_run + 16'd1;
        if (!tm_busy && tm_busy_d) begin                        // fill ended
            if (tm_fill_run > tm_fill_max) tm_fill_max <= tm_fill_run;
        end
    end
end

// ---- In-core 180-degree flip (the Flip Screen dip) --------------------
// The real board's video chips flip the raster themselves when the dip is
// on; doing it at the framework's screen_rotate instead (the first attempt,
// from PR #3) only flips the DDR3 framebuffer the SCALER displays -- HDMI
// flipped, direct analog VGA did not, and a rotated-CRT cab is exactly who
// needs this dip. Flipping here -- source line mirrored into the line fills,
// X mirrored at the line-buffer readout -- flips the core's own raster, so
// every output follows, analog included, with no framebuffer involved.
//
// The dip is active low (FF default = Off). Gated off for the raster-order
// self-test pages, which are diagnostics, not game video; "Sprites only"
// (show_spronly) is game video and flips with the rest.
wire       flip_active = ~dsw_bytes[0][7] & ~selftest_show;
// Only visible lines mirror; vblank-row fills stay where they were.
wire [8:0] fill_line   = (flip_active && next_line < 9'd240)
                       ? (9'd239 - next_line) : next_line;
// Garbage reads while hcnt is in blanking are masked downstream, exactly as
// the unflipped readout's were.
wire [8:0] lb_x        = flip_active ? (9'd319 - hcnt[8:0]) : hcnt[8:0];

sei0200 tilemaps
(
    .clk(clk_sys), .reset(reset),
    .line(fill_line), .start(line_start), .busy(tm_busy),

    .bg_scroll_x(bg_sx_l),   .bg_scroll_y(bg_sy_l),
    .mid_scroll_x(mid_sx_l), .mid_scroll_y(mid_sy_l),
    .fg_scroll_x(fg_sx_l),   .fg_scroll_y(fg_sy_l),
    .bg_bank(bg_bank), .mid_bank(mid_bank), .fg_bank(fg_bank), .tx_bank(tx_bank),
    .layer_enable(layer_enable),

    .map_addr(map_addr), .map_data(map_data),

    .rom_addr(gfx_addr), .rom_is_char(gfx_is_char), .rom_req(gfx_req),
    .rom_data(gfx_data), .rom_valid(gfx_valid),

    .fill_bank(fill_bank), .lb_rd_bank(~fill_bank), .lb_rd_x(lb_x),
    .lb_bg(lb_bg), .lb_mid(lb_mid), .lb_fg(lb_fg), .lb_txt(lb_txt)
);

// SEI360 mixer. Diffed against tools/mix_model.py by sim/tb_sei360.cpp.
// In "sprites only" mode the tilemaps are forced transparent so the sprite
// path can be judged on its own.
wire [11:0] mx_bg  = show_spronly ? 12'd0 : lb_bg;
wire [11:0] mx_mid = show_spronly ? 12'd0 : lb_mid;
wire [11:0] mx_fg  = show_spronly ? 12'd0 : lb_fg;
wire [11:0] mx_txt = show_spronly ? 12'd0 : lb_txt;

wire        mix_opaque;
wire [10:0] mix_top, mix_under;
wire        mix_blend;

raiden2_sei360 mixer
(
    .lb_bg(mx_bg), .lb_mid(mx_mid), .lb_fg(mx_fg), .lb_txt(mx_txt),
    .lb_spr(st_lb),
    .opaque(mix_opaque), .top_idx(mix_top),
    .blend(mix_blend), .under_idx(mix_under)
);

wire [10:0] px = mix_opaque ? mix_top : 11'd0;
// ---- CRAM (palette) checksum scanner --------------------------------
// The photos of the glitch show the tile ARTWORK intact but the COLOURS wrong,
// with sprites unaffected -- i.e. the tilemap palette is being corrupted, not
// the tiles. Nothing in the core could see that: CRAM FILLED latches on the
// first write and says nothing about the contents being right.
//
// During vblank the mixer's output is not displayed, so its CRAM read port is
// free. Borrow it to walk all 2048 entries and fold them into a rotating XOR.
// Freeze on a good frame, freeze on a bad one, compare FFEE: if the palette is
// being corrupted the two differ, and it stops being a matter of opinion.
reg [10:0] cram_scan;
reg [15:0] cram_hash;
reg        cram_scanning;
always @(posedge clk_sys) begin
    if (reset) begin
        cram_scan <= 11'd0; cram_hash <= 16'd0;
        cram_hash_pub <= 16'd0; cram_scanning <= 1'b0;
    end else if (vblank_rise) begin
        cram_scan <= 11'd0; cram_hash <= 16'd0; cram_scanning <= 1'b1;
    end else if (cram_scanning && ce_pix) begin
        // Read latency is absorbed by the fact that we only need a REPEATABLE
        // hash, not one aligned to a particular address.
        cram_hash <= {cram_hash[14:0], cram_hash[15]} ^ cram_data;
        cram_scan <= cram_scan + 11'd1;
        if (&cram_scan) begin
            cram_scanning <= 1'b0;
            cram_hash_pub <= {cram_hash[14:0], cram_hash[15]} ^ cram_data;
        end
    end
end

assign cram_addr  = cram_scanning ? cram_scan : mix_top;
assign cram2_addr = mix_under;

// CRAM is xBGR-555.
wire [4:0] tr5 = cram_data[4:0],  tg5 = cram_data[9:5],  tb5 = cram_data[14:10];
wire [4:0] ur5 = cram2_data[4:0], ug5 = cram2_data[9:5], ub5 = cram2_data[14:10];
wire [7:0] t_r = {tr5, tr5[4:2]}, t_g = {tg5, tg5[4:2]}, t_b = {tb5, tb5[4:2]};
wire [7:0] u_r = {ur5, ur5[4:2]}, u_g = {ug5, ug5[4:2]}, u_b = {ub5, ub5[4:2]};

// MAME uses alpha_blend_r32(dst, src, 0x7f) for the blended entries, i.e. an
// even mix of the pixel and whatever is behind it.
//
// The sums are declared 9 bits wide ON PURPOSE. Written inline as
//     {(t_r + u_r) >> 1, (t_g + u_g) >> 1, (t_b + u_b) >> 1}
// each addition sits inside a concatenation, where its width is
// SELF-DETERMINED -- 8 bits, the width of its operands -- so the carry is
// discarded before the shift. Any channel pair summing over 255 wrapped to
// near zero: the attract-intro engine flames, RGB(165,198,148) over the
// brown rock RGB(123,107,82), should blend to RGB(144,152,115) but came out
// RGB(16,24,115), because red and green overflowed and blue did not. That is
// the "green/white flames render purple and blue" bug (#78).
//
// sei360 was NOT at fault and its 100,000-vector oracle pass was not wrong:
// the mixer only emits indices and the blend flag, and this arithmetic lives
// here in the top level where nothing tested it.
wire [8:0] blend_r = {1'b0, t_r} + {1'b0, u_r};
wire [8:0] blend_g = {1'b0, t_g} + {1'b0, u_g};
wire [8:0] blend_b = {1'b0, t_b} + {1'b0, u_b};

wire [23:0] rgb_top   = {t_r, t_g, t_b};
wire [23:0] rgb_blend = {blend_r[8:1], blend_g[8:1], blend_b[8:1]};
wire [23:0] rgb = ~mix_opaque ? 24'd0
                : mix_blend   ? rgb_blend
                              : rgb_top;

///////////////////////     SOUND     ////////////////////////////
//
// The Z80 program ROM lives in block RAM rather than SDRAM: it is only 128 KB
// and the CPU needs it with no wait states, which would otherwise mean a
// fourth SDRAM client competing with video for bandwidth every few cycles.
// It is filled from the same download stream, tapped at the point where words
// are accepted, so it sees exactly what SDRAM sees.
wire [24:0] SDR_AUDIO = game_dx ? 25'h200000 : 25'h100000;   // 128 KB

wire [24:0] snd_dl_off  = dl_acc_addr - SDR_AUDIO;
wire        snd_rom_wr  = dl_acc && (dl_acc_addr >= SDR_AUDIO)
                                 && (dl_acc_addr < SDR_AUDIO + 25'h20000);
wire [15:0] snd_rom_ofs = snd_dl_off[16:1];

// coin_r at 0x4013: bit 0 COIN1, bit 1 COIN2, active low, everything else
// idle high (SEIBU_COIN_INPUTS_INVERT).
// Coin is joystick bit 11 (see the CONF_STR note above), not bit 7.
wire  [7:0] snd_coin_in = ~{6'd0, j1[11], j0[11]};

// Credit counter, streamed over the UART. Without this a "did the coin work"
// capture is guesswork: 0x9F?? credits live in work RAM, but the simplest
// unambiguous signal is the START1 line actually being consumed, so count
// coin pulses seen by the sound CPU.
reg [15:0] coin_seen; reg coin_d;
always @(posedge clk_sys) begin
    if (reset) begin coin_seen <= 16'd0; coin_d <= 1'b0; end
    else begin
        coin_d <= ~snd_coin_in[0];
        if (~snd_coin_in[0] && !coin_d && !(&coin_seen)) coin_seen <= coin_seen + 16'd1;
    end
end

wire snd_z80_running, snd_ym_write;

raiden2_sound sound
(
    .clk(clk_sys), .reset(reset),

    // The mailbox window is 0x700-0x71F, but its registers are FOUR bytes
    // apart, not two. MAME's map hands the lambda a word index and the lambda
    // shifts it again -- so main_r/main_w see offsets 0..7 across 32 bytes.
    // Using the word index directly put every register but 0 in the wrong
    // place; worst of all the main2sub_pending flag at register 5 read back as
    // 0xFF, so the game polled it forever and hung.
    .main_ofs({1'b0, reg_addr[4:2]}), .main_din(reg_dout[7:0]),
    .main_we(sound_cs & reg_we), .main_rd(sound_cs & reg_rd),
    .main_dout(snd_main_dout),

    .coin_in(snd_coin_in),

    .rom_wr(snd_rom_wr), .rom_wr_addr(snd_rom_ofs), .rom_wr_data(dl_acc_data),

    .OKI1_BASE(SDR_OKI1), .OKI2_BASE(SDR_OKI2),
    .oki_addr(sdr_oki_addr), .oki_req(sdr_oki_req),
    .oki_dout(sdr_oki_dout), .oki_ack(sdr_oki_ack),

    .audio_out(snd_audio),
    .dbg_z80_running(snd_z80_running), .dbg_ym_write(snd_ym_write),
    .dbg_oki_write(snd_oki_write), .dbg_intack(snd_z80_intack),
    .dbg_latch_rd(snd_latch_rd),   .dbg_bank_exec(snd_bank_exec),
    .dbg_z80_pc(snd_z80_pc), .dbg_rst18_ack(snd_rst18_ack),
    .dbg_pending_rd(snd_pending_rd)
);

///////////////////////   SELF TEST   ////////////////////////////
//
// Observation only -- nothing below can change how the core behaves. It exists
// because the SDRAM controller, the ROM loader and both fetch handshakes have
// no simulation coverage at all, so this is the only place their behaviour has
// ever been checked.

wire [43:0] chk_state;

raiden2_diag diag
(
    .clk(clk_sys), .reset(sys_reset), .core_reset(reset),

    .pll_locked(pll_locked),
    .dl_active(rom_load_busy),
    .dl_done(bist_dl_complete),
    .bist_busy(bist_busy), .bist_done(bist_done), .bist_pass(bist_pass),

    .cpu_fetch_done(cpu_fetch_done),
    .dbg_addr(dbg_addr), .dbg_mem_rd(dbg_mem_rd), .dbg_intack(dbg_intack),

    .reg_addr(reg_addr), .reg_dout(reg_dout), .reg_we(reg_we),
    .dma_unknown(dbg_dma_unknown),

    .cram_data(cram_data), .map_data(map_data),

    .gfx_valid(gfx_valid), .sprbuf_cs(sprbuf_cs),
    .px(px), .video_active(~hblank & ~vblank),

    .vblank_rise(vblank_rise),
    .crypt_done(spr_crc_done), .crypt_pass(spr_crc_pass),
    .spr_rom_ack(sdr_spr_ack), .spr_pixel(st_lb[12] & ~hblank & ~vblank),
    .z80_running(snd_z80_running), .ym_write(snd_ym_write),
    .cmd_unknown(dbg_cmd_unknown),
    .oki_ack(sdr_oki_ack), .audio_nz(|snd_audio),

    .chk_state(chk_state)
);

wire [23:0] selftest_rgb;

// Free-running counters for the trace. irq_cnt counts interrupt acknowledges,
// frame_cnt counts vblanks; the two together show whether the handler keeps up
// with the raster. cop_cmd_seen latches any COP command trigger in the frame,
// so a state machine waiting on the COP can be told from one that never asks.
reg [3:0] irq_cnt, frame_cnt;
reg       cop_cmd_seen;
reg       intack_d;
always @(posedge clk_sys) begin
    intack_d <= dbg_intack;
    if (dbg_intack & ~intack_d) irq_cnt <= irq_cnt + 4'd1;
    if (vblank_rise) begin
        frame_cnt    <= frame_cnt + 4'd1;
        cop_cmd_seen <= 1'b0;
    end else if (reg_we && (reg_addr[10:0] == 11'h500)) begin
        cop_cmd_seen <= 1'b1;
    end
end

// Bracket of every PC executed during the frame. One sample per frame cannot
// distinguish a two-instruction spin from a routine the CPU merely spends most
// of its time in -- both land on the same address. The span can.
reg [19:0] pc_lo, pc_hi, pc_lo_q, pc_hi_q;
always @(posedge clk_sys) begin
    if (vblank_rise) begin
        pc_lo_q <= pc_lo;   pc_hi_q <= pc_hi;
        pc_lo   <= dbg_pc;  pc_hi   <= dbg_pc;
    end else begin
        if (dbg_pc < pc_lo) pc_lo <= dbg_pc;
        if (dbg_pc > pc_hi) pc_hi <= dbg_pc;
    end
end

// Main CPU fetch address, sampled once a frame. Sampling every clock would
// make it unreadable; a frozen CPU shows a stable value either way.
// The instruction pointer, not the data address. A data address only says
// which variable is being polled; the IP says which code is doing the polling,
// which can be found in the ROM.
reg [19:0] cpu_pc_latched;
always @(posedge clk_sys) if (vblank_rise) cpu_pc_latched <= dbg_pc;

// Up/down scrolls the check page. Edge-detected off the raw joystick so it
// steps once per press rather than racing at the frame rate, and clamped so it
// cannot run past the end of the page.
localparam [5:0] SCROLL_MAX = 6'd12;
reg  [5:0] page_scroll;
reg        scr_up_d, scr_dn_d;
wire       scr_up = j0[3] | j1[3];
wire       scr_dn = j0[2] | j1[2];
always @(posedge clk_sys) begin
    scr_up_d <= scr_up;
    scr_dn_d <= scr_dn;
    if (~selftest_show) begin
        page_scroll <= 6'd0;          // reset when leaving the page
    end else begin
        if (scr_dn & ~scr_dn_d & (page_scroll != SCROLL_MAX))
            page_scroll <= page_scroll + 6'd1;
        if (scr_up & ~scr_up_d & (page_scroll != 6'd0))
            page_scroll <= page_scroll - 6'd1;
    end
end

raiden2_selftest selftest
(
    .clk(clk_sys), .ce_pix(ce_pix),
    .hcnt(hcnt), .vcnt(vcnt), .next_line(next_line),
    .chk_state(chk_state),
    .scroll(page_scroll),
    .bad_valid(bist_bad_valid), .bad_ch(bist_bad_ch),
    .bad_addr(bist_bad_addr),
    .game_dx(game_dx),
    .mode_valid(dbg_unknown_valid), .bad_mode({3'd0, dbg_unknown_mode}),
    .build_stamp(`BUILD_STAMP),
    .cpu_addr(cpu_pc_latched),
    .rgb(selftest_rgb)
);

///////////////////////  SPRITE TEST  ////////////////////////////
//
// sei252 driven by a synthetic list and tile set, NOT by the game. The real
// sprite ROMs arrive from the MRA encrypted (r2crypt is not in the loader),
// and the COP only builds a list once the game reaches attract mode -- so a
// test that depended on either would prove nothing about the renderer.
//
// This proves the renderer, the line buffer and the display path on hardware,
// standalone. What it does NOT cover is the SDRAM sprite fetch path (ch2 is
// still unused) or decryption.

wire [10:0] st_spr_addr;  wire [15:0] st_spr_data;
wire [22:0] st_rom_addr;  wire [63:0] st_rom_data;
wire        st_rom_req;
wire        st_fill_bank;
wire [12:0] st_lb;

raiden2_sprite_test_rom sprite_test_rom
(
    .clk(clk_sys),
    .spr_addr(st_spr_addr), .spr_data(st_spr_data),
    .rom_addr(st_rom_addr), .rom_data(st_rom_data)
);

// The test ROM answers in one clock, so valid is the request delayed.
reg st_rom_valid;
always @(posedge clk_sys) st_rom_valid <= st_rom_req;

// ---- sprite ROM fetch over ch2 ----------------------------------------
// sei252 asks with a level, not a pulse, and waits for rom_valid, so this only
// has to turn one outstanding request at a time into a single-cycle ch2 req.
// The sprite region base has to be ADDED, not OR-ed: 0x600000 is not aligned
// to the 8 MB the region spans, so bit 23 of the offset would collide with it.
// The address is REGISTERED rather than fed through combinationally. Driving
// it straight from sei252 put the whole chain -- sprite entry register, tile
// address arithmetic, this 25-bit base adder -- onto the SDRAM address pins in
// a single clk_sys -> clk_ram hop, and it missed setup by 0.268 ns. Latching it
// alongside the request leaves only a register output crossing the boundary.
reg [24:0] sdr_spr_addr_r;
assign sdr_spr_addr = sdr_spr_addr_r;

reg sdr_spr_busy;
always @(posedge clk_sys) begin
    sdr_spr_req <= 1'b0;
    if (sys_reset) begin
        sdr_spr_busy <= 1'b0;
    end else if (!sdr_spr_busy) begin
        // ~bist_busy: sei252 keeps rastering through the SDRAM sweep (it only
        // resets on sys_reset, so the self-test backdrop stays alive), and on a
        // warm reload its latched sprite RAM still holds the previous game's
        // list -- without this gate those stale fetches would interleave with
        // the BIST's own ch2 reads and corrupt the sweep. A gated-off fill
        // shows one stale sprite line while the core is in reset anyway.
        if (st_rom_req & ~show_sprtest & ~bist_busy) begin
            sdr_spr_addr_r <= SDR_SPRITES + {2'd0, st_rom_addr};
            sdr_spr_req    <= 1'b1;
            sdr_spr_busy   <= 1'b1;
        end
    end else if (sdr_spr_ack) begin
        sdr_spr_busy <= 1'b0;
    end
end
wire sdr_spr_valid = sdr_spr_ack;

// A single renderer, with its two source buses muxed. Sharing the instance
// means the on-screen sprite test exercises the very same logic that draws the
// game, rather than a copy that could drift away from it.
assign sprram_addr = st_spr_addr;

wire [15:0] spr_src_data = show_sprtest ? st_spr_data : sprram_data;
wire [63:0] rom_src_data = show_sprtest ? st_rom_data : sdr_spr_dout;
wire        rom_src_valid = show_sprtest ? st_rom_valid : sdr_spr_valid;

sei252 sprites
(
    .clk(clk_sys), .reset(sys_reset),
    // fill_line / lb_x: the in-core flip (see the tilemap instance above).
    // In sprite-test mode flip_active is forced off, so the test page is
    // bit-identical whatever the dip says.
    .line(fill_line), .start(line_start), .busy(spr_busy),
    .spr_addr(st_spr_addr), .spr_data(spr_src_data),
    .rom_addr(st_rom_addr), .rom_req(st_rom_req),
    .rom_data(rom_src_data), .rom_valid(rom_src_valid),
    .fill_bank(st_fill_bank), .lb_rd_bank(~st_fill_bank),
    .lb_rd_x(lb_x), .lb_out(st_lb)
);

// Fixed palette so the test does not depend on CRAM having been filled.
reg [23:0] sprtest_rgb;
always @(*) begin
    case (st_lb[3:0])
        4'h1: sprtest_rgb = 24'hFF5050;  4'h2: sprtest_rgb = 24'h50FF50;
        4'h3: sprtest_rgb = 24'h50A0FF;  4'h4: sprtest_rgb = 24'hFFFF50;
        4'h5: sprtest_rgb = 24'hFF50FF;  4'h6: sprtest_rgb = 24'h50FFFF;
        4'h7: sprtest_rgb = 24'hFFA03C;  4'h8: sprtest_rgb = 24'hA050FF;
        4'h9: sprtest_rgb = 24'h3CDCA0;  4'hA: sprtest_rgb = 24'hDCDCDC;
        4'hB: sprtest_rgb = 24'hFF78B4;  4'hC: sprtest_rgb = 24'h7878FF;
        4'hD: sprtest_rgb = 24'hB4FF78;  4'hE: sprtest_rgb = 24'hC8C83C;
        default: sprtest_rgb = 24'h000000;
    endcase
end

wire [23:0] sprtest_out = st_lb[12] ? sprtest_rgb : 24'h191923;

wire [23:0] out_rgb = show_checks  ? selftest_rgb
                    : show_sprtest ? sprtest_out
                                   : rgb;

///////////////////////   VIDEO OUT   ////////////////////////////

wire [7:0] r8, g8, b8;
wire       vga_de, vga_hs, vga_vs;
wire [1:0] vga_sl;

arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
    .clk_video(clk_sys),
    .ce_pix(ce_pix),
    .RGB_in(out_rgb),
    .HBlank(hblank), .VBlank(vblank),
    .HSync(~hsync),  .VSync(~vsync),

    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(r8), .VGA_G(g8), .VGA_B(b8),
    .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
    .VGA_SL(vga_sl),

    .fx(status[5:4]),
    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(gamma_bus)
);

assign VGA_R = r8;
assign VGA_G = g8;
assign VGA_B = b8;
assign VGA_HS = vga_hs;
assign VGA_VS = vga_vs;
assign VGA_DE = vga_de;
assign VGA_SL = vga_sl;

// The cabinet monitor is vertical, so rotate through the DDR3 framebuffer for
// normal displays.
screen_rotate screen_rotate
(
    .CLK_VIDEO(CLK_VIDEO),
    .CE_PIXEL(CE_PIXEL),
    .VGA_R(r8), .VGA_G(g8), .VGA_B(b8),
    .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),

    .rotate_ccw(rotate_ccw),
    .no_rotate(eff_no_rotate),
    // Deliberately NOT the Flip Screen dip. The flip here writes the DDR3
    // framebuffer the SCALER displays, so only HDMI flips -- verified on
    // hardware 2026-08-22: HDMI flipped, direct analog VGA did not, and a
    // rotated-CRT cab is exactly who needs the dip. The dip instead flips
    // the core's own raster (flip_active, at the line-fill/readout muxes by
    // the sei0200 instance), which every output follows; wiring it here as
    // well would double-flip HDMI back to normal. (First attempt was PR #3's
    // approach with the active-low polarity corrected -- kept in history.)
    .flip(1'b0),
    .video_rotated(video_rotated),

    .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
    .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
    .FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
    .FB_VBL(FB_VBL), .FB_LL(FB_LL),

    .DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
    .DDRAM_DIN(DDRAM_DIN)
);

assign FB_PAL_CLK  = 0;
assign FB_PAL_ADDR = 0;
assign FB_PAL_DOUT = 0;
assign FB_PAL_WR   = 0;

assign DDRAM_RD = 0;

endmodule
