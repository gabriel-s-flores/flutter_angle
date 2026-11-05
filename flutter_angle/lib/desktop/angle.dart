import '../shared/render_worker.dart';
import 'package:flutter_angle/flutter_angle.dart';

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:dylib/dylib.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_angle/shared/console.dart';
import 'lib_egl.dart';

class FlutterAngleTexture {
  final int textureId;
  late int rboId;
  Pointer<Void>? surfaceId;
  late int fboId;
  late int depth;
  late AngleOptions options;
  late final FlutterAngle _flutterAngle;

  LibOpenGLES get rawOpenGl {
    return _flutterAngle._rawOpenGl;
  }

  FlutterAngleTexture(
    FlutterAngle flutterAngle,
    this.textureId,
    this.rboId,
    this.fboId,
    this.depth,
    this.options
  ) {
    _flutterAngle = flutterAngle;
  }

  FlutterAngleTexture.fromSurface(
    FlutterAngle flutterAngle,
    this.textureId,
    this.surfaceId,
    this.options
  ) {
    rboId = 0;
    fboId = 0;
    _flutterAngle = flutterAngle;
  }
  
  Map<String, int> toMap() {
    return {
      'textureId': textureId,
      'rbo': rboId,
    };
  }

  RenderingContext getContext() {
    assert(_flutterAngle._baseAppContext != nullptr, "OpenGL isn't initialized! Please call FlutterAngle.initOpenGL");
    // ROOSTER: each of the renderer's calls holds our context (Linux).
    return RenderingContext.create(_flutterAngle._rawOpenGl, options.width, options.height, false, _flutterAngle._linuxGuard?.hold);
  }

  /// Whenever you finished your rendering you have to call this function to signal
  /// the Flutterengine that it can display the rendering
  /// Despite this being an asyc function it probably doesn't make sense to await it
  Future<void> signalNewFrameAvailable() async {
    await _flutterAngle.updateTexture(this);
  }

  /// As you can have multiple Texture objects, but WebGL allways draws in the currently
  /// active one you have to call this function if you use more than one Textureobject before
  /// you can start rendering on it. If you forget it you will render into the wrong Texture.
  void activate() {
    _flutterAngle.activateTexture(this);
    //_flutterAngle._rawOpenGl.glViewport(0, 0, options.width, options.height);
  }
}

class FlutterAngle {
  final MethodChannel _channel = const MethodChannel('flutter_angle');
  LibOpenGLES? _libOpenGLES;
  EGL? _libEGL;
  Pointer<Void> _display = nullptr;
  late Pointer<Void> _eglConfig;
  Pointer<Void> _baseAppContext = nullptr;
  Pointer<Void> _pluginContext = nullptr;
  Pointer<Void> _dummySurface = nullptr;
  int? _activeFramebuffer;
  RenderWorker? _worker;

  bool _useAngle = false;
  bool _isApple = false;
  bool _useSurface = false;
  bool _isRBO = true;
  bool _disposed = false;

  /// ROOSTER: Linux only; see [_LinuxGlGuard].
  _LinuxGlGuard? _linuxGuard;

  LibOpenGLES get _rawOpenGl {
    _linuxGuard?.hold();
    if (_libOpenGLES == null) {
      if (Platform.isWindows) {
        _libOpenGLES = LibOpenGLES(DynamicLibrary.open(resolveDylibPath('libGLESv2')));
      } 
      else if (Platform.isAndroid) {
        if (_useAngle) {
          _libOpenGLES = LibOpenGLES(DynamicLibrary.open('libGLESv2_angle.so'));
        } 
        else {
          _libOpenGLES = LibOpenGLES(DynamicLibrary.open('libGLESv3.so'),false);
        }
      } 
      else {
        _libOpenGLES = LibOpenGLES(DynamicLibrary.process());
      }
    }
    return _libOpenGLES!;
  }

