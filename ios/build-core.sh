#!/bin/sh
# Builds ios/Frameworks/Mobile.xcframework, which Runner and PacketTunnel link.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tools="$root/build/ios-gomobile"
mkdir -p "$tools" "$root/ios/Frameworks"
config() { sed -n "s/^$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$root/build_config.yaml"; }
cd "$root/core"
go build -o "$tools/" golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
PATH="$tools:$PATH"
# gomobile links through a generated main module, which would otherwise miss
# the GODEBUG defaults core/go.mod sets.
godebug=$(go list -f '{{.DefaultGODEBUG}}' ./cmd/core 2>/dev/null || true)
[ -n "$godebug" ] || godebug=$(CGO_ENABLED=0 go list -f '{{.DefaultGODEBUG}}' ./mobile)
gomobile bind \
  -target=ios/arm64,iossimulator/arm64 \
  -iosversion=16.0 \
  -tags="$(config tags)" \
  -ldflags="$(config go_ldflags) -X=runtime.godebugDefault=$godebug" \
  -o "$root/ios/Frameworks/Mobile.xcframework" \
  ./mobile
