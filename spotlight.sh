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
ARCHIVE_ENABLED=1
LIMIT_MB=500
PRUNE_TARGET_PERCENT=80
INTERVAL_MIN=150
MIN_WIDTH="${WALLPAPER_MIN_WIDTH:-}"
MIN_HEIGHT="${WALLPAPER_MIN_HEIGHT:-}"
HISTORY_FILE="$SPOTLIGHT_PATH/history.txt"
HISTORY_MAX=500
LOG_FILE="$SPOTLIGHT_PATH/wallpaper.log"
LOG_BUFFER=""
RUN_OK=0
CATEGORY="default"
DEFAULT_SOURCES=(spotlight bing nasa wallhaven picsum)
SCIENCE_SOURCES=(nasaimg wikisci ovsci whtech)
WILDLIFE_SOURCES=(inat wikifp ovwild wikiwild whwild)
SOURCES=("${DEFAULT_SOURCES[@]}")
SOURCE="random"
FALLBACK=1
FORCE=0

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
  predownload      (boot) fetch and save the next wallpaper without applying
  setup            Run the setup wizard again
  clean            Remove low-resolution images from disk
  reinstall        Reset everything and run setup fresh
  uninstall        Remove the script's data, config and files

Options:
  -s, --source NAME   Pin a source: ${SOURCES[*]} | random
  -f, --force         Force an update bypassing the boot/elapsed check
  -n, --no-fallback   Fail instead of trying other sources
  -w, --wait-net      Wait for internet if offline
  -y, --yes           Assume "yes" for reinstall/uninstall prompts
  -l, --list          List available sources
  -h, --help          Show this help
EOF
}

DO_CLEAN=0
DO_SETUP=0
WAIT_NET=0
DO_PREDOWNLOAD=0
DO_UNINSTALL=0
DO_REINSTALL=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        next)           shift ;;
        predownload)    DO_PREDOWNLOAD=1; shift ;;
        setup)          DO_SETUP=1; shift ;;
        clean|-c|--clean) DO_CLEAN=1; shift ;;
        reinstall)      DO_REINSTALL=1; shift ;;
        uninstall)      DO_UNINSTALL=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -f|--force)     FORCE=1; shift ;;
        -s|--source)    SOURCE="${2:?--source requires a value}"; shift 2 ;;
        -n|--no-fallback) FALLBACK=0; shift ;;
        -w|--wait-net)  WAIT_NET=1; shift ;;
        -l|--list)      printf '%s\n' "${SOURCES[@]}"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

apply_category() {
    case "$CATEGORY" in
        science)  SOURCES=("${SCIENCE_SOURCES[@]}") ;;
        wildlife) SOURCES=("${WILDLIFE_SOURCES[@]}") ;;
        *)        CATEGORY=default; SOURCES=("${DEFAULT_SOURCES[@]}") ;;
    esac
    if [[ "$SOURCE" == "random" ]]; then
        SOURCE="${SOURCES[RANDOM % ${#SOURCES[@]}]}"
    fi
    case " ${SOURCES[*]} ${DEFAULT_SOURCES[*]} ${SCIENCE_SOURCES[*]} ${WILDLIFE_SOURCES[*]} " in
        *" $SOURCE "*) ;;
        *) echo "Invalid source: $SOURCE" >&2; usage >&2; exit 1 ;;
    esac
}

log() {
    local prio="$1"; shift
    LOG_BUFFER+="$(date '+%F %T') [$prio] $*"$'\n'
    [[ "$prio" == "emerg" || "$prio" == "err" ]] && echo "[$prio] $*" >&2
    return 0
}

flush_logs() {
    [[ -z "$LOG_BUFFER" ]] && return 0
    mkdir -p "$(dirname "$LOG_FILE")"
    if [[ "${RUN_OK:-0}" == "1" ]]; then
        printf '%s' "$LOG_BUFFER" > "$LOG_FILE" 2>/dev/null || true
    else
        printf '%s' "$LOG_BUFFER" >> "$LOG_FILE" 2>/dev/null || true
        if [[ -f "$LOG_FILE" ]] && (( $(wc -l < "$LOG_FILE") > 200 )); then
            tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" || true
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

notify() {
    local title="$1" body="$2" action_url="${3:-}"
    local icon="preferences-desktop-wallpaper"
    ensure_dbus_session || return 0
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
                susssasa{sv}i \
                "Wallpaper" "$replaces_id" "$icon" "$title" "$body" \
                4 dismiss Dismiss view View 2 urgency y 0 desktop-entry s spotlight 10000 2>/dev/null)" || true
        else
            out="$(busctl --user call \
                org.freedesktop.Notifications \
                /org/freedesktop/Notifications \
                org.freedesktop.Notifications Notify \
                susssasa{sv}i \
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
                        *ActionInvoked*"$nid"*,*view*)
                            setsid xdg-open "$url" >/dev/null 2>&1 &
                            break ;;
                        *NotificationClosed*"$nid"*,*)
                            break ;;
                    esac
                done
            ' _ "$new_id" "$action_url" >/dev/null 2>&1 9>&- &
        ) 2>/dev/null || true
    fi
    return 0
}