  // Next stepps:
  // * test on all plaforms
  // * mulitple textures on Android and the other OSs
  Future<void> init([bool useDebugContext = false, bool useAngle = true]) async {
    if (_display != nullptr) return;

    _isApple = Platform.isIOS || Platform.isMacOS;
    _useAngle = useAngle;
    
    // Initialize native part of he plugin
    late final dynamic result;
    if (Platform.isAndroid && _useAngle) {
      result = await _channel.invokeMethod('initOpenGLAngle');
      _useAngle = result['forceOpengl'] == null?_useAngle:!result['forceOpengl'];
      angleConsole.info("Force Opengl: ${result['forceOpengl']}");
    }
    else {
      _useAngle = false;
      result = await _channel.invokeMethod('initOpenGL');

      if(_isApple){
        _isApple = result['isSimulator'] == null?_isApple:!result['isSimulator'];
      }
    }

    _libEGL = EGL(useAngle: _useAngle);
    angleConsole.info(result);

    if (result == null) {
      throw EglException('Plugin.initOpenGL didn\'t return anything. Something is really wrong!');
    }

    if (Platform.isWindows || Platform.isLinux || (Platform.isAndroid && !_useAngle)) {
      final pluginContextAdress = result['context'] ?? result['openGLContext'];
      if (pluginContextAdress == null) {
        throw EglException('Plugin.initOpenGL didn\'t return a Context. Something is really wrong!');
      }

      _pluginContext = Pointer<Void>.fromAddress(pluginContextAdress);
    }

    if(Platform.isAndroid && !_useAngle){
      final dummySurfacePointer = result['dummySurface'] as int?;
      if (dummySurfacePointer == null) {
        throw EglException('Plugin.initOpenGL didn\'t return a dummy surface. Something is really wrong!');
      }
      _dummySurface = Pointer<Void>.fromAddress(dummySurfacePointer);
    }

    /// Init OpenGL on the Dart side too
    // ROOSTER: on Linux, the display the plugin made its context on: the
    // one Flutter renders with (the same native display, the same
    // platform), so its texture can be handed to Flutter's context. The
    // default display is another one, and a context shared across two
    // displays is no share at all.
    final pluginDisplay = Platform.isLinux && result is Map ? result['display'] as int? : null;
    _display = pluginDisplay != null && pluginDisplay != 0
        ? Pointer<Void>.fromAddress(pluginDisplay)
        : _libEGL!.eglGetDisplay();
    final initializeResult = _libEGL!.eglInitialize(_display);

    angleConsole.info('EGL version: $initializeResult');

    late final Map<EglConfigAttribute, int> eglAttributes;

    /// In case the plugin returns its selected EGL config we use it.
    /// Finally this should be how all platforms behave. Till all platforms
    /// support this we leave this check here
    final eglConfigId = (result is Map && result.containsKey('eglConfigId'))? result['eglConfigId'] as int?: null;
    if (eglConfigId != null) {
      eglAttributes = {EglConfigAttribute.configId: eglConfigId,};
    } 
    else {
      eglAttributes = {
        EglConfigAttribute.renderableType: EglValue.openglEs3Bit.toIntValue(),
        EglConfigAttribute.redSize: 8,
        EglConfigAttribute.greenSize: 8,
        EglConfigAttribute.blueSize: 8,
        EglConfigAttribute.alphaSize: 8,
        EglConfigAttribute.depthSize: 24,
        EglConfigAttribute.samples: 4,
        EglConfigAttribute.stencilSize: 8,
      };
    }

    final chooseConfigResult = _libEGL!.eglChooseConfig(
      _display,
      attributes: eglAttributes,
      maxConfigs: 1,
    );
    eglAttributes.clear();
    _eglConfig = chooseConfigResult[0];

    // ROOSTER: an OpenGL ES context whatever API this thread has bound
    // (GTK binds desktop OpenGL for its windows on Linux), and GTK's API
    // put back after.
    final previousApi = Platform.isLinux ? _LinuxGlGuard.bindEs() : null;
    try {
      _baseAppContext = _libEGL!.eglCreateContext(
        _display,
        _eglConfig,
        shareContext: _pluginContext == nullptr?null:_pluginContext,
        contextClientVersion: 3,
        isDebugContext: useDebugContext && !Platform.isAndroid
      );
    } finally {
      if (previousApi != null) _LinuxGlGuard.bindApi(previousApi);
    }

    if (Platform.isLinux) {
      // ROOSTER: not made current for good here: GTK draws the window on
      // this very thread between our frames. The guard makes it current
      // for each GL call, and puts back what GTK had before the task ends.
      if (_baseAppContext == nullptr) {
        throw EglException('Could not create the renderer\'s EGL context.');
      }
      _linuxGuard = _LinuxGlGuard(_display, _baseAppContext);
    }
    else if(!_isApple){
      /// bind context to this thread. All following OpenGL calls from this thread will use this context
      _libEGL!.eglMakeCurrent(_display, _dummySurface, _dummySurface, _baseAppContext);
    
      if (useDebugContext && Platform.isWindows) {
        _rawOpenGl.glEnable(GL_DEBUG_OUTPUT);
        _rawOpenGl.glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS);
      }
    }
  }

  /// For iOS only: Creates an EGL surface from an IOSurface pointer
  Pointer<Void>? _createEGLSurfaceFromIOSurface(Pointer<Void> ioSurfacePtr, int width, int height) {
    if (!_isApple) return null;

    final textureTarget = _libEGL!.getTextureTarget(_display, _eglConfig);

    final surfaceAttribs = calloc<Int32>(20);
    int i = 0;
    surfaceAttribs[i++] = EGL_WIDTH;
    surfaceAttribs[i++] = width;
    surfaceAttribs[i++] = EGL_HEIGHT;
    surfaceAttribs[i++] = height;
    surfaceAttribs[i++] = EGL_IOSURFACE_PLANE_ANGLE;
    surfaceAttribs[i++] = 0;
    surfaceAttribs[i++] = EGL_TEXTURE_TARGET;
    surfaceAttribs[i++] = textureTarget;
    surfaceAttribs[i++] = EGL_TEXTURE_INTERNAL_FORMAT_ANGLE;
    surfaceAttribs[i++] = GL_BGRA_EXT;
    surfaceAttribs[i++] = EGL_TEXTURE_FORMAT;
    surfaceAttribs[i++] = EGL_TEXTURE_RGBA;
    surfaceAttribs[i++] = EGL_TEXTURE_TYPE_ANGLE;
    surfaceAttribs[i++] = GL_UNSIGNED_BYTE;
    surfaceAttribs[i++] = EGL_NONE;

    Pointer<Void>? macIosSurface;
    try {
      macIosSurface = _libEGL!.eglCreatePbufferFromClientBuffer(
        _display,
        EGL_IOSURFACE_ANGLE, // 0x3454
        ioSurfacePtr,
        _eglConfig,
        surfaceAttribs
      );

      if (macIosSurface != nullptr) {
        // Immediately make the surface current to initialize it properly
        try {
          _libEGL!.eglMakeCurrent(_display, macIosSurface, macIosSurface, _baseAppContext);
          angleConsole.info("Successfully made EGL surface current from IOSurface");
        } catch (e) {
          angleConsole.error("Failed to make EGL surface current: $e");
          return null;
        }
      }

      angleConsole.info("Successfully created EGL surface from IOSurface");
    } catch (e) {
      angleConsole.error("Failed to create EGL surface from IOSurface: $e");
      macIosSurface = nullptr;
    } finally {
      calloc.free(surfaceAttribs);
    }

    return macIosSurface;
  }
  Pointer<Void>? _createEGLSurfaceFromD3DSurface(Pointer<Void> d3dSurfacePtr, int width, int height){
    if (!Platform.isWindows) return null;

    final textureTarget = _libEGL!.getTextureTarget(_display, _eglConfig);

    final surfaceAttribs = calloc<Int32>(20);
    int i = 0;
    surfaceAttribs[i++] = EGL_WIDTH;
    surfaceAttribs[i++] = width;
    surfaceAttribs[i++] = EGL_HEIGHT;
    surfaceAttribs[i++] = height;
    surfaceAttribs[i++] = EGL_TEXTURE_TARGET;
    surfaceAttribs[i++] = textureTarget;
    surfaceAttribs[i++] = EGL_TEXTURE_FORMAT;
    surfaceAttribs[i++] = EGL_TEXTURE_RGBA;
    surfaceAttribs[i++] = EGL_NONE;

    Pointer<Void>? d3dSurface;
    try {
      d3dSurface = _libEGL!.eglCreatePbufferFromClientBuffer(
        _display,
        EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE,
        d3dSurfacePtr,
        _eglConfig,
        surfaceAttribs
      );

      if (d3dSurface != nullptr) {
        // Immediately make the surface current to initialize it properly
        try {
          _libEGL!.eglMakeCurrent(_display, d3dSurface, d3dSurface, _baseAppContext);
          angleConsole.info("Successfully made EGL surface current from D3DSurface");
        } catch (e) {
          angleConsole.error("Failed to make EGL surface current: $e");
          return null;
        }
      }

      angleConsole.info("Successfully created EGL surface from D3DSurface");
    } catch (e) {
      angleConsole.error("Failed to create EGL surface from D3DSurface: $e");
      d3dSurface = nullptr;
    } finally {
      calloc.free(surfaceAttribs);
    }

    return d3dSurface;
  }
  int _createFBOTexture(int rboId, int width, int height){    
    angleConsole.info(_rawOpenGl.glGetError());
    _rawOpenGl.glActiveTexture(WebGL.TEXTURE0);

    _initRenderbuffer(rboId);

    var frameBufferCheck = _rawOpenGl.glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (frameBufferCheck != GL_FRAMEBUFFER_COMPLETE) {
      angleConsole.error("Framebuffer (color) check failed: $frameBufferCheck");
    }

    _rawOpenGl.glViewport(0, 0, width, height);

    Pointer<Uint32> depthBuffer = calloc();
    _rawOpenGl.glGenRenderbuffers(1, depthBuffer.cast());
    _rawOpenGl.glBindRenderbuffer(GL_RENDERBUFFER, depthBuffer.value);
    _rawOpenGl.glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, width, height);
    _rawOpenGl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthBuffer.value);
    _rawOpenGl.glBindRenderbuffer(GL_RENDERBUFFER, 0);

    frameBufferCheck = _rawOpenGl.glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (frameBufferCheck != GL_FRAMEBUFFER_COMPLETE) {
      angleConsole.error("Framebuffer (depth) check failed: $frameBufferCheck");
    }
    final value = depthBuffer.value;

    calloc.free(depthBuffer);

    return value;
  }

  void _initRenderbuffer(int rboId) {
    if (!_isRBO) {
      _rawOpenGl.glBindTexture(GL_TEXTURE_2D, rboId);
      _rawOpenGl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D, rboId, 0);
    } 
    else {
      _rawOpenGl.glBindRenderbuffer(GL_RENDERBUFFER, rboId);
      _rawOpenGl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rboId);
    }
    _rawOpenGl.glBindRenderbuffer(GL_RENDERBUFFER, 0);
  }
  void _resizeDepthRenderbuffer(int depthRenderbuffer, int newWidth, int newHeight) {
    _rawOpenGl.glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
    _rawOpenGl.glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, newWidth, newHeight);
    _rawOpenGl.glBindRenderbuffer(GL_RENDERBUFFER, 0);
  }
  
  Future<FlutterAngleTexture> createTexture(AngleOptions options) async {
    final height = (options.height * options.dpr).toInt();
    final width = (options.width * options.dpr).toInt();
    late final dynamic result;

    result = await _channel.invokeMethod(_useAngle?'createTextureAngle':'createTexture', {
      "width": width,
      "height": height,
      "useSurfaceProducer": options.useSurfaceProducer
    });

    if (Platform.isAndroid) {
      _useSurface = true;
      final newTexture = FlutterAngleTexture.fromSurface(
        this,
        result['textureId']! as int,
        Pointer.fromAddress(result['surface'] as int? ?? 0),
        options
      );
      _rawOpenGl.glViewport(0, 0, width, height);

      if (!options.customRenderer) {
        _worker = RenderWorker(newTexture);
      }

      return newTexture;
    }
    else if (_isApple) {
      _useSurface = true;
      // Create the EGL surface from IOSurface before creating the texture object
      Pointer<Void>? macIosSurface;
      if (result.containsKey('surfacePointer')) {
        final surfacePointer = result['surfacePointer'] as int;
        if (surfacePointer != 0) {
          final ioSurfacePtr = Pointer<Void>.fromAddress(surfacePointer);
          macIosSurface = _createEGLSurfaceFromIOSurface(ioSurfacePtr, width, height);
          if (macIosSurface == null) {
            angleConsole.error("Failed to create EGL surface from IOSurface");
          } else {
            angleConsole.info("Successfully created EGL surface from IOSurface");
          }
        }
      }

      final newTexture = FlutterAngleTexture.fromSurface(
        this,
        result['textureId']! as int,
        macIosSurface, // We'll use an IOSurface instead
        options
      );

      _rawOpenGl.glViewport(0, 0, width, height);

      if (!options.customRenderer) {
        _worker = RenderWorker(newTexture);
      }

      return newTexture;
    }
    else if (Platform.isWindows && options.useSurfaceProducer) {
      _useSurface = true;
      // Create the EGL surface from D3DSurface before creating the texture object
      Pointer<Void>? d3dSurface;
      if (result.containsKey('surfacePointer')) {
        final surfacePointer = result['surfacePointer'] as int;
        if (surfacePointer != 0) {
          final d3dSurfacePtr = Pointer<Void>.fromAddress(surfacePointer);
          d3dSurface = _createEGLSurfaceFromD3DSurface(d3dSurfacePtr, width, height);
          if (d3dSurface == null) {
            angleConsole.info("Failed to create EGL surface from D3DSurface");
          } else {
            angleConsole.info("Successfully created EGL surface from D3DSurface");
          }
        }
      }

      final newTexture = FlutterAngleTexture.fromSurface(
        this,
        result['textureId']! as int,
        d3dSurface, // We'll use an D3DSurface instead
        options
      );
      _rawOpenGl.glViewport(0, 0, width, height);

      if (!options.customRenderer) {
        _worker = RenderWorker(newTexture);
      }

      return newTexture;
    }
    else{
      Pointer<Uint32> fbo = calloc();
      _rawOpenGl.glGenFramebuffers(1, fbo);
      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, fbo.value);

      final int rbo = (result['openglTexture'] as int?) ?? (result['rbo'] as int?) ?? 0;
      if(result['openglTexture'] != null){
        _isRBO = false;
      }

      final value = _createFBOTexture(rbo, width, height);

      final newTexture = FlutterAngleTexture(
        this,
        result['textureId']! as int,
        rbo,
        fbo.value,
        value,
        options
      );

      angleConsole.info(newTexture.toMap());
      _rawOpenGl.glViewport(0, 0, width, height);

      if (!options.customRenderer) {
        _worker = RenderWorker(newTexture);
      }

      _activeFramebuffer = fbo.value;
      calloc.free(fbo);

      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, 0);

      return newTexture;
    }
  }

  Future<void> resize(FlutterAngleTexture texture, AngleOptions options) async{
    if(_disposed || Platform.isAndroid) return;
    
    final height = (options.height * options.dpr).toInt();
    final width = (options.width * options.dpr).toInt();
    
    final result = await _channel.invokeMethod('resizeTexture', {
      "width": width,
      "height": height,
      "textureId": texture.textureId,
    });

    if(_useSurface){
      final surfacePointer = result['surfacePointer'] as int;
      final surfacePtr = Pointer<Void>.fromAddress(surfacePointer);
      texture.surfaceId = Platform.isWindows?_createEGLSurfaceFromD3DSurface(surfacePtr, width, height) :_createEGLSurfaceFromIOSurface(surfacePtr, width, height);
      _libEGL!.eglMakeCurrent(_display, texture.surfaceId!, texture.surfaceId!, _baseAppContext);
    }
    else if(result != null){
      final int rbo = (result['openglTexture'] as int?) ?? (result['rbo'] as int?) ?? 0;
      // ROOSTER: the attachments are the texture's own framebuffer's: bound
      // first (a frame leaves the default one bound), and let go after.
      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, texture.fboId);
      _initRenderbuffer(rbo);
      _resizeDepthRenderbuffer(texture.depth, width, height);
      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
      texture.rboId = rbo;
    }

    texture.options = options;
  }
  void updateSource(FlutterAngleTexture texture, [WebGLTexture? sourceTexture]) async {
    if(_disposed) return;
    if (sourceTexture != null) {
      _rawOpenGl.glClearColor(0.0, 0.0, 0.0, 0.0);
      _rawOpenGl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
      _rawOpenGl.glViewport(0, 0, (texture.options.width*texture.options.dpr).toInt(),( texture.options.height*texture.options.dpr).toInt());
      _worker?.renderTexture(sourceTexture, isFBO: Platform.isAndroid);
      _rawOpenGl.glFinish();
    }
  }

  Future<void> updateTexture(FlutterAngleTexture texture, [WebGLTexture? sourceTexture]) async {
    if(_disposed) return;
    updateSource(texture,sourceTexture);
    

    // If we have an iOS EGL surface created from IOSurface, use it
    if (_useSurface && texture.surfaceId != nullptr) {
      _libEGL!.eglSwapBuffers(_display, texture.surfaceId!);
    }
    else{
      // ROOSTER: Flutter samples the texture from its own context on the
      // raster thread (Linux): the frame must be done drawing by then, not
      // only on its way to the GPU.
      if (Platform.isLinux) {
        _rawOpenGl.glFinish();
      } else {
        _rawOpenGl.glFlush();
      }
      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, 0);
      assert(_activeFramebuffer != null, 'There is no active FlutterGL Texture to update');
    }

    if (!Platform.isAndroid) {
      if (Platform.isLinux || Platform.isWindows) {
        _channel.invokeMethod('textureFrameAvailable', {"textureId": texture.textureId});
      } 
      else {
        await _channel.invokeMethod('textureFrameAvailable', {"textureId": texture.textureId});
      }
    }
  }

  Future<void> deleteTexture(FlutterAngleTexture texture,[bool releaseAll = true]) async {
    if (Platform.isAndroid) return;

    if(_useSurface && texture.surfaceId != nullptr){
      _libEGL!.eglMakeCurrent(_display, texture.surfaceId!, texture.surfaceId!, _baseAppContext);
      _libEGL!.eglDestroySurface(_display, texture.surfaceId!);
      texture.surfaceId = nullptr;
    }

    angleConsole.warning('There is no active FlutterGL Texture to delete');

    if (_activeFramebuffer == texture.fboId && releaseAll) {
      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, texture.fboId);
      if (!_isRBO){
        _rawOpenGl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D, 0, 0);
      }
      else{
        _rawOpenGl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, 0);
      }
      _rawOpenGl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, 0);
      _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, 0);

      _rawOpenGl.glClearColor(0.0, 0.0, 0.0, 0.0);
      _rawOpenGl.glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

      Pointer<Uint32> fbo = calloc();
      fbo.value = texture.fboId;
      _rawOpenGl.glDeleteBuffersPointer(1, fbo);
      calloc.free(fbo);
      _activeFramebuffer = null;

      Pointer<Uint32> depth = calloc();
      depth.value = texture.depth;
      _rawOpenGl.glDeleteRenderbuffersPointer(1, depth);
      calloc.free(depth);
    }

    if(releaseAll){
      await _channel.invokeMethod('deleteTexture',{"textureId": texture.textureId});
    }
  }

  void dispose([List<FlutterAngleTexture?>? textures]) {
    textures?.forEach((t) {
      if(t!=null){
        deleteTexture(t);
      }
      t = null;
    });
    textures?.clear();
    if(_baseAppContext != nullptr){
      // ROOSTER: let go of it first (a context current on a thread is only
      // destroyed once it is no longer), then no more holding it.
      _linuxGuard?.releaseNow();
      _linuxGuard = null;
      _libEGL!.eglDestroyContext(_display, _baseAppContext);
      _baseAppContext = nullptr;
    }

    _worker?.dispose();
    _worker = null;
    //_libOpenGLES?.close();
    _libOpenGLES = null;
    _libEGL!.dispose();
    _disposed = true;
  }

  void activateTexture(FlutterAngleTexture texture) {
    if(_disposed) return;

    _rawOpenGl.glViewport(0, 0, (texture.options.width*texture.options.dpr).toInt(),( texture.options.height*texture.options.dpr).toInt());
    _rawOpenGl.glBindFramebuffer(GL_FRAMEBUFFER, texture.fboId);

    // If we have an iOS EGL surface created from IOSurface, use it
    if (_useSurface && texture.surfaceId != nullptr) {
      _libEGL!.eglMakeCurrent(_display, texture.surfaceId!, texture.surfaceId!, _baseAppContext);
      return;
    }

    if (!_isRBO){
      _rawOpenGl.glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D, texture.rboId, 0);
    }
    else{
      _rawOpenGl.glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, texture.rboId);
    }
    _activeFramebuffer = texture.fboId;
  }

  void printOpenGLError(String message) {
    var glGetError = _rawOpenGl.glGetError();
    if (glGetError != GL_NO_ERROR) {
      angleConsole.error('$message: $glGetError');
    }
  }
}

