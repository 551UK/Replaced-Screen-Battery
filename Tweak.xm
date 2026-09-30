#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <mach/mach.h>
#import <math.h>

// Replaced Screen & Battery
// iOS 15-16, with additional iOS 18 Parts & Service History hooks.

static BOOL RSBEnabled = YES;
static BOOL RSBSystemHealthHooksInitialized = NO;
static BOOL RSBFollowUpHooksInitialized = NO;
static BOOL RSBBatteryUIHooksInitialized = NO;

static void RSBInitializeSystemHealthHooks(void);
static void RSBLoadAndHookSystemHealthFramework(void);
static void RSBInitializeFollowUpHooks(void);
static void RSBLoadAndHookFollowUpFramework(void);
static void RSBInitializeBatteryUIHooks(void);

static void RSBLoadPreferences(void) {
    @autoreleasepool {
        NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.551.replacedscreenbattery.plist"];
        id value = preferences[@"enabled"];
        RSBEnabled = value ? [value boolValue] : YES;
    }
}

static void RSBPreferencesChanged(CFNotificationCenterRef __unused center,
                                  void * __unused observer,
                                  CFStringRef __unused name,
                                  const void * __unused object,
                                  CFDictionaryRef __unused userInfo) {
    RSBLoadPreferences();
}


typedef CFMutableDictionaryRef (*RSBIOServiceMatchingFn)(const char *);
typedef mach_port_t (*RSBIOServiceGetMatchingServiceFn)(mach_port_t, CFDictionaryRef);
typedef kern_return_t (*RSBIORegistryEntryCreateCFPropertiesFn)(
    mach_port_t, CFMutableDictionaryRef *, CFAllocatorRef, UInt32);
typedef kern_return_t (*RSBIOObjectReleaseFn)(mach_port_t);

static RSBIOServiceMatchingFn RSBIOServiceMatching = NULL;
static RSBIOServiceGetMatchingServiceFn RSBIOServiceGetMatchingService = NULL;
static RSBIORegistryEntryCreateCFPropertiesFn RSBIORegistryEntryCreateCFProperties = NULL;
static RSBIOObjectReleaseFn RSBIOObjectRelease = NULL;

static void RSBInitializeIOKitFunctions(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                             RTLD_LAZY | RTLD_LOCAL);
        if (!handle) return;

        RSBIOServiceMatching = (RSBIOServiceMatchingFn)dlsym(handle, "IOServiceMatching");
        RSBIOServiceGetMatchingService =
            (RSBIOServiceGetMatchingServiceFn)dlsym(handle, "IOServiceGetMatchingService");
        RSBIORegistryEntryCreateCFProperties =
            (RSBIORegistryEntryCreateCFPropertiesFn)dlsym(handle, "IORegistryEntryCreateCFProperties");
        RSBIOObjectRelease = (RSBIOObjectReleaseFn)dlsym(handle, "IOObjectRelease");
    });
}

// Read the same capacity properties Battman uses, but directly from the
// installed battery's power-source registry entry. Nothing is written to the
// BMS and no genuine/paired status is changed.
static NSDictionary *RSBCopyBatteryPowerProperties(void) {
    RSBInitializeIOKitFunctions();
    if (!RSBIOServiceMatching ||
        !RSBIOServiceGetMatchingService ||
        !RSBIORegistryEntryCreateCFProperties) {
        return nil;
    }

    static const char *serviceNames[] = {
        "IOPMPowerSource",
        "AppleSmartBattery"
    };

    for (NSUInteger index = 0;
         index < sizeof(serviceNames) / sizeof(serviceNames[0]);
         index++) {
        CFMutableDictionaryRef matching = RSBIOServiceMatching(serviceNames[index]);
        if (!matching) continue;

        mach_port_t service =
            RSBIOServiceGetMatchingService(MACH_PORT_NULL, matching);
        if (service == MACH_PORT_NULL) continue;

        CFMutableDictionaryRef properties = NULL;
        kern_return_t result =
            RSBIORegistryEntryCreateCFProperties(service,
                                                 &properties,
                                                 kCFAllocatorDefault,
                                                 0);
        if (RSBIOObjectRelease) RSBIOObjectRelease(service);

        if (result == KERN_SUCCESS && properties) {
            return CFBridgingRelease(properties);
        }
        if (properties) CFRelease(properties);
    }

    return nil;
}

