#!/bin/bash
#-
# Copyright (c) 2012-2015 Juan Romero Pardines <xtraeme@gmail.com>.
#               2012 Dave Elusive <davehome@redthumb.info.tm>.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#-

# Make sure we don't inherit these from env.
SOURCE_DONE=
HOSTNAME_DONE=
KEYBOARD_DONE=
LOCALE_DONE=
TIMEZONE_DONE=
ROOTPASSWORD_DONE=
USERLOGIN_DONE=
USERPASSWORD_DONE=
USERNAME_DONE=
USERGROUPS_DONE=
USERACCOUNT_DONE=
BOOTLOADER_DONE=
PARTITIONS_DONE=
NETWORK_DONE=
FILESYSTEMS_DONE=
MIRROR_DONE=

TARGETDIR=/mnt/target

# Auto-detect a usable log sink: prefer /dev/tty8 and /dev/console for classic
# images, then the controlling terminal and tty1..tty7; fall back to a temp file.
# This works on both standard and TUI (kmscon) live images.
detect_log() {
    local candidates=(
        "/dev/tty8"
        "/dev/console"
        "/dev/tty1"
        "/dev/tty2"
        "/dev/tty3"
        "/dev/tty4"
        "/dev/tty5"
        "/dev/tty6"
        "/dev/tty7"
    )

    # Try the controlling terminal first if we have one
    if [ -t 0 ]; then
        local ctty
        ctty="$(readlink -f /dev/stdin 2>/dev/null || true)"
        if [ -n "$ctty" ] && [ -c "$ctty" ] && [ -w "$ctty" ]; then
            echo "$ctty"
            return 0
        fi
    fi

    # Try each candidate
    for candidate in "${candidates[@]}"; do
        if [ -c "$candidate" ] && [ -w "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    # Fallback to temp file so installer never hard-fails on logging
    local fallback
    fallback="$(mktemp -t vinstall-log-XXXXXXXX 2>/dev/null || echo "/tmp/vinstall.log")"
    echo "$fallback"
    return 0
}

LOG="$(detect_log)"
CONF_FILE=/tmp/.void-installer.conf
if [ ! -f $CONF_FILE ]; then
    touch -f $CONF_FILE
fi
ANSWER=$(mktemp -t vinstall-XXXXXXXX || exit 1)
TARGET_SERVICES=$(mktemp -t vinstall-sv-XXXXXXXX || exit 1)
TARGET_SELECTED=$(mktemp -t vinstall-sel-XXXXXXXX || exit 1)
TARGET_FSTAB=$(mktemp -t vinstall-fstab-XXXXXXXX || exit 1)

trap "DIE" INT TERM QUIT

# disable printk
if [ -w /proc/sys/kernel/printk ]; then
    echo 0 >/proc/sys/kernel/printk
fi

# Detect if this is an EFI system.
if [ -e /sys/firmware/efi/systab ]; then
    EFI_SYSTEM=1
    EFI_FW_BITS=$(cat /sys/firmware/efi/fw_platform_size)
    if [ $EFI_FW_BITS -eq 32 ]; then
        EFI_TARGET=i386-efi
    else
        EFI_TARGET=x86_64-efi
    fi
fi

# gum colors, real ANSI escapes so that they survive inside gum prompts
BLACK=$'\033[30m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'
GREY=$'\033[90m'
BOLD=$'\033[1m'
REVERSE=$'\033[7m'
UNDERLINE=$'\033[4m'
RESET=$'\033[0m'
# Clear the screen without relying on terminfo; the installer UI is rendered by gum.
GUM_CLEAR() {
    printf '\033[H\033[2J\033[3J'
}


# Properties shared per widget.
MENULABEL="${BOLD}Use UP and DOWN keys to navigate menus,
type to filter and press ENTER to select.${RESET}"
MENUSIZE="14 60 0"
INPUTSIZE="8 60"
MSGBOXSIZE="8 70"
YESNOSIZE="$INPUTSIZE"
WIDGET_SIZE="10 70"

BACKTITLE="${BOLD}${WHITE}Void Linux installation -- https://www.voidlinux.org (@@MKLIVE_VERSION@@)${RESET}"

# Draw a framed block of text and, when stdin is a terminal, wait for the user
# to acknowledge it.
GUM_MSGBOX() {
    gum style --border rounded --padding "1 2" --margin "1 2" \
        --border-foreground "$CYAN" "$(printf '%b' "$1")"
    if [ -t 0 ]; then
        read -rs -n 1 -p "${BOLD}Press ENTER to continue...${RESET}" _gum_key
        echo
        unset _gum_key
    fi
    return 0
}

# Ask a yes/no question.  gum confirm only renders a single line prompt, so
# multi line questions are shown in a frame first to keep them readable.
GUM_YESNO() {
    local _text
    _text="$(printf '%b' "$1")"
    if [[ "$_text" == *$'\n'* ]]; then
        gum style --border rounded --padding "1 2" --margin "1 2" \
            --border-foreground "$CYAN" "$_text"
        gum confirm "${BOLD}Do you want to continue?${RESET}"
    else
        gum confirm "$_text"
    fi
}

# Number of rows the terminal currently offers.  Avoid terminfo tools here:
# gum uses ANSI output and must work even when $TERM has no terminfo entry.
GUM_TERM_LINES() {
    local size lines
    size=$(stty size 2>/dev/null) || size=""
    lines="${size%% *}"
    case "$lines" in
        ''|*[!0-9]*) lines="${LINES:-24}" ;;
    esac
    printf '%s' "$lines"
}

# dialog(1) sizes its lists in visible rows, while gum filter takes the height
# of the whole widget and carves the header, the filter input and the help
# block out of it on its own.  Translate one into the other: $1 is the number
# of rows dialog asked for, $2 the number of lines the shared header occupies
# and $3 the number of items in the list.  A widget that does not fit into the
# terminal is left to gum, which then renders itself full screen (--height 0).
GUM_FILTER_HEIGHT() {
    local rows="$1" header_lines="$2" items="$3" lines

    case "$rows" in
        ''|*[!0-9]*) rows=0 ;;
    esac
    # dialog treats 0 as "as many rows as there are items", whereas gum reads it
    # as a request for the full screen, so resolve it here.
    [ "$rows" -le 0 ] && rows="$items"
    # Never reserve room for rows that hold no item.
    [ "$items" -gt 0 ] && [ "$rows" -gt "$items" ] && rows="$items"
    # The list itself plus the filter input above and the help block below it.
    rows=$((rows + header_lines + 3))

    lines=$(GUM_TERM_LINES)
    [ "$rows" -ge "$lines" ] && rows=0
    printf '%s' "$rows"
}

