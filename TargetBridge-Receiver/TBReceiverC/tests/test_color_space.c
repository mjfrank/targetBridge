/* Tests for color_space.h: the colour space a Sender announces. */
#include "color_space.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    /* Wire names from the Sender. */
    CHECK(tb_color_space_from_name("srgb") == TB_COLOR_SPACE_SRGB);
    CHECK(tb_color_space_from_name("displayP3") == TB_COLOR_SPACE_DISPLAY_P3);

    /* Older Senders send nothing; unknown names never guess a colour space. */
    CHECK(tb_color_space_from_name(NULL) == TB_COLOR_SPACE_UNMANAGED);
    CHECK(tb_color_space_from_name("") == TB_COLOR_SPACE_UNMANAGED);
    CHECK(tb_color_space_from_name("SRGB") == TB_COLOR_SPACE_UNMANAGED);
    CHECK(tb_color_space_from_name("display-p3") == TB_COLOR_SPACE_UNMANAGED);
    CHECK(tb_color_space_from_name("rec2020") == TB_COLOR_SPACE_UNMANAGED);

    /* Overlay titles. */
    CHECK(strcmp(tb_color_space_title(TB_COLOR_SPACE_SRGB), "sRGB") == 0);
    CHECK(strcmp(tb_color_space_title(TB_COLOR_SPACE_DISPLAY_P3), "Display P3") == 0);
    CHECK(strcmp(tb_color_space_title(TB_COLOR_SPACE_UNMANAGED), "unmanaged") == 0);
    CHECK(strcmp(tb_color_space_title(42), "unmanaged") == 0);

    /* Panel name in the display profile round-trips through the parser. */
    CHECK(tb_color_space_from_name(tb_color_space_panel_name(1)) == TB_COLOR_SPACE_DISPLAY_P3);
    CHECK(tb_color_space_from_name(tb_color_space_panel_name(0)) == TB_COLOR_SPACE_SRGB);

    if (failures) {
        fprintf(stderr, "test_color_space: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_color_space: all %d checks passed\n", checks);
    return 0;
}
