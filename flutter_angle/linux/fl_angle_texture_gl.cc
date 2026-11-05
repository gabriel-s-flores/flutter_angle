#include "include/fl_angle_texture_gl.h"

// https://github.com/lattice0/external_texture_flutter_linux/tree/master/external_texture/linux

#include <iostream>
#include <vector>

#include <GLES2/gl2ext.h>

G_DEFINE_TYPE(
  FlAngleTextureGL,
  fl_angle_texture_gl,
  fl_texture_gl_get_type()
)

// ROOSTER: siblings of textures that are gone, deleted in Flutter's context
// (the only one they exist in) at the next populate.
static std::mutex orphans_mutex;
static std::vector<GLuint> orphans;

static void delete_orphans() {
  std::lock_guard<std::mutex> lock(orphans_mutex);
  if (orphans.empty()) return;
  glDeleteTextures(static_cast<GLsizei>(orphans.size()), orphans.data());
  orphans.clear();
}

static PFNEGLCREATEIMAGEKHRPROC create_image() {
  static auto f = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  return f;
}

static PFNEGLDESTROYIMAGEKHRPROC destroy_image() {
  static auto f = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  return f;
}

// ROOSTER: made as Flutter makes its own frames' images (fl_framebuffer.cc):
// from the texture's context, current, and with no attributes. Made from a
// context current nowhere, or asking for the pixels to be preserved, NVIDIA
// refuses it (EGL_BAD_ACCESS).
EGLImageKHR fl_angle_texture_gl_make_image(EGLDisplay display, EGLContext context, uint32_t texture) {
  if (create_image() == nullptr) return EGL_NO_IMAGE_KHR;
  return create_image()(
      display, context, EGL_GL_TEXTURE_2D_KHR,
      reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(texture)),
      nullptr);
}

// ROOSTER: the texture as Flutter's context sees it: our texture's EGLImage
// bound to a texture of Flutter's own. Called on the raster thread, with
// Flutter's context current.
static gboolean make_sibling(FlAngleTextureGL* self, GError** error) {
  static auto target_texture =
      reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
          eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  if (target_texture == nullptr) {
    g_set_error(error, g_quark_from_static_string("flutter_angle"), 1,
                "EGLImage textures are not available");
    return FALSE;
  }
  if (self->image == EGL_NO_IMAGE_KHR) {
    g_set_error(error, g_quark_from_static_string("flutter_angle"), 2,
                "Texture %u has no EGLImage", self->name);
    return FALSE;
  }

  GLint saved_binding = 0;
  glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_binding);
  if (self->sibling != 0) glDeleteTextures(1, &self->sibling);
  glGenTextures(1, &self->sibling);
  glBindTexture(GL_TEXTURE_2D, self->sibling);
  target_texture(GL_TEXTURE_2D, self->image);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, saved_binding);
  self->sibling_generation = self->generation;
  return TRUE;
}

static gboolean fl_angle_texture_gl_populate(
  FlTextureGL *texture,
  uint32_t *target,
  uint32_t *name,
  uint32_t *width,
  uint32_t *height,
  GError **error
){
  FlAngleTextureGL* f = (FlAngleTextureGL*) texture;
  delete_orphans();
  std::lock_guard<std::mutex> lock(*f->mutex);
  if (f->retired) {
    g_set_error(error, g_quark_from_static_string("flutter_angle"), 3,
                "The texture is gone");
    return FALSE;
  }
  if (f->sibling == 0 || f->sibling_generation != f->generation) {
    if (!make_sibling(f, error)) return FALSE;
  }
  *target = GL_TEXTURE_2D;
  *name = f->sibling;
  *width = f->width;
  *height = f->height;
  return TRUE;
}

FlAngleTextureGL *fl_angle_texture_gl_new(
  uint32_t target,
  uint32_t name,
  uint32_t width,
  uint32_t height,
  EGLDisplay display,
  EGLImageKHR image
){
  auto r = FL_ANGLE_TEXTURE_GL(g_object_new(fl_angle_texture_gl_get_type(), nullptr));
  r->target = target;
  r->name = name;
  r->width = width;
  r->height = height;
  r->display = display;
  r->image = image;
  return r;
}

void fl_angle_texture_gl_resized(FlAngleTextureGL *self, uint32_t width, uint32_t height, EGLImageKHR image) {
  std::lock_guard<std::mutex> lock(*self->mutex);
  // A sibling already made keeps the old storage; the image is not needed
  // for it any more.
  if (self->image != EGL_NO_IMAGE_KHR && destroy_image() != nullptr) {
    destroy_image()(self->display, self->image);
  }
  self->image = image;
  self->width = width;
  self->height = height;
  self->generation++;
}

void fl_angle_texture_gl_retire(FlAngleTextureGL *self) {
  std::lock_guard<std::mutex> lock(*self->mutex);
  self->retired = true;
  if (self->image != EGL_NO_IMAGE_KHR && destroy_image() != nullptr) {
    destroy_image()(self->display, self->image);
    self->image = EGL_NO_IMAGE_KHR;
  }
  if (self->sibling != 0) {
    std::lock_guard<std::mutex> orphans_lock(orphans_mutex);
    orphans.push_back(self->sibling);
    self->sibling = 0;
  }
}

static void fl_angle_texture_gl_finalize(GObject *object) {
  FlAngleTextureGL* self = FL_ANGLE_TEXTURE_GL(object);
  fl_angle_texture_gl_retire(self);
  delete self->mutex;
  G_OBJECT_CLASS(fl_angle_texture_gl_parent_class)->finalize(object);
}

static void fl_angle_texture_gl_class_init(FlAngleTextureGLClass *klass){
  FL_TEXTURE_GL_CLASS(klass)->populate = fl_angle_texture_gl_populate;
  G_OBJECT_CLASS(klass)->finalize = fl_angle_texture_gl_finalize;
}

static void fl_angle_texture_gl_init(FlAngleTextureGL *self){
  self->display = EGL_NO_DISPLAY;
  self->image = EGL_NO_IMAGE_KHR;
  self->generation = 0;
  self->sibling = 0;
  self->sibling_generation = 0;
  self->retired = false;
  self->mutex = new std::mutex();
}
