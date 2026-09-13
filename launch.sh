#!/bin/sh
# Map.txt Generator.pak — NX Redux edition
#
# Wraps minui-map-txt-creator to build `map.txt` display-alias files for
# FinalBurn Neo / MAME 2003 Plus rom folders (Roms/* tagged (FBN) or (MAME…)).
#
# Two entry points:
#   launch.sh                    UI session. Prepares the list files and runs
#                                bin/<platform>/nxlist.elf --wizard ONCE; that
#                                single process owns the display for the whole
#                                session (no black-outs between screens).
#   launch.sh --generate F D     called BY nxlist (popen) when the user picks
#                                folder F and dat D on the last wizard step.
#                                stdout is the UI protocol (@MSG / @RESULT /
#                                @DETAIL lines), stderr goes to the log.
#
# NX Redux specifics honoured here (see nx-redux/.dev/PAKS.md):
#   - flat pak layout: this pak lives at /Tools/Map.txt Generator.pak
#     (the platform-subfolder path still works as a fallback)
#   - PLATFORM is tg5040 (Brick / Brick Pro / Smart Pro) or tg5050 (Smart Pro S)
#   - the firmware ships no CA store; verified TLS needs the bundle at
#     $SHARED_SYSTEM_PATH/ssl/ca-certificates.crt
#   - map.txt is also where "Rename Rom" stores user aliases, so the previous
#     file is kept as a dot-prefixed backup (dotfiles are hidden from the list)
#   - nxlist.elf (native/nxlist) is built inside the NX Redux workspace, so
#     lists and messages render exactly like the launcher's Tools menu
PAK_DIR="$(cd "$(dirname "$0")" && pwd)"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

MODE=ui
if [ "$1" = "--generate" ]; then
    MODE=generate
    shift
fi

if [ "$MODE" = "ui" ]; then
    rm -f "$LOGS_PATH/$PAK_NAME.txt"
    exec >>"$LOGS_PATH/$PAK_NAME.txt"
    exec 2>&1
    echo "$0" "$@"
fi
# --generate: stdout is nxlist's pipe, stderr is already the log (inherited)
set -x

cd "$PAK_DIR" || exit 1

PAK_USERDATA="$USERDATA_PATH/$PAK_NAME"
DAT_CACHE_DIR="$PAK_USERDATA/dats"
LOCAL_DAT_DIR="$PAK_DIR/dats"
mkdir -p "$DAT_CACHE_DIR"

architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$PAK_DIR/lib/$architecture:$PAK_DIR/lib/$PLATFORM:$PAK_DIR/lib:$LD_LIBRARY_PATH"

# FBNeo dat files are fetched from GitHub over https. Prefer verified TLS via
# the NX Redux CA bundle (Go's net/http honours SSL_CERT_FILE); only fall back
# to -ignore-tls when the bundle is missing.
TLS_ARGS="-ignore-tls"
CA_BUNDLE="${SHARED_SYSTEM_PATH:-$SDCARD_PATH/.system/shared}/ssl/ca-certificates.crt"
if [ -f "$CA_BUNDLE" ]; then
    export SSL_CERT_FILE="$CA_BUNDLE"
    export CURL_CA_BUNDLE="$CA_BUNDLE"
    TLS_ARGS=""
fi

# Optional override for the FBNeo dat git ref (minui-map-txt-creator -ref).
# Leave unset to use the tool's built-in default.
REF_ARGS=""
if [ -n "$FBN_DAT_REF" ]; then
    REF_ARGS="-ref $FBN_DAT_REF"
fi

APP_TITLE="Map.txt Generator"
LOCAL_DAT_LABEL="Use local dat files (dats folder)"
ALL_DATS_LABEL="Use every Dat File"
MAME2003PLUS_LABEL="MAME 2003 Plus (libretro mame2003-plus.xml)"

# MAME 2003 Plus has no FBNeo-style dat on GitHub; libretro ships the core's
# full -listxml (~22 MB). Only <game name>/<description> matter to the
# creator, so it is slimmed to ~650 KB once and cached. BIOS sets are marked
# runnable="no" there; rewriting that to isbios="yes" makes the creator
# hide them the same way it hides FBNeo BIOS entries.
MAME2003PLUS_XML_URL="${MAME2003PLUS_XML_URL:-https://raw.githubusercontent.com/libretro/mame2003-plus-libretro/master/metadata/mame2003-plus.xml}"
MAME2003PLUS_DAT="$DAT_CACHE_DIR/mame2003-plus.dat"

