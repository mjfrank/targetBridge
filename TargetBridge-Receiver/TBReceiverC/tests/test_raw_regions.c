#include "raw_regions.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

#define CHECK(condition, message) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s\n", message); \
        failures++; \
    } \
} while (0)

/* Test stand-in for LZ4: the "compressed" data is the decoded data with every
 * byte inverted, so a forgotten decode step is caught. */
static int fake_decode(uint8_t *dst, size_t dst_len, const uint8_t *src, size_t src_len) {
    if (src_len != dst_len) return -1;
    for (size_t i = 0; i < dst_len; ++i) dst[i] = (uint8_t)~src[i];
    return 0;
}

struct writer {
    uint8_t buf[4096];
    size_t  len;
};

static void put8(struct writer *w, uint8_t v) { w->buf[w->len++] = v; }
static void put16(struct writer *w, uint16_t v) { put8(w, (uint8_t)(v >> 8)); put8(w, (uint8_t)v); }
static void put32(struct writer *w, uint32_t v) {
    put8(w, (uint8_t)(v >> 24)); put8(w, (uint8_t)(v >> 16));
    put8(w, (uint8_t)(v >> 8)); put8(w, (uint8_t)v);
}

static void header(struct writer *w, uint8_t flags, uint32_t width, uint32_t height, uint16_t count) {
    w->len = 0;
    put8(w, 1);
    put8(w, flags);
    put32(w, width);
    put32(w, height);
    put16(w, count);
    put16(w, 0);
}

static void band_entry(struct writer *w, uint32_t first, uint32_t rows, uint32_t length, uint8_t encoding) {
    put32(w, first);
    put32(w, rows);
    put32(w, length);
    put8(w, encoding);
}

static void band_data(struct writer *w, uint32_t width, uint32_t rows, uint8_t y, uint8_t uv, int invert) {
    for (uint32_t i = 0; i < width * rows; ++i) put8(w, invert ? (uint8_t)~y : y);
    for (uint32_t i = 0; i < width * (rows / 2); ++i) put8(w, invert ? (uint8_t)~uv : uv);
}

