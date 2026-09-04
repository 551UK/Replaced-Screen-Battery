ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

# iOS 14+ system processes use the new arm64e ABI. The open-source linker used
# by Linux Theos builds cannot emit that ABI, so building this SpringBoard tweak
# anywhere except macOS/Xcode creates a dylib that loads and then crashes on PAC.
ifneq ($(shell uname -s),Darwin)
$(error ReplacedScreenBattery must be built on macOS with Xcode for the iOS 14+ arm64e ABI)
endif

INSTALL_TARGET_PROCESSES = Preferences SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReplacedScreenBattery
ReplacedScreenBattery_FILES = Tweak.xm
ReplacedScreenBattery_CFLAGS = -fobjc-arc -Wall -Wextra
ReplacedScreenBattery_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = ReplacedScreenBatteryPrefs
ReplacedScreenBatteryPrefs_FILES = RSBRootListController.m
ReplacedScreenBatteryPrefs_CFLAGS = -fobjc-arc -Wall
ReplacedScreenBatteryPrefs_FRAMEWORKS = UIKit
ReplacedScreenBatteryPrefs_PRIVATE_FRAMEWORKS = Preferences
ReplacedScreenBatteryPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ReplacedScreenBatteryPrefs.plist$(ECHO_END)
