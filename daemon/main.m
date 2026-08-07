#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioSession.h>

#include <pjsua-lib/pjsua.h>
#include <pjsua-lib/pjsua_internal.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static NSString *const ConfigPath =
    @"/var/mobile/Library/Preferences/me.ancal.iosip.plist";
static NSString *const StateDirectory = @"/var/mobile/Library/IOSIP";
static NSString *const StatePath =
    @"/var/mobile/Library/IOSIP/state.plist";
static NSString *const HistoryPath =
    @"/var/mobile/Library/IOSIP/history.plist";
static NSString *const IPCTokenPath =
    @"/var/mobile/Library/IOSIP/ipc-token";
static NSString *const CallStateLock =
    @"me.ancal.iosip.call-state";
static const uint16_t IPCPort = 51601;
static NSString *IPCToken;

static void LaunchPhoneApplication(void)
{
    static int (*launch)(CFStringRef, Boolean);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *framework = dlopen(
            "/System/Library/PrivateFrameworks/"
            "SpringBoardServices.framework/SpringBoardServices",
            RTLD_LAZY);
        launch = dlsym(framework ?: RTLD_DEFAULT,
                       "SBSLaunchApplicationWithIdentifier");
    });
    if (launch)
        launch(CFSTR("com.apple.mobilephone"), false);
}

static pjsua_acc_id AccountID = PJSUA_INVALID_ID;
static pjsua_call_id CallID = PJSUA_INVALID_ID;
static BOOL Registered;
static unsigned long long Generation;
static NSDictionary *LastEnd;
static NSString *CurrentCallID;
static NSString *CurrentDirection;
static NSString *CurrentEndSource;
static NSDate *StartedAt;
static NSDate *ConnectedAt;
static NSDictionary *CurrentMedia;
static NSString *RewrittenRemoteSDPFrom;
static NSString *RewrittenRemoteSDPTo;
static NSNumber *AudioSessionInitializeStatus;
static NSNumber *AudioSessionCategoryStatus;
static NSNumber *AudioSessionActiveStatus;
static NSNumber *AudioRouteStatus;
static NSNumber *MuteStatus;
static BOOL CurrentMuted;
static BOOL CurrentSpeaker;
static BOOL ShouldExit;
static pjsip_route_hdr ProxyRouteSet;
static BOOL ProxyRouteReady;
static char SignalingAddress[INET_ADDRSTRLEN];
static char MediaAddress[INET_ADDRSTRLEN];
static pjsip_module SDPRewriteModule;
static unsigned CurrentCallSerial;
static unsigned AudioConnectedSerial;
static unsigned AudioScheduledSerial;
static BOOL CallStarting;
static BOOL IdlePending;
static const unsigned AudioConnectDelayMilliseconds = 750;

static BOOL ConfigureClientSocket(int socketFD)
{
    int enabled = 1;
    struct timeval timeout = {1, 0};
    return setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                      sizeof(enabled)) == 0 &&
           setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                      sizeof(timeout)) == 0 &&
           setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                      sizeof(timeout)) == 0;
}

static BOOL LoadIPCToken(void)
{
    IPCToken = [[NSString stringWithContentsOfFile:IPCTokenPath
                                         encoding:NSUTF8StringEncoding
                                            error:nil]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (IPCToken.length < 16) {
        IPCToken = [NSUUID UUID].UUIDString;
        if (![IPCToken writeToFile:IPCTokenPath
                        atomically:YES
                          encoding:NSUTF8StringEncoding
                             error:nil])
            return NO;
    }
    chown(IPCTokenPath.fileSystemRepresentation, 0, 501);
    chmod(IPCTokenPath.fileSystemRepresentation, 0640);
    return YES;
}

static ssize_t ReadCommand(int socketFD, char *buffer, size_t capacity)
{
    size_t length = 0;
    while (length < capacity - 1) {
        ssize_t received =
            read(socketFD, buffer + length, capacity - 1 - length);
        if (received > 0) {
            char *newline =
                memchr(buffer + length, '\n', (size_t)received);
            length += (size_t)received;
            if (newline) {
                length = (size_t)(newline - buffer);
                buffer[length] = '\0';
                return (ssize_t)length;
            }
            continue;
        }
        if (received < 0 && errno == EINTR)
            continue;
        return -1;
    }
    return -1;
}

static BOOL WriteAll(int socketFD, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t written = write(socketFD, cursor, length);
        if (written > 0) {
            cursor += written;
            length -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        return NO;
    }
    return YES;
}

static NSString *MemoryStatus(void)
{
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t status = task_info(
        mach_task_self(), MACH_TASK_BASIC_INFO,
        (task_info_t)&info, &count);
    if (status != KERN_SUCCESS)
        return @"ERROR";
    return [NSString stringWithFormat:
        @"rss=%llu peak=%llu virtual=%llu",
        (unsigned long long)info.resident_size,
        (unsigned long long)info.resident_size_max,
        (unsigned long long)info.virtual_size];
}

static void RestoreStateMetadata(void)
{
    NSDictionary *value =
        [NSDictionary dictionaryWithContentsOfFile:StatePath];
    Generation = [value[@"generation"] unsignedLongLongValue];
    LastEnd = [value[@"last_end"] copy];
}

static void PostHistoryNotification(void)
{
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("me.ancal.iosip.history"),
        NULL,
        NULL,
        true);
}