static NSInteger RSBReplacementBatteryHealthPercent(void) {
    NSDictionary *properties = RSBCopyBatteryPowerProperties();
    NSNumber *fullCapacity = properties[@"AppleRawMaxCapacity"];
    NSNumber *designCapacity = properties[@"DesignCapacity"];

    if (![fullCapacity isKindOfClass:NSNumber.class] ||
        ![designCapacity isKindOfClass:NSNumber.class]) {
        return -1;
    }

    double full = fullCapacity.doubleValue;
    double design = designCapacity.doubleValue;
    if (!isfinite(full) || !isfinite(design) || full <= 0.0 || design <= 0.0) {
        return -1;
    }

    // Match Battman's health calculation:
    // 100 * Full Charge Capacity / Design Capacity.
    double health = 100.0 * full / design;
    if (!isfinite(health) || health < 0.0 || health > 200.0) {
        return -1;
    }

    NSInteger roundedHealth = (NSInteger)llround(health);
    // Apple's Battery Health UI does not display values above 100%.
    if (roundedHealth > 100) roundedHealth = 100;
    if (roundedHealth < 0) roundedHealth = 0;
    return roundedHealth;
}

static NSString *RSBReplacementBatteryHealthString(void) {
    NSInteger health = RSBReplacementBatteryHealthPercent();
    if (health < 0) return nil;

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterPercentStyle;
    formatter.maximumFractionDigits = 0;
    formatter.minimumFractionDigits = 0;
    return [formatter stringFromNumber:@((double)health / 100.0)];
}

static BOOL RSBInstalledBatteryIsUnverified(void) {
    Class resourceClass = objc_getClass("BatteryUIResourceClass");
    if (!resourceClass) return NO;

    SEL unverifiedSelector = NSSelectorFromString(@"isBatteryUnverified");
    if ([resourceClass respondsToSelector:unverifiedSelector]) {
        BOOL (*implementation)(id, SEL) =
            (BOOL (*)(id, SEL))objc_msgSend;
        return implementation(resourceClass, unverifiedSelector);
    }

    // Older BatteryUsageUI versions expose only genuineBatteryStatus.
    // Apple's value 1 is the normal/genuine state; replacement/unverified
    // batteries use another state.
    SEL statusSelector = NSSelectorFromString(@"genuineBatteryStatus");
    if ([resourceClass respondsToSelector:statusSelector]) {
        NSInteger (*implementation)(id, SEL) =
            (NSInteger (*)(id, SEL))objc_msgSend;
        return implementation(resourceClass, statusSelector) != 1;
    }

    return NO;
}

static BOOL RSBStringContainsWarning(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0) return NO;

    NSString *text = value.lowercaseString;
    static NSArray<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[
            @"important display message",
            @"important battery message",
            @"unable to verify this iphone has a genuine apple display",
            @"unable to verify this iphone has a genuine apple battery",
            @"unable to verify this iphone has a genuine apple part",
            @"unknown part",
            @"systemhealthui",
            @"system_health",
            @"system-health",
            @"display_message",
            @"battery_message",
            @"displaymessage",
            @"batterymessage",
            @"important_display_message",
            @"important_battery_message",
            @"unable_to_verify_display",
            @"unable_to_verify_battery",
            @"com.apple.mobilerepair.displayrepair",
            @"com.apple.mobilerepair.batteryrepair"
        ];
    });

    for (NSString *marker in markers) {
        if ([text containsString:marker]) return YES;
    }
    return NO;
}

static id RSBCallObjectSelector(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    id (*implementation)(id, SEL) = (id (*)(id, SEL))[object methodForSelector:selector];
    return implementation ? implementation(object, selector) : nil;
}


