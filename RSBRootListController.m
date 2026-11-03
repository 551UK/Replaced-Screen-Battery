#import "RSBRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <errno.h>
#import <notify.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static CFStringRef const RSBPreferencesDomain = CFSTR("com.551.replacedscreenbattery");
static NSString *const RSBPreferencesPath =
    @"/var/mobile/Library/Preferences/com.551.replacedscreenbattery.plist";

static BOOL RSBRunCommandAndWait(NSString *path, char *const arguments[]) {
    const char *executable = path.fileSystemRepresentation;
    if (access(executable, X_OK) != 0) return NO;

    pid_t processIdentifier = 0;
    int spawnResult = posix_spawn(&processIdentifier,
                                  executable,
                                  NULL,
                                  NULL,
                                  arguments,
                                  environ);
    if (spawnResult != 0) return NO;

    int status = 0;
    pid_t waitedProcess;
    do {
        waitedProcess = waitpid(processIdentifier, &status, 0);
    } while (waitedProcess == -1 && errno == EINTR);

    return waitedProcess == processIdentifier &&
           WIFEXITED(status) &&
           WEXITSTATUS(status) == 0;
}

static void RSBExitSettingsSoon(void) {
    // Give sbreload/launchd time to accept the restart before terminating
    // Preferences. This also prevents its old filtered list from surviving.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        _exit(0);
    });
}

@interface RSBRootListController ()
@property (nonatomic, strong) UIView *headerCard;
@property (nonatomic, strong) CAGradientLayer *headerGradient;
@end

@implementation RSBRootListController

- (UITableViewStyle)tableViewStyle {
    return UITableViewStyleInsetGrouped;
}


- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];

        PSSpecifier *warningGroup = [PSSpecifier groupSpecifierWithName:@"Warning Control"];
        [warningGroup setProperty:
            @"Hide replaced-part warnings and show battery health for an unverified replacement battery. Respring after changing this switch."
                           forKey:@"footerText"];
        [items addObject:warningGroup];

        PSSpecifier *toggle = [PSSpecifier
            preferenceSpecifierNamed:@"Hide Parts Warning"
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:nil
            cell:PSSwitchCell
            edit:nil];
        [toggle setProperty:@"com.551.replacedscreenbattery" forKey:@"defaults"];
        [toggle setProperty:@"enabled" forKey:@"key"];
        [toggle setProperty:@YES forKey:@"default"];
        [toggle setProperty:@"com.551.replacedscreenbattery/preferences.changed"
                     forKey:@"PostNotification"];
        [items addObject:toggle];

        PSSpecifier *healthGroup = [PSSpecifier groupSpecifierWithName:@"Battery Health Display"];
        [healthGroup setProperty:
            @"Higher-mAh replacement batteries can report a Full Charge Capacity above their Design Capacity, making calculated health exceed 100%. On: cap the displayed health at 100% (110% becomes 100%). Off: show the uncapped value."
                         forKey:@"footerText"];
        [items addObject:healthGroup];

        PSSpecifier *capToggle = [PSSpecifier
            preferenceSpecifierNamed:@"Cap Battery Health at 100%"
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:nil
            cell:PSSwitchCell
            edit:nil];
        [capToggle setProperty:@"com.551.replacedscreenbattery" forKey:@"defaults"];
        [capToggle setProperty:@"capBatteryHealth" forKey:@"key"];
        [capToggle setProperty:@YES forKey:@"default"];
        [capToggle setProperty:@"com.551.replacedscreenbattery/preferences.changed"
                        forKey:@"PostNotification"];
        [items addObject:capToggle];
        [items addObject:[PSSpecifier emptyGroupSpecifier]];

        PSSpecifier *respring = [PSSpecifier
            preferenceSpecifierNamed:@"Respring"
            target:self
            set:nil
            get:nil
            detail:nil
            cell:PSButtonCell
            edit:nil];
        respring.buttonAction = @selector(respring);
        [items addObject:respring];

        [items addObject:[PSSpecifier emptyGroupSpecifier]];

        PSSpecifier *github = [PSSpecifier
            preferenceSpecifierNamed:@"Open GitHub Repository"
            target:self
            set:nil
            get:nil
            detail:nil
            cell:PSButtonCell
            edit:nil];
        github.buttonAction = @selector(openGitHub);
        [items addObject:github];

        PSSpecifier *credits = [PSSpecifier emptyGroupSpecifier];
        [credits setProperty:@"Made by 551" forKey:@"footerText"];
        [items addObject:credits];

        _specifiers = items;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Replaced Screen & Battery";
    UITableView *table = self.table;
    if (!table) return;
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(table.bounds), 156)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 16, MAX(0, CGRectGetWidth(header.bounds) - 32), 126)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.layer.cornerRadius = 19;
    card.layer.masksToBounds = YES;
    [header addSubview:card];
    self.headerCard = card;

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (__bridge id)[UIColor colorWithRed:0.11 green:0.17 blue:0.25 alpha:1].CGColor,
        (__bridge id)[UIColor colorWithRed:0.16 green:0.30 blue:0.34 alpha:1].CGColor
    ];
    gradient.startPoint = CGPointMake(0, 0);
    gradient.endPoint = CGPointMake(1, 1);
    gradient.frame = card.bounds;
    [card.layer insertSublayer:gradient atIndex:0];
    self.headerGradient = gradient;

    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    UIImage *icon = [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil];
    UIImageView *emblem = [[UIImageView alloc] initWithImage:icon ?: [UIImage systemImageNamed:@"battery.100"]];
    emblem.translatesAutoresizingMaskIntoConstraints = NO;
    emblem.contentMode = UIViewContentModeScaleAspectFit;
    emblem.tintColor = UIColor.systemGreenColor;
    emblem.layer.cornerRadius = 13;
    emblem.clipsToBounds = YES;
    emblem.isAccessibilityElement = NO;
    [card addSubview:emblem];

    UILabel *heading = [UILabel new];
    heading.text = @"Replaced Screen\n& Battery";
    heading.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    heading.textColor = UIColor.whiteColor;
    heading.numberOfLines = 2;
    heading.adjustsFontSizeToFitWidth = YES;
    heading.minimumScaleFactor = 0.75;
    UILabel *subtitle = [UILabel new];
    subtitle.text = @"Parts warnings. Battery health.";
    subtitle.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    subtitle.numberOfLines = 2;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[heading, subtitle]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 6;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:labels];
    [NSLayoutConstraint activateConstraints:@[
        [emblem.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [emblem.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [emblem.widthAnchor constraintEqualToConstant:54],
        [emblem.heightAnchor constraintEqualToConstant:54],
        [labels.leadingAnchor constraintEqualToAnchor:emblem.trailingAnchor constant:15],
        [labels.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [labels.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [labels.topAnchor constraintGreaterThanOrEqualToAnchor:card.topAnchor constant:12],
        [labels.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-12]
    ]];
    table.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.headerGradient.frame = self.headerCard.bounds;
    [CATransaction commit];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;
    NSNumber *storedValue = @([value boolValue]);

    // Keep cfprefsd's cache and the exact file read by the injected tweak in
    // agreement. Synchronize first, then verify the on-disk value explicitly
    // before notifying Preferences and SpringBoard to reload it.
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)storedValue,
                             RSBPreferencesDomain);
    CFPreferencesAppSynchronize(RSBPreferencesDomain);

    NSMutableDictionary *preferences =
        [[NSDictionary dictionaryWithContentsOfFile:RSBPreferencesPath] mutableCopy];
    if (!preferences) preferences = [NSMutableDictionary dictionary];
    preferences[key] = storedValue;
    [preferences writeToFile:RSBPreferencesPath atomically:YES];

    notify_post("com.551.replacedscreenbattery/preferences.changed");
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return [specifier propertyForKey:@"default"];
    id fileValue = [NSDictionary dictionaryWithContentsOfFile:RSBPreferencesPath][key];
    if (fileValue) return @([fileValue boolValue]);

    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        RSBPreferencesDomain);
    return value ? CFBridgingRelease(value) : [specifier propertyForKey:@"default"];
}

- (void)respring {
    NSArray<NSString *> *paths = @[
        @"/var/jb/usr/bin/sbreload",
        @"/usr/bin/sbreload"
    ];
    for (NSString *path in paths) {
        char *const arguments[] = {(char *)"sbreload", NULL};
        if (RSBRunCommandAndWait(path, arguments)) {
            RSBExitSettingsSoon();
            return;
        }
    }

    NSArray<NSString *> *killallPaths = @[
        @"/var/jb/usr/bin/killall",
        @"/usr/bin/killall"
    ];
    for (NSString *path in killallPaths) {
        char *const arguments[] = {
            (char *)"killall", (char *)"-9", (char *)"SpringBoard", NULL
        };
        if (RSBRunCommandAndWait(path, arguments)) {
            RSBExitSettingsSoon();
            return;
        }
    }
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/Replaced-Screen-Battery"];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end
