#import "SIPIPC.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

static NSString *const IOSIPSocketPath = @"/var/run/iosip.sock";
static NSString *const IOSIPStatePath =
    @"/var/mobile/Library/IOSIP/state.plist";

NSString *IOSIPCommand(NSString *command)
{
    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD < 0)
        return nil;

    int enabled = 1;
    struct timeval timeout = {2, 0};
    if (setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                   sizeof(enabled)) != 0 ||
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   sizeof(timeout)) != 0 ||
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout)) != 0) {
        close(socketFD);
        return nil;
    }

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, IOSIPSocketPath.UTF8String,
            sizeof(address.sun_path));
    if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return nil;
    }

    NSData *request = [[command stringByAppendingString:@"\n"]
        dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *requestBytes = request.bytes;
    NSUInteger writtenLength = 0;
    while (writtenLength < request.length) {
        ssize_t written = write(socketFD, requestBytes + writtenLength,
                                request.length - writtenLength);
        if (written > 0) {
            writtenLength += (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        close(socketFD);
        return nil;
    }

    char response[512] = {0};
    NSUInteger responseLength = 0;
    BOOL complete = NO;
    while (responseLength < sizeof(response) - 1) {
        ssize_t length = read(socketFD, response + responseLength,
                              sizeof(response) - 1 - responseLength);
        if (length > 0) {
            char *newline = memchr(response + responseLength, '\n',
                                   (size_t)length);
            responseLength += (NSUInteger)length;
            if (newline) {
                responseLength = (NSUInteger)(newline - response) + 1;
                complete = YES;
                break;
            }
            continue;
        }
        if (length == 0) {
            complete = YES;
            break;
        }
        if (errno == EINTR)
            continue;
        close(socketFD);
        return nil;
    }
    close(socketFD);
    if (!complete || responseLength == 0)
        return nil;
    return [[[NSString alloc] initWithBytes:response
                                    length:responseLength
                                  encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSDictionary *IOSIPState(void)
{
    return [NSDictionary dictionaryWithContentsOfFile:IOSIPStatePath];
}
