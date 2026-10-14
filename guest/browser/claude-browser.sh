#!/bin/sh
set -eu
# Always use the dedicated Debian WSL Firefox ESR profile, without host proxies.
unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
profile="$HOME/.local/share/claude-browser/profile"
[ -d "$profile" ] || { echo 'Dedicated Linux Firefox profile is missing' >&2; exit 1; }
exec /usr/bin/firefox-esr --no-remote --profile "$profile" "$@"
