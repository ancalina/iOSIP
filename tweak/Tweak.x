#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>

#import "SIPIPC.h"

typedef const void *CTCallRef;
typedef void (*CTStatusCallback)(void *center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo);

@interface NSObject (IOSIPDialerPrivate)
- (void)beginInterruption:(id)status;
- (id)callButton;
- (void)endInterruptionWithStatus:(id)status;
- (BOOL)_routeIsHandset:(id)route;
- (BOOL)_routeIsSpeaker:(id)route;
@end

static CFStringRef IOSIPCTCallStatusChangeNotification;
static CFStringRef IOSIPCTCallIdentificationChangeNotification;
static CFStringRef IOSIPCTCallHistoryRecordAddNotification;
static CFStringRef IOSIPCTCallHistorySignificantChangeNotification;
static CFStringRef IOSIPCTCall;
static CFStringRef IOSIPCTCallTypeNormal;

static NSString *const IOSIPNotification = @"me.ancal.iosip.state";
static NSString *const IOSIPHistoryNotification =
    @"me.ancal.iosip.history";
static NSString *const IOSIPHistoryPath =
    @"/var/mobile/Library/IOSIP/history.plist";
static CTCallRef const IOSIPCallToken =
    CFSTR("me.ancal.iosip.call-token");
static NSDictionary *IOSIPCurrentState;
static NSArray *IOSIPHistory;
static NSMutableDictionary *IOSIPHistoryTokens;
static unsigned long long IOSIPGeneration;
static unsigned long long IOSIPHistoryGeneration;
static BOOL IOSIPIsSpringBoardProcess;
static BOOL IOSIPIsInCallServiceProcess;
static BOOL IOSIPPhoneAudioReleased;
static BOOL IOSIPMuted;
static id IOSIPPhoneAudioController;
static id IOSIPModernCall;
static id IOSIPModernCallGroup;
static NSString *IOSIPTUCallStatusNotification;
static NSString *IOSIPTUCallModelNotification;
static NSString *IOSIPTUCallConnectedNotification;
static NSString *IOSIPActivatedCallID;

static void IOSIPNotifyModernState(void);
static void IOSIPActivateModernCallUI(void);

static CFStringRef IOSIPCoreTelephonyConstant(const char *symbol,
                                               CFStringRef fallback)
{
    CFStringRef *value = dlsym(RTLD_DEFAULT, symbol);
    return value && *value ? *value : fallback;
}

typedef struct {
    void *center;
    void *observer;
    CTStatusCallback callback;
    CFStringRef name;
    const void *object;
} IOSIPObserver;

static IOSIPObserver IOSIPObservers[32];
static NSUInteger IOSIPObserverCount;

static CFArrayRef (*OriginalCTCopyCurrentCalls)(CFAllocatorRef);
static CFArrayRef (*Original_CTCallCopyCurrentCalls)(
    CFAllocatorRef, Boolean);
static CFArrayRef (*Original_CTCallCopyAllCalls)(void);
static CFArrayRef (*OriginalCTCallCopyAllMissedCallsSince)(CFDateRef);
static void (*Original_CTCallDeleteFromCallHistory)(CTCallRef);
static void (*Original_CTCallDeleteAllCallsBeforeDate)(CFDateRef);
static int (*OriginalCTCallSetAllCallsRead)(void);
static int (*OriginalCTCallGetCountOfUnreadCallsWithTypes)(CFArrayRef);
static int (*OriginalCTGetCurrentCallCount)(void);
static int (*OriginalCTCallGetStatus)(CTCallRef);
static CFStringRef (*OriginalCTCallCopyAddress)(CFAllocatorRef, CTCallRef);
static CFStringRef (*OriginalCTCallCopyCountryCode)(
    CFAllocatorRef, CTCallRef);
static CFStringRef (*OriginalCTCallCopyNetworkCode)(
    CFAllocatorRef, CTCallRef);
static Boolean (*OriginalCTCallAddressBlocked)(CTCallRef);
static CFStringRef (*OriginalCTCallCopyName)(CFAllocatorRef, CTCallRef);
static Boolean (*OriginalCTCallIsOutgoing)(CTCallRef);
static Boolean (*OriginalCTCallIsAlerting)(CTCallRef);
static Boolean (*OriginalCTCallIsConferenced)(CTCallRef);
static Boolean (*OriginalCTCallIsToVoicemail)(CTCallRef);
static Boolean (*OriginalCTCallGetEmergencyStatus)(CTCallRef);
static int (*OriginalCTCallGetID)(CTCallRef);
static Boolean (*OriginalCTCallGetRead)(CTCallRef);
static CFStringRef (*OriginalCTCallCopyUniqueStringID)(
    CFAllocatorRef, CTCallRef);
static Boolean (*OriginalCTCallGetStartTime)(CTCallRef, double *);
static CFStringRef (*OriginalCTCallGetCallType)(CTCallRef);
static Boolean (*OriginalCTCallGetDuration)(CTCallRef, double *);
static CTCallRef (*OriginalCTCallDialWithID)(CFStringRef, int);
static int (*OriginalCTCallAnswer)(CTCallRef);
static int (*OriginalCTCallResume)(CTCallRef);
static int (*OriginalCTCallDisconnect)(CTCallRef);
static int (*OriginalCTCallListDisconnect)(void);
static int (*OriginalCTCallListDisconnectAll)(void);
static int (*OriginalCTCallHold)(CTCallRef);
static int (*OriginalCTDTMFPlayStart)(int);
static int (*OriginalCTDTMFPlayStop)(void);
static void (*OriginalCTTelephonyCenterAddObserver)(
    void *, void *, CTStatusCallback, CFStringRef, const void *, int);
static void (*OriginalCTTelephonyCenterRemoveObserver)(
    void *, void *, CFStringRef, const void *);
static void (*OriginalCTTelephonyCenterRemoveEveryObserver)(
    void *, void *);
static Boolean (*OriginalPNIsValidPhoneNumberForCountry)(
    CFStringRef, CFStringRef);
static const void *(*OriginalTUCopyPrimaryPersonForDestinationIDInAddressBook)(
    const void *, CTCallRef, void *, void *, void *, void *, int);

static int IOSIPCTCallResume(CTCallRef call);
static int IOSIPCTCallDisconnect(CTCallRef call);

static CTCallRef IOSIPActiveCallToken(void)
{
    return IOSIPCallToken;
}

static BOOL IOSIPIsCall(CTCallRef call)
{
    return call == IOSIPCallToken;
}

static NSDictionary *IOSIPHistoryRecord(CTCallRef call)
{
    @synchronized (IOSIPNotification) {
        for (NSDictionary *record in IOSIPHistory) {
            NSString *callID = record[@"call_id"];
            if (callID.length &&
                (__bridge CTCallRef)IOSIPHistoryTokens[callID] == call)
                return record;
        }
    }
    return nil;
}

static BOOL IOSIPIsHistoryCall(CTCallRef call)
{
    @synchronized (IOSIPNotification) {
        for (NSString *token in [IOSIPHistoryTokens allValues]) {
            if ((__bridge CTCallRef)token == call)
                return YES;
        }
    }
    return NO;
}

static BOOL IOSIPIsSyntheticCall(CTCallRef call)
{
    return IOSIPIsCall(call) || IOSIPHistoryRecord(call) != nil ||
           IOSIPIsHistoryCall(call);
}

static BOOL IOSIPIsMissedRecord(NSDictionary *record)
{
    return [record[@"direction"] isEqualToString:@"incoming"] &&
           !record[@"connected_at"];
}

static BOOL IOSIPIsUnreadMissedRecord(NSDictionary *record)
{
    return IOSIPIsMissedRecord(record) &&
           [record[@"read"] isEqual:@NO];
}

