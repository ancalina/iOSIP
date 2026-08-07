#import <GraphicsServices/GraphicsServices.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    GSEventRecord record;
    GSHandInfo hand;
    GSPathInfo path;
} IOSIPTouchEvent;

#if __LP64__
_Static_assert(sizeof(GSEventRecord) == 80, "unexpected GSEventRecord");
_Static_assert(sizeof(GSHandInfo) == 40, "unexpected GSHandInfo");
_Static_assert(sizeof(GSPathInfo) == 48, "unexpected GSPathInfo");
_Static_assert(sizeof(IOSIPTouchEvent) == 168, "unexpected touch event");
#else
_Static_assert(sizeof(GSEventRecord) == 52, "unexpected GSEventRecord");
_Static_assert(sizeof(GSHandInfo) == 36, "unexpected GSHandInfo");
_Static_assert(sizeof(GSPathInfo) == 24, "unexpected GSPathInfo");
_Static_assert(sizeof(IOSIPTouchEvent) == 112, "unexpected touch event");
#endif

static void SendTouch(CGPoint point, GSHandInfoType type)
{
    IOSIPTouchEvent event;
    memset(&event, 0, sizeof(event));
    event.record.type = kGSEventHand;
    event.record.location = point;
    event.record.windowLocation = point;
    event.record.timestamp = GSCurrentEventTimestamp();
    event.record.flags = (GSEventFlags)kGSEventShouldRouteToFrontMost;
    event.record.infoSize = sizeof(event.hand) + sizeof(event.path);
    event.hand.type = type;
    event.hand.pathInfosCount = 1;
    event.path.pathIndex = 1;
    event.path.pathIdentity = 2;
    Boolean touching = type != kGSHandInfoTypeTouchUp;
    event.path.pathProximity = touching ? 3 : 0;
    event.path.pathPressure = touching ? 1.0f : 0.0f;
    event.path.pathMajorRadius = 1.0f;
    event.path.pathLocation = point;
    GSSendSystemEvent(&event.record);
}

int main(int argc, char **argv)
{
    if (!dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
                RTLD_LAZY | RTLD_GLOBAL))
        return 1;
    if (argc == 2) {
        GSSendSimpleEvent(
            (GSEventType)atoi(argv[1]), GSGetPurpleSystemEventPort());
        return 0;
    }
    if (argc != 3)
    {
        if (argc != 5)
            return 2;
        CGPoint start = CGPointMake(atof(argv[1]), atof(argv[2]));
        CGPoint end = CGPointMake(atof(argv[3]), atof(argv[4]));
        SendTouch(start, kGSHandInfoTypeTouchDown);
        for (int step = 1; step <= 10; ++step) {
            usleep(20000);
            CGPoint point = CGPointMake(
                start.x + (end.x - start.x) * step / 10.0f,
                start.y + (end.y - start.y) * step / 10.0f);
            SendTouch(point, kGSHandInfoTypeTouchDragged);
        }
        usleep(20000);
        SendTouch(end, kGSHandInfoTypeTouchUp);
        return 0;
    }
    CGPoint point = CGPointMake(atof(argv[1]), atof(argv[2]));
    SendTouch(point, kGSHandInfoTypeTouchDown);
    usleep(100000);
    SendTouch(point, kGSHandInfoTypeTouchUp);
    return 0;
}
