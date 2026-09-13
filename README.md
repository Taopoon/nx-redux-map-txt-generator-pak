# Map.txt Generator.pak (NX Redux edition)

An [NX Redux](https://github.com/mohammadsyuhada/nx-redux) tool pak wrapping
[`minui-map-txt-creator`](https://github.com/josegonzalez/minui-map-txt-creator/)
to generate `map.txt` files for FinalBurn Neo **and MAME 2003 Plus** romsets,
so the game list shows real titles ("Metal Slug") instead of arcane rom
names (`mslug.zip`).

Adapted from [josegonzalez/minui-map-txt-generator-pak](https://github.com/josegonzalez/minui-map-txt-generator-pak).

## What differs from the MinUI pak

- **NX Redux / Trimui only** — `tg5040` (Brick, Brick Pro, Smart Pro) and
  `tg5050` (Smart Pro S). Other MinUI platforms were dropped.
- **Flat pak layout** — installs to `/Tools/Map.txt Generator.pak`, the NX
  Redux convention (a `/Tools/<platform>/` subfolder still works as a fallback).
- **Native NX Redux UI** — lists and messages are drawn by `nxlist.elf`
  ([`native/nxlist`](native/nxlist)), compiled inside the NX Redux workspace
  with the launcher's own toolkit (`ListView`, menu bar, button-hint bar), so
  fonts, theme colors, the clock/battery bar and the `B EXIT / A SELECT`
  hints match the Tools menu exactly. No minui-list / minui-presenter.
- **Verified TLS** — the firmware ships no CA store, so dat downloads use the
  NX Redux bundle (`.system/shared/ssl/ca-certificates.crt`). `-ignore-tls` is
  only used if that bundle is missing.
- **Dat cache** — downloaded dat files are kept in
  `.userdata/<platform>/Map.txt Generator/dats/` and are not re-downloaded on
  later runs (the GitHub file listing is still fetched, so Wi-Fi is needed).
- **Local / offline dats** — drop `*.dat` / `*.xml` (ClrMame Pro XML) files
  into the pak's `dats/` folder and a "Use local dat files" option appears.
  This path needs no network at all.
- **Backup of the previous map.txt** — NX Redux's *Rename Rom* stores user
  aliases in the same `map.txt`. Before regenerating, the old file is copied to
  a hidden `.map.txt.bak` in the same folder so nothing is lost.
- **MAME 2003 Plus support** — `(MAME2003PLUS)` folders (and any other
  `(MAME…)` tag) are listed too, with a *MAME 2003 Plus* option that uses
  libretro's `mame2003-plus.xml`. The 22 MB list is downloaded once, slimmed
  to the ~650 KB the creator needs (BIOS sets marked hidden) and cached.
- **Settings-file protection** — a snapshot of `minuisettings.txt` is taken
  before the UI runs and restored if keys ever go missing (a leftover from the
  NextUI-built minui-list days, kept as a safety net).

## Requirements

- NX Redux on a Trimui Brick / Brick Pro / Smart Pro (`tg5040`) or
  Smart Pro S (`tg5050`)
- Wi-Fi (unless you use local dat files)
- Rom folders tagged `(FBN)` or `(MAME2003PLUS)`, e.g. `Roms/Arcade (FBN)`

## Installation

1. Mount your NX Redux SD card.
2. Download the latest release, `Map.txt.Generator.pak.zip`.
3. Extract it so that you end up with `/Tools/Map.txt Generator.pak/launch.sh`
   (folder name **with a space**, no dot between `txt` and `Generator`).
4. Unmount the SD card and boot the device.

## Usage

Browse to `Tools > Map.txt Generator` and press `A`.

1. Pick the `(FBN)` / `(MAME2003PLUS)` rom folder.
2. Pick a dat file: *MAME 2003 Plus* (MAME folders), a specific FBNeo system
   (Arcade, Neogeo, …), *Use every Dat File*, or *Use local dat files* if you
   put any into `dats/`.
3. Wait for "Map.txt generated". Open the rom folder — names are now aliases.

BIOS sets are written with a leading `.`, which hides them from the list.

### Advanced

- `FBN_DAT_REF=<git ref>` in the environment overrides the FBNeo dat git
  reference passed to `minui-map-txt-creator -ref`.
- `MAME2003PLUS_XML_URL=<url>` overrides where the MAME 2003 Plus list is
  fetched from; delete `.userdata/<platform>/Map.txt Generator/dats/mame2003-plus.dat`
  to force a re-download.
- Debug log: `.userdata/<platform>/logs/Map.txt Generator.txt`.

## Building

`nxlist.elf` is cross-compiled by [`.github/workflows/native.yaml`](.github/workflows/native.yaml)
inside the public `ghcr.io/loveretro/<platform>-toolchain` images against a
pinned NX Redux ref (`v1.9.0` — bump `nx_redux_ref` when the firmware's UI
toolkit or `libmsettings` changes). CI drops the result into `bin/<platform>/`
before packaging; a local `make build` fetches the last released copy instead.

```bash
make build      # nxlist.elf (from the latest release) + minui-map-txt-creator into bin/
make release    # dist/Map.txt Generator.pak.zip
make push       # adb push to /mnt/SDCARD/Tools/Map.txt Generator.pak
```
