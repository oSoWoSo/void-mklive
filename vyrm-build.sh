#!/usr/bin/env bash

yes | ./mkiso.sh \
    -a "x86_64" \
    -b "sonicde" \
    -r https://repo-default.voidlinux.org/current/nonfree \
    -r https://github.com/xlibre-void/xlibre/releases/latest/download \
    -r https://github.com/sonicde-void/sonicde-void/releases/latest/download \
    -- -C "live.autologin" -v "linux-lts" -o "vyrm-linux-sonicde-xlibre-x86_64-$(date +%Y%m%d).iso"
