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
  -n, --no-fallback   Fail instead of trying other sources
  -y, --yes           Assume "yes" on all prompts
  -h, --help          Show this help
EOF
}
CMD="next"
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        next|install|reinstall|uninstall) CMD="$1"; shift ;;
        -s|--source)      SOURCE="${2:?--source needs a value}"; shift 2 ;;
        -n|--no-fallback) FALLBACK=0; shift ;;
        -y|--yes)         ASSUME_YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
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
confirm() { # confirm <question> -> 0 = yes
    [[ "$ASSUME_YES" == "1" ]] && return 0
    [[ -t 0 ]] || return 0                     # non-interactive: proceed
    local a=""; read -rp "$1 [Y/n]: " a || a=""
    [[ ! "${a,,}" =~ ^n ]]
}
as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then "$@"
    elif command -v sudo &>/dev/null; then
        if [[ -t 0 ]]; then sudo "$@"
        else sudo -n "$@" 2>/dev/null
        fi
    elif command -v pkexec &>/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        pkexec "$@"
    else
        return 1
    fi
}
if [[ -f "$SCRIPT_PATH" && ! -x "$SCRIPT_PATH" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        if confirm "  $(basename "$SCRIPT_PATH") is not executable. Add chmod +x now?"; then
            chmod +x "$SCRIPT_PATH" 2>/dev/null \
                && echo "  ✔ Execute permission added." \
                || warn "could not chmod — try: sudo chmod +x $SCRIPT_PATH"
        fi
    else
        chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    fi
fi
detect_pkg_manager() { # sets PM, PM_INSTALL, PM_REFRESH
    PM="" PM_INSTALL="" PM_REFRESH=""
    if   command -v apt-get      &>/dev/null; then PM=apt;    PM_INSTALL="apt-get install -y";        PM_REFRESH="apt-get update -qq"
    elif command -v dnf          &>/dev/null; then PM=dnf;    PM_INSTALL="dnf install -y"
    elif command -v yum          &>/dev/null; then PM=yum;    PM_INSTALL="yum install -y"
    elif command -v pacman       &>/dev/null; then PM=pacman; PM_INSTALL="pacman -S --noconfirm";     PM_REFRESH="pacman -Sy"
    elif command -v zypper       &>/dev/null; then PM=zypper; PM_INSTALL="zypper install -y"
    elif command -v apk          &>/dev/null; then PM=apk;    PM_INSTALL="apk add"
    elif command -v xbps-install &>/dev/null; then PM=xbps;   PM_INSTALL="xbps-install -y";           PM_REFRESH="xbps-install -S"
    elif command -v emerge       &>/dev/null; then PM=emerge; PM_INSTALL="emerge --quiet"
    fi
    [[ -n "$PM" ]]
}
pkg_name_for() { # pkg_name_for <tool> -> distro package name
    local tool="$1"
    case "$tool" in
        jq|wget|curl|wlr-randr) echo "$tool" ;;   # same name everywhere
        identify)
            case "$PM" in
                dnf|yum|zypper) echo "ImageMagick" ;;
                *)              echo "imagemagick" ;;
            esac ;;
        glib-compile-resources)
            case "$PM" in
                apt)     echo "libglib2.0-dev-bin" ;;
                dnf|yum) echo "glib2-devel" ;;
                pacman)  echo "glib2-devel" ;;
                zypper)  echo "glib2-devel" ;;
                apk)     echo "glib-dev" ;;
                *)       echo "glib2" ;;
            esac ;;
        xrandr)
            case "$PM" in
                apt)        echo "x11-xserver-utils" ;;
                dnf|yum)    echo "xrandr" ;;
                pacman)     echo "xorg-xrandr" ;;
                zypper)     echo "xrandr" ;;
                apk)        echo "xrandr" ;;
                xbps)       echo "xrandr" ;;
                emerge)     echo "x11-apps/xrandr" ;;
                *)          echo "xrandr" ;;
            esac ;;
        *) echo "$tool" ;;
    esac
}
collect_missing_deps() { # fills MISSING_REQUIRED[] and MISSING_OPTIONAL[]
    MISSING_REQUIRED=() MISSING_OPTIONAL=()
    command -v jq &>/dev/null || MISSING_REQUIRED+=(jq)
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        MISSING_REQUIRED+=(curl)          # install one downloader, curl is lightest
    fi
    if [[ -n "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        command -v xrandr &>/dev/null || command -v xdpyinfo &>/dev/null \
            || MISSING_OPTIONAL+=(xrandr)
    elif [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        command -v wlr-randr &>/dev/null || command -v swaymsg &>/dev/null \
            || command -v hyprctl &>/dev/null || command -v gsettings &>/dev/null \
            || MISSING_OPTIONAL+=(wlr-randr)
    fi
    if ! command -v identify &>/dev/null && ! command -v file &>/dev/null; then
        MISSING_OPTIONAL+=(identify)
    fi
    if { command -v gdm3 &>/dev/null || command -v gdm &>/dev/null || \
         [[ -d /etc/gdm3 || -d /etc/gdm ]]; } && \
       { ! command -v gresource &>/dev/null || ! command -v glib-compile-resources &>/dev/null; }; then
        MISSING_OPTIONAL+=(glib-compile-resources)
    fi
}
install_deps() { # install_deps <tool...> -> 0 if all installed
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
            install_deps "${MISSING_OPTIONAL[@]}" \
                || warn "optional tools not installed — continuing with fallbacks"
        fi
    fi
}
ensure_dependencies
if   command -v wget &>/dev/null; then HTTP=wget
elif command -v curl &>/dev/null; then HTTP=curl
else echo "Missing dependency: wget or curl" >&2; exit 1
fi
fetch() { # fetch <url>
    if [[ "$HTTP" == wget ]]; then
        wget -qO- -U "$USER_AGENT" --timeout=15 --tries=2 "$1"
    else
        curl -fsSL -A "$USER_AGENT" --max-time 15 --retry 1 "$1"
    fi
}
download() { # download <url> <out>
    if [[ "$HTTP" == wget ]]; then
        wget -qO "$2" -U "$USER_AGENT" --timeout=30 --tries=2 "$1"
    else
        curl -fsSL -A "$USER_AGENT" --max-time 60 --retry 1 -o "$2" "$1"
    fi
}
if command -v flock &>/dev/null; then
    exec 9>"$LOCK_FILE" || true
    flock -n 9 || { warn "another run is in progress — skipping"; exit 0; }
fi
detect_screen_size() { # sets SCREEN_W SCREEN_H
    SCREEN_W=0; SCREEN_H=0
    local out=""
    if [[ -n "${DISPLAY:-}" ]] && command -v xrandr &>/dev/null; then
        out="$(xrandr --current 2>/dev/null | sed -n 's/.* connected.* \([0-9]\+\)x\([0-9]\+\)+.*/\1 \2/p' | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wlr-randr &>/dev/null; then
        out="$(wlr-randr 2>/dev/null | sed -n 's/^[[:space:]]*\([0-9]\+\)x\([0-9]\+\).*current.*/\1 \2/p' | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v swaymsg &>/dev/null; then
        out="$(swaymsg -t get_outputs 2>/dev/null | jq -r '.[]|select(.active)|"\(.current_mode.width) \(.current_mode.height)"' 2>/dev/null | sort -rn | head -1)"
        [[ -n "$out" ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )) && command -v hyprctl &>/dev/null; then
        out="$(hyprctl monitors -j 2>/dev/null | jq -r '.[0]|"\(.width) \(.height)"' 2>/dev/null)"
        [[ "$out" =~ ^[0-9]+\ [0-9]+$ ]] && read -r SCREEN_W SCREEN_H <<< "$out"
    fi
    if (( SCREEN_W == 0 )); then
        local f
        for f in /sys/class/drm/*/modes; do
            [[ -r "$f" ]] || continue
            out="$(head -1 "$f" 2>/dev/null | sed -n 's/^\([0-9]\+\)x\([0-9]\+\).*/\1 \2/p')"
            [[ -n "$out" ]] && { read -r SCREEN_W SCREEN_H <<< "$out"; break; }
        done
    fi
    (( SCREEN_W >= 640 && SCREEN_H >= 480 )) || { SCREEN_W=1920; SCREEN_H=1080; }
}
detect_screen_size
REQ_W=$(( SCREEN_W > 3840 ? SCREEN_W : 3840 ))
REQ_H=$(( SCREEN_H > 2160 ? SCREEN_H : 2160 ))
[[ -z "$MIN_WIDTH"  ]] && MIN_WIDTH=$((  SCREEN_W < 1280 ? 1280 : SCREEN_W ))
[[ -z "$MIN_HEIGHT" ]] && MIN_HEIGHT=$(( SCREEN_H < 720  ? 720  : SCREEN_H ))
WALLHAVEN_API="https://wallhaven.cc/api/v1/search?sorting=toplist&topRange=1d&atleast=${MIN_WIDTH}x${MIN_HEIGHT}&ratios=landscape&purity=100&categories=101"
image_resolution() { # <file> -> WxH or empty
    local res=""
    command -v identify &>/dev/null && res="$(identify -format '%wx%h' "$1[0]" 2>/dev/null || true)"
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
    local r; r="$(fetch "$NASA_API")" || r=""
    imageUrl="$(jq -r 'select(.media_type=="image") | .hdurl // .url // empty' <<< "$r" 2>/dev/null || true)"
    if [[ -z "$imageUrl" ]]; then
        r="$(fetch "$NASA_RANDOM_API")" || return 1
        imageUrl="$(jq -r '[.[]|select(.media_type=="image")][0] | .hdurl // .url // empty' <<< "$r" 2>/dev/null || true)"
    fi
    [[ -n "$imageUrl" ]]
}
fetch_wallhaven() {
    local r; r="$(fetch "$WALLHAVEN_API")" || return 1
    imageUrl="$(jq -r '.data | if length>0 then .[('"$RANDOM"' % length)].path else empty end' <<< "$r" 2>/dev/null || true)"
    [[ -n "$imageUrl" ]]
}
fetch_picsum() {
    local page r id
    page=$((RANDOM % 10 + 1))
    r="$(fetch "$PICSUM_LIST_API?page=$page&limit=100")" || return 1
    id="$(jq -r --argjson mw "$MIN_WIDTH" --argjson mh "$MIN_HEIGHT" \
        '[.[]|select(.width>=$mw and .height>=$mh).id] | if length>0 then .[('"$RANDOM"' % length)] else empty end' <<< "$r" 2>/dev/null || true)"
    [[ -n "$id" ]] && imageUrl="https://picsum.photos/id/$id/$REQ_W/$REQ_H"
    [[ -n "$imageUrl" ]]
}
try_source() { # <name> -> downloaded valid image at $TMP_IMG
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
        c="$(update-alternatives --query gdm-theme.gresource 2>/dev/null \
             | sed -n 's/^Value: //p')"
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
apply_gdm() { # apply_gdm <image> -> 0 on success
    local img="$1" gres workdir themedir res xml css
    command -v gresource &>/dev/null || return 1
    command -v glib-compile-resources &>/dev/null || return 1
    gres="$(find_gdm_gresource)" || return 1
    if gresource extract "$gres" /org/gnome/shell/theme/gnome-shell.css 2>/dev/null \
        | grep -qF "file://$img"; then
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
        gresource extract "$base" "$res" > "$themedir/$rel" 2>/dev/null || {
            rm -rf "$workdir"; return 1; }
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
        echo '<gresources><gresource prefix="/org/gnome/shell/theme">'
        ( cd "$themedir" && find . -type f ! -name 'theme.gresource.xml' -printf '%P\n' ) |
            while IFS= read -r f; do printf '    <file>%s</file>\n' "$f"; done
        echo '</gresource></gresources>'
    } > "$xml"
    ( cd "$themedir" && glib-compile-resources theme.gresource.xml \
        --target="$workdir/new.gresource" --sourcedir=. ) 2>/dev/null || {
        rm -rf "$workdir"; return 1; }
    as_root bash -c "
        [[ -f '$gres.orig' ]] || cp -a '$gres' '$gres.orig'
        install -m 644 '$workdir/new.gresource' '$gres'
    " 2>/dev/null || { rm -rf "$workdir"; return 1; }
    rm -rf "$workdir"
    return 0
}
restore_gdm() { # uninstall: put the pristine theme back
    local gres
    gres="$(find_gdm_gresource)" || return 0
    [[ -f "$gres.orig" ]] || return 0
    as_root bash -c "mv -f '$gres.orig' '$gres'" 2>/dev/null || true
}
apply_lockscreen() { # <image path> -> 0 if at least one mechanism applied
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
                sed -i "s|^image=.*|image=$img|" "$sdir/config" 2>/dev/null \
                    || echo "image=$img" > "$sdir/config" 2>/dev/null || true
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
                    [[ -f \"\$conf\" ]] || printf '[%s]\n' '$gsec' > \"\$conf\"
                    grep -q '^\[$gsec\]' \"\$conf\" || printf '\n[%s]\n' '$gsec' >> \"\$conf\"
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
        as_root bash -c '
            theme_dir=$(grep -rhs "^Current=" /etc/sddm.conf.d /etc/sddm.conf 2>/dev/null | head -1 | cut -d= -f2)
            [[ -n "$theme_dir" ]] || exit 1
            t="/usr/share/sddm/themes/$theme_dir"
            [[ -d "$t" ]] || exit 1
            o="$t/theme.conf.user"
            if [[ -f "$o" ]] && grep -q "^background='"$img"'$" "$o"; then exit 0; fi
            if [[ -f "$o" ]] && grep -q "^background=" "$o"; then
                sed -i "s|^background=.*|background='"$img"'|" "$o"
            elif [[ -f "$o" ]]; then
                grep -q "^\[General\]" "$o" || printf "[General]\n" >> "$o"
                printf "background='"$img"'\n" >> "$o"
            else
                printf "[General]\nbackground='"$img"'\n" > "$o"
            fi
        ' 2>/dev/null && ok=0 || true
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
        echo "  ℹ systemd user session not available — add a cron entry instead:"
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
        sed -i "\|^image=$IMG_PATH\$|d" "$XDG_CONFIG/swaylock/config" 2>/dev/null || true
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
run_update() {
    trap 'rm -f "$TMP_IMG"' EXIT
    local order=("$SOURCE") rest=() s i j tmp
    if [[ "$FALLBACK" == "1" ]]; then
        for s in "${SOURCES[@]}"; do [[ "$s" != "$SOURCE" ]] && rest+=("$s"); done
        for ((i=${#rest[@]}-1; i>0; i--)); do
            j=$((RANDOM % (i+1))); tmp="${rest[i]}"; rest[i]="${rest[j]}"; rest[j]="$tmp"
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
        if command -v install &>/dev/null; then
            install -m 644 "$TMP_IMG" "$IMG_PATH"
        else
            cp "$TMP_IMG" "$IMG_PATH" && chmod 644 "$IMG_PATH"
        fi
    elif [[ -e "$IMG_PATH" && -w "$IMG_PATH" && -w "$IMG_DIR" ]]; then
        if command -v install &>/dev/null; then
            install -m 644 "$TMP_IMG" "$IMG_PATH"
        else
            cp "$TMP_IMG" "$IMG_PATH.new" && chmod 644 "$IMG_PATH.new" && mv -f "$IMG_PATH.new" "$IMG_PATH"
        fi
    elif [[ -e "$IMG_PATH" && -w "$IMG_PATH" ]]; then
        cp "$TMP_IMG" "$IMG_PATH"
    else
        local owner; owner="$(id -un)"
        as_root install -m 644 -o "$owner" "$TMP_IMG" "$IMG_PATH" || {
            echo "Cannot write $IMG_PATH (permission denied)" >&2; exit 1; }
    fi
    rm -f "$TMP_IMG"
    apply_lockscreen "$IMG_PATH" \
        || warn "no known lock-screen mechanism found — image is ready at $IMG_PATH"
    echo "Lock screen updated [$used]: $IMG_PATH ($(image_resolution "$IMG_PATH"))"
}
case "$CMD" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    reinstall) do_reinstall ;;
    next)      run_update ;;
esac