truncate_text() {
    local text="$1" max="$2"
    if (( ${#text} > max )); then
        text="${text:0:max}"
        text="${text% *}…"
    fi
    printf '%s' "$text"
}

truncate_words() {
    local text="$1" max="$2"
    local -a words
    read -ra words <<< "$text"
    if (( ${#words[@]} > max )); then
        printf '%s…' "${words[*]:0:max}"
    else
        printf '%s' "$text"
    fi
}

image_resolution() {
    local res=""
    if command -v identify &>/dev/null; then
        res="$(identify -format '%wx%h' "${1}[0]" 2>/dev/null || true)"
    fi
    if [[ -z "$res" ]] && command -v file &>/dev/null; then
        res="$(file "$1" | grep -oE '[0-9]{2,5} ?x ?[0-9]{2,5}' | head -1 | tr -d ' ' || true)"
    fi
    printf '%s' "$res"
}

meets_min_resolution() {
    local res w h
    res="$(image_resolution "$1")"
    [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]] || return 0
    w="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"
    (( w >= ${MIN_WIDTH:-1280} && h >= ${MIN_HEIGHT:-720} ))
}

declare -A SEEN
if [[ -f "$HISTORY_FILE" ]]; then
    while IFS= read -r _hline; do
        [[ -n "$_hline" ]] && SEEN["$_hline"]=1
    done < "$HISTORY_FILE"
fi

seen_url() {
    [[ -n "${SEEN["url:$1"]:-}" ]]
}

seen_checksum() {
    local sum
    sum="$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)" || return 1
    [[ -n "$sum" && -n "${SEEN["sum:$sum"]:-}" ]]
}

remember_image() {
    local sum
    sum="$(sha256sum "$2" 2>/dev/null | cut -d' ' -f1)" || sum=""
    SEEN["url:$1"]=1
    [[ -n "$sum" ]] && SEEN["sum:$sum"]=1
    {
        echo "url:$1"
        [[ -n "$sum" ]] && echo "sum:$sum"
    } >> "$HISTORY_FILE" || true
    if [[ "$(wc -l < "$HISTORY_FILE")" -gt "$HISTORY_MAX" ]]; then
        tail -n "$HISTORY_MAX" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
    fi
}

die() {
    log emerg "$*"
    exit 1
}

fail() {
    log warning "$*"
    return 1
}

if command -v jq &>/dev/null; then :; else echo "Missing dependency: jq" >&2; exit 1; fi

if command -v wget &>/dev/null; then HTTP_TOOL="wget"
elif command -v curl &>/dev/null; then HTTP_TOOL="curl"
else echo "Missing dependency: wget or curl" >&2; exit 1; fi

fetch() {
    if [[ "$HTTP_TOOL" == "wget" ]]; then
        wget -qO- -U "$USER_AGENT" --timeout=15 --tries=2 "$1"
    else
        curl -fsSL -A "$USER_AGENT" --max-time 15 --retry 1 "$1"
    fi
}

download() {
    if [[ "$HTTP_TOOL" == "wget" ]]; then
        if [[ -t 1 ]]; then
            wget --show-progress -O "$2" -U "$USER_AGENT" --timeout=30 --tries=2 "$1"
        else
            wget -qO "$2" -U "$USER_AGENT" --timeout=30 --tries=2 "$1"
        fi
    else
        if [[ -t 1 ]]; then
            curl -L -# -A "$USER_AGENT" --max-time 60 --retry 1 -o "$2" "$1"
        else
            curl -fsSL -A "$USER_AGENT" --max-time 60 --retry 1 -o "$2" "$1"
        fi
    fi
}

mkdir -p "$SPOTLIGHT_PATH" "$BACKGROUNDS_PATH" "$CONFIG_DIR"

LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/wallpaper-$(id -u).lock"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
if command -v flock &>/dev/null; then
    exec 9>"$LOCK_FILE" || true
    if ! flock -n 9; then
        echo "Another wallpaper run is already in progress — skipping." >&2
        exit 0
    fi
fi

confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    local ans=""
    read -rp "$1 [y/N]: " ans || ans=""
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

collect_install_paths() {
    INSTALL_PATHS=(
        "$CONFIG_DIR"
        "$SPOTLIGHT_PATH"
        "$BACKGROUNDS_PATH"
        "$ARCHIVE_PATH"
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
    printf '\n  The script file itself (%s) is NOT deleted.\n\n' "$0"
    if ! confirm "  Remove all of the above?"; then
        echo "  Uninstall cancelled — nothing was removed."
        exit 0
    fi
    if command -v systemctl &>/dev/null; then
        systemctl --user disable --now spotlight.timer spotlight.service 2>/dev/null || true
    fi
    for p in "${INSTALL_PATHS[@]}"; do
        rm -rf "$p" 2>/dev/null || true
    done
    echo "  ✔ Uninstalled. All data, config, history and images removed."
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
    rm -f "$HISTORY_FILE" "$LOG_FILE" "$SPOTLIGHT_PATH/background.jpg" "${XDG_RUNTIME_DIR:-/tmp}/wallpaper-notify-id" 2>/dev/null || true
    if [[ "$wipe_images" == "1" ]]; then
        rm -rf "$ARCHIVE_PATH" "$BACKGROUNDS_PATH" 2>/dev/null || true
        mkdir -p "$BACKGROUNDS_PATH"
        echo "  ✔ Downloaded wallpapers deleted."
    else
        echo "  ✔ Downloaded wallpapers kept."
    fi
    mkdir -p "$CONFIG_DIR" "$SPOTLIGHT_PATH"
    echo "  ✔ Reset complete — starting fresh setup..."
    DO_SETUP=1
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    local key val
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[A-Z_]+$ ]] || continue
        case "$key" in
            ARCHIVE_ENABLED) [[ "$val" =~ ^[01]$ ]] && ARCHIVE_ENABLED="$val" ;;
            LIMIT_MB)        [[ "$val" =~ ^[0-9]+$ ]] && LIMIT_MB="$val" ;;
            INTERVAL_MIN)     [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 ]] && INTERVAL_MIN="$val" ;;
            CATEGORY)        [[ "$val" =~ ^(default|science|wildlife)$ ]] && CATEGORY="$val" ;;
        esac
    done < "$CONFIG_FILE"
    return 0
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
ARCHIVE_ENABLED=$ARCHIVE_ENABLED
LIMIT_MB=$LIMIT_MB
CATEGORY=$CATEGORY
INTERVAL_MIN=$INTERVAL_MIN
EOF
}