# The installer only ever talks to a handful of dialog widgets, so instead of
# rewriting every call site this wrapper keeps the dialog(1) calling
# convention and translates it to gum.  Results are still handed back through
# $ANSWER: the widget writes the chosen tag (or a space separated list of tags
# for checklists) to that file, exactly like dialog wrote them to its error
# stream, and returns 0 on OK / 1 on cancel.
DIALOG() {
    rm -f $ANSWER
    : > $ANSWER

    local widget="" title="" no_tags=0 height_override="" default_item="" current_item="" done_items=""
    local current_item=""
    local -a args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --default-item)
                default_item="$2"
                shift 2 ;;
            --current-item)
                current_item="$2"
                shift 2 ;;
            --done-items)
                done_items="$2"
                shift 2 ;;
            --title|--ok-label|--cancel-label|--extra-label|--backtitle|--timeout)
                [ "$1" = "--title" ] && title="$2"
                shift 2 ;;
            --height)
                height_override="$2"
                shift 2 ;;
            --extra-button|--no-tags|--insecure)
                shift ;;
            --menu|--yesno|--msgbox|--inputbox|--passwordbox|--checklist|--form|--textbox|--infobox|--progressbox|--programbox)
                widget="${1#--}"
                shift ;;
            *)
                args+=("$1")
                shift ;;
        esac
    done

    # dialog's geometry arguments are otherwise ignored; the height is of some
    # use to gum, but it counts the whole widget, so it gets translated below.
    local label="${args[0]}" height="${args[1]}" header header_lines out line i off
    local -a items=() tags=() displays=() selection=()

    # An explicit --height wins over the one dialog passed as geometry.
    [ -n "$height_override" ] && height="$height_override"

    # dialog puts the widget text and its geometry in front of the items and
    # the number of geometry values differs per widget, so skip every leading
    # number instead of trusting a fixed offset.
    off=1
    while [ "$off" -lt "${#args[@]}" ]; do
        case "${args[off]}" in
            ''|*[!0-9]*) break ;;
        esac
        off=$((off + 1))
    done

    # gum filter renders on stderr, so a shared header carries what dialog used
    # to put in the backtitle and the title.
    header="$BACKTITLE"
    [ -n "$title" ] && header="$BACKTITLE"$'\n'"$title"
    # Backtitle, title and the menu label each take a row of their own.
    header_lines=$(($(printf '%b' "$header"$'\n'"$label" | wc -l) + 1))

    case "$widget" in
    menu)
        items=("${args[@]:off}")
        for ((i = 0; i < ${#items[@]}; i += 2)); do
            tags+=("${items[i]}")
            if [ -n "${items[i+1]:-}" ]; then
                displays+=("${items[i]}  ${items[i+1]}")
            else
                displays+=("${items[i]}")
            fi
        done
        # dialog has no equivalent, so --current-item marks the step the installer
        # expects next with a leading "> ".  Only the shown text is touched, the
        # tag stays bare so the choice still comes back as a plain tag.
        if [ -n "$current_item" ]; then
            for ((i = 0; i < ${#displays[@]}; i++)); do
                [ "${tags[i]}" = "$current_item" ] || continue
                displays[i]="> ${displays[i]}"
            done
        fi
        # gum filter hands the selected row back with the color escapes already
        # stripped, so keep a copy of the text as it reads once the markers are
        # on but before the colors go around it.  That is the form gum returns.
        local -a shown=()
        for ((i = 0; i < ${#displays[@]}; i++)); do
            shown+=("${displays[i]}")
        done
        # dialog had no equivalent, so --done-items paints the steps that are
        # already finished grey and leaves everything still to do green.  Again
        # only the shown text is touched, the tag stays bare.
        if [ -n "$done_items" ]; then
            for ((i = 0; i < ${#displays[@]}; i++)); do
                case " $done_items " in
                    *" ${tags[i]} "*) displays[i]="$GREY${displays[i]}${RESET}" ;;
                    *) displays[i]="$GREEN${displays[i]}${RESET}" ;;
                esac
            done
        fi
        # gum filter has no way to place its cursor on a given item, so dialog's
        # --default-item is emulated by listing that item first: the cursor always
        # starts on the first row, and the whole list stays visible just like it
        # did in dialog.  An unknown tag is ignored and the order is left alone.
        for ((i = 0; i < ${#tags[@]}; i++)); do
            [ "${tags[i]}" = "$default_item" ] && break
        done
        if [ -n "$default_item" ] && [ "$i" -lt "${#tags[@]}" ] && [ "$i" -gt 0 ]; then
            local moved_tag moved_shown
            moved_tag="${tags[i]}"
            moved_shown="${shown[i]}"
            tags=("$moved_tag" "${tags[@]:0:i}" "${tags[@]:i+1}")
            shown=("$moved_shown" "${shown[@]:0:i}" "${shown[@]:i+1}")
            displays=("${displays[i]}" "${displays[@]:0:i}" "${displays[@]:i+1}")
        fi
        height=$(GUM_FILTER_HEIGHT "$height" "$header_lines" "${#displays[@]}")
        out=$(gum filter --no-fuzzy --height "$height" \
            --header "$header"$'\n'"$label" "${displays[@]}") || return 1
        for ((i = 0; i < ${#shown[@]}; i++)); do
            [ "${shown[i]}" = "$out" ] && break
        done
        if [ "$i" -lt "${#tags[@]}" ]; then
            printf '%s' "${tags[i]}" > $ANSWER
        else
            printf '%s' "$out" > $ANSWER
        fi
        return 0
        ;;
    checklist)
        local preselect=""
        items=("${args[@]:off}")
        for ((i = 0; i < ${#items[@]}; i += 3)); do
            tags+=("${items[i]}")
            if [ "$no_tags" -eq 1 ]; then
                displays+=("${items[i+1]}")
            else
                displays+=("${items[i]} ${items[i+1]}")
            fi
            [ "${items[i+2]}" = "on" ] && \
                preselect="${preselect:+$preselect,}${displays[${#displays[@]}-1]}"
        done
        height=$(GUM_FILTER_HEIGHT "$height" "$header_lines" "${#displays[@]}")
        out=$(gum filter --no-fuzzy --no-limit --height "$height" \
            --header "$header"$'\n'"$label" ${preselect:+--selected "$preselect"} \
            "${displays[@]}") || return 1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            for ((i = 0; i < ${#displays[@]}; i++)); do
                [ "${displays[i]}" = "$line" ] && break
            done
            if [ "$i" -lt "${#tags[@]}" ]; then
                selection+=("${tags[i]}")
            else
                selection+=("$line")
            fi
        done <<< "$out"
        printf '%s' "${selection[*]}" > $ANSWER
        return 0
        ;;
    yesno)
        GUM_YESNO "$label"
        return $?
        ;;
    msgbox)
        GUM_MSGBOX "$label"
        return 0
        ;;
    infobox)
        INFOBOX "$label"
        return 0
        ;;
    inputbox|passwordbox)
        local _extra=()
        [ "$widget" = "passwordbox" ] && _extra=(--password)
        [ -n "${args[3]:-}" ] && _extra+=(--value "${args[3]}")
        out=$(gum input "${_extra[@]}" --header "$header" \
            --placeholder "$(printf '%b' "$label")") || return 1
        printf '%s' "$out" > $ANSWER
        return 0
        ;;
    textbox)
        if [ -n "$title" ]; then
            printf '%s\n%s\n' "$BACKTITLE" "$title" | \
                gum style --border rounded --padding "0 2" --margin "1 2" \
                    --border-foreground "$CYAN"
        fi
        if [ -r "$label" ]; then
            gum pager -- "$(cat "$label")"
        else
            gum pager
        fi
        return $?
        ;;
    form)
        # dialog form: title, geometry, then
        # text/y/x/initial-value/item-y/item-x/item-height/item-width/item-type
        # tuples.  gum has no form widget, so ask for each field in turn and
        # write them back in the layout the call sites expect: one value per
        # line for --form driven readarray, whitespace separated otherwise.
        local -a _values=() _field=()
        for ((i = 4; i < ${#args[@]}; i += 8)); do
            _field=()
            # dialog field type 3 is "hidden" (password); 1 is an unchecked
            # checkbox value and must NOT be masked.
            case "${args[i+7]}" in
                1|3) _field=(--password) ;;
            esac
            out=$(gum input "${_field[@]}" --header "$BACKTITLE"$'\n'"$(printf '%b' "$label")" \
                --placeholder "$(printf '%b' "${args[i]}")" \
                ${args[i+3]:+--value "${args[i+3]}"}) || return 1
            _values+=("$out")
        done
        printf '%s\n' "${_values[@]}" > $ANSWER
        return 0
        ;;
    progressbox|programbox)
        local _text="$label" _scratch
        [ "$widget" = "programbox" ] && [ -n "$title" ] && _text="$title"
        _scratch=$(mktemp -t vinstall-progress-XXXXXXXX) || return 1
        gum spin --title "$(printf '%b' "$_text")" -- sh -c "cat > '$_scratch'"
        GUM_MSGBOX "$(printf '%b' "$_text")"$'\n\n'"Finished, see $LOG for the full output."
        rm -f "$_scratch"
        return 0
        ;;
    esac

    return 1
}

# Transient status message, no acknowledgement needed.
INFOBOX() {
    gum style --border rounded --padding "0 2" --margin "1 2" \
        --border-foreground "$YELLOW" "$(printf '%b' "$1")"
}

DIE() {
    rval=$1
    [ -z "$rval" ] && rval=0
    GUM_CLEAR
    rm -f $ANSWER $TARGET_FSTAB $TARGET_SERVICES $TARGET_SELECTED
    # reenable printk
    if [ -w /proc/sys/kernel/printk ]; then
        echo 4 >/proc/sys/kernel/printk
    fi
    umount_filesystems
    exit $rval
}

set_option() {
    if grep -Eq "^${1} .*" $CONF_FILE; then
        sed -i -e "/^${1} .*/d" $CONF_FILE
    fi
    echo "${1} ${2}" >>$CONF_FILE
}

get_option() {
    grep -E "^${1} .*" $CONF_FILE | sed -e "s|^${1} ||"
}

# ISO-639 language names for locales
iso639_language() {
    case "$1" in
    aa)  echo "Afar" ;;
    af)  echo "Afrikaans" ;;
    an)  echo "Aragonese" ;;
    ar)  echo "Arabic" ;;
    ast) echo "Asturian" ;;
    be)  echo "Belarusian" ;;
    bg)  echo "Bulgarian" ;;
    bhb) echo "Bhili" ;;
    br)  echo "Breton" ;;
    bs)  echo "Bosnian" ;;
    ca)  echo "Catalan" ;;
    cs)  echo "Czech" ;;
    cy)  echo "Welsh" ;;
    da)  echo "Danish" ;;
    de)  echo "German" ;;
    el)  echo "Greek" ;;
    en)  echo "English" ;;
    es)  echo "Spanish" ;;
    et)  echo "Estonian" ;;
    eu)  echo "Basque" ;;
    fi)  echo "Finnish" ;;
    fo)  echo "Faroese" ;;
    fr)  echo "French" ;;
    ga)  echo "Irish" ;;
    gd)  echo "Scottish Gaelic" ;;
    gl)  echo "Galician" ;;
    gv)  echo "Manx" ;;
    he)  echo "Hebrew" ;;
    hr)  echo "Croatian" ;;
    hsb) echo "Upper Sorbian" ;;
    hu)  echo "Hungarian" ;;
    id)  echo "Indonesian" ;;
    is)  echo "Icelandic" ;;
    it)  echo "Italian" ;;
    iw)  echo "Hebrew" ;;
    ja)  echo "Japanese" ;;
    ka)  echo "Georgian" ;;
    kk)  echo "Kazakh" ;;
    kl)  echo "Kalaallisut" ;;
    ko)  echo "Korean" ;;
    ku)  echo "Kurdish" ;;
    kw)  echo "Cornish" ;;
    lg)  echo "Ganda" ;;
    lt)  echo "Lithuanian" ;;
    lv)  echo "Latvian" ;;
    mg)  echo "Malagasy" ;;
    mi)  echo "Maori" ;;
    mk)  echo "Macedonian" ;;
    ms)  echo "Malay" ;;
    mt)  echo "Maltese" ;;
    nb)  echo "Norwegian Bokmål" ;;
    nl)  echo "Dutch" ;;
    nn)  echo "Norwegian Nynorsk" ;;
    oc)  echo "Occitan" ;;
    om)  echo "Oromo" ;;
    pl)  echo "Polish" ;;
    pt)  echo "Portuguese" ;;
    ro)  echo "Romanian" ;;
    ru)  echo "Russian" ;;
    sk)  echo "Slovak" ;;
    sl)  echo "Slovenian" ;;
    so)  echo "Somali" ;;
    sq)  echo "Albanian" ;;
    st)  echo "Southern Sotho" ;;
    sv)  echo "Swedish" ;;
    tcy) echo "Tulu" ;;
    tg)  echo "Tajik" ;;
    th)  echo "Thai" ;;
    tl)  echo "Tagalog" ;;
    tr)  echo "Turkish" ;;
    uk)  echo "Ukrainian" ;;
    uz)  echo "Uzbek" ;;
    wa)  echo "Walloon" ;;
    xh)  echo "Xhosa" ;;
    yi)  echo "Yiddish" ;;
    zh)  echo "Chinese" ;;
    zu)  echo "Zulu" ;;
    *)   echo "$1" ;;
    esac
}

