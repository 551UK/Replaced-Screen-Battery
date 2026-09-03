# Replaced Screen & Battery

A rootless Dopamine tweak for iOS 15–16 that hides replaced-part warnings for
the display and battery.

It targets both places involved:

- `Preferences`: removes SystemHealthUI specifiers and filters the visible
  "Important Display Message", "Important Battery Message", genuine-part, and
  "Unknown Part" rows.
- `SpringBoard`: subtracts the one badge contributed by the parts warning from
  the Settings app icon. Any additional Settings badge count is preserved.
- `Settings`: provides a master enable/disable switch and a direct link to the
  GitHub repository.

This is a cosmetic tweak. It does not modify, pair, or falsify hardware data.
Disabling or uninstalling the tweak restores the original warnings.

## Compared with the original Replaced tweak

The original [Replaced tweak](https://github.com/34306/replaced/blob/main/Tweak.xm)
is a compact 10-line `SystemHealthUI` hook. It removes the Parts and Service and
Unknown Part entries from General > About, but does not handle the persistent
Settings-home warning or the Settings app badge.

Replaced Screen & Battery expands that idea into a complete rootless iOS 15–16
tweak. It removes the display and battery messages before Settings builds their
rows, removes the About entries, subtracts the warning's single Settings badge
without hiding unrelated badges, and provides a master switch and Respring
button.

## Compatibility

- iOS 15.0–16.x
- Dopamine/rootless jailbreak
- arm64 and arm64e devices

## Build

This tweak must be built on macOS with Xcode because it injects into the
arm64e SpringBoard process. The Makefile intentionally rejects Linux builds:
the Linux linker can only produce the old arm64e ABI, which is incompatible
with iOS 14 and later.

```sh
gmake clean package FINALPACKAGE=1
```

The rootless `.deb` will be placed in `packages/`. Pushing to GitHub also runs
the included workflow and uploads the package as a workflow artifact.

## Install

Install the generated `.deb` in Sileo or Zebra, then respring. If the warning
inside Settings was already open, force-close Settings once after the respring.

If Choicy is installed, tweak injection must be enabled for both Settings and
SpringBoard.

## Credits

Made by 551.