static NSString *IOSIPHistoryTokenForRecord(NSDictionary *record)
{
    NSString *callID = record[@"call_id"];
    if (!callID.length)
        return nil;
    @synchronized (IOSIPNotification) {
        return IOSIPHistoryTokens[callID];
    }
}

static void IOSIPReloadHistory(void)
{
    NSArray *history =
        [NSArray arrayWithContentsOfFile:IOSIPHistoryPath] ?: @[];
    @synchronized (IOSIPNotification) {
        IOSIPHistory = history;
        if (!IOSIPHistoryTokens)
            IOSIPHistoryTokens = [NSMutableDictionary dictionary];
        for (NSDictionary *record in IOSIPHistory) {
            NSString *callID = record[@"call_id"];
            if (callID.length && !IOSIPHistoryTokens[callID])
                IOSIPHistoryTokens[callID] =
                    [@"me.ancal.iosip.history."
                        stringByAppendingString:callID];
        }
    }
}

static BOOL IOSIPShouldCaptureCallback(CTStatusCallback callback)
{
    Dl_info info = {0};
    if (!dladdr((const void *)callback, &info) || !info.dli_fname)
        return NO;
    return strstr(info.dli_fname, "/MobilePhone.app/MobilePhone") ||
           strstr(info.dli_fname, "/SpringBoard.app/SpringBoard") ||
           strstr(info.dli_fname,
                  "/MPDataProvider.bundle/MPDataProvider") ||
           strstr(info.dli_fname,
                  "/IncomingCall.servicebundle/IncomingCall");
}

static BOOL IOSIPHasCall(void)
{
    NSString *state = IOSIPCurrentState[@"state"];
    return [state isEqualToString:@"incoming"] ||
           [state isEqualToString:@"calling"] ||
           [state isEqualToString:@"connected"] ||
           [state isEqualToString:@"ended"];
}

static BOOL IOSIPModernHasCall(void)
{
    NSString *state = IOSIPCurrentState[@"state"];
    return [state isEqualToString:@"incoming"] ||
           [state isEqualToString:@"calling"] ||
           [state isEqualToString:@"connected"];
}

static int IOSIPCallStatus(void)
{
    NSString *state = IOSIPCurrentState[@"state"];
    if ([state isEqualToString:@"connected"])
        return 1;
    if ([state isEqualToString:@"calling"])
        return 3;
    if ([state isEqualToString:@"incoming"])
        return 4;
    return 5;
}

static NSString *IOSIPNumberFromRemote(NSString *remote)
{
    remote = remote ?: @"";
    NSRange start = [remote rangeOfString:@"sip:"];
    if (start.location == NSNotFound)
        return remote;
    NSString *number = [remote substringFromIndex:NSMaxRange(start)];
    NSRange end = [number rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"@>;"]];
    return end.location == NSNotFound ? number :
        [number substringToIndex:end.location];
}

static NSString *IOSIPRemoteNumber(void)
{
    return IOSIPNumberFromRemote(IOSIPCurrentState[@"remote"]);
}

static BOOL IOSIPObserverIsRegistered(
    void *center, void *observer, CTStatusCallback callback,
    CFStringRef name, const void *object);

static void IOSIPNotifyRecents(void)
{
    if (IOSIPIsSpringBoardProcess)
        return;
    Class managerClass = objc_getClass("PARecentsManager");
    SEL sharedSelector = NSSelectorFromString(@"sharedRecentsManager");
    SEL reloadSelector =
        NSSelectorFromString(@"reloadCallsArrayIfNecessary");
    if (!managerClass ||
        ![managerClass respondsToSelector:sharedSelector])
        return;
    id manager = ((id (*)(id, SEL))objc_msgSend)(
        managerClass, sharedSelector);
    if ([manager respondsToSelector:reloadSelector])
        ((void (*)(id, SEL))objc_msgSend)(manager, reloadSelector);
}

static void IOSIPNotifyObserversWithInfo(
    CFStringRef name, CTCallRef token, CFDictionaryRef userInfo)
{
    IOSIPObserver observers[32];
    NSUInteger count;
    @synchronized (IOSIPNotification) {
        count = IOSIPObserverCount;
        memcpy(observers, IOSIPObservers,
               count * sizeof(IOSIPObserver));
    }
    for (NSUInteger index = 0; index < count; ++index) {
        IOSIPObserver item = observers[index];
        if (!CFEqual(item.name, name))
            continue;
        if (item.object && item.object != token)
            continue;
        if (!IOSIPObserverIsRegistered(
                item.center, item.observer, item.callback,
                item.name, item.object))
            continue;
        item.callback(item.center, item.observer, item.name,
                      token, userInfo);
    }
}

static void IOSIPNotifyObservers(CFStringRef name)
{
    IOSIPNotifyObserversWithInfo(
        name, IOSIPCallToken, NULL);
}

static BOOL IOSIPObserverIsRegistered(
    void *center, void *observer, CTStatusCallback callback,
    CFStringRef name, const void *object)
{
    @synchronized (IOSIPNotification) {
        for (NSUInteger index = 0; index < IOSIPObserverCount; ++index) {
            IOSIPObserver item = IOSIPObservers[index];
            if (item.center == center && item.observer == observer &&
                item.callback == callback && item.name == name &&
                item.object == object)
                return YES;
        }
    }
    return NO;
}

static void IOSIPNotifyHistoryRecordAdded(NSDictionary *record)
{
    NSString *token = IOSIPHistoryTokenForRecord(record);
    if (!token)
        return;
    if (IOSIPIsMissedRecord(record) &&
        !IOSIPIsUnreadMissedRecord(
            IOSIPHistoryRecord((__bridge CTCallRef)token)))
        return;
    NSDictionary *userInfo = @{
        (__bridge NSString *)IOSIPCTCall: token
    };
    IOSIPNotifyObserversWithInfo(
        IOSIPCTCallHistoryRecordAddNotification,
        (__bridge CTCallRef)token,
        (__bridge CFDictionaryRef)userInfo);
}

static void IOSIPReloadState(void)
{
    NSDictionary *state = IOSIPState();
    unsigned long long generation =
        [state[@"generation"] unsignedLongLongValue];
    if (!state || generation == IOSIPGeneration)
        return;
    IOSIPCurrentState = state;
    IOSIPGeneration = generation;
    NSString *callState = state[@"state"];
    NSDictionary *lastEnd = state[@"last_end"];
    unsigned long long historyGeneration =
        [lastEnd[@"generation"] unsignedLongLongValue];
    BOOL historyChanged =
        historyGeneration != IOSIPHistoryGeneration;
    if (historyChanged) {
        IOSIPHistoryGeneration = historyGeneration;
        IOSIPReloadHistory();
    }
    if ([callState isEqualToString:@"incoming"] ||
        [callState isEqualToString:@"calling"]) {
        IOSIPPhoneAudioReleased = NO;
        IOSIPMuted = NO;
    }
    IOSIPNotifyObservers(IOSIPCTCallStatusChangeNotification);
    if ([callState isEqualToString:@"incoming"] ||
        [callState isEqualToString:@"calling"])
        IOSIPNotifyObservers(IOSIPCTCallIdentificationChangeNotification);
    IOSIPNotifyModernState();
    IOSIPActivateModernCallUI();
    if (historyChanged)
        IOSIPNotifyHistoryRecordAdded(lastEnd);
    if (IOSIPIsSpringBoardProcess &&
        [callState isEqualToString:@"connected"] &&
        IOSIPPhoneAudioController && !IOSIPPhoneAudioReleased) {
        [IOSIPPhoneAudioController
            endInterruptionWithStatus:@"iosip.connected"];
        IOSIPPhoneAudioReleased = YES;
    } else if ([callState isEqualToString:@"idle"]) {
        IOSIPPhoneAudioReleased = NO;
        IOSIPMuted = NO;
    }
    if (historyChanged)
        IOSIPNotifyRecents();
}