static void PostStateWithStatus(NSString *state, NSString *remote,
                                NSNumber *status, NSString *reason)
{
    NSFileManager *files = [NSFileManager defaultManager];
    @synchronized (StatePath) {
        [files createDirectoryAtPath:StateDirectory
         withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions: @0755}
                               error:nil];
        ++Generation;
        if ([state isEqualToString:@"ended"]) {
            NSMutableDictionary *lastEnd = [@{
                @"generation": @(Generation),
                @"remote": remote ?: @"",
                @"status": status ?: @0,
                @"reason": reason ?: @"",
                @"time": [NSDate date],
                @"read": @(![CurrentDirection
                    isEqualToString:@"incoming"] || ConnectedAt != nil),
            } mutableCopy];
            if (CurrentCallID)
                lastEnd[@"call_id"] = CurrentCallID;
            if (CurrentDirection)
                lastEnd[@"direction"] = CurrentDirection;
            if (StartedAt)
                lastEnd[@"started_at"] = StartedAt;
            if (ConnectedAt)
                lastEnd[@"connected_at"] = ConnectedAt;
            if (CurrentEndSource)
                lastEnd[@"end_source"] = CurrentEndSource;
            if (CurrentMedia)
                lastEnd[@"media"] = CurrentMedia;
            LastEnd = lastEnd;

            NSMutableArray *history = [[NSArray
                arrayWithContentsOfFile:HistoryPath] mutableCopy] ?:
                [NSMutableArray array];
            NSString *callID = lastEnd[@"call_id"];
            for (NSInteger index = history.count - 1; index >= 0;
                 --index) {
                if (callID.length &&
                    [history[index][@"call_id"] isEqualToString:callID])
                    [history removeObjectAtIndex:index];
            }
            [history insertObject:lastEnd atIndex:0];
            if (history.count > 100)
                [history removeObjectsInRange:
                    NSMakeRange(100, history.count - 100)];
            [history writeToFile:HistoryPath atomically:YES];
            chmod(HistoryPath.fileSystemRepresentation, 0644);
        }

        NSMutableDictionary *value = [@{
            @"state": state,
            @"remote": remote ?: @"",
            @"registered": @(Registered),
            @"generation": @(Generation),
        } mutableCopy];
        if (CurrentCallID)
            value[@"call_id"] = CurrentCallID;
        if (CurrentDirection)
            value[@"direction"] = CurrentDirection;
        if (StartedAt)
            value[@"started_at"] = StartedAt;
        if (ConnectedAt)
            value[@"connected_at"] = ConnectedAt;
        if (CurrentEndSource)
            value[@"end_source"] = CurrentEndSource;
        if (CurrentMedia)
            value[@"media"] = CurrentMedia;
        if (LastEnd)
            value[@"last_end"] = LastEnd;
        [value writeToFile:StatePath atomically:YES];
        chmod(StatePath.fileSystemRepresentation, 0644);

    }
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("me.ancal.iosip.state"),
        NULL,
        NULL,
        true);
}

static void PostState(NSString *state, NSString *remote)
{
    PostStateWithStatus(state, remote, nil, nil);
}

