#!/bin/sh

# gum action menu. Cancelling the picker (ESC / ctrl-c) reboots, which
# matches the previous dialog --cancel-label "Reboot" behaviour.
action=$(gum choose \
    --header "Void Linux installation -- https://www.voidlinux.org

Select an Action:" \
    "Install" \
    "Shell") || reboot -f

case "$action" in
    "Install") /usr/bin/void-installer ; exec sh ;;
    "Shell") exec sh ;;
esac
