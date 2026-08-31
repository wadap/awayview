[日本語](README.ja.md)

# AwayView

Automatically lowers your Mac's display resolution while you're screen-sharing
into it from far away — and restores it the moment you disconnect.

The point is not bandwidth: on a small remote screen (an iPad on the road,
a laptop at a café), your desktop's native resolution renders text too small
to read. AwayView switches the Mac to a lower resolution so everything is
bigger, then switches back when you leave.

## How it works
- A menu bar app polls established TCP connections to a watched port
  (default 5900 = macOS Screen Sharing) via sysctl — no root, no shell-outs.
- If the peer address falls inside configured CIDR ranges
  (default: the Tailscale range 100.64.0.0/10 + fd7a:115c:a1e0::/48),
  the display switches to a low resolution after a short settle delay.
- On disconnect it restores the previous ("home") resolution, which is
  auto-learned and guarded against mis-learning during display sleep.

## Requirements
- macOS 13+ / Apple silicon or Intel
- Xcode toolchain to build from source (`swift build`)

## Install

### Homebrew
    brew tap wadap/tap
    brew trust --tap wadap/tap    # Homebrew 6+ requires this for third-party taps
    brew install --cask awayview

Or download the notarized app from
[Releases](https://github.com/wadap/awayview/releases).

### From source
    git clone https://github.com/wadap/awayview && cd awayview
    make install       # builds dist/AwayView.app, copies to ~/Applications, launches

## Menu bar
🏠 home / 💻 low / 📌 pinned high / ⚠️ no target display.
Modes: Automatic / High resolution (home) / Low resolution (away).
Resolution pickers for both high and low sides.

The menu also shows the running version and checks GitHub for newer releases
(daily, and on demand). If AwayView was installed with Homebrew it hands you
the `brew upgrade` command rather than replacing itself; installed any other
way, it downloads the notarized build, verifies its signature, and restarts.
AwayView will not start an update while the display is lowered — switch back to
the home resolution first. If the display happens to lower while an update is
already downloading, the new version is installed but not started, and takes
effect the next time you launch AwayView. Automatic checking can be turned off
in Settings.

## Settings
Menu → Settings…: watched port, remote CIDR ranges (one per line; empty list
disables automatic switching), launch at login. Changes apply within seconds.

## Hooks
Executable files in `~/.config/awayview/hooks/on_low.d/` and `on_high.d/`
run (in name order) after each successful switch. Failures are logged and
never block the watcher.

## Observability
`~/.local/state/awayview/state` (current STATE/REMOTE_IP/CHANGED_AT) and
`~/.local/state/awayview/watch.log`.

## Uninstall
    make uninstall     # or quit from the menu and delete ~/Applications/AwayView.app
Disable "Launch at login" in Settings first if you enabled it.

## License
MIT
