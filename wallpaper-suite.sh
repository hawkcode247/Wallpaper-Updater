#!/usr/bin/env bash

set -uo pipefail

APP_TITLE="Wallpaper Suite"

VERSION="2026-08-01"

# Changed payload hash: forces re-extraction of the fixed payloads on
# machines that already have the older (broken) extraction marker.
PAYLOAD_HASH="3e8b21c5f0d9a647"

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

DEBUG=0; [[ "${1:-}" == "--debug" ]] && { DEBUG=1; shift; }

HAVE_TTY=0; [[ -t 0 && -t 1 ]] && HAVE_TTY=1

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper-suite"

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=/tmp

LOG="$LOG_DIR/suite.log"

# ---------- single instance: refuse to open twice, show PID of the running one ----------

SUITE_LOCK="$LOG_DIR/suite.pid"

if [[ -f "$SUITE_LOCK" ]]; then
    OLD_PID="$(cat "$SUITE_LOCK" 2>/dev/null)"
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null \
       && grep -qE 'bash|wallpaper' "/proc/$OLD_PID/comm" 2>/dev/null; then
        MSG="Wallpaper Suite is already running (PID $OLD_PID).\n\nClose that window first, or stop it with:\n  kill $OLD_PID"
        if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v zenity &>/dev/null; then
            zenity --warning --title="Wallpaper Suite" --width=380 --text="$MSG" 2>/dev/null
        elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v kdialog &>/dev/null; then
            kdialog --title "Wallpaper Suite" --sorry "$(printf '%b' "$MSG")" 2>/dev/null
        else
            printf 'Already running (PID %s). Stop it with: kill %s\n' "$OLD_PID" "$OLD_PID" >&2
        fi
        exit 0
    fi
    rm -f "$SUITE_LOCK"   # stale lock from a crashed/finished run
fi

echo $$ > "$SUITE_LOCK"

trap 'rm -f "$SUITE_LOCK"' EXIT
trap 'rm -f "$SUITE_LOCK"; exit 130' INT TERM

dlog(){ printf '%s %s\n' "$(date '+%T')" "$*" >>"$LOG" 2>/dev/null; [[ $DEBUG -eq 1 ]] && printf 'DBG %s\n' "$*" >&2; return 0; }

trap 'rc=$?; [[ $rc -ne 0 ]] && dlog "ERR rc=$rc line=$LINENO: $BASH_COMMAND"' ERR

if [[ -f "$SELF" && ! -x "$SELF" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        read -rp "Make $(basename "$SELF") executable? [Y/n]: " _a || _a=""
        [[ ! "${_a,,}" =~ ^n ]] && chmod +x "$SELF" 2>/dev/null
    else chmod +x "$SELF" 2>/dev/null || true; fi
fi

GUI=""
if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    if command -v zenity &>/dev/null; then GUI=zenity
    elif command -v kdialog &>/dev/null; then GUI=kdialog
    elif command -v yad &>/dev/null; then GUI=yad; fi
fi

if [[ -z "$GUI" && -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && -t 0 ]]; then
    read -rp "Install zenity for GUI dialogs? [Y/n]: " _a || _a=""
    if [[ ! "${_a,,}" =~ ^n ]]; then
        { command -v apt-get &>/dev/null && sudo apt-get install -y zenity; } ||
        { command -v dnf &>/dev/null && sudo dnf install -y zenity; } ||
        { command -v pacman &>/dev/null && sudo pacman -S --noconfirm zenity; } ||
        { command -v zypper &>/dev/null && sudo zypper install -y zenity; } || true
        command -v zenity &>/dev/null && GUI=zenity
    fi
fi

# ---------- silent-launch guard ----------
# No GUI dialog tool + no terminal + no command = an invisible, useless run
# (double-click from the file manager). Fail loudly instead of doing nothing.
if [[ -z "$GUI" && "$HAVE_TTY" == "0" && $# -eq 0 ]]; then
    MSG="Wallpaper Suite needs a dialog tool (zenity/kdialog/yad) when launched without a terminal.\n\nRun it from a terminal instead:\n  $0\n\nor install zenity and try again:\n  sudo apt install zenity   (or your distro's equivalent)"
    if command -v notify-send &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        notify-send -u critical "Wallpaper Suite" "$(printf '%b' "$MSG")" 2>/dev/null
    fi
    printf '%b\n' "$MSG" >&2
    exit 1
fi

CENTER_STARTED=0

center(){
    [[ $CENTER_STARTED -eq 1 ]] && return 0
    [[ -n "${DISPLAY:-}" ]] && command -v xdotool &>/dev/null || { CENTER_STARTED=1; return 0; }
    CENTER_STARTED=1
    (
        read -r SW SH < <(xdotool getdisplaygeometry 2>/dev/null)
        [[ -n "${SW:-}" ]] || exit 0
        LAST=""
        while kill -0 $$ 2>/dev/null; do
            W="$(xdotool search --name "^${APP_TITLE}" 2>/dev/null | tail -1)"
            if [[ -n "$W" && "$W" != "$LAST" ]]; then
                eval "$(xdotool getwindowgeometry --shell "$W" 2>/dev/null | grep -E '^(WIDTH|HEIGHT)=')"
                [[ -n "${WIDTH:-}" ]] && xdotool windowmove "$W" $(((SW-WIDTH)/2)) $(((SH-HEIGHT)/2)) 2>/dev/null
                LAST="$W"
            fi
            sleep 0.03
        done
    ) &>/dev/null &
    disown 2>/dev/null || true
}

ui_info(){ center; case "$GUI" in
    zenity) zenity --info --title="$APP_TITLE" --width=440 --text="$1" 2>/dev/null;;
    kdialog) kdialog --title "$APP_TITLE" --msgbox "$1" 2>/dev/null;;
    yad) yad --title="$APP_TITLE" --center --width=440 --text="$1" --button=OK 2>/dev/null;;
    *) printf '\n%b\n' "$1";; esac; }

ui_err(){ dlog "UIERR: $1"; center; case "$GUI" in
    zenity) zenity --error --title="$APP_TITLE" --width=440 --text="$1" 2>/dev/null;;
    kdialog) kdialog --title "$APP_TITLE" --error "$1" 2>/dev/null;;
    yad) yad --title="$APP_TITLE" --center --image=dialog-error --width=440 --text="$1" --button=OK 2>/dev/null;;
    *) printf '\nERROR: %b\n' "$1" >&2;; esac; }

ui_ask(){ center; case "$GUI" in
    zenity) zenity --question --title="$APP_TITLE" --width=440 --text="$1" 2>/dev/null;;
    kdialog) kdialog --title "$APP_TITLE" --yesno "$1" 2>/dev/null;;
    yad) yad --title="$APP_TITLE" --center --width=440 --text="$1" --button=Yes:0 --button=No:1 2>/dev/null;;
    *) local a=""; printf '%b' "$1" >&2; read -rp " [Y/n]: " a || a=""; a="${a//$'\r'/}"; [[ ! "${a,,}" =~ ^n ]];; esac; }

