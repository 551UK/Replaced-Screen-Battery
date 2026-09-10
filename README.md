# Replaced Screen & Battery

A rootless tweak that hides replaced display/battery warnings and Settings badges.
The existing iOS 15–16 behaviour is preserved. Version 1.0.14 adds iOS 18 hooks
for the entire **Parts & Service History** section in **Settings → General → About**.
The iOS 18.5 change still needs confirmation on a device with working tweak injection.

If you need a build for another iOS version, DM me.

It targets both places involved:

- `Preferences`: removes SystemHealthUI specifiers and filters the visible
  "Important Display Message", "Important Battery Message", genuine-part, and
  "Unknown Part" rows.
- `SpringBoard`: subtracts up to two badges contributed by the display and
  battery warnings. Any Settings badge count above those two is preserved.
- `Settings`: provides a master enable/disable switch and a direct link to the
  GitHub repository.

This is a cosmetic tweak. It does not modify, pair, or falsify hardware data.
Disabling or uninstalling the tweak restores the original warnings.


### iOS 18 change

iOS 18 can insert the section during an asynchronous refresh, bypassing the
older cached-specifier getter. The new hooks return an empty section from
`reloadCurrentSystemHealthInfoSpecifiers` and pass an empty list through
`_updateSpecifiers:specifierToInsertAfter:withUpdates:`. The original update
removes both `PARTS_AND_SERVICE_GROUP` and `MAIN_PARTS_AND_SERVICE`, so no
empty section is left behind. Apple's update/callback flow is retained.

These extra hooks only install on iOS 18 when both methods exist. Turning the
master switch off passes the original arguments and results through; use Respring
after changing it. This package requires an environment that can load rootless
tweaks into Settings; installing a deb alone does not provide that capability.

Implementation reference: [iOS 18.2 SystemHealthUI decompilation](https://github.com/EthanArbuckle/iPhone17-1_18.2_22C152_Restore/blob/main/System/Library/PrivateFrameworks/CoreRepairUI.framework/SystemHealthUI.m).
This establishes the iOS 18 refresh path; it is not an on-device iOS 18.5 test.
