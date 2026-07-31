#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

#import "../tweak/SIPIPC.h"

@interface IOSIPRootListController : PSListController
@end

static NSString *LocalizedString(NSString *key)
{
    return [[NSBundle bundleForClass:[IOSIPRootListController class]]
        localizedStringForKey:key value:key table:nil];
}

@implementation IOSIPRootListController

- (NSArray *)specifiers
{
    if (!_specifiers)
        _specifiers =
            [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)applySettings
{
    [self.view endEditing:YES];
    CFPreferencesAppSynchronize(CFSTR("me.ancal.iosip"));

    NSString *reply = IOSIPCommand(@"RELOAD");
    NSString *message;
    if ([reply isEqualToString:@"OK"])
        message = LocalizedString(@"SETTINGS_SAVED");
    else if ([reply isEqualToString:@"BUSY"])
        message = LocalizedString(@"SETTINGS_BUSY");
    else if ([reply isEqualToString:@"INVALID"])
        message = LocalizedString(@"SETTINGS_INVALID");
    else
        message = LocalizedString(@"DAEMON_UNAVAILABLE");

    [[[UIAlertView alloc] initWithTitle:@"iOSIP"
                               message:message
                              delegate:nil
                     cancelButtonTitle:LocalizedString(@"OK")
                     otherButtonTitles:nil] show];
}

@end
