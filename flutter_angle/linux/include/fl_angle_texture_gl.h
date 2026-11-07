#ifndef FL_ANGLE_TEXTURE_H
#define FL_ANGLE_TEXTURE_H

#include  "opengl_renderer.h"
#include "flutter_angle/flutter_angle_plugin.h"

#include <gtk/gtk.h>
#include <glib-object.h>
#include <flutter_linux/flutter_linux.h>

#include <GLES3/gl3.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <iostream>
#include <memory>
#include <mutex>

G_DECLARE_FINAL_TYPE(
  FlAngleTextureGL,
  fl_angle_texture_gl,
  FL,
  ANGLE_TEXTURE_GL,
  FlTextureGL
)

struct _FlAngleTextureGL{
  FlTextureGL parent_instance;
  uint32_t target;
  uint32_t name;
  uint32_t width;
  uint32_t height;
  // ROOSTER: Flutter samples the texture from its own context on the
  // raster thread, which shares no objects with ours: it binds [image], an
  // EGLImage of our texture made on Flutter's display, to a texture of its
  // own (the sibling), made again when [generation] moves (the texture's
  // storage was resized, and [image] with it). [mutex] guards these
  // against the platform thread.
  EGLDisplay display;
  EGLImageKHR image;
  uint32_t generation;
  uint32_t sibling;
  uint32_t sibling_generation;
  bool retired;
  std::mutex* mutex;
};


#define FLUTTER_ANGLE_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_angle_plugin_get_type(), \
                              FlutterAnglePlugin))

struct _FlutterAnglePlugin{
  GObject parent_instance;

  FlTextureRegistrar *textureRegistrar = nullptr;
  FlView *fl_view = nullptr;
  GdkWindow *window = nullptr;
  GdkGLContext* context;

  EGLDisplay eglDisplay;
  EGLContext eglContext = nullptr;
  EGLConfig config;
  Map *map = nullptr;
};

FlAngleTextureGL *fl_angle_texture_gl_new(
  uint32_t target,
  uint32_t name,
  uint32_t width,
  uint32_t height,
  EGLDisplay display,
  EGLImageKHR image
);

// ROOSTER: the texture's storage is now [width] x [height], and [image] is
// its EGLImage (the previous one is destroyed): Flutter's sibling is made
// again.
void fl_angle_texture_gl_resized(FlAngleTextureGL *self, uint32_t width, uint32_t height, EGLImageKHR image);

// ROOSTER: an EGLImage of [texture] in [context] (current on this thread),
// on [display]; EGL_NO_IMAGE_KHR when it cannot be made.
EGLImageKHR fl_angle_texture_gl_make_image(EGLDisplay display, EGLContext context, uint32_t texture);

// ROOSTER: the texture is going: its sibling is deleted from Flutter's
// context the next time any texture is populated there.
void fl_angle_texture_gl_retire(FlAngleTextureGL *self);

#endif // FL_ANGLE_TEXTURE_H