static NSString *RemoteForCall(pjsua_call_id callID)
{
    pjsua_call_info info;
    if (pjsua_call_get_info(callID, &info) != PJ_SUCCESS)
        return @"";
    return [[NSString alloc] initWithBytes:info.remote_info.ptr
                                   length:(NSUInteger)info.remote_info.slen
                                 encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *AddressString(const pj_sockaddr *address)
{
    if (address->addr.sa_family != pj_AF_INET() &&
        address->addr.sa_family != pj_AF_INET6())
        return @"";
    char buffer[80];
    return pj_sockaddr_print(address, buffer, sizeof(buffer), 1) ?
        @(buffer) : @"";
}

static NSDictionary *MediaSnapshot(
    pjsua_call_id callID, NSNumber *callToSoundStatus,
    NSNumber *soundToCallStatus)
{
    pjsua_call_info info;
    if (pjsua_call_get_info(callID, &info) != PJ_SUCCESS)
        return nil;

    NSDictionary *previousMedia;
    NSNumber *initializeStatus;
    NSNumber *categoryStatus;
    NSNumber *activeStatus;
    NSNumber *routeSetStatus;
    NSNumber *muteStatus;
    NSString *rewrittenFrom;
    NSString *rewrittenTo;
    BOOL muted;
    BOOL speaker;
    @synchronized (CallStateLock) {
        previousMedia = CurrentMedia;
        initializeStatus = AudioSessionInitializeStatus;
        categoryStatus = AudioSessionCategoryStatus;
        activeStatus = AudioSessionActiveStatus;
        routeSetStatus = AudioRouteStatus;
        muteStatus = MuteStatus;
        rewrittenFrom = RewrittenRemoteSDPFrom;
        rewrittenTo = RewrittenRemoteSDPTo;
        muted = CurrentMuted;
        speaker = CurrentSpeaker;
    }
    NSMutableDictionary *media = [@{
        @"status": @(info.media_status),
        @"direction": @(info.media_dir),
        @"conference_slot": @(info.conf_slot),
        @"sound_active": @(pjsua_snd_is_active()),
    } mutableCopy];
    if (!callToSoundStatus)
        callToSoundStatus = previousMedia[@"call_to_sound_status"];
    if (!soundToCallStatus)
        soundToCallStatus = previousMedia[@"sound_to_call_status"];
    if (callToSoundStatus)
        media[@"call_to_sound_status"] = callToSoundStatus;
    if (soundToCallStatus)
        media[@"sound_to_call_status"] = soundToCallStatus;
    if (initializeStatus)
        media[@"audio_session_initialize_status"] =
            initializeStatus;
    if (categoryStatus)
        media[@"audio_session_category_status"] =
            categoryStatus;
    if (activeStatus)
        media[@"audio_session_active_status"] =
            activeStatus;
    if (routeSetStatus)
        media[@"audio_route_status"] = routeSetStatus;
    if (muteStatus)
        media[@"mute_status"] = muteStatus;
    media[@"muted"] = @(muted);
    media[@"speaker"] = @(speaker);
    CFStringRef route = NULL;
    UInt32 routeSize = sizeof(route);
    OSStatus routeStatus = AudioSessionGetProperty(
        kAudioSessionProperty_AudioRoute, &routeSize, &route);
    media[@"audio_route_get_status"] = @(routeStatus);
    if (routeStatus == noErr && route) {
        media[@"audio_route"] = (__bridge NSString *)route;
        CFRelease(route);
    }

    int captureDevice;
    int playbackDevice;
    pj_status_t deviceStatus =
        pjsua_get_snd_dev(&captureDevice, &playbackDevice);
    media[@"sound_device_status"] = @(deviceStatus);
    if (deviceStatus == PJ_SUCCESS) {
        media[@"capture_device"] = @(captureDevice);
        media[@"playback_device"] = @(playbackDevice);
    }

    for (unsigned index = 0; index < info.media_cnt; ++index) {
        if (info.media[index].type != PJMEDIA_TYPE_AUDIO)
            continue;
        pjsua_stream_stat stat;
        pj_status_t statStatus =
            pjsua_call_get_stream_stat(callID, index, &stat);
        media[@"stream_index"] = @(index);
        media[@"stream_stat_status"] = @(statStatus);
        if (statStatus == PJ_SUCCESS) {
            media[@"tx_packets"] = @(stat.rtcp.tx.pkt);
            media[@"rx_packets"] = @(stat.rtcp.rx.pkt);
            media[@"rx_discard"] = @(stat.rtcp.rx.discard);
            media[@"rx_loss"] = @(stat.rtcp.rx.loss);
        }
        pjsua_stream_info streamInfo;
        pj_status_t streamInfoStatus =
            pjsua_call_get_stream_info(callID, index, &streamInfo);
        media[@"stream_info_status"] = @(streamInfoStatus);
        if (streamInfoStatus == PJ_SUCCESS &&
            streamInfo.type == PJMEDIA_TYPE_AUDIO)
            media[@"remote_rtp"] =
                AddressString(&streamInfo.info.aud.rem_addr);

        pjmedia_transport_info transportInfo;
        pj_status_t transportInfoStatus =
            pjsua_call_get_med_transport_info(
                callID, index, &transportInfo);
        media[@"transport_info_status"] = @(transportInfoStatus);
        if (transportInfoStatus == PJ_SUCCESS) {
            media[@"local_rtp"] =
                AddressString(&transportInfo.sock_info.rtp_addr_name);
            media[@"source_rtp"] =
                AddressString(&transportInfo.src_rtp_name);
        }
        if (rewrittenFrom.length) {
            media[@"remote_sdp_original"] =
                rewrittenFrom;
            media[@"remote_sdp_rewritten"] =
                rewrittenTo;
        }
        break;
    }
    return media;
}

static void RewriteConnection(pj_pool_t *pool, pjmedia_sdp_conn *connection)
{
    if (!connection ||
        pj_stricmp2(&connection->net_type, "IN") ||
        pj_stricmp2(&connection->addr_type, "IP4") ||
        pj_strcmp2(&connection->addr, MediaAddress) == 0)
        return;

    NSString *rewrittenFrom = [[NSString alloc]
        initWithBytes:connection->addr.ptr
               length:(NSUInteger)connection->addr.slen
             encoding:NSUTF8StringEncoding] ?: @"";
    NSString *rewrittenTo = @(MediaAddress);
    @synchronized (CallStateLock) {
        RewrittenRemoteSDPFrom = rewrittenFrom;
        RewrittenRemoteSDPTo = rewrittenTo;
    }
    pj_strdup2(pool, &connection->addr, MediaAddress);
}

static pj_bool_t RewriteRemoteSDP(pjsip_rx_data *data)
{
    if (!MediaAddress[0] ||
        strcmp(data->pkt_info.src_name, SignalingAddress) != 0)
        return PJ_FALSE;

    if (data->msg_info.cseq &&
        data->msg_info.cseq->method.id == PJSIP_INVITE_METHOD &&
        data->msg_info.msg->type == PJSIP_REQUEST_MSG) {
        @synchronized (CallStateLock) {
            if (CallID == PJSUA_INVALID_ID) {
                RewrittenRemoteSDPFrom = nil;
                RewrittenRemoteSDPTo = nil;
            }
        }
    }

    pjsip_rdata_sdp_info *info = pjsip_rdata_get_sdp_info(data);
    if (!info || !info->sdp)
        return PJ_FALSE;

    RewriteConnection(data->tp_info.pool, info->sdp->conn);
    for (unsigned index = 0; index < info->sdp->media_count; ++index)
        RewriteConnection(data->tp_info.pool,
                          info->sdp->media[index]->conn);
    return PJ_FALSE;
}

static BOOL ResolveIPv4(NSString *hostName, char *address, size_t size)
{
    struct hostent *host = gethostbyname(hostName.UTF8String);
    return host && host->h_addrtype == AF_INET &&
           host->h_length == sizeof(struct in_addr) &&
           host->h_addr_list[0] &&
           inet_ntop(AF_INET, host->h_addr_list[0], address, size);
}

static void SetDialogProxyRoute(pjsua_call_id callID)
{
    pjsua_call *call = &pjsua_var.calls[callID];
    if (ProxyRouteReady && call->inv &&
        pj_list_empty(&call->inv->dlg->route_set) &&
        pjsip_dlg_set_route_set(
            call->inv->dlg, &ProxyRouteSet) != PJ_SUCCESS)
        ProxyRouteReady = NO;
}

static BOOL CallMatchesSerialLocked(pjsua_call_id callID, unsigned serial)
{
    return (unsigned)(uintptr_t)pjsua_call_get_user_data(callID) == serial;
}

static void ConnectCallAudio(void *serialValue)
{
    @autoreleasepool {
    unsigned serial = (unsigned)(uintptr_t)serialValue;
    pjsua_call_id callID;
    BOOL muted;
    BOOL speaker;
    PJSUA_LOCK();
    @synchronized (CallStateLock) {
    if (AudioScheduledSerial == serial)
        AudioScheduledSerial = 0;
    if (serial != CurrentCallSerial ||
        CallID == PJSUA_INVALID_ID ||
        AudioConnectedSerial == CurrentCallSerial) {
        PJSUA_UNLOCK();
        return;
    }
    callID = CallID;
    muted = CurrentMuted;
    speaker = CurrentSpeaker;
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(callID, &info) != PJ_SUCCESS ||
        info.state != PJSIP_INV_STATE_CONFIRMED ||
        info.media_status != PJSUA_CALL_MEDIA_ACTIVE) {
        PJSUA_UNLOCK();
        return;
    }
    NSNumber *initializeStatus =
        @(AudioSessionInitialize(NULL, NULL, NULL, NULL));
    UInt32 category = kAudioSessionCategory_PlayAndRecord;
    NSNumber *categoryStatus = @(AudioSessionSetProperty(
        kAudioSessionProperty_AudioCategory,
        sizeof(category), &category));
    NSNumber *activeStatus = @(AudioSessionSetActive(true));
    UInt32 route = speaker ?
        kAudioSessionOverrideAudioRoute_Speaker :
        kAudioSessionOverrideAudioRoute_None;
    NSNumber *routeStatus = @(AudioSessionSetProperty(
        kAudioSessionProperty_OverrideAudioRoute,
        sizeof(route), &route));
    NSNumber *callToSoundStatus =
        @(pjsua_conf_connect(info.conf_slot, 0));
    NSNumber *soundToCallStatus = muted ?
        @(pjsua_conf_disconnect(0, info.conf_slot)) :
        @(pjsua_conf_connect(0, info.conf_slot));
    @synchronized (CallStateLock) {
    if (serial != CurrentCallSerial || callID != CallID) {
        PJSUA_UNLOCK();
        return;
    }
    AudioSessionInitializeStatus = initializeStatus;
    AudioSessionCategoryStatus = categoryStatus;
    AudioSessionActiveStatus = activeStatus;
    AudioRouteStatus = routeStatus;
    if (callToSoundStatus.intValue == PJ_SUCCESS &&
        soundToCallStatus.intValue == PJ_SUCCESS &&
        activeStatus.intValue == noErr)
        AudioConnectedSerial = CurrentCallSerial;
    }
    PJSUA_UNLOCK();
    NSDictionary *media =
        MediaSnapshot(callID, callToSoundStatus, soundToCallStatus);
    NSString *remote = RemoteForCall(callID);
    @synchronized (CallStateLock) {
    if (serial != CurrentCallSerial || callID != CallID)
        return;
    CurrentMedia = media;
    PostStateWithStatus(
        @"connected", remote, nil, @"audio");
    }
    }
}

static void ScheduleAudioConnect(pjsua_call_id callID)
{
    unsigned serial = 0;
    @synchronized (CallStateLock) {
        if (CallID == callID &&
            AudioConnectedSerial != CurrentCallSerial &&
            AudioScheduledSerial != CurrentCallSerial) {
            serial = CurrentCallSerial;
            AudioScheduledSerial = serial;
        }
    }
    if (!serial)
        return;
    if (pjsua_schedule_timer2(
            ConnectCallAudio, (void *)(uintptr_t)serial,
            AudioConnectDelayMilliseconds) != PJ_SUCCESS) {
        @synchronized (CallStateLock) {
            if (AudioScheduledSerial == serial)
                AudioScheduledSerial = 0;
        }
    }
}

static void OnRegistrationState(pjsua_acc_id accountID)
{
    @autoreleasepool {
    pjsua_acc_info info;
    BOOL registered =
        pjsua_acc_get_info(accountID, &info) == PJ_SUCCESS &&
        info.status >= 200 && info.status < 300;
    @synchronized (CallStateLock) {
    Registered = registered;
    if (CallID == PJSUA_INVALID_ID && !CallStarting && !IdlePending)
        PostState(@"idle", @"");
    }
    }
}

static void OnIncomingCall(pjsua_acc_id accountID,
                           pjsua_call_id callID,
                           pjsip_rx_data *data)
{
    @autoreleasepool {
    BOOL busy;
    unsigned serial = 0;
    @synchronized (CallStateLock) {
    busy = ShouldExit || CallStarting || IdlePending ||
           CallID != PJSUA_INVALID_ID;
    if (!busy) {
    CallID = callID;
    serial = ++CurrentCallSerial;
    CurrentCallID = [NSUUID UUID].UUIDString;
    CurrentDirection = @"incoming";
    CurrentEndSource = nil;
    StartedAt = [NSDate date];
    ConnectedAt = nil;
    CurrentMedia = nil;
    AudioSessionInitializeStatus = nil;
    AudioSessionCategoryStatus = nil;
    AudioSessionActiveStatus = nil;
    AudioRouteStatus = nil;
    MuteStatus = nil;
    CurrentMuted = NO;
    CurrentSpeaker = NO;
    }
    }
    if (busy) {
        pjsua_call_answer(callID, PJSIP_SC_BUSY_HERE, NULL, NULL);
        return;
    }
    pjsua_call_set_user_data(callID, (void *)(uintptr_t)serial);
    SetDialogProxyRoute(callID);
    NSString *remote = RemoteForCall(callID);
    @synchronized (CallStateLock) {
    if (CallID != callID || CurrentCallSerial != serial)
        return;
    PostState(@"incoming", remote);
    }
    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL current;
            @synchronized (CallStateLock) {
                current = CallID == callID &&
                          CurrentCallSerial == serial;
            }
            if (!current)
                return;
            LaunchPhoneApplication();
        });
    }
}

