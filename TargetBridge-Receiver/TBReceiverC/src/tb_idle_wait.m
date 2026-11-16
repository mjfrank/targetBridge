/* tb_idle_wait.m — see tb_idle_wait.h. */

#import "tb_idle_wait.h"

#import <AppKit/AppKit.h>

#include <stdio.h>
#include <sys/resource.h>

static dispatch_source_t g_listen_source;
static int g_listen_watching = 0;   /* source resumed (only while waiting) */
static int g_wake_posted = 0;       /* at most one wake-up event per wait */

static void tb_idle_wait_post_wakeup(void) {
    if (g_wake_posted) return;
    g_wake_posted = 1;
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:NO];
}

void tb_idle_wait_watch_listen_socket(int listen_fd) {
    if (g_listen_source || listen_fd < 0) return;
    /* Runs on the main queue, i.e. inside the run loop of tb_idle_wait. It
     * starts suspended: while a session runs, further connection attempts
     * must not wake the loop over and over. */
    g_listen_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)listen_fd, 0,
                                             dispatch_get_main_queue());
    if (!g_listen_source) return;
    dispatch_source_set_event_handler(g_listen_source, ^{
        tb_idle_wait_post_wakeup();
    });
}

void tb_idle_wait(int timeout_ms) {
    if (timeout_ms <= 0) return;
    @autoreleasepool {
        g_wake_posted = 0;
        if (g_listen_source && !g_listen_watching) {
            dispatch_resume(g_listen_source);
            g_listen_watching = 1;
        }
        /* Returns as soon as any event is queued (also our wake-up), and runs
         * the main run loop meanwhile, so dispatch and Bonjour work happens. */
        (void)[NSApp nextEventMatchingMask:NSEventMaskAny
                                 untilDate:[NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0]
                                    inMode:NSDefaultRunLoopMode
                                   dequeue:NO];
        if (g_listen_source && g_listen_watching) {
            dispatch_suspend(g_listen_source);
            g_listen_watching = 0;
        }
    }
}

void tb_idle_set_background_priority(int background) {
    static int current = -1;
    background = background ? 1 : 0;
    if (current == background) return;
    current = background;
#ifdef PRIO_DARWIN_BG
    if (setpriority(PRIO_DARWIN_PROCESS, 0, background ? PRIO_DARWIN_BG : 0) != 0) {
        perror("[idle] setpriority");
        return;
    }
    fprintf(stderr, "[idle] %s priority\n", background ? "background" : "normal");
#endif
}
