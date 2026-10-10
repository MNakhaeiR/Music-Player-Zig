/* A narrow C surface over minimp3, so the Zig side never has to mirror
 * minimp3's struct layouts. Everything crossing the boundary is a primitive
 * type or an opaque byte buffer whose size the caller asks for.
 *
 * minimp3 itself is vendored unmodified; see LICENSE (CC0, public domain). */

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_NO_STDIO
#include "minimp3_ex.h"

#include <stddef.h>
#include <string.h>

/* Size and alignment of the decoder state, so Zig can allocate it. */
size_t zmp_mp3_state_size(void) { return sizeof(mp3dec_ex_t); }
size_t zmp_mp3_state_align(void) { return 16; }

/* Open a whole in-memory MP3. Builds a frame index, which is what makes
 * sample-accurate seeking and an exact duration possible.
 * Returns 0 on success. */
int zmp_mp3_open(void *state, const unsigned char *buf, size_t len)
{
    mp3dec_ex_t *dec = (mp3dec_ex_t *)state;
    memset(dec, 0, sizeof(*dec));
    return mp3dec_ex_open_buf(dec, buf, len, MP3D_SEEK_TO_SAMPLE);
}

void zmp_mp3_close(void *state)
{
    mp3dec_ex_close((mp3dec_ex_t *)state);
}

/* Report stream properties. `samples` is a total count of individual samples
 * (frames * channels), which is how minimp3 counts. */
void zmp_mp3_info(void *state,
                  int *rate,
                  int *channels,
                  unsigned long long *samples,
                  int *bitrate_kbps,
                  int *layer)
{
    mp3dec_ex_t *dec = (mp3dec_ex_t *)state;
    *rate = dec->info.hz;
    *channels = dec->info.channels;
    *samples = (unsigned long long)dec->samples;
    *bitrate_kbps = dec->info.bitrate_kbps;
    *layer = dec->info.layer;
}

/* Read up to `max_samples` interleaved int16 samples. Returns the count read,
 * 0 at end of stream. */
size_t zmp_mp3_read(void *state, short *out, size_t max_samples)
{
    return mp3dec_ex_read((mp3dec_ex_t *)state, out, max_samples);
}

/* Seek to an absolute sample offset (frames * channels). Returns 0 on success. */
int zmp_mp3_seek(void *state, unsigned long long sample)
{
    return mp3dec_ex_seek((mp3dec_ex_t *)state, (uint64_t)sample);
}
