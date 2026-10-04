#!/bin/sh
# Build-time cache busting for the LuCI views (run from the package Makefile).
#
# LuCI loads every JS module as <resources>/view/<name>.js?v=<LuCI core version>.
# That version changes with luci-base, not with this app, so after a NetShift
# update the browser keeps serving the previous main.js / section.js from its
# cache (uhttpd sends ETag + Last-Modified but no Cache-Control, which lets the
# browser pick its own freshness lifetime) and the UI stays on the old version.
#
# The fix is to make the module URLs themselves change with the content: the
# views are installed in view/netshift_<hash>/ instead of view/netshift/, every
# `require view.netshift.<x>` is pointed at that directory and the menu entry
# opens netshift_<hash>/netshift. A new version has new URLs, so the browser has
# nothing cached for them. The source tree keeps the plain view/netshift/ layout.
#
# Usage: cache-bust.sh <htdocs dir> <package root dir>
#   <htdocs dir>  contains luci-static/resources/view/netshift/
#   <package root> contains usr/share/luci/menu.d/luci-app-netshift.json
set -eu
# The hash must not depend on the build host's locale: glob order and md5 input
# are then the same for the ipk and the apk build.
export LC_ALL=C

HTDOCS="${1:?usage: cache-bust.sh <htdocs dir> <package root dir>}"
ROOT="${2:?usage: cache-bust.sh <htdocs dir> <package root dir>}"

VIEW="$HTDOCS/luci-static/resources/view"
MENU="$ROOT/usr/share/luci/menu.d/luci-app-netshift.json"

[ -d "$VIEW/netshift" ] || {
    echo "cache-bust: $VIEW/netshift not found" >&2
    exit 1
}
[ -f "$MENU" ] || {
    echo "cache-bust: $MENU not found" >&2
    exit 1
}

# The tag is derived from the content (including the version stamped into
# main.js), so it changes exactly when the views change and is the same for the
# same build. Files are concatenated in glob order, which LC_ALL=C makes plain
# byte order.
ls "$VIEW"/netshift/*.js > /dev/null 2>&1 || {
    echo "cache-bust: no .js views in $VIEW/netshift" >&2
    exit 1
}
# The Makefile stamps the version into main.js before this runs (and tolerates a
# failed stamp); a bundle that still carries the placeholder cannot tell its
# version, so it must not ship.
if grep -q '__COMPILED_VERSION_VARIABLE__' "$VIEW"/netshift/main.js; then
    echo "cache-bust: version placeholder not stamped in $VIEW/netshift/main.js" >&2
    exit 1
fi
tag="$(cat "$VIEW"/netshift/*.js | md5sum | cut -c1-8)"
new="netshift_$tag"

# Never move the views INTO an existing hashed directory (a second run over an
# already processed tree would otherwise fail later with a confusing sed error).
[ ! -e "$VIEW/$new" ] || {
    echo "cache-bust: $VIEW/$new already exists" >&2
    exit 1
}

mv "$VIEW/netshift" "$VIEW/$new"
sed -i -e "s/view\.netshift\./view.$new./g" "$VIEW/$new"/*.js
sed -i -e "s#\"netshift/netshift\"#\"$new/netshift\"#" "$MENU"

# A rewrite that missed something would ship a UI that cannot load: fail the
# build instead. Both the dotted (`view.netshift.x`) and the path form
# (`view/netshift/x`) must be gone, and nothing may point at another hash.
if grep -qE 'view[./]netshift[./]' "$VIEW/$new"/*.js; then
    echo "cache-bust: unrewritten view/netshift reference left in $VIEW/$new" >&2
    exit 1
fi
stale="$(grep -hoE 'view[./]netshift_[0-9a-f]+' "$VIEW/$new"/*.js | tr / . | sort -u | grep -vx "view.$new" || true)"
if [ -n "$stale" ]; then
    echo "cache-bust: reference to another view directory left in $VIEW/$new: $stale" >&2
    exit 1
fi
if ! grep -q "\"$new/netshift\"" "$MENU"; then
    echo "cache-bust: menu path was not updated in $MENU" >&2
    exit 1
fi
# Every `require` must resolve to a file of the new directory. A plain loop (not
# a pipe into `while`) so the `exit 1` really ends the script.
refs="$(grep -hoE "require view\.$new\.[A-Za-z0-9_]*" "$VIEW/$new"/*.js | sort -u | sed 's/^require //')"
for ref in $refs; do
    [ -f "$VIEW/$new/${ref#view."$new".}.js" ] || {
        echo "cache-bust: $ref has no file in $VIEW/$new" >&2
        exit 1
    }
done

echo "cache-bust: views installed as view/$new"
