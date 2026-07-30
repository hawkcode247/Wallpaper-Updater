#!/usr/bin/env bash
if (return 0 2>/dev/null); then
    echo "spotlight.sh: do not source this script — run it as './spotlight.sh'" >&2
    return 1
fi
set -euo pipefail
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        _uid="$(id -u "$SUDO_USER")"
        _rt="/run/user/$_uid"; [[ -d "$_rt" ]] || _rt="/tmp"
        echo "spotlight.sh: desktop wallpaper must be set as user '$SUDO_USER', not root — re-running as $SUDO_USER..." >&2
        exec sudo -u "$SUDO_USER" \
            XDG_RUNTIME_DIR="$_rt" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$_uid/bus" \
            bash "$0" "$@"
    else
        echo "spotlight.sh: do not run as root — the wallpaper would be set for root's session, not yours. Run it as your normal user." >&2
        exit 1
    fi
fi
DATA_PATH="${XDG_DATA_HOME:-$HOME/.local/share}"
SPOTLIGHT_PATH="$DATA_PATH/spotlight"
BACKGROUNDS_PATH="$DATA_PATH/backgrounds"
ARCHIVE_PATH="$HOME/.wallpaper"
USER_AGENT="WindowsShellClient/0"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wallpaper"
CONFIG_FILE="$CONFIG_DIR/config"
ARCHIVE_ENABLED=1     # 1 = keep previous wallpapers in ~/.wallpaper
LIMIT_MB=500          # storage cap for the archive folder
PRUNE_TARGET_PERCENT=80
MIN_WIDTH="${WALLPAPER_MIN_WIDTH:-}"
MIN_HEIGHT="${WALLPAPER_MIN_HEIGHT:-}"
HISTORY_FILE="$SPOTLIGHT_PATH/history.txt"
HISTORY_MAX=500   # keep the last N entries
LOG_FILE="$SPOTLIGHT_PATH/wallpaper.log"
LOG_BUFFER=""
RUN_OK=0
SOURCES=(spotlight bing nasa wallhaven picsum)
SOURCE="${WALLPAPER_SOURCE:-random}"
FALLBACK="${WALLPAPER_FALLBACK:-1}"
SPOTLIGHT_API="https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&fmt=json&locale=en-US&country=US"
BING_API="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-US"
NASA_API="https://api.nasa.gov/planetary/apod?api_key=${NASA_API_KEY:-DEMO_KEY}&thumbs=true"
NASA_RANDOM_API="https://api.nasa.gov/planetary/apod?api_key=${NASA_API_KEY:-DEMO_KEY}&count=8&thumbs=true"
WALLHAVEN_API="https://wallhaven.cc/api/v1/search?sorting=toplist&topRange=1d&atleast=1920x1080&ratios=landscape&purity=100&categories=101"
PICSUM_LIST_API="https://picsum.photos/v2/list"
usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  next (default)   Fetch and apply the next wallpaper
  setup            Run the setup wizard again
  clean            Remove low-resolution images from disk
  reinstall        Reset everything and run setup fresh
  uninstall        Remove the script's data, config and files

Options:
  -s, --source NAME   Pin a source: ${SOURCES[*]} | random
  -n, --no-fallback   Fail instead of trying other sources
  -y, --yes           Assume "yes" for uninstall/reinstall prompts
  -l, --list          List available sources
  -h, --help          Show this help
EOF
}
DO_CLEAN=0
DO_SETUP=0
DO_UNINSTALL=0
DO_REINSTALL=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        next)           shift ;;
        setup)          DO_SETUP=1; shift ;;
        clean|-c|--clean) DO_CLEAN=1; shift ;;
        reinstall)      DO_REINSTALL=1; shift ;;
        uninstall)      DO_UNINSTALL=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -s|--source)    SOURCE="${2:?--source requires a value}"; shift 2 ;;
        -n|--no-fallback) FALLBACK=0; shift ;;
        -l|--list)      printf '%s\n' "${SOURCES[@]}"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done
if [[ "$SOURCE" == "random" ]]; then
    SOURCE="${SOURCES[RANDOM % ${#SOURCES[@]}]}"
fi
case " ${SOURCES[*]} " in
    *" $SOURCE "*) ;;
    *) echo "Invalid source: $SOURCE" >&2; usage >&2; exit 1 ;;