static void OnCallState(pjsua_call_id callID, pjsip_event *event)
{
    @autoreleasepool {
    unsigned callbackSerial =
        (unsigned)(uintptr_t)pjsua_call_get_user_data(callID);
    unsigned callSerial;
    @synchronized (CallStateLock) {
    if (callID != CallID && CallStarting &&
        CallID == PJSUA_INVALID_ID &&
        callbackSerial == CurrentCallSerial &&
        [CurrentDirection isEqualToString:@"outgoing"])
        CallID = callID;
    if (callID != CallID)
        return;
    callSerial = CurrentCallSerial;
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(callID, &info) != PJ_SUCCESS)
        return;

    NSString *remote = RemoteForCall(callID);
    NSString *statusText = [[NSString alloc]
        initWithBytes:info.last_status_text.ptr
               length:(NSUInteger)info.last_status_text.slen
             encoding:NSUTF8StringEncoding] ?: @"";
    NSNumber *status = info.last_status ? @(info.last_status) : nil;
    if (info.state == PJSIP_INV_STATE_CONNECTING)
        SetDialogProxyRoute(callID);
    NSDictionary *media = nil;
    if (info.state == PJSIP_INV_STATE_DISCONNECTED) {
        media = MediaSnapshot(callID, nil, nil);
        AudioSessionSetActive(false);
    }
    BOOL scheduleAudio = NO;
    BOOL scheduleIdle = NO;
    @synchronized (CallStateLock) {
    if (callID != CallID || callSerial != CurrentCallSerial)
        return;
    switch (info.state) {
    case PJSIP_INV_STATE_INCOMING:
        PostStateWithStatus(@"incoming", remote, status, statusText);
        break;
    case PJSIP_INV_STATE_CALLING:
    case PJSIP_INV_STATE_EARLY:
    case PJSIP_INV_STATE_CONNECTING:
        PostStateWithStatus(
            [CurrentDirection isEqualToString:@"incoming"] ?
                @"incoming" : @"calling",
            remote, status, statusText);
        break;
    case PJSIP_INV_STATE_CONFIRMED:
        if (!ConnectedAt)
            ConnectedAt = [NSDate date];
        PostStateWithStatus(@"connected", remote, status, statusText);
        scheduleAudio = YES;
        break;
    case PJSIP_INV_STATE_DISCONNECTED: {
        if (media)
            CurrentMedia = media;
        PostStateWithStatus(@"ended", remote, @(info.last_status),
                            statusText);
        IdlePending = YES;
        CurrentCallID = nil;
        CurrentDirection = nil;
        CurrentEndSource = nil;
        StartedAt = nil;
        ConnectedAt = nil;
        CallID = PJSUA_INVALID_ID;
        scheduleIdle = YES;
        break;
    }
    default:
        break;
    }
    }
    if (scheduleAudio)
        ScheduleAudioConnect(callID);
    if (scheduleIdle)
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @autoreleasepool {
                @synchronized (CallStateLock) {
                if (CallID == PJSUA_INVALID_ID &&
                    callSerial == CurrentCallSerial) {
                    CurrentMedia = nil;
                    IdlePending = NO;
                    PostState(@"idle", @"");
                }
                }
                }
            });
    }
}

