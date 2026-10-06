import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

/// Resolves PDF named actions captured from PDFium's form-fill environment
/// into viewer navigation.
///
/// Named actions are structurally invisible to pdfrx 2.4.7 / the PDFium public
/// API used by pdfrx_engine 0.4.5 (see research notes under
/// docs/superpowers), so this handler draws the form-fill environment itself
/// via pdfium_dart FFI, simulates a left-button click at the tap point, and
/// captures the `FFI_ExecuteNamedAction` callback PDFium fires when a `/Btn`
/// widget with a `/N` named action is activated.
///
/// Only `NextPage` and `PrevPage` are mapped. `FirstPage`, `LastPage`,
/// JavaScript, submit/reset, and form persistence are intentionally ignored.
class PdfNamedActionHandler {
  PdfNamedActionHandler({this.onError, @visibleForTesting this.pdfiumLoader});

  final void Function(Object error, StackTrace stackTrace)? onError;

  @visibleForTesting
  final pdfium.PDFium Function()? pdfiumLoader;

  void _reportError(Object error, StackTrace stackTrace) {
    try {
      onError?.call(error, stackTrace);
    } catch (_) {}
  }

  int _requestId = 0;
  pdfium.PDFium? _pdfiumApi;
  bool _pdfiumUnavailable = false;
  bool _tapInFlight = false;
  _FormFillCallbacks? _formFill;
  String? _capturedAction;

  /// Maps a captured named action to a 1-based target page number.
  ///
  /// Returns null for unsupported actions. The caller should treat a target
  /// equal to [currentPage] as a no-op (no navigation).
  ///
  /// Pages are clamped to `[1, pageCount]`.
  static int? targetPageForNamedAction(
    String? actionName, {
    required int currentPage,
    required int pageCount,
  }) {
    if (actionName == null || actionName.isEmpty) return null;
    final target = switch (actionName) {
      'NextPage' => math.min(currentPage + 1, pageCount),
      'PrevPage' => math.max(currentPage - 1, 1),
      _ => null,
    };
    return target;
  }

  /// Handles a single-page tap by simulating a click on the PDF form widget at
  /// the tap position and captures any named action PDFium executes.
  ///
  /// Returns `true` iff a supported named action was captured and a page
  /// navigation was scheduled. Returns `false` when nothing happened; the
  /// caller should then let the tap fall through to the viewer's built-in
  /// handlers (links, text selection, ...).
  ///
  /// This method never throws: binary/platform failure, document disposal and
  /// in-flight races are contained and reported to [onError].
  ///
  /// FFI lifetime mirrors pdfrx_engine 0.4.5's own form-fill usage: the
  /// `FPDF_FORMFILLINFO` stays valid while the form handle is open, and
  /// `FPDFDOC_ExitFormFillEnvironment` is called before `calloc.free`.
  Future<bool> handleTap({
    required PdfDocument? document,
    required PdfPage page,
    required Rect pageRect,
    required Offset pagePosition,
    required PdfViewerController controller,
  }) async {
    if (document == null || !controller.isReady) return false;
    if (_pdfiumUnavailable || _tapInFlight) return false;

    final api = _resolvePdfium();
    if (api == null) return false;

    final formFill = _formFill ??= _FormFillCallbacks(
      onNamedAction: (action) => _capturedAction = action,
    );

    final requestId = ++_requestId;
    _tapInFlight = true;
    _capturedAction = null;

    try {
      await document.useNativeDocumentHandle((documentAddress) async {
        if (requestId != _requestId) return;

        final nativeDocument = pdfium.FPDF_DOCUMENT.fromAddress(documentAddress);
        final nativePage = api.FPDF_LoadPage(nativeDocument, page.pageNumber - 1);
        if (nativePage.address == 0) return;

        final formHandle = formFill.install(api, nativeDocument);
        if (formHandle.address == 0) {
          api.FPDF_ClosePage(nativePage);
          return;
        }

        try {
          final pagePoint = _toPagePoint(api, nativePage, pageRect, pagePosition);
          if (pagePoint == null) return;
          api
            ..FORM_OnAfterLoadPage(nativePage, formHandle)
            ..FORM_OnLButtonDown(formHandle, nativePage, 0, pagePoint.dx, pagePoint.dy)
            ..FORM_OnLButtonUp(formHandle, nativePage, 0, pagePoint.dx, pagePoint.dy);
          // A named action, if any, is captured synchronously during the
          // FORM_OnLButton* calls above (executeNamedAction is isolateLocal),
          // so there is nothing to wait for here.
        } finally {
          api
            ..FORM_OnBeforeClosePage(nativePage, formHandle)
            ..FPDFDOC_ExitFormFillEnvironment(formHandle)
            ..FPDF_ClosePage(nativePage);
        }
      });

      if (requestId != _requestId) return false;
      final currentPage = controller.pageNumber;
      if (currentPage == null) return false;
      final targetPage = targetPageForNamedAction(
        _capturedAction,
        currentPage: currentPage,
        pageCount: controller.pageCount,
      );
      if (targetPage == null || targetPage == currentPage) return false;

      await controller.goToPage(pageNumber: targetPage);
      return true;
    } catch (e, s) {
      _reportError(e, s);
      return false;
    } finally {
      _tapInFlight = false;
    }
  }

