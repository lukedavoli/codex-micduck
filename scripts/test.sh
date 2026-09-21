#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
python3 scripts/test-packaging.py
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-micduck-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

swiftc -swift-version 5 \
  Sources/CodexSpotifyDuck/VolumePolicy.swift \
  Tests/VolumePolicyTestRunner.swift -o "$test_dir/volume-policy"
"$test_dir/volume-policy"

swiftc -swift-version 5 \
  Sources/CodexSpotifyDuck/LaunchAtLoginManager.swift \
  Tests/LaunchAtLoginTestRunner.swift -o "$test_dir/launch-at-login"
"$test_dir/launch-at-login"

swiftc -swift-version 5 \
  Sources/CodexSpotifyDuck/AppConstants.swift \
  Sources/CodexSpotifyDuck/VolumePolicy.swift \
  Sources/CodexSpotifyDuck/MicrophoneOperationGate.swift \
  Sources/CodexSpotifyDuck/SpotifyVolumeClient.swift \
  Sources/CodexSpotifyDuck/SpotifyController.swift \
  Tests/SpotifyControllerTestRunner.swift \
  -framework AppKit -framework ScriptingBridge -o "$test_dir/spotify-controller"
"$test_dir/spotify-controller"
