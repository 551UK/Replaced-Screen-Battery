#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>

// Replaced Screen & Battery
// iOS 15-16, rootless Dopamine

static BOOL RSBEnabled = YES;
static BOOL RSBSystemHealthHooksInitialized = NO;
static BOOL RSBFollowUpHooksInitialized = NO;

static void RSBInitializeSystemHealthHooks(void);
static void RSBLoadAndHookSystemHealthFramework(void);
static void RSBInitializeFollowUpHooks(void);
static void RSBLoadAndHookFollowUpFramework(void);

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
    cell.hidden = YES;
    cell.alpha = 0.0;
    cell.userInteractionEnabled = NO;

    // Hiding a UITableViewCell leaves its row height behind. Once the lazily
    // populated warning text identifies the cell, remove its real PSSpecifier
    // so Settings closes the row and its separator with no blank gap.
    if ([objc_getAssociatedObject(cell, &RSBRemovalScheduledKey) boolValue]) return;
    objc_setAssociatedObject(cell, &RSBRemovalScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITableView *tableView = RSBTableViewContainingView(cell);
    NSIndexPath *indexPath = [tableView indexPathForCell:cell];
    id controller = tableView.delegate;
    SEL specifierSelector = NSSelectorFromString(@"specifierAtIndexPath:");
    SEL removeSelector = NSSelectorFromString(@"removeSpecifier:animated:");
    if (!tableView || !indexPath || !controller ||
        ![controller respondsToSelector:specifierSelector] ||
        ![controller respondsToSelector:removeSelector]) return;

    id specifier = RSBCallObjectSelectorWithObject(controller, specifierSelector, indexPath);
    if (!specifier) return;

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

static id RSBRemovingOneSettingsBadge(id icon, id originalValue) {
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

    // The replaced-part warning contributes one badge. Subtract only that one,
    // preserving any additional Settings alerts rather than hiding them all.
    if (value <= 1) return nil;
    value -= 1;
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
    return RSBRemovingOneSettingsBadge(badgeOwner, originalValue);
}

%end

%end


static void RSBInitializeSystemHealthHooks(void) {
    if (RSBSystemHealthHooksInitialized || !objc_getClass("SystemHealthUI")) return;

    @synchronized(NSObject.class) {
        if (RSBSystemHealthHooksInitialized || !objc_getClass("SystemHealthUI")) return;
        RSBSystemHealthHooksInitialized = YES;
        %init(SystemHealthHooks);
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

            // SystemHealthUI is loaded lazily on some iOS 16 builds. Install
            // its hooks synchronously as soon as NSBundle finishes loading the
            // framework, before Settings asks it to create the warning row.
            [[NSNotificationCenter defaultCenter]
                addObserverForName:NSBundleDidLoadNotification
                            object:nil
                             queue:nil
                        usingBlock:^(__unused NSNotification *notification) {
                            RSBInitializeFollowUpHooks();
                            RSBInitializeSystemHealthHooks();
                        }];
        } else if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            %init(SpringBoardHooks);
        }
    }
}