static void IOSIPStateChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (IOSIPIsSpringBoardProcess &&
            [UIDevice currentDevice].systemVersion.integerValue >= 7) {
            NSDictionary *state = IOSIPState();
            unsigned long long generation =
                [state[@"generation"] unsignedLongLongValue];
            if (!state || generation == IOSIPGeneration)
                return;
            IOSIPCurrentState = state;
            IOSIPGeneration = generation;
            IOSIPActivateModernCallUI();
            return;
        }
        IOSIPReloadState();
    });
}

static void IOSIPHistoryChanged(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOSIPReloadHistory();
        IOSIPNotifyObserversWithInfo(
            IOSIPCTCallHistorySignificantChangeNotification, NULL, NULL);
        IOSIPNotifyRecents();
    });
}

static NSString *IOSIPNormalizeNumber(NSString *value)
{
    if (!value.length)
        return nil;
    NSCharacterSet *digits = [NSCharacterSet
        characterSetWithCharactersInString:@"+0123456789*#"];
    NSCharacterSet *formatting = [NSCharacterSet
        characterSetWithCharactersInString:@" -()."];
    NSMutableString *normalized = [NSMutableString string];
    for (NSUInteger index = 0; index < value.length; ++index) {
        unichar character = [value characterAtIndex:index];
        if ([digits characterIsMember:character]) {
            [normalized appendFormat:@"%C", character];
        } else if (![formatting characterIsMember:character] &&
                   ![[NSCharacterSet whitespaceAndNewlineCharacterSet]
                       characterIsMember:character]) {
            return nil;
        }
    }
    return normalized.length ? normalized : nil;
}

static BOOL IOSIPIsDialableNumber(NSString *value)
{
    return IOSIPNormalizeNumber(value) != nil;
}

static NSString *IOSIPDialReply(NSString *number)
{
    NSString *normalized = IOSIPNormalizeNumber(number);
    if (!normalized)
        return nil;
    NSString *reply = IOSIPCommand(
        [@"CALL " stringByAppendingString:normalized]);
    if ([reply isEqualToString:@"OK"]) {
        NSDictionary *state = IOSIPState();
        if (state)
            IOSIPCurrentState = state;
    }
    return reply;
}

static int IOSIPModernCallStatus(id self, SEL selector)
{
    NSString *state = IOSIPCurrentState[@"state"];
    if ([state isEqualToString:@"connected"])
        return 1;
    if ([state isEqualToString:@"calling"])
        return 3;
    if ([state isEqualToString:@"incoming"])
        return 4;
    return 6;
}

static BOOL IOSIPModernCallIsOutgoing(id self, SEL selector)
{
    return [IOSIPCurrentState[@"direction"] isEqualToString:@"outgoing"];
}

static BOOL IOSIPModernCallIsConnected(id self, SEL selector)
{
    return [IOSIPCurrentState[@"state"] isEqualToString:@"connected"];
}

static BOOL IOSIPModernCallIsConnecting(id self, SEL selector)
{
    return [IOSIPCurrentState[@"state"] isEqualToString:@"calling"];
}

static BOOL IOSIPModernCallIsAlerting(id self, SEL selector)
{
    return [IOSIPCurrentState[@"state"] isEqualToString:@"incoming"];
}

static BOOL IOSIPModernCallIsActive(id self, SEL selector)
{
    return IOSIPModernHasCall();
}

static BOOL IOSIPModernCallIsFinal(id self, SEL selector)
{
    NSString *state = IOSIPCurrentState[@"state"];
    return [state isEqualToString:@"ended"] ||
           [state isEqualToString:@"idle"];
}

static BOOL IOSIPModernYes(id self, SEL selector)
{
    return YES;
}

static BOOL IOSIPModernNo(id self, SEL selector)
{
    return NO;
}

static NSString *IOSIPModernCallNumber(id self, SEL selector)
{
    return IOSIPRemoteNumber();
}

static NSString *IOSIPModernCallIdentifier(id self, SEL selector)
{
    return IOSIPCurrentState[@"call_id"] ?: @"me.ancal.iosip.call";
}

static NSUUID *IOSIPModernCallUUID(id self, SEL selector)
{
    return [[NSUUID alloc] initWithUUIDString:IOSIPModernCallIdentifier(nil, 0)];
}

static NSString *IOSIPModernSourceIdentifier(id self, SEL selector)
{
    return @"me.ancal.iosip";
}

static NSString *IOSIPModernAudioCategory(id self, SEL selector)
{
    return @"PhoneCall";
}

static NSString *IOSIPModernAudioMode(id self, SEL selector)
{
    return @"VoiceChat";
}

static int IOSIPModernService(id self, SEL selector)
{
    return 1;
}

static double IOSIPModernStartTime(id self, SEL selector)
{
    id start = IOSIPCurrentState[@"connected_at"] ?:
        IOSIPCurrentState[@"started_at"];
    return [start isKindOfClass:[NSDate class]] ?
        [start timeIntervalSinceReferenceDate] :
        ([start respondsToSelector:@selector(doubleValue)] ?
            [start doubleValue] : 0);
}

static double IOSIPModernCallDuration(id self, SEL selector)
{
    id start = IOSIPCurrentState[@"connected_at"];
    if ([start isKindOfClass:[NSDate class]])
        return MAX(0, [[NSDate date] timeIntervalSinceDate:start]);
    double value = [start respondsToSelector:@selector(doubleValue)] ?
        [start doubleValue] : 0;
    return value > 0 ?
        MAX(0, [[NSDate date] timeIntervalSince1970] - value) : 0;
}

static void IOSIPModernAnswer(id self, SEL selector)
{
    IOSIPCommand(@"ANSWER");
}

static void IOSIPModernDisconnect(id self, SEL selector)
{
    IOSIPCommand(@"HANGUP TUCall");
}

static BOOL IOSIPModernSetMuted(id self, SEL selector, BOOL muted)
{
    BOOL success = [IOSIPCommand(muted ? @"MUTE 1" : @"MUTE 0")
        isEqualToString:@"OK"];
    if (success)
        IOSIPMuted = muted;
    return success;
}

static BOOL IOSIPModernIsMuted(id self, SEL selector)
{
    return IOSIPMuted;
}

static void IOSIPModernPlayDTMF(id self, SEL selector, unsigned char key)
{
    IOSIPCommand([NSString stringWithFormat:@"DTMF %c", key]);
}

static void IOSIPModernAddMethod(Class cls, NSString *name, IMP method,
                                  const char *types)
{
    class_addMethod(cls, NSSelectorFromString(name), method, types);
}

