#import <Foundation/Foundation.h>

extern CFStringRef SBSCopyFrontmostApplicationDisplayIdentifier(void);

int main(void)
{
    @autoreleasepool {
        CFStringRef identifier =
            SBSCopyFrontmostApplicationDisplayIdentifier();
        if (!identifier)
            return 1;
        puts([(__bridge NSString *)identifier UTF8String]);
        CFRelease(identifier);
    }
    return 0;
}
