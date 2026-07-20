#!/bin/sh
# Start the stand, picking the OpenWrt image for the host arch.
#
# openwrt/rootfs has no multiarch manifest, and the arm image declares
# aarch64_generic rather than arm64 — without both the tag and the platform,
# the build fails with "no match for platform in manifest".
#
# Override: OPENWRT_TAG=... ./up.sh
set -e

OPENWRT_RELEASE=25.12.4

if [ -z "$OPENWRT_TAG" ]; then
	case "$(uname -m)" in
	arm64 | aarch64)
		OPENWRT_TAG="armsr-armv8-$OPENWRT_RELEASE"
		OPENWRT_PLATFORM="linux/aarch64_generic"
		;;
	x86_64 | amd64)
		OPENWRT_TAG="x86-64-$OPENWRT_RELEASE"
		OPENWRT_PLATFORM="linux/amd64"
		;;
	*)
		echo "unknown arch $(uname -m); set OPENWRT_TAG manually" >&2
		exit 1
		;;
	esac
fi

echo "image: openwrt/rootfs:$OPENWRT_TAG ($OPENWRT_PLATFORM)"
OPENWRT_TAG="$OPENWRT_TAG" OPENWRT_PLATFORM="$OPENWRT_PLATFORM" \
	docker compose up -d --build "$@"

echo
echo "ui:        http://localhost:8080 -> Services -> Podkop (root, empty password)"
echo "scenarios: ./scenario.sh ok | fail | stopped"