esac
log() { # log <priority> <message> — buffered; written to own log file at exit
    local prio="$1"; shift
    LOG_BUFFER+="$(date '+%F %T') [$prio] $*"$'\n'
    [[ "$prio" == "emerg" || "$prio" == "err" ]] && echo "[$prio] $*" >&2
    return 0
}
flush_logs() { # called on exit: success -> fresh log only; failure -> append
    [[ -n "$LOG_BUFFER" ]] || return 0
    [[ -d "$(dirname "$LOG_FILE")" ]] || return 0
    if [[ "${RUN_OK:-0}" == "1" ]]; then
        printf '%s' "$LOG_BUFFER" > "$LOG_FILE" 2>/dev/null || true
    else
        printf '%s' "$LOG_BUFFER" >> "$LOG_FILE" 2>/dev/null || true
        if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > 200 )); then
            tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null &&
                mv "$LOG_FILE.tmp" "$LOG_FILE" || true
        fi
    fi
}
trap flush_logs EXIT
NOTIFY_ID_FILE="${XDG_RUNTIME_DIR:-/tmp}/wallpaper-notify-id"
ensure_dbus_session() {
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        local uid buspath
        uid="$(id -u)"
        buspath="/run/user/$uid/bus"
        [[ -S "$buspath" ]] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$buspath"
    fi
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]
}
notify_supports_hyperlinks() {
    grep -q "body-hyperlinks" <<< "$(get_notify_capabilities)"
}
notify_supports_actions() {
    grep -qw 'actions' <<< "$(get_notify_capabilities)"
}
NOTIFY_CAPS=""
get_notify_capabilities() {
    if [[ -z "$NOTIFY_CAPS" ]]; then
        if command -v gdbus &>/dev/null; then
            NOTIFY_CAPS="$(gdbus call --session \
                --dest org.freedesktop.Notifications \
                --object-path /org/freedesktop/Notifications \
                --method org.freedesktop.Notifications.GetCapabilities 2>/dev/null)" || NOTIFY_CAPS="none"
        elif command -v busctl &>/dev/null; then
            NOTIFY_CAPS="$(busctl --user call \
                org.freedesktop.Notifications \
                /org/freedesktop/Notifications \
                org.freedesktop.Notifications GetCapabilities 2>/dev/null)" || NOTIFY_CAPS="none"
        else
            NOTIFY_CAPS="none"
        fi
    fi
    printf '%s' "$NOTIFY_CAPS"
}
notify() { # notify <title> <body> [action-url]
    local title="$1" body="$2" action_url="${3:-}"
    local icon="preferences-desktop-wallpaper"
    ensure_dbus_session || return 0   # no session bus -> skip silently
    local replaces_id=0
    [[ -f "$NOTIFY_ID_FILE" ]] && replaces_id="$(cat "$NOTIFY_ID_FILE" 2>/dev/null || echo 0)"
    [[ "$replaces_id" =~ ^[0-9]+$ ]] || replaces_id=0
    local actions='[]'
    local use_action=0
    if [[ -n "$action_url" ]] && notify_supports_actions; then
        actions='["dismiss", "Dismiss", "view", "View"]'
        use_action=1
    fi
    local out="" new_id=""
    if command -v gdbus &>/dev/null; then
        out="$(gdbus call --session \
            --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify \
            "Wallpaper" "$replaces_id" "$icon" "$title" "$body" \
            "$actions" \
            '{"urgency": <byte 0>, "desktop-entry": <"spotlight">}' \
            10000 2>/dev/null)" || true
        new_id="$(sed -n 's/.*uint32 \([0-9]\+\).*/\1/p' <<< "$out" || true)"
    elif command -v busctl &>/dev/null; then
        if [[ "$use_action" == "1" ]]; then
            out="$(busctl --user call \
                org.freedesktop.Notifications \
                /org/freedesktop/Notifications \
                org.freedesktop.Notifications Notify \
                susssasa\{sv\}i \
                "Wallpaper" "$replaces_id" "$icon" "$title" "$body" \
                4 dismiss Dismiss view View 2 urgency y 0 desktop-entry s spotlight 10000 2>/dev/null)" || true
        else
            out="$(busctl --user call \
                org.freedesktop.Notifications \
                /org/freedesktop/Notifications \
                org.freedesktop.Notifications Notify \
                susssasa\{sv\}i \
                "Wallpaper" "$replaces_id" "$icon" "$title" "$body" \
                0 2 urgency y 0 desktop-entry s spotlight 10000 2>/dev/null)" || true
        fi
        new_id="$(awk '{print $2}' <<< "$out" || true)"
    elif command -v dbus-send &>/dev/null; then
        dbus-send --session --type=method_call \
            --dest=org.freedesktop.Notifications \
            /org/freedesktop/Notifications \
            org.freedesktop.Notifications.Notify \
            string:"Wallpaper" uint32:"$replaces_id" string:"$icon" \
            string:"$title" string:"$body" \
            array:string: dict:string:string: int32:10000 2>/dev/null || true
        use_action=0
    fi
    [[ "$new_id" =~ ^[0-9]+$ ]] && echo "$new_id" > "$NOTIFY_ID_FILE" || true
    if [[ "$use_action" == "1" && "$new_id" =~ ^[0-9]+$ ]] && command -v gdbus &>/dev/null; then
        (
            setsid bash -c '
                nid="$1"; url="$2"
                timeout 30 gdbus monitor --session \
                    --dest org.freedesktop.Notifications 2>/dev/null |
                while IFS= read -r line; do
                    case "$line" in
                        *ActionInvoked*"(uint32 $nid, '"'"'view'"'"')"*)
                            setsid xdg-open "$url" >/dev/null 2>&1 &
                            break ;;
                        *NotificationClosed*"(uint32 $nid,"*)
                            break ;;
                    esac
                done
            ' _ "$new_id" "$action_url" >/dev/null 2>&1 9>&- &
        ) 2>/dev/null || true
    fi
    return 0
}
truncate_text() { # truncate_text <text> <maxlen> — cut at word boundary, add ellipsis
    local text="$1" max="$2"
    if (( ${#text} > max )); then
        text="${text:0:max}"
        text="${text% *}…"
    fi
    printf '%s' "$text"
}
truncate_words() { # truncate_words <text> <maxwords> — keep first N words, add ellipsis
    local text="$1" max="$2"
    local -a words
    read -ra words <<< "$text"
    if (( ${#words[@]} > max )); then
        printf '%s…' "${words[*]:0:max}"
    else
        printf '%s' "$text"
    fi
}
image_resolution() { # image_resolution <file> -> "WIDTHxHEIGHT" or empty
    local res=""
    if command -v identify &>/dev/null; then
        res="$(identify -format '%wx%h' "$1[0]" 2>/dev/null || true)"
    fi
    if [[ -z "$res" ]] && command -v file &>/dev/null; then
        res="$(file "$1" | grep -oE '[0-9]{2,5} ?x ?[0-9]{2,5}' | head -1 | tr -d ' ' || true)"
    fi
    printf '%s' "$res"
}
meets_min_resolution() { # meets_min_resolution <file> -> 0 if >= MIN_WIDTH x MIN_HEIGHT
    local res w h
    res="$(image_resolution "$1")"
    [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]] || return 0
    w="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"
    (( w >= MIN_WIDTH && h >= MIN_HEIGHT ))
}
declare -A SEEN=()
if [[ -f "$HISTORY_FILE" ]]; then
    while IFS= read -r _hline; do
        [[ -n "$_hline" ]] && SEEN["$_hline"]=1
    done < "$HISTORY_FILE"
fi
seen_url() { # seen_url <url> -> 0 if already used
    [[ -n "${SEEN["url:$1"]:-}" ]]
}
seen_checksum() { # seen_checksum <file> -> 0 if identical image already used
    local sum
    sum="$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" || return 1
    [[ -n "$sum" && -n "${SEEN["sum:$sum"]:-}" ]]
}
remember_image() { # remember_image <url> <file>
    local sum
    sum="$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)" || sum=""
    SEEN["url:$1"]=1
    [[ -n "$sum" ]] && SEEN["sum:$sum"]=1
    {
        echo "url:$1"
        [[ -n "$sum" ]] && echo "sum:$sum"
    } >> "$HISTORY_FILE" || true
    if [[ "$(wc -l < "$HISTORY_FILE")" -gt "$HISTORY_MAX" ]]; then
        tail -n "$HISTORY_MAX" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" \
            && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    fi
}
die() {
    log emerg "$*"
    exit 1
}
fail() { # recoverable failure inside a fetcher — logged, then caller tries next source
    log warning "$*"
    return 1
}
command -v jq &>/dev/null || { echo "Missing dependency: jq" >&2; exit 1; }
if command -v wget &>/dev/null; then
    HTTP_TOOL="wget"
elif command -v curl &>/dev/null; then
    HTTP_TOOL="curl"
else
    echo "Missing dependency: wget or curl (need at least one)" >&2
    exit 1
fi
fetch() { # fetch <url> -> body on stdout
    if [[ "$HTTP_TOOL" == "wget" ]]; then
        wget -qO- -U "$USER_AGENT" --timeout=15 --tries=2 "$1"
    else
        curl -fsSL -A "$USER_AGENT" --max-time 15 --retry 1 "$1"
    fi
}
download() { # download <url> <outfile>
    if [[ "$HTTP_TOOL" == "wget" ]]; then
        wget -qO "$2" -U "$USER_AGENT" --timeout=30 --tries=2 "$1"
    else
        curl -fsSL -A "$USER_AGENT" --max-time 60 --retry 1 -o "$2" "$1"
    fi
}
mkdir -p "$SPOTLIGHT_PATH" "$BACKGROUNDS_PATH" "$CONFIG_DIR"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/wallpaper-$(id -u).lock"
if command -v flock &>/dev/null; then
    exec 9>"$LOCK_FILE" || true
    if ! flock -n 9; then
        echo "Another wallpaper run is already in progress — skipping." >&2
        exit 0
    fi
fi
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [[ -f "$SCRIPT_PATH" && ! -x "$SCRIPT_PATH" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        printf '\n  ⚠ %s is not executable.\n' "$(basename "$SCRIPT_PATH")"
        printf '    Without it, running the script directly (./%s),\n' "$(basename "$SCRIPT_PATH")"
        printf '    from hotkeys, timers or services will fail.\n\n'
        _ans=""
        read -rp "  Add execute permission now (chmod +x)? [Y/n]: " _ans || _ans=""
        case "${_ans,,}" in
            n|no)
                echo "  Skipped — remember to run it via:  bash $SCRIPT_PATH"
                ;;
            *)
                if chmod +x "$SCRIPT_PATH" 2>/dev/null; then
                    echo "  ✔ Execute permission added — './$(basename "$SCRIPT_PATH")' will work from now on."
                else
                    echo "  ✘ Could not chmod (no write permission?) — try: sudo chmod +x $SCRIPT_PATH" >&2
                fi
                ;;
        esac
        printf '\n'
    else
        chmod +x "$SCRIPT_PATH" 2>/dev/null &&
            log info "Added missing execute permission to $SCRIPT_PATH" || true
    fi
fi
confirm() { # confirm <question> -> 0 if user agrees (or --yes given)
    [[ "$ASSUME_YES" == "1" ]] && return 0
    local ans=""
    read -rp "$1 [y/N]: " ans || ans=""
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}
collect_install_paths() { # everything the script ever creates
    INSTALL_PATHS=(
        "$CONFIG_DIR"                       # config (wizard answers)
        "$SPOTLIGHT_PATH"                   # symlink, history, log
        "$BACKGROUNDS_PATH"                 # current wallpapers
        "$ARCHIVE_PATH"                     # archived wallpapers
        "${XDG_RUNTIME_DIR:-/tmp}/wallpaper-notify-id"
        "$LOCK_FILE"
    )
}
do_uninstall() {
    collect_install_paths
    printf '\n  Wallpaper Fetcher — Uninstall\n'
    printf '  This will remove:\n\n'
    local p size
    for p in "${INSTALL_PATHS[@]}"; do
        [[ -e "$p" ]] || continue
        size="$(du -sh "$p" 2>/dev/null | cut -f1)"
        printf '    %-8s %s\n' "${size:-—}" "$p"
    done
    printf '\n  The script file itself (%s) is NOT deleted.\n\n' "$SCRIPT_PATH"
    if ! confirm "  Remove all of the above?"; then
        echo "  Uninstall cancelled — nothing was removed."
        exit 0
    fi
    if command -v systemctl &>/dev/null; then
        systemctl --user disable --now spotlight.timer spotlight.service &>/dev/null || true
    fi
    for p in "${INSTALL_PATHS[@]}"; do
        rm -rf "$p" 2>/dev/null || true
    done
    echo "  ✔ Uninstalled. All data, config, history and images removed."
    echo "  ✔ To also remove the script:  rm '$SCRIPT_PATH'"
    exit 0
}
do_reinstall() {
    printf '\n  Wallpaper Fetcher — Reinstall (fresh start)\n\n'
    if ! confirm "  Reset config, history and logs, then run setup again?"; then
        echo "  Reinstall cancelled — nothing was changed."
        exit 0
    fi
    local wipe_images=0
    if [[ -d "$ARCHIVE_PATH" || -d "$BACKGROUNDS_PATH" ]]; then
        if confirm "  Also delete all downloaded wallpapers?"; then
            wipe_images=1
        fi
    fi
    rm -rf "$CONFIG_DIR" 2>/dev/null || true
    rm -f "$HISTORY_FILE" "$LOG_FILE" "$SPOTLIGHT_PATH/background.jpg" \
          "${XDG_RUNTIME_DIR:-/tmp}/wallpaper-notify-id" 2>/dev/null || true
    if [[ "$wipe_images" == "1" ]]; then
        rm -rf "$ARCHIVE_PATH" "$BACKGROUNDS_PATH" 2>/dev/null || true
        mkdir -p "$BACKGROUNDS_PATH"
        echo "  ✔ Downloaded wallpapers deleted."
    else
        echo "  ✔ Downloaded wallpapers kept."
    fi
    mkdir -p "$CONFIG_DIR" "$SPOTLIGHT_PATH"
    echo "  ✔ Reset complete — starting fresh setup..."
    DO_SETUP=1   # fall through into the wizard below
}
[[ "$DO_UNINSTALL" == "1" ]] && do_uninstall
[[ "$DO_REINSTALL" == "1" ]] && do_reinstall
load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    local key val
    while IFS='=' read -r key val; do
        case "$key" in
            ARCHIVE_ENABLED) [[ "$val" =~ ^[01]$ ]] && ARCHIVE_ENABLED="$val" ;;
            LIMIT_MB)        [[ "$val" =~ ^[0-9]+$ ]] && LIMIT_MB="$val" ;;
        esac
    done < "$CONFIG_FILE"
    return 0
}
save_config() {
    cat > "$CONFIG_FILE" <<EOF
# spotlight.sh configuration — generated $(date '+%F %T')
# Re-run the wizard anytime:  spotlight.sh setup
ARCHIVE_ENABLED=$ARCHIVE_ENABLED
LIMIT_MB=$LIMIT_MB
EOF
}
setup_wizard() { # interactive; requires a terminal on stdin/stdout
    printf '\n'
    printf '  ┌──────────────────────────────────────────────┐\n'
    printf '  │        Wallpaper Fetcher — First-time Setup   │\n'
    printf '  └──────────────────────────────────────────────┘\n'
    printf '\n'
    printf '  Previous wallpapers can be kept in %s\n' "$ARCHIVE_PATH"
    printf '  so you can reuse them later.\n\n'
    local ans=""
    read -rp "  Save previous wallpapers? [Y/n]: " ans || ans=""
    case "${ans,,}" in
        n|no) ARCHIVE_ENABLED=0 ;;
        *)    ARCHIVE_ENABLED=1 ;;
    esac
    if [[ "$ARCHIVE_ENABLED" == "1" ]]; then
        printf '\n  How much disk space may the archive use?\n\n'
        printf '    1) 500 MB   (default)\n'
        printf '    2) 1 GB\n'
        printf '    3) Custom (enter your own, e.g. "750MB" or "2GB")\n\n'
        local choice=""
        read -rp "  Choose [1/2/3, Enter = 1]: " choice || choice=""
        case "$choice" in
            2) LIMIT_MB=1024 ;;
            3)
                local custom=""
                read -rp "  Enter limit (e.g. 750MB or 2GB): " custom || custom=""
                custom="${custom^^}"; custom="${custom// /}"
                if   [[ "$custom" =~ ^([0-9]+([.][0-9]+)?)GB?$ ]]; then
                    LIMIT_MB="$(awk "BEGIN{printf \"%d\", ${BASH_REMATCH[1]} * 1024}")"
                elif [[ "$custom" =~ ^([0-9]+)MB?$ ]]; then
                    LIMIT_MB="${BASH_REMATCH[1]}"
                else
                    printf '  Could not parse "%s" — using 500 MB.\n' "$custom"
                    LIMIT_MB=500
                fi
                (( LIMIT_MB >= 50 )) || { printf '  Minimum is 50 MB — using 50 MB.\n'; LIMIT_MB=50; }
                ;;
            *) LIMIT_MB=500 ;;
        esac
    fi
    save_config
    printf '\n  ✔ Saved to %s\n' "$CONFIG_FILE"
    if [[ "$ARCHIVE_ENABLED" == "1" ]]; then
        printf '  ✔ Keeping previous wallpapers (limit: %s MB)\n' "$LIMIT_MB"
    else
        printf '  ✔ Previous wallpapers will NOT be kept\n'
    fi
    printf '  ✔ Setup complete — fetching your first wallpaper...\n\n'
}
launch_setup_in_terminal() {
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1
    local term
    for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal \
                mate-terminal lxterminal tilix kitty alacritty foot xterm; do
        command -v "$term" &>/dev/null || continue
        case "$term" in
            gnome-terminal|tilix|mate-terminal)
                "$term" -- bash -c "'$SCRIPT_PATH' setup; read -rp 'Press Enter to close...'" 2>/dev/null 9>&- & ;;
            *)
                "$term" -e bash -c "'$SCRIPT_PATH' setup; read -rp 'Press Enter to close...'" 2>/dev/null 9>&- & ;;
        esac
        local pid=$!
        sleep 1
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}
if [[ "$DO_SETUP" == "1" ]]; then
    if read -t 0 -N 0 2>/dev/null || [[ -t 0 ]]; then
        setup_wizard
    elif launch_setup_in_terminal; then
        exit 0
    else
        echo "setup: no terminal available; using defaults (archive on, 500 MB)" >&2
        save_config
    fi
