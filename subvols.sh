#!/bin/sh
# Create test subvolumes on a btrfs mount, then delete them.
# Usage: ./subvol-test.sh [mountpoint]
# Default mountpoint is /mnt

MNT="${1:-/mnt}"
PREFIX="temp"
START=256
END=999

# --- Sanity checks ---
if [ ! -d "$MNT" ]; then
    echo "!!! $MNT does not exist"
    exit 1
fi

if ! mountpoint -q "$MNT"; then
    echo "!!! $MNT is not a mountpoint. Aborting."
    exit 1
fi

if [ "$(stat -f -c %T "$MNT")" != "btrfs" ]; then
    echo "!!! $MNT is not btrfs. Aborting."
    exit 1
fi

# --- Create ---
echo ">>> Target: $MNT"
echo ">>> Creating subvolumes ${PREFIX}${START} .. ${PREFIX}${END}"
i=$START
FAIL=0
while [ "$i" -le "$END" ]; do
    name="${PREFIX}${i}"
    if ! btrfs subvolume create "$MNT/$name" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
    fi
    i=$((i + 1))
done
echo ">>> Created. Failures: $FAIL"

# --- Verify ---
COUNT=$(btrfs subvolume list "$MNT" | grep -c "$PREFIX")
echo ">>> Subvolumes matching '$PREFIX': $COUNT"

# --- Pause before delete ---
echo
echo ">>> Press Enter to delete them all, or Ctrl+C to keep them."
read -r _

# --- Delete ---
echo ">>> Deleting subvolumes ${PREFIX}${START} .. ${PREFIX}${END}"
i=$START
FAIL=0
while [ "$i" -le "$END" ]; do
    name="${PREFIX}${i}"
    if ! btrfs subvolume delete "$MNT/$name" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
    fi
    i=$((i + 1))
done
echo ">>> Deleted. Failures: $FAIL"
echo ">>> Done."
