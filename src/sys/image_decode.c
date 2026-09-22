// Decode image metadata through the host platform's image stack. The call
// forces the first frame to materialize instead of trusting an HTTP status or
// filename extension as proof that the bytes are an image.
#include <stddef.h>
#include <stdint.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>

int lp_image_decode_info(const uint8_t *data, size_t len,
                         uint32_t *width, uint32_t *height) {
  if (!data || !len || !width || !height) return 0;
  *width = *height = 0;
  CFDataRef bytes = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, data,
      (CFIndex)len, kCFAllocatorNull);
  if (!bytes) return 0;
  CGImageSourceRef source = CGImageSourceCreateWithData(bytes, NULL);
  CFRelease(bytes);
  if (!source) return 0;

  const void *keys[] = {kCGImageSourceShouldCacheImmediately};
  const void *values[] = {kCFBooleanTrue};
  CFDictionaryRef options = CFDictionaryCreate(kCFAllocatorDefault, keys,
      values, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, options);
  if (options) CFRelease(options);
  int ok = 0;
  if (image) {
    const size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w > 0 && h > 0 && w <= UINT32_MAX && h <= UINT32_MAX &&
        CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete) {
      *width = (uint32_t)w;
      *height = (uint32_t)h;
      ok = 1;
    }
    CGImageRelease(image);
  }
  CFRelease(source);
  return ok;
}
#else
int lp_image_decode_info(const uint8_t *data, size_t len,
                         uint32_t *width, uint32_t *height) {
  (void)data;
  (void)len;
  if (width) *width = 0;
  if (height) *height = 0;
  return 0;
}
#endif