ui_pick(){ local text="$1" def="$2"; shift 2; center; case "$GUI" in
    zenity) local a=() t l o
        while (($#)); do t="$1"; l="$2"; shift 2; o=FALSE; [[ "$t" == "$def" ]] && o=TRUE; a+=("$o" "$t" "$l"); done
        zenity --list --radiolist --title="$APP_TITLE" --width=520 --height=340 --text="$text" \
            --column= --column= --column= --hide-header --hide-column=2 --print-column=2 "${a[@]}" 2>/dev/null;;
    kdialog) local a=() t l o
        while (($#)); do t="$1"; l="$2"; shift 2; o=off; [[ "$t" == "$def" ]] && o=on; a+=("$t" "$l" "$o"); done
        kdialog --title "$APP_TITLE" --radiolist "$text" "${a[@]}" 2>/dev/null;;
    yad) local a=() t l o
        while (($#)); do t="$1"; l="$2"; shift 2; o=FALSE; [[ "$t" == "$def" ]] && o=TRUE; a+=("$o" "$t" "$l"); done
        yad --list --radiolist --title="$APP_TITLE" --center --width=520 --height=340 --text="$text" \
            --column= --column= --column= "${a[@]}" 2>/dev/null | cut -d'|' -f2;;
    *) printf '\n%b\n' "$(sed -E 's/<[^>]+>//g' <<<"$text")" >&2; local i=1 tags=() t l
        while (($#)); do t="$1"; l="$2"; shift 2; tags+=("$t"); printf '  %d) %s\n' "$i" "$l" >&2; i=$((i+1)); done
        local c=""; read -rp "Choose [1-${#tags[@]}]: " c || c=""; c="${c//$'\r'/}"
        if [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le ${#tags[@]} ]]; then echo "${tags[c-1]}"
        elif [[ -z "$c" ]]; then echo "$def"
        else echo ""; fi;; esac; }

ui_text(){ center; case "$GUI" in
    zenity) zenity --entry --title="$APP_TITLE" --width=440 --text="$1" --entry-text="$2" 2>/dev/null;;
    kdialog) kdialog --title "$APP_TITLE" --inputbox "$1" "$2" 2>/dev/null;;
    yad) yad --entry --title="$APP_TITLE" --center --width=440 --text="$1" --entry-text="$2" 2>/dev/null;;
    *) local v=""; read -rp "$1 [$2]: " v || v=""; v="${v//$'\r'/}"; echo "${v:-$2}";; esac; }

# Completely removed the hanging GUI progress bars. Now always executes natively with clean terminal spinners when run interactively!
ui_busy(){
    local label="$1"; shift
    dlog "RUN: $*"
    if [[ -t 1 ]]; then
        printf '... %s ' "$label"
        ( "$@" ) >>"$LOG" 2>&1 &
        local pid=$!
        local chars="/-\|"
        while kill -0 $pid 2>/dev/null; do
            for (( i=0; i<4; i++ )); do
                printf '\b%s' "${chars:i:1}"
                sleep 0.1
            done
        done
        wait $pid
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            printf '\b✔ Done!\n'
        else
            printf '\b✘ Failed!\n'
        fi
        return $rc
    else
        ( "$@" ) >>"$LOG" 2>&1
        return $?
    fi
}

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wallpaper"
SCRIPTS_DIR="$HOME/.spotlight"
TIMERS_DIR="$HOME/.spotlight-timers"
SYSD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_DST="$TIMERS_DIR"
HASH_MARK="$LOG_DIR/payload.hash"

extract(){

    if [[ -f "$HASH_MARK" && -f "$SCRIPTS_DIR/spotlight.sh" && -f "$SCRIPTS_DIR/lockscreen.sh" \
          && -f "$SCRIPTS_DIR/boot.sh" ]] \
       && [[ "$(cat "$HASH_MARK" 2>/dev/null)" == "$PAYLOAD_HASH" ]]; then
        dlog "payload unchanged — skip extraction"; return 0
    fi

    dlog "extracting payloads"

    mkdir -p "$SCRIPTS_DIR"

    # Write spotlight.sh directly as raw text using EOF_SPOTLIGHT to avoid inner heredoc termination!
    cat << 'EOF_SPOTLIGHT' > "$SCRIPTS_DIR/spotlight.sh"
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
EOF_SPOTLIGHT
    # Write lockscreen.sh directly as raw text using EOF_LOCKSCREEN to avoid inner heredoc termination!
    cat << 'EOF_LOCKSCREEN' > "$SCRIPTS_DIR/lockscreen.sh"
#!/usr/bin/env bash

if (return 0 2>/dev/null); then
    echo "lockscreen.sh: run it, don't source it (./lockscreen.sh)" >&2
    return 1
fi

set -euo pipefail

XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR:-}" ]]; then
    XDG_RUNTIME="$XDG_RUNTIME_DIR"
else
    XDG_RUNTIME="/tmp/lockscreen-$(id -u)"
    mkdir -p -m 700 "$XDG_RUNTIME" 2>/dev/null || XDG_RUNTIME="/tmp"
fi

APP_NAME="lockscreen"
USER_IMG_DIR="$XDG_DATA/$APP_NAME"
SYSTEM_IMG_DIR="${LOCKSCREEN_SYSTEM_DIR:-/usr/share/backgrounds}"

have_system_greeter() {
    command -v gdm3 &>/dev/null || command -v gdm &>/dev/null || \
    command -v sddm &>/dev/null || command -v lightdm &>/dev/null || \
    command -v lxdm &>/dev/null || \
    [[ -d /etc/gdm3 || -d /etc/gdm || -f /etc/sddm.conf || -d /etc/sddm.conf.d \
       || -d /etc/lightdm || -f /etc/lxdm/lxdm.conf ]]
}

if [[ "$(id -u)" -eq 0 ]] || have_system_greeter; then
    IMG_DIR="$SYSTEM_IMG_DIR"
else
    IMG_DIR="$USER_IMG_DIR"
fi

IMG_PATH="${LOCKSCREEN_IMAGE:-$IMG_DIR/$APP_NAME.jpg}"
TMP_IMG="$(mktemp -u "$XDG_RUNTIME/$APP_NAME-XXXXXX.jpg")"
USER_AGENT="WindowsShellClient/0"
LOCK_FILE="$XDG_RUNTIME/$APP_NAME-$(id -u).lock"
MIN_WIDTH="${LOCKSCREEN_MIN_WIDTH:-}"
MIN_HEIGHT="${LOCKSCREEN_MIN_HEIGHT:-}"
SOURCES=(spotlight bing nasa wallhaven picsum)
SOURCE="${LOCKSCREEN_SOURCE:-random}"
FALLBACK="${LOCKSCREEN_FALLBACK:-1}"
FORCE=0
INTERVAL_MIN="${LOCKSCREEN_INTERVAL_MIN:-240}"

SPOTLIGHT_API="https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&fmt=json&locale=en-US&country=US"
BING_API="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-US"
NASA_API="https://api.nasa.gov/planetary/apod?api_key=${NASA_API_KEY:-DEMO_KEY}&thumbs=true"
NASA_RANDOM_API="https://api.nasa.gov/planetary/apod?api_key=${NASA_API_KEY:-DEMO_KEY}&count=8&thumbs=true"
PICSUM_LIST_API="https://picsum.photos/v2/list"

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  next (default)   Fetch a new image and update the lock screen
  install          Guided install: permissions, greeter config, auto-update timer
  reinstall        Clean out and install again
  uninstall        Remove image, greeter config and timer

Options:
  -s, --source NAME   Pin a source: ${SOURCES[*]} | random
  -f, --force         Force an update bypassing the boot/elapsed check
  -n, --no-fallback   Fail instead of trying other sources
  -w, --wait-net      Wait for internet if offline
  -y, --yes           Assume "yes" on all prompts
  -h, --help          Show this help
EOF
}

CMD="next"
ASSUME_YES=0
WAIT_NET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        next|install|reinstall|uninstall) CMD="$1"; shift ;;
        -s|--source)    SOURCE="${2:?--source needs a value}"; shift 2 ;;
        -n|--no-fallback) FALLBACK=0; shift ;;
        -w|--wait-net)  WAIT_NET=1; shift ;;
        -f|--force)     FORCE=1; shift ;;
        -y|--yes)       ASSUME_YES=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$SOURCE" == "random" ]] && SOURCE="${SOURCES[RANDOM % ${#SOURCES[@]}]}"
case " ${SOURCES[*]} " in
    *" $SOURCE "*) ;;
    *) echo "Invalid source: $SOURCE" >&2; exit 1 ;;
esac

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

warn() { echo "lockscreen: $*" >&2; }

confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    [[ -t 0 ]] || return 0
    local a=""; read -rp "$1 [Y/n]: " a || a=""
    [[ ! "${a,,}" =~ ^n ]]
}

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        if [[ -t 0 ]]; then sudo "$@"
        else sudo -n "$@" 2>/dev/null; fi
    elif command -v pkexec &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        pkexec "$@"
    else
        return 1
    fi
}

if [[ -f "$SCRIPT_PATH" && ! -x "$SCRIPT_PATH" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        if confirm "  $(basename "$SCRIPT_PATH") is not executable. Add chmod +x now?"; then
            chmod +x "$SCRIPT_PATH" 2>/dev/null && echo "  ✔ Execute permission added." || \
                warn "could not chmod — try: sudo chmod +x $SCRIPT_PATH"
        fi
    else
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi
fi

detect_pkg_manager() {
    PM="" PM_INSTALL="" PM_REFRESH=""
    if   command -v apt-get      &>/dev/null; then PM=apt;       PM_INSTALL="apt-get install -y";        PM_REFRESH="apt-get update -qq"
    elif command -v dnf          &>/dev/null; then PM=dnf;       PM_INSTALL="dnf install -y"
    elif command -v yum          &>/dev/null; then PM=yum;       PM_INSTALL="yum install -y"
    elif command -v pacman       &>/dev/null; then PM=pacman;    PM_INSTALL="pacman -S --noconfirm";     PM_REFRESH="pacman -Sy"
    elif command -v zypper       &>/dev/null; then PM=zypper;    PM_INSTALL="zypper install -y"
    elif command -v apk          &>/dev/null; then PM=apk;       PM_INSTALL="apk add"
    elif command -v xbps-install &>/dev/null; then PM=xbps;      PM_INSTALL="xbps-install -y";           PM_REFRESH="xbps-install -S"
    elif command -v emerge       &>/dev/null; then PM=emerge;    PM_INSTALL="emerge --quiet"
    fi
    [[ -n "$PM" ]]
}

pkg_name_for() {
    local tool="$1"
    case "$tool" in
        jq|wget|curl|wlr-randr) echo "$tool" ;;
        identify)
            case "$PM" in
                dnf|yum|zypper) echo "ImageMagick" ;;
                *)              echo "imagemagick" ;;
            esac ;;
        glib-compile-resources)
            case "$PM" in
                apt)     echo "libglib2.0-dev-bin" ;;
                *)       echo "glib2-devel" ;;
            esac ;;
        xrandr)
            case "$PM" in
                apt)     echo "x11-xserver-utils" ;;
                pacman)  echo "xorg-xrandr" ;;
                *)       echo "xrandr" ;;
            esac ;;
        *) echo "$tool" ;;
    esac
}