/// ROOSTER: on Linux, Flutter 3.41 runs the Dart UI thread on GTK's main
/// thread, and GTK (its window's paint context) and Flutter make their own
/// GL contexts current there between our frames. Upstream made the
/// renderer's context current once, at init: every later GL call landed in
/// whichever context GTK had left current. The game drew into the window's
/// own context (the whole window flickered, half of it a frame behind, as
/// the game's depth test and culling met GTK's quad) and nothing into its
/// texture. Now each GL call makes ours current first, and whatever was
/// current before goes back at the end of the task (a microtask: nothing of
/// GTK's runs in between), so GTK finds its context where it left it.
///
/// On X11 GTK's contexts are GLX ones, and libglvnd refuses an EGL context
/// while a GLX one is current on the thread (EGL_BAD_ACCESS): that one is
/// let go first and made current again after.
class _LinuxGlGuard {
  _LinuxGlGuard(this.display, this.context);

  final Pointer<Void> display;
  final Pointer<Void> context;

  static const int _eglDraw = 0x3059;
  static const int _eglRead = 0x305A;

  static final DynamicLibrary _lib = DynamicLibrary.open('libEGL.so.1');
  static final Pointer<Void> Function() _currentContext = _lib.lookupFunction<
      Pointer<Void> Function(), Pointer<Void> Function()>('eglGetCurrentContext');
  static final Pointer<Void> Function() _currentDisplay = _lib.lookupFunction<
      Pointer<Void> Function(), Pointer<Void> Function()>('eglGetCurrentDisplay');
  static final Pointer<Void> Function(int) _currentSurface = _lib.lookupFunction<
      Pointer<Void> Function(Int32), Pointer<Void> Function(int)>('eglGetCurrentSurface');
  static final int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
      _makeCurrent = _lib.lookupFunction<
          Uint32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
          'eglMakeCurrent');

  static const int _eglOpenGlEsApi = 0x30A0;
  static final int Function() _queryApi =
      _lib.lookupFunction<Uint32 Function(), int Function()>('eglQueryAPI');
  static final int Function(int) _bindApi =
      _lib.lookupFunction<Uint32 Function(Uint32), int Function(int)>('eglBindAPI');

  /// Binds OpenGL ES on this thread; the API bound before.
  static int bindEs() {
    final previous = _queryApi();
    _bindApi(_eglOpenGlEsApi);
    return previous;
  }

  static void bindApi(int api) => _bindApi(api);

  static final _Glx? _glx = _Glx.find();

  bool _holding = false;
  bool _switched = false;
  _GlxBinding? _glxPrevious;
  Pointer<Void> _previousDisplay = nullptr;
  Pointer<Void> _previousDraw = nullptr;
  Pointer<Void> _previousRead = nullptr;
  Pointer<Void> _previous = nullptr;

  /// Makes the renderer's context current until the end of this task.
  void hold() {
    if (_holding) return;
    _holding = true;
    scheduleMicrotask(releaseNow);
    _previous = _currentContext();
    if (_previous == context) return;
    _previousDisplay = _currentDisplay();
    _previousDraw = _currentSurface(_eglDraw);
    _previousRead = _currentSurface(_eglRead);
    _glxPrevious = _glx?.release();
    _switched = _makeCurrent(display, nullptr, nullptr, context) == 1;
    if (!_switched) {
      final glxPrevious = _glxPrevious;
      _glxPrevious = null;
      if (glxPrevious != null) _glx!.restore(glxPrevious);
      angleConsole.error('Could not make the renderer\'s EGL context current');
    }
  }

  /// Puts back whatever was current before [hold].
  void releaseNow() {
    if (!_holding) return;
    _holding = false;
    if (!_switched) return;
    _switched = false;
    if (_previous == nullptr) {
      _makeCurrent(display, nullptr, nullptr, nullptr);
    } else {
      _makeCurrent(_previousDisplay, _previousDraw, _previousRead, _previous);
    }
    final glxPrevious = _glxPrevious;
    _glxPrevious = null;
    if (glxPrevious != null) _glx!.restore(glxPrevious);
  }
}

