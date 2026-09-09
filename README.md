# Replaced Screen & Battery

A rootless Dopamine tweak for iOS 15–16 that hides replaced-part warnings for
the display and battery.

If you need a build for a iOS version outside of this i can make it. DM ME.

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