static BOOL IOSIPCreateModernCall(void)
{
    Class callClass = objc_getClass("TUCall");
    Class groupClass = objc_getClass("TUCallGroup");
    if (!callClass || !groupClass)
        return NO;
    Class cls = objc_getClass("IOSIPSyntheticTUCall");
    if (!cls) {
        cls = objc_allocateClassPair(callClass,
                                     "IOSIPSyntheticTUCall", 0);
        IOSIPModernAddMethod(cls, @"status", (IMP)IOSIPModernCallStatus,
                             "i@:");
        IOSIPModernAddMethod(cls, @"callStatus", (IMP)IOSIPModernCallStatus,
                             "i@:");
        IOSIPModernAddMethod(cls, @"transitionStatus",
                             (IMP)IOSIPModernCallStatus, "i@:");
        IOSIPModernAddMethod(cls, @"service", (IMP)IOSIPModernService,
                             "i@:");
        IOSIPModernAddMethod(cls, @"destinationID",
                             (IMP)IOSIPModernCallNumber, "@@:");
        IOSIPModernAddMethod(cls, @"displayName",
                             (IMP)IOSIPModernCallNumber, "@@:");
        IOSIPModernAddMethod(cls, @"multiLineDisplayName",
                             (IMP)IOSIPModernCallNumber, "@@:");
        IOSIPModernAddMethod(cls, @"suggestedDisplayName",
                             (IMP)IOSIPModernCallNumber, "@@:");
        IOSIPModernAddMethod(cls, @"uniqueProxyIdentifier",
                             (IMP)IOSIPModernCallIdentifier, "@@:");
        IOSIPModernAddMethod(cls, @"callHistoryIdentifier",
                             (IMP)IOSIPModernCallIdentifier, "@@:");
        IOSIPModernAddMethod(cls, @"callUUID", (IMP)IOSIPModernCallUUID,
                             "@@:");
        IOSIPModernAddMethod(cls, @"sourceIdentifier",
                             (IMP)IOSIPModernSourceIdentifier, "@@:");
        IOSIPModernAddMethod(cls, @"audioCategory",
                             (IMP)IOSIPModernAudioCategory, "@@:");
        IOSIPModernAddMethod(cls, @"audioMode", (IMP)IOSIPModernAudioMode,
                             "@@:");
        IOSIPModernAddMethod(cls, @"startTime", (IMP)IOSIPModernStartTime,
                             "d@:");
        IOSIPModernAddMethod(cls, @"callDuration",
                             (IMP)IOSIPModernCallDuration, "d@:");
        IOSIPModernAddMethod(cls, @"isOutgoing",
                             (IMP)IOSIPModernCallIsOutgoing, "B@:");
        IOSIPModernAddMethod(cls, @"isConnected",
                             (IMP)IOSIPModernCallIsConnected, "B@:");
        IOSIPModernAddMethod(cls, @"isConnecting",
                             (IMP)IOSIPModernCallIsConnecting, "B@:");
        IOSIPModernAddMethod(cls, @"isAlerting",
                             (IMP)IOSIPModernCallIsAlerting, "B@:");
        IOSIPModernAddMethod(cls, @"shouldPlayInCallSounds",
                             (IMP)IOSIPModernCallIsAlerting, "B@:");
        IOSIPModernAddMethod(cls, @"isActive",
                             (IMP)IOSIPModernCallIsActive, "B@:");
        IOSIPModernAddMethod(cls, @"isStatusFinal",
                             (IMP)IOSIPModernCallIsFinal, "B@:");
        for (NSString *name in @[@"isEndpointOnCurrentDevice",
                                 @"isHostedOnCurrentDevice",
                                 @"managesAudioInterruptions"])
            IOSIPModernAddMethod(cls, name, (IMP)IOSIPModernYes, "B@:");
        for (NSString *name in @[@"isVideo", @"isVoIPCall",
                                 @"isEmergencyCall", @"isVoicemail",
                                 @"isOnHold", @"isBlocked",
                                 @"shouldSuppressRingtone"])
            IOSIPModernAddMethod(cls, name, (IMP)IOSIPModernNo, "B@:");
        IOSIPModernAddMethod(cls, @"answer", (IMP)IOSIPModernAnswer,
                             "v@:");
        IOSIPModernAddMethod(cls, @"disconnect",
                             (IMP)IOSIPModernDisconnect, "v@:");
        IOSIPModernAddMethod(cls, @"isMuted", (IMP)IOSIPModernIsMuted,
                             "B@:");
        IOSIPModernAddMethod(cls, @"setMuted:",
                             (IMP)IOSIPModernSetMuted, "B@:B");
        IOSIPModernAddMethod(cls, @"playDTMFToneForKey:",
                             (IMP)IOSIPModernPlayDTMF, "v@:C");
        objc_registerClassPair(cls);
    }
    IOSIPModernCall = ((id (*)(id, SEL, id))objc_msgSend)(
        [cls alloc], @selector(initWithUniqueProxyIdentifier:),
        @"me.ancal.iosip.call");
    IOSIPModernCallGroup = [groupClass new];
    ((void (*)(id, SEL, id))objc_msgSend)(
        IOSIPModernCallGroup, @selector(setCalls:), @[IOSIPModernCall]);
    return IOSIPModernCall && IOSIPModernCallGroup;
}

static void IOSIPNotifyModernState(void)
{
    if (!IOSIPModernCall)
        return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center postNotificationName:IOSIPTUCallStatusNotification
                          object:IOSIPModernCall];
    [center postNotificationName:IOSIPTUCallModelNotification object:nil];
    if ([IOSIPCurrentState[@"state"] isEqualToString:@"connected"])
        [center postNotificationName:IOSIPTUCallConnectedNotification
                              object:IOSIPModernCall];
}

static void IOSIPActivateModernCallUI(void)
{
    if (!IOSIPIsSpringBoardProcess && !IOSIPIsInCallServiceProcess)
        return;
    if (IOSIPIsInCallServiceProcess && !IOSIPModernCall)
        return;
    if (!IOSIPModernHasCall()) {
        IOSIPActivatedCallID = nil;
        return;
    }
    NSString *callID = IOSIPCurrentState[@"call_id"] ?:
        @"me.ancal.iosip.call";
    if ([IOSIPActivatedCallID isEqualToString:callID])
        return;
    if (IOSIPIsInCallServiceProcess) {
        id application = [UIApplication sharedApplication];
        SEL selector = @selector(activateRemoteAlertsForCall:withURL:);
        if (![application respondsToSelector:selector])
            return;
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            application, selector, IOSIPModernCall, nil);
        IOSIPActivatedCallID = callID;
        return;
    }
    id application = [UIApplication sharedApplication];
    SEL launch = @selector(launchApplicationWithIdentifier:suspended:);
    if ([application respondsToSelector:launch])
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(
            application, launch, @"com.apple.InCallService", NO);
    IOSIPActivatedCallID = callID;
}

static Boolean IOSIPPNIsValidPhoneNumberForCountry(
    CFStringRef number, CFStringRef country)
{
    return OriginalPNIsValidPhoneNumberForCountry(number, country) ||
           IOSIPIsDialableNumber((__bridge NSString *)number);
}

static const void *
IOSIPTUCopyPrimaryPersonForDestinationIDInAddressBook(
    const void *destination, CTCallRef call, void *match,
    void *label, void *value, void *addressBook, int options)
{
    return OriginalTUCopyPrimaryPersonForDestinationIDInAddressBook(
        destination, IOSIPIsSyntheticCall(call) ? NULL : call, match,
        label, value, addressBook, options);
}

static CFArrayRef IOSIPCTCopyCurrentCalls(CFAllocatorRef allocator)
{
    if (!IOSIPHasCall())
        return OriginalCTCopyCurrentCalls ?
            OriginalCTCopyCurrentCalls(allocator) : NULL;
    const void *values[] = {IOSIPActiveCallToken()};
    return CFArrayCreate(allocator, values, 1, &kCFTypeArrayCallBacks);
}

static CFArrayRef IOSIP_CTCallCopyCurrentCalls(
    CFAllocatorRef allocator, Boolean activeOnly)
{
    if (!IOSIPHasCall())
        return Original_CTCallCopyCurrentCalls(allocator, activeOnly);
    const void *values[] = {IOSIPActiveCallToken()};
    return CFArrayCreate(allocator, values, 1, &kCFTypeArrayCallBacks);
}

static CFArrayRef IOSIP_CTCallCopyAllCalls(void)
{
    CFArrayRef original = Original_CTCallCopyAllCalls();
    NSArray *history;
    NSDictionary *tokens;
    @synchronized (IOSIPNotification) {
        history = IOSIPHistory;
        tokens = [IOSIPHistoryTokens copy];
    }
    if (!history.count)
        return original;
    NSMutableArray *calls =
        [NSMutableArray arrayWithCapacity:
            history.count + (original ? CFArrayGetCount(original) : 0)];
    for (NSDictionary *record in history) {
        NSString *token = tokens[record[@"call_id"]];
        if (token)
            [calls addObject:token];
    }
    if (original) {
        [calls addObjectsFromArray:(__bridge NSArray *)original];
        CFRelease(original);
    }
    return (__bridge_retained CFArrayRef)calls;
}

