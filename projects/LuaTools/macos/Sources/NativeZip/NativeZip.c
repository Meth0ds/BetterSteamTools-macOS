#include "NativeZip.h"
#include <limits.h>
#include <string.h>
#include <zlib.h>

int luatools_zip_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size) {
    if (input_size > UINT_MAX || output_size > UINT_MAX || (!input && input_size) || (!output && output_size)) return -1;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_size;
    uint8_t dummy;
    stream.next_out = output_size ? output : &dummy;
    stream.avail_out = output_size ? (uInt)output_size : 1;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -1;
    int result = inflate(&stream, Z_FINISH);
    const int valid = result == Z_STREAM_END && stream.total_in == input_size && stream.total_out == output_size;
    inflateEnd(&stream);
    return valid ? 0 : -1;
}

uint32_t luatools_zip_crc32(const uint8_t *data, size_t size) {
    if (size > UINT_MAX || (!data && size)) return 0;
    return (uint32_t)crc32(0, data, (uInt)size);
}