elif ! load_config; then
    if [[ -t 1 ]]; then
        setup_wizard
    elif launch_setup_in_terminal; then
        save_config 2>/dev/null || true
    else
        save_config
    fi
fi
detect_screen_size() { # sets SCREEN_W, SCREEN_H
    SCREEN_W=0; SCREEN_H=0
    local out=""
    if [[ -n "${DISPLAY:-}" ]] && command -v xrandr &>/dev/null; then
        out="$(xrandr --current 2>/dev/null | sed -n 's/.* connected.* \([0-9]\+\)x\([0-9]\+\)+.*/\1 \2/p' | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && [[ -n "${DISPLAY:-}" ]] && command -v xdpyinfo &>/dev/null; then
        out="$(xdpyinfo 2>/dev/null | sed -n 's/.*dimensions:[[:space:]]*\([0-9]\+\)x\([0-9]\+\) pixels.*/\1 \2/p' | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wlr-randr &>/dev/null; then
        out="$(wlr-randr 2>/dev/null | sed -n 's/^[[:space:]]*\([0-9]\+\)x\([0-9]\+\).*current.*/\1 \2/p' | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v swaymsg &>/dev/null; then
        out="$(swaymsg -t get_outputs 2>/dev/null | jq -r '.[] | select(.active) | "\(.current_mode.width) \(.current_mode.height)"' 2>/dev/null | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v hyprctl &>/dev/null; then
        out="$(hyprctl monitors -j 2>/dev/null | jq -r '.[0] | "\(.width) \(.height)"' 2>/dev/null)"
        [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )); then
        local f
        for f in /sys/class/drm/*/modes; do
            [[ -r "$f" ]] || continue
            out="$(head -1 "$f" 2>/dev/null | sed -n 's/^\([0-9]\+\)x\([0-9]\+\).*/\1 \2/p')"
            if [[ -n "$out" ]]; then read -r SCREEN_W SCREEN_H <<< "$out"; break; fi
        done
    fi
    if (( ${SCREEN_W:-0} < 640 || ${SCREEN_H:-0} < 480 )); then
        SCREEN_W=1920; SCREEN_H=1080
    fi
}
detect_screen_size
REQ_W=$(( SCREEN_W > 3840 ? SCREEN_W : 3840 ))
REQ_H=$(( SCREEN_H > 2160 ? SCREEN_H : 2160 ))
if [[ -z "$MIN_WIDTH" ]]; then
    MIN_WIDTH=$(( SCREEN_W < 1280 ? 1280 : SCREEN_W ))