static CFArrayRef IOSIPCTCallCopyAllMissedCallsSince(CFDateRef since)
{
    CFArrayRef original = OriginalCTCallCopyAllMissedCallsSince(since);
    NSArray *history;
    NSDictionary *tokens;
    @synchronized (IOSIPNotification) {
        history = IOSIPHistory;
        tokens = [IOSIPHistoryTokens copy];
    }
    NSMutableArray *calls = [NSMutableArray array];
    NSDate *sinceDate = (__bridge NSDate *)since;
    for (NSDictionary *record in history) {
        if (!IOSIPIsMissedRecord(record))
            continue;
        NSDate *date = record[@"started_at"] ?: record[@"time"];
        if (sinceDate &&
            (!date || [date compare:sinceDate] == NSOrderedAscending))
            continue;
        NSString *token = tokens[record[@"call_id"]];
        if (token)
            [calls addObject:token];
    }
    if (!calls.count)
        return original;
    if (original) {
        [calls addObjectsFromArray:(__bridge NSArray *)original];
        CFRelease(original);
    }
    return (__bridge_retained CFArrayRef)calls;
}

static void IOSIP_CTCallDeleteFromCallHistory(CTCallRef call)
{
    NSDictionary *record = IOSIPHistoryRecord(call);
    if (!record) {
        if (!IOSIPIsSyntheticCall(call))
            Original_CTCallDeleteFromCallHistory(call);
        return;
    }
    NSString *callID = record[@"call_id"];
    if (callID.length)
        IOSIPCommand(
            [@"HISTORY_DELETE " stringByAppendingString:callID]);
    IOSIPReloadHistory();
}

static void IOSIP_CTCallDeleteAllCallsBeforeDate(CFDateRef date)
{
    Original_CTCallDeleteAllCallsBeforeDate(date);
    if (!date) {
        IOSIPCommand(@"HISTORY_CLEAR");
        IOSIPReloadHistory();
    }
}

static int IOSIPCTCallSetAllCallsRead(void)
{
    int result = OriginalCTCallSetAllCallsRead();
    if ([IOSIPCommand(@"HISTORY_MARK_ALL_READ")
            isEqualToString:@"OK"]) {
        IOSIPReloadHistory();
    } else {
        result = 0;
    }
    return result;
}

static int IOSIPCTCallGetCountOfUnreadCallsWithTypes(CFArrayRef types)
{
    int count = OriginalCTCallGetCountOfUnreadCallsWithTypes(types);
    if (types &&
        ![(__bridge NSArray *)types
            containsObject:(__bridge NSString *)IOSIPCTCallTypeNormal])
        return count;
    NSArray *history;
    @synchronized (IOSIPNotification) {
        history = IOSIPHistory;
    }
    for (NSDictionary *record in history) {
        if (IOSIPIsUnreadMissedRecord(record))
            ++count;
    }
    return count;
}

static int IOSIPCTGetCurrentCallCount(void)
{
    return IOSIPHasCall() ? 1 :
        (OriginalCTGetCurrentCallCount ?
            OriginalCTGetCurrentCallCount() : 0);
}

static int IOSIPCTCallGetStatus(CTCallRef call)
{
    if (IOSIPIsCall(call))
        return IOSIPCallStatus();
    return IOSIPIsSyntheticCall(call) ? 5 :
        OriginalCTCallGetStatus(call);
}

static CFStringRef IOSIPCTCallCopyAddress(CFAllocatorRef allocator,
                                           CTCallRef call)
{
    NSDictionary *record = IOSIPHistoryRecord(call);
    if (!IOSIPIsSyntheticCall(call))
        return OriginalCTCallCopyAddress(allocator, call);
    NSString *number = record ?
        IOSIPNumberFromRemote(record[@"remote"]) :
        (IOSIPIsCall(call) ? IOSIPRemoteNumber() : @"");
    return CFStringCreateCopy(allocator, (__bridge CFStringRef)
                             number);
}

static CFStringRef IOSIPCTCallCopyCountryCode(CFAllocatorRef allocator,
                                               CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? NULL :
        OriginalCTCallCopyCountryCode(allocator, call);
}

static CFStringRef IOSIPCTCallCopyNetworkCode(CFAllocatorRef allocator,
                                               CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? NULL :
        OriginalCTCallCopyNetworkCode(allocator, call);
}

static Boolean IOSIPCTCallAddressBlocked(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? false :
        OriginalCTCallAddressBlocked(call);
}

static CFStringRef IOSIPCTCallCopyName(CFAllocatorRef allocator,
                                        CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? NULL :
        OriginalCTCallCopyName(allocator, call);
}

static Boolean IOSIPCTCallIsOutgoing(CTCallRef call)
{
    NSDictionary *record = IOSIPHistoryRecord(call);
    if (IOSIPIsCall(call))
        return [IOSIPCurrentState[@"direction"]
            isEqualToString:@"outgoing"];
    return record ?
        [record[@"direction"] isEqualToString:@"outgoing"] :
        (IOSIPIsSyntheticCall(call) ? false :
            OriginalCTCallIsOutgoing(call));
}

static Boolean IOSIPCTCallIsAlerting(CTCallRef call)
{
    if (IOSIPIsCall(call))
        return [IOSIPCurrentState[@"state"]
            isEqualToString:@"incoming"];
    return IOSIPIsSyntheticCall(call) ? false :
        OriginalCTCallIsAlerting(call);
}

static Boolean IOSIPCTCallIsConferenced(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? false :
        OriginalCTCallIsConferenced(call);
}

static Boolean IOSIPCTCallIsToVoicemail(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? false :
        OriginalCTCallIsToVoicemail(call);
}

static Boolean IOSIPCTCallGetEmergencyStatus(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? false :
        OriginalCTCallGetEmergencyStatus(call);
}

static int IOSIPCTCallGetID(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? -1 :
        OriginalCTCallGetID(call);
}

static Boolean IOSIPCTCallGetRead(CTCallRef call)
{
    NSDictionary *record = IOSIPHistoryRecord(call);
    if (record)
        return ![record[@"read"] isEqual:@NO];
    return IOSIPIsSyntheticCall(call) ? true :
        OriginalCTCallGetRead(call);
}

static CFStringRef IOSIPCTCallCopyUniqueStringID(
    CFAllocatorRef allocator, CTCallRef call)
{
    if (!IOSIPIsSyntheticCall(call))
        return OriginalCTCallCopyUniqueStringID(allocator, call);
    NSDictionary *record = IOSIPHistoryRecord(call);
    NSString *identifier = record[@"call_id"] ?:
        (IOSIPIsCall(call) ? IOSIPCurrentState[@"call_id"] :
            (__bridge NSString *)call);
    return identifier ?
        CFStringCreateCopy(
            allocator, (__bridge CFStringRef)identifier) : NULL;
}

static Boolean IOSIPCTCallGetStartTime(CTCallRef call, double *startTime)
{
    NSDictionary *record = IOSIPHistoryRecord(call);
    if (!IOSIPIsSyntheticCall(call))
        return OriginalCTCallGetStartTime(call, startTime);
    NSDate *startedAt = record ?
        record[@"started_at"] : IOSIPCurrentState[@"started_at"];
    if ((!IOSIPIsCall(call) && !record) ||
        !startedAt || !startTime)
        return false;
    *startTime = [startedAt timeIntervalSinceReferenceDate];
    return true;
}

static CFStringRef IOSIPCTCallGetCallType(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? IOSIPCTCallTypeNormal :
        OriginalCTCallGetCallType(call);
}

