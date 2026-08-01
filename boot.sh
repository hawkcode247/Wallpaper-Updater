#!/usr/bin/env bash
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
