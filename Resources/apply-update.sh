#!/bin/sh
set -eu
pid="$1"
target="$2"
work="$3"
requirement="$4"
staged="$work/Reprise.app"
backup="$work/previous.app"

# The caller creates this private sibling directory and verifies the same signature.
case "$work" in "$(dirname "$target")"/.Reprise-update-*) ;; *) exit 2 ;; esac
[ -d "$target" ] && [ -d "$staged" ] && [ ! -L "$target" ] && [ ! -L "$work" ] || exit 2
count=0
while kill -0 "$pid" 2>/dev/null; do
    count=$((count + 1))
    [ "$count" -lt 300 ] || exit 3
    /bin/sleep 0.2
done
/usr/bin/codesign --verify --strict -R "=$requirement" "$target" || exit 4
if ! /usr/bin/codesign --verify --strict --all-architectures -R "=$requirement" "$staged"; then
    /usr/bin/open "$target"
    exit 4
fi
/bin/mv "$target" "$backup"
if ! /bin/mv "$staged" "$target"; then
    /bin/mv "$backup" "$target"
    /usr/bin/open "$target"
    exit 5
fi
if ! /usr/bin/open "$target"; then
    /bin/mv "$target" "$staged"
    /bin/mv "$backup" "$target"
    /usr/bin/open "$target"
    exit 6
fi
/bin/rm -rf "$work"