fi
if [[ -z "$MIN_HEIGHT" ]]; then
    MIN_HEIGHT=$(( SCREEN_H < 720 ? 720 : SCREEN_H ))
fi
WALLHAVEN_API="https://wallhaven.cc/api/v1/search?sorting=toplist&topRange=1d&atleast=${MIN_WIDTH}x${MIN_HEIGHT}&ratios=landscape&purity=100&categories=101"
dir_size_mb() { # dir_size_mb <dir>
    du -sm "$1" 2>/dev/null | cut -f1 || echo 0
}
prune_archive() {
    [[ "$ARCHIVE_ENABLED" == "1" && -d "$ARCHIVE_PATH" ]] || return 0
    local used target removed=0 f
    used="$(dir_size_mb "$ARCHIVE_PATH")"
    (( used > LIMIT_MB )) || return 0
    target=$(( LIMIT_MB * PRUNE_TARGET_PERCENT / 100 ))
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        rm -f "$f" && removed=$((removed+1))
        used="$(dir_size_mb "$ARCHIVE_PATH")"
        (( used <= target )) && break
    done < <(find "$ARCHIVE_PATH" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null \
             | sort -n | cut -d' ' -f2-)
    (( removed > 0 )) && log info "Archive pruned: removed $removed old images (now ${used}MB / limit ${LIMIT_MB}MB)"
    return 0
}
if [[ "$DO_CLEAN" == "1" ]]; then
    removed=0 kept=0
    current="$(readlink "$SPOTLIGHT_PATH/background.jpg" 2>/dev/null || true)"
    for f in "$BACKGROUNDS_PATH"/* "$ARCHIVE_PATH"/*; do
        [[ -f "$f" ]] || continue
        if ! meets_min_resolution "$f"; then
            res="$(image_resolution "$f")"
            echo "Removing low-res (${res:-unknown}): $(basename "$f")"
            rm -f "$f"
            removed=$((removed+1))
            [[ "$f" == "$current" ]] && rm -f "$SPOTLIGHT_PATH/background.jpg"
        else
            kept=$((kept+1))
        fi
    done
    echo "Clean done: removed $removed, kept $kept (min ${MIN_WIDTH}x${MIN_HEIGHT})"
    log info "Cleaned $removed low-res images (kept $kept)"
    RUN_OK=1
    exit 0
fi
fetch_spotlight() {
    local response attempt row cand t desc cta
    for attempt in 1 2 3 4; do
        response="$(fetch "$SPOTLIGHT_API")" || continue
        row="$(jq -r '[.ad.landscapeImage.asset // "", .ad.title // "Spotlight",
                       .ad.description // "", .ad.ctaUri // ""] | @tsv' <<< "$response" 2>/dev/null)" || continue
        IFS=$'\t' read -r cand t desc cta <<< "$row"
        [[ -n "$cand" ]] || continue
        if ! seen_url "$cand"; then
            imageUrl="$cand"
            title="$t"
            description="$desc"
            url="$(sed 's/.*\(http.*\)/\1/' <<< "$cta")"
            return 0
        fi
    done
    fail "Spotlight: no unseen image after 4 attempts" || return 1
}
fetch_bing() {
    local response rows row urlbase t c l candidate
    response="$(fetch "$BING_API")" || fail "Bing API request failed" || return 1
    mapfile -t rows < <(jq -r '.images[] | [.urlbase, .title, .copyright, .copyrightlink] | @tsv' <<< "$response" 2>/dev/null)
    (( ${#rows[@]} > 0 )) || fail "Bing returned no images" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r urlbase t c l <<< "$row"
        [[ -n "$urlbase" ]] || continue
        candidate="https://www.bing.com${urlbase}_UHD.jpg"
        if ! seen_url "$candidate"; then
            imageUrl="$candidate"
            title="${t:-Bing Image of the Day}"
            description="$c"
            url="$l"
            return 0
        fi
    done
    fail "Bing: all 8 archive images already used" || return 1
}
fetch_nasa() {
    local response row cand t expl d
    response="$(fetch "$NASA_API")" || true
    if [[ -n "${response:-}" ]]; then
        row="$(jq -r 'select(.media_type == "image")
            | [(.hdurl // .url // ""), (.title // "NASA APOD"), (.explanation // "")] | @tsv' <<< "$response" 2>/dev/null || true)"
        IFS=$'\t' read -r cand t expl <<< "$row"
        if [[ -n "$cand" ]] && ! seen_url "$cand"; then
            imageUrl="$cand"
            title="$t"
            description="$expl"
            url="https://apod.nasa.gov/apod/astropix.html"
            return 0
        fi
    fi
    response="$(fetch "$NASA_RANDOM_API")" || fail "NASA APOD API request failed" || return 1
    local rows
    mapfile -t rows < <(jq -r '.[] | select(.media_type == "image")
        | [(.hdurl // .url // ""), .title, (.explanation // ""), (.date // "")] | @tsv' <<< "$response" 2>/dev/null)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r cand t expl d <<< "$row"
        [[ -n "$cand" ]] || continue
        if ! seen_url "$cand"; then
            imageUrl="$cand"
            title="${t:-NASA APOD}"
            description="$expl"
            url="https://apod.nasa.gov/apod/ap$(date -d "$d" +%y%m%d 2>/dev/null || echo "").html"
            [[ "$url" == "https://apod.nasa.gov/apod/ap.html" ]] && url="https://apod.nasa.gov/apod/"
            return 0
        fi
    done
    fail "NASA: no unseen image in random batch" || return 1
}
fetch_wallhaven() {
    local response rows row path wid cat wurl
    response="$(fetch "$WALLHAVEN_API")" || fail "Wallhaven API request failed" || return 1
    mapfile -t rows < <(jq -r '.data[] | [.path, .id, .category, .url] | @tsv' <<< "$response" 2>/dev/null | shuf)
    (( ${#rows[@]} > 0 )) || fail "Wallhaven returned no results" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r path wid cat wurl <<< "$row"
        [[ -n "$path" ]] || continue
        if ! seen_url "$path"; then
            imageUrl="$path"
            title="Wallhaven $wid"
            description="Today's top ${cat} wallpaper pick"
            url="$wurl"
            return 0
        fi
    done
    fail "Wallhaven: all toplist images already used" || return 1
}
fetch_picsum() {
    local page response rows row id author purl width height attempt
    for attempt in 1 2 3; do
        page=$((RANDOM % 10 + 1))
        response="$(fetch "$PICSUM_LIST_API?page=$page&limit=100")" || continue
        mapfile -t rows < <(jq -r \
            --argjson mw "$MIN_WIDTH" --argjson mh "$MIN_HEIGHT" '
            .[] | select(.width >= $mw and .height >= $mh)
                | [.id, .author, .url] | @tsv' <<< "$response" 2>/dev/null | shuf)
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r id author purl <<< "$row"
            [[ -n "$id" ]] || continue
            local candidate="https://picsum.photos/id/$id/$REQ_W/$REQ_H"
            if ! seen_url "$candidate"; then
                imageUrl="$candidate"
                title="Lorem Picsum #$id"
                description="Photo${author:+ by $author} from the Picsum collection"
                url="${purl:-https://picsum.photos}"
                return 0
            fi
        done
    done
    fail "Picsum: no unseen image found" || return 1
}
try_source() { # try_source <name> — fetch metadata + download; 0 on success
    local src="$1"
    imageUrl="" title="" description="" url=""
    "fetch_$src" || return 1
    if [[ -z "$imageUrl" ]]; then
        log warning "No image URL found (source: $src)"
        return 1
    fi
    # security: only ever download over http(s) — reject anything else an
    # API response could try to smuggle in (file://, ftp://, data:, ...)
    if [[ ! "$imageUrl" =~ ^https?:// ]]; then
        log warning "Rejected non-http image URL (source: $src)"
        return 1
    fi
    [[ "$url" =~ ^https?:// ]] || url=""
    if seen_url "$imageUrl"; then
        log notice "Image already used before, skipping (source: $src)"
        return 1
    fi
    local safeTitle timestamp
    safeTitle="$(echo "$title" | tr -cd '[:alnum:] *-' | tr ' ' '*' | cut -c1-60)"
    timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
    imagePath="$BACKGROUNDS_PATH/${timestamp}-${src}-${safeTitle}.jpg"
    if ! download "$imageUrl" "$imagePath"; then
        rm -f "$imagePath"
        log warning "Image download failed (source: $src)"
        return 1
    fi
    if [[ ! -s "$imagePath" ]]; then
        rm -f "$imagePath"
        log warning "Downloaded image is empty (source: $src)"
        return 1
    fi
    if ! meets_min_resolution "$imagePath"; then
        local badres; badres="$(image_resolution "$imagePath")"
        rm -f "$imagePath"
        log warning "Image too small (${badres:-unknown} < ${MIN_WIDTH}x${MIN_HEIGHT}), rejected (source: $src)"
        return 1
    fi
    if seen_checksum "$imagePath"; then
        rm -f "$imagePath"
        echo "url:$imageUrl" >> "$HISTORY_FILE"
        log notice "Identical image already used before, skipping (source: $src)"
        return 1
    fi
    remember_image "$imageUrl" "$imagePath"
    return 0
}
attempt_order=("$SOURCE")
if [[ "$FALLBACK" == "1" ]]; then
    remaining=()
    for s in "${SOURCES[@]}"; do
        [[ "$s" != "$SOURCE" ]] && remaining+=("$s")
    done
    for ((i=${#remaining[@]}-1; i>0; i--)); do
        j=$((RANDOM % (i+1)))
        tmp="${remaining[i]}"; remaining[i]="${remaining[j]}"; remaining[j]="$tmp"
    done
    attempt_order+=("${remaining[@]}")
fi
imagePath="" usedSource=""
for src in "${attempt_order[@]}"; do
    [[ -t 1 ]] && echo "Fetching wallpaper from '$src'..."
    if try_source "$src"; then
        usedSource="$src"
        break
    fi
    [[ "$src" == "$SOURCE" && "$FALLBACK" == "1" && ${#attempt_order[@]} -gt 1 ]] && \
        log notice "Source '$src' failed — falling back to: ${attempt_order[*]:1}"
done
if [[ -z "$usedSource" ]]; then
    die "All sources failed (tried: ${attempt_order[*]})"
fi
SOURCE="$usedSource"
previousImagePath="$(readlink "$SPOTLIGHT_PATH/background.jpg" || true)"
if [[ -n "$previousImagePath" && -f "$previousImagePath" && "$previousImagePath" != "$imagePath" ]]; then
    if [[ "$ARCHIVE_ENABLED" == "1" ]]; then
        mkdir -p "$ARCHIVE_PATH"
        mv "$previousImagePath" "$ARCHIVE_PATH/" 2>/dev/null || true
        prune_archive
    else
        rm -f "$previousImagePath" 2>/dev/null || true
    fi
fi
ln -sf "$imagePath" "$SPOTLIGHT_PATH/background.jpg"
detect_environment() {
    local de="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}${DESKTOP_SESSION:-}"
    de="${de,,}"   # lowercase
    case "$de" in
        *gnome*|*unity*|*pantheon*) echo gnome ;;
        *cinnamon*)                 echo cinnamon ;;
        *budgie*)                   echo budgie ;;
        *mate*)                     echo mate ;;
        *kde*|*plasma*)             echo kde ;;
        *xfce*)                     echo xfce ;;
        *lxqt*)                     echo lxqt ;;
        *lxde*)                     echo lxde ;;
        *deepin*)                   echo deepin ;;
        *sway*)                     echo sway ;;
        *hyprland*)                 echo hyprland ;;
        *)
            if pgrep -x gnome-shell   &>/dev/null; then echo gnome
            elif pgrep -x cinnamon    &>/dev/null; then echo cinnamon
            elif pgrep -x mate-session &>/dev/null; then echo mate
            elif pgrep -x plasmashell &>/dev/null; then echo kde
            elif pgrep -x xfce4-session &>/dev/null; then echo xfce
            elif pgrep -x lxqt-session  &>/dev/null; then echo lxqt
            elif pgrep -x lxsession   &>/dev/null; then echo lxde
            elif pgrep -x sway        &>/dev/null; then echo sway
            elif pgrep -x Hyprland    &>/dev/null; then echo hyprland
            else echo unknown
            fi ;;
    esac
}
set_wallpaper() { # set_wallpaper <image-path> -> 0 if applied
    local img="$1" env applied=1
    env="$(detect_environment)"
    case "$env" in
        gnome|budgie)
            if command -v gsettings &>/dev/null; then
                gsettings set org.gnome.desktop.background picture-options "zoom" 2>/dev/null || true
                gsettings set org.gnome.desktop.background picture-uri "file://$img" 2>/dev/null &&
                applied=0
                gsettings set org.gnome.desktop.background picture-uri-dark "file://$img" 2>/dev/null || true
            fi ;;
        cinnamon)
            command -v gsettings &>/dev/null &&
                gsettings set org.cinnamon.desktop.background picture-uri "file://$img" 2>/dev/null &&
                applied=0 ;;
        mate)
            command -v gsettings &>/dev/null &&
                gsettings set org.mate.background picture-filename "$img" 2>/dev/null &&
                applied=0 ;;
        deepin)
            command -v gsettings &>/dev/null &&
                gsettings set com.deepin.wrap.gnome.desktop.background picture-uri "file://$img" 2>/dev/null &&
                applied=0 ;;
        kde)
            if command -v qdbus &>/dev/null || command -v qdbus6 &>/dev/null; then
                local qd; qd="$(command -v qdbus || command -v qdbus6)"
                "$qd" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
                    var allDesktops = desktops();
                    for (var i = 0; i < allDesktops.length; i++) {
                        var d = allDesktops[i];
                        d.wallpaperPlugin = 'org.kde.image';
                        d.currentConfigGroup = ['Wallpaper','org.kde.image','General'];
                        d.writeConfig('Image', 'file://$img');
                    }" 2>/dev/null && applied=0
            fi
            if [[ $applied -ne 0 ]] && command -v plasma-apply-wallpaperimage &>/dev/null; then
                plasma-apply-wallpaperimage "$img" 2>/dev/null && applied=0
            fi ;;
        xfce)
            if command -v xfconf-query &>/dev/null; then
                local prop
                while IFS= read -r prop; do
                    xfconf-query -c xfce4-desktop -p "$prop" -s "$img" 2>/dev/null && applied=0
                done < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E "last-image$" || true)
            fi ;;
        lxqt)
            command -v pcmanfm-qt &>/dev/null &&
                pcmanfm-qt --set-wallpaper "$img" --wallpaper-mode=zoom 2>/dev/null &&
                applied=0 ;;
        lxde)
            command -v pcmanfm &>/dev/null &&
                pcmanfm --set-wallpaper "$img" --wallpaper-mode=fit 2>/dev/null &&
                applied=0 ;;
        sway)
            command -v swaymsg &>/dev/null &&
                swaymsg "output * bg '$img' fill" &>/dev/null &&
                applied=0 ;;
        hyprland)
            if command -v hyprctl &>/dev/null && pgrep -x hyprpaper &>/dev/null; then
                hyprctl hyprpaper preload "$img" &>/dev/null &&
                hyprctl hyprpaper wallpaper ",$img" &>/dev/null &&
                applied=0
            fi ;;
    esac
    if [[ $applied -ne 0 ]]; then
        if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
            if command -v swww &>/dev/null; then
                if ! pgrep -x swww-daemon &>/dev/null; then
                    (setsid swww-daemon &>/dev/null &) || true
                    sleep 0.5
                fi
                swww img "$img" 2>/dev/null && applied=0
            fi
            if [[ $applied -ne 0 ]] && command -v swaybg &>/dev/null; then
                pkill -x swaybg 2>/dev/null || true
                (setsid swaybg -i "$img" -m fill &>/dev/null &) && applied=0
            fi
            if [[ $applied -ne 0 ]] && command -v wbg &>/dev/null; then
                pkill -x wbg 2>/dev/null || true
                (setsid wbg "$img" &>/dev/null &) && applied=0
            fi
        fi
        if [[ $applied -ne 0 && -n "${DISPLAY:-}" ]]; then
            if command -v feh &>/dev/null; then
                feh --bg-fill "$img" 2>/dev/null && applied=0
            elif command -v nitrogen &>/dev/null; then
                nitrogen --set-zoom-fill "$img" 2>/dev/null && applied=0
            elif command -v xwallpaper &>/dev/null; then
                xwallpaper --zoom "$img" 2>/dev/null && applied=0
            fi
        fi
        if [[ $applied -ne 0 ]] && command -v gsettings &>/dev/null; then
            gsettings set org.gnome.desktop.background picture-uri "file://$img" 2>/dev/null && applied=0
            gsettings set org.gnome.desktop.background picture-uri-dark "file://$img" 2>/dev/null || true
        fi
    fi
    if [[ $applied -eq 0 ]]; then
        log info "Wallpaper applied via: $env (${XDG_SESSION_TYPE:-unknown} session)"
        [[ -t 1 ]] && echo "✔ Applied to desktop via: $env"
        return 0
    else
        log warning "Could not apply wallpaper (env: $env, session: ${XDG_SESSION_TYPE:-unknown}) — image saved at $img"
        [[ -t 1 ]] && echo "⚠ Could not apply to desktop (detected env: $env, session: ${XDG_SESSION_TYPE:-unknown}) — image saved at $img" >&2
        return 1
    fi
}
ensure_dbus_session || true
export GSETTINGS_BACKEND=dconf
set_wallpaper "$imagePath" || true
resolution="$(image_resolution "$imagePath")"
fileSize="$(du -h "$imagePath" | cut -f1)"
ensure_dbus_session && get_notify_capabilities >/dev/null || true
blurb="$title"
read -ra titleWords <<< "$title"
if (( ${#titleWords[@]} < 5 )) && [[ -n "$description" && "$description" != "$title" ]]; then
    need=$((8 - ${#titleWords[@]}))
    blurb+=" · $(truncate_words "$description" "$need")"
fi
body="$blurb"
if [[ -n "$url" ]] && ! notify_supports_actions; then
    if notify_supports_hyperlinks; then
        body+=$'\n\n'"[ <a href=\"$url\"><u>view</u></a> ]"
    else
        domain="$(sed -E 's|^[a-z]+://([^/]+).*|\1|; s|^www\.||' <<< "$url")"
        body+=$'\n\n'"[ credit: ${domain} ]"
    fi
fi
notify "Wallpaper Updated" "$body" "$url"
log info "Wallpaper updated [$SOURCE]: $title | ${resolution:-?} ${fileSize} | screen ${SCREEN_W}x${SCREEN_H} | $url"
[[ -t 1 ]] && echo "✔ Wallpaper updated [$SOURCE]: $title (${resolution:-?}, $fileSize)"
RUN_OK=1