collect_missing_deps() {
    MISSING_REQUIRED=() MISSING_OPTIONAL=()
    command -v jq &>/dev/null || MISSING_REQUIRED+=(jq)
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        MISSING_REQUIRED+=(curl)
    fi
    if [[ -n "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        command -v xrandr &>/dev/null || command -v xdpyinfo &>/dev/null || MISSING_OPTIONAL+=(xrandr)
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        command -v wlr-randr &>/dev/null || command -v swaymsg &>/dev/null || command -v hyprctl &>/dev/null || \
            command -v gsettings &>/dev/null || MISSING_OPTIONAL+=(wlr-randr)
    fi
    if ! command -v identify &>/dev/null && ! command -v file &>/dev/null; then
        MISSING_OPTIONAL+=(identify)
    fi
    if { command -v gdm3 &>/dev/null || command -v gdm &>/dev/null || [[ -d /etc/gdm3 || -d /etc/gdm ]]; } && \
       { ! command -v gresource &>/dev/null || ! command -v glib-compile-resources &>/dev/null; }; then
        MISSING_OPTIONAL+=(glib-compile-resources)
    fi
}

install_deps() {
    local tools=("$@") pkgs=() t
    for t in "${tools[@]}"; do pkgs+=("$(pkg_name_for "$t")"); done
    echo "  Installing via $PM: ${pkgs[*]}"
    if [[ -n "$PM_REFRESH" ]]; then
        as_root $PM_REFRESH >/dev/null 2>&1 || true
    fi
    as_root $PM_INSTALL "${pkgs[@]}" || return 1
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || { warn "'$t' still missing after install"; return 1; }
    done
    return 0
}

ensure_dependencies() {
    collect_missing_deps
    [[ ${#MISSING_REQUIRED[@]} -eq 0 && ${#MISSING_OPTIONAL[@]} -eq 0 ]] && return 0
    if ! detect_pkg_manager; then
        if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
            echo "Missing required tools: ${MISSING_REQUIRED[*]}" >&2
            echo "No supported package manager found — install them manually." >&2
            exit 1
        fi
        return 0
    fi
    if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
        echo "  This system needs: ${MISSING_REQUIRED[*]} (required)"
        if confirm "  Install now using $PM?"; then
            install_deps "${MISSING_REQUIRED[@]}" || {
                echo "Automatic install failed — install manually: ${MISSING_REQUIRED[*]}" >&2
                exit 1
            }
        else
            echo "Cannot continue without: ${MISSING_REQUIRED[*]}" >&2
            exit 1
        fi
    fi
    if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
        echo "  Recommended for this system: ${MISSING_OPTIONAL[*]}"
        echo "  (screen-size detection / image validation — script works without them)"
        if confirm "  Install recommended tools too?"; then
            install_deps "${MISSING_OPTIONAL[@]}" || warn "optional tools not installed — continuing with fallbacks"
        fi
    fi
}

ensure_dependencies

if   command -v wget &>/dev/null; then HTTP=wget
elif command -v curl &>/dev/null; then HTTP=curl
else echo "Missing dependency: wget or curl" >&2; exit 1; fi

fetch() {
    if [[ "$HTTP" == "wget" ]]; then
        wget -qO- -U "$USER_AGENT" --timeout=15 --tries=2 "$1"
    else
        curl -fsSL -A "$USER_AGENT" --max-time 15 --retry 1 "$1"
    fi
}

download() {
    if [[ "$HTTP" == "wget" ]]; then
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

if command -v flock &>/dev/null; then
    exec 9>"$LOCK_FILE" || true
    flock -n 9 || { warn "another run is in progress — skipping"; exit 0; }
fi

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
        out="$(swaymsg -t get_outputs 2>/dev/null | jq -r '.[]|select(.active)|"\(.current_mode.width) \(.current_mode.height)"' 2>/dev/null | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v hyprctl &>/dev/null; then
        out="$(hyprctl monitors -j 2>/dev/null | jq -r '.[0]|"\(.width) \(.height)"' 2>/dev/null)"
        [[ "$out" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )); then
        local f
        for f in /sys/class/drm/*/modes; do
            [[ -r "$f" ]] || continue
            out="$(head -1 "$f" 2>/dev/null | sed -n 's/^\([0-9]\+\)x\([0-9]\+\).*/\1 \2/p')" || true
            [[ -n "$out" ]] && { read -r SCREEN_W SCREEN_H <<< "$out"; break; }
        done
    fi
    (( SCREEN_W >= 640 && SCREEN_H >= 480 )) || { SCREEN_W=1920; SCREEN_H=1080; }
}

detect_screen_size

REQ_W=$(( SCREEN_W > 3840 ? SCREEN_W : 3840 ))
REQ_H=$(( SCREEN_H > 2160 ? SCREEN_H : 2160 ))
[[ -z "$MIN_WIDTH" ]] && MIN_WIDTH=$(( SCREEN_W < 1280 ? 1280 : SCREEN_W ))
[[ -z "$MIN_HEIGHT" ]] && MIN_HEIGHT=$(( SCREEN_H < 720  ? 720  : SCREEN_H ))
WALLHAVEN_API="https://wallhaven.cc/api/v1/search?sorting=toplist&topRange=1d&atleast=${MIN_WIDTH}x${MIN_HEIGHT}&ratios=landscape&purity=100&categories=101"

image_resolution() {
    local res=""
    command -v identify &>/dev/null && res="$(identify -format '%wx%h' "${1}[0]" 2>/dev/null || true)"
    [[ -z "$res" ]] && command -v file &>/dev/null && \
        res="$(file "$1" | grep -oE '[0-9]{2,5} ?x ?[0-9]{2,5}' | head -1 | tr -d ' ' || true)"
    printf '%s' "$res"
}

meets_min_resolution() {
    local res; res="$(image_resolution "$1")"
    [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]] || return 0
    (( BASH_REMATCH[1] >= MIN_WIDTH && BASH_REMATCH[2] >= MIN_HEIGHT ))
}

fetch_spotlight() {
    local r; r="$(fetch "$SPOTLIGHT_API")" || return 1
    imageUrl="$(jq -r '.ad.landscapeImage.asset // empty' <<< "$r")"
    [[ -n "$imageUrl" ]]
}

fetch_bing() {
    local r u; r="$(fetch "$BING_API")" || return 1
    u="$(jq -r '.images[0].urlbase // empty' <<< "$r")"
    [[ -n "$u" ]] && imageUrl="https://www.bing.com${u}_UHD.jpg"
    [[ -n "$imageUrl" ]]
}

fetch_nasa() {
    local r
    r="$(fetch "$NASA_API")" || r=""
    imageUrl="$(jq -r 'select(.media_type=="image") | (.hdurl // .url // empty)' <<< "$r" 2>/dev/null || true)"
    if [[ -z "$imageUrl" ]]; then
        r="$(fetch "$NASA_RANDOM_API")" || return 1
        imageUrl="$(jq -r '.[] | select(.media_type=="image") | (.hdurl // .url // empty)' <<< "$r" 2>/dev/null | head -1 || true)"
    fi
    [[ -n "$imageUrl" ]]
}

fetch_wallhaven() {
    local r; r="$(fetch "$WALLHAVEN_API")" || return 1
    imageUrl="$(jq -r '.data | if length>0 then .[("'$RANDOM'" % length)].path else empty end' <<< "$r" 2>/dev/null || true)"
    [[ -n "$imageUrl" ]]
}

fetch_picsum() {
    local page r id
    page=$((RANDOM % 10 + 1))
    r="$(fetch "$PICSUM_LIST_API?page=$page&limit=100")" || return 1
    id="$(jq -r --argjson mw "$MIN_WIDTH" --argjson mh "$MIN_HEIGHT" \
        '.[]|select(.width>=$mw and .height>=$mh).id' <<< "$r" 2>/dev/null | shuf | head -1)"
    [[ -n "$id" ]] && imageUrl="https://picsum.photos/id/$id/$REQ_W/$REQ_H"
    [[ -n "$imageUrl" ]]
}

try_source() {
    local src="$1"; imageUrl=""
    "fetch_$src" 2>/dev/null || { warn "source '$src' failed"; return 1; }
    [[ "$imageUrl" =~ ^https?:// ]] || { warn "rejected non-http URL ($src)"; return 1; }
    download "$imageUrl" "$TMP_IMG" || { rm -f "$TMP_IMG"; warn "download failed ($src)"; return 1; }
    [[ -s "$TMP_IMG" ]] || { rm -f "$TMP_IMG"; warn "empty download ($src)"; return 1; }
    meets_min_resolution "$TMP_IMG" || {
        warn "image too small ($src: $(image_resolution "$TMP_IMG") < ${MIN_WIDTH}x${MIN_HEIGHT})"
        rm -f "$TMP_IMG"; return 1
    }
    return 0
}

find_gdm_gresource() {
    local c
    if command -v update-alternatives &>/dev/null; then
        c="$(update-alternatives --query gdm-theme.gresource 2>/dev/null | sed -n 's/^Value: //p')"
        [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
    fi
    for c in /usr/share/gnome-shell/gdm-theme.gresource \
             /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource \
             /usr/share/gnome-shell/gnome-shell-theme.gresource \
             /usr/share/gnome-shell/theme/gnome-shell-theme.gresource \
             /usr/local/share/gnome-shell/gnome-shell-theme.gresource; do
        [[ -f "$c" ]] && { readlink -f "$c"; return 0; }
    done
    return 1
}

apply_gdm() {
    local img="$1" gres workdir themedir res xml css
    command -v gresource &>/dev/null || return 1
    command -v glib-compile-resources &>/dev/null || return 1
    gres="$(find_gdm_gresource)" || return 1
    if gresource extract "$gres" /org/gnome/shell/theme/gnome-shell.css 2>/dev/null | grep -qF "file://$img"; then
        return 0
    fi
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/$APP_NAME-gdm.XXXXXX")" || return 1
    themedir="$workdir/theme"
    mkdir -p "$themedir"
    local base="$gres"
    [[ -f "$gres.orig" ]] && base="$gres.orig"
    while IFS= read -r res; do
        local rel="${res#/org/gnome/shell/theme/}"
        mkdir -p "$themedir/$(dirname "$rel")"
        gresource extract "$base" "$res" > "$themedir/$rel" 2>/dev/null || { rm -rf "$workdir"; return 1; }
    done < <(gresource list "$base" 2>/dev/null)
    if ! ls "$themedir"/gnome-shell*.css &>/dev/null; then
        rm -rf "$workdir"; return 1
    fi
    for css in "$themedir"/gnome-shell*.css; do
        [[ -f "$css" ]] || continue
        sed -i "/\/\* $APP_NAME-begin \*\//,/\/\* $APP_NAME-end \*\//d" "$css"
        cat >> "$css" <<CSSEOF
/* $APP_NAME-begin */
#lockDialogGroup {
  background: #000000 url("file://$img");
  background-size: cover;
  background-position: center;
}
/* $APP_NAME-end */
CSSEOF
    done
    xml="$themedir/theme.gresource.xml"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<resources><gresource prefix="/org/gnome/shell/theme">'
        ( cd "$themedir" && find . -type f ! -name 'theme.gresource.xml' -printf '%P\n' ) | \
            while IFS= read -r f; do printf '    <file>%s</file>\n' "$f"; done
        echo '</gresource></resources>'
    } > "$xml"
    ( cd "$themedir" && glib-compile-resources theme.gresource.xml \
        --target="$workdir/new.gresource" --sourcedir=. ) 2>/dev/null || { rm -rf "$workdir"; return 1; }
    as_root bash -c "
        [[ -f '$gres.orig' ]] || cp -a '$gres' '$gres.orig'
        install -m 644 '$workdir/new.gresource' '$gres'
    " 2>/dev/null || { rm -rf "$workdir"; return 1; }
    rm -rf "$workdir"
    return 0
}

restore_gdm() {
    local gres
    gres="$(find_gdm_gresource)" || return 0
    [[ -f "$gres.orig" ]] || return 0
    as_root bash -c "mv -f '$gres.orig' '$gres'" 2>/dev/null || true
}

apply_lockscreen() {
    local img="$1"
    local ok=1
    local uri="file://$img"
    if command -v gsettings &>/dev/null; then
        gsettings set org.gnome.desktop.screensaver picture-options "zoom" 2>/dev/null || true
        gsettings set org.gnome.desktop.screensaver picture-uri "$uri" 2>/dev/null && ok=0 || true
        gsettings set org.cinnamon.desktop.background.slideshow slideshow-enabled false 2>/dev/null || true
        gsettings set org.cinnamon.desktop.screensaver background-color "#000000" 2>/dev/null || true
        gsettings set org.mate.screensaver picture-filename "$img" 2>/dev/null && ok=0 || true
        gsettings set com.deepin.dde.appearance greeter-background "$img" 2>/dev/null && ok=0 || true
    fi
    local kw
    for kw in kwriteconfig6 kwriteconfig5; do
        if command -v "$kw" &>/dev/null; then
            "$kw" --file kscreenlockerrc --group Greeter --group Wallpaper \
                  --group org.kde.image --group General --key Image "$uri" 2>/dev/null && ok=0
            break
        fi
    done
    if command -v swaylock &>/dev/null; then
        local sdir="$XDG_CONFIG/swaylock"
        mkdir -p "$sdir" 2>/dev/null || true
        if [[ -w "$sdir" || ! -e "$sdir/config" ]]; then
            if [[ ! -f "$sdir/config" ]] || grep -q "^image=" "$sdir/config" 2>/dev/null; then
                sed -i "s|^image=.*|image=$img|" "$sdir/config" 2>/dev/null || \
                    echo "image=$img" > "$sdir/config" 2>/dev/null || true
                grep -q "^image=" "$sdir/config" 2>/dev/null || echo "image=$img" >> "$sdir/config"
                ok=0
            else
                echo "image=$img" >> "$sdir/config" && ok=0
            fi
        fi
    fi
    if command -v hyprlock &>/dev/null; then
        local hconf="$XDG_CONFIG/hypr/hyprlock.conf"
        mkdir -p "$(dirname "$hconf")" 2>/dev/null || true
        if [[ -f "$hconf" ]] && grep -q "path *=" "$hconf" 2>/dev/null; then
            sed -i "0,/path *=.*/s||path = $img|" "$hconf" 2>/dev/null && ok=0 || true
        elif [[ ! -e "$hconf" ]]; then
            printf 'background {\n    path = %s\n    blur_passes = 2\n}\n' "$img" > "$hconf" 2>/dev/null && ok=0 || true
        fi
    fi
    if [[ -d /etc/lightdm ]] || command -v lightdm &>/dev/null; then
        local spec gconf gsec gname
        for spec in "lightdm-gtk-greeter.conf:greeter:lightdm-gtk-greeter" \
                    "slick-greeter.conf:Greeter:slick-greeter"; do
            IFS=: read -r gconf gsec gname <<< "$spec"
            if [[ -f "/etc/lightdm/$gconf" ]] || command -v "$gname" &>/dev/null \
               || [[ -f "/usr/share/xgreeters/$gname.desktop" ]]; then
                if as_root bash -c "
                    mkdir -p /etc/lightdm
                    conf='/etc/lightdm/$gconf'
                    [[ -f \"\$conf\" ]] || printf '[$gsec]\n' > \"\$conf\"
                    grep -q '^\[$gsec\]' \"\$conf\" || printf '\n[$gsec]\n' >> \"\$conf\"
                    if grep -q '^background=' \"\$conf\"; then
                        sed -i 's|^background=.*|background=$img|' \"\$conf\"
                    else
                        sed -i '/^\[$gsec\]/a background=$img' \"\$conf\"
                    fi
                    if [[ '$gname' == 'slick-greeter' ]]; then
                        if grep -q '^draw-user-backgrounds=' \"\$conf\"; then
                            sed -i 's|^draw-user-backgrounds=.*|draw-user-backgrounds=false|' \"\$conf\"
                        else
                            sed -i '/^\[$gsec\]/a draw-user-backgrounds=false' \"\$conf\"
                        fi
                    fi
                " 2>/dev/null; then ok=0; fi
            fi
        done
        if [[ -d /var/lib/AccountsService/users ]]; then
            local asvc_user; asvc_user="$(id -un)"
            as_root bash -c "
                f='/var/lib/AccountsService/users/$asvc_user'
                [[ -f \"\$f\" ]] || printf '[User]\n' > \"\$f\"
                if grep -q '^\[org.freedesktop.DisplayManager.AccountsService\]' \"\$f\"; then
                    if grep -q '^BackgroundFile=' \"\$f\"; then
                        sed -i 's|^BackgroundFile=.*|BackgroundFile=$img|' \"\$f\"
                    else
                        sed -i '/^\[org.freedesktop.DisplayManager.AccountsService\]/a BackgroundFile=$img' \"\$f\"
                    fi
                else
                    printf '\n[org.freedesktop.DisplayManager.AccountsService]\nBackgroundFile=%s\n' '$img' >> \"\$f\"
                fi
            " 2>/dev/null && ok=0 || true
        fi
    fi
    if [[ -f /etc/lxdm/lxdm.conf ]]; then
        as_root bash -c "
            grep -q '^bg=' /etc/lxdm/lxdm.conf \
                && sed -i 's|^bg=.*|bg=$img|' /etc/lxdm/lxdm.conf \
                || sed -i '/^\[display\]/a bg=$img' /etc/lxdm/lxdm.conf
        " 2>/dev/null && ok=0 || true
    fi
    if command -v gdm3 &>/dev/null || command -v gdm &>/dev/null || \
       [[ -d /etc/gdm3 || -d /etc/gdm ]]; then
        if apply_gdm "$img"; then
            ok=0
            [[ -t 1 ]] && echo "GDM login page patched — visible after reboot (or: sudo systemctl restart gdm3)"
        fi
    fi
    if [[ -d /etc/sddm.conf.d || -f /etc/sddm.conf ]] || command -v sddm &>/dev/null; then
        if as_root bash -c "
            theme_dir=\$(grep -rhs '^Current=' /etc/sddm.conf.d /etc/sddm.conf 2>/dev/null | head -1 | cut -d= -f2)
            [[ -n \"\$theme_dir\" ]] || exit 1
            t=\"/usr/share/sddm/themes/\$theme_dir\"
            [[ -d \"\$t\" ]] || exit 1
            o=\"\$t/theme.conf.user\"
            if [[ -f \"\$o\" ]] && grep -qF 'background=' \"\$o\" && grep -qF \"background='$img'\" \"\$o\"; then exit 0; fi
            if [[ -f \"\$o\" ]] && grep -q '^background=' \"\$o\"; then
                sed -i \"s|^background=.*|background='$img'|\" \"\$o\"
            elif [[ -f \"\$o\" ]]; then
                grep -q '^\\[General\\]' \"\$o\" || printf '[General]\n' >> \"\$o\"
                printf \"background='%s'\\n\" '$img' >> \"\$o\"
            else
                printf '[General]\nbackground=%s\n' \"'$img'\" > \"\$o\"
            fi
        " 2>/dev/null; then
            ok=0
        fi
    fi
    if command -v gsettings &>/dev/null; then
        gsettings set io.elementary.desktop.screensaver picture-uri "$uri" 2>/dev/null && ok=0 || true
    fi
    if command -v i3lock &>/dev/null || command -v xscreensaver &>/dev/null; then
        ok=0
    fi
    return $ok
}

SYSTEMD_USER_DIR="$XDG_CONFIG/systemd/user"

do_install() {
    printf '\n  Lock-screen Updater — Install\n\n'
    printf '  Image will live at:  %s\n' "$IMG_PATH"
    printf '  It is overwritten on every update (no copies kept).\n\n'
    confirm "  Proceed with install?" || { echo "  Cancelled."; exit 0; }
    mkdir -p "$IMG_DIR"
    if command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; then
        if confirm "  Enable automatic update every 6 hours?"; then
            mkdir -p "$SYSTEMD_USER_DIR"
            cat > "$SYSTEMD_USER_DIR/$APP_NAME.service" <<EOF
[Unit]
Description=Update lock-screen image

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH next
EOF
            cat > "$SYSTEMD_USER_DIR/$APP_NAME.timer" <<EOF
[Unit]
Description=Update lock-screen image periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
            systemctl --user daemon-reload 2>/dev/null || true
            systemctl --user enable --now "$APP_NAME.timer" 2>/dev/null \
                && echo "  ✔ Timer enabled ($APP_NAME.timer, every 6 h)" \
                || warn "could not enable timer (enable later: systemctl --user enable --now $APP_NAME.timer)"
        fi
    else
        echo "  ⚠ systemd user session not available — add a cron entry instead:"
        echo "      0 */6 * * * $SCRIPT_PATH next"
    fi
    echo "  ✔ Install done — fetching first lock-screen image..."
    run_update
}

do_uninstall() {
    printf '\n  Lock-screen Updater — Uninstall\n'
    printf '  Removes: image (%s),\n           timer units, swaylock/hyprlock entries it created.\n\n' "$IMG_PATH"
    confirm "  Proceed?" || { echo "  Cancelled."; exit 0; }
    if command -v systemctl &>/dev/null; then
        systemctl --user disable --now "$APP_NAME.timer" &>/dev/null || true
    fi
    rm -f "$SYSTEMD_USER_DIR/$APP_NAME.service" "$SYSTEMD_USER_DIR/$APP_NAME.timer" 2>/dev/null || true
    command -v systemctl &>/dev/null && systemctl --user daemon-reload 2>/dev/null || true
    restore_gdm
    rm -f "$IMG_PATH" 2>/dev/null || as_root rm -f "$IMG_PATH" 2>/dev/null || true
    rmdir "$USER_IMG_DIR" 2>/dev/null || true
    rm -f "$LOCK_FILE" 2>/dev/null || true
    if [[ -f "$XDG_CONFIG/swaylock/config" ]] && grep -qF "image=$IMG_PATH" "$XDG_CONFIG/swaylock/config" 2>/dev/null; then
        sed -i "\|image=$IMG_PATH|d" "$XDG_CONFIG/swaylock/config" 2>/dev/null || true
    fi
    echo "  ✔ Uninstalled. (Script file kept: $SCRIPT_PATH)"
    exit 0
}

do_reinstall() {
    ASSUME_YES_SAVED=$ASSUME_YES
    printf '\n  Lock-screen Updater — Reinstall\n\n'
    confirm "  Remove current setup and install fresh?" || { echo "  Cancelled."; exit 0; }
    ASSUME_YES=1
    command -v systemctl &>/dev/null && systemctl --user disable --now "$APP_NAME.timer" &>/dev/null || true
    rm -f "$SYSTEMD_USER_DIR/$APP_NAME.service" "$SYSTEMD_USER_DIR/$APP_NAME.timer" 2>/dev/null || true
    rm -f "$IMG_PATH" 2>/dev/null || as_root rm -f "$IMG_PATH" 2>/dev/null || true
    echo "  ✔ Old setup removed."
    ASSUME_YES=$ASSUME_YES_SAVED
    do_install
}

net_ok() {
    if [[ "$HTTP" == "curl" ]]; then
        curl -fsI -m 5 https://www.bing.com >/dev/null 2>&1 && return 0
        curl -fsI -m 5 https://picsum.photos >/dev/null 2>&1 && return 0
    else
        wget -q --spider -T 5 -t 1 https://www.bing.com >/dev/null 2>&1 && return 0
        wget -q --spider -T 5 -t 1 https://picsum.photos >/dev/null 2>&1 && return 0
    fi
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1
}

run_update() {
    trap 'rm -f "$TMP_IMG"' EXIT
    if [[ "$WAIT_NET" == "1" ]] && ! net_ok; then
        warn "no internet — waiting for connection"
        until net_ok; do sleep 10; done
        warn "internet detected — updating lock screen now"
    fi
    # Real detection logic for bootup/updates:
    # If system has just booted up (uptime < 5 minutes), we ALWAYS bypass elapsed limit and change it!
    uptime_sec=99999
    [[ -f /proc/uptime ]] && uptime_sec="$(cut -d. -f1 /proc/uptime)"
    if (( uptime_sec < 300 )); then
        FORCE=1
    fi
    LAST_CHANGE_FILE="$USER_IMG_DIR/last_change"
    # interval (minutes) — may come from $XDG_CONFIG/lockscreen/config
    if [[ -f "$XDG_CONFIG/lockscreen/config" ]]; then
        while IFS='=' read -r _k _v; do
            [[ "$_k" == "INTERVAL_MIN" && "$_v" =~ ^[0-9]+$ && "$_v" -ge 1 ]] && INTERVAL_MIN="$_v"
        done < "$XDG_CONFIG/lockscreen/config"
    fi
    INTERVAL_LIMIT=$(( INTERVAL_MIN * 60 )) # seconds
    if [[ "$FORCE" == "0" && -f "$LAST_CHANGE_FILE" && -f "$IMG_PATH" ]]; then
        last_time="$(cat "$LAST_CHANGE_FILE" 2>/dev/null || echo 0)"
        if [[ "$last_time" =~ ^[0-9]+$ ]]; then
            now="$(date +%s)"
            elapsed=$(( now - last_time ))
            if (( elapsed < INTERVAL_LIMIT && elapsed >= 0 )); then
                warn "Interval not elapsed yet (${elapsed}s / ${INTERVAL_LIMIT}s). Re-applying current lockscreen image."
                if apply_lockscreen "$IMG_PATH"; then
                    exit 0
                fi
            fi
        fi
    fi
    local order=("$SOURCE") rest=() s i j tmp
    if [[ "$FALLBACK" == "1" ]]; then
        for s in "${SOURCES[@]}"; do [[ "$s" != "$SOURCE" ]] && rest+=("$s"); done
        for ((i=${#rest[@]}-1; i>0; i--)); do
            j=$((RANDOM % (i+1)))
            tmp="${rest[i]}"; rest[i]="${rest[j]}"; rest[j]="$tmp"
        done
        order+=("${rest[@]}")
    fi
    local used=""
    for s in "${order[@]}"; do
        if try_source "$s"; then used="$s"; break; fi
    done
    [[ -n "$used" ]] || { echo "All sources failed (tried: ${order[*]})" >&2; exit 1; }
    mkdir -p "$IMG_DIR" 2>/dev/null || as_root mkdir -p "$IMG_DIR" || {
        echo "Cannot create $IMG_DIR" >&2; exit 1; }
    if [[ ! -e "$IMG_PATH" && -w "$IMG_DIR" ]]; then
        if command -v install &>/dev/null; then install -m 644 "$TMP_IMG" "$IMG_PATH"
        else cp "$TMP_IMG" "$IMG_PATH" && chmod 644 "$IMG_PATH"; fi
    elif [[ -e "$IMG_PATH" && -w "$IMG_PATH" && -w "$IMG_DIR" ]]; then
        if command -v install &>/dev/null; then install -m 644 "$TMP_IMG" "$IMG_PATH"
        else cp "$TMP_IMG" "$IMG_PATH.new" && chmod 644 "$IMG_PATH.new" && mv -f "$IMG_PATH.new" "$IMG_PATH"; fi
    elif [[ -e "$IMG_PATH" && -w "$IMG_PATH" ]]; then
        cp "$TMP_IMG" "$IMG_PATH"
    else
        local owner; owner="$(id -un)"
        as_root install -m 644 -o "$owner" "$TMP_IMG" "$IMG_PATH" || {
            echo "Cannot write $IMG_PATH (permission denied)" >&2; exit 1; }
    fi
    rm -f "$TMP_IMG"
    apply_lockscreen "$IMG_PATH" || warn "no known lock-screen mechanism found — image is ready at $IMG_PATH"
    echo "Lock screen updated [$used]: $IMG_PATH ($(image_resolution "$IMG_PATH"))"
    # Record successful update time
    mkdir -p "$(dirname "$LAST_CHANGE_FILE")" 2>/dev/null || true
    date +%s > "$LAST_CHANGE_FILE" 2>/dev/null || true
    systemctl --user restart lockscreen.timer spotlight.timer 2>/dev/null || true
}

case "$CMD" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    reinstall) do_reinstall ;;
    next)      run_update ;;
esac
EOF_LOCKSCREEN
    # Write boot.sh (system boot-time updater) directly as raw text
    cat << 'EOF_BOOT' > "$SCRIPTS_DIR/boot.sh"
#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wallpaper-boot.sh — system-level boot updater.
# Runs as root, BEFORE the display manager starts, AFTER the network manager
# is available:
#   1) waits (bounded) for the network
#   2) updates the login window / greeter image instantly
#   3) predownloads the user-session desktop wallpaper (applied at login)
#   4) syncs the boot lock image into the user's data dir + enables user timers
# Log: /var/log/wallpaper-boot.log
# ---------------------------------------------------------------------------
set -uo pipefail

LOG_FILE="${WALLPAPER_BOOT_LOG:-/var/log/wallpaper-boot.log}"
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

find_primary_user() {
    while IFS=: read -r _u _x _uid _gid _desc _h _sh; do
        [[ "$_uid" =~ ^[0-9]+$ && "$_uid" -ge 1000 && "$_uid" -lt 60000 ]] || continue
        [[ -d "$_h" ]] || continue
        case "$_sh" in */nologin|*/false) continue ;; esac
        printf '%s %s %s\n' "$_u" "$_h" "$_uid"
        return 0
    done < /etc/passwd
    return 1
}

net_ok() {
    if command -v curl &>/dev/null; then
        curl -fsI -m 5 https://www.bing.com >/dev/null 2>&1 && return 0
    fi
    if command -v wget &>/dev/null; then
        wget -q --spider -T 5 -t 1 https://www.bing.com >/dev/null 2>&1 && return 0
    fi
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1
}

log "=== boot updater start ==="

# 1) bounded network wait (the unit is also ordered After=NetworkManager.service / network-online.target)
for _i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    net_ok && { log "network available"; break; }
    sleep 5
done
net_ok || log "network unavailable after wait — continuing best-effort"

# 2) login window / greeter image instantly (before the display manager starts)
if [[ -x /usr/local/bin/lockscreen.sh ]]; then
    if timeout 90 /usr/local/bin/lockscreen.sh next --force --wait-net >> "$LOG_FILE" 2>&1; then
        log "greeter/login-window image updated"
    else
        log "greeter update failed (user session will retry at login)"
    fi
else
    log "lockscreen.sh missing — skipping greeter update"
fi

# 3) predownload desktop wallpaper + sync lock image for the primary user
U="" H="" UIDN=""
read -r U H UIDN < <(find_primary_user) || true
if [[ -n "$U" && -n "$UIDN" && -n "$H" ]]; then
    log "primary user: $U (uid $UIDN)"

    # make the boot lock image the user's starting point → instant re-apply at first login
    if [[ -f /usr/share/backgrounds/lockscreen.jpg ]]; then
        if mkdir -p "$H/.local/share/lockscreen" 2>/dev/null \
           && cp -f /usr/share/backgrounds/lockscreen.jpg "$H/.local/share/lockscreen/lockscreen.jpg" 2>/dev/null \
           && date +%s > "$H/.local/share/lockscreen/last_change" 2>/dev/null \
           && chown -R "$U" "$H/.local/share/lockscreen" 2>/dev/null; then
            log "lock image synced for $U"
        fi
        # ensure the user's data tree stays user-owned
        chown -R "$U" "$H/.local/share" 2>/dev/null || true
    fi

    # runtime dir (normally created by pam_systemd at login)
    mkdir -p "/run/user/$UIDN" 2>/dev/null && chown "$U" "/run/user/$UIDN" 2>/dev/null || true

    if [[ -x /usr/local/bin/spotlight.sh ]]; then
        if command -v sudo &>/dev/null; then
            if timeout 120 sudo -u "$U" env \
                HOME="$H" \
                PATH="/usr/local/bin:/usr/bin:/bin" \
                XDG_RUNTIME_DIR="/run/user/$UIDN" \
                XDG_CONFIG_HOME="$H/.config" \
                XDG_CACHE_HOME="$H/.cache" \
                XDG_DATA_HOME="$H/.local/share" \
                /usr/local/bin/spotlight.sh predownload --force >> "$LOG_FILE" 2>&1; then
                log "desktop wallpaper predownloaded for $U (applied instantly at login)"
            else
                log "wallpaper predownload failed for $U (user timer retries at login)"
            fi
        elif command -v su &>/dev/null; then
            if timeout 120 su -s /bin/bash "$U" -c \
                "exec env HOME='$H' PATH=/usr/local/bin:/usr/bin:/bin XDG_RUNTIME_DIR=/run/user/$UIDN \
                        XDG_CONFIG_HOME='$H/.config' XDG_CACHE_HOME='$H/.cache' XDG_DATA_HOME='$H/.local/share' \
                        /usr/local/bin/spotlight.sh predownload --force" >> "$LOG_FILE" 2>&1; then
                log "desktop wallpaper predownloaded for $U (applied instantly at login)"
            else
                log "wallpaper predownload failed for $U (user timer retries at login)"
            fi
        else
            log "neither sudo nor su available — cannot predownload for $U"
        fi
    else
        log "spotlight.sh missing — skipping predownload"
    fi

    # 4) ensure user timers are enabled so they start at login
    if [[ -f /etc/systemd/user/spotlight.timer && -f /etc/systemd/user/lockscreen.timer ]]; then
        systemctl --global enable spotlight.timer lockscreen.timer >> "$LOG_FILE" 2>&1 || \
            log "could not enable user timers globally (will be enabled at install/login)"
    else
        log "user timers not installed yet — will be enabled by the suite install"
    fi
else
    log "no human user found — skipping user steps"
fi

log "=== boot updater done ==="
exit 0
EOF_BOOT
    chmod 755 "$SCRIPTS_DIR/spotlight.sh" "$SCRIPTS_DIR/lockscreen.sh" "$SCRIPTS_DIR/boot.sh" 2>/dev/null

    # Copy files to system-wide paths /usr/local/bin if root/sudo is available
    if [[ "$(id -u)" -eq 0 ]] || command -v sudo &>/dev/null; then
        local CMD_PREFIX=""
        [[ "$(id -u)" -ne 0 ]] && CMD_PREFIX="sudo"
        $CMD_PREFIX mkdir -p /usr/local/bin 2>/dev/null || true
        $CMD_PREFIX cp -f "$SCRIPTS_DIR/spotlight.sh" /usr/local/bin/spotlight.sh 2>/dev/null || true
        $CMD_PREFIX cp -f "$SCRIPTS_DIR/lockscreen.sh" /usr/local/bin/lockscreen.sh 2>/dev/null || true
        $CMD_PREFIX cp -f "$SCRIPTS_DIR/boot.sh" /usr/local/bin/wallpaper-boot.sh 2>/dev/null || true
        $CMD_PREFIX chmod 755 /usr/local/bin/spotlight.sh /usr/local/bin/lockscreen.sh /usr/local/bin/wallpaper-boot.sh 2>/dev/null || true
    fi

    bash -n "$SCRIPTS_DIR/spotlight.sh" && bash -n "$SCRIPTS_DIR/lockscreen.sh" && bash -n "$SCRIPTS_DIR/boot.sh" \
        || { ui_err "Extraction failed verification.\nLog: $LOG"; return 1; }

    echo "$PAYLOAD_HASH" >"$HASH_MARK"
}

fmt_interval(){
    local m="$1" h r
    h=$(( m / 60 )); r=$(( m % 60 ))
    if (( h > 0 && r > 0 )); then printf '%sh %smin' "$h" "$r"
    elif (( h > 0 )); then printf '%sh' "$h"
    else printf '%smin' "$r"; fi
}

set_conf_key(){
    local f="$1" k="$2" v="$3"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    if [[ -f "$f" ]] && grep -q "^$k=" "$f" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$f" 2>/dev/null || true
    else
        printf '%s=%s\n' "$k" "$v" >> "$f" 2>/dev/null || true
    fi
}

units(){
    mkdir -p "$UNIT_DST"

    # timer intervals (minutes) from ~/.config/wallpaper/suite.conf
    local WI=150 LI=240 ICONF="$CONFIG_DIR/suite.conf"
    if [[ -f "$ICONF" ]]; then
        while IFS='=' read -r _k _v; do
            case "$_k" in
                WALLPAPER_INTERVAL)  [[ "$_v" =~ ^[0-9]+$ && "$_v" -ge 5 ]] && WI="$_v" ;;
                LOCKSCREEN_INTERVAL) [[ "$_v" =~ ^[0-9]+$ && "$_v" -ge 5 ]] && LI="$_v" ;;
            esac
        done < "$ICONF"
    fi
    local WI_STR LI_STR
    WI_STR="$(fmt_interval "$WI")"
    LI_STR="$(fmt_interval "$LI")"

    # keep the scripts' own "don't re-download" guard in sync with the timers
    set_conf_key "$CONFIG_DIR/config" INTERVAL_MIN "$WI"
    set_conf_key "${XDG_CONFIG_HOME:-$HOME/.config}/lockscreen/config" INTERVAL_MIN "$LI"

    local exec_spotlight="%h/.spotlight/spotlight.sh"
    local exec_lockscreen="%h/.spotlight/lockscreen.sh"
    if [[ -f "/usr/local/bin/spotlight.sh" ]]; then exec_spotlight="/usr/local/bin/spotlight.sh"; fi
    if [[ -f "/usr/local/bin/lockscreen.sh" ]]; then exec_lockscreen="/usr/local/bin/lockscreen.sh"; fi

    cat >"$UNIT_DST/spotlight.service" <<EOF
[Unit]
Description=Desktop wallpaper updater (multi-source)
After=graphical-session.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $exec_spotlight next --wait-net
Environment=XDG_RUNTIME_DIR=%t
TimeoutStartSec=infinity

[Install]
WantedBy=graphical-session.target
EOF

    cat >"$UNIT_DST/spotlight.timer" <<EOF
[Unit]
Description=Runs Spotlight immediately on startup/login and then at fixed interval

[Timer]
OnStartupSec=1s
OnUnitInactiveSec=$WI_STR
Persistent=false
Unit=spotlight.service

[Install]
WantedBy=timers.target
EOF

    cat >"$UNIT_DST/lockscreen.service" <<EOF
[Unit]
Description=Lock-screen and login-page image updater (multi-source)
After=graphical-session.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $exec_lockscreen next --wait-net
Environment=XDG_RUNTIME_DIR=%t
TimeoutStartSec=infinity

[Install]
WantedBy=graphical-session.target
EOF

    cat >"$UNIT_DST/lockscreen.timer" <<EOF
[Unit]
Description=Runs lockscreen immediately on startup/login and then at fixed interval

[Timer]
OnStartupSec=1s
OnUnitInactiveSec=$LI_STR
Persistent=false
Unit=lockscreen.service

[Install]
WantedBy=timers.target
EOF

    chmod 644 "$UNIT_DST"/{spotlight,lockscreen}.{service,timer} 2>/dev/null

    mkdir -p "$SYSD_DIR"
    local u
    for u in spotlight.service spotlight.timer lockscreen.service lockscreen.timer; do
        ln -sf "$UNIT_DST/$u" "$SYSD_DIR/$u"
    done

    systemctl --user daemon-reload 2>/dev/null || true
}

have_sysd(){ command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; }

installed(){ [[ -f "$SCRIPTS_DIR/spotlight.sh" && -f "$UNIT_DST/spotlight.timer" ]]; }

act_install(){

    if installed; then
        ui_err "Wallpaper Suite is already installed!\n\nIf you want to reset and reinstall fresh, please use the Reinstall option instead."
        return 1
    fi

    local A=1 L=500 c v CAT

    CAT="$(ui_pick "Choose your wallpaper style:" default \
        default  "🌐  Default — Spotlight · Bing · NASA APOD · Wallhaven · Picsum" \
        science  "🔬  Scientific — NASA library · research & tech imagery" \
        wildlife "🦜  Wildlife Sanctuary — animals · sanctuaries · nature")"
    [[ "$CAT" =~ ^(default|science|wildlife)$ ]] || CAT=default

    if ui_ask "Keep previous wallpapers in ~/.wallpaper?\n(You can reuse them later)"; then
        c="$(ui_pick "Archive size limit:" mb500 \
            mb500 "500 MB — recommended" gb1 "1 GB" custom "Custom size…")"
        case "$c" in
            gb1) L=1024;;
            custom) v="$(ui_text "Limit (e.g. 750MB or 2GB):" 750MB)"; v="${v^^}"; v="${v// /}"
                if [[ "$v" =~ ^([0-9]+([.][0-9]+)?)GB?$ ]]; then L="$(awk "BEGIN{printf \"%d\",${BASH_REMATCH[1]}*1024}")"
                elif [[ "$v" =~ ^([0-9]+)MB?$ ]]; then L="${BASH_REMATCH[1]}"
                else L=500; fi
                ((L>=50)) || L=50;;
        esac
    else A=0; fi

    extract || return 1

    mkdir -p "$CONFIG_DIR"; printf 'ARCHIVE_ENABLED=%s\nLIMIT_MB=%s\nCATEGORY=%s\nINTERVAL_MIN=150\n' "$A" "$L" "$CAT" >"$CONFIG_DIR/config"
    if [[ ! -f "$CONFIG_DIR/suite.conf" ]]; then
        printf 'WALLPAPER_INTERVAL=150\nLOCKSCREEN_INTERVAL=240\n# intervals in minutes — edit, then run the suite (Update now) to regenerate the timers\n' > "$CONFIG_DIR/suite.conf"
    fi

    local S="Install finished:"

    units

    # Fetch and apply first wallpaper *after* installation is finished!
    ui_busy "Fetching and applying your first desktop wallpaper…" bash "$SCRIPTS_DIR/spotlight.sh" next --force \
        && S+="\n✔ Desktop wallpaper applied  ($CAT · archive: $( ((A)) && echo "${L} MB" || echo off ))" \
        || S+="\n✘ Desktop wallpaper fetch failed — timer will retry"

    ui_info "Next step may ask your password once\n(to set up the login screen)."

    ui_busy "Setting up lock screen…" bash "$SCRIPTS_DIR/lockscreen.sh" next --force \
        && S+="\n✔ Lock screen + login page set up  (login page: after reboot)" \
        || S+="\n✘ Lock-screen step failed — run: bash ~/.spotlight/lockscreen.sh next --force"

    # Set up skeleton directory /etc/skel for new users (requires root / sudo)
    if [[ "$(id -u)" -eq 0 ]] || command -v sudo &>/dev/null; then
        dlog "Setting up system-wide defaults for new users in /etc/skel"
        local CMD_PREFIX=""
        [[ "$(id -u)" -ne 0 ]] && CMD_PREFIX="sudo"

        $CMD_PREFIX mkdir -p /etc/skel/.spotlight /etc/skel/.config/systemd/user 2>/dev/null || true
        $CMD_PREFIX cp -f "$SCRIPTS_DIR/spotlight.sh" "$SCRIPTS_DIR/lockscreen.sh" /etc/skel/.spotlight/ 2>/dev/null || true
        $CMD_PREFIX chmod 755 /etc/skel/.spotlight/*.sh 2>/dev/null || true
        for u in spotlight.service spotlight.timer lockscreen.service lockscreen.timer; do
            $CMD_PREFIX cp -f "$UNIT_DST/$u" /etc/skel/.config/systemd/user/ 2>/dev/null || true
        done

        # Copy user systemd units system-wide so any user session can resolve them
        $CMD_PREFIX mkdir -p /etc/systemd/user 2>/dev/null || true
        for u in spotlight.service spotlight.timer lockscreen.service lockscreen.timer; do
            $CMD_PREFIX cp -f "$UNIT_DST/$u" /etc/systemd/user/ 2>/dev/null || true
        done

        # System-level pre-login boot service:
        # runs AFTER the network manager is available and BEFORE the login
        # window loads, so the greeter shows the new image instantly at boot.
        $CMD_PREFIX mkdir -p /etc/systemd/system 2>/dev/null || true
        $CMD_PREFIX tee /etc/systemd/system/lockscreen-boot.service >/dev/null <<EOF
[Unit]
Description=Pre-login Wallpaper and Lock Screen Updater
After=network-online.target NetworkManager.service network.target
Wants=network-online.target
Before=display-manager.service
ConditionPathExists=/usr/local/bin/wallpaper-boot.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/wallpaper-boot.sh
TimeoutStartSec=300
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        $CMD_PREFIX chmod 644 /etc/systemd/system/lockscreen-boot.service 2>/dev/null || true
        $CMD_PREFIX systemctl daemon-reload 2>/dev/null || true
        if $CMD_PREFIX systemctl enable lockscreen-boot.service >/dev/null 2>&1; then
            S+="\n✔ Pre-login updater registered: runs after NetworkManager, before the login window"
        else
            S+="\n⚠ Pre-login updater: enable failed — run: sudo systemctl enable lockscreen-boot.service"
        fi

        # Enable user timers globally for all active user login sessions
        $CMD_PREFIX systemctl --global enable spotlight.timer lockscreen.timer 2>/dev/null || true

        S+="\n✔ System-wide support configured (new users inherit timers automatically)"
        S+="\n✔ Pre-login background boot service registered!"
    fi

    if have_sysd; then
        local E=""
        systemctl --user enable spotlight.service lockscreen.service 2>>"$LOG" || E+=" services"
        systemctl --user enable --now spotlight.timer 2>>"$LOG" || E+=" spotlight.timer"
        systemctl --user enable --now lockscreen.timer 2>>"$LOG" || E+=" lockscreen.timer"
        systemctl --user start spotlight.service lockscreen.service 2>>"$LOG" || E+=" first-update"
        [[ -z "$E" ]] && S+="\n✔ Auto-update ON  (each boot + wallpaper 2.5 h · lock 4 h)" \
                      || S+="\n✘ Enable failed:$E\n   Fix: systemctl --user enable --now$E"
    else S+="\n⚠ Timers ready — activate after login:\n   systemctl --user enable --now spotlight.timer lockscreen.timer"; fi

    ui_info "$S\n\nLog: $LOG"
}

wipe(){
    systemctl --user disable --now spotlight.timer lockscreen.timer 2>/dev/null || true
    rm -f "$UNIT_DST"/{spotlight,lockscreen}.{service,timer} \
          "$SYSD_DIR"/{spotlight,lockscreen}.{service,timer} 2>/dev/null
    rmdir "$TIMERS_DIR" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true

    [[ -f "$SCRIPTS_DIR/lockscreen.sh" ]] && bash "$SCRIPTS_DIR/lockscreen.sh" uninstall --yes >>"$LOG" 2>&1
    [[ -f "$SCRIPTS_DIR/spotlight.sh" ]] && bash "$SCRIPTS_DIR/spotlight.sh" uninstall --yes >>"$LOG" 2>&1

    rm -f "$HASH_MARK"

    # Clean up skeleton /etc/skel and global timers
    if [[ "$(id -u)" -eq 0 ]] || command -v sudo &>/dev/null; then
        local CMD_PREFIX=""
        [[ "$(id -u)" -ne 0 ]] && CMD_PREFIX="sudo"
        $CMD_PREFIX systemctl disable lockscreen-boot.service 2>/dev/null || true
        $CMD_PREFIX rm -f /etc/systemd/system/lockscreen-boot.service 2>/dev/null || true
        $CMD_PREFIX rm -rf /etc/skel/.spotlight /etc/skel/.config/systemd/user/spotlight.* /etc/skel/.config/systemd/user/lockscreen.* 2>/dev/null || true
        $CMD_PREFIX rm -f /etc/systemd/user/{spotlight,lockscreen}.{service,timer} 2>/dev/null || true
        $CMD_PREFIX rm -f /usr/local/bin/spotlight.sh /usr/local/bin/lockscreen.sh /usr/local/bin/wallpaper-boot.sh /var/log/wallpaper-boot.log 2>/dev/null || true
        $CMD_PREFIX systemctl --global disable spotlight.timer lockscreen.timer 2>/dev/null || true
        $CMD_PREFIX systemctl daemon-reload 2>/dev/null || true
    fi
}

act_uninstall(){
    ui_ask "Remove the Wallpaper Suite?\n\n• stops the timers\n• deletes images, config, history\n• restores the original login theme" || return 0
    wipe
    if ui_ask "Also delete the ~/.spotlight folder (both scripts)?"; then
        rm -rf "$SCRIPTS_DIR"
        ui_info "✔ Everything removed."
    else ui_info "✔ Removed. Scripts kept in $HOME."; fi
}

act_reinstall(){ ui_ask "Reset everything and reinstall fresh?" || return 0; wipe; act_install; }

act_next(){
    extract || return 1
    units
    ui_busy "New desktop wallpaper…" bash "$SCRIPTS_DIR/spotlight.sh" next --force \
    && ui_busy "New lock-screen image…" bash "$SCRIPTS_DIR/lockscreen.sh" next --force \
    && ui_info "✔ Fresh images applied." \
    || ui_err "Update failed.\nLog: $LOG"
}

case "${1:-}" in
    install) act_install; exit;;
    reinstall) act_reinstall; exit;;
    uninstall) act_uninstall; exit;;
    next) act_next; exit;;
esac

while :; do
    if installed; then ST="✔ installed"; DEF=next; else ST="not installed"; DEF=install; fi
    CH="$(ui_pick "<b>Wallpaper Suite</b>  v$VERSION\nStatus: $ST\n" "$DEF" \
        next      "🖼  Update now — fetch fresh images" \
        install   "📦  Install — full setup with timers" \
        reinstall "🔄  Reinstall — reset and set up fresh" \
        uninstall "🗑  Uninstall — remove everything" \
        quit      "✖  Quit")"
    CH="${CH//$'\r'/}"
    case "$CH" in
        install) act_install;; reinstall) act_reinstall;;
        uninstall) act_uninstall;; next) act_next;;
        quit) exit 0;;
        *) continue;;   # invalid input: re-ask instead of doing something unexpected
    esac
done
