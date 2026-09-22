// Local diagnostic, not part of the browser build. Run from the repo root:
// clang -std=c11 -O2 -framework CoreFoundation -framework CoreGraphics \
//   -framework CoreText tools/canvas_text_raster_probe.c -o /private/tmp/lp-raster-probe
// /private/tmp/lp-raster-probe
#include "../src/sys/font_decode.c"
#include <stdio.h>

static void run(int allows_smooth, int should_smooth, int subpixel,
    int quantize, int antialias) {
  uint8_t pixels[64 * 32 * 4] = {0};
  CTLineRef line = lp_font_line((const uint8_t *)"A", 1,
      (const uint8_t *)"Arial", 5, 20, 0, 0);
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(pixels, 64, 32, 8, 64 * 4, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (allows_smooth >= 0) CGContextSetAllowsFontSmoothing(ctx, allows_smooth);
  if (should_smooth >= 0) CGContextSetShouldSmoothFonts(ctx, should_smooth);
  if (subpixel >= 0) CGContextSetShouldSubpixelPositionFonts(ctx, subpixel);
  if (quantize >= 0) CGContextSetShouldSubpixelQuantizeFonts(ctx, quantize);
  if (antialias >= 0) CGContextSetShouldAntialias(ctx, antialias);
  CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
  CGContextTranslateCTM(ctx, 0, 32);
  CGContextScaleCTM(ctx, 1, -1);
  CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
  CGContextSetTextPosition(ctx, 2, 24);
  CTLineDraw(line, ctx);
  CGContextRelease(ctx);
  CFRelease(line);
  unsigned n = 0, sum = 0, hash = 2166136261u;
  for (size_t i = 0; i < sizeof(pixels); i++) {
    hash = (hash ^ pixels[i]) * 16777619u;
    sum += pixels[i];
    if (i % 4 == 3 && pixels[i]) n++;
  }
  printf("smooth=%d/%d subpixel=%d quant=%d aa=%d n=%u sum=%u hash=%u\n",
      allows_smooth, should_smooth, subpixel, quantize, antialias,
      n, sum, hash);
}

int main(void) {
  run(-1, -1, -1, -1, -1);
  for (int smooth = 0; smooth <= 1; smooth++)
    for (int subpixel = 0; subpixel <= 1; subpixel++)
      for (int quantize = 0; quantize <= 1; quantize++)
        run(smooth, smooth, subpixel, quantize, 1);
  run(-1, -1, -1, -1, 0);
  return 0;
}
