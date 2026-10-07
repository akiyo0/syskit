#!/usr/bin/env bash
# One-time boot selector for Linux (Ubuntu/Debian) on UEFI systems.
#
# Lists the UEFI firmware boot entries, sets the chosen one as the one-time boot
# target (BootNext) and restarts the computer. The regular boot order is not
# changed: the choice applies to the next restart only.
#
# Generic firmware entries (USB, CD/DVD, PXE/network, EFI shell, diagnostics,
# firmware settings) are hidden unless -a/--all is given.
#
# Requires root and efibootmgr (sudo apt install efibootmgr). When started
# without root, the script relaunches itself through sudo with the same arguments.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: reboot.sh [options] [TARGET]
       reboot.sh -l|--list [-a]
       reboot.sh -c|--clear

One-time boot selector for UEFI systems. Shows a menu (or uses TARGET), sets the
one-time boot target (BootNext) and restarts. The boot order is not changed.

TARGET can be:
  - the number shown in the menu or by --list, e.g. 2
  - the system name or description, case-insensitive, partial match allowed, e.g. windows
  - the identifier, e.g. Boot0000 or 0000

Options:
  -n, --no-reboot    Set the one-time boot target without restarting.
  -d, --delay SEC    Seconds to wait before restarting (0-3600), during which
                     Ctrl+C cancels. Default is 5.
  -a, --all          Also include the generic firmware entries (USB, CD/DVD,
                     network, ...). Numbers shown with --all are only valid
                     together with --all.
  -l, --list         List the boot targets with their identifiers and the
                     pending one-time boot target if any, then exit.
  -c, --clear        Remove a pending one-time boot target, e.g. one set with
                     --no-reboot.
      --dry-run      Show what would be done, without changing anything.
  -h, --help         Show this help.

Examples:
  reboot.sh                      Show the menu.
  reboot.sh windows              Restart into Windows once.
  reboot.sh 2 -d 0               Restart into menu entry 2 without waiting.
  reboot.sh ubuntu --no-reboot   Boot Ubuntu on the next restart, without restarting now.
  reboot.sh windows --dry-run    Show what would be done.
  reboot.sh --list --all         List every firmware entry.
  reboot.sh --clear              Cancel a pending one-time boot target.
EOF
}

# --- output helpers -----------------------------------------------------------

if [[ -t 2 ]]; then
    YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
    YELLOW=''; RED=''; RESET=''
fi

die() {
    printf '%sError: %s%s\n' "$RED" "$1" "$RESET" >&2
    exit 1
}

# --- argument parsing ---------------------------------------------------------

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
ORIG_ARGS=("$@")

TARGET=''
NO_REBOOT=0
DELAY=5
SHOW_ALL=0
MODE=boot          # boot | list | clear
DRY_RUN=0
DELAY_SET=0

while (($#)); do
    case $1 in
        -n|--no-reboot) NO_REBOOT=1 ;;
        -d|--delay)
            (($# >= 2)) || die "Option $1 requires a value."
            DELAY=$2; DELAY_SET=1; shift
            ;;
        --delay=*) DELAY=${1#*=}; DELAY_SET=1 ;;
        -a|--all) SHOW_ALL=1 ;;
        -l|--list) MODE=list ;;
        -c|--clear) MODE=clear ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "Unknown option: $1. Use --help for usage." ;;
        *)
            [[ -z $TARGET ]] || die "Only one target can be given."
            TARGET=$1
            ;;
    esac
    shift