  /// Converts a tap inside [pageRect] to PDF page coordinates.
  ///
  /// PDFium applies the page's `/Rotate` and the y-axis flip itself, which a
  /// hand-written transform would get wrong on rotated pages.
  Offset? _toPagePoint(
    pdfium.PDFium api,
    pdfium.FPDF_PAGE nativePage,
    Rect pageRect,
    Offset pagePosition,
  ) {
    final pageX = calloc<ffi.Double>();
    final pageY = calloc<ffi.Double>();
    try {
      final converted = api.FPDF_DeviceToPage(
        nativePage,
        0,
        0,
        pageRect.width.round(),
        pageRect.height.round(),
        0,
        pagePosition.dx.round(),
        pagePosition.dy.round(),
        pageX,
        pageY,
      );
      if (converted == 0) return null;
      return Offset(pageX.value, pageY.value);
    } finally {
      calloc
        ..free(pageX)
        ..free(pageY);
    }
  }

  pdfium.PDFium? _resolvePdfium() {
    if (_pdfiumApi != null) return _pdfiumApi;
    if (_pdfiumUnavailable) return null;
    try {
      final loader = pdfiumLoader;
      return _pdfiumApi = loader == null ? pdfium.getPdfium() : loader();
    } catch (e, s) {
      _pdfiumUnavailable = true;
      _reportError(e, s);
      return null;
    }
  }

  /// Invalidates any in-flight tap handling and releases the native
  /// callbacks. After this returns, a pending [handleTap] continuation must not
  /// mutate state or navigate.
  void dispose() {
    _requestId++;
    _formFill?.dispose();
    _formFill = null;
  }
}

/// Allocates the `FPDF_FORMFILLINFO` struct and installs safe stub callbacks
/// for every v1 interface PDFium documents as "Implementation Required: yes",
/// so PDFium never dereferences a NULL callback during form interaction.
///
/// Void-returning stubs use `NativeCallable.listener` (async-dispatched; they never
/// dereference pointer arguments). Stubs that must consume pointer data or
/// return a value use `NativeCallable.isolateLocal` (synchronous call from
/// the UI isolate, which is where `useNativeDocumentHandle` runs its task
/// while the pdfium background worker is suspended).
///
/// `isolateLocal` is valid here because PDFium's form events are
/// embedder-driven and synchronous: every callback fires inline on the same
/// native thread that invoked `FORM_OnLButton*`. These pdfium builds ship
/// without V8/JS and the `FFI_SetTimer` stub returns 0 (no timers), so PDFium
/// has no mechanism to defer or move action execution to another thread. If
/// a future pdfium upgrade changes this, a wrong-thread `isolateLocal` call
/// crashes hard; the fix at that point would be a native trampoline copying
/// the string on the native side — revisit this before upgrading pdfium.
class _FormFillCallbacks {
  _FormFillCallbacks({required void Function(String action) onNamedAction})
    : _onNamedAction = onNamedAction {
    _build();
  }

  final void Function(String action) _onNamedAction;
  late final ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _callbacks;
  final List<ffi.NativeCallable<Function>> _callables = [];

  /// Opens a form-fill environment for [document].
  ///
  /// The environment is short-lived by design: its lifetime stays inside a
  /// single `useNativeDocumentHandle` call, where the document is guaranteed
  /// alive. Caching it across taps would risk outliving the document, which
  /// pdfrx may close from its own ref cache.
  pdfium.FPDF_FORMHANDLE install(pdfium.PDFium api, pdfium.FPDF_DOCUMENT document) {
    return api.FPDFDOC_InitFormFillEnvironment(document, _callbacks);
  }

