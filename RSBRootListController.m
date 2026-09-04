#import "RSBRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
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

@implementation RSBRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];

        PSSpecifier *warningGroup = [PSSpecifier groupSpecifierWithName:@"Warning Control"];
        [warningGroup setProperty:
            @"When enabled, the replaced display/battery message stays hidden and its one Settings badge is removed. Use Respring after changing this switch."
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
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    (void)specifier;
    NSNumber *enabled = @([value boolValue]);

    // Keep cfprefsd's cache and the exact file read by the injected tweak in
    // agreement. Synchronize first, then verify the on-disk value explicitly
    // before notifying Preferences and SpringBoard to reload it.
    CFPreferencesSetAppValue(CFSTR("enabled"),
                             (__bridge CFPropertyListRef)enabled,
                             RSBPreferencesDomain);
    CFPreferencesAppSynchronize(RSBPreferencesDomain);

    NSMutableDictionary *preferences =
        [[NSDictionary dictionaryWithContentsOfFile:RSBPreferencesPath] mutableCopy];
    if (!preferences) preferences = [NSMutableDictionary dictionary];
    preferences[@"enabled"] = enabled;
    [preferences writeToFile:RSBPreferencesPath atomically:YES];

    notify_post("com.551.replacedscreenbattery/preferences.changed");
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    (void)specifier;
    id fileValue = [NSDictionary dictionaryWithContentsOfFile:RSBPreferencesPath][@"enabled"];
    if (fileValue) return @([fileValue boolValue]);

    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("enabled"),
                                                        RSBPreferencesDomain);
    return value ? CFBridgingRelease(value) : @YES;
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
