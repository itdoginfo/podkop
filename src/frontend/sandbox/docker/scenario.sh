#!/bin/sh
# Switch the backend stub's scenario on a running stand.
#
#   ./scenario.sh          show current
#   ./scenario.sh ok       everything works
#   ./scenario.sh fail     commands fail (empty stdout)
#   ./scenario.sh stopped  services down, Clash unreachable
#
# Reload the page afterwards.
set -e

CONTAINER=podkop-dev-router

if [ $# -eq 0 ]; then
	# A missing file is fine — the stub falls back to ok
	current=$(docker exec "$CONTAINER" cat /tmp/podkop-scenario 2>/dev/null || true)
	echo "scenario: ${current:-ok (default)}"
	exit 0
fi

case "$1" in
ok | fail | stopped) ;;
*)
	echo "unknown scenario: $1 (ok | fail | stopped)" >&2
	exit 1
	;;
esac

docker exec "$CONTAINER" sh -c "echo '$1' > /tmp/podkop-scenario"
# Drop accumulated state so the scenario starts clean
docker exec "$CONTAINER" sh -c 'rm -rf /tmp/podkop-latency /tmp/podkop-selected'
echo "scenario: $1 — reload the page"