static void OnCallMediaState(pjsua_call_id callID)
{
    @autoreleasepool {
    unsigned callbackSerial =
        (unsigned)(uintptr_t)pjsua_call_get_user_data(callID);
    unsigned callSerial;
    BOOL incoming;
    @synchronized (CallStateLock) {
    if (callID != CallID && CallStarting &&
        CallID == PJSUA_INVALID_ID &&
        callbackSerial == CurrentCallSerial &&
        [CurrentDirection isEqualToString:@"outgoing"])
        CallID = callID;
    if (callID != CallID)
        return;
    callSerial = CurrentCallSerial;
    incoming = [CurrentDirection isEqualToString:@"incoming"];
    }
    pjsua_call_info info;
    if (pjsua_call_get_info(callID, &info) != PJ_SUCCESS)
        return;
    NSString *state = nil;
    switch (info.state) {
    case PJSIP_INV_STATE_CONFIRMED:
        state = @"connected";
        break;
    case PJSIP_INV_STATE_INCOMING:
        state = @"incoming";
        break;
    case PJSIP_INV_STATE_CALLING:
    case PJSIP_INV_STATE_EARLY:
    case PJSIP_INV_STATE_CONNECTING:
        state = incoming ? @"incoming" : @"calling";
        break;
    default:
        return;
    }
    NSDictionary *media = MediaSnapshot(callID, nil, nil);
    NSString *remote = RemoteForCall(callID);
    BOOL scheduleAudio = NO;
    @synchronized (CallStateLock) {
    if (callID != CallID || callSerial != CurrentCallSerial)
        return;
    CurrentMedia = media;
    PostStateWithStatus(state, remote, nil, @"media");
    if (info.state == PJSIP_INV_STATE_CONFIRMED &&
        info.media_status == PJSUA_CALL_MEDIA_ACTIVE)
        scheduleAudio = YES;
    }
    if (scheduleAudio)
        ScheduleAudioConnect(callID);
    }
}

static BOOL ConfigIsValid(NSDictionary *config)
{
    id server = config[@"Server"];
    id username = config[@"Username"];
    id password = config[@"Password"];
    id mediaHost = config[@"MediaHost"];
    id portValue = config[@"Port"] ?: @5060;
    if (![server isKindOfClass:[NSString class]] ||
        ![username isKindOfClass:[NSString class]] ||
        ![password isKindOfClass:[NSString class]] ||
        (mediaHost && ![mediaHost isKindOfClass:[NSString class]]) ||
        ![portValue respondsToSelector:@selector(integerValue)])
        return NO;
    NSInteger port = [portValue integerValue];
    return [server length] && [username length] && [password length] &&
           port > 0 && port <= 65535;
}

static BOOL StartPJSIP(NSDictionary *config)
{
    NSString *server = config[@"Server"];
    NSString *username = config[@"Username"];
    NSString *password = config[@"Password"];
    id portValue = config[@"Port"] ?: @5060;
    if (!ConfigIsValid(config))
        return NO;

    if (pjsua_create() != PJ_SUCCESS)
        return NO;

    pjsua_config userConfig;
    pjsua_logging_config loggingConfig;
    pjsua_media_config mediaConfig;
    pjsua_config_default(&userConfig);
    pjsua_logging_config_default(&loggingConfig);
    pjsua_media_config_default(&mediaConfig);
    userConfig.cb.on_reg_state = OnRegistrationState;
    userConfig.cb.on_incoming_call = OnIncomingCall;
    userConfig.cb.on_call_state = OnCallState;
    userConfig.cb.on_call_media_state = OnCallMediaState;
    userConfig.thread_cnt = 1;
    loggingConfig.level = 3;
    loggingConfig.console_level = 3;
    mediaConfig.clock_rate = 8000;
    mediaConfig.snd_clock_rate = 8000;
    mediaConfig.no_vad = PJ_TRUE;

    if (pjsua_init(&userConfig, &loggingConfig, &mediaConfig) != PJ_SUCCESS)
        return NO;

    if (!ResolveIPv4(server, SignalingAddress,
                     sizeof(SignalingAddress)))
        return NO;
    NSString *mediaHost = config[@"MediaHost"];
    if (mediaHost.length) {
        if (!ResolveIPv4(mediaHost, MediaAddress,
                         sizeof(MediaAddress)))
            return NO;
        pj_bzero(&SDPRewriteModule, sizeof(SDPRewriteModule));
        SDPRewriteModule.name = pj_str("mod-iosip-sdp-rewrite");
        SDPRewriteModule.id = -1;
        SDPRewriteModule.priority = PJSIP_MOD_PRIORITY_TSX_LAYER - 1;
        SDPRewriteModule.on_rx_request = RewriteRemoteSDP;
        SDPRewriteModule.on_rx_response = RewriteRemoteSDP;
        if (pjsip_endpt_register_module(
                pjsua_get_pjsip_endpt(),
                &SDPRewriteModule) != PJ_SUCCESS)
            return NO;
    }

    pjsua_transport_config transportConfig;
    pjsua_transport_config_default(&transportConfig);
    transportConfig.port = 0;
    if (pjsua_transport_create(PJSIP_TRANSPORT_UDP,
                               &transportConfig, NULL) != PJ_SUCCESS)
        return NO;

    if (pjsua_start() != PJ_SUCCESS)
        return NO;

    NSString *registrar = [NSString stringWithFormat:@"sip:%@:%@",
                            server, portValue];
    NSString *identity = [NSString stringWithFormat:@"sip:%@@%@",
                           username, server];
    pjsua_acc_config accountConfig;
    pjsua_acc_config_default(&accountConfig);
    accountConfig.id = pj_str((char *)identity.UTF8String);
    accountConfig.reg_uri = pj_str((char *)registrar.UTF8String);
    accountConfig.reg_timeout = 300;
    accountConfig.ka_interval = 15;
    accountConfig.cred_count = 1;
    accountConfig.cred_info[0].realm = pj_str("*");
    accountConfig.cred_info[0].scheme = pj_str("digest");
    accountConfig.cred_info[0].username =
        pj_str((char *)username.UTF8String);
    accountConfig.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    accountConfig.cred_info[0].data = pj_str((char *)password.UTF8String);
    NSString *proxyHost = @(SignalingAddress);
    NSString *proxy = [NSString
        stringWithFormat:@"<sip:%@:%@;transport=udp;lr>",
                         proxyHost, portValue];
    pj_str_t routeName = pj_str("Route");
    pj_str_t routeValue = pj_str((char *)proxy.UTF8String);
    pj_str_t routeCopy;
    pj_strdup_with_null(pjsua_var.pool, &routeCopy, &routeValue);
    pjsip_route_hdr *route = (pjsip_route_hdr *)pjsip_parse_hdr(
        pjsua_var.pool, &routeName, routeCopy.ptr,
        routeCopy.slen, NULL);
    pj_list_init(&ProxyRouteSet);
    if (!route)
        return NO;
    pj_list_push_back(&ProxyRouteSet, route);
    ProxyRouteReady = YES;
    if (pjsua_acc_add(&accountConfig, PJ_TRUE, &AccountID) != PJ_SUCCESS)
        return NO;

    pj_str_t pcmu = pj_str("PCMU/8000");
    pj_str_t pcma = pj_str("PCMA/8000");
    pjsua_codec_set_priority(&pcmu, 255);
    pjsua_codec_set_priority(&pcma, 254);
    return YES;
}