static BOOL RSBIsBatteryHealthSpecifier(id specifier) {
    if (!specifier) return NO;

    id identifier = RSBCallObjectSelector(specifier, NSSelectorFromString(@"identifier"));
    if ([identifier isKindOfClass:NSString.class]) {
        NSString *upper = [(NSString *)identifier uppercaseString];
        if ([upper isEqualToString:@"BATTERY_HEALTH_TITLE"] ||
            [upper isEqualToString:@"BATTERY_HEALTH"] ||
            [upper isEqualToString:@"BATTERY_HEALTH_ID"]) {
            return YES;
        }
    }

    id name = RSBCallObjectSelector(specifier, NSSelectorFromString(@"name"));
    if ([name isKindOfClass:NSString.class]) {
        NSString *lower = [(NSString *)name lowercaseString];
        if ([lower containsString:@"battery health"]) return YES;
    }

    return NO;
}

static BOOL RSBViewContainsBatteryHealthTitle(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text.lowercaseString;
        if ([text containsString:@"battery health"]) return YES;
    }

    for (UIView *subview in view.subviews) {
        if (RSBViewContainsBatteryHealthTitle(subview)) return YES;
    }
    return NO;
}

static void RSBClearWarningLabelsInView(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (RSBStringContainsWarning(label.text)) {
            label.text = @"";
            label.attributedText = [[NSAttributedString alloc] initWithString:@""];
            label.hidden = YES;
            return;
        }
    }

    for (UIView *subview in view.subviews) {
        RSBClearWarningLabelsInView(subview);
    }
}

static BOOL RSBObjectContainsWarning(id object, NSUInteger depth) {
    if (!object || depth > 5) return NO;
    if ([object isKindOfClass:NSString.class]) {
        return RSBStringContainsWarning((NSString *)object);
    }
    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class]) {
        for (id value in object) {
            if (RSBObjectContainsWarning(value, depth + 1)) return YES;
        }
        return NO;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id key in object) {
            if (RSBObjectContainsWarning(key, depth + 1) ||
                RSBObjectContainsWarning(object[key], depth + 1)) return YES;
        }
    }
    return NO;
}

static BOOL RSBSpecifierOrFollowUpContainsWarning(id object) {
    if (!object) return NO;

    NSArray<NSString *> *selectors = @[
        @"name", @"identifier", @"properties", @"userInfo",
        @"clientIdentifier", @"uniqueIdentifier", @"typeIdentifier",
        @"categoryIdentifier", @"collectionIdentifier", @"groupIdentifier",
        @"title", @"informativeText", @"informativeFooterText",
        @"targetBundleIdentifier"
    ];
    for (NSString *selectorName in selectors) {
        id value = RSBCallObjectSelector(object, NSSelectorFromString(selectorName));
        if (RSBObjectContainsWarning(value, 0)) return YES;
    }
    return NO;
}

static BOOL RSBIsFollowUpGroupSpecifier(id specifier) {
    id identifier = RSBCallObjectSelector(specifier, NSSelectorFromString(@"identifier"));
    if (![identifier isKindOfClass:NSString.class]) return NO;
    return [[identifier lowercaseString] hasPrefix:@"followups:"];
}

static id RSBFilteredFollowUpSpecifiers(id specifiers) {
    if (!RSBEnabled || ![specifiers isKindOfClass:NSArray.class]) return specifiers;

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:[specifiers count]];
    BOOL changed = NO;
    for (id specifier in (NSArray *)specifiers) {
        if (RSBSpecifierOrFollowUpContainsWarning(specifier)) {
            changed = YES;
        } else {
            [filtered addObject:specifier];
        }
    }

    // CoreFollowUp creates a group specifier before its rows. If the repair
    // alert was that group's only row, remove the now-orphaned group too so it
    // cannot contribute spacing to the Settings home page.
    for (NSInteger index = (NSInteger)filtered.count - 1; index >= 0; index--) {
        if (!RSBIsFollowUpGroupSpecifier(filtered[(NSUInteger)index])) continue;
        BOOL hasRow = NO;
        for (NSUInteger next = (NSUInteger)index + 1; next < filtered.count; next++) {
            if (RSBIsFollowUpGroupSpecifier(filtered[next])) break;
            hasRow = YES;
            break;
        }
        if (!hasRow) {
            [filtered removeObjectAtIndex:(NSUInteger)index];
            changed = YES;
        }
    }
    return changed ? [filtered copy] : specifiers;
}

