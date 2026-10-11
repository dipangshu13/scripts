#!/usr/bin/env bash
# btrfs-uuid-sub-bruteforce-dm.sh
set -euo pipefail

# ---------------- Config ----------------
REAL_DEV="${REAL_DEV:-/dev/nvme0n1p4}"
LABEL="${LABEL:-/}"
MAIN_UUID="${MAIN_UUID:-0dd13410-013a-013b-013c-1341000000f4}"
PREFIX="${PREFIX:-0dd}"
EXCLUDE="${EXCLUDE:-f5}"
SIZE="${SIZE:-1G}"
WORKERS="${WORKERS:-$(nproc)}"
WORKDIR="${WORKDIR:-/dev/shm/btrfs-uuid-bf}"

LOG_EVERY="${LOG_EVERY:-5000}"
HEARTBEAT_EVERY="${HEARTBEAT_EVERY:-5}"

SB_OFF=0x10000
SB_UUID_SUB_OFF=$((SB_OFF + 0x40))

# ---------------- Sanity ----------------
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
for c in mkfs.btrfs dmsetup dd od blkid truncate grep; do
    command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
done
[ -b "$REAL_DEV" ] || { echo "not a block device: $REAL_DEV" >&2; exit 1; }

mkdir -p "$WORKDIR"
log() { printf '%s\n' "$*" >&2; }

# ---------------- Cleanup ----------------
KEEP_RUNNING=1
declare -a DM_NAMES=()

cleanup() {
    trap - INT TERM EXIT
    [ "$KEEP_RUNNING" -eq 0 ] && return
    echo "" >&2
    echo ">>> Shutting down..." >&2
    jobs -p 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    pkill -9 -f "btrfs-uuid-bf" 2>/dev/null || true
    for n in "${DM_NAMES[@]:-}"; do
        [ -n "$n" ] && dmsetup remove "$n" 2>/dev/null || true
    done
    echo ">>> Done." >&2
    exit 130
}
trap cleanup INT TERM

# ---------------- Helpers ----------------
read_uuid_sub_hex() {
    dd if="$1" bs=1 skip="$SB_UUID_SUB_OFF" count=16 \
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
    printf '%s-%s-%s-%s-%s' \
        "${1:0:8}" "${1:8:4}" "${1:12:4}" "${1:16:4}" "${1:20:12}"
}

# ---------------- Shared ----------------
WIN_LOCK="$WORKDIR/.win.lock"
WIN_PATH="$WORKDIR/.win.path"
rm -rf "$WIN_LOCK" "$WIN_PATH"
claimed() { [ -d "$WIN_LOCK" ]; }

# ---------------- Preflight: allocate DM devices ----------------
log "=== Pre-flight ==="
log "target : $REAL_DEV"
log "size   : $SIZE"
log "workers: $WORKERS"
log "scratch: $WORKDIR"
log ""

declare -a DM_DEVS=()
declare -a DM_FILES=()

log "Allocating $WORKERS device-mapper volumes..."
for ((i=1; i<=WORKERS; i++)); do
    img="$WORKDIR/bf_$i.img"
    name="bfu$i"

    truncate -s "$SIZE" "$img"
    DM_FILES[$i]="$img"

    sectors=$(( $(stat -c%s "$img") / 512 ))
    echo "0 $sectors linear $img 0" | dmsetup create "$name"

    DM_NAMES+=("$name")
    DM_DEVS[$i]="/dev/mapper/$name"
done
log "Allocated: ${DM_DEVS[*]}"
log ""

# Quick verify: mkfs once on one DM device
if ! mkfs.btrfs -f -q "${DM_DEVS[1]}" -L "$LABEL" -U "$MAIN_UUID" 2>/dev/null; then
    log "ERROR: mkfs.btrfs failed on ${DM_DEVS[1]}"
    cleanup
fi
log "mkfs on ${DM_DEVS[1]} OK. Starting workers..."
log ""

# ---------------- Worker ----------------
worker() {
    local id="$1"
    local dev="${DM_DEVS[$id]}"
    local img="${DM_FILES[$id]}"

    local i=0 h uuid fail=0
    while [ "$KEEP_RUNNING" -eq 1 ] && ! claimed; do
        i=$((i+1))

        if ! mkfs.btrfs -f -q "$dev" -L "$LABEL" -U "$MAIN_UUID" \
                2>"$WORKDIR/mkfs.err.$id"; then
            fail=$((fail+1))
            if [ "$fail" -le 3 ] || [ $((fail % 500)) -eq 0 ]; then
                log "[worker $id] mkfs failed (attempt $i, fail #$fail):"
                sed 's/^/    /' "$WORKDIR/mkfs.err.$id" >&2
            fi
            sleep 0.2
            continue
        fi
        rm -f "$WORKDIR/mkfs.err.$id"
        fail=0

        h="$(read_uuid_sub_hex "$dev")" || true
        [ "${#h}" -eq 32 ] || continue

        if [ $((i % LOG_EVERY)) -eq 0 ]; then
            log "[worker $id] attempt=$i  last=$(hex_to_uuid "$h")"
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

while [ "$KEEP_RUNNING" -eq 1 ] && ! claimed; do sleep 0.2; done

kill "$HB_PID" 2>/dev/null || true
for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true
KEEP_RUNNING=0

WIN_IMG="$(cat "$WIN_PATH" 2>/dev/null || true)"
[ -n "$WIN_IMG" ] && [ -f "$WIN_IMG" ] || { log "no winner"; cleanup; }

# Remove DM devices
for n in "${DM_NAMES[@]}"; do
    dmsetup remove "$n" 2>/dev/null || true
done

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
    log "Resize: mount $REAL_DEV /mnt && btrfs filesystem resize max /mnt && umount /mnt"
fi

log ""
log ">>> All done."