static NSString *HandleCommand(NSString *command)
{
    if ([command isEqualToString:@"STATUS"]) {
        @synchronized (CallStateLock) {
            return Registered ? @"OK" : @"UNREGISTERED";
        }
    }

    if ([command isEqualToString:@"MEMORY"])
        return MemoryStatus();

    if ([command isEqualToString:@"RELOAD"]) {
        NSDictionary *config =
            [NSDictionary dictionaryWithContentsOfFile:ConfigPath];
        if (!ConfigIsValid(config))
            return @"INVALID";
        @synchronized (CallStateLock) {
            if (CallID != PJSUA_INVALID_ID ||
                CallStarting || IdlePending)
                return @"BUSY";
            ShouldExit = YES;
            return @"OK";
        }
    }

    if ([command isEqualToString:@"LAST_END"]) {
        @synchronized (StatePath) {
            if (!LastEnd)
                return @"NONE";
            return [NSString stringWithFormat:@"%@ %@",
                    LastEnd[@"status"], LastEnd[@"reason"]];
        }
    }

    if ([command isEqualToString:@"MEDIA"]) {
        pjsua_call_id callID;
        unsigned callSerial;
        @synchronized (CallStateLock) {
            callID = CallID;
            callSerial = CurrentCallSerial;
        }
        if (callID == PJSUA_INVALID_ID)
            return @"NO_CALL";
        NSDictionary *media = MediaSnapshot(callID, nil, nil);
        @synchronized (CallStateLock) {
        if (callID != CallID || callSerial != CurrentCallSerial)
            return @"NO_CALL";
        if (media)
            CurrentMedia = media;
        return [NSString stringWithFormat:
            @"status=%@ direction=%@ slot=%@ sound=%@ "
             @"call_to_sound=%@ sound_to_call=%@ tx=%@ rx=%@ "
             @"local=%@ remote=%@ source=%@",
            CurrentMedia[@"status"], CurrentMedia[@"direction"],
            CurrentMedia[@"conference_slot"], CurrentMedia[@"sound_active"],
            CurrentMedia[@"call_to_sound_status"],
            CurrentMedia[@"sound_to_call_status"],
            CurrentMedia[@"tx_packets"], CurrentMedia[@"rx_packets"],
            CurrentMedia[@"local_rtp"], CurrentMedia[@"remote_rtp"],
            CurrentMedia[@"source_rtp"]];
        }
    }

    if ([command hasPrefix:@"HISTORY_DELETE "]) {
        NSString *callID = [command substringFromIndex:15];
        if (!callID.length)
            return @"INVALID";
        @synchronized (StatePath) {
        NSMutableArray *history = [[NSArray
            arrayWithContentsOfFile:HistoryPath] mutableCopy] ?:
            [NSMutableArray array];
        for (NSInteger index = history.count - 1; index >= 0;
             --index) {
            if ([history[index][@"call_id"] isEqualToString:callID])
                [history removeObjectAtIndex:index];
        }
        if (![history writeToFile:HistoryPath atomically:YES])
            return @"ERROR";
        chmod(HistoryPath.fileSystemRepresentation, 0644);
        PostHistoryNotification();
        return @"OK";
        }
    }

    if ([command isEqualToString:@"HISTORY_MARK_ALL_READ"]) {
        @synchronized (StatePath) {
        NSMutableArray *history = [[NSArray
            arrayWithContentsOfFile:HistoryPath] mutableCopy] ?:
            [NSMutableArray array];
        NSDictionary *markedLastEnd = nil;
        BOOL changed = NO;
        for (NSUInteger index = 0; index < history.count; ++index) {
            NSDictionary *record = history[index];
            if (![record[@"read"] boolValue]) {
                NSMutableDictionary *updated = [record mutableCopy];
                updated[@"read"] = @YES;
                history[index] = updated;
                if ([LastEnd[@"call_id"]
                        isEqualToString:updated[@"call_id"]])
                    markedLastEnd = updated;
                changed = YES;
            }
        }
        if (!changed)
            return @"OK";
        if (![history writeToFile:HistoryPath atomically:YES])
            return @"ERROR";
        chmod(HistoryPath.fileSystemRepresentation, 0644);
        if (markedLastEnd) {
            NSMutableDictionary *state = [[NSDictionary
                dictionaryWithContentsOfFile:StatePath] mutableCopy];
            if (!state)
                return @"ERROR";
            state[@"last_end"] = markedLastEnd;
            if (![state writeToFile:StatePath atomically:YES])
                return @"ERROR";
            chmod(StatePath.fileSystemRepresentation, 0644);
            LastEnd = [markedLastEnd copy];
        }
        PostHistoryNotification();
        return @"OK";
        }
    }

    if ([command isEqualToString:@"HISTORY_CLEAR"]) {
        @synchronized (StatePath) {
        if (![@[] writeToFile:HistoryPath atomically:YES])
            return @"ERROR";
        chmod(HistoryPath.fileSystemRepresentation, 0644);
        PostHistoryNotification();
        return @"OK";
        }
    }

    if ([command hasPrefix:@"CALL "]) {
        NSString *number = [command substringFromIndex:5];
        const char *digits = number.UTF8String;
        BOOL valid = number.length > 0;
        for (const char *cursor = digits; valid && *cursor; ++cursor)
            valid = strchr("+0123456789*#", *cursor) != NULL;
        if (!valid)
            return @"INVALID";

        NSDictionary *config =
            [NSDictionary dictionaryWithContentsOfFile:ConfigPath];
        if (!ConfigIsValid(config))
            return @"INVALID";
        NSString *server = config[@"Server"];
        NSString *destination = [NSString
            stringWithFormat:@"sip:%@@%@:%@", number, server,
                             config[@"Port"] ?: @5060];
        pj_str_t uri = pj_str((char *)destination.UTF8String);
        unsigned callSerial;
        @synchronized (CallStateLock) {
        if (!Registered)
            return @"UNREGISTERED";
        if (ShouldExit || CallStarting || IdlePending ||
            CallID != PJSUA_INVALID_ID)
            return @"BUSY";
        CurrentCallID = [NSUUID UUID].UUIDString;
        callSerial = ++CurrentCallSerial;
        CallStarting = YES;
        CurrentDirection = @"outgoing";
        CurrentEndSource = nil;
        StartedAt = [NSDate date];
        ConnectedAt = nil;
        CurrentMedia = nil;
        AudioSessionInitializeStatus = nil;
        AudioSessionCategoryStatus = nil;
        AudioSessionActiveStatus = nil;
        AudioRouteStatus = nil;
        MuteStatus = nil;
        CurrentMuted = NO;
        CurrentSpeaker = NO;
        RewrittenRemoteSDPFrom = nil;
        RewrittenRemoteSDPTo = nil;
        }
        pjsua_call_id callID = PJSUA_INVALID_ID;
        pj_status_t status = pjsua_call_make_call(
            AccountID, &uri, 0, (void *)(uintptr_t)callSerial,
            NULL, &callID);
        @synchronized (CallStateLock) {
        if (callSerial != CurrentCallSerial)
            return status == PJ_SUCCESS ? @"OK" : @"ERROR";
        CallStarting = NO;
        if (status != PJ_SUCCESS) {
            if (CallID == callID)
                CallID = PJSUA_INVALID_ID;
            CurrentCallID = nil;
            CurrentDirection = nil;
            StartedAt = nil;
            return @"ERROR";
        }
        if ([CurrentDirection isEqualToString:@"outgoing"] &&
            CallID == PJSUA_INVALID_ID)
            CallID = callID;
        if (CallID == callID)
            PostState(@"calling", number);
        return @"OK";
        }
    }

    if ([command isEqualToString:@"ANSWER"]) {
        pjsua_call_id callID;
        unsigned callSerial;
        @synchronized (CallStateLock) {
            callID = CallID;
            callSerial = CurrentCallSerial;
        }
        if (callID == PJSUA_INVALID_ID)
            return @"NO_CALL";
        PJSUA_LOCK();
        BOOL validCall = CallMatchesSerialLocked(callID, callSerial);
        PJSUA_UNLOCK();
        pj_status_t status = validCall ?
            pjsua_call_answer(callID, 200, NULL, NULL) : PJ_EINVALIDOP;
        return status == PJ_SUCCESS ? @"OK" : @"ERROR";
    }

    if ([command hasPrefix:@"MUTE "]) {
        NSString *value = [command substringFromIndex:5];
        if (![value isEqualToString:@"0"] &&
            ![value isEqualToString:@"1"])
            return @"INVALID";
        BOOL muted = [value isEqualToString:@"1"];
        BOOL oldMuted;
        pjsua_call_id callID;
        unsigned callSerial;
        @synchronized (CallStateLock) {
            callID = CallID;
            callSerial = CurrentCallSerial;
            oldMuted = CurrentMuted;
        }
        if (callID == PJSUA_INVALID_ID)
            return @"NO_CALL";
        pjsua_call_info info;
        PJSUA_LOCK();
        pj_status_t status =
            CallMatchesSerialLocked(callID, callSerial) &&
            pjsua_call_get_info(callID, &info) == PJ_SUCCESS &&
            info.state == PJSIP_INV_STATE_CONFIRMED ?
                PJ_SUCCESS : PJ_EINVALIDOP;
        if (status == PJ_SUCCESS) {
            @synchronized (CallStateLock) {
                if (callID == CallID &&
                    callSerial == CurrentCallSerial)
                    CurrentMuted = muted;
                else
                    status = PJ_EINVALIDOP;
            }
        }
        if (status == PJ_SUCCESS)
            status = muted ?
                pjsua_conf_disconnect(0, info.conf_slot) :
                pjsua_conf_connect(0, info.conf_slot);
        PJSUA_UNLOCK();
        if (status != PJ_SUCCESS) {
            @synchronized (CallStateLock) {
                if (callID == CallID &&
                    callSerial == CurrentCallSerial &&
                    CurrentMuted == muted)
                    CurrentMuted = oldMuted;
            }
            return @"ERROR";
        }
        NSDictionary *media = MediaSnapshot(callID, nil, nil);
        NSString *remote = RemoteForCall(callID);
        @synchronized (CallStateLock) {
        if (callID != CallID || callSerial != CurrentCallSerial)
            return @"ERROR";
        MuteStatus = @(status);
        if (media)
            CurrentMedia = media;
        PostStateWithStatus(
            @"connected", remote, nil, @"mute");
        return status == PJ_SUCCESS ? @"OK" : @"ERROR";
        }
    }

    if ([command hasPrefix:@"ROUTE "]) {
        NSString *value = [command substringFromIndex:6];
        if (![value isEqualToString:@"SPEAKER"] &&
            ![value isEqualToString:@"HANDSET"])
            return @"INVALID";
        BOOL speaker = [value isEqualToString:@"SPEAKER"];
        BOOL oldSpeaker;
        pjsua_call_id callID;
        unsigned callSerial;
        @synchronized (CallStateLock) {
            callID = CallID;
            callSerial = CurrentCallSerial;
            oldSpeaker = CurrentSpeaker;
        }
        if (callID == PJSUA_INVALID_ID)
            return @"NO_CALL";
        pjsua_call_info info;
        PJSUA_LOCK();
        BOOL validCall =
            CallMatchesSerialLocked(callID, callSerial) &&
            pjsua_call_get_info(callID, &info) == PJ_SUCCESS &&
            info.state == PJSIP_INV_STATE_CONFIRMED;
        if (validCall) {
            @synchronized (CallStateLock) {
                validCall = callID == CallID &&
                            callSerial == CurrentCallSerial;
                if (validCall)
                    CurrentSpeaker = speaker;
            }
        }
        UInt32 route = speaker ?
            kAudioSessionOverrideAudioRoute_Speaker :
            kAudioSessionOverrideAudioRoute_None;
        OSStatus status = validCall ? AudioSessionSetProperty(
            kAudioSessionProperty_OverrideAudioRoute, sizeof(route),
            &route) : (OSStatus)-50;
        PJSUA_UNLOCK();
        if (!validCall || status != noErr) {
            @synchronized (CallStateLock) {
                if (callID == CallID &&
                    callSerial == CurrentCallSerial &&
                    CurrentSpeaker == speaker)
                    CurrentSpeaker = oldSpeaker;
            }
            return @"ERROR";
        }
        NSDictionary *media = MediaSnapshot(callID, nil, nil);
        NSString *remote = RemoteForCall(callID);
        @synchronized (CallStateLock) {
        if (callID != CallID || callSerial != CurrentCallSerial)
            return @"ERROR";
        AudioRouteStatus = @(status);
        if (media)
            CurrentMedia = media;
        PostStateWithStatus(
            @"connected", remote, nil, @"route");
        return status == noErr ? @"OK" : @"ERROR";
        }
    }

    if ([command hasPrefix:@"DTMF "]) {
        NSString *value = [command substringFromIndex:5];
        if (value.length != 1 ||
            [value rangeOfCharacterFromSet:
                [NSCharacterSet characterSetWithCharactersInString:
                    @"0123456789*#ABCD"]].location == NSNotFound)
            return @"INVALID";
        pjsua_call_id callID;
        unsigned callSerial;
        @synchronized (CallStateLock) {
            callID = CallID;
            callSerial = CurrentCallSerial;
        }
        if (callID == PJSUA_INVALID_ID)
            return @"NO_CALL";
        pj_str_t digits = pj_str((char *)value.UTF8String);
        PJSUA_LOCK();
        BOOL validCall = CallMatchesSerialLocked(callID, callSerial);
        PJSUA_UNLOCK();
        pj_status_t status = validCall ?
            pjsua_call_dial_dtmf(callID, &digits) : PJ_EINVALIDOP;
        return status == PJ_SUCCESS ? @"OK" : @"ERROR";
    }

    if ([command isEqualToString:@"HANGUP"] ||
        [command hasPrefix:@"HANGUP "]) {
        pjsua_call_id callID;
        unsigned callSerial;
        NSString *oldEndSource;
        @synchronized (CallStateLock) {
            callID = CallID;
            callSerial = CurrentCallSerial;
            oldEndSource = CurrentEndSource;
        }
        if (callID == PJSUA_INVALID_ID)
            return @"NO_CALL";
        NSDictionary *media = MediaSnapshot(callID, nil, nil);
        NSString *endSource = [command isEqualToString:@"HANGUP"] ?
            @"control" : [command substringFromIndex:7];
        PJSUA_LOCK();
        BOOL validCall = CallMatchesSerialLocked(callID, callSerial);
        if (validCall) {
            @synchronized (CallStateLock) {
                validCall = callID == CallID &&
                            callSerial == CurrentCallSerial;
                if (validCall) {
                    if (media)
                        CurrentMedia = media;
                    CurrentEndSource = endSource;
                }
            }
        }
        PJSUA_UNLOCK();
        pj_status_t status = validCall ?
            pjsua_call_hangup(callID, 0, NULL, NULL) : PJ_EINVALIDOP;
        if (status != PJ_SUCCESS) {
            @synchronized (CallStateLock) {
                if (callID == CallID &&
                    callSerial == CurrentCallSerial &&
                    [CurrentEndSource isEqualToString:endSource])
                    CurrentEndSource = oldEndSource;
            }
        }
        return status == PJ_SUCCESS ? @"OK" : @"ERROR";
    }
    return @"INVALID";
}

