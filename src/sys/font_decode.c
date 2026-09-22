// Validate downloaded font bytes using the host font parser. A successful
// HTTP response or a WOFF2 signature alone is not proof of a loadable face.
#include <stddef.h>
#include <stdint.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

static CTLineRef lp_font_line(const uint8_t *text, size_t text_len,
    const uint8_t *family, size_t family_len, double size, int bold, int italic) {
  if (!text || !family || text_len > (size_t)INT32_MAX ||
      family_len > (size_t)INT32_MAX || size <= 0) return NULL;
  CFStringRef name = CFStringCreateWithBytes(kCFAllocatorDefault, family,
      (CFIndex)family_len, kCFStringEncodingUTF8, false);
  CFStringRef string = CFStringCreateWithBytes(kCFAllocatorDefault, text,
      (CFIndex)text_len, kCFStringEncodingUTF8, false);
  if (!name || !string) {
    if (name) CFRelease(name);
    if (string) CFRelease(string);
    return NULL;
  }
  CTFontRef font = CTFontCreateWithName(name, size, NULL);
  CFRelease(name);
  if (!font) { CFRelease(string); return NULL; }
  CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) |
      (italic ? kCTFontItalicTrait : 0);
  if (traits) {
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font, size, NULL,
        traits, traits);
    if (styled) { CFRelease(font); font = styled; }
  }
  int zero = 0;
  CFNumberRef kern = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
  if (!kern) { CFRelease(font); CFRelease(string); return NULL; }
  const void *keys[] = { kCTFontAttributeName, kCTKernAttributeName };
  const void *values[] = { font, kern };
  CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys,
      values, 2, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(font);
  CFRelease(kern);
  if (!attributes) { CFRelease(string); return NULL; }
  CFAttributedStringRef attributed = CFAttributedStringCreate(
      kCFAllocatorDefault, string, attributes);
  CFRelease(string);
  CFRelease(attributes);
  if (!attributed) return NULL;
  CTLineRef line = CTLineCreateWithAttributedString(attributed);
  CFRelease(attributed);
  return line;
}

double lp_font_measure_utf8(const uint8_t *text, size_t text_len,
    const uint8_t *family, size_t family_len, double size, int bold, int italic) {
  CTLineRef line = lp_font_line(text, text_len, family, family_len, size,
      bold, italic);
  if (!line) return -1;
  const double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  CFRelease(line);
  return width;
}

int lp_font_draw_utf8(uint8_t *pixels, size_t pixels_len,
    uint32_t width, uint32_t height, const uint8_t *text, size_t text_len,
    const uint8_t *family, size_t family_len, double size, int bold, int italic,
    double x, double y, double max_width,
    uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha) {
  if (!pixels || !width || !height || (uint64_t)width * height * 4 != pixels_len)
    return 0;
  CTLineRef line = lp_font_line(text, text_len, family, family_len, size,
      bold, italic);
  if (!line) return 0;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  if (!space) { CFRelease(line); return 0; }
  CGContextRef ctx = CGBitmapContextCreate(pixels, width, height, 8, (size_t)width * 4,
      space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (!ctx) { CFRelease(line); return 0; }
  CGContextSetRGBFillColor(ctx, red / 255.0, green / 255.0,
      blue / 255.0, alpha / 255.0);
  CGContextTranslateCTM(ctx, 0, height);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
  const double line_width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  if (max_width > 0 && line_width > max_width) {
    CGContextTranslateCTM(ctx, x, 0);
    CGContextScaleCTM(ctx, max_width / line_width, 1);
    x = 0;
  }
  CGContextSetTextPosition(ctx, x, y);
  CTLineDraw(line, ctx);
  CGContextRelease(ctx);
  CFRelease(line);
  return 1;
}

int lp_font_decode_valid(const uint8_t *data, size_t len) {
  if (!data || !len || len > (size_t)INT32_MAX) return 0;
  CFDataRef bytes = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, data,
      (CFIndex)len, kCFAllocatorNull);
  if (!bytes) return 0;
  CFArrayRef faces = CTFontManagerCreateFontDescriptorsFromData(bytes);
  CFRelease(bytes);
  if (!faces) return 0;
  const int valid = CFArrayGetCount(faces) > 0;
  CFRelease(faces);
  return valid;
}
#else
int lp_font_draw_utf8(uint8_t *pixels, size_t pixels_len,
    uint32_t width, uint32_t height, const uint8_t *text, size_t text_len,
    const uint8_t *family, size_t family_len, double size, int bold, int italic,
    double x, double y, double max_width,
    uint8_t red, uint8_t green, uint8_t blue, uint8_t alpha) {
  (void)pixels; (void)pixels_len; (void)width; (void)height;
  (void)text; (void)text_len; (void)family; (void)family_len;
  (void)size; (void)bold; (void)italic; (void)x; (void)y;
  (void)max_width; (void)red; (void)green; (void)blue; (void)alpha;
  return 0;
}

double lp_font_measure_utf8(const uint8_t *text, size_t text_len,
    const uint8_t *family, size_t family_len, double size, int bold, int italic) {
  (void)text; (void)text_len; (void)family; (void)family_len;
  (void)size; (void)bold; (void)italic;
  return -1;
}

int lp_font_decode_valid(const uint8_t *data, size_t len) {
  (void)data;
  (void)len;
  return 0;
}
#endif