int main(void) {
    struct tb_raw_frame frame = {0};
    struct tb_raw_regions_result result;
    struct writer w;
    const uint32_t width = 8;
    const uint32_t height = 8;

    /* Full frame as two raw bands. */
    header(&w, TB_RAW_REGIONS_FLAG_FULL, width, height, 2);
    band_entry(&w, 0, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
    band_entry(&w, 4, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 4, 50, 60, 0);
    band_data(&w, width, 4, 70, 80, 0);
    memset(&result, 0, sizeof(result));
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, &result) == 0, "full frame applies");
    CHECK(result.full == 1 && result.bands == 2 && result.rows == 8, "full frame result");
    CHECK(result.first_row == 0 && result.end_row == 8, "full frame row span");
    CHECK(frame.w == 8 && frame.h == 8, "frame allocated");
    CHECK(((uintptr_t)frame.y % TB_RAW_REGIONS_Y_ALIGNMENT) == 0 &&
          frame.y_capacity % TB_RAW_REGIONS_Y_ALIGNMENT == 0 && frame.y_capacity >= 64 &&
          ((uintptr_t)frame.uv % TB_RAW_REGIONS_Y_ALIGNMENT) == 0 && frame.uv_capacity >= 32,
          "picture memory page aligned for the GPU");
    CHECK(frame.y[0] == 50 && frame.y[width * 4] == 70 && frame.y[width * 8 - 1] == 70, "Y rows patched");
    CHECK(frame.uv[0] == 60 && frame.uv[width * 2] == 80, "CbCr rows patched");

    /* Changed rows 2-3 only, LZ4-encoded. */
    header(&w, 0, width, height, 1);
    band_entry(&w, 2, 2, width * 2 + width, TB_RAW_REGIONS_ENCODING_LZ4);
    band_data(&w, width, 2, 99, 111, 1);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, &result) == 0, "partial LZ4 frame applies");
    CHECK(result.full == 0 && result.compressed == 1, "partial frame flags");
    CHECK(result.first_row == 2 && result.end_row == 4, "partial frame row span");
    CHECK(frame.y[width * 1] == 50 && frame.y[width * 2] == 99 && frame.y[width * 4] == 70,
          "only the changed Y rows change");
    CHECK(frame.uv[0] == 60 && frame.uv[width] == 111 && frame.uv[width * 2] == 80,
          "only the changed CbCr row changes");

    /* Malformed input changes nothing. */
    header(&w, 0, width, height, 1);
    band_entry(&w, 1, 2, width * 2 + width, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "odd first row rejected");

    header(&w, 0, width, height, 1);
    band_entry(&w, 6, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 4, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "band past the bottom rejected");

    header(&w, 0, width, height, 1);
    band_entry(&w, 0, 2, width * 3 + 1, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "wrong raw length rejected");

    header(&w, 0, width, height, 2);
    band_entry(&w, 0, 2, width * 3, TB_RAW_REGIONS_ENCODING_RAW);
    band_entry(&w, 2, 2, width * 3, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "truncated payload rejected");
    CHECK(frame.y[0] == 50, "rejected packet left the first band untouched");

    header(&w, 0, width, height, 1);
    band_entry(&w, 0, 2, width * 3, 7);
    band_data(&w, width, 2, 1, 1, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "unknown encoding rejected");

    header(&w, 0, width, height, 1);
    band_entry(&w, 0, 2, 4, TB_RAW_REGIONS_ENCODING_LZ4);
    put32(&w, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, NULL, NULL) == -1, "LZ4 without decoder rejected");
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -2, "undecodable LZ4 band reported");

    header(&w, 0, 7, height, 1);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "odd width rejected");

    header(&w, 0, width, height, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "zero bands rejected");

    /* Parts over parallel streams: a newer part wins even if it arrives first. */
    {
        struct writer part;
        /* Frame 7 writes rows 0-3 with 30. */
        part.len = 0;
        put32(&part, 7);
        size_t base = part.len;
        header(&w, 0, width, height, 1);
        memcpy(part.buf + base, w.buf, w.len); part.len = base + w.len;
        band_entry(&part, 0, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
        band_data(&part, width, 4, 30, 31, 0);
        CHECK(tb_raw_regions_apply_part(&frame, part.buf, part.len, fake_decode, &result) == 0,
              "part applies");
        CHECK(result.sequence == 7 && frame.y[0] == 30 && frame.y[width * 3] == 30, "part wrote rows 0-3");
        CHECK(result.parts == 0, "unknown part count reported as 0");

        /* An older frame 6 for rows 2-5 only fills rows 4-5. */
        part.len = 0;
        put32(&part, 6);
        base = part.len;
        memcpy(part.buf + base, w.buf, w.len); part.len = base + w.len;
        band_entry(&part, 2, 4, width * 4 + width * 2, TB_RAW_REGIONS_ENCODING_RAW);
        band_data(&part, width, 4, 66, 67, 0);
        CHECK(tb_raw_regions_apply_part(&frame, part.buf, part.len, fake_decode, NULL) == 0,
              "older part applies");
        CHECK(frame.y[width * 2] == 30 && frame.uv[width] == 31, "older part kept away from newer rows");
        CHECK(frame.y[width * 4] == 66 && frame.y[width * 5] == 66 && frame.uv[width * 2] == 67,
              "older part filled rows nobody newer wrote");

        /* The part count byte is reported. */
        part.buf[4 + 12] = 3;
        memset(&result, 0, sizeof(result));
        CHECK(tb_raw_regions_apply_part(&frame, part.buf, part.len, fake_decode, &result) == 0 &&
              result.parts == 3, "part count reported");

        /* Sequence 0 is invalid. */
        part.buf[0] = part.buf[1] = part.buf[2] = part.buf[3] = 0;
        CHECK(tb_raw_regions_apply_part(&frame, part.buf, part.len, fake_decode, NULL) == -1,
              "sequence 0 rejected");
        CHECK(tb_raw_regions_apply_part(&frame, part.buf, 3, fake_decode, NULL) == -1,
              "part without sequence rejected");
    }

    /* A size change reallocates and starts black outside the sent rows. */
    header(&w, 0, 4, 4, 1);
    band_entry(&w, 0, 2, 4 * 2 + 4, TB_RAW_REGIONS_ENCODING_RAW);
    band_data(&w, 4, 2, 200, 201, 0);
    CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == 0, "resized frame applies");
    CHECK(frame.w == 4 && frame.h == 4, "frame resized");
    CHECK(frame.y[0] == 200 && frame.y[4 * 2] == 16 && frame.uv[4] == 128, "unsent rows start black");

    /* 10-bit RGB: 4 bytes per pixel, one plane, starts opaque black. */
    {
        header(&w, 0, 4, 4, 1);
        w.buf[0] = TB_RAW_REGIONS_FORMAT_RGB10;
        band_entry(&w, 2, 2, 4 * 4 * 2, TB_RAW_REGIONS_ENCODING_RAW);
        for (int i = 0; i < 4 * 4 * 2; ++i) put8(&w, 0x5A);
        CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, &result) == 0, "RGB10 frame applies");
        CHECK(result.format == TB_RAW_REGIONS_FORMAT_RGB10 && frame.format == TB_RAW_REGIONS_FORMAT_RGB10,
              "RGB10 format reported");
        CHECK(frame.uv == NULL, "RGB10 has no CbCr plane");
        const uint32_t *pixels = (const uint32_t *)frame.y;
        CHECK(pixels[0] == 0xC0000000u && frame.y[4 * 4 * 2] == 0x5A && frame.y[4 * 4 * 4 - 1] == 0x5A,
              "RGB10 rows patched, others black");

        header(&w, 0, 4, 4, 1);
        w.buf[0] = TB_RAW_REGIONS_FORMAT_RGB10;
        band_entry(&w, 0, 2, 4 * 2 + 4, TB_RAW_REGIONS_ENCODING_RAW);
        band_data(&w, 4, 2, 1, 1, 0);
        CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1,
              "RGB10 band with NV12 length rejected");

        header(&w, 0, 4, 4, 1);
        w.buf[0] = 3;
        CHECK(tb_raw_regions_apply(&frame, w.buf, w.len, fake_decode, NULL) == -1, "unknown format rejected");
    }

    /* Scaled bands (latency setting): carried at half or quarter size and
     * enlarged into the frame. */
    {
        struct tb_raw_frame f = {0};
        struct tb_raw_regions_result result;
        struct writer w;

        /* NV12 8x8, rows 0..8 at half size: 4x4 Y, then 2 CbCr rows of 4 bytes. */
        header(&w, 0, 8, 8, 1);
        band_entry(&w, 0, 8, 4 * 4 + 4 * 2, TB_RAW_REGIONS_ENCODING_RAW | 0x10);
        for (int r = 0; r < 4; ++r)
            for (int x = 0; x < 4; ++x) put8(&w, (uint8_t)(10 * r + x));
        for (int r = 0; r < 2; ++r)
            for (int c = 0; c < 2; ++c) { put8(&w, (uint8_t)(100 + 10 * r + c)); put8(&w, (uint8_t)(200 + 10 * r + c)); }
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, &result) == 0, "half-size NV12 band applies");
        CHECK(result.scaled_rows == 8 && result.rows == 8, "scaled rows reported");
        CHECK(f.y[0] == 0 && f.y[1] == 0 && f.y[2] == 1 && f.y[7] == 3, "Y pixels doubled across");
        CHECK(f.y[8 * 1 + 2] == 1 && f.y[8 * 2 + 0] == 10 && f.y[8 * 7 + 7] == 33, "Y rows doubled down");
        CHECK(f.uv[0] == 100 && f.uv[1] == 200 && f.uv[2] == 100 && f.uv[4] == 101 && f.uv[5] == 201,
              "CbCr pairs doubled across");
        CHECK(f.uv[8 * 1 + 0] == 100 && f.uv[8 * 2 + 0] == 110 && f.uv[8 * 3 + 6] == 111,
              "CbCr rows doubled down");

        /* Quarter size, LZ4: 8x8 rows carried as 2x2 Y and one CbCr row of 2 bytes. */
        header(&w, 0, 8, 8, 1);
        band_entry(&w, 0, 8, 2 * 2 + 2, TB_RAW_REGIONS_ENCODING_LZ4 | 0x20);
        const uint8_t quarter[6] = { 1, 2, 3, 4, 50, 60 };
        for (int i = 0; i < 6; ++i) put8(&w, (uint8_t)~quarter[i]);
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, &result) == 0, "quarter-size LZ4 band applies");
        CHECK(f.y[0] == 1 && f.y[3] == 1 && f.y[4] == 2 && f.y[8 * 3 + 7] == 2 && f.y[8 * 4] == 3 && f.y[63] == 4,
              "quarter-size Y enlarged 4x");
        CHECK(f.uv[0] == 50 && f.uv[1] == 60 && f.uv[6] == 50 && f.uv[8 * 3 + 7] == 60, "quarter-size CbCr enlarged");

        /* Full-size rows replace the enlarged ones (the Sender's refinement). */
        header(&w, 0, 8, 8, 1);
        band_entry(&w, 0, 2, 8 * 2 + 8, TB_RAW_REGIONS_ENCODING_RAW);
        band_data(&w, 8, 2, 77, 88, 0);
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, NULL) == 0 && f.y[0] == 77 && f.y[15] == 77
              && f.y[16] == 1, "full-size rows refine a scaled band");

        /* Misaligned or unknown scales are rejected. */
        header(&w, 0, 8, 8, 1);
        band_entry(&w, 2, 4, 2 * 2 + 2, TB_RAW_REGIONS_ENCODING_RAW | 0x10);
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, NULL) == -1, "half-size band off a 4-row grid rejected");
        header(&w, 0, 12, 8, 1);
        band_entry(&w, 0, 8, 6 * 4 + 6 * 2, TB_RAW_REGIONS_ENCODING_RAW | 0x20);
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, NULL) == -1, "quarter size with width not divisible by 8 rejected");
        header(&w, 0, 8, 8, 1);
        band_entry(&w, 0, 8, 8, TB_RAW_REGIONS_ENCODING_RAW | 0x30);
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, NULL) == -1, "scale shift 3 rejected");

        /* RGB10 at half size. */
        header(&w, 0, 4, 4, 1);
        w.buf[0] = TB_RAW_REGIONS_FORMAT_RGB10;
        band_entry(&w, 0, 4, 2 * 2 * 4, TB_RAW_REGIONS_ENCODING_RAW | 0x10);
        const uint32_t px[4] = { 0xC0000001u, 0xC0000002u, 0xC0000003u, 0xC0000004u };
        for (int i = 0; i < 4; ++i) {
            put8(&w, (uint8_t)px[i]); put8(&w, (uint8_t)(px[i] >> 8));
            put8(&w, (uint8_t)(px[i] >> 16)); put8(&w, (uint8_t)(px[i] >> 24));
        }
        CHECK(tb_raw_regions_apply(&f, w.buf, w.len, fake_decode, NULL) == 0, "half-size RGB10 band applies");
        const uint32_t *p = (const uint32_t *)f.y;
        CHECK(p[0] == px[0] && p[1] == px[0] && p[2] == px[1] && p[4] == px[0] && p[8] == px[2] && p[15] == px[3],
              "RGB10 pixels enlarged");

        tb_raw_frame_free(&f);
        tb_raw_frame_free(&f);
    }

    tb_raw_frame_free(&frame);
    CHECK(frame.y == NULL && frame.uv == NULL && frame.w == 0, "frame freed");

    printf("raw regions: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
