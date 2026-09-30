# Replaced Screen & Battery

Hides the annoying warnings in Settings after replacing your iPhone’s screen or battery.

EDIT: I have added battery health to the tweak, this returns battery health by calculating Full Charge Capacity ÷ Design Capacity x 100.

For example, if the BMS reports:
- Design Capacity = 4,323 mAh
- Full Charge Capacity = 4,323 mAh
- 
then:
4323 ÷ 4323 × 100 = 100%
  
If, after some wear, Full Charge Capacity falls to 4,100 mAh:
4100 ÷ 4323 × 100 = 94.84%

It will go down from 100,99,98... 

**Full support for iOS 15.2–18.5 on devices with working rootless tweak support.** Confirmed working on iOS 16.2 and iOS 18.2; not every version in this range has been tested but all should work. The tweak checks for iOS 18 and applies the extra fix if applicable, earlier iOS versions remain unaffected and the previous fixes remain untouched.

- Hides “Important Display Message”, “Important Battery Message” and “Unknown Part” warnings.
- Keeps **Battery Health & Charging** visible for replacement batteries and shows **Maximum Capacity** from the installed BMS using `Full Charge Capacity ÷ Design Capacity × 100` (capped at 100% for display).
- Removes the Parts & Service History section from **Settings → General → About**, including the separate clickable menu on iOS 18.
- Removes the warning in the About tab in older iOS versions.
- Reduces the Settings app badge by up to two.
- Includes an on/off switch and a Respring button in the tweak’s settings.

Install the latest deb from [Releases](https://github.com/551UK/Replaced-Screen-Battery/releases/latest), then respring. Use the switch in Settings to turn it on or off, and respring after changing it.

This only changes what Settings displays. It does not repair or pair replacement parts, change genuine/verification status, reset the BMS, or alter the phone’s repair history. The replacement-battery percentage is calculated from capacity data reported by the installed BMS/gas gauge. Turning the tweak off or uninstalling it brings the original information back.

**Made by 551.**
