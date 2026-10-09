#!/bin/zsh
set -eu
cd "${0:A:h}/.."
check_dir=$(mktemp -d /tmp/herdr-notch-check.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
cp tests/NavigationChecks.swift "$check_dir/main.swift"
swiftc Sources/HerdrNotch/Models.swift Sources/HerdrNotch/InventoryStream.swift Sources/HerdrNotch/GhosttyNavigation.swift Sources/HerdrNotch/TerminalChoice.swift Sources/HerdrNotch/ClientView.swift tests/InventoryChecks.swift tests/TerminalChoiceChecks.swift tests/ClientViewChecks.swift tests/WalkChecks.swift "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