static Boolean IOSIPCTCallGetDuration(CTCallRef call, double *duration)
{
    NSDictionary *record = IOSIPHistoryRecord(call);
    if (!IOSIPIsSyntheticCall(call))
        return OriginalCTCallGetDuration(call, duration);
    if ((!IOSIPIsCall(call) && !record) || !duration)
        return false;
    NSDate *connectedAt = record ?
        record[@"connected_at"] : IOSIPCurrentState[@"connected_at"];
    NSDate *endedAt = record[@"time"];
    *duration = connectedAt ?
        (record ? [endedAt timeIntervalSinceDate:connectedAt] :
            -[connectedAt timeIntervalSinceNow]) : 0;
    return true;
}

static CTCallRef IOSIPCTCallDialWithID(CFStringRef number, int uid)
{
    NSString *reply = IOSIPDialReply((__bridge NSString *)number);
    if ([reply isEqualToString:@"OK"])
        return IOSIPActiveCallToken();
    if ([reply isEqualToString:@"UNREGISTERED"])
        return OriginalCTCallDialWithID(number, uid);
    return NULL;
}

static int IOSIPCTCallAnswer(CTCallRef call)
{
    if (!IOSIPIsCall(call) && IOSIPIsSyntheticCall(call))
        return 0;
    if (!IOSIPIsCall(call))
        return OriginalCTCallAnswer(call);
    return [IOSIPCommand(@"ANSWER") isEqualToString:@"OK"];
}

static int IOSIPCTCallResume(CTCallRef call)
{
    if (!IOSIPIsCall(call) && IOSIPIsSyntheticCall(call))
        return 0;
    if (!IOSIPIsCall(call))
        return OriginalCTCallResume(call);
    return [IOSIPCommand(@"ANSWER") isEqualToString:@"OK"];
}

static int IOSIPCTCallDisconnect(CTCallRef call)
{
    if (!IOSIPIsCall(call) && IOSIPIsSyntheticCall(call))
        return 1;
    if (!IOSIPIsCall(call))
        return OriginalCTCallDisconnect(call);
    return [IOSIPCommand(@"HANGUP CTCallDisconnect")
        isEqualToString:@"OK"];
}

static int IOSIPCTCallListDisconnect(void)
{
    return IOSIPHasCall() ?
        [IOSIPCommand(@"HANGUP CTCallListDisconnect")
            isEqualToString:@"OK"] :
        OriginalCTCallListDisconnect();
}

static int IOSIPCTCallListDisconnectAll(void)
{
    return IOSIPHasCall() ?
        [IOSIPCommand(@"HANGUP CTCallListDisconnectAll")
            isEqualToString:@"OK"] :
        OriginalCTCallListDisconnectAll();
}

static int IOSIPCTCallHold(CTCallRef call)
{
    return IOSIPIsSyntheticCall(call) ? 0 : OriginalCTCallHold(call);
}

static int IOSIPCTDTMFPlayStart(int digit)
{
    if (!IOSIPHasCall())
        return OriginalCTDTMFPlayStart(digit);
    if (!strchr("0123456789*#ABCD", digit))
        return 0;
    NSString *command = [NSString
        stringWithFormat:@"DTMF %c", digit];
    return [IOSIPCommand(command) isEqualToString:@"OK"];
}

static int IOSIPCTDTMFPlayStop(void)
{
    return IOSIPHasCall() ? 1 : OriginalCTDTMFPlayStop();
}

static void IOSIPCTTelephonyCenterAddObserver(
    void *center, void *observer, CTStatusCallback callback,
    CFStringRef name, const void *object, int suspension)
{
    BOOL sipObjectObserver = object == IOSIPCallToken;
    if (!sipObjectObserver)
        OriginalCTTelephonyCenterAddObserver(
            center, observer, callback, name, object, suspension);
    BOOL callNotification =
        name && (CFEqual(name, IOSIPCTCallStatusChangeNotification) ||
                 CFEqual(name, IOSIPCTCallIdentificationChangeNotification));
    BOOL historyNotification =
        name && (CFEqual(name, IOSIPCTCallHistoryRecordAddNotification) ||
                 CFEqual(
                     name, IOSIPCTCallHistorySignificantChangeNotification));
    if ((!callNotification && !historyNotification) ||
        (callNotification && object && object != IOSIPCallToken) ||
        (historyNotification && object) ||
        !IOSIPShouldCaptureCallback(callback))
        return;
    @synchronized (IOSIPNotification) {
        BOOL duplicate = NO;
        for (NSUInteger index = 0; index < IOSIPObserverCount; ++index) {
            IOSIPObserver item = IOSIPObservers[index];
            duplicate = item.center == center &&
                        item.observer == observer &&
                        item.callback == callback &&
                        item.name == name &&
                        item.object == object;
            if (duplicate)
                break;
        }
        if (!duplicate && IOSIPObserverCount < 32) {
            IOSIPObservers[IOSIPObserverCount++] =
                (IOSIPObserver){center, observer, callback,
                                name, object};
        }
    }
    if (callNotification && IOSIPHasCall()) {
        CTCallRef token = IOSIPCallToken;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (IOSIPIsCall(token) &&
                (!object || object == token) &&
                IOSIPObserverIsRegistered(
                    center, observer, callback, name, object))
                callback(center, observer, name, token, NULL);
        });
    }
}

static void IOSIPCTTelephonyCenterRemoveObserver(
    void *center, void *observer, CFStringRef name, const void *object)
{
    @synchronized (IOSIPNotification) {
        for (NSUInteger index = 0; index < IOSIPObserverCount;) {
            IOSIPObserver item = IOSIPObservers[index];
            BOOL nameMatches = !name || CFEqual(name, item.name);
            BOOL objectMatches = !object || object == item.object;
            if (item.observer == observer && nameMatches && objectMatches) {
                memmove(&IOSIPObservers[index],
                        &IOSIPObservers[index + 1],
                        (IOSIPObserverCount - index - 1) *
                        sizeof(IOSIPObserver));
                --IOSIPObserverCount;
            } else {
                ++index;
            }
        }
    }
    BOOL sipObjectObserver = object == IOSIPCallToken;
    if (!sipObjectObserver)
        OriginalCTTelephonyCenterRemoveObserver(
            center, observer, name, object);
}

static void IOSIPCTTelephonyCenterRemoveEveryObserver(
    void *center, void *observer)
{
    @synchronized (IOSIPNotification) {
        for (NSUInteger index = 0; index < IOSIPObserverCount;) {
            IOSIPObserver item = IOSIPObservers[index];
            if (item.center == center && item.observer == observer) {
                memmove(&IOSIPObservers[index],
                        &IOSIPObservers[index + 1],
                        (IOSIPObserverCount - index - 1) *
                        sizeof(IOSIPObserver));
                --IOSIPObserverCount;
            } else {
                ++index;
            }
        }
    }
    OriginalCTTelephonyCenterRemoveEveryObserver(center, observer);
}

static void IOSIPHook(const char *symbol, void *replacement,
                       void **original)
{
    void *target = dlsym(RTLD_DEFAULT, symbol);
    if (target)
        MSHookFunction(target, replacement, original);
}

%group IOSIPDialerHooks

%hook DialerController

- (void)performCallActionForService:(int)service
{
    if (service != 1) {
        %orig;
        return;
    }
    Ivar ivar = class_getInstanceVariable([(id)self class], "_dialerView");
    id dialerView = ivar ? object_getIvar(self, ivar) : nil;
    id lcdView = [dialerView respondsToSelector:@selector(lcdView)] ?
        ((id (*)(id, SEL))objc_msgSend)(dialerView, @selector(lcdView)) : nil;
    NSString *number = [lcdView respondsToSelector:@selector(text)] ?
        ((id (*)(id, SEL))objc_msgSend)(lcdView, @selector(text)) : nil;
    NSString *reply = IOSIPDialReply(number);
    if (!reply || [reply isEqualToString:@"UNREGISTERED"])
        %orig;
}

