# Contributing to Lanternfish

Thanks for helping out! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs

Open an issue with:

- your macOS version and Mac model,
- what you did, what you expected, and what happened instead,
- for scanning problems: the kind of network (home router, mesh, VLANs, VPN, …).

Please leave out anything private: real IP or MAC addresses, network names and device names.
Screenshots are fine if you blur those.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Development

Requirements: macOS 27 and Xcode 27 (Swift 6.4).

```sh
swift build                 # build everything
swift test                  # run the LanternfishKit tests
./scripts/build-app.sh      # build build/Lanternfish.app
./scripts/install.sh        # build, install to /Applications and open
```

Before opening a pull request:

1. `swift format --in-place --recursive Sources Tests` (the config is in `.swift-format`).
2. `swift format lint --strict --recursive Sources Tests` reports nothing.
3. `swift test` passes.
4. For UI changes, add before and after screenshots to the pull request. Use the demo network
   (`./scripts/screenshots.sh`) rather than your own.

### Code guidelines

- Engine code (scanning, parsing, naming, history) goes in `LanternfishKit` and gets unit tests. Keep it
  free of SwiftUI and AppKit.
- App code goes in `Sources/Lanternfish`; feature windows live in `Sources/Lanternfish/Features`.
- Comments explain *why*, not *what*. Doc comments for public `LanternfishKit` API.
- Test fixtures use documentation addresses (`192.0.2.x`, `198.51.100.x`, `203.0.113.x`, MAC
  `00:00:5e:00:53:xx`) and made-up names, never data from a real network.

## License of contributions

Lanternfish is licensed under the [PolyForm Shield License 1.0.0](LICENSE.md). By submitting a contribution,
you agree that it is your own work, that it may be distributed under that license, and that the
maintainer (Kriyak) may also distribute it under other license terms in the future.
