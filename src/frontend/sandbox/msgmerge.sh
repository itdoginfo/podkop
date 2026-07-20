#!/usr/bin/env bash
set -euo pipefail

PODIR="po"
POTFILE="$PODIR/templates/podkop.pot"
WIDTH=120

if [ $# -ne 1 ]; then
    echo "Usage: $0 <language_code> (e.g., ru, de, fr)"
    exit 1
fi

LANG="$1"
POFILE="$PODIR/$LANG/podkop.po"

if [ ! -f "$POTFILE" ]; then
    echo "Template $POTFILE not found. Run xgettext first."
    exit 1
fi

if [ -f "$POFILE" ]; then
    echo "Updating $POFILE"
    msgmerge --update --width="$WIDTH" --no-location "$POFILE" "$POTFILE"
else
    echo "Creating new $POFILE using msginit"
    mkdir -p "$PODIR/$LANG"
    msginit --no-translator --no-location --locale="$LANG" --width="$WIDTH" --input="$POTFILE" --output-file="$POFILE"
fi

echo "Translation file for $LANG updated."