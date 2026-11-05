#include "include/opengl_renderer.h"
#include "include/fl_angle_texture_gl.h"
#include <flutter_linux/fl_texture_registrar.h>

#include <dlfcn.h>

// ROOSTER: our context current on this (the platform) thread for a moment,
// and whatever was current before put back after: GTK draws the window on
// this thread with its own context, and keeps track of which is current. On
// X11 that is a GLX context, and libglvnd refuses an EGL context while a GLX
// one is current (EGL_BAD_ACCESS): it is let go first, and made current
// again after. GLX is looked up in the process (GTK loads it on X11).
namespace {
struct Glx {
  void* (*get_current_context)();
  void* (*get_current_display)();
  unsigned long (*get_current_drawable)();
  unsigned long (*get_current_read_drawable)();
  int (*make_context_current)(void*, unsigned long, unsigned long, void*);
};

const Glx* glx() {
  static const Glx* found = []() -> const Glx* {
    static Glx table;
    table.get_current_context = reinterpret_cast<void* (*)()>(dlsym(RTLD_DEFAULT, "glXGetCurrentContext"));
    table.get_current_display = reinterpret_cast<void* (*)()>(dlsym(RTLD_DEFAULT, "glXGetCurrentDisplay"));
    table.get_current_drawable = reinterpret_cast<unsigned long (*)()>(dlsym(RTLD_DEFAULT, "glXGetCurrentDrawable"));
    table.get_current_read_drawable = reinterpret_cast<unsigned long (*)()>(dlsym(RTLD_DEFAULT, "glXGetCurrentReadDrawable"));
    table.make_context_current = reinterpret_cast<int (*)(void*, unsigned long, unsigned long, void*)>(dlsym(RTLD_DEFAULT, "glXMakeContextCurrent"));
    if (!table.get_current_context || !table.get_current_display ||
        !table.get_current_drawable || !table.get_current_read_drawable ||
        !table.make_context_current) {
      return nullptr;
    }
    return &table;
  }();
  return found;
}

class ScopedContext {
 public:
  ScopedContext(EGLDisplay display, EGLContext context)
      : display_(eglGetCurrentDisplay()),
        draw_(eglGetCurrentSurface(EGL_DRAW)),
        read_(eglGetCurrentSurface(EGL_READ)),
        previous_(eglGetCurrentContext()),
        ours_(display) {
    const Glx* g = glx();
    if (g != nullptr && g->get_current_context() != nullptr) {
      glx_context_ = g->get_current_context();
      glx_display_ = g->get_current_display();
      glx_draw_ = g->get_current_drawable();
      glx_read_ = g->get_current_read_drawable();
      g->make_context_current(glx_display_, 0, 0, nullptr);
    }
    ok_ = eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, context) ==
          EGL_TRUE;
  }
  ~ScopedContext() {
    if (previous_ != EGL_NO_CONTEXT) {
      eglMakeCurrent(display_, draw_, read_, previous_);
    } else {
      eglMakeCurrent(ours_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (glx_context_ != nullptr) {
      glx()->make_context_current(glx_display_, glx_draw_, glx_read_, glx_context_);
    }
  }
  bool ok() const { return ok_; }

 private:
  EGLDisplay display_;
  EGLSurface draw_;
  EGLSurface read_;
  EGLContext previous_;
  EGLDisplay ours_;
  void* glx_context_ = nullptr;
  void* glx_display_ = nullptr;
  unsigned long glx_draw_ = 0;
  unsigned long glx_read_ = 0;
  bool ok_ = false;
};
}  // namespace

OpenglRenderer::OpenglRenderer(
  FlTextureRegistrar* textureRegistrar, 
  EGLDisplay display, 
  EGLContext context,
  int width, 
  int height
){
  this->textureRegistrar = textureRegistrar;
  this->eglDisplay = display;
  this->eglContext = context;
  this->texId = 0;
  this->textureId = 0;
  this->texture = nullptr;

  changeSize(width, height);
}

FlValue *OpenglRenderer::createTexture() {
  g_autoptr(FlValue) value = fl_value_new_map ();
  fl_value_set_string_take(value, "textureId", fl_value_new_int(textureId));
  fl_value_set_string_take(value, "openglTexture", fl_value_new_int((int64_t)texId));
  return fl_value_ref(value);
}

// ROOSTER: the texture keeps its name and its Flutter registration through a
// resize: only its storage changes (and Flutter's sibling of it). Upstream
// made a new texture and registered it under a new id the Dart side never
// heard of, so the game's view showed nothing after its first resize.
void OpenglRenderer::changeSize(int width, int height) {
  const int MAX_TEXTURE_SIZE = 8192;
  if (width <= 0 || height <= 0 || width > MAX_TEXTURE_SIZE || height > MAX_TEXTURE_SIZE) {
    return;
  }

  this->width = width;
  this->height = height;

  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  {
    ScopedContext scope(eglDisplay, eglContext);
    if (!scope.ok()) {
      g_warning("flutter_angle: could not make the plugin's context current (EGL error 0x%x)", eglGetError());
      return;
    }
    if (texId == 0) glGenTextures(1, &texId);
    glBindTexture(GL_TEXTURE_2D, texId);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);
    // The storage exists before the renderer's context attaches it and
    // Flutter's imports it.
    glFinish();
    image = fl_angle_texture_gl_make_image(eglDisplay, eglContext, texId);
    if (image == EGL_NO_IMAGE_KHR) {
      g_warning("flutter_angle: could not make an EGLImage of texture %u (EGL error 0x%x)", texId, eglGetError());
    }
  }

  if (texture == nullptr) {
    auto ft = fl_angle_texture_gl_new(GL_TEXTURE_2D, texId, width, height, eglDisplay, image);
    texture = FL_TEXTURE(ft);
    fl_texture_registrar_register_texture(textureRegistrar, texture);
    textureId = fl_texture_get_id(texture);
  } else {
    fl_angle_texture_gl_resized(FL_ANGLE_TEXTURE_GL(texture), width, height, image);
    fl_texture_registrar_mark_texture_frame_available(textureRegistrar, texture);
  }
}

void OpenglRenderer::updateTexture() {
  if (texture) {
    fl_texture_registrar_mark_texture_frame_available(textureRegistrar, texture);
  }
}

void OpenglRenderer::dispose(bool release_context) {
  if (texture != nullptr) {
    fl_angle_texture_gl_retire(FL_ANGLE_TEXTURE_GL(texture));
  }

  if (texId != 0) {
    // ROOSTER: deleted in our context, not whichever GTK left current.
    ScopedContext scope(eglDisplay, eglContext);
    if (scope.ok()) glDeleteTextures(1, &texId);
    texId = 0;
  }

  if (release_context && texture) {
    fl_texture_registrar_unregister_texture(textureRegistrar, texture);
    textureId = 0;
    texture = nullptr;
  }
}

OpenglRenderer::~OpenglRenderer() {
  dispose(true);
}