# --- shared helpers ---------------------------------------------------------

# local dats: ClrMame Pro XML files, either *.dat (FBNeo naming) or *.xml
has_local_dats() {
    [ -d "$LOCAL_DAT_DIR" ] && ls "$LOCAL_DAT_DIR"/*.dat "$LOCAL_DAT_DIR"/*.xml >/dev/null 2>&1
}

# FBNeo folders plus any MAME-family folder (NX Redux ships MAME2003PLUS)
populate_emus_list() {
    ls -A "$SDCARD_PATH/Roms" 2>/dev/null | grep -v '^\.' | grep -E '\((FBN|MAME[A-Z0-9]*)\)' | sort >/tmp/emus.list
}

is_mame_folder() {
    echo "$1" | grep -qE '\(MAME[A-Z0-9]*\)'
}

# The dat choices for one rom folder (wizard step 2), one label per line.
print_action_list() {
    ROM_FOLDER="$1"
    if is_mame_folder "$ROM_FOLDER"; then
        echo "$MAME2003PLUS_LABEL"
    fi
    if has_local_dats; then
        echo "$LOCAL_DAT_LABEL"
    fi
    echo "$ALL_DATS_LABEL"
    echo "Arcade"
    echo "ColecoVision"
    echo "FDS Games"
    echo "Fairchild Channel F Games"
    echo "Game Gear"
    echo "MSX 1 Games"
    echo "Master System"
    echo "Megadrive"
    echo "NES Games"
    echo "NeoGeo Pocket Games"
    echo "Neogeo"
    echo "PC-Engine"
    echo "Sega SG-1000"
    echo "SuprGrafx"
    echo "TurboGrafx16"
    echo "ZX Spectrum Games"
}

# --- --generate: UI protocol on stdout ---------------------------------------
# nxlist shows @MSG while the command runs, then @RESULT (+ @DETAIL) on the
# result screen until the user presses A.
ui_msg() { echo "@MSG $*"; }
ui_result() { echo "@RESULT $*"; }
ui_detail() { echo "@DETAIL $*"; }

# Keep the previous map.txt (it may hold "Rename Rom" aliases). Dot-prefixed
# so NX Redux hides it from the game list.
backup_map_txt() {
    map_file="$1"
    if [ -f "$map_file" ]; then
        cp -f "$map_file" "$(dirname "$map_file")/.map.txt.bak"
    fi
}

# minui-map-txt-creator is a static Go binary: its resolver reads only
# /etc/resolv.conf (written by udhcpc when NX Redux joins a WiFi network).
# With no nameserver it dials [::1]:53 and fails with "connection refused",
# so check up front and tell the user instead of failing mid-run.
WIFI_IF="wlan0"
WPA_CLI="wpa_cli -p /etc/wifi/sockets -i $WIFI_IF" # socket path from NX Redux wifi_init.sh

has_nameserver() {
    grep -q '^nameserver' /etc/resolv.conf 2>/dev/null
}

log_net_state() {
    {
        echo "--- network state"
        cat /etc/resolv.conf 2>/dev/null || echo "(no /etc/resolv.conf)"
        ifconfig "$WIFI_IF" 2>/dev/null | grep -E 'inet |UP' || echo "($WIFI_IF down)"
        $WPA_CLI status 2>/dev/null | grep -E '^(wpa_state|ssid|ip_address)=' || echo "(wpa_supplicant not reachable)"
        echo "---"
    } 1>&2
}

# On failure prints the @RESULT/@DETAIL pair and returns 1.
net_preflight() {
    [ -n "$MAPTXT_SKIP_NETCHECK" ] && return 0 # host-side tests only
    log_net_state
    has_nameserver && return 0

    # Associated to an AP but no lease yet (e.g. just woke from sleep): ask
    # udhcpc once more before giving up. -n: exit on failure, -q: exit once
    # a lease is obtained, -t/-T: 3 tries x 3 s.
    if $WPA_CLI status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; then
        ui_msg "WiFi connected, waiting for IP address..."
        udhcpc -i "$WIFI_IF" -n -q -t 3 -T 3 >/dev/null 2>&1
        log_net_state
        has_nameserver && return 0
        ui_result "No network"
        ui_detail "WiFi joined but no IP/DNS from the router. Reconnect in Settings > WiFi"
        return 1
    fi

    ui_result "No network"
    ui_detail "WiFi not connected. Join a network in Settings > WiFi first"
    return 1
}

# wget: the vendored GNU wget in .system/shared/bin takes --ca-certificate;
# busybox wget (fallback) only knows --no-check-certificate
fetch_url() {
    url="$1"
    dest="$2"
    if wget --version 2>/dev/null | grep -q GNU; then
        if [ -n "$SSL_CERT_FILE" ]; then
            wget -q --timeout=30 --tries=2 --ca-certificate="$SSL_CERT_FILE" -O "$dest" "$url"
        else
            wget -q --timeout=30 --tries=2 --no-check-certificate -O "$dest" "$url"
        fi
    else
        wget -q -T 30 --no-check-certificate -O "$dest" "$url"
    fi
}

ensure_mame2003plus_dat() {
    [ -s "$MAME2003PLUS_DAT" ] && return 0
    ui_msg "Downloading MAME 2003 Plus game list (22 MB)..."
    xml="$DAT_CACHE_DIR/mame2003-plus.xml.part"
    rm -f "$xml"
    if ! fetch_url "$MAME2003PLUS_XML_URL" "$xml" || [ ! -s "$xml" ]; then
        rm -f "$xml"
        ui_result "Download of mame2003-plus.xml failed"
        ui_detail "Check the WiFi connection and the log"
        return 1
    fi
    ui_msg "Preparing MAME 2003 Plus game list..."
    {
        echo '<datafile>'
        grep -E '<game |<description>|</game>' "$xml" | sed 's/runnable="no"/isbios="yes"/'
        echo '</datafile>'
    } >"$MAME2003PLUS_DAT.tmp"
    rm -f "$xml"
    if ! grep -q '<game ' "$MAME2003PLUS_DAT.tmp"; then
        rm -f "$MAME2003PLUS_DAT.tmp"
        ui_result "mame2003-plus.xml had no game entries"
        return 1
    fi
    mv -f "$MAME2003PLUS_DAT.tmp" "$MAME2003PLUS_DAT"
    echo "cached $(grep -c '<game ' "$MAME2003PLUS_DAT") games -> $MAME2003PLUS_DAT" 1>&2
    return 0
}

# "N / M ROMs mapped · B BIOS hidden · U unmatched" for the result screen;
# the unmatched names go to the log.
print_summary() {
    ROMS_DIR="$1"
    MAP_FILE="$2"
    total=$(find "$ROMS_DIR" -maxdepth 1 -type f ! -name '.*' ! -name 'map.txt' 2>/dev/null | wc -l)
    mapped=$(grep -c . "$MAP_FILE" 2>/dev/null)
    hidden=$(grep -c "^[^	]*	\." "$MAP_FILE" 2>/dev/null)
    unmatched=$((total - mapped))
    [ "$unmatched" -lt 0 ] && unmatched=0
    if [ "$unmatched" -gt 0 ]; then
        cut -f1 "$MAP_FILE" >/tmp/maptxt.keys
        echo "--- $unmatched ROM(s) not in the dat:" 1>&2
        ls -Ap "$ROMS_DIR" | grep -v '/$' | grep -v '^\.' | grep -vx 'map.txt' | grep -vxF -f /tmp/maptxt.keys 1>&2
        rm -f /tmp/maptxt.keys
    fi
    ui_detail "$mapped / $total ROMs mapped  ·  $hidden BIOS hidden  ·  $unmatched unmatched"
}

generate_map_txt() {
    ROM_FOLDER="$1"
    DAT_CHOICE="$2"

    ROMS_DIR="$SDCARD_PATH/Roms/$ROM_FOLDER"
    MAP_FILE="$ROMS_DIR/map.txt"

    if [ ! -d "$ROMS_DIR" ]; then
        ui_result "Folder not found"
        ui_detail "$ROMS_DIR"
        return 1
    fi

    if [ "$DAT_CHOICE" != "$LOCAL_DAT_LABEL" ]; then
        net_preflight || return 1
    fi

    backup_map_txt "$MAP_FILE"

    exit_code=0
    if [ "$DAT_CHOICE" = "$MAME2003PLUS_LABEL" ]; then
        ensure_mame2003plus_dat || return 1
        ui_msg "Generating map.txt for $ROM_FOLDER with MAME 2003 Plus list"
        minui-map-txt-creator -roms "$ROMS_DIR" -map "$MAP_FILE" -dat "$MAME2003PLUS_DAT" 1>&2
        exit_code=$?
    elif [ "$DAT_CHOICE" = "$LOCAL_DAT_LABEL" ]; then
        ui_msg "Generating map.txt for $ROM_FOLDER with local dat files"
        # build the arg list positionally so paths with spaces/parens survive
        set -- -roms "$ROMS_DIR" -map "$MAP_FILE"
        for dat in "$LOCAL_DAT_DIR"/*.dat "$LOCAL_DAT_DIR"/*.xml; do
            [ -f "$dat" ] || continue # unmatched glob stays literal
            set -- "$@" -dat "$dat"
        done
        minui-map-txt-creator "$@" 1>&2
        exit_code=$?
    elif [ "$DAT_CHOICE" = "$ALL_DATS_LABEL" ]; then
        ui_msg "Generating map.txt for $ROM_FOLDER with every dat file"
        # shellcheck disable=SC2086
        minui-map-txt-creator -roms "$ROMS_DIR" -map "$MAP_FILE" -cache-dir "$DAT_CACHE_DIR" $TLS_ARGS $REF_ARGS -all-dats 1>&2
        exit_code=$?
    else
        ui_msg "Generating map.txt for $ROM_FOLDER with $DAT_CHOICE dat file"
        # shellcheck disable=SC2086
        minui-map-txt-creator -roms "$ROMS_DIR" -map "$MAP_FILE" -cache-dir "$DAT_CACHE_DIR" $TLS_ARGS $REF_ARGS -dat-name "FinalBurn Neo (ClrMame Pro XML, $DAT_CHOICE only).dat" 1>&2
        exit_code=$?
    fi

    if [ $exit_code -ne 0 ]; then
        ui_result "Failed to generate map.txt for $ROM_FOLDER"
        ui_detail "See the log in .userdata/$PLATFORM/logs"
        return $exit_code
    fi

    # NX Redux re-reads map.txt whenever the folder is opened, but bump the
    # folder mtime anyway so any mtime-fingerprinted cache notices the change.
    touch "$ROMS_DIR" 2>/dev/null || true

    ui_result "Map.txt generated for $ROM_FOLDER"
    print_summary "$ROMS_DIR" "$MAP_FILE"
    return 0
}

# --- UI session ---------------------------------------------------------------

cleanup() {
    rm -f /tmp/stay_awake
    rm -f /tmp/emus.list
    rm -f /tmp/action.*.list
    killall nxlist.elf >/dev/null 2>&1 || true
}

main_ui() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    allowed_platforms="tg5040 tg5050"
    if ! echo "$allowed_platforms" | grep -qw "$PLATFORM"; then
        echo "$PLATFORM is not a supported platform" 1>&2
        return 1
    fi

    if ! command -v nxlist.elf >/dev/null 2>&1; then
        echo "nxlist.elf not found for $PLATFORM" 1>&2
        return 1
    fi

    if ! command -v minui-map-txt-creator >/dev/null 2>&1; then
        echo "minui-map-txt-creator not found" 1>&2
        return 1
    fi

    chmod +x "$PAK_DIR/bin/$PLATFORM/nxlist.elf"
    chmod +x "$PAK_DIR/bin/$architecture/minui-map-txt-creator"

    populate_emus_list
    if [ ! -s /tmp/emus.list ]; then
        nxlist.elf --message "No (FBN) or (MAME) folder found in Roms" --timeout 3
        return 2
    fi

    # step-2 lists, one per folder, picked by nxlist via the %d placeholder
    rm -f /tmp/action.*.list
    i=0
    while IFS= read -r folder; do
        print_action_list "$folder" >"/tmp/action.$i.list"
        i=$((i + 1))
    done </tmp/emus.list

    nxlist.elf --wizard --disable-auto-sleep \
        --app-title "$APP_TITLE" \
        --step "Select ROM Folder for map.txt|EXIT|/tmp/emus.list" \
        --step "Select Dat File for %s|BACK|/tmp/action.%d.list" \
        --exec "'$PAK_DIR/launch.sh' --generate"
    # exit codes: 2 = EXIT (B), 3 = MENU
    return $?
}

if [ "$MODE" = "generate" ]; then
    generate_map_txt "$1" "$2"
    exit $?
fi

main_ui "$@"
