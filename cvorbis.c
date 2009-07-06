#include <vorbis/codec.h>
#include <vorbis/vorbisfile.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "codec.h"
#include "cvorbis.h"

static FILE *file;
static OggVorbis_File vorbis_file;
static vorbis_info *vi;
static int cur_bit_stream;

int cvorbis_init (const char *fname) {
    file = NULL;
    vi = NULL;
    cur_bit_stream = -1;

    file = fopen (fname, "rb");
    if (!file) {
        return -1;
    }

    memset (&cvorbis.info, 0, sizeof (fileinfo_t));
    ov_open (file, &vorbis_file, NULL, 0);
    vi = ov_info (&vorbis_file, -1);
    cvorbis.info.bitsPerSample = 16;
    cvorbis.info.dataSize = ov_pcm_total (&vorbis_file, -1) * vi->channels * 2;
    cvorbis.info.channels = vi->channels;
    cvorbis.info.samplesPerSecond = vi->rate;
    cvorbis.info.duration = ov_seekable (&vorbis_file) ? ov_time_total (&vorbis_file, -1) : -1;
//    printf ("vorbis info: bps: %d, size: %d, chan: %d, rate: %d, dur: %f\n", cvorbis.info.bitsPerSample, cvorbis.info.dataSize, cvorbis.info.channels, cvorbis.info.samplesPerSecond, cvorbis.info.duration);
    return 0;
}

void
cvorbis_free (void) {
    if (file) {
        ov_clear (&vorbis_file);
        //fclose (file); -- ov_clear closes it
        file = NULL;
        vi = NULL;
    }
}

int
cvorbis_read (char *bytes, int size)
{
    if (!file)
        return -1;
    for (;;)
    {
        // read ogg
        long ret=ov_read (&vorbis_file, bytes, size, 0, 2, 1, &cur_bit_stream);
        if (ret < 0)
        {
            printf ("WARNING: ogg vorbis decoder tells error %x\n", ret);
            memset (bytes, 0, size);
            return -1;
        }
        else if (ret == 0) {
            if (size > 0) {
                memset (bytes, 0, size);
            }
            return -1;
        }
        else if (ret < size)
        {
            size -= ret;
            bytes += ret;
//            if (ret == 0) {
//                ov_raw_seek (&vorbis_file, 0);
//            }
        }
        else {
            break;
        }
    }
    return 0;
}

int
cvorbis_seek (float time) {
    if (!file) {
        return -1;
    }
//    printf ("seeking for %f\n");
    int res = ov_time_seek (&vorbis_file, time);
    if (res != 0 && res != OV_ENOSEEK)
        return -1;
//    printf ("seek result: %d\n", res);
    return 0;
}

codec_t cvorbis = {
    .init = cvorbis_init,
    .free = cvorbis_free,
    .read = cvorbis_read,
    .seek = cvorbis_seek
};