static id RSBCallObjectSelectorWithObject(id object, SEL selector, id argument) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    id (*implementation)(id, SEL, id) = (id (*)(id, SEL, id))[object methodForSelector:selector];
    return implementation ? implementation(object, selector, argument) : nil;
}

static void RSBCallVoidSelectorWithObjectAndBool(id object, SEL selector, id argument, BOOL flag) {
    if (!object || ![object respondsToSelector:selector]) return;
    void (*implementation)(id, SEL, id, BOOL) =
        (void (*)(id, SEL, id, BOOL))[object methodForSelector:selector];
    if (implementation) implementation(object, selector, argument, flag);
}

static BOOL RSBViewContainsWarning(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        if (RSBStringContainsWarning(((UILabel *)view).text)) return YES;
    }
    for (UIView *subview in view.subviews) {
        if (RSBViewContainsWarning(subview)) return YES;
    }
    return NO;
}

static UITableView *RSBTableViewContainingView(UIView *view) {
    UIView *candidate = view.superview;
    while (candidate) {
        if ([candidate isKindOfClass:UITableView.class]) return (UITableView *)candidate;
        candidate = candidate.superview;
    }
    return nil;
}

static char RSBRemovalScheduledKey;

static void RSBHideWarningCellIfNeeded(UITableViewCell *cell) {
    if (!RSBEnabled || !cell || !RSBViewContainsWarning(cell)) return;

    UITableView *tableView = RSBTableViewContainingView(cell);
    NSIndexPath *indexPath = [tableView indexPathForCell:cell];
    id controller = tableView.delegate;
    SEL specifierSelector = NSSelectorFromString(@"specifierAtIndexPath:");
    SEL removeSelector = NSSelectorFromString(@"removeSpecifier:animated:");

    id specifier = nil;
    if (tableView && indexPath && controller &&
        [controller respondsToSelector:specifierSelector]) {
        specifier =
            RSBCallObjectSelectorWithObject(controller, specifierSelector, indexPath);
    }

    // BatteryUsageUI puts the "unable to verify" text inside the Battery
    // Health & Charging navigation cell. The old generic warning filter saw
    // that text and removed the whole navigation row. Keep the real row and
    // strip only its warning label.
    if (RSBIsBatteryHealthSpecifier(specifier) ||
        RSBViewContainsBatteryHealthTitle(cell)) {
        RSBClearWarningLabelsInView(cell);
        cell.hidden = NO;
        cell.alpha = 1.0;
        cell.userInteractionEnabled = YES;
        return;
    }

    cell.hidden = YES;
    cell.alpha = 0.0;
    cell.userInteractionEnabled = NO;

    // Hiding a UITableViewCell leaves its row height behind. Once the lazily
    // populated warning text identifies the cell, remove its real PSSpecifier
    // so Settings closes the row and its separator with no blank gap.
    if ([objc_getAssociatedObject(cell, &RSBRemovalScheduledKey) boolValue]) return;
    objc_setAssociatedObject(cell, &RSBRemovalScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (!tableView || !indexPath || !controller ||
        ![controller respondsToSelector:specifierSelector] ||
        ![controller respondsToSelector:removeSelector] ||
        !specifier) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!RSBEnabled) return;
        RSBCallVoidSelectorWithObjectAndBool(controller, removeSelector, specifier, NO);
    });
}

static NSString *RSBApplicationIdentifier(id object) {
    if (!object) return nil;

    NSArray<NSString *> *selectors = @[
        @"applicationBundleID", @"applicationBundleIdentifier", @"bundleIdentifier",
        @"leafIdentifier", @"uniqueIdentifier"
    ];
    for (NSString *selectorName in selectors) {
        id value = RSBCallObjectSelector(object, NSSelectorFromString(selectorName));
        if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
    }

    id application = RSBCallObjectSelector(object, NSSelectorFromString(@"application"));
    if (application && application != object) return RSBApplicationIdentifier(application);
    return nil;
}

