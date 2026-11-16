/* color_space.h — the colour space a Sender announces for its video.
 *
 * A Sender that labels its colour space puts "colorSpace" into the session
 * ack (TB_PKT_CREATE_SESSION_ACK): "srgb" or "displayP3". The Receiver then
 * tags its Metal layer accordingly, so macOS converts the picture for the
 * panel. Without the field (older Senders) the layer stays untagged, as
 * before: the values go to the panel unchanged. Pure C, no dependencies. */

#ifndef TB_COLOR_SPACE_H
#define TB_COLOR_SPACE_H

#include <stddef.h>
#include <string.h>

enum tb_color_space {
    TB_COLOR_SPACE_UNMANAGED  = 0, /* untagged: values go to the panel as they are */
    TB_COLOR_SPACE_SRGB       = 1,
    TB_COLOR_SPACE_DISPLAY_P3 = 2
};

/* Wire names, as in the Sender's TBVideoColorSpace. */
#define TB_COLOR_SPACE_NAME_SRGB       "srgb"
#define TB_COLOR_SPACE_NAME_DISPLAY_P3 "displayP3"

/* "srgb" / "displayP3" -> enum; anything else (or NULL) -> unmanaged. */
static inline int tb_color_space_from_name(const char *name) {
    if (!name) return TB_COLOR_SPACE_UNMANAGED;
    if (strcmp(name, TB_COLOR_SPACE_NAME_SRGB) == 0) return TB_COLOR_SPACE_SRGB;
    if (strcmp(name, TB_COLOR_SPACE_NAME_DISPLAY_P3) == 0) return TB_COLOR_SPACE_DISPLAY_P3;
    return TB_COLOR_SPACE_UNMANAGED;
}

/* For the stats overlay and the log. */
static inline const char *tb_color_space_title(int color_space) {
    switch (color_space) {
    case TB_COLOR_SPACE_SRGB:       return "sRGB";
    case TB_COLOR_SPACE_DISPLAY_P3: return "Display P3";
    default:                        return "unmanaged";
    }
}

/* The colour space this Receiver's panel shows best, for its display
 * profile ("panelColorSpace"). */
static inline const char *tb_color_space_panel_name(int supports_p3) {
    return supports_p3 ? TB_COLOR_SPACE_NAME_DISPLAY_P3 : TB_COLOR_SPACE_NAME_SRGB;
}

#endif