# ISO-3166 country codes for locales
iso3166_country() {
    case "$1" in
    AD) echo "Andorra" ;;
    AE) echo "United Arab Emirates" ;;
    AL) echo "Albania" ;;
    AR) echo "Argentina" ;;
    AT) echo "Austria" ;;
    AU) echo "Australia" ;;
    BA) echo "Bosnia and Herzegovina" ;;
    BE) echo "Belgium" ;;
    BG) echo "Bulgaria" ;;
    BH) echo "Bahrain" ;;
    BO) echo "Bolivia" ;;
    BR) echo "Brazil" ;;
    BW) echo "Botswana" ;;
    BY) echo "Belarus" ;;
    CA) echo "Canada" ;;
    CH) echo "Switzerland" ;;
    CL) echo "Chile" ;;
    CN) echo "China" ;;
    CO) echo "Colombia" ;;
    CR) echo "Costa Rica" ;;
    CY) echo "Cyprus" ;;
    CZ) echo "Czech Republic" ;;
    DE) echo "Germany" ;;
    DJ) echo "Djibouti" ;;
    DK) echo "Denmark" ;;
    DO) echo "Dominican Republic" ;;
    DZ) echo "Algeria" ;;
    EC) echo "Ecuador" ;;
    EE) echo "Estonia" ;;
    EG) echo "Egypt" ;;
    ES) echo "Spain" ;;
    FI) echo "Finland" ;;
    FO) echo "Faroe Islands" ;;
    FR) echo "France" ;;
    GB) echo "Great Britain" ;;
    GE) echo "Georgia" ;;
    GL) echo "Greenland" ;;
    GR) echo "Greece" ;;
    GT) echo "Guatemala" ;;
    HK) echo "Hong Kong" ;;
    HN) echo "Honduras" ;;
    HR) echo "Croatia" ;;
    HU) echo "Hungary" ;;
    ID) echo "Indonesia" ;;
    IE) echo "Ireland" ;;
    IL) echo "Israel" ;;
    IN) echo "India" ;;
    IQ) echo "Iraq" ;;
    IS) echo "Iceland" ;;
    IT) echo "Italy" ;;
    JO) echo "Jordan" ;;
    JP) echo "Japan" ;;
    KE) echo "Kenya" ;;
    KR) echo "Korea, Republic of" ;;
    KW) echo "Kuwait" ;;
    KZ) echo "Kazakhstan" ;;
    LB) echo "Lebanon" ;;
    LT) echo "Lithuania" ;;
    LU) echo "Luxembourg" ;;
    LV) echo "Latvia" ;;
    LY) echo "Libya" ;;
    MA) echo "Morocco" ;;
    MG) echo "Madagascar" ;;
    MK) echo "Macedonia" ;;
    MT) echo "Malta" ;;
    MX) echo "Mexico" ;;
    MY) echo "Malaysia" ;;
    NI) echo "Nicaragua" ;;
    NL) echo "Netherlands" ;;
    NO) echo "Norway" ;;
    NZ) echo "New Zealand" ;;
    OM) echo "Oman" ;;
    PA) echo "Panama" ;;
    PE) echo "Peru" ;;
    PH) echo "Philippines" ;;
    PL) echo "Poland" ;;
    PR) echo "Puerto Rico" ;;
    PT) echo "Portugal" ;;
    PY) echo "Paraguay" ;;
    QA) echo "Qatar" ;;
    RO) echo "Romania" ;;
    RU) echo "Russian Federation" ;;
    SA) echo "Saudi Arabia" ;;
    SD) echo "Sudan" ;;
    SE) echo "Sweden" ;;
    SG) echo "Singapore" ;;
    SI) echo "Slovenia" ;;
    SK) echo "Slovakia" ;;
    SO) echo "Somalia" ;;
    SV) echo "El Salvador" ;;
    SY) echo "Syria" ;;
    TH) echo "Thailand" ;;
    TJ) echo "Tajikistan" ;;
    TN) echo "Tunisia" ;;
    TR) echo "Turkey" ;;
    TW) echo "Taiwan" ;;
    UA) echo "Ukraine" ;;
    UG) echo "Uganda" ;;
    US) echo "United States of America" ;;
    UY) echo "Uruguay" ;;
    UZ) echo "Uzbekistan" ;;
    VE) echo "Venezuela" ;;
    YE) echo "Yemen" ;;
    ZA) echo "South Africa" ;;
    ZW) echo "Zimbabwe" ;;
    *)  echo "$1" ;;
    esac
}

show_disks() {
    local dev size sectorsize gbytes

    # IDE
    for dev in $(ls /sys/block|grep -E '^hd'); do
        if [ "$(cat /sys/block/$dev/device/media)" = "disk" ]; then
            # Find out nr sectors and bytes per sector;
            echo "/dev/$dev"
            size=$(cat /sys/block/$dev/size)
            sectorsize=$(cat /sys/block/$dev/queue/hw_sector_size)
            gbytes="$(($size * $sectorsize / 1024 / 1024 / 1024))"
            echo "size:${gbytes}GB;sector_size:$sectorsize"
        fi
    done
    # SATA/SCSI and Virtual disks (virtio)
    for dev in $(ls /sys/block|grep -E '^([sv]|xv)d|mmcblk|nvme'); do
        echo "/dev/$dev"
        size=$(cat /sys/block/$dev/size)
        sectorsize=$(cat /sys/block/$dev/queue/hw_sector_size)
        gbytes="$(($size * $sectorsize / 1024 / 1024 / 1024))"
        echo "size:${gbytes}GB;sector_size:$sectorsize"
    done
    # cciss(4) devices
    for dev in $(ls /dev/cciss 2>/dev/null|grep -E 'c[0-9]d[0-9]$'); do
        echo "/dev/cciss/$dev"
        size=$(cat /sys/block/cciss\!$dev/size)
        sectorsize=$(cat /sys/block/cciss\!$dev/queue/hw_sector_size)
        gbytes="$(($size * $sectorsize / 1024 / 1024 / 1024))"
        echo "size:${gbytes}GB;sector_size:$sectorsize"
    done
}

get_partfs() {
    # Get fs type from configuration if available. This ensures
    # that the user is shown the proper fs type if they install the system.
    local part="$1"
    local default="${2:-none}"
    local fstype=$(grep "MOUNTPOINT ${part} " "$CONF_FILE"|awk '{print $3}')
    echo "${fstype:-$default}"
}