static BOOL RSBIsSettingsIcon(id icon) {
    return [[RSBApplicationIdentifier(icon) lowercaseString] isEqualToString:@"com.apple.preferences"];
}

static id RSBRemovingPartsSettingsBadges(id icon, id originalValue) {
    if (!RSBEnabled || !RSBIsSettingsIcon(icon) || !originalValue) return originalValue;

    long long value = 0;
    BOOL isString = [originalValue isKindOfClass:NSString.class];
    if ([originalValue isKindOfClass:NSNumber.class]) {
        value = [originalValue longLongValue];
    } else if (isString) {
        NSString *string = (NSString *)originalValue;
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if (string.length == 0 || [string rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
            return originalValue;
        }
        value = string.longLongValue;
    } else {
        return originalValue;
    }

    // The display and battery warnings can each contribute one Settings badge.
    // Remove up to both contributions while keeping any count above two visible.
    if (value <= 2) return nil;
    value -= 2;
    return isString ? [NSString stringWithFormat:@"%lld", value] : @(value);
}

%group SystemHealthHooks

%hook SystemHealthUI

- (id)getCurrentSystemHealthInfoSpecifiers {
    if (!RSBEnabled) return %orig;
    return nil;
}

- (BOOL)isVaildCAA:(id)argument {
    if (!RSBEnabled) return %orig;
    return YES;
}

- (BOOL)isValidCAA:(id)argument {
    if (!RSBEnabled) return %orig;
    return YES;
}

%end

%end


// iOS 18 rebuilds the About group asynchronously, bypassing the cached getter
// hooked above. Cover both its producer and the final update transaction.
// Keep the original transaction: it removes PARTS_AND_SERVICE_GROUP and
// MAIN_PARTS_AND_SERVICE, updates the cache, and preserves Apple's callbacks.
%group SystemHealthIOS18Hooks

%hook SystemHealthUI

- (id)reloadCurrentSystemHealthInfoSpecifiers {
    if (!RSBEnabled) return %orig;
    return @[];
}

- (void)_updateSpecifiers:(id)specifiers specifierToInsertAfter:(id)anchor withUpdates:(id)updates {
    %orig(RSBEnabled ? @[] : specifiers, anchor, updates);
}

%end

%end

%group FollowUpHooks

%hook FLFollowUpItem

- (BOOL)showInSettings {
    if (RSBEnabled && RSBSpecifierOrFollowUpContainsWarning(self)) return NO;
    return %orig;
}

%end

%hook FLPreferencesController

- (id)_specifiersForItem:(id)item group:(id)group {
    if (RSBEnabled && RSBSpecifierOrFollowUpContainsWarning(item)) return @[];
    return %orig;
}

- (id)topLevelSpecifiers {
    id specifiers = %orig;
    return RSBFilteredFollowUpSpecifiers(specifiers);
}

- (id)topLevelSpecifiersForGroup:(unsigned long long)group {
    id specifiers = %orig;
    return RSBFilteredFollowUpSpecifiers(specifiers);
}

- (id)_topLevelSpecifiersForGroup:(unsigned long long)group {
    id specifiers = %orig;
    return RSBFilteredFollowUpSpecifiers(specifiers);
}

%end

%end


%group BatteryUIHooks

%hook BatteryHealthUIController

// Apple's row remains Apple's row. For an unverified replacement battery,
// replace only the unavailable percentage with the capacity reported by the
// installed battery's BMS/gas gauge.
- (id)getChargeCapacityRemaining {
    if (!RSBEnabled || !RSBInstalledBatteryIsUnverified()) return %orig;

    NSString *health = RSBReplacementBatteryHealthString();
    return health ?: %orig;
}

%end

%end


%group PreferencesHooks

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    RSBHideWarningCellIfNeeded(self);
}

%end

%end


%group SpringBoardHooks

%hook SBApplication

