# Map.txt Generator.pak

An [NX Redux](https://github.com/mohammadsyuhada/nx-redux) tool pak that
generates `map.txt` files for FinalBurn Neo and MAME 2003 Plus rom folders, so
the game list shows real titles ("Metal Slug") instead of romset names
(`mslug.zip`).

Name matching is done by
[`minui-map-txt-creator`](https://github.com/josegonzalez/minui-map-txt-creator/);
the pak started as an NX Redux port of
[josegonzalez/minui-map-txt-generator-pak](https://github.com/josegonzalez/minui-map-txt-generator-pak).

## Features

- **Native NX Redux UI** — every screen is drawn by `nxlist.elf`
  ([`native/nxlist`](native/nxlist)), compiled inside the NX Redux workspace
  with the launcher's own toolkit (`ListView`, menu bar, button-hint bar).
  Fonts, theme colors, the clock/battery bar and the `B EXIT / A SELECT`
  hints are the Tools menu's. One process runs the whole session, so there
  are no black frames between screens and `B` steps back.
- **FinalBurn Neo** — any `(FBN)` folder, with the per-system dats from the
  FBNeo repository (Arcade, Neogeo, Megadrive, …) or all of them at once.
- **MAME 2003 Plus** — any `(MAME…)` folder, using libretro's
  `mame2003-plus.xml`. The 22 MB list is downloaded once, reduced to the
  ~650 KB the matcher needs, and cached.
- **Result summary** — `N / M ROMs mapped · B BIOS hidden · U unmatched`
  after each run; unmatched rom names are written to the log.
- **BIOS sets hidden** — written with a leading `.` so NX Redux keeps them out
  of the game list.
- **Previous map.txt kept** — NX Redux's *Rename Rom* stores user aliases in
  the same file, so the old one is copied to a hidden `.map.txt.bak` first.
- **Offline dats** — drop `*.dat` / `*.xml` (ClrMame Pro XML) files into the
  pak's `dats/` folder and a *Use local dat files* option appears; that path
  needs no network.
- **Verified TLS** — downloads use the NX Redux CA bundle
  (`.system/shared/ssl/ca-certificates.crt`); the firmware itself ships no CA
  store.

## Requirements

- NX Redux on a Trimui Brick / Brick Pro / Smart Pro (`tg5040`) or Smart Pro S
  (`tg5050`)
- Wi-Fi, unless you only use local dat files
- Rom folders tagged `(FBN)` or `(MAME2003PLUS)`, e.g. `Roms/Arcade (FBN)`

## Installation

1. Download `Map.txt.Generator.pak.zip` from the latest release.
2. Extract it onto the SD card so that
   `/Tools/Map.txt Generator.pak/launch.sh` exists (folder name with a space,
   no dot between `txt` and `Generator`).
3. Boot the device.

## Usage

`Tools > Map.txt Generator`

1. **Select ROM Folder** — the `(FBN)` / `(MAME…)` folders under `Roms/`.
2. **Select Dat File** — *MAME 2003 Plus* (MAME folders only), a specific
   FBNeo system, *Use every Dat File*, or *Use local dat files* when `dats/`
   holds any. `B` returns to the folder list.
3. A status screen shows the download / generation progress.
4. The result screen shows the summary; `A` returns to the folder list.

Open the rom folder afterwards — NX Redux reads `map.txt` each time a folder
is opened.

### Where the dat files live

| Path | Purpose |
|---|---|
| `.userdata/<platform>/Map.txt Generator/dats/` | cache of downloaded FBNeo dats and the reduced `mame2003-plus.dat`; delete a file to force a re-download |
| `Tools/Map.txt Generator.pak/dats/` | your own dats for the *Use local dat files* option |

### Advanced

- `FBN_DAT_REF=<git ref>` — FBNeo dat git reference passed to
  `minui-map-txt-creator -ref` (default: the tool's built-in ref).
- `MAME2003PLUS_XML_URL=<url>` — where the MAME 2003 Plus list is fetched from.
- Log: `.userdata/<platform>/logs/Map.txt Generator.txt`.

## How it works

`launch.sh` has two entry points:

- **UI session** (no arguments) — lists the rom folders, writes one dat-choice
  list per folder, then runs `nxlist.elf --wizard` once.
- **`--generate <folder> <dat>`** — run by `nxlist` through `popen` when the
  last step is confirmed. Its stdout is a tiny protocol that drives the
  screens: `@MSG` (status line while running), `@RESULT` / `@DETAIL` (the
  result screen); everything else goes to the log.

`nxlist.elf` also has a `--message <text> [--timeout <secs>]` mode for
one-off notices.

## Building

`nxlist.elf` is cross-compiled by
[`.github/workflows/native.yaml`](.github/workflows/native.yaml) inside the
public `ghcr.io/loveretro/<platform>-toolchain` images against a pinned NX Redux
ref (`v1.9.0`). Bump `nx_redux_ref` when the firmware's UI toolkit or
`libmsettings` changes. CI places the binaries in `bin/<platform>/` before
packaging; a local `make build` downloads the last released copies instead.

```bash
make build      # nxlist.elf (latest release) + minui-map-txt-creator into bin/
make release    # dist/Map.txt Generator.pak.zip
make push       # adb push to /mnt/SDCARD/Tools/Map.txt Generator.pak
```
