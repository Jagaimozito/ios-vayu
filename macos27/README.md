# macos27/

Working area for the macOS 27.2 (26B123, Mac17,5) bring-up: device-tree profile, kernel diffs, root-image notes and
launchd changes that are specific to macOS. Shared code stays where it is on `ios27` (`xnu/`, `userland/`,
`tools/`, `shim/`). Plan: [`../docs/macos27.md`](../docs/macos27.md).

Apple artifacts (IPSW, filesystems, kernelcaches, dumps) never go here: use `research/macos27/`, which is git-ignored.
