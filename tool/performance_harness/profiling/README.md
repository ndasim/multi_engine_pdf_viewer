# Android Device Profiling

## Setup

From `package/pdfjs_viewer_flutter/example`:

```sh
node profiling/copy_fixture.mjs
flutter analyze
flutter build apk --profile
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

The APK is deliberately a profile build. `MainActivity` enables WebView DevTools inspection for `debug` and `profile` only. Release builds keep inspection disabled. `android.permission.INTERNET` and the loopback-only cleartext network rule are required because `PdfJsViewer` serves its PDF and PDF.js assets from `127.0.0.1`. Treat `first_page_rendered` as the visible-first-page KPI, not `viewer_ready`: the latter only reports PDF.js `pagesinit` bootstrap completion.

## Capture

Start the app, then forward the Android WebView DevTools socket:

```sh
PID=$(adb shell pidof com.thy.perf.pdfjs_perf_harness)
adb forward tcp:9222 localabstract:webview_devtools_remote_$PID
node profiling/workerprofile.mjs 20 /tmp/pdfjs-6474643 --reload
```

`--reload` reloads the viewer only after CDP attaches to the WebView, placing the PDF.js opening inside the CPU profile window. Omit it only to profile an interaction you start manually. The script stores `page-*.cpuprofile`, `worker-*.cpuprofile`, and `summary.json` in the supplied directory.

To report inclusive sampled CPU time for the full capture or a narrower window:

```sh
node profiling/windows.mjs /tmp/pdfjs-6474643/worker-2.cpuprofile
node profiling/windows.mjs /tmp/pdfjs-6474643/worker-2.cpuprofile 0 7500
```

The first command reports the full sampled window. The second reports the first 7.5 seconds. The CDP script needs Node 22 or later for the built-in `WebSocket` client; the workspace currently has Node 26.

## Repeat Protocol

1. Close the harness with `adb shell am force-stop com.thy.perf.pdfjs_perf_harness`.
2. Launch it and wait for the first-page-ready metric.
3. Capture a Flutter DevTools or Perfetto trace and a CDP page/worker profile.
4. Repeat at least three times. Report each ready duration and the median. Outline time is separate because the viewer deliberately loads it after the first page paints.

Use the metric panel to identify the run phase, but use a Flutter trace for raster/UI scheduling and the worker CPU profile for PDF.js parsing, annotation, image-decode, and rendering costs.

Extract the timing lines after each run with:

```sh
adb logcat -d -v brief | rg 'PDFJS_HARNESS|viewer_error'
```

On the SM-A137F baseline (2026-09-29), three cold-process runs produced a median `first_page_rendered` of 7.989 s, bootstrap of 1.660 s and outline-ready of 10.233 s. The worker profile was dominated by `createImageData` and form widget annotation work, while the page main thread was mostly idle.

## Upgrade Comparison

For a PDF.js update, first copy the fixture and collect this baseline. Update only the vendored PDF.js assets through `../../tool/update_pdfjs.sh`, then repeat the identical device protocol. `pdfjs-dist` 6.3.289 contains the required legacy assets and JPEG/image improvements, but officially supports only Chrome 125+ and Safari 18+ in its legacy build. It is not a production update while this package supports Chrome/Android WebView 98+ and Safari/WKWebView 15.4+. Accept any later update only after it passes the package tests, interaction smoke checks, and the existing security configuration review (`isEvalSupported: false`, CSP, XFA disabled), while showing a measured gain that justifies the iOS Safari/WKWebView support change. Do not add a replacement viewer package to CrewApp before proving outline, search, GoTo/URI links, named actions, structured extraction, licensing, and device performance parity.