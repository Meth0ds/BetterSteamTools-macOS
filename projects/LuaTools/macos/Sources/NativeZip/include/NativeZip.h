#pragma once
#include <stddef.h>
#include <stdint.h>

// Inflate one raw ZIP deflate stream into an exactly sized buffer. Returns 0
// only when all compressed bytes were consumed and the output length matches.
int luatools_zip_inflate(const uint8_t *input, size_t input_size, uint8_t *output, size_t output_size);
uint32_t luatools_zip_crc32(const uint8_t *data, size_t size);