show_partitions() {
    local dev fstype fssize p part

    set -- $(show_disks)
    while [ $# -ne 0 ]; do
        disk=$(basename $1)
        shift 2
        # ATA/SCSI/SATA
        for p in /sys/block/$disk/$disk*; do
            if [ -d $p ]; then
                part=$(basename $p)
                fstype=$(lsblk -nfr /dev/$part|awk '{print $2}'|head -1)
                [ "$fstype" = "iso9660" ] && continue
                [ "$fstype" = "crypto_LUKS" ] && continue
                [ "$fstype" = "LVM2_member" ] && continue
                fssize=$(lsblk -nr /dev/$part|awk '{print $4}'|head -1)
                echo "/dev/$part"
                echo "size:${fssize:-unknown};fstype:$(get_partfs "/dev/$part")"
            fi
        done
    done
    # Device Mapper
    for p in /dev/mapper/*; do
        part=$(basename $p)
        [ "${part}" = "live-rw" ] && continue
        [ "${part}" = "live-base" ] && continue
        [ "${part}" = "control" ] && continue

        fstype=$(lsblk -nfr $p|awk '{print $2}'|head -1)
        fssize=$(lsblk -nr $p|awk '{print $4}'|head -1)
        echo "${p}"
        echo "size:${fssize:-unknown};fstype:$(get_partfs "$p")"
    done
    # Software raid (md)
    for p in $(ls -d /dev/md* 2>/dev/null|grep '[0-9]'); do
        part=$(basename $p)
        if cat /proc/mdstat|grep -qw $part; then
            fstype=$(lsblk -nfr /dev/$part|awk '{print $2}')
            [ "$fstype" = "crypto_LUKS" ] && continue
            [ "$fstype" = "LVM2_member" ] && continue
            fssize=$(lsblk -nr /dev/$part|awk '{print $4}')
            echo "$p"
            echo "size:${fssize:-unknown};fstype:$(get_partfs "$p")"
        fi
    done
    # cciss(4) devices
    for part in $(ls /dev/cciss 2>/dev/null|grep -E 'c[0-9]d[0-9]p[0-9]+'); do
        fstype=$(lsblk -nfr /dev/cciss/$part|awk '{print $2}')
        [ "$fstype" = "crypto_LUKS" ] && continue
        [ "$fstype" = "LVM2_member" ] && continue
        fssize=$(lsblk -nr /dev/cciss/$part|awk '{print $4}')
        echo "/dev/cciss/$part"
        echo "size:${fssize:-unknown};fstype:$(get_partfs "/dev/cciss/$part")"
    done
    if [ -e /sbin/lvs ]; then
        # LVM
        lvs --noheadings|while read lvname vgname perms size; do
            echo "/dev/mapper/${vgname}-${lvname}"
            echo "size:${size};fstype:$(get_partfs "/dev/mapper/${vgname}-${lvname}" lvm)"
        done
    fi
}

menu_filesystems() {
    local dev fstype fssize mntpoint reformat

    while true; do
        DIALOG --ok-label "Change" --cancel-label "Done" \
            --title " Select the partition to edit " --menu "$MENULABEL" \
            ${MENUSIZE} $(show_partitions)
        [ $? -ne 0 ] && return

        dev=$(cat $ANSWER)
        DIALOG --title " Select the filesystem type for $dev " \
            --menu "$MENULABEL" ${MENUSIZE} \
            "btrfs" "Oracle's Btrfs" \
            "ext2" "Linux ext2 (no journaling)" \
            "ext3" "Linux ext3 (journal)" \
            "ext4" "Linux ext4 (journal)" \
            "f2fs" "Flash-Friendly Filesystem" \
            "swap" "Linux swap" \
            "vfat" "FAT32" \
            "xfs" "SGI's XFS"
        if [ $? -eq 0 ]; then
            fstype=$(cat $ANSWER)
        else
            continue
        fi
        if [ "$fstype" != "swap" ]; then
            DIALOG --inputbox "Please specify the mount point for $dev:" ${INPUTSIZE}
            if [ $? -eq 0 ]; then
                mntpoint=$(cat $ANSWER)
            elif [ $? -eq 1 ]; then
                continue
            fi
        else
            mntpoint=swap
        fi
        DIALOG --yesno "Do you want to create a new filesystem on $dev?" ${YESNOSIZE}
        if [ $? -eq 0 ]; then
            reformat=1
        elif [ $? -eq 1 ]; then
            reformat=0
        else
            continue
        fi
        fssize=$(lsblk -nr $dev|awk '{print $4}')
        set -- "$fstype" "$fssize" "$mntpoint" "$reformat"
        if [ -n "$1" -a -n "$2" -a -n "$3" -a -n "$4" ]; then
            local bdev=$(basename $dev)
            local ddev=$(basename $(dirname $dev))
            if [ "$ddev" != "dev" ]; then
                sed -i -e "/^MOUNTPOINT \/dev\/${ddev}\/${bdev} .*/d" $CONF_FILE
            else
                sed -i -e "/^MOUNTPOINT \/dev\/${bdev} .*/d" $CONF_FILE
            fi
            echo "MOUNTPOINT $dev $1 $2 $3 $4" >>$CONF_FILE
        fi
    done
    FILESYSTEMS_DONE=1
}

menu_partitions() {
    DIALOG --title " Select the disk to partition " \
        --menu "$MENULABEL" ${MENUSIZE} $(show_disks)
    if [ $? -eq 0 ]; then
        local device=$(cat $ANSWER)

        DIALOG --title " Select the software for partitioning " \
            --menu "$MENULABEL" ${MENUSIZE} \
            "cfdisk" "Easy to use" \
            "fdisk" "More advanced"
        if [ $? -eq 0 ]; then
            local software=$(cat $ANSWER)

            DIALOG --title "Modify Partition Table on $device" --msgbox "\n
${BOLD}${software} will be executed in disk $device.${RESET}\n\n
For BIOS systems, MBR or GPT partition tables are supported. To use GPT\n
on PC BIOS systems, an empty partition of 1MB must be added at the first\n
2GB of the disk with the partition type \`BIOS Boot'.\n
${BOLD}NOTE: you don't need this on EFI systems.${RESET}\n\n
For EFI systems, GPT is mandatory and a FAT32 partition with at least 100MB\n
must be created with the partition type \`EFI System'. This will be used as\n
the EFI System Partition. This partition must have the mountpoint \`/boot/efi'.\n\n
At least 1 partition is required for the rootfs (/). For this partition,\n
at least 2GB is required, but more is recommended. The rootfs partition\n
should have the partition type \`Linux Filesystem'. For swap, RAM*2\n
should be enough and the partition type \`Linux swap' should be used.\n\n
${BOLD}WARNING: /usr is not supported as a separate partition.${RESET}\n
${RESET}\n" 23 80
            if [ $? -eq 0 ]; then
                while true; do
                    GUM_CLEAR
                    if [ "$software" = cfdisk ] && [ "${TERM:-}" = xterm-kitty ]; then
                        TERM=xterm-256color "$software" "$device"
                    else
                        "$software" "$device"
                    fi
                    PARTITIONS_DONE=1
                    break
                done
            else
                return
            fi
        fi
    fi
}

menu_keymap() {
    local _keymaps="$(find /usr/share/kbd/keymaps/ -type f -iname "*.map.gz" -printf "%f\n" | sed 's|.map.gz||g' | sort)"
    local _KEYMAPS=

    for f in ${_keymaps}; do
        _KEYMAPS="${_KEYMAPS} ${f} -"
    done
    while true; do
        DIALOG --title " Select your keymap " --menu "$MENULABEL" 14 70 14 ${_KEYMAPS}
        if [ $? -eq 0 ]; then
            set_option KEYMAP "$(cat $ANSWER)"
            loadkeys "$(cat $ANSWER)"
            KEYBOARD_DONE=1
            break
        else
            return
        fi
    done
}

set_keymap() {
    local KEYMAP=$(get_option KEYMAP)

    if [ -f /etc/vconsole.conf ]; then
        sed -i -e "s|KEYMAP=.*|KEYMAP=$KEYMAP|g" $TARGETDIR/etc/vconsole.conf
    else
        sed -i -e "s|#\?KEYMAP=.*|KEYMAP=$KEYMAP|g" $TARGETDIR/etc/rc.conf
    fi
}

menu_locale() {
    local _locales="$(grep -E '\.UTF-8' /etc/default/libc-locales|awk '{print $1}'|sed -e 's/^#//')"
    local LOCALES ISO639 ISO3166
    local TMPFILE=$(mktemp -t vinstall-XXXXXXXX || exit 1)
    INFOBOX "Scanning locales ..." 4 60
    for f in ${_locales}; do
        eval $(echo $f | awk 'BEGIN { FS="." } \
            { FS="_"; split($1, a); printf "ISO639=%s ISO3166=%s\n", a[1], a[2] }')
        echo "$f|$(iso639_language $ISO639) ($(iso3166_country $ISO3166))|" >> $TMPFILE
    done
    GUM_CLEAR
    # Sort by ISO-639 language names
    LOCALES=$(sort -t '|' -k 2 < $TMPFILE | xargs | sed -e's/| /|/g')
    rm -f $TMPFILE
    while true; do
        (IFS="|"; DIALOG --title " Select your locale " --menu "$MENULABEL" 18 70 18 ${LOCALES})
        if [ $? -eq 0 ]; then
            set_option LOCALE "$(cat $ANSWER)"
            LOCALE_DONE=1
            break
        else
            return
        fi
    done
}

set_locale() {
    if [ -f $TARGETDIR/etc/default/libc-locales ]; then
        local LOCALE="$(get_option LOCALE)"
        : "${LOCALE:=C.UTF-8}"
        sed -i -e "s|LANG=.*|LANG=$LOCALE|g" $TARGETDIR/etc/locale.conf
        # Uncomment locale from /etc/default/libc-locales and regenerate it.
        sed -e "/${LOCALE}/s/^\#//" -i $TARGETDIR/etc/default/libc-locales
        echo "Running xbps-reconfigure -f glibc-locales ..." >$LOG
        chroot $TARGETDIR xbps-reconfigure -f glibc-locales >$LOG 2>&1
    fi
}

menu_timezone() {
    local areas=(Africa America Antarctica Arctic Asia Atlantic Australia Europe Indian Pacific)

    local area locations location
    while (IFS='|'; DIALOG ${area:+--default-item|"$area"} --title " Select area " --menu "$MENULABEL" 19 51 19 $(printf '%s||' "${areas[@]}")); do
        area=$(cat $ANSWER)
        read -a locations -d '\n' < <(find /usr/share/zoneinfo/$area -type f -printf '%P\n' | sort)
        if (IFS='|'; DIALOG --title " Select location (${area}) " --menu "$MENULABEL" 19 51 19 $(printf '%s||' "${locations[@]//_/ }")); then
            location=$(tr ' ' '_' < $ANSWER)
            set_option TIMEZONE "$area/$location"
            TIMEZONE_DONE=1
            return 0
        else
            continue
        fi
    done
    return 1
}

set_timezone() {
    local TIMEZONE="$(get_option TIMEZONE)"

    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${TARGETDIR}/etc/localtime"
}

menu_hostname() {
    while true; do
        DIALOG --inputbox "Set the machine hostname:" ${INPUTSIZE}
        if [ $? -eq 0 ]; then
            set_option HOSTNAME "$(cat $ANSWER)"
            HOSTNAME_DONE=1
            break
        else
            return
        fi
    done
}

set_hostname() {
    local hostname="$(get_option HOSTNAME)"
    echo "${hostname:-void}" > $TARGETDIR/etc/hostname
}

menu_rootpassword() {
    local _firstpass _secondpass _again _desc

    while true; do
        if [ -z "${_firstpass}" ]; then
            _desc="Enter the root password"
        else
            _again=" again"
        fi
        DIALOG --insecure --passwordbox "${_desc}${_again}" ${INPUTSIZE}
        if [ $? -eq 0 ]; then
            if [ -z "${_firstpass}" ]; then
                _firstpass="$(cat $ANSWER)"
            else
                _secondpass="$(cat $ANSWER)"
            fi
            if [ -n "${_firstpass}" -a -n "${_secondpass}" ]; then
                if [ "${_firstpass}" != "${_secondpass}" ]; then
                    INFOBOX "Passwords do not match! Please enter again." 6 60
                    unset _firstpass _secondpass _again
                    sleep 2 && GUM_CLEAR && continue
                fi
                set_option ROOTPASSWORD "${_firstpass}"
                ROOTPASSWORD_DONE=1
                break
            fi
        else
            return
        fi
    done
}

set_rootpassword() {
    echo "root:$(get_option ROOTPASSWORD)" | chroot $TARGETDIR chpasswd -c SHA512
}

menu_useraccount() {
    local _firstpass _secondpass _desc _again
    local _groups _status _group _checklist
    local _preset _userlogin

    while true; do
        _preset=$(get_option USERLOGIN)
        [ -z "$_preset" ] && _preset="void"
        DIALOG --inputbox "Enter a primary login name:" ${INPUTSIZE} "$_preset"
        if [ $? -eq 0 ]; then
            _userlogin="$(cat $ANSWER)"
            # based on useradd(8) § Caveats
            if [ "${#_userlogin}" -le 32 ] && [[ "${_userlogin}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
                set_option USERLOGIN "${_userlogin}"
                USERLOGIN_DONE=1
                break
            else
                INFOBOX "Invalid login name! Please try again." 6 60
                unset _userlogin
                sleep 2 && GUM_CLEAR && continue
            fi
        else
            return
        fi
    done

    while true; do
        _preset=$(get_option USERNAME)
        [ -z "$_preset" ] && _preset="Void User"
        DIALOG --inputbox "Enter a display name for login '$(get_option USERLOGIN)' :" \
            ${INPUTSIZE} "$_preset"
        if [ $? -eq 0 ]; then
            set_option USERNAME "$(cat $ANSWER)"
            USERNAME_DONE=1
            break
        else
            return
        fi
    done

    while true; do
        if [ -z "${_firstpass}" ]; then
            _desc="Enter the password for login '$(get_option USERLOGIN)'"
        else
            _again=" again"
        fi
        DIALOG --insecure --passwordbox "${_desc}${_again}" ${INPUTSIZE}
        if [ $? -eq 0 ]; then
            if [ -z "${_firstpass}" ]; then
                _firstpass="$(cat $ANSWER)"
            else
                _secondpass="$(cat $ANSWER)"
            fi
            if [ -n "${_firstpass}" -a -n "${_secondpass}" ]; then
                if [ "${_firstpass}" != "${_secondpass}" ]; then
                    INFOBOX "Passwords do not match! Please enter again." 6 60
                    unset _firstpass _secondpass _again
                    sleep 2 && GUM_CLEAR && continue
                fi
                set_option USERPASSWORD "${_firstpass}"
                USERPASSWORD_DONE=1
                break
            fi
        else
            return
        fi
    done

    _groups="wheel,audio,video,floppy,cdrom,optical,kvm,users,xbuilder"
    _count=0
    while true; do
        for _group in $(cat /etc/group); do
            _gid="$(echo ${_group} | cut -d: -f3)"
            _group="$(echo ${_group} | cut -d: -f1)"
            _status="$(echo ${_groups} | grep -w ${_group})"
            if [ -z "${_status}" ]; then
                _status=off
            else
                _status=on
            fi
            # ignore the groups of root, existing users, and package groups
            if [[ "${_gid}" -ge 1000 || "${_group}" = "_"* || "${_group}" =~ ^(root|nogroup|chrony|dbus|lightdm|polkitd)$ ]]; then
                continue
            fi
            if [ -z "${_checklist}" ]; then
                _checklist="${_group} ${_group}:${_gid} ${_status}"
            else
                _checklist="${_checklist} ${_group} ${_group}:${_gid} ${_status}"
            fi
            _count=$((_count + 1))
        done
        # The checklist is as tall as the number of groups it offers, so the whole
        # list is visible at once instead of only the first rows of it.
        _desc="Select group membership for login '$(get_option USERLOGIN)':"
        DIALOG --no-tags --checklist "${_desc}" "${_count}" 60 18 ${_checklist}
        if [ $? -eq 0 ]; then
            set_option USERGROUPS $(cat $ANSWER | sed -e's| |,|g')
            USERGROUPS_DONE=1
            break
        else
            return
        fi
    done
}

set_useraccount() {
    [ -z "$USERACCOUNT_DONE" ] && return
    chroot $TARGETDIR useradd -m -G "$(get_option USERGROUPS)" \
        -c "$(get_option USERNAME)" "$(get_option USERLOGIN)"
    echo "$(get_option USERLOGIN):$(get_option USERPASSWORD)" | \
        chroot $TARGETDIR chpasswd -c SHA512
}

menu_bootloader() {
    while true; do
        DIALOG --title " Select the disk to install the bootloader" \
            --menu "$MENULABEL" ${MENUSIZE} $(show_disks) none "Manage bootloader otherwise"
        if [ $? -eq 0 ]; then
            set_option BOOTLOADER "$(cat $ANSWER)"
            BOOTLOADER_DONE=1
            break
        else
            return
        fi
    done
    while true; do
        DIALOG --yesno "Use a graphical terminal for the boot loader?" ${YESNOSIZE}
        if [ $? -eq 0 ]; then
            set_option TEXTCONSOLE 0
            break
        elif [ $? -eq 1 ]; then
            set_option TEXTCONSOLE 1
            break
        else
            return
        fi
    done
}

set_bootloader() {
    local dev=$(get_option BOOTLOADER) grub_args=

    if [ "$dev" = "none" ]; then return; fi

    # Check if it's an EFI system via efivars module.
    if [ -n "$EFI_SYSTEM" ]; then
        grub_args="--target=$EFI_TARGET --efi-directory=/boot/efi --bootloader-id=void_grub --recheck"
    fi
    echo "Running grub-install $grub_args $dev..." >$LOG
    chroot $TARGETDIR grub-install $grub_args $dev >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to install GRUB to $dev!\nCheck $LOG for errors." ${MSGBOXSIZE}
        DIE 1
    fi
    echo "Running grub-mkconfig on $TARGETDIR..." >$LOG
    chroot $TARGETDIR grub-mkconfig -o /boot/grub/grub.cfg >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR${RESET}: \
failed to run grub-mkconfig!\nCheck $LOG for errors." ${MSGBOXSIZE}
        DIE 1
    fi
}

test_network() {
    # Reset the global variable to ensure that network is accessible for this test.
    NETWORK_DONE=

    rm -f otime && \
        xbps-uhelper fetch https://repo-default.voidlinux.org/current/otime >$LOG 2>&1
    local status=$?
    rm -f otime

    if [ "$status" -eq 0 ]; then
        DIALOG --msgbox "Network is working properly!" ${MSGBOXSIZE}
        NETWORK_DONE=1
        return 1
    fi
    if [ "$1" = "nm" ]; then
        DIALOG --msgbox "Network Manager is enabled but network is inaccessible, please set it up externally with nmcli, nmtui, or the Network Manager tray applet." ${MSGBOXSIZE}
    else
        DIALOG --msgbox "Network is inaccessible, please set it up properly." ${MSGBOXSIZE}
    fi
}

configure_wifi() {
    local dev="$1" ssid enc pass _wpasupconf=/etc/wpa_supplicant/wpa_supplicant.conf

    DIALOG --form "Wireless configuration for ${dev}\n(encryption type: wep, wpa, or sae)" 0 0 0 \
        "SSID:" 1 1 "" 1 16 30 0 \
        "Encryption:" 2 1 "" 2 16 4 3 \
        "Password:" 3 1 "" 3 16 63 0 || return 1
    readarray -t values <<<$(cat $ANSWER)
    ssid="${values[0]}"; enc="${values[1]}"; pass="${values[2]}"

    if [ -z "$ssid" ]; then
        DIALOG --msgbox "Invalid SSID." ${MSGBOXSIZE}
        return 1
    elif [ -z "$enc" ] || [[ "$enc" != "wep" && "$enc" != "wpa" && "$enc" != "sae" ]]; then
        DIALOG --msgbox "Invalid encryption type (possible values: wep, wpa, or sae)." ${MSGBOXSIZE}
        return 1
    elif [ -z "$pass" ]; then
        DIALOG --msgbox "Invalid AP password." ${MSGBOXSIZE}
    fi

    # reset the configuration to the default, if necessary
    # otherwise backup the configuration
    if [ -f ${_wpasupconf}.orig ]; then
        cp -f ${_wpasupconf}.orig ${_wpasupconf}
    else
        cp -f ${_wpasupconf} ${_wpasupconf}.orig
    fi
    if [ "$enc" = "wep" ]; then
        cat << EOF >> ${_wpasupconf}
network={
  ssid="$ssid"
  wep_key0="$pass"
  wep_tx_keyidx=0
  auth_alg=SHARED
}
EOF
    elif [ "$enc" = "sae" ]; then
        cat << EOF >> ${_wpasupconf}
network={
    ssid="$ssid"
    key_mgmt=SAE
    sae_password="$pass"
    ieee80211w=2
}
EOF
    else
        wpa_passphrase "$ssid" "$pass" >> ${_wpasupconf}
    fi

    sv restart wpa_supplicant
    configure_net_dhcp $dev
    return $?
}

configure_net() {
    local dev="$1" rval

    DIALOG --yesno "Do you want to use DHCP for $dev?" ${YESNOSIZE}
    rval=$?
    if [ $rval -eq 0 ]; then
        configure_net_dhcp $dev
    elif [ $rval -eq 1 ]; then
        configure_net_static $dev
    fi
}

iface_setup() {
    ip addr show dev $1 | grep -q -e 'inet ' -e 'inet6 '
    return $?
}

configure_net_dhcp() {
    local dev="$1"

    iface_setup $dev
    if [ $? -eq 1 ]; then
        sv restart dhcpcd 2>&1 | tee $LOG | \
            DIALOG --progressbox "Initializing $dev via DHCP..." ${WIDGET_SIZE}
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} failed to run dhcpcd. See $LOG for details." ${MSGBOXSIZE}
            return 1
        fi
        export -f iface_setup
        timeout 10s bash -c "while true; do iface_setup $dev; sleep 0.25; done"
        if [ $? -eq 1 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} DHCP request failed for $dev. Check $LOG for errors." ${MSGBOXSIZE}
            return 1
        fi
    fi
    test_network
    if [ $? -eq 1 ]; then
        set_option NETWORK "${dev} dhcp"
    fi
}

configure_net_static() {
    local ip gw dns1 dns2 dev=$1

    DIALOG --form "Static IP configuration for $dev:" 0 0 0 \
        "IP address:" 1 1 "192.168.0.2" 1 21 20 0 \
        "Gateway:" 2 1 "192.168.0.1" 2 21 20 0 \
        "DNS Primary" 3 1 "8.8.8.8" 3 21 20 0 \
        "DNS Secondary" 4 1 "8.8.4.4" 4 21 20 0 || return 1

    set -- $(cat $ANSWER)
    ip=$1; gw=$2; dns1=$3; dns2=$4
    echo "running: ip link set dev $dev up" >$LOG
    ip link set dev $dev up >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} Failed to bring $dev interface." ${MSGBOXSIZE}
        return 1
    fi
    echo "running: ip addr add $ip dev $dev" >$LOG
    ip addr add $ip dev $dev >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} Failed to set ip to the $dev interface." ${MSGBOXSIZE}
        return 1
    fi
    ip route add default via $gw >$LOG 2>&1
    if [ $? -ne 0 ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} failed to setup your gateway." ${MSGBOXSIZE}
        return 1
    fi
    echo "nameserver $dns1" >/etc/resolv.conf
    echo "nameserver $dns2" >>/etc/resolv.conf
    test_network
    if [ $? -eq 1 ]; then
        set_option NETWORK "${dev} static $ip $gw $dns1 $dns2"
    fi
}

menu_network() {
    local dev addr f DEVICES

    if [ -e /var/service/NetworkManager ]; then
        # test_network returns 1 when the network turned out to be working, so
        # handing that status back left the menu stuck on this step instead of
        # moving the default item on to the next one.
        test_network nm
        return 0
    fi

    for f in $(ls /sys/class/net); do
        [ "$f" = "lo" ] && continue
        addr=$(cat /sys/class/net/$f/address)
        DEVICES="$DEVICES $f $addr"
    done
    DIALOG --title " Select the network interface to configure " \
        --menu "$MENULABEL" ${MENUSIZE} ${DEVICES}
    if [ $? -eq 0 ]; then
        dev=$(cat $ANSWER)
        if $(echo $dev|egrep -q "^wl.*" 2>/dev/null); then
            configure_wifi $dev
        else
            configure_net $dev
        fi
    fi
    # The caller checks NETWORK_DONE to see whether this step completed, so
    # never let an incidental status from configure_wifi/configure_net leak out.
    return 0
}

validate_useraccount() {
    # don't check that USERNAME has been set because it can be empty
    local USERLOGIN=$(get_option USERLOGIN)
    local USERPASSWORD=$(get_option USERPASSWORD)
    local USERGROUPS=$(get_option USERGROUPS)

    if [ -n "$USERLOGIN" ] && [ -n "$USERPASSWORD" ] && [ -n "$USERGROUPS" ]; then
        USERACCOUNT_DONE=1
    fi
}

validate_filesystems() {
    local mnts dev size fstype mntpt mkfs rootfound fmt
    local usrfound efi_system_partition
    local bootdev=$(get_option BOOTLOADER)

    unset TARGETFS
    mnts=$(grep -E '^MOUNTPOINT .*' $CONF_FILE)
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        fmt=""
        dev=$2; fstype=$3; size=$4; mntpt="$5"; mkfs=$6
        shift 6

        if [ "$mntpt" = "/" ]; then
            rootfound=1
        elif [ "$mntpt" = "/usr" ]; then
            usrfound=1
        elif [ "$fstype" = "vfat" -a "$mntpt" = "/boot/efi" ]; then
            efi_system_partition=1
        fi
        if [ "$mkfs" -eq 1 ]; then
            fmt="NEW FILESYSTEM: "
        fi
        if [ -z "$TARGETFS" ]; then
            TARGETFS="${fmt}$dev ($size) mounted on $mntpt as ${fstype}\n"
        else
            TARGETFS="${TARGETFS}${fmt}${dev} ($size) mounted on $mntpt as ${fstype}\n"
        fi
    done
    if [ -z "$rootfound" ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
the mount point for the root filesystem (/) has not yet been configured." ${MSGBOXSIZE}
        return 1
    elif [ -n "$usrfound" ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
/usr mount point has been configured but is not supported, please remove it to continue." ${MSGBOXSIZE}
        return 1
    elif [ -n "$EFI_SYSTEM" -a "$bootdev" != "none" -a -z "$efi_system_partition" ]; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
The EFI System Partition has not yet been configured, please create it\n
as FAT32, mountpoint /boot/efi and at least with 100MB of size." ${MSGBOXSIZE}
        return 1
    fi
    FILESYSTEMS_DONE=1
}

create_filesystems() {
    local mnts dev mntpt fstype fspassno mkfs size rv uuid

    # truncate to avoid doubling up
    : >"$TARGET_FSTAB"

    mnts=$(grep -E '^MOUNTPOINT .*' $CONF_FILE | sort -k 5)
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        dev=$2; fstype=$3; mntpt="$5"; mkfs=$6
        shift 6

        # swap partitions
        if [ "$fstype" = "swap" ]; then
            swapoff $dev >/dev/null 2>&1
            if [ "$mkfs" -eq 1 ]; then
                mkswap $dev >$LOG 2>&1
                if [ $? -ne 0 ]; then
                    DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to create swap on ${dev}!\ncheck $LOG for errors." ${MSGBOXSIZE}
                    DIE 1
                fi
            fi
            swapon $dev >$LOG 2>&1
            if [ $? -ne 0 ]; then
                DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to activate swap on $dev!\ncheck $LOG for errors." ${MSGBOXSIZE}
                DIE 1
            fi
            # Add entry for target fstab
            uuid=$(blkid -o value -s UUID "$dev")
            echo "UUID=$uuid none swap defaults 0 0" >>$TARGET_FSTAB
            continue
        fi

        if [ "$mkfs" -eq 1 ]; then
            case "$fstype" in
            btrfs) MKFS="mkfs.btrfs -f"; modprobe btrfs >$LOG 2>&1;;
            ext2) MKFS="mke2fs -F"; modprobe ext2 >$LOG 2>&1;;
            ext3) MKFS="mke2fs -F -j"; modprobe ext3 >$LOG 2>&1;;
            ext4) MKFS="mke2fs -F -t ext4"; modprobe ext4 >$LOG 2>&1;;
            f2fs) MKFS="mkfs.f2fs -f"; modprobe f2fs >$LOG 2>&1;;
            vfat) MKFS="mkfs.vfat -F32"; modprobe vfat >$LOG 2>&1;;
            xfs) MKFS="mkfs.xfs -f -i sparse=0"; modprobe xfs >$LOG 2>&1;;
            esac
            TITLE="Check $LOG for details ..."
            INFOBOX "Creating filesystem $fstype on $dev for $mntpt ..." 8 60
            echo "Running $MKFS $dev..." >$LOG
            $MKFS $dev >$LOG 2>&1; rv=$?
            if [ $rv -ne 0 ]; then
                DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to create filesystem $fstype on $dev!\ncheck $LOG for errors." ${MSGBOXSIZE}
                DIE 1
            fi
        fi
        # Mount rootfs the first one.
        [ "$mntpt" != "/" ] && continue
        mkdir -p $TARGETDIR
        echo "Mounting $dev on $mntpt ($fstype)..." >$LOG
        mount -t $fstype $dev $TARGETDIR >$LOG 2>&1
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to mount $dev on ${mntpt}! check $LOG for errors." ${MSGBOXSIZE}
            DIE 1
        fi
        # Add entry to target fstab
        uuid=$(blkid -o value -s UUID "$dev")
        if [ "$fstype" = "f2fs" -o "$fstype" = "btrfs" -o "$fstype" = "xfs" ]; then
            fspassno=0
        else
            fspassno=1
        fi
        echo "UUID=$uuid $mntpt $fstype defaults 0 $fspassno" >>$TARGET_FSTAB
    done

    # mount all filesystems in target rootfs
    mnts=$(grep -E '^MOUNTPOINT .*' $CONF_FILE | sort -k 5)
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        dev=$2; fstype=$3; mntpt="$5"
        shift 6
        [ "$mntpt" = "/" -o "$fstype" = "swap" ] && continue
        mkdir -p ${TARGETDIR}${mntpt}
        echo "Mounting $dev on $mntpt ($fstype)..." >$LOG
        mount -t $fstype $dev ${TARGETDIR}${mntpt} >$LOG 2>&1
        if [ $? -ne 0 ]; then
            DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
failed to mount $dev on $mntpt! check $LOG for errors." ${MSGBOXSIZE}
            DIE
        fi
        # Add entry to target fstab
        uuid=$(blkid -o value -s UUID "$dev")
        if [ "$fstype" = "f2fs" -o "$fstype" = "btrfs" -o "$fstype" = "xfs" ]; then
            fspassno=0
        else
            fspassno=2
        fi
        echo "UUID=$uuid $mntpt $fstype defaults 0 $fspassno" >>$TARGET_FSTAB
    done
}

mount_filesystems() {
    for f in sys proc dev; do
        [ ! -d $TARGETDIR/$f ] && mkdir $TARGETDIR/$f
        echo "Mounting $TARGETDIR/$f..." >$LOG
        mount --rbind /$f $TARGETDIR/$f >$LOG 2>&1
    done
}

umount_filesystems() {
    local mnts="$(grep -E '^MOUNTPOINT .* swap .*$' $CONF_FILE | sort -r -k 5)"
    set -- ${mnts}
    while [ $# -ne 0 ]; do
        local dev=$2; local fstype=$3
        shift 6
        if [ "$fstype" = "swap" ]; then
            echo "Disabling swap space on $dev..." >$LOG
            swapoff $dev >$LOG 2>&1
            continue
        fi
    done
    echo "Unmounting $TARGETDIR..." >$LOG
    umount -R $TARGETDIR >$LOG 2>&1
}

log_and_count() {
    local progress whole tenth
    while read line; do
        echo "$line" >$LOG
        copy_count=$((copy_count + 1))
        progress=$((1000 * copy_count / copy_total))
        if [ "$progress" != "$copy_progress" ]; then
            whole=$((progress / 10))
            tenth=$((progress % 10))
            printf "Progress: %d.%d%% (%d of %d files)\n" $whole $tenth $copy_count $copy_total
            copy_progress=$progress
        fi
    done
}

copy_rootfs() {
    local tar_in="--create --one-file-system --xattrs"
    TITLE="Check $LOG for details ..."
    INFOBOX "Counting files, please be patient ..." 4 60
    copy_total=$(tar ${tar_in} -v -f /dev/null / 2>/dev/null | wc -l)
    export copy_total copy_count=0 copy_progress=
    GUM_CLEAR
    tar ${tar_in} -f - / 2>/dev/null | \
        tar --extract --xattrs --xattrs-include='*' --preserve-permissions -v -f - -C $TARGETDIR | \
        log_and_count | \
        DIALOG --title "${TITLE}" \
            --progressbox "Copying live image to target rootfs." 5 60
    if [ $? -ne 0 ]; then
        DIE 1
    fi
    unset copy_total copy_count copy_percent
}

install_packages() {
    local _grub= _syspkg=

    if [ "$(get_option BOOTLOADER)" != none ]; then
        if [ -n "$EFI_SYSTEM" ]; then
            if [ $EFI_FW_BITS -eq 32 ]; then
                _grub="grub-i386-efi"
            else
                _grub="grub-x86_64-efi"
            fi
        else
            _grub="grub"
        fi
    fi

    _syspkg="base-system"

    mkdir -p $TARGETDIR/var/db/xbps/keys $TARGETDIR/usr/share
    cp -a /usr/share/xbps.d $TARGETDIR/usr/share/
    cp /var/db/xbps/keys/*.plist $TARGETDIR/var/db/xbps/keys
    if [ -n "$MIRROR_DONE" ]; then
        mkdir -p $TARGETDIR/etc
        cp -a /etc/xbps.d $TARGETDIR/etc
    fi
    mkdir -p $TARGETDIR/boot/grub

    _arch=$(xbps-uhelper arch)

    stdbuf -oL env XBPS_ARCH=${_arch} \
        xbps-install  -r $TARGETDIR -SyU ${_syspkg} ${_grub} 2>&1 | \
        DIALOG --title "Installing base system packages..." \
        --programbox 24 80
    if [ $? -ne 0 ]; then
        DIE 1
    fi
    xbps-reconfigure -r $TARGETDIR -f base-files >/dev/null 2>&1
    stdbuf -oL chroot $TARGETDIR xbps-reconfigure -a 2>&1 | \
        DIALOG --title "Configuring base system packages..." --programbox 24 80
    if [ $? -ne 0 ]; then
        DIE 1
    fi
}

menu_services() {
    local sv _status _checklist=""
    # filter out services that probably shouldn't be messed with
    # kmscon-tty* are live-only TUI console services; suppress them like agetty
    local sv_ignore='^(agetty-(tty[1-9]|generic|serial|console)|kmscon-(tty[1-6]|generic)|udevd|sulogin)$'
    find $TARGETDIR/etc/runit/runsvdir/default -mindepth 1 -maxdepth 1 -xtype d -printf '%f\n' | \
        grep -Ev "$sv_ignore" | sort -u > "$TARGET_SERVICES"
    while true; do
        while read -r sv; do
            if [ -n "$sv" ]; then
                if grep -qx "$sv" "$TARGET_SERVICES" 2>/dev/null; then
                    _status=on
                else
                    _status=off
                fi
                _checklist+=" ${sv} ${sv} ${_status}"
            fi
        done < <(find $TARGETDIR/etc/sv -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -Ev "$sv_ignore" | sort -u)
        DIALOG --no-tags --checklist "Select services to enable:" 20 60 18 ${_checklist}
        if [ $? -eq 0 ]; then
            # The checklist returns items in selection order, not sorted; comm
            # silently reports garbage on unsorted input, which used to disable
            # services the user never touched (NetworkManager, elogind, ...).
            tr ' ' '\n' < "$ANSWER" | grep -v '^$' | sort -u > "$TARGET_SELECTED"
            comm -13 "$TARGET_SERVICES" "$TARGET_SELECTED" | while read -r sv; do
                enable_service "$sv"
            done
            comm -23 "$TARGET_SERVICES" "$TARGET_SELECTED" | while read -r sv; do
                disable_service "$sv"
            done
            break
        else
            return
        fi
    done
}

enable_service() {
    ln -sf "/etc/sv/$1" "$TARGETDIR/etc/runit/runsvdir/default/$1"
}

disable_service() {
    rm -f "$TARGETDIR/etc/runit/runsvdir/default/$1"
}

menu_install() {
    ROOTPASSWORD_DONE="$(get_option ROOTPASSWORD)"
    BOOTLOADER_DONE="$(get_option BOOTLOADER)"

    if [ -z "$ROOTPASSWORD_DONE" ]; then
        DIALOG --msgbox "${BOLD}The root password has not been configured, \
please do so before starting the installation.${RESET}" ${MSGBOXSIZE}
        return 1
    elif [ -z "$BOOTLOADER_DONE" ]; then
        DIALOG --msgbox "${BOLD}The disk to install the bootloader has not been \
configured, please do so before starting the installation.${RESET}" ${MSGBOXSIZE}
        return 1
    fi

    # Validate filesystems after making sure bootloader is done,
    # so that specific checks can be made based on the selection
    validate_filesystems || return 1

    if [ -z "$FILESYSTEMS_DONE" ]; then
        DIALOG --msgbox "${BOLD}Required filesystems were not configured, \
please do so before starting the installation.${RESET}" ${MSGBOXSIZE}
        return 1
    fi

    # Validate useraccount. All parameters must be set (name, password, login name, groups).
    validate_useraccount

    if [ -z "$USERACCOUNT_DONE" ]; then
        DIALOG --yesno "${BOLD}The user account is not set up properly.${RESET}\n\n
${BOLD}${RED}WARNING: no user will be created. You will only be able to login \
with the root user in your new system.${RESET}\n\n
${BOLD}Do you want to continue?${RESET}" 10 60 || return
    fi

    DIALOG --yesno "${BOLD}The following operations will be executed:${RESET}\n\n
${BOLD}${TARGETFS}${RESET}\n
${BOLD}${RED}WARNING: data on partitions will be COMPLETELY DESTROYED for new \
filesystems.${RESET}\n\n
${BOLD}Do you want to continue?${RESET}" 20 80 || return
    unset TARGETFS

    # Create and mount filesystems
    create_filesystems

    # check if there are any files in the root partition, ignoring lost+found
    if find "$TARGETDIR" -xdev -not -name 'lost+found' -not -type d | read; then
        DIALOG --msgbox "${BOLD}${RED}ERROR:${RESET} \
Root partition not empty! Aborting..." ${MSGBOXSIZE}
        DIE 1
    fi

    SOURCE_DONE="$(get_option SOURCE)"
    # If source not set use defaults.
    if [ "$(get_option SOURCE)" = "local" -o -z "$SOURCE_DONE" ]; then
        copy_rootfs
        . /etc/default/live.conf
        rm -f $TARGETDIR/etc/motd
        rm -f $TARGETDIR/etc/issue
        rm -f $TARGETDIR/usr/sbin/void-installer
        # Remove modified sddm.conf to let sddm use the defaults.
        rm -f $TARGETDIR/etc/sddm.conf
        # Remove live user.
        echo "Removing $USERNAME live user from targetdir ..." >$LOG
        chroot $TARGETDIR userdel -r $USERNAME >$LOG 2>&1
        rm -f "$TARGETDIR/etc/sudoers.d/99-void-live"
        # Remove live-only login configuration so installed KMSCON prompts normally.
        rm -f "$TARGETDIR/etc/default/live.conf" "$TARGETDIR/usr/bin/tui-auto-login"
        # KMSCON handles tty1 on TUI images; agetty's conf may not exist.
        if [ -f "$TARGETDIR/etc/sv/agetty-tty1/conf" ]; then
            sed -i "s,GETTY_ARGS=\"--noclear -a $USERNAME\",GETTY_ARGS=\"--noclear\",g" "$TARGETDIR/etc/sv/agetty-tty1/conf"
        fi
        TITLE="Check $LOG for details ..."
        INFOBOX "Rebuilding initramfs for target ..." 4 60
        echo "Rebuilding initramfs for target ..." >$LOG
        # mount required fs
        mount_filesystems
        chroot $TARGETDIR dracut --no-hostonly --add-drivers "ahci" --force >>$LOG 2>&1
        INFOBOX "Removing temporary packages from target ..." 4 60
        echo "Removing temporary packages from target ..." >$LOG
        TO_REMOVE="gum xtools-minimal xmirror"
        # only remove espeakup and brltty if it wasn't enabled in the live environment
        if ! [ -e "/var/service/espeakup" ]; then
            TO_REMOVE+=" espeakup"
        fi
        if ! [ -e "/var/service/brltty" ]; then
            TO_REMOVE+=" brltty"
        fi
        if [ "$(get_option BOOTLOADER)" = none ]; then
            TO_REMOVE+=" grub-x86_64-efi grub-i386-efi grub"
        fi
        # uninstall separately to minimise errors
        for pkg in $TO_REMOVE; do
            xbps-remove -r $TARGETDIR -Ry "$pkg" >>$LOG 2>&1
        done
        rmdir $TARGETDIR/mnt/target
    else
        # mount required fs
        mount_filesystems
        # network install, use packages.
        install_packages
    fi

    INFOBOX "Applying installer settings..." 4 60

    # copy target fstab.
    install -Dm644 $TARGET_FSTAB $TARGETDIR/etc/fstab
    # Mount /tmp as tmpfs.
    echo "tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0" >> $TARGETDIR/etc/fstab


    # set up keymap, locale, timezone, hostname, root passwd and user account.
    set_keymap
    set_locale
    set_timezone
    set_hostname
    set_rootpassword
    set_useraccount

    # Copy /etc/skel files for root.
    cp $TARGETDIR/etc/skel/.[bix]* $TARGETDIR/root

    NETWORK_DONE="$(get_option NETWORK)"
    # network settings for target
    if [ -n "$NETWORK_DONE" ]; then
        local net="$(get_option NETWORK)"
        set -- ${net}
        local _dev="$1" _type="$2" _ip="$3" _gw="$4" _dns1="$5" _dns2="$6"
        if [ -z "$_type" ]; then
            # network type empty??!!!
            :
        elif [ "$_type" = "dhcp" ]; then
            if $(echo $_dev|egrep -q "^wl.*" 2>/dev/null); then
                cp /etc/wpa_supplicant/wpa_supplicant.conf $TARGETDIR/etc/wpa_supplicant
                enable_service wpa_supplicant
            fi
            enable_service dhcpcd
        elif [ -n "$_dev" -a "$_type" = "static" ]; then
            # static IP through dhcpcd.
            mv $TARGETDIR/etc/dhcpcd.conf $TARGETDIR/etc/dhcpcd.conf.orig
            echo "# Static IP configuration set by the void-installer for $_dev." \
                >$TARGETDIR/etc/dhcpcd.conf
            echo "interface $_dev" >>$TARGETDIR/etc/dhcpcd.conf
            echo "static ip_address=$_ip" >>$TARGETDIR/etc/dhcpcd.conf
            echo "static routers=$_gw" >>$TARGETDIR/etc/dhcpcd.conf
            echo "static domain_name_servers=$_dns1 $_dns2" >>$TARGETDIR/etc/dhcpcd.conf
            enable_service dhcpcd
        fi
    fi

    if [ -d $TARGETDIR/etc/sudoers.d ]; then
        USERLOGIN="$(get_option USERLOGIN)"
        if [ -z "$(echo $(get_option USERGROUPS) | grep -w wheel)" -a -n "$USERLOGIN" ]; then
            # enable sudo for primary user USERLOGIN who is not member of wheel
            echo "# Enable sudo for login '$USERLOGIN'" > "$TARGETDIR/etc/sudoers.d/$USERLOGIN"
            echo "$USERLOGIN ALL=(ALL:ALL) ALL" >> "$TARGETDIR/etc/sudoers.d/$USERLOGIN"
        else
            # enable the sudoers entry for members of group wheel
            echo "%wheel ALL=(ALL:ALL) ALL" > "$TARGETDIR/etc/sudoers.d/wheel"
        fi
        unset USERLOGIN
    fi

    # clean up polkit rule - it's only useful in live systems
    rm -f $TARGETDIR/etc/polkit-1/rules.d/void-live.rules

    # enable text console for grub if chosen
    if [ "$(get_option TEXTCONSOLE)" = "1" ]; then
        sed -i $TARGETDIR/etc/default/grub \
            -e 's|#\(GRUB_TERMINAL_INPUT\).*|\1=console|' \
            -e 's|#\(GRUB_TERMINAL_OUTPUT\).*|\1=console|'
    fi

    # install bootloader.
    set_bootloader

    # menu for enabling services
    menu_services

    sync && sync && sync

    # unmount all filesystems.
    umount_filesystems

    # installed successfully.
    DIALOG --yesno "${BOLD}Void Linux has been installed successfully!${RESET}\n
Do you want to reboot the system?" ${YESNOSIZE}
    if [ $? -eq 0 ]; then
        shutdown -r now
    else
        return
    fi
}

menu_source() {
    local src=

    DIALOG --title " Select installation source " \
        --menu "$MENULABEL" 8 70 0 \
        "Local" "Packages from ISO image" \
        "Network" "Base system only, downloaded from official repository"
    case "$(cat $ANSWER)" in
        "Local") src="local";;
        "Network") src="net";
            if [ -z "$NETWORK_DONE" ]; then
                if test_network; then
                    menu_network
                fi
            fi;;
        *) return 1;;
    esac
    SOURCE_DONE=1
    set_option SOURCE $src
}

# Mirror selection used to be delegated to xmirror, which depends on dialog.
# Keep its mirror-list and XBPS configuration behavior while presenting the
# chooser and confirmation with gum.
mirror_region_name() {
    case "$1" in
        AF) echo "Africa" ;;
        AN) echo "Antarctica" ;;
        AS) echo "Asia" ;;
        EU) echo "Europe" ;;
        NA) echo "North America" ;;
        OC) echo "Oceania" ;;
        SA) echo "South and Central America" ;;
        World) echo "Globally Available" ;;
        *) echo "$1" ;;
    esac
}

mirror_write() {
    local repository="$1" file
    repository="${repository%/}"
    [[ "$repository" == *"://"* ]] || repository="http://$repository"
    mkdir -p /etc/xbps.d || return 1
    local -a files=(/usr/share/xbps.d/*-repository-*.conf)
    [ -e "${files[0]}" ] || return 1
    cp --no-preserve=mode,ownership --backup=simple --suffix=.old \
        "${files[@]}" /etc/xbps.d/ || return 1
    if ! sed -i "s|https://repo-default.voidlinux.org|${repository}|g" /etc/xbps.d/*-repository-*.conf ||
        ! xbps-install -S; then
        for file in /etc/xbps.d/*-repository-*.conf.old; do
            [ -e "$file" ] && mv "$file" "${file%.old}"
        done
        return 1
    fi
    rm -f /etc/xbps.d/*-repository-*.conf.old
    return 0
}

mirror_reset() {
    local file
    for file in /usr/share/xbps.d/*-repository-*.conf; do
        [ -e "$file" ] || continue
        rm -f "/etc/xbps.d/${file##*/}" || return 1
    done
    xbps-install -S
}

mirror_choose() {
    local mirrorlist=/usr/share/xmirror/mirrors.lst
    local mirrorurl=https://xmirror.voidlinux.org/raw/mirrors.lst
    local line region url location tier choice
    local -A mirrors_by_region=()
    local -a regions=()
    if ! xbps-uhelper fetch -o "$mirrorlist" "$mirrorurl" >/dev/null 2>&1; then
        GUM_MSGBOX "Unable to update the mirror list. The installed list will be used."
    fi
    if [ ! -r "$mirrorlist" ]; then
        GUM_MSGBOX "Unable to read the mirror list at $mirrorlist."
        return 1
    fi
    while IFS= read -r line; do
        [[ "$line" == \#* || -z "$line" ]] && continue
        IFS=$'\t' read -r region url location tier _ <<< "$line"
        [ -n "$region" ] && mirrors_by_region["$region"]+="${url}"$'\t'"${location} (Tier ${tier})"$'\n'
    done < "$mirrorlist"
    GUM_MSGBOX "For the best experience, choose a mirror close to you, or use the Fastly Global CDN listed under Globally Available. Choose Default to use repo-default.voidlinux.org, which may route to any Tier 1 mirror.

Tier 1 mirrors are maintained by the Void Linux Infrastructure Team and have the latest packages. Tier 2 mirrors are independently maintained and are not guaranteed to be current or complete."

    while IFS= read -r region; do
        [ -n "$region" ] && regions+=("$(mirror_region_name "$region")")
    done < <(printf '%s\n' "${!mirrors_by_region[@]}" | sort)
    [ "${#regions[@]}" -gt 0 ] || {
        GUM_MSGBOX "No mirrors were found in $mirrorlist."
        return 1
    }
    while choice=$(gum choose --header "Choose a mirror region" "${regions[@]}" "Default" "Exit"); do
        case "$choice" in
            Exit) return 1 ;;
            Default)
                if GUM_YESNO "Reset the XBPS mirror to the default repository?"; then
                    if mirror_reset >>"$LOG" 2>&1; then
                        MIRROR_DONE=1
                        return 0
                    fi
                    GUM_MSGBOX "Mirror reset failed. See $LOG for details."
                fi ;;
            *)
                region=""
                for key in "${!mirrors_by_region[@]}"; do
                    [ "$(mirror_region_name "$key")" = "$choice" ] && region="$key" && break
                done
                [ -n "$region" ] || continue
                local -a choices=()
                while IFS=$'\t' read -r url location; do
                    [ -n "$url" ] && choices+=("${location}:$url")
                done <<< "${mirrors_by_region[$region]}"
                local selected
                selected=$(gum choose --header "Choose a mirror ($(mirror_region_name "$region"))" \
                    --label-delimiter ":" "${choices[@]}") || continue
                url="$selected"
                if GUM_YESNO "Switch XBPS to $url and refresh repository data?"; then
                    if mirror_write "$url" > "$LOG" 2>&1; then
                        MIRROR_DONE=1
                        return 0
                    fi
                    GUM_MSGBOX "Mirror update failed. See $LOG for details."
                fi ;;
        esac
    done
    return 1
}

menu_mirror() {
    mirror_choose
}

# The menu greys out the steps that are already finished, so collect their tags
# into the single space separated list that the DIALOG shim expects.
menu_done_items() {
    local done=""
    [ -n "$KEYBOARD_DONE" ] && done="$done Keyboard"
    [ -n "$NETWORK_DONE" ] && done="$done Network"
    [ -n "$SOURCE_DONE" ] && done="$done Source"
    [ -n "$MIRROR_DONE" ] && done="$done Mirror"
    [ -n "$HOSTNAME_DONE" ] && done="$done Hostname"
    [ -n "$LOCALE_DONE" ] && done="$done Locale"
    [ -n "$TIMEZONE_DONE" ] && done="$done Timezone"
    [ -n "$ROOTPASSWORD_DONE" ] && done="$done RootPassword"
    { [ -n "$USERLOGIN_DONE" ] && [ -n "$USERPASSWORD_DONE" ]; } && done="$done UserAccount"
    [ -n "$BOOTLOADER_DONE" ] && done="$done BootLoader"
    [ -n "$PARTITIONS_DONE" ] && done="$done Partition"
    [ -n "$FILESYSTEMS_DONE" ] && done="$done Filesystems"
    printf '%s' "$done"
}

menu() {
    local AFTER_HOSTNAME
    if [ -z "$DEFITEM" ]; then
        DEFITEM="Keyboard"
    fi

    if xbps-uhelper arch | grep -qe '-musl$'; then
        AFTER_HOSTNAME="Timezone"
        DIALOG --default-item $DEFITEM --current-item $DEFITEM \
            --done-items "$(menu_done_items)" \
            --title " Void Linux installation menu " \
            --menu "$MENULABEL" 15 70 0 \
            "Keyboard" "Set system keyboard" \
            "Network" "Set up the network" \
            "Source" "Set source installation" \
            "Mirror" "Select XBPS mirror" \
            "Hostname" "Set system hostname" \
            "Timezone" "Set system time zone" \
            "RootPassword" "Set system root password" \
            "UserAccount" "Set primary user name and password" \
            "BootLoader" "Set disk to install bootloader" \
            "Partition" "Partition disk(s)" \
            "Filesystems" "Configure filesystems and mount points" \
            "Install" "Start installation with saved settings" \
            "Exit" "Exit installation" \
            "Settings" "Show saved settings for installation"
    else
        AFTER_HOSTNAME="Locale"
        DIALOG --default-item $DEFITEM --current-item $DEFITEM \
            --done-items "$(menu_done_items)" \
            --title " Void Linux installation menu " \
            --menu "$MENULABEL" 15 70 0 \
            "Keyboard" "Set system keyboard" \
            "Network" "Set up the network" \
            "Source" "Set source installation" \
            "Mirror" "Select XBPS mirror" \
            "Hostname" "Set system hostname" \
            "Locale" "Set system locale" \
            "Timezone" "Set system time zone" \
            "RootPassword" "Set system root password" \
            "UserAccount" "Set primary user name and password" \
            "BootLoader" "Set disk to install bootloader" \
            "Partition" "Partition disk(s)" \
            "Filesystems" "Configure filesystems and mount points" \
            "Install" "Start installation with saved settings" \
            "Exit" "Exit installation" \
            "Settings" "Show saved settings for installation"
    fi

    case $(cat $ANSWER) in
        "Settings")
            # Show settings
            cp $CONF_FILE /tmp/conf_hidden.$$;
            sed -i "s/^ROOTPASSWORD .*/ROOTPASSWORD <-hidden->/" /tmp/conf_hidden.$$
            sed -i "s/^USERPASSWORD .*/USERPASSWORD <-hidden->/" /tmp/conf_hidden.$$
            DIALOG --title "Saved settings for installation" --textbox /tmp/conf_hidden.$$ 14 60
            rm /tmp/conf_hidden.$$;;
        "Keyboard") menu_keymap && [ -n "$KEYBOARD_DONE" ] && DEFITEM="Network";;
        "Network") menu_network && [ -n "$NETWORK_DONE" ] && DEFITEM="Source";;
        "Source") menu_source && [ -n "$SOURCE_DONE" ] && DEFITEM="Mirror";;
        "Mirror") menu_mirror && [ -n "$MIRROR_DONE" ] && DEFITEM="Hostname";;
        "Hostname") menu_hostname && [ -n "$HOSTNAME_DONE" ] && DEFITEM="$AFTER_HOSTNAME";;
        "Locale") menu_locale && [ -n "$LOCALE_DONE" ] && DEFITEM="Timezone";;
        "Timezone") menu_timezone && [ -n "$TIMEZONE_DONE" ] && DEFITEM="RootPassword";;
        "RootPassword") menu_rootpassword && [ -n "$ROOTPASSWORD_DONE" ] && DEFITEM="UserAccount";;
        "UserAccount") menu_useraccount && [ -n "$USERLOGIN_DONE" ] && [ -n "$USERPASSWORD_DONE" ] && DEFITEM="BootLoader";;
        "BootLoader") menu_bootloader && [ -n "$BOOTLOADER_DONE" ] && DEFITEM="Partition";;
        "Partition") menu_partitions && [ -n "$PARTITIONS_DONE" ] && DEFITEM="Filesystems";;
        "Filesystems") menu_filesystems && [ -n "$FILESYSTEMS_DONE" ] && DEFITEM="Install";;
        "Install") menu_install;;
        "Exit") DIE;;
        *) DIALOG --yesno "Abort Installation?" ${YESNOSIZE} && DIE
    esac
}

if ! command -v gum >/dev/null; then
    echo "ERROR: missing gum command, exiting..."
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
   echo "void-installer must run as root" 1>&2
   exit 1
fi

#
# main()
#
DIALOG --title "${BOLD}${RED} Enter the void ... ${RESET}" --msgbox "Welcome to the Void Linux installation. \n\n
A simple and minimal Linux distribution made from scratch. \n
The installation should be pretty straightforward. \n
If you are in trouble please join us at ${BOLD}#voidlinux${RESET} on ${BOLD}irc.libera.chat${RESET}.\n
${BOLD}https://www.voidlinux.org${RESET}\n\n" 16 80

while true; do
    menu
    GUM_CLEAR
done

exit 0
# vim: set ts=4 sw=4 et:
