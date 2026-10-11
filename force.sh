#!/bin/bash
# btrfs-uuid-sub-bruteforce.sh
#
# Brute-forces a btrfs UUID_SUB that starts with a given prefix and
# excludes certain hex digits, then writes the winning filesystem to a
# target block device.
#
# Requires: root, bash, mkfs.btrfs, losetup, dd, xxd, blkid
# WARNING:  The target device is COMPLETELY OVERWRITTEN.

set -euo pipefail

# ---------- Config (override via env) ----------
REAL_DEV="${REAL_DEV:-/dev/nvme0n1p4}"
LABEL="${LABEL:-/}"
MAIN_UUID="${MAIN_UUID:-0dd13410-013a-013b-013c-1341000000f4}"

# UUID_SUB must start with this and contain none of the excluded chars.
PREFIX="${PREFIX:-0dd}"
EXCLUDE="${EXCLUDE:-f5}"

# Loop image size. Keep <= size of REAL_DEV.
SIZE="${SIZE:-128M}"

# Parallel workers. Default: number of CPUs.
WORKERS="${WORKERS:-$(nproc)}"

# Scratch dir (tmpfs recommended).
WORKDIR="${WORKDIR:-/dev/shm/btrfs-uuid-bf}"

# btrfs on-disk offsets
SB_OFF=0x10000
SB_UUID_SUB_OFF=$((SB_OFF + 0x40))

# ---------- Sanity ----------
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
for c in mkfs.btrfs losetup dd xxd blkid truncate; do
    command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
[ -b "$REAL_DEV" ] || { echo "not a block device: $REAL_DEV" >&2; exit 1; }

mkdir -p "$WORKDIR"

# ---------- Helpers ----------
log() { printf '%s\n' "$*" >&2; }

# Read UUID_SUB from the raw superblock, output canonical UUID form.
read_uuid_sub_hex() {
    local dev="$1"
    dd if="$dev" bs=1 skip="$SB_UUID_SUB_OFF" count=16 \
       iflag=skip_bytes,count_bytes 2>/dev/null | xxd -p -c 32
}

# Accept if first len(PREFIX) nibbles == PREFIX and no nibble in EXCLUDE.
accept_hex() {
    local h="$1" c
    [ "${h:0:${#PREFIX}}" = "$PREFIX" ] || return 1
    local i
    for ((i=0; i<${#h}; i++)); do
        c="${h:i:1}"
        case "$EXCLUDE" in
            *"$c"*) return 1 ;;
        esac
    done
    return 0
}

hex_to_uuid() {
    local h="$1"
    printf '%s-%s-%s-%s-%s' \
        "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# ---------- State ----------
WIN_LOCK="$WORKDIR/.win.lock"
WIN_PATH="$WORKDIR/.win.path"
rm -rf "$WIN_LOCK" "$WIN_PATH"

claimed() { [ -d "$WIN_LOCK" ]; }

# ---------- Worker ----------
worker() {
    local id="$1"
    local img="$WORKDIR/bf_$id.img"
    local dev

    truncate -s "$SIZE" "$img"
    dev="$(losetup -f --show "$img")"
    # shellcheck disable=SC2064
    trap "losetup -d '$dev' 2>/dev/null || true" EXIT

    local i=0 h uuid
    while ! claimed; do
        i=$((i+1))
        until mkfs.btrfs -f -q "$dev" -L "$LABEL" -U "$MAIN_UUID" >/dev/null 2>&1; do
            :
        done

        h="$(read_uuid_sub_hex "$dev")" || continue
        [ "${#h}" -eq 32 ] || continue

        if accept_hex "$h"; then
            uuid="$(hex_to_uuid "$h")"
            if mkdir "$WIN_LOCK" 2>/dev/null; then
                log ">>> MATCH  worker=$id  attempts=$i"
                log "    UUID_SUB = $uuid"
                printf '%s\n' "$img" > "$WIN_PATH"
            fi
            break
        fi
    done
}

# ---------- Run ----------
log "target     : $REAL_DEV"
log "label      : $LABEL"
log "main uuid  : $MAIN_UUID"
log "prefix     : $PREFIX"
log "exclude    : $EXCLUDE"
log "size       : $SIZE"
log "workers    : $WORKERS"
log "scratch    : $WORKDIR"
log ""

pids=()
for ((i=1; i<=WORKERS; i++)); do
    worker "$i" &
    pids+=($!)
done

# Wait for a winner
while ! claimed; do
    sleep 0.1
done

# Reap workers
for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true

WIN_IMG="$(cat "$WIN_PATH" 2>/dev/null || true)"
[ -n "$WIN_IMG" ] && [ -f "$WIN_IMG" ] || { log "no winner"; exit 1; }

# Detach any loop devices still attached to our images
while read -r d; do
    [ -n "$d" ] && losetup -d "$d" 2>/dev/null || true
done < <(losetup -j "$WORKDIR"/*.img 2>/dev/null | cut -d: -f1)

# ---------- Write to real device ----------
log ""
log ">>> Writing winner to $REAL_DEV ..."
dd if="$WIN_IMG" of="$REAL_DEV" bs=4M conv=fsync status=progress
sync

# ---------- Verify ----------
log ""
log ">>> Result on $REAL_DEV:"
blkid -s UUID -s UUID_SUB -o value "$REAL_DEV" | paste - -

# ---------- Optional resize hint ----------
REAL_BYTES=$(blockdev --getsize64 "$REAL_DEV" 2>/dev/null || echo 0)
IMG_BYTES=$(stat -c%s "$WIN_IMG" 2>/dev/null || echo 0)
if [ "$REAL_BYTES" -gt "$IMG_BYTES" ]; then
    log ""
    log "Note: real device is larger than the written image."
    log "Run:  mount $REAL_DEV /mnt && btrfs filesystem resize max /mnt && umount /mnt"
fi