- (void)_updateCallButtonEnabledState:(NSString *)number
{
    %orig;
    if (!IOSIPIsDialableNumber(number))
        return;
    Ivar ivar = class_getInstanceVariable([(id)self class], "_dialerView");
    id dialerView = ivar ? object_getIvar(self, ivar) : nil;
    id callButton = [dialerView callButton];
    SEL selector = @selector(setCharge:);
    if ([callButton respondsToSelector:selector])
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(
            callButton, selector, (CGFloat)-0.3);
}

%end

%end

%group IOSIPModernHooks

%hook TUCallCenter

- (NSArray *)currentCalls
{
    return IOSIPModernHasCall() ? @[IOSIPModernCall] : %orig;
}

- (NSArray *)_allCalls
{
    return IOSIPModernHasCall() ? @[IOSIPModernCall] : %orig;
}

- (NSArray *)currentAudioAndVideoCalls
{
    return IOSIPModernHasCall() ? @[IOSIPModernCall] : %orig;
}

- (NSArray *)displayedCalls
{
    return IOSIPModernHasCall() ? @[IOSIPModernCall] : %orig;
}

- (NSArray *)incomingCalls
{
    return IOSIPModernHasCall() ?
        ([IOSIPCurrentState[@"state"] isEqualToString:@"incoming"] ?
            @[IOSIPModernCall] : @[]) : %orig;
}

- (NSArray *)currentCallGroups
{
    return IOSIPModernHasCall() ? @[IOSIPModernCallGroup] : %orig;
}

- (NSUInteger)currentCallCount
{
    return IOSIPModernHasCall() ? 1 : %orig;
}

- (NSUInteger)currentAudioAndVideoCallCount
{
    return IOSIPModernHasCall() ? 1 : %orig;
}

- (id)incomingCall
{
    if (!IOSIPModernHasCall())
        return %orig;
    return [IOSIPCurrentState[@"state"] isEqualToString:@"incoming"] ?
        IOSIPModernCall : nil;
}

- (id)displayedCall
{
    return IOSIPModernHasCall() ? IOSIPModernCall : %orig;
}

- (id)frontmostCall
{
    return IOSIPModernHasCall() ? IOSIPModernCall : %orig;
}

- (id)frontmostAudioOrVideoCall
{
    return IOSIPModernHasCall() ? IOSIPModernCall : %orig;
}

- (id)displayedCallFromCalls:(NSArray *)calls
{
    return [calls containsObject:IOSIPModernCall] ? IOSIPModernCall : %orig;
}

- (id)callWithStatus:(int)status
{
    return IOSIPModernHasCall() && status == IOSIPModernCallStatus(nil, 0) ?
        IOSIPModernCall : %orig;
}

- (NSArray *)callsWithStatus:(int)status
{
    return IOSIPModernHasCall() ?
        (status == IOSIPModernCallStatus(nil, 0) ?
            @[IOSIPModernCall] : @[]) : %orig;
}

- (id)audioOrVideoCallWithStatus:(int)status
{
    return IOSIPModernHasCall() && status == IOSIPModernCallStatus(nil, 0) ?
        IOSIPModernCall : %orig;
}

- (NSArray *)audioAndVideoCallsWithStatus:(int)status
{
    return IOSIPModernHasCall() ?
        (status == IOSIPModernCallStatus(nil, 0) ?
            @[IOSIPModernCall] : @[]) : %orig;
}

- (BOOL)isAddCallAllowed
{
    return IOSIPModernHasCall() ? NO : %orig;
}

- (BOOL)isHoldAllowed
{
    return IOSIPModernHasCall() ? NO : %orig;
}

- (BOOL)anyCallIsHostedOnCurrentDevice
{
    return IOSIPModernHasCall() ? YES : %orig;
}

- (BOOL)anyCallIsEndpointOnCurrentDevice
{
    return IOSIPModernHasCall() ? YES : %orig;
}

- (void)answerCall:(id)call
{
    if (call == IOSIPModernCall)
        IOSIPModernAnswer(call, _cmd);
    else
        %orig;
}

- (void)answerCall:(id)call withSourceIdentifier:(id)source
{
    if (call == IOSIPModernCall)
        IOSIPModernAnswer(call, _cmd);
    else
        %orig;
}

- (void)answerCall:(id)call
    withSourceIdentifier:(id)source
    wantsHoldMusic:(BOOL)holdMusic
{
    if (call == IOSIPModernCall)
        IOSIPModernAnswer(call, _cmd);
    else
        %orig;
}

- (void)disconnectCall:(id)call
{
    if (call == IOSIPModernCall)
        IOSIPModernDisconnect(call, _cmd);
    else
        %orig;
}

- (void)disconnectCall:(id)call withReason:(int)reason
{
    if (call == IOSIPModernCall)
        IOSIPModernDisconnect(call, _cmd);
    else
        %orig;
}

- (void)resumeCall:(id)call
{
    if (call != IOSIPModernCall)
        %orig;
}

- (void)disconnectAllCalls
{
    if (IOSIPModernHasCall())
        IOSIPModernDisconnect(IOSIPModernCall, _cmd);
    else
        %orig;
}

%end


%end


%group IOSIPLegacyHooks

%hook PhoneApplication

- (BOOL)shouldAttemptPhoneCall
{
    return YES;
}

- (BOOL)promptForTTY
{
    return NO;
}

- (NSString *)ttyTitle
{
    return @"TTY";
}

- (BOOL)isMuted
{
    return IOSIPHasCall() ? IOSIPMuted : %orig;
}

- (BOOL)setMuted:(BOOL)muted
{
    if (!IOSIPHasCall())
        return %orig;
    %orig;
    BOOL success = [IOSIPCommand(
        muted ? @"MUTE 1" : @"MUTE 0") isEqualToString:@"OK"];
    if (success)
        IOSIPMuted = muted;
    return success;
}

%end

%hook AVController

- (void)beginInterruption:(id)status
{
    if (IOSIPIsSpringBoardProcess &&
        self == IOSIPPhoneAudioController &&
        [IOSIPCurrentState[@"direction"] isEqualToString:@"outgoing"])
        return;
    %orig;
}

- (BOOL)setAttribute:(id)value forKey:(id)key error:(id *)error
{
    if (IOSIPIsSpringBoardProcess &&
        [value isEqual:@"Phone"])
        IOSIPPhoneAudioController = self;
    if (IOSIPIsSpringBoardProcess && IOSIPHasCall() &&
        ([value isEqual:@"PhoneCall"] ||
         [value isEqual:@"TTYCall"]))
        return YES;
    return %orig;
}

%end

%hook AudioDeviceController

- (void)_pickRoute:(id)route
{
    %orig;
    if (!IOSIPHasCall())
        return;
    if (((BOOL (*)(id, SEL, id))objc_msgSend)(
            self, @selector(_routeIsSpeaker:), route))
        IOSIPCommand(@"ROUTE SPEAKER");
    else if (((BOOL (*)(id, SEL, id))objc_msgSend)(
                 self, @selector(_routeIsHandset:), route))
        IOSIPCommand(@"ROUTE HANDSET");
}

%end

%hook TPPhoneCallModel

- (BOOL)isAddCallAllowed
{
    return IOSIPHasCall() ? NO : %orig;
}

- (BOOL)isHoldAllowed
{
    return IOSIPHasCall() ? NO : %orig;
}

%end

%hook InCallController

- (void)_toggleHold
{
    if (!IOSIPHasCall())
        %orig;
}

%end

%hook SBTelephonyManager

- (NSString *)ttyTitle
{
    return @"TTY";
}

%end

%end