done
if (($#)); then
    [[ -z $TARGET && $# -eq 1 ]] || die "Only one target can be given."
    TARGET=$1
fi

[[ $DELAY =~ ^[0-9]+$ ]] && ((DELAY <= 3600)) || die "--delay must be an integer from 0 to 3600."

if [[ $MODE != boot ]]; then
    [[ -z $TARGET ]] || die "A target cannot be combined with --$MODE."
    ((NO_REBOOT == 0 && DELAY_SET == 0)) || die "--no-reboot and --delay cannot be combined with --$MODE."
fi
if [[ $MODE == clear ]]; then
    ((SHOW_ALL == 0)) || die "--all cannot be combined with --clear."
fi

# --- elevation ----------------------------------------------------------------

# Listing and dry runs only read the firmware variables, which needs no root
if ((EUID != 0)) && [[ $MODE != list ]] && ((DRY_RUN == 0)); then
    command -v sudo >/dev/null 2>&1 || die "Root rights are required. Run this script as root."
    exec sudo -- bash "$SCRIPT_PATH" "${ORIG_ARGS[@]}"
fi

command -v efibootmgr >/dev/null 2>&1 || die "efibootmgr was not found. Install it with: sudo apt install efibootmgr"
[[ -d /sys/firmware/efi ]] || die "This system is not booted in UEFI mode. This script requires a UEFI system."

# --- boot entries -------------------------------------------------------------

# Descriptions of generic firmware entries, hidden unless --all is given
NOISE_PATTERN='firmware settings|hard drive|cd/dvd|cdrom|pxe|network|usb|ipv4|ipv6|ip4|ip6|diagnostic|shell'

# Descriptions kept even when the entry has no EFI path
KNOWN_OS_PATTERN='windows|ubuntu|debian|fedora|\barch|manjaro|centos|rocky|almalinux|opensuse|mint|pop!_os|opencore|macos'

# Display names and the (lowercase) patterns matched against the description or the EFI path
FRIENDLY_NAMES=(Windows Ubuntu OpenCore macOS)
FRIENDLY_PATTERNS=(
    'windows boot manager|\\efi\\microsoft\\boot\\bootmgfw\.efi'
    'ubuntu'
    'opencore|\\efi\\oc\\opencore\.efi'
    'macos|\\system\\library\\coreservices\\boot\.efi'
)

# Entries shown to the user, in firmware boot order
E_NUM=(); E_ID=(); E_NAME=(); E_DESC=(); E_DEV=(); E_TYPE=()
PENDING=''

friendly_name() {
    # friendly_name DESCRIPTION PATH IDENTIFIER
    local desc=${1,,} path=${2,,} i
    for i in "${!FRIENDLY_NAMES[@]}"; do
        if [[ $desc =~ ${FRIENDLY_PATTERNS[i]} || $path =~ ${FRIENDLY_PATTERNS[i]} ]]; then
            printf '%s' "${FRIENDLY_NAMES[i]}"
            return
        fi
    done
    if [[ -n $1 ]]; then printf '%s' "$1"
    elif [[ -n $2 ]]; then printf '%s' "${2##*\\}"
    else printf '%s' "$3"
    fi
}

disk_for_devpath() {
    # Maps an EFI device path (HD(1,GPT,<guid>,...)) to "<model> (<disk>)", or fails
    local dp=$1 key link disk model
    if [[ $dp =~ HD\(([0-9]+),GPT,([0-9A-Fa-f-]{36}) ]]; then
        key=${BASH_REMATCH[2],,}
    elif [[ $dp =~ HD\(([0-9]+),MBR,0x([0-9A-Fa-f]+) ]]; then
        printf -v key '%08x-%02x' "$((16#${BASH_REMATCH[2]}))" "${BASH_REMATCH[1]}"
    else
        return 1
    fi

    link=$(readlink -f "/dev/disk/by-partuuid/$key" 2>/dev/null) || return 1
    [[ -b $link ]] || return 1
    disk=$(lsblk -no PKNAME "$link" 2>/dev/null | head -n 1 || true)
    [[ -n $disk ]] || disk=${link##*/}
    model=$(lsblk -dno MODEL "/dev/$disk" 2>/dev/null | sed 's/[[:space:]]*$//' || true)
    printf '%s (%s)' "${model:-$disk}" "$disk"
}

format_entry() {
    # format_entry INDEX: "Name  |  Device  |  Identifier", skipping empty parts
    local i=$1 out='' part
    for part in "${E_NAME[i]}" "${E_DEV[i]}" "${E_ID[i]}"; do
        [[ -n $part ]] || continue
        out+="${out:+  |  }$part"
    done
    printf '%s' "$out"
}

load_boot_configuration() {
    local output
    output=$(efibootmgr -v 2>&1) || die $'efibootmgr failed:\n'"$output"

    local -A desc_of=() path_of=() devp_of=()
    local all_ids=() order=() next=''
    local line id rest desc devp path

    while IFS= read -r line; do
        if [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+(.*)$ ]]; then
            id=${BASH_REMATCH[1]^^}
            rest=${BASH_REMATCH[2]}
            desc=${rest%%$'\t'*}
            devp=''
            [[ $rest == *$'\t'* ]] && devp=${rest#*$'\t'}
            path=''
            [[ $devp =~ File\(([^\)]*)\) && ${BASH_REMATCH[1]} != . ]] && path=${BASH_REMATCH[1]}
            all_ids+=("$id")
            desc_of[$id]=$desc
            path_of[$id]=$path
            devp_of[$id]=$devp
        elif [[ $line =~ ^BootOrder:[[:space:]]*(.*)$ ]]; then
            IFS=, read -ra order <<<"${BASH_REMATCH[1]^^}"
        elif [[ $line =~ ^BootNext:[[:space:]]*([0-9A-Fa-f]{4}) ]]; then
            next=${BASH_REMATCH[1]^^}
        fi
    done <<<"$output"

    # Firmware boot order first, then entries missing from it in listing order
    local -A seen=()
    local ordered=()
    for id in "${order[@]}" "${all_ids[@]}"; do
        [[ -n $id && -n ${desc_of[$id]+x} && -z ${seen[$id]+x} ]] || continue
        seen[$id]=1
        ordered+=("$id")
    done

    local is_efi is_os device count=0
    local -a all_names=()
    E_NUM=(); E_ID=(); E_NAME=(); E_DESC=(); E_DEV=(); E_TYPE=()
    for id in "${ordered[@]}"; do
        desc=${desc_of[$id]}; path=${path_of[$id]}; devp=${devp_of[$id]}

        is_efi=0
        [[ ${path,,} =~ \.efi$|\\efi\\ ]] && is_efi=1
        is_os=0
        if ! [[ ${desc,,} =~ $NOISE_PATTERN ]] && { ((is_efi)) || [[ ${desc,,} =~ $KNOWN_OS_PATTERN ]]; }; then
            is_os=1
        fi

        all_names[${#all_names[@]}]="$id"
        if ((SHOW_ALL || is_os)); then
            device=$(disk_for_devpath "$devp" || true)
            if [[ -z $device && -n $devp ]]; then
                device=$devp
                ((${#device} > 48)) && device="${device:0:45}..."
            fi
            count=$((count + 1))
            E_NUM+=("$count")
            E_ID+=("Boot$id")
            E_NAME+=("$(friendly_name "$desc" "$path" "Boot$id")")
            E_DESC+=("$desc")
            E_DEV+=("$device")
            E_TYPE+=("$( ((is_efi)) && echo UEFI || echo Device )")
        fi
    done

    PENDING=''
    if [[ -n $next ]]; then
        PENDING="Boot$next"
        # Describe the pending target even when it is a hidden entry
        local i
        for i in "${!E_ID[@]}"; do
            if [[ ${E_ID[i]} == "Boot$next" ]]; then
                PENDING=$(format_entry "$i")
                break
            fi
        done
        if [[ $PENDING == "Boot$next" && -n ${desc_of[$next]+x} ]]; then
            PENDING="${desc_of[$next]}  |  Boot$next"
        fi
    fi
}

show_boot_entries() {
    # show_boot_entries [with-identifier]
    local with_id=${1:-} i
    local w_no=3 w_name=6 w_dev=6 w_type=4

    for i in "${!E_ID[@]}"; do
        ((${#E_NUM[i]} > w_no)) && w_no=${#E_NUM[i]}
        ((${#E_NAME[i]} > w_name)) && w_name=${#E_NAME[i]}
        ((${#E_DEV[i]} > w_dev)) && w_dev=${#E_DEV[i]}
        ((${#E_TYPE[i]} > w_type)) && w_type=${#E_TYPE[i]}
    done

    local fmt="%-${w_no}s  %-${w_name}s  %-${w_dev}s  %-${w_type}s"
    local -a head=("No." "System" "Device" "Type")
    [[ -n $with_id ]] && fmt+="  %s"
    fmt+=$'\n'

    if [[ -n $with_id ]]; then head+=("Identifier"); fi
    printf "$fmt" "${head[@]}"
    local dashes=("${head[@]//?/-}")
    printf "$fmt" "${dashes[@]}"
    for i in "${!E_ID[@]}"; do
        if [[ -n $with_id ]]; then
            printf "$fmt" "${E_NUM[i]}" "${E_NAME[i]}" "${E_DEV[i]}" "${E_TYPE[i]}" "${E_ID[i]}"
        else
            printf "$fmt" "${E_NUM[i]}" "${E_NAME[i]}" "${E_DEV[i]}" "${E_TYPE[i]}"
        fi
    done
    echo
}

# Sets RESOLVED to the index of the matching entry; on failure sets RESOLVE_ERROR and returns 1
RESOLVED=-1
RESOLVE_ERROR=''
resolve_boot_entry() {
    local value=$1 i lower found=()
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    lower=${value,,}

    # Number shown in the menu
    if [[ $value =~ ^[0-9]{1,3}$ ]]; then
        local number=$((10#$value))
        for i in "${!E_NUM[@]}"; do
            if ((E_NUM[i] == number)); then RESOLVED=$i; return 0; fi
        done
        RESOLVE_ERROR="Invalid number: $number. Choose a number from 1 to ${#E_NUM[@]}."
        return 1
    fi

    # Identifier (Boot prefix and braces optional), then exact name/description, then partial
    local id=${lower//[\{\}]/}
    id=${id#boot}
    for i in "${!E_ID[@]}"; do
        [[ ${E_ID[i],,} == "boot$id" ]] && found+=("$i")
    done
    if ((${#found[@]} == 0)); then
        for i in "${!E_ID[@]}"; do
            [[ ${E_NAME[i],,} == "$lower" || ${E_DESC[i],,} == "$lower" ]] && found+=("$i")
        done
    fi
    if ((${#found[@]} == 0)); then
        for i in "${!E_ID[@]}"; do
            [[ ${E_NAME[i],,} == *"$lower"* || ${E_DESC[i],,} == *"$lower"* ]] && found+=("$i")
        done
    fi

    if ((${#found[@]} == 1)); then RESOLVED=${found[0]}; return 0; fi
    if ((${#found[@]} == 0)); then
        RESOLVE_ERROR="No boot target matches '$value'. Run with --list to see the boot targets."
        return 1
    fi

    RESOLVE_ERROR="'$value' matches more than one boot target:"
    for i in "${found[@]}"; do
        RESOLVE_ERROR+=$'\n'"  ${E_NUM[i]}) $(format_entry "$i")"
    done
    RESOLVE_ERROR+=$'\nUse the number or the identifier instead.'
    return 1
}

read_boot_entry() {
    # Prompts until a valid entry is chosen; returns 1 when the user exits
    local answer
    while true; do
        read -r -p 'Select boot target (number or name, 0 = exit): ' answer || { echo; return 1; }
        answer=${answer#"${answer%%[![:space:]]*}"}
        answer=${answer%"${answer##*[![:space:]]}"}
        case ${answer,,} in
            0|q|exit) return 1 ;;
            '') continue ;;
        esac
        if resolve_boot_entry "$answer"; then return 0; fi
        printf '%s%s%s\n' "$YELLOW" "$RESOLVE_ERROR" "$RESET" >&2
    done
}

set_boot_next() {
    # set_boot_next Boot0002
    local out
    out=$(efibootmgr --bootnext "${1#Boot}" 2>&1) || die $'efibootmgr failed:\n'"$out"
}

restart_computer() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot
    else
        reboot
    fi
}

# --- main ---------------------------------------------------------------------

main() {
    load_boot_configuration

    if [[ $MODE == clear ]]; then
        if [[ -z $PENDING ]]; then
            echo 'No one-time boot target is set.'
        elif ((DRY_RUN)); then
            echo "[dry-run] Would clear one-time boot target: $PENDING"
        else
            local out
            out=$(efibootmgr --delete-bootnext 2>&1) || die $'efibootmgr failed:\n'"$out"
            echo "One-time boot target cleared: $PENDING"
        fi
        return
    fi

    ((${#E_ID[@]} > 0)) || die 'No boot targets found. Use --all to include every firmware entry.'

    if [[ $MODE == list ]]; then
        show_boot_entries with-id
        [[ -z $PENDING ]] || echo "Pending one-time boot: $PENDING"
        return
    fi

    if [[ -n $TARGET ]]; then
        resolve_boot_entry "$TARGET" || die "$RESOLVE_ERROR"
    else
        show_boot_entries
        [[ -z $PENDING ]] || printf 'Pending one-time boot: %s\n\n' "$PENDING"
        read_boot_entry || exit 0
    fi

    local entry=$RESOLVED summary
    summary=$(format_entry "$entry")

    if ((NO_REBOOT)); then
        if ((DRY_RUN)); then
            echo "[dry-run] Would set one-time boot target: $summary"
            return
        fi
        set_boot_next "${E_ID[entry]}"
        echo "The next restart boots into: $summary"
        echo 'This applies once. Run with --clear to cancel it.'
        return
    fi

    if ((DRY_RUN)); then
        echo "[dry-run] Would set one-time boot target and restart: $summary"
        return
    fi

    echo "Restarting into: $summary"
    if ((DELAY > 0)); then
        echo "Restarting in $DELAY seconds. Press Ctrl+C to cancel."
        sleep "$DELAY"
    fi

    # Set only now, so that cancelling the countdown leaves nothing behind
    set_boot_next "${E_ID[entry]}"
    restart_computer || die 'Restart failed. The one-time boot target is set: restart manually, or run with --clear.'
}

main