setup_wizard() {
    printf '\n'
    printf '  ┌──────────────────────────────────────────┐\n'
    printf '  │        Wallpaper Fetcher Setup           │\n'
    printf '  └──────────────────────────────────────────┘\n\n'
    printf '  Previous wallpapers can be kept in %s\n' "$ARCHIVE_PATH"
    printf '  so you can reuse them later.\n\n'
    printf '  Image category:\n'
    printf '    1) Default       — Spotlight, Bing, NASA APOD, Wallhaven, Picsum\n'
    printf '    2) Scientific    — NASA library, research & tech imagery\n'
    printf '    3) Wildlife      — sanctuaries, animals & nature\n\n'
    local catc=""
    read -rp "  Choose [1/2/3, Enter = 1]: " catc || catc=""
    case "$catc" in
        2) CATEGORY=science ;;
        3) CATEGORY=wildlife ;;
        *) CATEGORY=default ;;
    esac
    printf '\n'
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
        printf '    3) Custom (enter size, e.g. "750MB" or "2GB")\n\n'
        local choice=""
        read -rp "  Choose [1/2/3, Enter = 1]: " choice || choice=""
        case "$choice" in
            2) LIMIT_MB=1024 ;;
            3)
                local custom=""
                read -rp "  Enter limit (e.g. 750MB or 2GB): " custom || custom=""
                custom="${custom^^}"; custom="${custom// /}"
                if [[ "$custom" =~ ^([0-9]+([.][0-9]+)?)GB?$ ]]; then
                    LIMIT_MB="$(awk "BEGIN{printf \"%d\", ${BASH_REMATCH[1]} * 1024}")"
                elif [[ "$custom" =~ ^([0-9]+)MB?$ ]]; then
                    LIMIT_MB="${BASH_REMATCH[1]}"
                else
                    printf '  Could not parse "%s" — using 500 MB.\n' "$custom"
                    LIMIT_MB=500
                fi
                (( LIMIT_MB >= 50 )) || LIMIT_MB=50
                ;;
            *) LIMIT_MB=500 ;;
        esac
    fi
    save_config
    printf '\n  ✔ Saved config to %s\n' "$CONFIG_FILE"
}

[[ "$DO_SETUP" == "1" ]] && setup_wizard

if ! load_config; then
    setup_wizard
fi

apply_category

LAST_CHANGE_FILE="$SPOTLIGHT_PATH/last_change"
INTERVAL_LIMIT=$(( ${INTERVAL_MIN:-150} * 60 ))

detect_environment() {
    local de="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:-}${DESKTOP_SESSION:-}"
    de="${de,,}"
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
            elif pgrep -x plasmashell  &>/dev/null; then echo kde
            elif pgrep -x xfce4-session &>/dev/null; then echo xfce
            elif pgrep -x lxqt-session  &>/dev/null; then echo lxqt
            elif pgrep -x lxsession     &>/dev/null; then echo lxde
            elif pgrep -x sway          &>/dev/null; then echo sway
            elif pgrep -x Hyprland      &>/dev/null; then echo hyprland
            else echo unknown; fi
            ;;
    esac
}

set_wallpaper() {
    local img="$1" env applied=1
    env="$(detect_environment)"
    case "$env" in
        gnome|budgie)
            if command -v gsettings &>/dev/null; then
                gsettings set org.gnome.desktop.background picture-options "zoom" 2>/dev/null || true
                gsettings set org.gnome.desktop.background picture-uri "file://$img" 2>/dev/null && applied=0
                gsettings set org.gnome.desktop.background picture-uri-dark "file://$img" 2>/dev/null || true
            fi ;;
        cinnamon)
            command -v gsettings &>/dev/null && \
                gsettings set org.cinnamon.desktop.background picture-uri "file://$img" 2>/dev/null && applied=0 ;;
        mate)
            command -v gsettings &>/dev/null && \
                gsettings set org.mate.background picture-filename "$img" 2>/dev/null && applied=0 ;;
        deepin)
            command -v gsettings &>/dev/null && \
                gsettings set com.deepin.wrap.gnome.desktop.background picture-uri "file://$img" 2>/dev/null && applied=0 ;;
        kde)
            if command -v qdbus &>/dev/null || command -v qdbus6 &>/dev/null; then
                local qd; qd="$(command -v qdbus || command -v qdbus6)"
                "$qd" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
                    "var allDesktops = desktops();
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
            command -v pcmanfm-qt &>/dev/null && \
                pcmanfm-qt --set-wallpaper "$img" --wallpaper-mode=zoom 2>/dev/null && applied=0 ;;
        lxde)
            command -v pcmanfm &>/dev/null && \
                pcmanfm --set-wallpaper "$img" --wallpaper-mode=fit 2>/dev/null && applied=0 ;;
        sway)
            command -v swaymsg &>/dev/null && \
                swaymsg "output * bg '$img' fill" &>/dev/null && applied=0 ;;
        hyprland)
            if command -v hyprctl &>/dev/null && pgrep -x hyprpaper &>/dev/null; then
                hyprctl hyprpaper preload "$img" &>/dev/null && \
                hyprctl hyprpaper wallpaper ",$img" &>/dev/null && applied=0
            fi ;;
    esac
    if [[ $applied -ne 0 ]]; then
        if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
            if command -v swww &>/dev/null; then
                if ! pgrep -x swww-daemon &>/dev/null; then
                    (setsid swww-daemon &>/dev/null &)
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
        # Record successful update time
        date +%s > "$LAST_CHANGE_FILE" 2>/dev/null || true
        systemctl --user restart spotlight.timer lockscreen.timer 2>/dev/null || true
        return 0
    else
        log warning "Could not apply wallpaper (env: $env, session: ${XDG_SESSION_TYPE:-unknown}) — image saved at $img"
        [[ -t 1 ]] && echo "⚠ Could not apply to desktop (detected env: $env, session: ${XDG_SESSION_TYPE:-unknown}) — image saved at $img" >&2
        return 1
    fi
}

detect_screen_size() {
    SCREEN_W=0; SCREEN_H=0
    local out=""
    if [[ -n "${DISPLAY:-}" ]] && command -v xrandr &>/dev/null; then
        out="$(xrandr --current 2>/dev/null | sed -n 's/.* connected.* \([0-9]\+\)x\([0-9]\+\)+.*/\1 \2/p' | sort -rn | head -1)" || true
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && [[ -n "${DISPLAY:-}" ]] && command -v xdpyinfo &>/dev/null; then
        out="$(xdpyinfo 2>/dev/null | sed -n 's/.*dimensions:[[:space:]]*\([0-9]\+\)x\([0-9]\+\) pixels.*/\1 \2/p' | head -1)" || true
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wlr-randr &>/dev/null; then
        out="$(wlr-randr 2>/dev/null | sed -n 's/^[[:space:]]*\([0-9]\+\)x\([0-9]\+\).*/\1 \2/p' | sort -rn | head -1)" || true
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v swaymsg &>/dev/null; then
        out="$(swaymsg -t get_outputs 2>/dev/null | jq -r '.[] | select(.active) | "\(.current_mode.width) \(.current_mode.height)"' 2>/dev/null | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v hyprctl &>/dev/null; then
        out="$(hyprctl monitors -j 2>/dev/null | jq -r '.[0] | "\(.width) \(.height)"' 2>/dev/null)"
        [[ "$out" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )); then
        local f
        for f in /sys/class/drm/*/modes; do
            [[ -r "$f" ]] || continue
            out="$(head -1 "$f" 2>/dev/null | sed -n 's/^\([0-9]\+\)x\([0-9]\+\).*/\1 \2/p')" || true
            if [[ -n "$out" ]]; then read -r SCREEN_W SCREEN_H <<< "$out"; break; fi
        done
    fi
    if (( SCREEN_W < 640 || SCREEN_H < 480 )); then
        SCREEN_W=1920; SCREEN_H=1080
    fi
}

detect_screen_size

REQ_W=$(( SCREEN_W > 3840 ? SCREEN_W : 3840 ))
REQ_H=$(( SCREEN_H > 2160 ? SCREEN_H : 2160 ))
[[ -z "$MIN_WIDTH" ]] && MIN_WIDTH=$(( SCREEN_W < 1280 ? 1280 : SCREEN_W ))
[[ -z "$MIN_HEIGHT" ]] && MIN_HEIGHT=$(( SCREEN_H < 720 ? 720 : SCREEN_H ))
WALLHAVEN_API="https://wallhaven.cc/api/v1/search?sorting=toplist&topRange=1d&atleast=${MIN_WIDTH}x${MIN_HEIGHT}&ratios=landscape&purity=100&categories=101"

