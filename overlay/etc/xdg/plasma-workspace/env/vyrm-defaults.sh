# Populate the live account before Plasma components read their configuration.
# Copy the complete skeleton, including dotfiles and nested directories. Limit
# this workaround to the live user so an installed user's home is not replaced.

VYRM_LIVE_USER=$(sed -n 's/^USERNAME=//p' /etc/default/live.conf 2>/dev/null | tail -n 1)
VYRM_CURRENT_USER=${USER:-$(id -un)}
VYRM_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
VYRM_DEFAULTS_MARKER="$VYRM_CONFIG_HOME/.vyrm-defaults-applied"

case "$HOME" in
    "" | /)
        ;;
    *)
        if [ -n "$VYRM_LIVE_USER" ] \
            && [ "$VYRM_CURRENT_USER" = "$VYRM_LIVE_USER" ] \
            && [ ! -e "$VYRM_DEFAULTS_MARKER" ] \
            && [ -d /etc/skel ]; then
            mkdir -p "$HOME" "$VYRM_CONFIG_HOME"

            if cp -a --no-preserve=ownership /etc/skel/. "$HOME/"; then
                : > "$VYRM_DEFAULTS_MARKER"
            fi
        fi
        ;;
esac

unset VYRM_CURRENT_USER VYRM_DEFAULTS_MARKER VYRM_CONFIG_HOME VYRM_LIVE_USER
