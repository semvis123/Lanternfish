# Manual QA checklist (~10 min)

Install first: `./scripts/install.sh` (or `./scripts/build-app.sh` and open `build/Lanternfish.app`).
If you can, connect to two networks at once (for example Ethernet and Wi-Fi).

## Scan & table
- [ ] Devices start appearing within a second; the scan finishes in a few seconds.
- [ ] Both networks appear under the Networks menu; switching between them keeps sort order, search text and the inspector open/closed.
- [ ] ⌘R rescans (with two networks: "Rescan All Networks"); it's disabled while a scan runs.
- [ ] Start "Scan All Ports" on a device, then press ⌘R: the full port scan keeps going.
- [ ] ⌘C with a device selected copies its IP.

## Saved networks (browse one you're not connected to)
- [ ] Open in Browser / Ping / Trace are disabled and explain why.
- [ ] The menu bar still shows the live network's devices; clicking one switches the window back to the live network.

## Keyboard & windows
- [ ] ⌘K opens Quick Search, also when pressed while Airwaves or Settings is in front (the main window comes forward).
- [ ] In Quick Search, "Run Speed Test" really starts the test; closing the overview stops it.
- [ ] ⌘1 / ⌘2 switch Table / Map; ⌘+ / ⌘− / ⌘0 zoom only in Map.
- [ ] ⌥⌘I toggles the inspector; ⇧⌘O toggles offline devices; ⇧⌘E opens Airwaves.
- [ ] ⌘R inside Airwaves rescans Wi-Fi; in Service Details it inspects again; in the Overview popover it refreshes the overview.

## Map
- [ ] Scrolling zooms toward the pointer; labels stay sharp; the gateway is labeled.
- [ ] Arrow keys move the selection between nodes.
- [ ] Minimize the window for a minute: CPU in Activity Monitor drops to ~0%.

## Watch list & notifications
- [ ] Watch a device (e.g. a phone), turn its Wi-Fi off for 2 minutes: you get an "offline" alert, then "back online" after re-enabling.
- [ ] Clicking the notification opens the window with that device selected.
- [ ] Quit the app for a while, relaunch: no fake "back after N hours" alert, and that gap isn't counted as downtime.

## Persistence
- [ ] Rename a device, set a type and a note, quit (⌘Q) right away, relaunch: everything kept.
- [ ] Launching a second copy of the app doesn't corrupt history (only one should save).

## Onboarding & accessibility
- [ ] Help → Welcome: Esc closes it on every page, Return advances.
- [ ] VoiceOver (⌘F5): port chips, the watch indicator ("Watched, online") and map controls read sensibly.
- [ ] System Settings → Accessibility → Display → larger text: Quick Search scales up without clipping.
