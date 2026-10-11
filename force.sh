#!/usr/bin/env bash
# btrfs-uuid-sub-bruteforce.sh  (verbose / NixOS-safe)
#
# Brute-forces a btrfs UUID_SUB. Prints live progress.

set -euo pipefail

# ---------- Config (override via env) ----------
REAL_DEV="${REAL_DEV:-/dev/nvme0n1p4}"
LABEL="${LABEL:-/}"
MAIN_UUID="${MAIN_UUID:-0dd13410-013a-013b-013c-1341000000f4}"
PREFIX="${PREFIX:-0dd}"
EXCLUDE="${EXCLUDE:-f5}"
SIZE="${SIZE:-128M}"
WORKERS="${WORKERS:-$(nproc)}"
WORKDIR="${WORKDIR:-/dev/shm/btrfs-uuid-bf}"

# How often each worker prints progress (attempts)
LOG_EVERY="${LOG_EVERY:-2000}"

# btrfs on-disk offsets
SB_OFF=0x10000
SB_UUID_SUB_OFF=$((SB_OFF + 0x40))

# ---------- Sanity ----------
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
for c in mkfs.btrfs losetup dd od blkid truncate; do
    command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
[ -b "$REAL_DEV" ] || { echo "not a block device: $REAL_DEV" >&2; exit 1; }

mkdir -p "$WORKDIR"

# ---------- Helpers ----------
log() { printf '%s\n' "$*" >&2; }

# Read UUID_SUB from raw superblock as 32-char hex (od, no xxd needed)
read_uuid_sub_hex() {
    local dev="$1"
    dd if="$dev" bs=1 skip="$SB_UUID_SUB_OFF" count=16 \
       iflag=skip_bytes,count_bytes 2>/dev/null \
    | od -An -tx1 | tr -d ' \n'
}

accept_hex() {
    local h="$1" c i
    [ "${h:0:${#PREFIX}}" = "$PREFIX" ] || return 1
    for ((i=0; i<${#h}; i++)); do
        c="${h:i:1}"
        case "$EXCLUDE" in *"$c"*) return 1 ;; esac
    done
    return 0
}

hex_to_uuid() {
    local h="$1"
    printf '%s-%s-%s-%s-%s' \
        "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# ---------- Shared state ----------
WIN_LOCK="$WORKDIR/.win.lock"
WIN_PATH="$WORKDIR/.win.path"
TOTAL_FILE="$WORKDIR/.total"      # atomic-ish attempt counter
rm -rf "$WIN_LOCK" "$WIN_PATH"
echo 0 > "$TOTAL_FILE"

claimed() { [ -d "$WIN_LOCK" ]; }

# ---------- Pre-flight check ----------
log "=== Pre-flight ==="
log "target     : $REAL_DEV"
log "label      : $LABEL"
log "main uuid  : $MAIN_UUID"
log "prefix     : $PREFIX"
log "exclude    : $EXCLUDE"
log "size       : $SIZE"
log "workers    : $WORKERS"
log "scratch    : $WORKDIR"
log ""

log "Testing a single mkfs cycle..."
TEST_IMG="$WORKDIR/.test.img"
truncate -s "$SIZE" "$TEST_IMG"
TEST_DEV="$(losetup -f --show "$TEST_IMG")"
if mkfs.btrfs -f -q "$TEST_DEV" -L "$LABEL" -U "$MAIN_UUID" 2>&1; then
    TEST_SUB="$(read_uuid_sub_hex "$TEST_DEV")"
    log "ok — sample UUID_SUB hex = $TEST_SUB"
    [ "${#TEST_SUB}" -eq 32 ] || {
        log "ERROR: raw read returned ${#TEST_SUB} chars, expected 32."
        log "Check the SB offset or byte order."
        losetup -d "$TEST_DEV"; rm -f "$TEST_IMG"; exit 1
    }
else
    log "ERROR: mkfs.btrfs failed on the loop device (see above)."
    losetup -d "$TEST_DEV"; rm -f "$TEST_IMG"; exit 1
fi
losetup -d "$TEST_DEV"
rm -f "$TEST_IMG"
log "Pre-flight OK. Starting $WORKERS workers..."
log ""

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

        # mkfs — log first failure to help debugging
        if ! mkfs.btrfs -f -q "$dev" -L "$LABEL" -U "$MAIN_UUID" 2>"$WORKDIR/mkfs.err.$id"; then
            log "[worker $id] mkfs FAILED on attempt $i:"
            sed 's/^/    /' "$WORKDIR/mkfs.err.$id" >&2
            rm -f "$WORKDIR/mkfs.err.$id"
            sleep 1
            continue
        fi
        rm -f "$WORKDIR/mkfs.err.$id"

        h="$(read_uuid_sub_hex "$dev")" || true
        [ "${#h}" -eq 32 ] || {
            log "[worker $id] bad raw read (${#h} chars): '$h'"
            continue
        }

        # progress line
        if (( i % LOG_EVERY == 0 )); then
            uuid="$(hex_to_uuid "$h")"
            log "[worker $id] attempt=$i  last=$uuid"
        fi

        if accept_hex "$h"; then
            uuid="$(hex_to_uuid "$h")"
            if mkdir "$WIN_LOCK" 2>/dev/null; then
                log ""
                log ">>> MATCH  worker=$id  attempts=$i"
                log "    UUID_SUB = $uuid"
                printf '%s\n' "$img" > "$WIN_PATH"
            fi
            break
        fi
    done
}

# ---------- Heartbeat ----------
heartbeat() {
    local start=$SECONDS
    while ! claimed; do
        sleep 5
        local n
        n="$(ps -eo cmd= | grep -c '[m]kfs.btrfs' || true)"
        log "[heartbeat] elapsed=$((SECONDS-start))s  active_mkfs=$n  workers=$WORKERS"
    done
}

# ---------- Run ----------
pids=()
for ((i=1; i<=WORKERS; i++)); do
    worker "$i" &
    pids+=($!)
done

heartbeat &
HB_PID=$!

# Wait for a winner
while ! claimed; do sleep 0.2; done

kill "$HB_PID" 2>/dev/null || true
for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true

WIN_IMG="$(cat "$WIN_PATH" 2>/dev/null || true)"
[ -n "$WIN_IMG" ] && [ -f "$WIN_IMG" ] || { log "no winner"; exit 1; }

# Detach loop devices
while read -r d; do
    [ -n "$d" ] && losetup -d "$d" 2>/dev/null || true
done < <(losetup -j "$WORKDIR"/*.img 2>/dev/null | cut -d: -f1)

# ---------- Write to real device ----------
log ""
log ">>> Writing winner to $REAL_DEV ..."
dd if="$WIN_IMG" of="$REAL_DEV" bs=4M conv=fsync status=progress
sync

log ""
log ">>> Result on $REAL_DEV:"
blkid -s UUID -s UUID_SUB -o value "$REAL_DEV" | paste - -

REAL_BYTES=$(blockdev --getsize64 "$REAL_DEV" 2>/dev/null || echo 0)
IMG_BYTES=$(stat -c%s "$WIN_IMG" 2>/dev/null || echo 0)
if [ "$REAL_BYTES" -gt "$IMG_BYTES" ]; then
    log ""
    log "Note: real device is larger than the written image."
    log "Run:  mount $REAL_DEV /mnt && btrfs filesystem resize max /mnt && umount /mnt"
fi
