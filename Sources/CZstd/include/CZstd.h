// The four Zstandard entry points pillr uses, and nothing else.
//
// `zstddeclib.c` beside this file is the official single-file *decoder*
// amalgamation, and it carries the whole of `zstd.h` inside itself rather than
// shipping it as a header — so there is no header to include. Declaring only
// what is called keeps the vendored surface to four functions instead of the
// 150 kB of public API the real `zstd.h` would add, and keeps the vendored `.c`
// pristine: it is never edited, so re-generating it is a straight overwrite.
//
// Copied verbatim from `lib/zstd.h` of the same pinned release — see README.md
// for the version and how to regenerate. The declarations are ABI-frozen (zstd
// has not changed any of these signatures since 1.0), which is the only reason
// hand-copying them is safe; if a future bump ever did change one, that is a
// deliberate act with the README's steps in front of you.
//
// `ZSTDLIB_API` is deliberately dropped. It only ever expands to a visibility
// attribute for shared-library builds, and this is compiled straight into the
// app binary.

#ifndef CZSTD_SHIM_H
#define CZSTD_SHIM_H

#include <stddef.h>

/// Decompresses exactly `compressedSize` bytes of frame into `dst`, returning
/// the decompressed size — or an error code, which is why every result goes
/// through `ZSTD_isError` first. Refuses to write past `dstCapacity`, which is
/// how the cap on decompressed output is enforced: too small is an error, never
/// an overrun.
size_t ZSTD_decompress(void *dst, size_t dstCapacity,
                       const void *src, size_t compressedSize);

/// How many bytes the first frame in `src` occupies, or an error when `src` does
/// not begin with a whole frame. Needed because a Simple Cache entry stores the
/// response body immediately followed by unrelated bytes (the header block), and
/// `ZSTD_decompress` rejects trailing data rather than stopping at the frame.
size_t ZSTD_findFrameCompressedSize(const void *src, size_t srcSize);

/// Whether a `size_t` result from either of the above is an error code.
unsigned ZSTD_isError(size_t result);

/// The decompressed size the frame header declares, or `ZSTD_CONTENTSIZE_*`.
/// Chunked responses declare nothing, so this is a cheap early reject for the
/// frames that do declare an oversized body — not the only guard.
unsigned long long ZSTD_getFrameContentSize(const void *src, size_t srcSize);

#define ZSTD_CONTENTSIZE_UNKNOWN (0ULL - 1)
#define ZSTD_CONTENTSIZE_ERROR   (0ULL - 2)

#endif /* CZSTD_SHIM_H */