/// ROOSTER: a GLX context current on the thread, as it was.
typedef _GlxBinding = ({
  Pointer<Void> display,
  int draw,
  int read,
  Pointer<Void> context,
});

/// ROOSTER: GLX, when the process has it (GTK on X11); see [_LinuxGlGuard].
class _Glx {
  _Glx._(DynamicLibrary lib)
      : _currentContext = lib.lookupFunction<Pointer<Void> Function(),
            Pointer<Void> Function()>('glXGetCurrentContext'),
        _currentDisplay = lib.lookupFunction<Pointer<Void> Function(),
            Pointer<Void> Function()>('glXGetCurrentDisplay'),
        _currentDrawable = lib.lookupFunction<UnsignedLong Function(),
            int Function()>('glXGetCurrentDrawable'),
        _currentReadDrawable = lib.lookupFunction<UnsignedLong Function(),
            int Function()>('glXGetCurrentReadDrawable'),
        _makeContextCurrent = lib.lookupFunction<
            Int32 Function(Pointer<Void>, UnsignedLong, UnsignedLong, Pointer<Void>),
            int Function(Pointer<Void>, int, int, Pointer<Void>)>('glXMakeContextCurrent');

  static _Glx? find() {
    final process = DynamicLibrary.process();
    if (process.providesSymbol('glXGetCurrentContext') &&
        process.providesSymbol('glXMakeContextCurrent')) {
      return _Glx._(process);
    }
    return null;
  }

  final Pointer<Void> Function() _currentContext;
  final Pointer<Void> Function() _currentDisplay;
  final int Function() _currentDrawable;
  final int Function() _currentReadDrawable;
  final int Function(Pointer<Void>, int, int, Pointer<Void>) _makeContextCurrent;

  /// Lets go of the current GLX context, if any; what it was.
  _GlxBinding? release() {
    final context = _currentContext();
    if (context == nullptr) return null;
    final binding = (
      display: _currentDisplay(),
      draw: _currentDrawable(),
      read: _currentReadDrawable(),
      context: context,
    );
    _makeContextCurrent(binding.display, 0, 0, nullptr);
    return binding;
  }

  void restore(_GlxBinding binding) {
    _makeContextCurrent(
        binding.display, binding.draw, binding.read, binding.context);
  }
}