static void Serve(void)
{
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0)
        return;

    int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(IPCPort);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(server, 4) != 0) {
        close(server);
        return;
    }

    for (;;) {
        @autoreleasepool {
        struct sockaddr_in peer = {0};
        socklen_t peerLength = sizeof(peer);
        int client = accept(server, (struct sockaddr *)&peer, &peerLength);
        if (client < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (peer.sin_family != AF_INET ||
            peer.sin_addr.s_addr != htonl(INADDR_LOOPBACK) ||
            !ConfigureClientSocket(client)) {
            close(client);
            continue;
        }
        char buffer[512] = {0};
        ssize_t length = ReadCommand(client, buffer, sizeof(buffer));
        if (length >= 0) {
            NSString *request = [[[NSString alloc]
                initWithBytes:buffer
                       length:(NSUInteger)length
                     encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *prefix = [IPCToken stringByAppendingString:@" "];
            NSString *response = [request hasPrefix:prefix] ?
                HandleCommand([request substringFromIndex:prefix.length]) :
                @"UNAUTHORIZED";
            NSData *data = [[response stringByAppendingString:@"\n"]
                dataUsingEncoding:NSUTF8StringEncoding];
            WriteAll(client, data.bytes, data.length);
        }
        close(client);
        if (ShouldExit)
            break;
        }
    }
    close(server);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        RestoreStateMetadata();
        PostState(@"idle", @"");
        if (!LoadIPCToken())
            return 1;
        NSDictionary *config =
            [NSDictionary dictionaryWithContentsOfFile:ConfigPath];
        BOOL validConfig = ConfigIsValid(config);
        BOOL started = validConfig && StartPJSIP(config);
        if (validConfig && !started)
            return 1;
        Serve();
        if (started)
            pjsua_destroy();
    }
    return 0;
}
