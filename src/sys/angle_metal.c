// Optional local ANGLE/Metal backend. The browser does not ship Chrome's
// libraries: on macOS this loads the user's installed Chrome at runtime.
// On other platforms the entry points report unavailable.
#include <stddef.h>
#include <stdint.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// This is deliberately an exact known-host check, not a guess that every
// Apple-silicon Mac has the measured 14-inch M2 Pro Chrome profile.
static int chrome_version_matches(void) {
  CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
      CFSTR("/Applications/Google Chrome.app"), kCFURLPOSIXPathStyle, true);
  if (!url) return 0;
  CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url);
  CFRelease(url);
  if (!bundle) return 0;
  CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle,
      CFSTR("CFBundleShortVersionString"));
  const int matches = value && CFGetTypeID(value) == CFStringGetTypeID() &&
      CFStringCompare((CFStringRef)value, CFSTR("151.0.7922.138"), 0) == kCFCompareEqualTo;
  CFRelease(bundle);
  return matches;
}

int lp_host_is_m2pro_baseline(void) {
  char model[64] = {0}, chip[64] = {0}, os[64] = {0};
  size_t model_len = sizeof model, chip_len = sizeof chip, os_len = sizeof os;
  int cores = 0;
  uint64_t memory = 0;
  size_t cores_len = sizeof cores, memory_len = sizeof memory;
  if (sysctlbyname("hw.model", model, &model_len, NULL, 0) ||
      sysctlbyname("machdep.cpu.brand_string", chip, &chip_len, NULL, 0) ||
      sysctlbyname("kern.osproductversion", os, &os_len, NULL, 0) ||
      sysctlbyname("hw.logicalcpu", &cores, &cores_len, NULL, 0) ||
      sysctlbyname("hw.memsize", &memory, &memory_len, NULL, 0)) return 0;
  const CGRect display = CGDisplayBounds(CGMainDisplayID());
  return strcmp(model, "Mac14,9") == 0 && strcmp(chip, "Apple M2 Pro") == 0 &&
         strcmp(os, "14.8.1") == 0 && cores == 10 && memory == UINT64_C(17179869184) &&
         display.size.width == 1512 && display.size.height == 982 &&
         chrome_version_matches();
}

typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef intptr_t EGLAttrib;
typedef int32_t EGLint;
typedef unsigned int EGLenum;

enum {
  EGL_NONE = 0x3038,
  EGL_SURFACE_TYPE = 0x3033,
  EGL_PBUFFER_BIT = 1,
  EGL_RENDERABLE_TYPE = 0x3040,
  EGL_OPENGL_ES2_BIT = 4,
  EGL_OPENGL_ES3_BIT = 0x40,
  EGL_RED_SIZE = 0x3024,
  EGL_GREEN_SIZE = 0x3023,
  EGL_BLUE_SIZE = 0x3022,
  EGL_ALPHA_SIZE = 0x3021,
  EGL_WIDTH = 0x3057,
  EGL_HEIGHT = 0x3056,
  EGL_CONTEXT_CLIENT_VERSION = 0x3098,
  EGL_OPENGL_ES_API = 0x30A0,
  EGL_PLATFORM_ANGLE_ANGLE = 0x3202,
  EGL_PLATFORM_ANGLE_TYPE_ANGLE = 0x3203,
  EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE = 0x3489,
  GL_RGBA = 0x1908,
  GL_UNSIGNED_BYTE = 0x1401,
};