- (id)badgeNumberOrStringForIcon:(id)icon {
    id originalValue = %orig;
    // SBApplication is the active SBLeafIconDataSource on iOS 16. Hooking the
    // data source is reliable even when SpringBoardHome loads SBLeafIcon after
    // this tweak's constructor has already run.
    id badgeOwner = RSBIsSettingsIcon(self) ? self : icon;
    return RSBRemovingPartsSettingsBadges(badgeOwner, originalValue);
}

%end

%end


static void RSBInitializeSystemHealthHooks(void) {
    if (RSBSystemHealthHooksInitialized || !objc_getClass("SystemHealthUI")) return;

    @synchronized(NSObject.class) {
        if (RSBSystemHealthHooksInitialized || !objc_getClass("SystemHealthUI")) return;
        RSBSystemHealthHooksInitialized = YES;
        %init(SystemHealthHooks);

        // Do not install these extra hooks on iOS 16. Require both methods
        // before installing, rather than adding guessed selectors to a class.
        Class healthClass = objc_getClass("SystemHealthUI");
        if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 18 &&
            class_getInstanceMethod(healthClass, @selector(reloadCurrentSystemHealthInfoSpecifiers)) &&
            class_getInstanceMethod(healthClass, @selector(_updateSpecifiers:specifierToInsertAfter:withUpdates:))) {
            %init(SystemHealthIOS18Hooks);
        }
    }
}

static void RSBLoadAndHookSystemHealthFramework(void) {
    if (!objc_getClass("SystemHealthUI")) {
        // On iOS 16, SystemHealthUI lives in CoreRepairUI. Loading it during
        // Settings startup lets us hook its specifier provider before the
        // first table snapshot is built, avoiding a visible row removal.
        (void)dlopen("/System/Library/PrivateFrameworks/CoreRepairUI.framework/CoreRepairUI",
                     RTLD_LAZY | RTLD_LOCAL);
    }
    RSBInitializeSystemHealthHooks();
}

static void RSBInitializeFollowUpHooks(void) {
    if (RSBFollowUpHooksInitialized || !objc_getClass("FLPreferencesController")) return;

    @synchronized(NSObject.class) {
        if (RSBFollowUpHooksInitialized || !objc_getClass("FLPreferencesController")) return;
        RSBFollowUpHooksInitialized = YES;
        %init(FollowUpHooks);
    }
}

static void RSBLoadAndHookFollowUpFramework(void) {
    if (!objc_getClass("FLPreferencesController")) {
        (void)dlopen("/System/Library/PrivateFrameworks/CoreFollowUpUI.framework/CoreFollowUpUI",
                     RTLD_LAZY | RTLD_LOCAL);
    }
    RSBInitializeFollowUpHooks();
}

static void RSBInitializeBatteryUIHooks(void) {
    if (RSBBatteryUIHooksInitialized ||
        !objc_getClass("BatteryHealthUIController")) {
        return;
    }

    @synchronized(NSObject.class) {
        if (RSBBatteryUIHooksInitialized ||
            !objc_getClass("BatteryHealthUIController")) {
            return;
        }
        RSBBatteryUIHooksInitialized = YES;
        %init(BatteryUIHooks);
    }
}


%ctor {
    @autoreleasepool {
        RSBLoadPreferences();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        RSBPreferencesChanged,
                                        CFSTR("com.551.replacedscreenbattery/preferences.changed"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier.lowercaseString;
        if ([bundleIdentifier isEqualToString:@"com.apple.preferences"]) {
            %init(PreferencesHooks);
            RSBLoadAndHookFollowUpFramework();
            RSBLoadAndHookSystemHealthFramework();
            RSBInitializeBatteryUIHooks();

            // SystemHealthUI and BatteryUsageUI are loaded lazily on some builds. Install
            // its hooks synchronously as soon as NSBundle finishes loading the
            // framework, before Settings asks it to create the warning row.
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSBundleDidLoadNotification
                            object:nil
                             queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
                            RSBInitializeFollowUpHooks();
                            RSBInitializeSystemHealthHooks();
                            RSBInitializeBatteryUIHooks();
                        }];
        } else if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            %init(SpringBoardHooks);
        }
    }
}
