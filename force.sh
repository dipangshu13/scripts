#!/usr/bin/env bash
# btrfs-uuid-sub-bruteforce.sh
#
# Brute-forces a btrfs UUID_SUB that starts with PREFIX and contains none
# of the chars in EXCLUDE, then writes the winning filesystem to REAL_DEV.
#
# Requires (root): mkfs.btrfs, losetup, dd, od, blkid, truncate, flock
# WARNING: REAL_DEV is COMPLETELY OVERWRITTEN.

set -euo pipefail

# ---------------- Config (override via env) ----------------
REAL_DEV="${REAL_DEV:-/dev/nvme0n1p4}"
LABEL="${LABEL:-/}"
MAIN_UUID="${MAIN_UUID:-0dd13410-013a-013b-013c-1341000000f4}"
PREFIX="${PREFIX:-0dd}"
EXCLUDE="${EXCLUDE:-f5}"
SIZE="${SIZE:-1G}"
WORKERS="${WORKERS:-$(nproc)}"
WORKDIR="${WORKDIR:-/dev/shm/btrfs-uuid-bf}"

# Print a per-worker progress line every N attempts
LOG_EVERY="${LOG_EVERY:-5000}"
# Print a global heartbeat every N seconds
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-5}"

# btrfs on-disk offsets
SB_OFF=0x10000
SB_UUID_SUB_OFF=$((SB_OFF + 0x40))

# ---------------- Sanity ----------------
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
for c in mkfs.btrfs losetup dd od blkid truncate flock; do
    command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
[ -b "$REAL_DEV" ] || { echo "not a block device: $REAL_DEV" >&2; exit 1; }

mkdir -p "$WORKDIR"

# ---------------- Logging ----------------
log() { printf '%s\n' "$*" >&2; }

# ---------------- Cleanup / Ctrl+C ----------------
KEEP_RUNNING=1
cleanup() {
    trap - INT TERM EXIT
    [ "$KEEP_RUNNING" -eq 0 ] && return
    echo "" >&2
    echo ">>> Shutting down (killing workers, detaching loops)..." >&2
    jobs -p 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    pkill -9 -f "btrfs-uuid-bf" 2>/dev/null || true
    if [ -n "${WORKDIR:-}" ]; then
        while IFS=: read -r d _; do
            [ -n "$d" ] && losetup -d "$d" 2>/dev/null || true
        done < <(losetup -a 2>/dev/null | grep "$WORKDIR" || true)
    fi
    echo ">>> Done." >&2
    exit 130
}
trap cleanup INT TERM

# ---------------- Helpers ----------------
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

# ---------------- Shared state ----------------
WIN_LOCK="$WORKDIR/.win.lock"
WIN_PATH="$WORKDIR/.win.path"
rm -rf "$WIN_LOCK" "$WIN_PATH"

claimed() { [ -d "$WIN_LOCK" ]; }

# ---------------- Pre-flight ----------------
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
if mkfs.btrfs -f -q "$TEST_DEV" -L "$LABEL" -U "$MAIN_UUID" 2>/dev/null; then
    TEST_SUB="$(read_uuid_sub_hex "$TEST_DEV")"
    log "ok — sample UUID_SUB hex = $TEST_SUB"
    if [ "${#TEST_SUB}" -ne 32 ]; then
        log "ERROR: raw read returned ${#TEST_SUB} chars, expected 32."
        losetup -d "$TEST_DEV"; rm -f "$TEST_IMG"; exit 1
    fi
else
    log "ERROR: mkfs.btrfs failed on the loop device."
    losetup -d "$TEST_DEV"; rm -f "$TEST_IMG"; exit 1
fi
losetup -d "$TEST_DEV"
rm -f "$TEST_IMG"
log "Pre-flight OK. Starting $WORKERS workers..."
log ""

# ---------------- Worker ----------------
worker() {
    local id="$1"
    local img="$WORKDIR/bf_$id.img"
    local dev lockfile="$WORKDIR/.losetup.lock"

    truncate -s "$SIZE" "$img"

    # Allocate a unique loop device under a global lock.
    {
        flock -x 9
        dev="$(losetup -f 2>/dev/null || true)"
    } 9>"$lockfile"
    [ -n "$dev" ] || { log "[worker $id] could not get loop dev"; return 1; }

    # Attach ONCE. Reuse the same attached device every iteration.
    if ! losetup "$dev" "$img" 2>/dev/null; then
        log "[worker $id] losetup attach failed on $dev"
        return 1
    fi
    # shellcheck disable=SC2064
    trap "losetup -d '$dev' 2>/dev/null || true; exit 1" TERM INT HUP

    local i=0 h uuid fail=0
    while [ "$KEEP_RUNNING" -eq 1 ] && ! claimed; do
        i=$((i+1))

        if ! mkfs.btrfs -f -q "$dev" -L "$LABEL" -U "$MAIN_UUID" \
                2>"$WORKDIR/mkfs.err.$id"; then
            fail=$((fail+1))
            if [ "$fail" -le 3 ]; then
                log "[worker $id] mkfs failed (attempt $i, fail #$fail):"
                sed 's/^/    /' "$WORKDIR/mkfs.err.$id" >&2
            elif [ $((fail % 200)) -eq 0 ]; then
                log "[worker $id] still failing (fail #$fail)"
            fi
            sleep 0.05
            continue
        fi
        rm -f "$WORKDIR/mkfs.err.$id"
        fail=0

        h="$(read_uuid_sub_hex "$dev")" || true
        if [ "${#h}" -ne 32 ]; then
            continue
        fi

        if [ $((i % LOG_EVERY)) -eq 0 ]; then
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

    losetup -d "$dev" 2>/dev/null || true
}

# ---------------- Heartbeat ----------------
heartbeat() {
    local start=$SECONDS
    while [ "$KEEP_RUNNING" -eq 1 ] && ! claimed; do
        sleep "$HEARTBEAT_EVERY"
        local n
        n="$(pgrep -c -x mkfs.btrfs 2>/dev/null || echo 0)"
        log "[heartbeat] elapsed=$((SECONDS-start))s  active_mkfs=$n  workers=$WORKERS"
    done
}

# ---------------- Launch ----------------
pids=()
for ((i=1; i<=WORKERS; i++)); do
    worker "$i" &
    pids+=($!)
done

heartbeat &
HB_PID=$!

# Wait for a winner (or Ctrl+C).
while [ "$KEEP_RUNNING" -eq 1 ] && ! claimed; do
    sleep 0.2
done

# Stop heartbeat + workers.
kill "$HB_PID" 2>/dev/null || true
for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true

# Prevent cleanup from running during normal shutdown.
KEEP_RUNNING=0

WIN_IMG="$(cat "$WIN_PATH" 2>/dev/null || true)"
[ -n "$WIN_IMG" ] && [ -f "$WIN_IMG" ] || { log "no winner"; exit 1; }

# Detach any loops still hanging on our scratch images.
while IFS=: read -r d _; do
    [ -n "$d" ] && losetup -d "$d" 2>/dev/null || true
done < <(losetup -a 2>/dev/null | grep "$WORKDIR" || true)

# ---------------- Write to real device ----------------
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

log ""
log ">>> All done."
