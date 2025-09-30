#!/bin/bash

SRC_DIR="htdocs/luci-static/resources/view/podkop"
OUT_POT="po/templates/podkop.pot"
ENCODING="UTF-8"

mapfile -t FILES < <(find "$SRC_DIR" -type f -name "*.js")
if [ ${#FILES[@]} -eq 0 ]; then
    echo "No JS files found in $SRC_DIR"
    exit 1
fi

mkdir -p "$(dirname "$OUT_POT")"

echo "Generating POT template from JS files in $SRC_DIR"
xgettext --language=JavaScript \
         --keyword=_ \
         --from-code="$ENCODING" \
         --output="$OUT_POT" \
         "${FILES[@]}"

echo "POT template generated: $OUT_POT"