typedef struct {
  EGLDisplay (*eglGetPlatformDisplay)(EGLenum, void *, const EGLAttrib *);
  EGLint (*eglInitialize)(EGLDisplay, EGLint *, EGLint *);
  EGLint (*eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
  EGLSurface (*eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);
  EGLContext (*eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
  EGLint (*eglBindAPI)(EGLenum);
  EGLint (*eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
  EGLint (*eglDestroyContext)(EGLDisplay, EGLContext);
  EGLint (*eglDestroySurface)(EGLDisplay, EGLSurface);
  unsigned int (*glCreateShader)(unsigned int);
  void (*glShaderSource)(unsigned int, int, const char *const *, const int *);
  void (*glCompileShader)(unsigned int);
  void (*glGetShaderiv)(unsigned int, unsigned int, int *);
  void (*glGetShaderInfoLog)(unsigned int, int, int *, char *);
  unsigned int (*glCreateProgram)(void);
  void (*glAttachShader)(unsigned int, unsigned int);
  void (*glDetachShader)(unsigned int, unsigned int);
  void (*glLinkProgram)(unsigned int);
  void (*glValidateProgram)(unsigned int);
  void (*glGetProgramiv)(unsigned int, unsigned int, int *);
  void (*glGetProgramInfoLog)(unsigned int, int, int *, char *);
  void (*glGetActiveAttrib)(unsigned int, unsigned int, int, int *, int *, unsigned int *, char *);
  void (*glGetActiveUniform)(unsigned int, unsigned int, int, int *, int *, unsigned int *, char *);
  void (*glUseProgram)(unsigned int);
  unsigned char (*glIsProgram)(unsigned int);
  void (*glDeleteProgram)(unsigned int);
  unsigned char (*glIsShader)(unsigned int);
  void (*glDeleteShader)(unsigned int);
  int (*glGetUniformLocation)(unsigned int, const char *);
  void (*glUniform1f)(int, float);
  void (*glUniform2f)(int, float, float);
  void (*glUniform3f)(int, float, float, float);
  void (*glUniform4f)(int, float, float, float, float);
  void (*glUniform1i)(int, int);
  void (*glUniform2i)(int, int, int);
  void (*glUniform3i)(int, int, int, int);
  void (*glUniform4i)(int, int, int, int, int);
  void (*glGenBuffers)(int, unsigned int *);
  void (*glBindBuffer)(unsigned int, unsigned int);
  void (*glBufferData)(unsigned int, intptr_t, const void *, unsigned int);
  unsigned char (*glIsBuffer)(unsigned int);
  void (*glDeleteBuffers)(int, const unsigned int *);
  void (*glGenTextures)(int, unsigned int *);
  void (*glBindTexture)(unsigned int, unsigned int);
  unsigned char (*glIsTexture)(unsigned int);
  void (*glDeleteTextures)(int, const unsigned int *);
  void (*glActiveTexture)(unsigned int);
  void (*glTexParameteri)(unsigned int, unsigned int, int);
  void (*glTexParameterf)(unsigned int, unsigned int, float);
  void (*glGetTexParameteriv)(unsigned int, unsigned int, int *);
  void (*glTexImage2D)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void *);
  void (*glTexSubImage2D)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void *);
  void (*glPixelStorei)(unsigned int, int);
  void (*glGenFramebuffers)(int, unsigned int *);
  void (*glBindFramebuffer)(unsigned int, unsigned int);
  unsigned int (*glCheckFramebufferStatus)(unsigned int);
  void (*glFramebufferRenderbuffer)(unsigned int, unsigned int, unsigned int, unsigned int);
  void (*glFramebufferTexture2D)(unsigned int, unsigned int, unsigned int, unsigned int, int);
  unsigned char (*glIsFramebuffer)(unsigned int);
  void (*glDeleteFramebuffers)(int, const unsigned int *);
  void (*glGenRenderbuffers)(int, unsigned int *);
  void (*glBindRenderbuffer)(unsigned int, unsigned int);
  void (*glRenderbufferStorage)(unsigned int, unsigned int, int, int);
  void (*glGetRenderbufferParameteriv)(unsigned int, unsigned int, int *);
  unsigned char (*glIsRenderbuffer)(unsigned int);
  void (*glDeleteRenderbuffers)(int, const unsigned int *);
  int (*glGetAttribLocation)(unsigned int, const char *);
  void (*glEnableVertexAttribArray)(unsigned int);
  void (*glVertexAttribPointer)(unsigned int, int, unsigned int, unsigned char, int, const void *);
  void (*glViewport)(int, int, int, int);
  void (*glDrawArrays)(unsigned int, int, int);
  void (*glClearColor)(float, float, float, float);
  void (*glClear)(unsigned int);
  void (*glReadPixels)(int, int, int, int, unsigned int, unsigned int, void *);
  unsigned int (*glGetError)(void);
  void *egl_lib;
  void *gles_lib;
  EGLDisplay display;
  int available;
} AngleAPI;

typedef struct {
  EGLConfig config;
  EGLSurface surface;
  EGLContext context;
  uint32_t width;
  uint32_t height;
} AngleContext;

static AngleAPI api;
static pthread_once_t api_once = PTHREAD_ONCE_INIT;

#define LOAD(library, symbol) do { \
  *(void **)(&api.symbol) = dlsym(library, #symbol); \
  if (!api.symbol) return; \
} while (0)

static void initialize_api(void) {
  const char *directory = getenv("LIGHTPANDA_ANGLE_LIB_DIR");
  if (!directory || !*directory) directory = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/Current/Libraries";
  char egl_path[2048], gles_path[2048];
  const int egl_len = snprintf(egl_path, sizeof egl_path, "%s/libEGL.dylib", directory);
  const int gles_len = snprintf(gles_path, sizeof gles_path, "%s/libGLESv2.dylib", directory);
  if (egl_len < 0 || gles_len < 0 || (size_t)egl_len >= sizeof egl_path || (size_t)gles_len >= sizeof gles_path) return;
  api.egl_lib = dlopen(egl_path, RTLD_NOW | RTLD_LOCAL);
  if (!api.egl_lib) return;
  api.gles_lib = dlopen(gles_path, RTLD_NOW | RTLD_LOCAL);
  if (!api.gles_lib) return;
  LOAD(api.egl_lib, eglGetPlatformDisplay);
  LOAD(api.egl_lib, eglInitialize);
  LOAD(api.egl_lib, eglChooseConfig);
  LOAD(api.egl_lib, eglCreatePbufferSurface);
  LOAD(api.egl_lib, eglCreateContext);
  LOAD(api.egl_lib, eglBindAPI);
  LOAD(api.egl_lib, eglMakeCurrent);
  LOAD(api.egl_lib, eglDestroyContext);
  LOAD(api.egl_lib, eglDestroySurface);
  LOAD(api.gles_lib, glCreateShader);
  LOAD(api.gles_lib, glShaderSource);
  LOAD(api.gles_lib, glCompileShader);
  LOAD(api.gles_lib, glGetShaderiv);
  LOAD(api.gles_lib, glGetShaderInfoLog);
  LOAD(api.gles_lib, glCreateProgram);
  LOAD(api.gles_lib, glAttachShader);
  LOAD(api.gles_lib, glDetachShader);
  LOAD(api.gles_lib, glLinkProgram);
  LOAD(api.gles_lib, glValidateProgram);
  LOAD(api.gles_lib, glGetProgramiv);
  LOAD(api.gles_lib, glGetProgramInfoLog);
  LOAD(api.gles_lib, glGetActiveAttrib);
  LOAD(api.gles_lib, glGetActiveUniform);
  LOAD(api.gles_lib, glUseProgram);
  LOAD(api.gles_lib, glIsProgram);
  LOAD(api.gles_lib, glDeleteProgram);
  LOAD(api.gles_lib, glIsShader);
  LOAD(api.gles_lib, glDeleteShader);
  LOAD(api.gles_lib, glGetUniformLocation);
  LOAD(api.gles_lib, glUniform1f);
  LOAD(api.gles_lib, glUniform2f);
  LOAD(api.gles_lib, glUniform3f);
  LOAD(api.gles_lib, glUniform4f);
  LOAD(api.gles_lib, glUniform1i);
  LOAD(api.gles_lib, glUniform2i);
  LOAD(api.gles_lib, glUniform3i);
  LOAD(api.gles_lib, glUniform4i);
  LOAD(api.gles_lib, glGenBuffers);
  LOAD(api.gles_lib, glBindBuffer);
  LOAD(api.gles_lib, glBufferData);
  LOAD(api.gles_lib, glIsBuffer);
  LOAD(api.gles_lib, glDeleteBuffers);
  LOAD(api.gles_lib, glGenTextures);
  LOAD(api.gles_lib, glBindTexture);
  LOAD(api.gles_lib, glIsTexture);
  LOAD(api.gles_lib, glDeleteTextures);
  LOAD(api.gles_lib, glActiveTexture);
  LOAD(api.gles_lib, glTexParameteri);
  LOAD(api.gles_lib, glTexParameterf);
  LOAD(api.gles_lib, glGetTexParameteriv);
  LOAD(api.gles_lib, glTexImage2D);
  LOAD(api.gles_lib, glTexSubImage2D);
  LOAD(api.gles_lib, glPixelStorei);
  LOAD(api.gles_lib, glGenFramebuffers);
  LOAD(api.gles_lib, glBindFramebuffer);
  LOAD(api.gles_lib, glCheckFramebufferStatus);
  LOAD(api.gles_lib, glFramebufferRenderbuffer);
  LOAD(api.gles_lib, glFramebufferTexture2D);
  LOAD(api.gles_lib, glIsFramebuffer);
  LOAD(api.gles_lib, glDeleteFramebuffers);
  LOAD(api.gles_lib, glGenRenderbuffers);
  LOAD(api.gles_lib, glBindRenderbuffer);
  LOAD(api.gles_lib, glRenderbufferStorage);
  LOAD(api.gles_lib, glGetRenderbufferParameteriv);
  LOAD(api.gles_lib, glIsRenderbuffer);
  LOAD(api.gles_lib, glDeleteRenderbuffers);
  LOAD(api.gles_lib, glGetAttribLocation);
  LOAD(api.gles_lib, glEnableVertexAttribArray);
  LOAD(api.gles_lib, glVertexAttribPointer);
  LOAD(api.gles_lib, glViewport);
  LOAD(api.gles_lib, glDrawArrays);
  LOAD(api.gles_lib, glClearColor);
  LOAD(api.gles_lib, glClear);
  LOAD(api.gles_lib, glReadPixels);
  LOAD(api.gles_lib, glGetError);
  const EGLAttrib platform[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
  api.display = api.eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, platform);
  if (!api.display || !api.eglInitialize(api.display, NULL, NULL)) return;
  api.available = 1;
}

static int current(AngleContext *ctx) {
  return ctx && api.eglMakeCurrent(api.display, ctx->surface, ctx->surface, ctx->context);
}

static EGLSurface create_surface(AngleContext *ctx, uint32_t width, uint32_t height) {
  if (width == 0 || height == 0 || width > 16384 || height > 16384) return NULL;
  const EGLint surface_attrs[] = {EGL_WIDTH, (EGLint)width, EGL_HEIGHT, (EGLint)height, EGL_NONE};
  return api.eglCreatePbufferSurface(api.display, ctx->config, surface_attrs);
}

void *lp_angle_create(uint32_t width, uint32_t height, int webgl2) {
  pthread_once(&api_once, initialize_api);
  if (!api.available) return NULL;
  const EGLint config_attrs[] = {
    EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, webgl2 ? EGL_OPENGL_ES3_BIT : EGL_OPENGL_ES2_BIT,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE,
  };
  EGLConfig config = NULL;
  EGLint count = 0;
  if (!api.eglChooseConfig(api.display, config_attrs, &config, 1, &count) || count != 1) return NULL;
  AngleContext *ctx = calloc(1, sizeof *ctx);
  if (!ctx) return NULL;
  ctx->config = config;
  ctx->surface = create_surface(ctx, width, height);
  if (!ctx->surface) { free(ctx); return NULL; }
  if (!api.eglBindAPI(EGL_OPENGL_ES_API)) { api.eglDestroySurface(api.display, ctx->surface); free(ctx); return NULL; }
  const EGLint context_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, webgl2 ? 3 : 2, EGL_NONE};
  ctx->context = api.eglCreateContext(api.display, config, NULL, context_attrs);
  if (!ctx->context) { api.eglDestroySurface(api.display, ctx->surface); free(ctx); return NULL; }
  ctx->width = width;
  ctx->height = height;
  return ctx;
}

