#!/bin/sh
# pager.sh - lightweight log pager for BusyBox/initramfs

FILE="$1"
LINES=30   # number of lines per page
START=1

[ -z "$FILE" ] && echo "Usage: $0 <file>" && exit 1
[ ! -f "$FILE" ] && echo "File not found: $FILE" && exit 1

while true; do
    clear
    sed -n "${START},$((START+LINES-1))p" "$FILE"
    echo
    echo "[n] next  [p] prev  [q] quit  [#] jump to line"
    read -r cmd
    case "$cmd" in
        n) START=$((START+LINES)) ;;
        p) START=$((START-LINES)); [ $START -lt 1 ] && START=1 ;;
        q) break ;;
        [0-9]*) START="$cmd" ;;
        *) echo "Unknown command" ;;
    esac
done