dir_size_mb() {
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
        rm -f "$f" && ((removed++))
        used="$(dir_size_mb "$ARCHIVE_PATH")"
        (( used <= target )) && break
    done < <(find "$ARCHIVE_PATH" -maxdepth 1 -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
    (( removed > 0 )) && log info "Archive pruned: removed $removed old images (now ${used}MB / limit ${LIMIT_MB}MB)"
    return 0
}

if [[ "$DO_CLEAN" == "1" ]]; then
    removed=0; kept=0
    current="$(readlink "$SPOTLIGHT_PATH/background.jpg" 2>/dev/null || true)"
    for f in "$BACKGROUNDS_PATH"/* "$ARCHIVE_PATH"/*; do
        [[ -f "$f" ]] || continue
        if ! meets_min_resolution "$f"; then
            res="$(image_resolution "$f")"
            echo "Removing low-res (${res:-unknown}): $(basename "$f")"
            rm -f "$f"
            ((removed++))
            [[ "$f" == "$current" ]] && rm -f "$SPOTLIGHT_PATH/background.jpg"
        else
            ((kept++))
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
        row="$(jq -r '[.ad.landscapeImage.asset // "", .ad.title // "Spotlight", .ad.description // "", .ad.ctaUri // ""] | @tsv' <<< "$response" 2>/dev/null)" || continue
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
    fail "Spotlight: no unseen image after 4 attempts"
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
    fail "Bing: all 8 archive images already used"
}

fetch_nasa() {
    local response row cand t expl d
    response="$(fetch "$NASA_API")" || response=""
    if [[ -n "${response:-}" ]]; then
        row="$(jq -r 'select(.media_type == "image") | [(.hdurl // .url // ""), .title // "NASA APOD", .explanation // ""] | @tsv' <<< "$response" 2>/dev/null)" || row=""
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
    local -a rows
    mapfile -t rows < <(jq -r '.[] | select(.media_type == "image") | [(.hdurl // .url // ""), .title, .explanation, .date // ""] | @tsv' <<< "$response" 2>/dev/null)
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
    fail "NASA: no unseen image in random batch"
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
    fail "Wallhaven: all toplist images already used"
}

fetch_picsum() {
    local page response rows row id author purl width height attempt
    for attempt in 1 2 3; do
        page=$((RANDOM % 10 + 1))
        response="$(fetch "$PICSUM_LIST_API?page=$page&limit=100")" || continue
        mapfile -t rows < <(jq -r --argjson mw "$MIN_WIDTH" --argjson mh "$MIN_HEIGHT" '.[] | select(.width >= $mw and .height >= $mh) | [.id, .author, .url] | @tsv' <<< "$response" 2>/dev/null | shuf)
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
    fail "Picsum: no unseen image found"
}

SCI_QUERIES=("supercomputer" "quantum computer" "research laboratory" "particle accelerator" "space telescope" "mars rover" "robotics research" "data center" "microscope science" "satellite technology")
WILD_QUERIES=("wildlife sanctuary" "national park wildlife" "bird sanctuary" "tiger reserve" "elephant herd" "forest wildlife" "safari animals" "nature reserve" "mountain wildlife" "wetland birds")

rand_of() {
    local -n _a=$1
    echo "${_a[RANDOM % ${#_a[@]}]}"
}

urlenc() {
    printf '%s' "$1" | sed 's/ /%20/g'
}

fetch_nasaimg() {
    local q r rows row nid t d cand
    q="$(urlenc "$(rand_of SCI_QUERIES)")"
    r="$(fetch "https://images-api.nasa.gov/search?q=$q&media_type=image&page_size=40")" || fail "NASA image library request failed" || return 1
    mapfile -t rows < <(jq -r '.collection.items[] | [.data[0].nasa_id, .data[0].title, (.data[0].description // "")[0:200]] | @tsv' <<< "$r" 2>/dev/null | shuf | head -12)
    (( ${#rows[@]} > 0 )) || fail "NASA library: no results" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r nid t d <<< "$row"
        [[ -n "$nid" ]] || continue
        cand="$(fetch "https://images-api.nasa.gov/asset/$nid" 2>/dev/null | jq -r '.collection.items[].href' 2>/dev/null | grep -Ei '~(orig|large)\.(jpg|jpeg|png)$' | head -1)"
        cand="${cand/http:\/\//https:\/\/}"
        [[ -n "$cand" ]] || continue
        if ! seen_url "$cand"; then
            imageUrl="$cand"; title="$t"; description="$d"
            url="https://images.nasa.gov/details/$nid"
            return 0
        fi
    done
    fail "NASA library: no unseen image"
}

fetch_wiki_common() {
    local q r rows row tu tw th pt du
    q="$(urlenc "filetype:bitmap $1")"
    r="$(fetch "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=$q&gsrnamespace=6&gsrlimit=30&prop=imageinfo&iiprop=url%7Csize&iiurlwidth=$REQ_W&format=json")" || fail "Wikimedia request failed" || return 1
    mapfile -t rows < <(jq -r '.query.pages | to_entries[] | .value | [(.imageinfo[0].thumburl // ""), (.imageinfo[0].thumbwidth // 0), (.imageinfo[0].thumbheight // 0), (.title // "" | sub("^File:";"") | sub("\\.[a-zA-Z]+$";"")), (.imageinfo[0].descriptionurl // "")] | @tsv' <<< "$r" 2>/dev/null | shuf)
    (( ${#rows[@]} > 0 )) || fail "Wikimedia: no results" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r tu tw th pt du <<< "$row"
        [[ -n "$tu" ]] || continue
        (( tw >= MIN_WIDTH && th >= MIN_HEIGHT )) || continue
        if ! seen_url "$tu"; then
            imageUrl="$tu"; title="$pt"; description="From Wikimedia Commons"
            url="$du"
            return 0
        fi
    done
    fail "Wikimedia: no unseen hi-res image"
}

fetch_wikisci()   { fetch_wiki_common "$(rand_of SCI_QUERIES)"; }
fetch_wikitiger() { fetch_wiki_common "$(rand_of WILD_QUERIES)"; }
fetch_wikifp()    { fetch_wikitiger; }
fetch_wikiwild()  { fetch_wikitiger; }

fetch_ov_common() {
    local q r rows row iu w h t cu
    q="$(urlenc "$1")"
    r="$(fetch "https://api.openverse.org/v1/images/?q=$q&page_size=20&size=large&license_type=commercial")" || fail "Openverse request failed" || return 1
    mapfile -t rows < <(jq -r '.results[] | [(.url // ""), (.width // 0), (.height // 0), (.title // "Openverse image"), (.foreign_landing_url // "")] | @tsv' <<< "$r" 2>/dev/null | shuf)
    (( ${#rows[@]} > 0 )) || fail "Openverse: no results" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r iu w h t cu <<< "$row"
        [[ -n "$iu" ]] || continue
        (( w >= MIN_WIDTH && h >= MIN_HEIGHT )) || continue
        if ! seen_url "$iu"; then
            imageUrl="$iu"; title="$t"; description="Via Openverse"
            url="$cu"
            return 0
        fi
    done
    fail "Openverse: no unseen hi-res image"
}

fetch_ovsci()  { fetch_ov_common "$(rand_of SCI_QUERIES)"; }
fetch_ovwild() { fetch_ov_common "$(rand_of WILD_QUERIES)"; }

WH_TECH_TERMS=(technology computer circuit server code cyberpunk laboratory space satellite robot)
WH_WILD_TERMS=(wildlife animal bird tiger elephant forest deer wolf eagle safari)

fetch_wh_common() {
    local q r rows row p wid wurl
    q="$(urlenc "$1")"
    r="$(fetch "https://wallhaven.cc/api/v1/search?q=$q&sorting=favorites&atleast=${MIN_WIDTH}x${MIN_HEIGHT}&ratios=landscape&purity=100&categories=101")" || fail "Wallhaven search failed" || return 1
    mapfile -t rows < <(jq -r '.data[] | [.path, .id, .url] | @tsv' <<< "$r" 2>/dev/null | shuf)
    (( ${#rows[@]} > 0 )) || fail "Wallhaven: no results" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r p wid wurl <<< "$row"
        [[ -n "$p" ]] || continue
        if ! seen_url "$p"; then
            imageUrl="$p"; title="Wallhaven $wid"; description="Curated $1 wallpaper"
            url="$wurl"
            return 0
        fi
    done
    fail "Wallhaven: all results already used"
}

fetch_whtech() { fetch_wh_common "$(rand_of WH_TECH_TERMS)"; }
fetch_whwild() { fetch_wh_common "$(rand_of WH_WILD_TERMS)"; }

INAT_TAXA=(3 40151 26036 20978 47119)

fetch_inat() {
    local taxon page r rows row pu w h t ou cand
    taxon="${INAT_TAXA[RANDOM % ${#INAT_TAXA[@]}]}"
    page=$((RANDOM % 5 + 1))
    r="$(fetch "https://api.inaturalist.org/v1/observations?photos=true&quality_grade=research&per_page=50&page=$page&order_by=votes&taxon_id=$taxon&photo_license=cc0,cc-by,cc-by-nc")" || fail "iNaturalist request failed" || return 1
    mapfile -t rows < <(jq -r '.results[] | select(.photos[0].original_dimensions != null) | [(.photos[0].url // ""), (.photos[0].original_dimensions.width // 0), (.photos[0].original_dimensions.height // 0), (.taxon.preferred_common_name // .species_guess // "Wildlife"), (.uri // "")] | @tsv' <<< "$r" 2>/dev/null | shuf)
    (( ${#rows[@]} > 0 )) || fail "iNaturalist: no results" || return 1
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r pu w h t ou <<< "$row"
        [[ -n "$pu" ]] || continue
        (( w >= MIN_WIDTH && h >= MIN_HEIGHT )) || continue
        cand="${pu/square/original}"
        if ! seen_url "$cand"; then
            imageUrl="$cand"; title="$t"; description="Research-grade wildlife photo via iNaturalist"
            url="$ou"
            return 0
        fi
    done
    fail "iNaturalist: no unseen hi-res photo"
}

try_source() {
    local src="$1"
    imageUrl="" title="" description="" url=""
    "fetch_$src" || return 1
    if [[ -z "$imageUrl" ]]; then
        log warning "No image URL found (source: $src)"
        return 1
    fi
    if [[ ! "$imageUrl" =~ ^https:// ]]; then
        log warning "Rejected non-https image URL (source: $src)"
        return 1
    fi
    if seen_url "$imageUrl"; then
        log notice "Image already used before, skipping (source: $src)"
        return 1
    fi
    local safeTitle timestamp
    safeTitle="$(echo "$title" | tr -cd '[:alnum:] *-' | tr ' ' '*' | cut -c1-60)"
    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
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
        badres="$(image_resolution "$imagePath")"
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

net_ok() {
    if [[ "$HTTP_TOOL" == "curl" ]]; then
        curl -fsI -m 5 https://www.bing.com >/dev/null 2>&1 && return 0
        curl -fsI -m 5 https://picsum.photos >/dev/null 2>&1 && return 0
    else
        wget -q --spider -T 5 -t 1 https://www.bing.com >/dev/null 2>&1 && return 0
        wget -q --spider -T 5 -t 1 https://picsum.photos >/dev/null 2>&1 && return 0
    fi
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1
}

if [[ "$WAIT_NET" == "1" ]] && ! net_ok; then
    log info "No internet — waiting for connection"
    [[ -t 1 ]] && echo "Waiting for internet connection..."
    until net_ok; do sleep 10; done
    log info "Internet detected — fetching wallpaper"
    [[ -t 1 ]] && echo "Internet detected — fetching wallpaper."
fi

# Real detection logic for bootup/updates:
# If system has just booted up (uptime < 5 minutes), we ALWAYS bypass elapsed limit and change it!
uptime_sec=99999
[[ -f /proc/uptime ]] && uptime_sec="$(cut -d. -f1 /proc/uptime)"
if (( uptime_sec < 300 )); then
    FORCE=1
fi

if [[ "$DO_PREDOWNLOAD" == "1" ]]; then
    FORCE=1
fi

if [[ "$FORCE" == "0" && -f "$LAST_CHANGE_FILE" && -f "$SPOTLIGHT_PATH/background.jpg" ]]; then
    last_time="$(cat "$LAST_CHANGE_FILE" 2>/dev/null || echo 0)"
    if [[ "$last_time" =~ ^[0-9]+$ ]]; then
        now="$(date +%s)"
        elapsed=$(( now - last_time ))
        if (( elapsed < INTERVAL_LIMIT && elapsed >= 0 )); then
            log info "Interval not elapsed yet (${elapsed}s / ${INTERVAL_LIMIT}s). Re-applying current desktop wallpaper."
            if set_wallpaper "$SPOTLIGHT_PATH/background.jpg"; then
                RUN_OK=1
                exit 0
            fi
        fi
    fi
fi

# Instant apply of the wallpaper predownloaded at boot (before login).
# Runs even when FORCE=1 (uptime-based boot force) — the predownload itself
# already did the "fresh at boot" job, so the session just applies it.
if [[ -f "$SPOTLIGHT_PATH/predownloaded" && -f "$SPOTLIGHT_PATH/background.jpg" \
      && -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    _pm="$(stat -c %Y "$SPOTLIGHT_PATH/predownloaded" 2>/dev/null || echo 0)"
    if (( $(date +%s) - _pm <= INTERVAL_LIMIT )); then
        log info "Applying wallpaper predownloaded at boot — instantly."
        rm -f "$SPOTLIGHT_PATH/predownloaded"
        if set_wallpaper "$SPOTLIGHT_PATH/background.jpg"; then
            ensure_dbus_session && notify "Wallpaper Updated" "Wallpaper predownloaded at boot — applied now."
            RUN_OK=1
            exit 0
        fi
    else
        rm -f "$SPOTLIGHT_PATH/predownloaded"
        log notice "Boot predownload too old — fetching fresh wallpaper."
    fi
fi

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

previousImagePath="$(readlink "$SPOTLIGHT_PATH/background.jpg" 2>/dev/null || true)"
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

if [[ "$DO_PREDOWNLOAD" == "1" ]]; then
    date +%s > "$LAST_CHANGE_FILE" 2>/dev/null || true
    touch "$SPOTLIGHT_PATH/predownloaded" 2>/dev/null || true
    resolution="$(image_resolution "$imagePath")"
    echo "✔ Predownloaded for login: $imagePath (${resolution:-?})"
    log info "Predownloaded at boot [$SOURCE]: $title (${resolution:-?})"
    RUN_OK=1
    exit 0
fi

rm -f "$SPOTLIGHT_PATH/predownloaded" 2>/dev/null || true

ensure_dbus_session || true
export GSETTINGS_BACKEND=dconf

set_wallpaper "$imagePath" || true

resolution="$(image_resolution "$imagePath")"
fileSize="$(du -h "$imagePath" | cut -f1)"

ensure_dbus_session && get_notify_capabilities >/dev/null || true

blurb="$title"
read -ra titleWords <<< "$title"
if (( ${#titleWords[@]} < 5 )) && [[ -n "$description" && "$description" != "$title" ]]; then
    need=$(( 8 - ${#titleWords[@]} ))
    blurb+=" · $(truncate_words "$description" "$need")"
fi

body="$blurb"
if [[ -n "$url" ]] && ! notify_supports_actions; then
    if notify_supports_hyperlinks; then
        body+=$'\n\n'" [ <a href=\"$url\"><u>view</u></a> ]"
    else
        domain="$(sed -E 's|^[a-z]+://([^/]+).*|\1|; s|^www\.||' <<< "$url")"
        body+=$'\n\n'" [ credit: ${domain} ]"
    fi
fi

notify "Wallpaper Updated" "$body" "$url"

log info "Wallpaper updated [$SOURCE]: $title | ${resolution:-?} $fileSize | screen ${SCREEN_W}x${SCREEN_H} | $url"
[[ -t 1 ]] && echo "✔ Wallpaper updated [$SOURCE]: $title (${resolution:-?}, $fileSize)"

RUN_OK=1
