# Raiden II & Raiden DX for MiSTer

An FPGA recreation of the arcade board for **Raiden II** (Seibu Kaihatsu, 1993)
and **Raiden DX** (1994), for the MiSTer FPGA platform. One core runs both
games; the MRA tells it which board to be.

## Status

**Both games boot, play at full speed, and have sound.** On real hardware (a
DE10-Nano) **both** now pass all 22 built-in self-test checks, verified on
2026-08-12 against build `11195503`.

Raiden DX used to fail `CPU BOOT`, and that was a fault in the **test**, not
the core. The check asks whether the CPU ever read the boot-entry window
0x98000-0x98010 and used to give up after 8 frames; Raiden DX does not touch
that window until frame 836, so the check could never pass on DX however
healthy the core. Its deadline is now 1200 frames and DX passes. This had
been reported as 22/22 for both games before that fix, which was not true of
DX at the time.

Raiden II has had the most play-testing. Raiden DX became playable much more
recently, so treat it as the newer of the two — see
[Known problems](#known-problems) below.

## What the core covers

| Part of the arcade board | State |
|---|---|
| V30 main CPU | Working, incl. Raiden DX's 2 MB banked program ROM |
| Seibu COP (protection and maths chip) | Working — all 58 known commands match MAME, plus DX's own 0x7E05 |
| SEI252 sprite chip | Working, including sprite decryption for both ROM sets |
| SEI0200 tilemap chip (4 layers) | Working, incl. DX's swapped CRTC register layout |
| SEI360 mixer (layer priority, transparency) | Working |
| Sound — Z80, YM2151, two OKI6295 chips | Working |
| Video timing | 320x240 at 55.4 Hz native, optional 60 Hz for CRTs |
| SDRAM and ROM loading | Working — 14 MB (II) / 16.5 MB (DX) verified on hardware |

## Known problems

1. **ROM data landing in SDRAM corrupted at load time — believed fixed in the
   current release, but not proven gone.** This used to happen on roughly one
   core load in four, caught by the built-in `SDRAM VERIFY` check and visible
   as a band of wrong graphics or wrong colours.

   The likely cause was never in the SDRAM logic: the previous release
   **failed hold timing on the SDRAM read crossing**, at -0.338 ns on
   `sdram|ch1_dout[13]`, with the ch2 (sprite) and ch4 (OKI) return paths only
   +0.035 and +0.050 behind it. The current release closes that whole crossing
   at +0.242 or better.

   Measured on a DE10-Nano: **38 consecutive core loads with zero failures.**
   Under the old one-in-four rate that run has probability ~1 in 56,000, so
   the old rate is ruled out. What 38 clean loads *cannot* do is prove the
   fault is gone — they bound it at roughly 7% or below with 95% confidence,
   so a low-single-digit rate would have survived this test unnoticed. It is
   also one board at one temperature. **If the picture still looks wrong,
   load the core again, and please report it.**
2. **Raiden DX is newly playable and lightly tested.** Both games pass the
   full self test, but DX has had hours of play-testing where Raiden II has
   had days. DX also pushes the sprite chip closer to its per-line time
   budget than any Raiden II scene measured so far.

An earlier version of this README reported some palette entries staying at
the wrong brightness (issue #74). That was disproved by measurement: the
palette was compared word-for-word against MAME across 1,016 attract frames —
2,080,768 comparisons including the flash-and-fade animations — with zero
divergence. The report came from a comparison-script bug, not the core.

Recently fixed and included in the current release:

- Raiden DX support in full: per-game memory map and decryption window, the
  DX-only COP command 0x7E05 (foreground tile banking), the swapped CRTC
  register layout, and the 8-byte scratch RAM at 0x4D0 whose absence left
  DX's canyon stage drawing placeholder tiles.
- See-through effects (engine flames, water, clouds) came out blue or purple,
  because the 50% colour blend discarded its carry and any channel pair over
  255 wrapped to near zero.
- Both graphics chips ran out of time on busy scanlines and dropped them.
  Dropped scanlines now measure zero on hardware.
- The picture sat off-centre on a CRT, with a black band down one side. The
  sync pulses were not centred in the blanking, and a monitor positions the
  image from the back porch. Only visible on a display fed the core's raw
  video; the scaler re-times everything, which is why it went unnoticed.
- Keyboard and analog stick support, which the core simply did not have.

## How to use it

Copy the files across so your SD card ends up like this:

```
/media/fat/_Arcade/cores/Raiden2_20260811.rbf   <- from releases/
/media/fat/_Arcade/Raiden II.mra                <- from releases/
/media/fat/_Arcade/Raiden DX.mra                <- from releases/
/media/fat/games/mame/raiden2.zip               <- your own MAME ROM set
/media/fat/games/mame/raidendx.zip              <- your own MAME ROM set
```

Then pick **Raiden II** or **Raiden DX** from the Arcade menu. Both MRAs use
the same core file, so you only need the one `.rbf`.

**Get the three files with these commands, not from your browser.** SSH into
the MiSTer (default login `root`, password `1`) and paste:

```
R=https://raw.githubusercontent.com/spacestate1/Arcade-Raiden2_MiSTer/main/releases
mkdir -p /media/fat/_Arcade/cores
cd /media/fat/_Arcade
wget -O 'Raiden II.mra'          "$R/Raiden%20II.mra"
wget -O 'Raiden DX.mra'          "$R/Raiden%20DX.mra"
wget -O cores/Raiden2_20260811.rbf "$R/Raiden2_20260811.rbf"
```

The `.rbf` should come out at just over 4 MB and the MRAs at about 6.7 kB.

**Do not save the files from GitHub's file view.** Opening
`github.com/…/blob/…/Raiden2_20260811.rbf` and saving the page gives you 200 kB
of HTML wearing the right filename, and all three files fail in ways that point
somewhere else: the FPGA rejects the HTML `.rbf` silently, so it looks like a
missing core, and the HTML MRAs fail to parse. If you download in a browser,
use the **Download** button on the file page (or a
`raw.githubusercontent.com` link), then copy the files over.
`tools/check_files.py` below names this case outright.

**The core filename does not have to be exact, and renaming is never
necessary.** Both MRAs ask for `<rbf>Raiden2</rbf>`, and MiSTer's lookup
(`get_rbf` in `support/arcade/mra_loader.cpp`) accepts any file in
`_Arcade/cores/` beginning `Raiden2` *or* `Arcade-Raiden2`, matched
case-insensitively and followed by a `.` or a `_`. So `Raiden2.rbf`,
`Raiden2_20260811.rbf` and `Arcade-Raiden2_20260811.rbf` all work. An
earlier version of this README said the `Arcade-` prefixed releases had to
be renamed by hand; that was wrong, and it sent people chasing filenames
over a fault that was never in the name. If several files match, MiSTer
takes the greatest by byte-wise string comparison rather than the newest,
so delete superseded copies instead of leaving them side by side.

**If choosing the game just bumps you back to the menu**, read what is on
screen, because MiSTer tells these cases apart:

| What you see | What it means |
|---|---|
| `No rbf found!`, about 2 seconds | Nothing in `_Arcade/cores/` matched. Check the folder exists and holds the `.rbf`. |
| `<name> Not Found`, about 5 seconds | A file matched but would not open. Permissions, or a bad card. |
| **No message at all, just a brief flash** | The FPGA rejected the bitstream: the `.rbf` is corrupt or truncated. |

The last case is the one that masquerades as a missing core. It is silent by
design: MiSTer logs the failure only to its console and then restarts
itself, and that restart is what drops you back at the menu. Check the file
itself rather than its name:

**On the MiSTer itself** — this is the one to run if the core will not start,
because it checks the copy on the SD card rather than the copy you downloaded.
SSH in (default login `root`, password `1`) and paste:

```
cd /tmp
wget https://raw.githubusercontent.com/spacestate1/Arcade-Raiden2_MiSTer/main/tools/check_files.py
python3 check_files.py
```

Nothing to install: MiSTer already has Python 3 and `wget`. On hardware it
finds `/media/fat/_Arcade/cores`, `/media/fat/_Arcade` and
`/media/fat/games/mame` by itself; `--install`, `--mra` and `--roms` are only
needed for a non-standard layout. It prints a line per check and ends with
either `All checks passed.` or `FAILED`. Only `.mra` files asking for
`<rbf>Raiden2</rbf>` are checked, so other Raiden cores installed alongside are
left alone.

It says what each file **is**, not just whether its hash matches — an HTML
page, a zip, a Git LFS stub, an empty file and a real-but-wrong-version
bitstream all read differently, and the wrong *type* is the common case:

```
[ FAIL ] Raiden2_20260811.rbf: 175053 bytes -- this is an HTML page, not an FPGA bitstream
[ FAIL ]                       (you saved GitHub's file view instead of the file itself)
[ FAIL ]                       the FPGA rejects it without a message, which looks exactly
[ FAIL ]                       like a missing core
```

Any run that fails ends with the exact `wget` commands to put the install
back, aimed at the directories it just checked. Or have it do the work:

```
python3 check_files.py --repair
```

`--repair` re-downloads the bitstream and both MRAs, **verifies each one
before installing it**, and then re-runs every check. A download that arrives
damaged, or does not arrive at all, leaves the existing file untouched — so
running it on a healthy install cannot break anything. It cannot fetch
`raiden2.zip` / `raidendx.zip`; those are your own MAME sets.

**On the machine you downloaded to**, from a checkout:

```
tools/check_files.py --roms /path/to/your/mame/roms
```

The script needs nothing but Python 3 — no ssh, and no ROMs of its own. A file
can survive the download and still be damaged by the copy to SD, which is why
it checks the *installed* copy by default rather than the one in `releases/`.

The expected hashes live in `releases/md5sums.txt`. In a checkout it reads that
file; run on its own it fetches it, so the hashes are always the current
release's rather than whatever was current when the script was written. With no
network it still reports what each file is, just not which release. Plain
`md5sum -c md5sums.txt` from inside `releases/` works too if you would rather
not run the script at all.

An earlier version of this README hard-coded the size and md5 here, and they
went stale the moment the bitstream was rebuilt — so it told people with a
perfectly good download that it was corrupt. That is why the numbers now live
in a generated manifest instead.

**ROM problems cannot cause a bounce back to the menu.** MiSTer programs the
FPGA and restarts itself *before* it reads a single byte of ROM, so a
missing zip, a wrong revision or a bad CRC always shows up as a running core
with an error box over it, never as a return to the menu.

**No ROMs are included here, and none ever will be.** The `.mra` file only
lists which files it needs and checks them by CRC. You must supply your own.

### Which ROM sets — check yours before reporting graphics bugs

Raiden II exists in a dozen-plus regional revisions with different program
ROMs. The MRAs match the **parent sets** from MAME 0.264 by per-file CRC32
(listed inside each `.mra`). A different revision will load wrongly or not at
all, and the classic symptom is **wrong colours or garbled graphics** — if
you see that, or the built-in self test shows `SPRITE DECRYPT FAIL` /
`SDRAM VERIFY FAIL` on every load, verify your sets first.

The exact zips this core was verified against on hardware:

```
md5sum raiden2.zip  raidendx.zip
af1c4608fbe251313ff2552a780f472c  raiden2.zip
25532740c0f6f9942bac18e700a26d52  raidendx.zip
```

A zip with a different md5 is not automatically wrong — **most correct sets
will not match these**, and that is expected. The `raiden2.zip` above is a
rebuilt parent-only set of 13 files, not a stock MAME zip, and it carries the
two background ROMs under transposed u-numbers (`bg-1.u075` / `bg-2.u0714`
where MAME 0.264 has `bg-1.u0714` / `bg-2.u075`). It loads anyway, because
MiSTer resolves each part by CRC32 first and only falls back to the filename.

**The per-file CRC32s in the MRA are the real test**, and they are what the
MRAs are written against. Use the md5s only to confirm you have byte-for-byte
the set the hardware testing was done on.

To check a set properly rather than by md5, run:

```
tools/check_files.py --roms /path/to/your/mame/roms
```

It reads the CRC32s the MRA asks for and resolves them the way MiSTer does —
by CRC first, filename second — so it tells a genuinely wrong ROM apart from
one that merely sits under a different name. On the reference `raiden2.zip`
it reports 11 of 13 parts matching exactly and the two background ROMs
matching by CRC under transposed u-numbers, which is correct and loads.

## Controls

Defaults follow the same layout as
[Arcade-Cave_MiSTer](https://github.com/MiSTer-devel/Arcade-Cave_MiSTer), so
shmups behave the same way across cores:

| Gamepad | Keyboard | Action |
|---|---|---|
| D-pad or left analog stick | Arrow keys | Move |
| A | Ctrl | Fire |
| B | Alt | Bomb |
| X | Space | Auto fire — Raiden DX only, held; the ~15 Hz repeat is in the game itself |
| R | 1 | Start |
| L | 5 | Insert coin |
| Start | — | Pause |

The left analog stick works alongside the d-pad without any setup, and the
keyboard layout is the usual arcade one, so muscle memory from MAME carries
over. All gamepad buttons can be remapped in the MiSTer menu.

## Video options

**Refresh Rate** (OSD): the real board runs 282 lines per frame at ~55.4 Hz,
and some 15 kHz CRTs will not hold vertical sync that far below 60. The
**60Hz** setting trims vertical blanking to 260 lines — 60.10 Hz, with the
horizontal rate unchanged at 15.625 kHz, so the picture geometry does not
move. The trade is honest and unavoidable: the game paces itself off the
vblank interrupt, so in this mode it plays about 8% faster than the arcade.
Music tempo is set by the YM2151's own timer and does not speed up. Leave it
on **55.4Hz Native** unless your display cannot hold the picture.

**Flip Screen** (DIP switches menu): flips the picture 180°, as the real
board's DIP does. The flip happens inside the core's own raster — the same
place the arcade hardware does it — so it applies to **every output**:
HDMI, direct analog VGA, rotated or not.

## The arcade board's own service menu

Separate from the core's self test below, and useful for anyone comparing
against a real PCB: the game's **DIAGNOSTIC MODE**, showing the live DIP
readout and a per-player input test.

It is not a button. On the real board it is DIP **SW2:8**, so turn on
**Test Mode** in the MiSTer DIP menu and reset. Both games have it.

MiSTer remembers DIP settings per ROM set in `/media/fat/config/<setname>.CFG`,
and those saved settings win over the defaults in the `.mra` — so change it in
the menu rather than by editing the MRA, or the edit will look like it did
nothing.

## Built-in self test

The core can run a self test that checks 22 things — the CPU, memory, video
chips, sound chips and so on — and shows the results on screen. It also sends
them over the debug serial port, which is how the core is tested without
anyone watching a monitor.

It is **off by default**; turn it on from the MiSTer menu under **Self test**,
which also offers two sprite-only display modes used for debugging graphics.

**Give it a minute before believing a FAIL.** Most checks settle within 8
frames, but two do not, and a page read too early is the commonest way to
misread this test:

- `CPU BOOT` has a 1200-frame (~21 s) deadline, because the event it waits
  for happens once, at frame 836 on Raiden DX.
- `OKI ROM FETCH` wants 32 sample-ROM reads out of SDRAM. The OKI cache
  absorbs most of them, so on Raiden II the count only crosses 32 about a
  minute into attract mode. It read `FAIL` at 35 s and `PASS` at 80 s on the
  same build and the same load.

A check that has passed stays passed, so the honest reading is the page after
it has been up for a minute or two, not the one that appears first.

**What `SDRAM VERIFY` covers.** It checksums every word as it is downloaded
(sprites post-decryption, i.e. exactly what lands in memory), then reads the
whole image back through **each of the four SDRAM channels** — ch3 (CPU),
ch1 (tiles), ch2 (sprites), ch4 (OKI) — and compares per 64 KB block. A
mismatch names the channel and the block base address on the detail line, so
a fault confined to one port's return path points at that port instead of
passing unnoticed. (Earlier releases swept only ch1 and ch3; a ch2/ch4-only
fault — wrong sprites or noisy sound over a fully green page — was invisible
to the check. The two extra sweeps add roughly a second to the post-load
check.)

This exists because a black screen tells you nothing about *why* it is black.
The self test has found several real faults that simulation missed.

## Building it yourself

You need **Quartus Prime 17.0** (the free Lite edition works).

### Required packages

Quartus ships most of its own libraries — about 960 of them — so it needs very
little from the distribution, and the compile binaries are 64-bit, so no 32-bit
multilib is required.

```sh
# Debian / Ubuntu
sudo apt install libglib2.0-0 libnsl2 zlib1g libpcre2-8-0

# Fedora / RHEL
sudo dnf install glib2 libnsl zlib pcre2

# Arch
sudo pacman -S glib2 libnsl zlib pcre2
```

On a stock Ubuntu 24.04 install all of these are already present, including
`libnsl.so.1`, which is the one people usually expect to be missing.

**Use the command-line flow below rather than the Quartus GUI.** The GUI wants
`libpng12`, which distributions dropped years ago, along with old Qt libraries.
The command-line flow never loads either, which is why it still works on a
current system.

```sh
export QUARTUS_ROOTDIR=/path/to/intelFPGA_lite/17.0/quartus
export PATH=$QUARTUS_ROOTDIR/bin:$PATH
quartus_sh --flow compile Raiden2
```

The finished core appears at `output_files/Raiden2.rbf`.

Three things that will trip you up:

- The DE10-Nano chip is **`5CSEBA6U23I7`**. Some guides write `...I7N`; that is
  a marketing suffix and Quartus rejects it.
- Quartus 17.0 does not understand `case (...) inside`, even though Verilator
  does. Use an if/else chain instead.
- Quartus 17.0 cannot **index a function call result** — `f(a,b)[5:4]` is a
  syntax error there and compiles fine under Verilator. Assign the call to a
  wire first, then slice the wire.
- **Always check that timing passed before using a build.** Quartus prints
  "Full Compilation was successful" even when timing has failed. Search the
  log for `Timing requirements not met`.

## Clock speeds (read this before changing the PLL)

- **`clk_sys` is 64 MHz.** Divided by 8 it gives the 8 MHz pixel clock, and
  divided by 2 it gives the 32 MHz tick the V30 CPU needs.
- **`clk_ram` is 96 MHz.** It used to be 128 MHz, which looked tidy because it
  was exactly twice `clk_sys`, but the SDRAM controller cannot close timing
  that fast on this chip.

Because 96 and 64 are a 3:2 ratio, signals crossing between the two clocks are
**not** automatically safe. Two mechanisms make the crossing correct, and
removing either one produces a core that hangs waiting for data that already
arrived. Both are commented in `Raiden2.sv`.

## How this core is tested

For each chip on the arcade board, a reference model was written from the MAME
source **first**, and the FPGA code is then compared against it — signal by
signal, or pixel by pixel.

Writing the model first matters: it is an independent implementation, so
agreement means something. Checking the FPGA code against a recording of its
own output would mean nothing.

| Chip | Compared against | Result |
|---|---|---|
| Seibu COP (protection/maths) | `tb_cop_cmd.cpp` vs MAME | all 58 commands match |
| Sprite decryption | `tools/r2crypt.py` | 200,032 test values, all exact |
| SEI360 mixer | `tools/mix_model.py` | 100,000 test values, all exact |
| SEI252 sprite chip | `tools/render_sprites.py` | 76,800 of 76,800 pixels match |
| SEI0200 tilemap chip | `tools/render_frame.py` | every pixel matches |
| Sound latch | `tb_seibu_latch.cpp` vs MAME | 36 of 36 cases match |

Every chip checked this way worked on real hardware the first time.

There are fourteen test benches, each runnable on its own:

```
spr-run   sprpaced-run  sprprot-run  cop-run    crypt-run  mix-run  latch-run
itoa-run  bist-run      selftest-run sdmain-run sound-run  vec-run  video-run
```

The sprite chip has **two** benches deliberately. `spr-run` draws every
scanline offline and compares it to the reference picture. `sprpaced-run`
starts a new line every 4,096 clocks whether the chip has finished the last one
or not, exactly as the real board does. The second exists because the first one
passed a change that doubled every sprite on real hardware: a test that treats
the chip more gently than the hardware does will keep passing forever.

The benches and reference models live in the wider development tree (`sim/` and
`tools/`), not in this repository.

### Timing budget

The sprite and tilemap chips each have 4,096 clocks to draw one scanline
(512 pixels × 8). Over that and the line is dropped, which looks like
flickering or missing graphics.

Where both chips stand on a DE10-Nano, measured per line:

| chip | worst line | budget | dropped scanlines |
|---|---|---|---|
| sprites (SEI252) | **3,973** | 4,096 | **0** |
| tilemaps (SEI0200) | **3,568** | 4,096 | **0** |

The sprite chip started at 8,262 clocks with 59 to 132 scanlines dropped per
frame. Three changes closed that: a duplicate memory fetch that made every
back-to-back read return the previous one's data; splitting the chip into a
scanner and a plotter so the next sprite is found while the current one is
still being drawn; and two scanner optimisations. The tilemap chip got the
same treatment for the column it was not prefetching.

A caution for anyone comparing against older notes: the on-chip counters
originally measured from one busy edge to the next, which spans several lines
whenever a line overruns, and they were never cleared per frame — so they
included start-up, when the ROM load saturates memory. One capture read 40,522
that way, which is not a fill time at all. They now restart every line. Any
figure recorded before that fix is an upper bound, not a per-line measurement.

### What the testing does **not** catch

The honest part, and worth reading before trusting a green result.

**Every hardware fault so far has been in the wiring *between* tested chips,
not inside them.** Each chip passed its own tests and was still wrong once
connected. The clearest example: the mixer passed 100,000 test values, and the
bug was in the arithmetic that blends two colours together — code sitting
outside the mixer, in the top level, where no test was looking.

**A test is only as good as what you feed it.** Four real cases:

- A sprite bench reported "76,800 of 76,800 pixels match" while its input list
  of sprites had been silently emptied. Blank matched blank perfectly.
- Two parts of the sprite chip hand work to each other. A fault in that
  handover could only occur when the timing was exactly back to back, and both
  benches left a comfortable gap, so neither could ever produce it. Real
  hardware leaves no gap.
- A bench modelled the sprite RAM as answering instantly when the real one
  answers a cycle later. It then **failed** the version that is correct for
  hardware and would have passed one that reads the wrong sprite.
- The tilemap bench ran with a ROM that answers instantly, which does not
  exist. At that setting the chip looked comfortably fast while the real one
  was near its limit.

All four were faults in the test harness, not the FPGA code. The benches now
refuse to run on empty input, model the real memory latency, and default to a
realistic ROM latency.

**`sdmain-run` does not include the sprite chip**, so it is not a test of it,
despite exercising the memory path that feeds it.

## Credits and licence

Licensed under the **GNU GPL v3** — see [LICENSE](LICENSE).

Framework and building blocks come from
**[Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer)**
by Martin Donlon (wickerwaka), GPL-2.0: the `sys/` folder, the SDRAM
controller, the V30-class CPU core, the RAM primitives and the PLL.

Hardware behaviour was derived from the MAME source for the Seibu drivers:

- `r2crypt.cpp` (BSD-3-Clause) — Andreas Naive, Olivier Galibert
- `sei25x_rise1x_spr.cpp`, `seibusound.cpp` (BSD-3-Clause)
- `raiden2.cpp`, `raiden2_v.cpp`, `seibucop.cpp`, `seibu_crtc.cpp`
  (LGPL-2.1+) — Olivier Galibert, Angelo Salese, David Haywood,
  Tomasz Slanina and others

LGPL-2.1+ allows relicensing to GPLv3 through its "or later" clause.
Attribution is kept here and in the headers of the files concerned.

**Raiden II is a trademark of its respective owner. This project is not
affiliated with or endorsed by them.**