void lp_angle_destroy(void *handle) {
  AngleContext *ctx = handle;
  if (!ctx) return;
  api.eglMakeCurrent(api.display, NULL, NULL, NULL);
  api.eglDestroyContext(api.display, ctx->context);
  api.eglDestroySurface(api.display, ctx->surface);
  free(ctx);
}

int lp_angle_resize(void *handle, uint32_t width, uint32_t height) {
  AngleContext *ctx = handle;
  if (!ctx) return 0;
  if (ctx->width == width && ctx->height == height) return 1;
  EGLSurface replacement = create_surface(ctx, width, height);
  if (!replacement) return 0;
  api.eglMakeCurrent(api.display, NULL, NULL, NULL);
  api.eglDestroySurface(api.display, ctx->surface);
  ctx->surface = replacement;
  ctx->width = width;
  ctx->height = height;
  return current(ctx);
}

#define NEED_CONTEXT(ctx, result) if (!current((AngleContext *)(ctx))) return result
uint32_t lp_angle_create_shader(void *ctx, uint32_t type) { NEED_CONTEXT(ctx, 0); return api.glCreateShader(type); }
void lp_angle_shader_source(void *ctx, uint32_t shader, const char *text, int length) {
  NEED_CONTEXT(ctx, );
  api.glShaderSource(shader, 1, &text, &length);
}
void lp_angle_compile_shader(void *ctx, uint32_t shader) { NEED_CONTEXT(ctx, ); api.glCompileShader(shader); }
int lp_angle_shader_info_log(void *ctx, uint32_t shader, char *out, int capacity) {
  NEED_CONTEXT(ctx, 0);
  if (!out || capacity <= 0) return 0;
  int length = 0;
  api.glGetShaderInfoLog(shader, capacity, &length, out);
  return length;
}
int lp_angle_shader_parameter(void *ctx, uint32_t shader, uint32_t pname) {
  NEED_CONTEXT(ctx, 0);
  int value = 0;
  api.glGetShaderiv(shader, pname, &value);
  return value;
}
uint32_t lp_angle_create_program(void *ctx) { NEED_CONTEXT(ctx, 0); return api.glCreateProgram(); }
void lp_angle_attach_shader(void *ctx, uint32_t program, uint32_t shader) { NEED_CONTEXT(ctx, ); api.glAttachShader(program, shader); }
void lp_angle_detach_shader(void *ctx, uint32_t program, uint32_t shader) { NEED_CONTEXT(ctx, ); api.glDetachShader(program, shader); }
void lp_angle_link_program(void *ctx, uint32_t program) { NEED_CONTEXT(ctx, ); api.glLinkProgram(program); }
void lp_angle_validate_program(void *ctx, uint32_t program) { NEED_CONTEXT(ctx, ); api.glValidateProgram(program); }
int lp_angle_program_info_log(void *ctx, uint32_t program, char *out, int capacity) {
  NEED_CONTEXT(ctx, 0);
  if (!out || capacity <= 0) return 0;
  int length = 0;
  api.glGetProgramInfoLog(program, capacity, &length, out);
  return length;
}
int lp_angle_program_parameter(void *ctx, uint32_t program, uint32_t pname) {
  NEED_CONTEXT(ctx, 0);
  int value = 0;
  api.glGetProgramiv(program, pname, &value);
  return value;
}
int lp_angle_active_info(void *ctx, uint32_t program, uint32_t index, int uniform, char *name, int capacity, int *size, uint32_t *type) {
  NEED_CONTEXT(ctx, -1);
  if (!name || capacity < 2 || !size || !type) return -1;
  int length = 0;
  if (uniform) api.glGetActiveUniform(program, index, capacity, &length, size, type, name);
  else api.glGetActiveAttrib(program, index, capacity, &length, size, type, name);
  if (api.glGetError() != 0 || length < 0 || length >= capacity) return -1;
  name[length] = '\0';
  return length;
}
void lp_angle_use_program(void *ctx, uint32_t program) { NEED_CONTEXT(ctx, ); api.glUseProgram(program); }
int lp_angle_is_program(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, 0); return api.glIsProgram(id) != 0; }
void lp_angle_delete_program(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, ); api.glDeleteProgram(id); }
int lp_angle_is_shader(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, 0); return api.glIsShader(id) != 0; }
void lp_angle_delete_shader(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, ); api.glDeleteShader(id); }
int lp_angle_uniform_location(void *ctx, uint32_t program, const char *name) { NEED_CONTEXT(ctx, -1); return api.glGetUniformLocation(program, name); }
void lp_angle_uniform1f(void *ctx, int loc, float x) { NEED_CONTEXT(ctx, ); api.glUniform1f(loc, x); }
void lp_angle_uniform2f(void *ctx, int loc, float x, float y) { NEED_CONTEXT(ctx, ); api.glUniform2f(loc, x, y); }
void lp_angle_uniform3f(void *ctx, int loc, float x, float y, float z) { NEED_CONTEXT(ctx, ); api.glUniform3f(loc, x, y, z); }
void lp_angle_uniform4f(void *ctx, int loc, float x, float y, float z, float w) { NEED_CONTEXT(ctx, ); api.glUniform4f(loc, x, y, z, w); }
void lp_angle_uniform1i(void *ctx, int loc, int x) { NEED_CONTEXT(ctx, ); api.glUniform1i(loc, x); }
void lp_angle_uniform2i(void *ctx, int loc, int x, int y) { NEED_CONTEXT(ctx, ); api.glUniform2i(loc, x, y); }
void lp_angle_uniform3i(void *ctx, int loc, int x, int y, int z) { NEED_CONTEXT(ctx, ); api.glUniform3i(loc, x, y, z); }
void lp_angle_uniform4i(void *ctx, int loc, int x, int y, int z, int w) { NEED_CONTEXT(ctx, ); api.glUniform4i(loc, x, y, z, w); }
uint32_t lp_angle_create_buffer(void *ctx) {
  NEED_CONTEXT(ctx, 0);
  uint32_t buffer = 0;
  api.glGenBuffers(1, &buffer);
  return buffer;
}
void lp_angle_bind_buffer(void *ctx, uint32_t target, uint32_t buffer) { NEED_CONTEXT(ctx, ); api.glBindBuffer(target, buffer); }
int lp_angle_is_buffer(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, 0); return api.glIsBuffer(id) != 0; }
void lp_angle_delete_buffer(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, ); api.glDeleteBuffers(1, &id); }
uint32_t lp_angle_create_texture(void *ctx) { NEED_CONTEXT(ctx, 0); uint32_t id = 0; api.glGenTextures(1, &id); return id; }
void lp_angle_bind_texture(void *ctx, uint32_t target, uint32_t id) { NEED_CONTEXT(ctx, ); api.glBindTexture(target, id); }
int lp_angle_is_texture(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, 0); return api.glIsTexture(id) != 0; }
void lp_angle_delete_texture(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, ); api.glDeleteTextures(1, &id); }
void lp_angle_active_texture(void *ctx, uint32_t texture) { NEED_CONTEXT(ctx, ); api.glActiveTexture(texture); }
void lp_angle_tex_parameteri(void *ctx, uint32_t target, uint32_t pname, int value) { NEED_CONTEXT(ctx, ); api.glTexParameteri(target, pname, value); }
void lp_angle_tex_parameterf(void *ctx, uint32_t target, uint32_t pname, float value) { NEED_CONTEXT(ctx, ); api.glTexParameterf(target, pname, value); }
int lp_angle_get_tex_parameter(void *ctx, uint32_t target, uint32_t pname) { NEED_CONTEXT(ctx, 0); int value = 0; api.glGetTexParameteriv(target, pname, &value); return value; }
void lp_angle_tex_image2d(void *ctx, uint32_t target, int level, int internal_format, int width, int height, int border, uint32_t format, uint32_t pixel_type, const void *pixels) { NEED_CONTEXT(ctx, ); api.glTexImage2D(target, level, internal_format, width, height, border, format, pixel_type, pixels); }
void lp_angle_tex_sub_image2d(void *ctx, uint32_t target, int level, int x, int y, int width, int height, uint32_t format, uint32_t pixel_type, const void *pixels) { NEED_CONTEXT(ctx, ); api.glTexSubImage2D(target, level, x, y, width, height, format, pixel_type, pixels); }
void lp_angle_pixel_storei(void *ctx, uint32_t pname, int value) { NEED_CONTEXT(ctx, ); api.glPixelStorei(pname, value); }
uint32_t lp_angle_create_framebuffer(void *ctx) { NEED_CONTEXT(ctx, 0); uint32_t id = 0; api.glGenFramebuffers(1, &id); return id; }
void lp_angle_bind_framebuffer(void *ctx, uint32_t target, uint32_t id) { NEED_CONTEXT(ctx, ); api.glBindFramebuffer(target, id); }
uint32_t lp_angle_check_framebuffer_status(void *ctx, uint32_t target) { NEED_CONTEXT(ctx, 0); return api.glCheckFramebufferStatus(target); }
void lp_angle_framebuffer_renderbuffer(void *ctx, uint32_t target, uint32_t attachment, uint32_t renderbuffer_target, uint32_t id) { NEED_CONTEXT(ctx, ); api.glFramebufferRenderbuffer(target, attachment, renderbuffer_target, id); }
void lp_angle_framebuffer_texture2d(void *ctx, uint32_t target, uint32_t attachment, uint32_t texture_target, uint32_t id, int level) { NEED_CONTEXT(ctx, ); api.glFramebufferTexture2D(target, attachment, texture_target, id, level); }
int lp_angle_is_framebuffer(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, 0); return api.glIsFramebuffer(id) != 0; }
void lp_angle_delete_framebuffer(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, ); api.glDeleteFramebuffers(1, &id); }
uint32_t lp_angle_create_renderbuffer(void *ctx) { NEED_CONTEXT(ctx, 0); uint32_t id = 0; api.glGenRenderbuffers(1, &id); return id; }
void lp_angle_bind_renderbuffer(void *ctx, uint32_t target, uint32_t id) { NEED_CONTEXT(ctx, ); api.glBindRenderbuffer(target, id); }
void lp_angle_renderbuffer_storage(void *ctx, uint32_t target, uint32_t format, int width, int height) { NEED_CONTEXT(ctx, ); api.glRenderbufferStorage(target, format, width, height); }
int lp_angle_get_renderbuffer_parameter(void *ctx, uint32_t target, uint32_t pname) { NEED_CONTEXT(ctx, 0); int value = 0; api.glGetRenderbufferParameteriv(target, pname, &value); return value; }
int lp_angle_is_renderbuffer(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, 0); return api.glIsRenderbuffer(id) != 0; }
void lp_angle_delete_renderbuffer(void *ctx, uint32_t id) { NEED_CONTEXT(ctx, ); api.glDeleteRenderbuffers(1, &id); }
void lp_angle_buffer_data(void *ctx, uint32_t target, const void *data, size_t length, uint32_t usage) {
  NEED_CONTEXT(ctx, );
  api.glBufferData(target, (intptr_t)length, data, usage);
}
int lp_angle_attrib_location(void *ctx, uint32_t program, const char *name) { NEED_CONTEXT(ctx, -1); return api.glGetAttribLocation(program, name); }
void lp_angle_enable_vertex_attrib(void *ctx, uint32_t index) { NEED_CONTEXT(ctx, ); api.glEnableVertexAttribArray(index); }
void lp_angle_vertex_attrib_pointer(void *ctx, uint32_t index, int size, uint32_t type, int normalized, int stride, uintptr_t offset) {
  NEED_CONTEXT(ctx, );
  api.glVertexAttribPointer(index, size, type, normalized != 0, stride, (const void *)offset);
}
void lp_angle_viewport(void *ctx, int x, int y, int width, int height) { NEED_CONTEXT(ctx, ); api.glViewport(x, y, width, height); }
void lp_angle_draw_arrays(void *ctx, uint32_t mode, int first, int count) { NEED_CONTEXT(ctx, ); api.glDrawArrays(mode, first, count); }
void lp_angle_clear_color(void *ctx, float r, float g, float b, float a) { NEED_CONTEXT(ctx, ); api.glClearColor(r, g, b, a); }
void lp_angle_clear(void *ctx, uint32_t mask) { NEED_CONTEXT(ctx, ); api.glClear(mask); }
int lp_angle_read_pixels(void *ctx, int x, int y, int width, int height, void *out) {
  NEED_CONTEXT(ctx, 0);
  api.glReadPixels(x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, out);
  return api.glGetError() == 0;
}
uint32_t lp_angle_get_error(void *ctx) { NEED_CONTEXT(ctx, 0); return api.glGetError(); }

