#!/usr/bin/env bash
# Interactive gum front-end for selecting and building live ISO variants.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MKISO="$SCRIPT_DIR/mkiso.sh"

usage() {
    cat <<'EOF'
Usage: build-iso-gum.sh

Choose architecture, ISO variants, date, and optionally the strict
KMSCON-only mode for selected TUI variants. Selections are passed to mkiso.sh;
non-root builds use sudo. Requires gum.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

fatal() {
    printf 'build-iso-gum: %s\n' "$*" >&2
    exit 1
}

command -v gum >/dev/null 2>&1 || fatal 'gum is required (install the gum package first).'
[[ -x $MKISO ]] || fatal "mkiso.sh not found or not executable: $MKISO"
cd -- "$SCRIPT_DIR" || fatal "cannot enter project directory: $SCRIPT_DIR"

arch=$(gum filter --header 'Select architecture' \
    --placeholder 'Type to filter architectures...' \
    i686 x86_64 x86_64-musl aarch64 aarch64-musl asahi asahi-musl) || exit 0

variants=(base cinnamon enlightenment gnome hyprland kde labwc lxde lxqt mate openbox \
    xfce xfce-wayland tui-dvtm tui-vtm tui-desktop tui-tuios)
if [[ $arch != x86_64 ]]; then
    filtered_variants=()
    for variant in "${variants[@]}"; do
        case $variant in
            tui-vtm|tui-desktop|tui-tuios|hyprland) continue ;;
        esac
        filtered_variants+=("$variant")
    done
    variants=("${filtered_variants[@]}")
fi

selected=$(gum filter --no-limit \
    --header 'Select ISO variants (Tab toggles; Enter confirms)' \
    --placeholder 'Type to filter; select one or more...' "${variants[@]}") || exit 0
[[ -n $selected ]] || fatal 'Select at least one variant.'
mapfile -t selected_variants <<< "$selected"
variant_list="${selected_variants[*]}"

kmscon_only=no
for variant in "${selected_variants[@]}"; do
    case $variant in
        tui-*)
            if gum confirm 'Use strict KMSCON-only mode? This omits fbterm and disables the agetty fallback.'; then
                kmscon_only=yes
            fi
            break
            ;;
    esac
done

date=$(gum input --value "$(date -u +%Y%m%d)" --header 'Image date (YYYYMMDD)') || exit 0
[[ $date =~ ^[0-9]{8}$ ]] || fatal 'Date must use YYYYMMDD format.'

repository=$(gum input --header 'Optional XBPS repository URL' \
    --placeholder 'Leave blank for the default repository') || exit 0

printf 'Build ISO(s)\n  Architecture: %s\n  Variant(s):    %s\n  Date:          %s\n' \
    "$arch" "${selected_variants[*]}" "$date"
[[ $kmscon_only != yes ]] || printf '  Console:       KMSCON only (no agetty fallback or fbterm)\n'
[[ -z $repository ]] || printf '  Repository:    %s\n' "$repository"
gum confirm 'Start the build?' || exit 0

args=(-a "$arch" -b "$variant_list" -d "$date")
[[ -z $repository ]] || args+=(-r "$repository")
[[ $kmscon_only != yes ]] || args+=(--kmscon-only)
if [[ $(id -u) -eq 0 ]]; then
    exec "$MKISO" "${args[@]}"
fi
command -v sudo >/dev/null 2>&1 || fatal 'sudo is required to build; run this script as root or install sudo.'
exec sudo "$MKISO" "${args[@]}"
