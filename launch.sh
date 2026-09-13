#!/bin/sh
# Map.txt Generator.pak — NX Redux edition
#
# Wraps minui-map-txt-creator to build `map.txt` display-alias files for
# FinalBurn Neo rom folders (any folder under Roms tagged "(FBN)").
#
# NX Redux specifics honoured here (see nx-redux/.dev/PAKS.md):
#   - flat pak layout: this pak lives at /Tools/Map.txt Generator.pak
#     (the platform-subfolder path still works as a fallback)
#   - PLATFORM is tg5040 (Brick / Brick Pro / Smart Pro) or tg5050 (Smart Pro S)
#   - the firmware ships no CA store; verified TLS needs the bundle at
#     $SHARED_SYSTEM_PATH/ssl/ca-certificates.crt
#   - map.txt is also where "Rename Rom" stores user aliases, so the previous
#     file is kept as a dot-prefixed backup (dotfiles are hidden from the list)
set -x
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
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

LOCAL_DAT_LABEL="Use local dat files (dats folder)"
ALL_DATS_LABEL="Use every Dat File"

# local dats: ClrMame Pro XML files, either *.dat (FBNeo naming) or *.xml
has_local_dats() {
    [ -d "$LOCAL_DAT_DIR" ] && ls "$LOCAL_DAT_DIR"/*.dat "$LOCAL_DAT_DIR"/*.xml >/dev/null 2>&1
}

populate_emus_list() {
    ls -A "$SDCARD_PATH/Roms" 2>/dev/null | grep -v '^\.' | grep '(FBN)' | sort >/tmp/emus.list
}

main_screen() {
    minui_list_file="/tmp/minui-list"
    rm -f "$minui_list_file" "/tmp/minui-output"
    touch "$minui_list_file"

    if [ ! -f "/tmp/emus.list" ]; then
        populate_emus_list
    fi

    if [ ! -s "/tmp/emus.list" ]; then
        show_message "No (FBN) folder found in Roms" 3
        return 2
    fi

    killall minui-presenter >/dev/null 2>&1 || true
    minui-list --disable-auto-sleep --item-key "folders" --file "/tmp/emus.list" --format text --cancel-text "EXIT" --title "Select ROM Folder for map.txt" --write-location /tmp/minui-output --write-value selected
}

action_menu() {
    ROM_FOLDER="$1"

    rm -f /tmp/action.list /tmp/action-output

    {
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
    } >>/tmp/action.list

    killall minui-presenter >/dev/null 2>&1 || true
    minui-list --disable-auto-sleep --item-key "actions" --file "/tmp/action.list" --format text --cancel-text "BACK" --title "Select Dat File for $ROM_FOLDER" --write-location /tmp/action-output --write-value selected

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0
}

# Keep the previous map.txt (it may hold "Rename Rom" aliases). Dot-prefixed
# so NX Redux hides it from the game list.
backup_map_txt() {
    map_file="$1"
    if [ -f "$map_file" ]; then
        cp -f "$map_file" "$(dirname "$map_file")/.map.txt.bak"
    fi
}

generate_map_txt() {
    ROM_FOLDER="$1"
    FBN_DAT_FILE="$2"

    ROMS_DIR="$SDCARD_PATH/Roms/$ROM_FOLDER"
    MAP_FILE="$ROMS_DIR/map.txt"

    backup_map_txt "$MAP_FILE"

    exit_code=0
    if [ "$FBN_DAT_FILE" = "$LOCAL_DAT_LABEL" ]; then
        show_message "Generating map.txt for $ROM_FOLDER with local dat files" forever
        # build the arg list positionally so paths with spaces/parens survive
        set -- -roms "$ROMS_DIR" -map "$MAP_FILE"
        for dat in "$LOCAL_DAT_DIR"/*.dat "$LOCAL_DAT_DIR"/*.xml; do
            [ -f "$dat" ] || continue # unmatched glob stays literal
            set -- "$@" -dat "$dat"
        done
        minui-map-txt-creator "$@"
        exit_code=$?
    elif [ "$FBN_DAT_FILE" = "$ALL_DATS_LABEL" ]; then
        show_message "Generating map.txt for $ROM_FOLDER with every dat file" forever
        # shellcheck disable=SC2086
        minui-map-txt-creator -roms "$ROMS_DIR" -map "$MAP_FILE" -cache-dir "$DAT_CACHE_DIR" $TLS_ARGS $REF_ARGS -all-dats
        exit_code=$?
    else
        show_message "Generating map.txt for $ROM_FOLDER with $FBN_DAT_FILE dat file" forever
        # shellcheck disable=SC2086
        minui-map-txt-creator -roms "$ROMS_DIR" -map "$MAP_FILE" -cache-dir "$DAT_CACHE_DIR" $TLS_ARGS $REF_ARGS -dat-name "FinalBurn Neo (ClrMame Pro XML, $FBN_DAT_FILE only).dat"
        exit_code=$?
    fi

    if [ $exit_code -ne 0 ]; then
        show_message "Failed to generate map.txt for $ROM_FOLDER (see log)" 3
        return $exit_code
    fi

    # NX Redux re-reads map.txt whenever the folder is opened, but bump the
    # folder mtime anyway so any mtime-fingerprinted cache notices the change.
    touch "$ROMS_DIR" 2>/dev/null || true

    show_message "Map.txt generated for $ROM_FOLDER" 2
    return 0
}

show_message() {
    message="$1"
    seconds="$2"

    if [ -z "$seconds" ]; then
        seconds="forever"
    fi

    killall minui-presenter >/dev/null 2>&1 || true
    echo "$message" 1>&2
    if [ "$seconds" = "forever" ]; then
        minui-presenter --message "$message" --timeout -1 &
    else
        minui-presenter --message "$message" --timeout "$seconds"
    fi
}

cleanup() {
    rm -f /tmp/stay_awake
    rm -f /tmp/emus.list
    rm -f /tmp/minui-output
    rm -f /tmp/action.list
    rm -f /tmp/action-output
    killall minui-presenter >/dev/null 2>&1 || true
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    allowed_platforms="tg5040 tg5050"
    if ! echo "$allowed_platforms" | grep -qw "$PLATFORM"; then
        show_message "$PLATFORM is not a supported platform" 2
        return 1
    fi

    if ! command -v minui-list >/dev/null 2>&1; then
        show_message "minui-list not found" 2
        return 1
    fi

    if ! command -v minui-presenter >/dev/null 2>&1; then
        show_message "minui-presenter not found" 2
        return 1
    fi

    if ! command -v minui-map-txt-creator >/dev/null 2>&1; then
        show_message "minui-map-txt-creator not found" 2
        return 1
    fi

    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-list"
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-presenter"
    chmod +x "$PAK_DIR/bin/$architecture/minui-map-txt-creator"

    while true; do
        main_screen
        exit_code=$?
        # exit codes: 2 = back button, 3 = menu button
        if [ "$exit_code" -ne 0 ]; then
            break
        fi

        selection="$(cat /tmp/minui-output)"
        if [ -z "$selection" ]; then
            show_message "No selection made" forever
            continue
        fi

        # Show action menu
        action_menu "$selection"
        if [ $? -ne 0 ]; then
            continue
        fi

        fbn_dat_file="$(cat /tmp/action-output)"
        generate_map_txt "$selection" "$fbn_dat_file"
    done
}

main "$@"
