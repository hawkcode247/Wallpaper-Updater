# Contributing

1. Fork → branch → PR against `main`.
2. Bash style: `set -uo pipefail`, guard every external tool with `command -v`,
   never break `set -e` callers, keep everything distro-agnostic.
3. Test before PR: `bash -n` all scripts, then run the audit:
   every source (`--source X --no-fallback`), fallback, `clean`, `install`, `uninstall`.
4. After changing spotlight.sh/lockscreen.sh, rebuild:
   `python3 build-suite.py && bash build-appimage.sh`