  void _build() {
    final callbacks = calloc<pdfium.FPDF_FORMFILLINFO>();
    _callbacks = callbacks;

    // No-op stubs that never dereference their pointer arguments: listener
    // callables are async-dispatched and safe from any thread PDFium may
    // call them on.
    final invalidate =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<pdfium.FPDF_FORMFILLINFO>,
            pdfium.FPDF_PAGE,
            ffi.Double,
            ffi.Double,
            ffi.Double,
            ffi.Double,
          )
        >.listener(
          (
            ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _,
            pdfium.FPDF_PAGE _,
            double _,
            double _,
            double _,
            double _,
          ) {},
        );
    final setCursor =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<pdfium.FPDF_FORMFILLINFO>, ffi.Int)
        >.listener((ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, int _) {});
    final killTimer =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<pdfium.FPDF_FORMFILLINFO>, ffi.Int)
        >.listener((ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, int _) {});
    final executeNamedAction =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<pdfium.FPDF_FORMFILLINFO>, pdfium.FPDF_BYTESTRING)
        >.isolateLocal((ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, pdfium.FPDF_BYTESTRING action) {
          // Must be isolateLocal (synchronous), NOT listener: the nativeAction
          // byte string is only guaranteed valid for the duration of the native
          // FORM_OnLButton* call. A listener callable would defer this closure to
          // the event loop with a bare pointer and toDartString() could then read
          // freed/reused native memory (garbled action name or native crash).
          // isolateLocal runs this inline on the UI isolate — the same thread
          // that invoked FORM_OnLButton* — so the string is copied while valid.
          _onNamedAction(action.cast<Utf8>().toDartString());
        });

    // Value-returning stubs: isolateLocal callables answer synchronously.
    // `useNativeDocumentHandle` runs its task on the UI isolate with the
    // pdfium background worker suspended, so a same-isolate call is guaranteed.
    // FFI_GetLocalTime is intentionally left NULL: PDFium documents it as
    // "Unused" (and pdfrx_engine's own form-fill environment leaves it NULL
    // too), and NativeCallable.isolateLocal cannot return structs by value.
    final setTimer =
        ffi.NativeCallable<
          ffi.Int Function(ffi.Pointer<pdfium.FPDF_FORMFILLINFO>, ffi.Int, pdfium.TimerCallback)
        >.isolateLocal(
          (ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, int _, pdfium.TimerCallback _) => 0,
          exceptionalReturn: 0,
        );
    final getPage =
        ffi.NativeCallable<
          pdfium.FPDF_PAGE Function(
            ffi.Pointer<pdfium.FPDF_FORMFILLINFO>,
            pdfium.FPDF_DOCUMENT,
            ffi.Int,
          )
        >.isolateLocal(
          (ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, pdfium.FPDF_DOCUMENT _, int _) => ffi.nullptr,
        );
    final getCurrentPage =
        ffi.NativeCallable<
          pdfium.FPDF_PAGE Function(ffi.Pointer<pdfium.FPDF_FORMFILLINFO>, pdfium.FPDF_DOCUMENT)
        >.isolateLocal(
          (ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, pdfium.FPDF_DOCUMENT _) => ffi.nullptr,
        );
    final getRotation =
        ffi.NativeCallable<
          ffi.Int Function(ffi.Pointer<pdfium.FPDF_FORMFILLINFO>, pdfium.FPDF_PAGE)
        >.isolateLocal(
          (ffi.Pointer<pdfium.FPDF_FORMFILLINFO> _, pdfium.FPDF_PAGE _) => 0,
          exceptionalReturn: 0,
        );

    _callables.addAll([
      invalidate,
      setCursor,
      killTimer,
      executeNamedAction,
      setTimer,
      getPage,
      getCurrentPage,
      getRotation,
    ]);

    callbacks.ref
      ..version = 1
      ..FFI_Invalidate = invalidate.nativeFunction
      ..FFI_SetCursor = setCursor.nativeFunction
      ..FFI_SetTimer = setTimer.nativeFunction
      ..FFI_KillTimer = killTimer.nativeFunction
      ..FFI_GetPage = getPage.nativeFunction
      ..FFI_GetCurrentPage = getCurrentPage.nativeFunction
      ..FFI_GetRotation = getRotation.nativeFunction
      ..FFI_ExecuteNamedAction = executeNamedAction.nativeFunction;
  }

  /// Closes all native callables and frees the struct. Must not be called
  /// while a form handle opened by [install] is still open.
  void dispose() {
    for (final callable in _callables) {
      callable.close();
    }
    _callables.clear();
    calloc.free(_callbacks);
  }
}