#else
int lp_host_is_m2pro_baseline(void) { return 0; }
void *lp_angle_create(uint32_t width, uint32_t height, int webgl2) { (void)width; (void)height; (void)webgl2; return NULL; }
void lp_angle_destroy(void *handle) { (void)handle; }
int lp_angle_resize(void *handle, uint32_t width, uint32_t height) { (void)handle; (void)width; (void)height; return 0; }
uint32_t lp_angle_create_shader(void *ctx, uint32_t type) { (void)ctx; (void)type; return 0; }
void lp_angle_shader_source(void *ctx, uint32_t shader, const char *text, int length) { (void)ctx; (void)shader; (void)text; (void)length; }
void lp_angle_compile_shader(void *ctx, uint32_t shader) { (void)ctx; (void)shader; }
int lp_angle_shader_info_log(void *ctx, uint32_t shader, char *out, int capacity) { (void)ctx; (void)shader; (void)out; (void)capacity; return 0; }
int lp_angle_shader_parameter(void *ctx, uint32_t shader, uint32_t pname) { (void)ctx; (void)shader; (void)pname; return 0; }
uint32_t lp_angle_create_program(void *ctx) { (void)ctx; return 0; }
void lp_angle_attach_shader(void *ctx, uint32_t program, uint32_t shader) { (void)ctx; (void)program; (void)shader; }
void lp_angle_detach_shader(void *ctx, uint32_t program, uint32_t shader) { (void)ctx; (void)program; (void)shader; }
void lp_angle_link_program(void *ctx, uint32_t program) { (void)ctx; (void)program; }
void lp_angle_validate_program(void *ctx, uint32_t program) { (void)ctx; (void)program; }
int lp_angle_program_info_log(void *ctx, uint32_t program, char *out, int capacity) { (void)ctx; (void)program; (void)out; (void)capacity; return 0; }
int lp_angle_program_parameter(void *ctx, uint32_t program, uint32_t pname) { (void)ctx; (void)program; (void)pname; return 0; }
int lp_angle_active_info(void *ctx, uint32_t program, uint32_t index, int uniform, char *name, int capacity, int *size, uint32_t *type) { (void)ctx; (void)program; (void)index; (void)uniform; (void)name; (void)capacity; (void)size; (void)type; return -1; }
void lp_angle_use_program(void *ctx, uint32_t program) { (void)ctx; (void)program; }
int lp_angle_is_program(void *ctx, uint32_t id) { (void)ctx; (void)id; return 0; }
void lp_angle_delete_program(void *ctx, uint32_t id) { (void)ctx; (void)id; }
int lp_angle_is_shader(void *ctx, uint32_t id) { (void)ctx; (void)id; return 0; }
void lp_angle_delete_shader(void *ctx, uint32_t id) { (void)ctx; (void)id; }
int lp_angle_uniform_location(void *ctx, uint32_t program, const char *name) { (void)ctx; (void)program; (void)name; return -1; }
void lp_angle_uniform1f(void *ctx, int loc, float x) { (void)ctx; (void)loc; (void)x; }
void lp_angle_uniform2f(void *ctx, int loc, float x, float y) { (void)ctx; (void)loc; (void)x; (void)y; }
void lp_angle_uniform3f(void *ctx, int loc, float x, float y, float z) { (void)ctx; (void)loc; (void)x; (void)y; (void)z; }
void lp_angle_uniform4f(void *ctx, int loc, float x, float y, float z, float w) { (void)ctx; (void)loc; (void)x; (void)y; (void)z; (void)w; }
void lp_angle_uniform1i(void *ctx, int loc, int x) { (void)ctx; (void)loc; (void)x; }
void lp_angle_uniform2i(void *ctx, int loc, int x, int y) { (void)ctx; (void)loc; (void)x; (void)y; }
void lp_angle_uniform3i(void *ctx, int loc, int x, int y, int z) { (void)ctx; (void)loc; (void)x; (void)y; (void)z; }
void lp_angle_uniform4i(void *ctx, int loc, int x, int y, int z, int w) { (void)ctx; (void)loc; (void)x; (void)y; (void)z; (void)w; }
uint32_t lp_angle_create_buffer(void *ctx) { (void)ctx; return 0; }
void lp_angle_bind_buffer(void *ctx, uint32_t target, uint32_t buffer) { (void)ctx; (void)target; (void)buffer; }
int lp_angle_is_buffer(void *ctx, uint32_t id) { (void)ctx; (void)id; return 0; }
void lp_angle_delete_buffer(void *ctx, uint32_t id) { (void)ctx; (void)id; }
uint32_t lp_angle_create_texture(void *ctx) { (void)ctx; return 0; }
void lp_angle_bind_texture(void *ctx, uint32_t target, uint32_t id) { (void)ctx; (void)target; (void)id; }
int lp_angle_is_texture(void *ctx, uint32_t id) { (void)ctx; (void)id; return 0; }
void lp_angle_delete_texture(void *ctx, uint32_t id) { (void)ctx; (void)id; }
void lp_angle_active_texture(void *ctx, uint32_t texture) { (void)ctx; (void)texture; }
void lp_angle_tex_parameteri(void *ctx, uint32_t target, uint32_t pname, int value) { (void)ctx; (void)target; (void)pname; (void)value; }
void lp_angle_tex_parameterf(void *ctx, uint32_t target, uint32_t pname, float value) { (void)ctx; (void)target; (void)pname; (void)value; }
int lp_angle_get_tex_parameter(void *ctx, uint32_t target, uint32_t pname) { (void)ctx; (void)target; (void)pname; return 0; }
void lp_angle_tex_image2d(void *ctx, uint32_t target, int level, int internal_format, int width, int height, int border, uint32_t format, uint32_t pixel_type, const void *pixels) { (void)ctx; (void)target; (void)level; (void)internal_format; (void)width; (void)height; (void)border; (void)format; (void)pixel_type; (void)pixels; }
void lp_angle_tex_sub_image2d(void *ctx, uint32_t target, int level, int x, int y, int width, int height, uint32_t format, uint32_t pixel_type, const void *pixels) { (void)ctx; (void)target; (void)level; (void)x; (void)y; (void)width; (void)height; (void)format; (void)pixel_type; (void)pixels; }
void lp_angle_pixel_storei(void *ctx, uint32_t pname, int value) { (void)ctx; (void)pname; (void)value; }
uint32_t lp_angle_create_framebuffer(void *ctx) { (void)ctx; return 0; }
void lp_angle_bind_framebuffer(void *ctx, uint32_t target, uint32_t id) { (void)ctx; (void)target; (void)id; }
uint32_t lp_angle_check_framebuffer_status(void *ctx, uint32_t target) { (void)ctx; (void)target; return 0; }
void lp_angle_framebuffer_renderbuffer(void *ctx, uint32_t target, uint32_t attachment, uint32_t renderbuffer_target, uint32_t id) { (void)ctx; (void)target; (void)attachment; (void)renderbuffer_target; (void)id; }
void lp_angle_framebuffer_texture2d(void *ctx, uint32_t target, uint32_t attachment, uint32_t texture_target, uint32_t id, int level) { (void)ctx; (void)target; (void)attachment; (void)texture_target; (void)id; (void)level; }
int lp_angle_is_framebuffer(void *ctx, uint32_t id) { (void)ctx; (void)id; return 0; }
void lp_angle_delete_framebuffer(void *ctx, uint32_t id) { (void)ctx; (void)id; }
uint32_t lp_angle_create_renderbuffer(void *ctx) { (void)ctx; return 0; }
void lp_angle_bind_renderbuffer(void *ctx, uint32_t target, uint32_t id) { (void)ctx; (void)target; (void)id; }
void lp_angle_renderbuffer_storage(void *ctx, uint32_t target, uint32_t format, int width, int height) { (void)ctx; (void)target; (void)format; (void)width; (void)height; }
int lp_angle_get_renderbuffer_parameter(void *ctx, uint32_t target, uint32_t pname) { (void)ctx; (void)target; (void)pname; return 0; }
int lp_angle_is_renderbuffer(void *ctx, uint32_t id) { (void)ctx; (void)id; return 0; }
void lp_angle_delete_renderbuffer(void *ctx, uint32_t id) { (void)ctx; (void)id; }
void lp_angle_buffer_data(void *ctx, uint32_t target, const void *data, size_t length, uint32_t usage) { (void)ctx; (void)target; (void)data; (void)length; (void)usage; }
int lp_angle_attrib_location(void *ctx, uint32_t program, const char *name) { (void)ctx; (void)program; (void)name; return -1; }
void lp_angle_enable_vertex_attrib(void *ctx, uint32_t index) { (void)ctx; (void)index; }
void lp_angle_vertex_attrib_pointer(void *ctx, uint32_t index, int size, uint32_t type, int normalized, int stride, uintptr_t offset) { (void)ctx; (void)index; (void)size; (void)type; (void)normalized; (void)stride; (void)offset; }
void lp_angle_viewport(void *ctx, int x, int y, int width, int height) { (void)ctx; (void)x; (void)y; (void)width; (void)height; }
void lp_angle_draw_arrays(void *ctx, uint32_t mode, int first, int count) { (void)ctx; (void)mode; (void)first; (void)count; }
void lp_angle_clear_color(void *ctx, float r, float g, float b, float a) { (void)ctx; (void)r; (void)g; (void)b; (void)a; }
void lp_angle_clear(void *ctx, uint32_t mask) { (void)ctx; (void)mask; }
int lp_angle_read_pixels(void *ctx, int x, int y, int width, int height, void *out) { (void)ctx; (void)x; (void)y; (void)width; (void)height; (void)out; return 0; }
uint32_t lp_angle_get_error(void *ctx) { (void)ctx; return 0; }
#endif
