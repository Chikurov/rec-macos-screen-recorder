#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

swiftc -O -o "$WORKDIR/audio-check" \
    Sources/Rec/AudioMixer.swift \
    Sources/Rec/AudioTrackWriter.swift \
    Sources/Rec/RecordingEngine.swift \
    Tools/AudioPipelineCheck/main.swift
"$WORKDIR/audio-check" "$WORKDIR"
