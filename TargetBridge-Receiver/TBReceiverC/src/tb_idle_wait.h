/* tb_idle_wait.h — sleep while the Receiver waits for a Mac.
 *
 * The Receiver announces itself through Bonjour, which macOS's mDNSResponder
 * does on its behalf, and listens on a TCP port. Nothing in the process has
 * to run while it waits, so instead of polling every millisecond the main
 * loop sleeps here until one of these happens:
 *   - a Mac connects (the listening socket becomes readable),
 *   - a window, menu bar or keyboard event arrives,
 *   - the timeout passes (for the slow periodic checks).
 * Events are only peeked, never removed: SDL processes them as usual. */

#ifndef TB_IDLE_WAIT_H
#define TB_IDLE_WAIT_H

/* Wakes the wait when `listen_fd` becomes readable. Call once. */
void tb_idle_wait_watch_listen_socket(int listen_fd);

/* Sleeps up to `timeout_ms`; returns early on a connection or an event. */
void tb_idle_wait(int timeout_ms);

/* Low CPU and disk priority (macOS background band) while nothing streams;
 * normal priority for a session. */
void tb_idle_set_background_priority(int background);

#endif