static void IOSIPInitialize(void)
{
    @autoreleasepool {
        static BOOL initialized;
        if (initialized)
            return;
        initialized = YES;
        NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
        if (![bundle isEqualToString:@"com.apple.mobilephone"] &&
            ![bundle isEqualToString:@"com.apple.springboard"] &&
            ![bundle isEqualToString:@"com.apple.InCallService"])
            return;
        IOSIPIsSpringBoardProcess =
            [bundle isEqualToString:@"com.apple.springboard"];
        IOSIPIsInCallServiceProcess =
            [bundle isEqualToString:@"com.apple.InCallService"];
        if ([bundle isEqualToString:@"com.apple.mobilephone"])
            %init(IOSIPDialerHooks);
        BOOL modern =
            [UIDevice currentDevice].systemVersion.integerValue >= 7;
        if (modern && IOSIPIsSpringBoardProcess) {
            IOSIPCurrentState = IOSIPState() ?: @{};
            IOSIPGeneration =
                [IOSIPCurrentState[@"generation"] unsignedLongLongValue];
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                IOSIPStateChanged,
                (__bridge CFStringRef)IOSIPNotification,
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            return;
        }
        if (modern) {
            if (!IOSIPCreateModernCall())
                return;
            %init(IOSIPModernHooks);
        } else {
            %init(IOSIPLegacyHooks);
        }

        IOSIPCTCallStatusChangeNotification = IOSIPCoreTelephonyConstant(
            "kCTCallStatusChangeNotification",
            CFSTR("kCTCallStatusChangeNotification"));
        IOSIPCTCallIdentificationChangeNotification =
            IOSIPCoreTelephonyConstant(
                "kCTCallIdentificationChangeNotification",
                CFSTR("kCTCallIdentificationChangeNotification"));
        IOSIPCTCallHistoryRecordAddNotification =
            IOSIPCoreTelephonyConstant(
                "kCTCallHistoryRecordAddNotification",
                CFSTR("kCTCallHistoryRecordAddNotification"));
        IOSIPCTCallHistorySignificantChangeNotification =
            IOSIPCoreTelephonyConstant(
                "kCTCallHistorySignificantChangeNotification",
                CFSTR("kCTCallHistorySignificantChangeNotification"));
        IOSIPCTCall = IOSIPCoreTelephonyConstant(
            "kCTCall", CFSTR("kCTCall"));
        IOSIPCTCallTypeNormal = IOSIPCoreTelephonyConstant(
            "kCTCallTypeNormal", CFSTR("kCTCallTypeNormal"));
        IOSIPTUCallStatusNotification =
            (__bridge NSString *)IOSIPCoreTelephonyConstant(
                "TUCallCenterCallStatusChangedNotification",
                CFSTR("TUCallCenterCallStatusChangedNotification"));
        IOSIPTUCallModelNotification =
            (__bridge NSString *)IOSIPCoreTelephonyConstant(
                "TUCallCenterModelStateChangedNotification",
                CFSTR("TUCallCenterModelStateChangedNotification"));
        IOSIPTUCallConnectedNotification =
            (__bridge NSString *)IOSIPCoreTelephonyConstant(
                "TUCallCenterCallConnectedNotification",
                CFSTR("TUCallCenterCallConnectedNotification"));

        IOSIPCurrentState = IOSIPState() ?: @{};
        IOSIPGeneration =
            [IOSIPCurrentState[@"generation"] unsignedLongLongValue];
        IOSIPHistoryGeneration =
            [IOSIPCurrentState[@"last_end"][@"generation"]
                unsignedLongLongValue];
        IOSIPReloadHistory();

        if (!modern) {
#define IOSIP_HOOK(symbol) \
        IOSIPHook(#symbol, (void *)&IOSIP##symbol, \
                   (void **)&Original##symbol)
        IOSIP_HOOK(CTCopyCurrentCalls);
        IOSIP_HOOK(_CTCallCopyCurrentCalls);
        IOSIP_HOOK(_CTCallCopyAllCalls);
        IOSIP_HOOK(CTCallCopyAllMissedCallsSince);
        IOSIP_HOOK(_CTCallDeleteFromCallHistory);
        IOSIP_HOOK(_CTCallDeleteAllCallsBeforeDate);
        IOSIP_HOOK(CTCallSetAllCallsRead);
        IOSIP_HOOK(CTCallGetCountOfUnreadCallsWithTypes);
        IOSIP_HOOK(CTGetCurrentCallCount);
        IOSIP_HOOK(CTCallGetStatus);
        IOSIP_HOOK(CTCallCopyAddress);
        IOSIP_HOOK(CTCallCopyCountryCode);
        IOSIP_HOOK(CTCallCopyNetworkCode);
        IOSIP_HOOK(CTCallAddressBlocked);
        IOSIP_HOOK(CTCallCopyName);
        IOSIP_HOOK(CTCallIsOutgoing);
        IOSIP_HOOK(CTCallIsAlerting);
        IOSIP_HOOK(CTCallIsConferenced);
        IOSIP_HOOK(CTCallIsToVoicemail);
        IOSIP_HOOK(CTCallGetEmergencyStatus);
        IOSIP_HOOK(CTCallGetID);
        IOSIP_HOOK(CTCallGetRead);
        IOSIP_HOOK(CTCallCopyUniqueStringID);
        IOSIP_HOOK(CTCallGetStartTime);
        IOSIP_HOOK(CTCallGetCallType);
        IOSIP_HOOK(CTCallGetDuration);
        IOSIP_HOOK(CTCallDialWithID);
        IOSIP_HOOK(CTCallAnswer);
        IOSIP_HOOK(CTCallResume);
        IOSIP_HOOK(CTCallDisconnect);
        IOSIP_HOOK(CTCallListDisconnect);
        IOSIP_HOOK(CTCallListDisconnectAll);
        IOSIP_HOOK(CTCallHold);
        IOSIP_HOOK(CTDTMFPlayStart);
        IOSIP_HOOK(CTDTMFPlayStop);
        IOSIP_HOOK(CTTelephonyCenterAddObserver);
        IOSIP_HOOK(CTTelephonyCenterRemoveObserver);
        IOSIP_HOOK(CTTelephonyCenterRemoveEveryObserver);
#undef IOSIP_HOOK
        IOSIPHook(
            "TUCopyPrimaryPersonForDestinationIDInAddressBook",
            (void *)&IOSIPTUCopyPrimaryPersonForDestinationIDInAddressBook,
            (void **)
                &OriginalTUCopyPrimaryPersonForDestinationIDInAddressBook);

        if ([bundle isEqualToString:@"com.apple.mobilephone"]) {
            IOSIPHook("PNIsValidPhoneNumberForCountry",
                       (void *)&IOSIPPNIsValidPhoneNumberForCountry,
                       (void **)&OriginalPNIsValidPhoneNumberForCountry);
        }
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            IOSIPStateChanged,
            (__bridge CFStringRef)IOSIPNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            IOSIPHistoryChanged,
            (__bridge CFStringRef)IOSIPHistoryNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        IOSIPReloadState();
        if (modern && IOSIPIsInCallServiceProcess)
            IOSIPActivateModernCallUI();
    }
}

%ctor
{
    @autoreleasepool {
        NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
        NSString *className =
            [bundle isEqualToString:@"com.apple.mobilephone"] ?
                @"DialerController" :
            ([bundle isEqualToString:@"com.apple.springboard"] ?
                @"SBTelephonyManager" :
            ([bundle isEqualToString:@"com.apple.InCallService"] ?
                @"InCallServiceApplication" : nil));
        if (!className)
            return;
        BOOL deferUntilLaunch =
            [bundle isEqualToString:@"com.apple.InCallService"] ||
            (!NSClassFromString(className) &&
             ![bundle isEqualToString:@"com.apple.springboard"]);
        if (!deferUntilLaunch && NSClassFromString(className)) {
            IOSIPInitialize();
        } else if (deferUntilLaunch) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidFinishLaunchingNotification
                object:nil
                queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *notification) {
                    IOSIPInitialize();
                }];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                IOSIPInitialize();
            });
        }
    }
}
