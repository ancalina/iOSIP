#include <errno.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: iosipctl COMMAND [ARG]\n");
        return 2;
    }

    char command[256] = {0};
    for (int index = 1; index < argc; ++index) {
        if ((index > 1 &&
             strlcat(command, " ", sizeof(command)) >= sizeof(command)) ||
            strlcat(command, argv[index], sizeof(command)) >= sizeof(command)) {
            fprintf(stderr, "iosipctl: command too long\n");
            return 2;
        }
    }
    if (strlcat(command, "\n", sizeof(command)) >= sizeof(command)) {
        fprintf(stderr, "iosipctl: command too long\n");
        return 2;
    }

    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD < 0) {
        perror("iosipctl");
        return 1;
    }
    int enabled = 1;
    struct timeval timeout = {2, 0};
    if (setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                   sizeof(enabled)) != 0 ||
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   sizeof(timeout)) != 0 ||
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout)) != 0) {
        perror("iosipctl");
        close(socketFD);
        return 1;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/var/run/iosip.sock",
            sizeof(address.sun_path));
    if (connect(socketFD, (struct sockaddr *)&address, sizeof(address))) {
        perror("iosipctl");
        close(socketFD);
        return 1;
    }
    const char *cursor = command;
    size_t remaining = strlen(command);
    while (remaining) {
        ssize_t written = write(socketFD, cursor, remaining);
        if (written > 0) {
            cursor += written;
            remaining -= (size_t)written;
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        perror("iosipctl");
        close(socketFD);
        return 1;
    }

    char response[512] = {0};
    size_t responseLength = 0;
    int complete = 0;
    while (responseLength < sizeof(response) - 1) {
        ssize_t length =
            read(socketFD, response + responseLength,
                 sizeof(response) - 1 - responseLength);
        if (length > 0) {
            char *newline =
                memchr(response + responseLength, '\n', (size_t)length);
            responseLength += (size_t)length;
            if (newline) {
                responseLength = (size_t)(newline - response) + 1;
                complete = 1;
                break;
            }
            continue;
        }
        if (length == 0) {
            complete = 1;
            break;
        }
        if (errno == EINTR)
            continue;
        break;
    }
    close(socketFD);
    if (!complete || responseLength == 0)
        return 1;
    response[responseLength] = '\0';
    fputs(response, stdout);
    return 0;
}
