#!/bin/sh
DEV="/dev/nvme0n1p4"
LABEL="/"
UUID="0dd13410-013a-013b-013c-1341000000f4"

i=0
while :; do
    i=$((i+1))
    echo ">>> Attempt #$i"

    until mkfs.btrfs -f "$DEV" -L "$LABEL" -U "$UUID" >/dev/null 2>&1; do
        :
    done

    UUID_SUB=$(blkid -s UUID_SUB -o value "$DEV")
    echo "    UUID_SUB = $UUID_SUB"

    case "$UUID_SUB" in
        0dd*) echo ">>> MATCH after $i attempt(s)"; break ;;
    esac
done
