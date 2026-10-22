# Example

```sh
cd example
flutter pub get
flutter run
```

Open a PDF from the app bar. PDF.js is the default on iOS and Android.
The menu offers PDF.js, EmbedPDF and pdfrx on both platforms, plus PDFKit on iOS.

Android allows cleartext HTTP for `127.0.0.1` only. The example targets iOS 14 or later.

## iOS integration test

```sh
flutter test integration_test/pdfkit_test.dart -d <ios-simulator-id>
```

For a local Xcode whose simulator deployment floor is iOS 15+, prefix the command
with `FLUTTER_XCODE_IPHONEOS_DEPLOYMENT_TARGET=15.0`. This does not raise the
package's runtime minimum.

For actual native touches, start the opt-in fixture:

```sh
flutter test integration_test/pdfkit_hid_test.dart \
  --dart-define=PDFKIT_HID=true -d <ios-simulator-id>
```

The printed `PDFKIT_HID_PORT` exposes only synthetic test state and fixed navigation
commands on loopback, for four minutes. In another terminal, run the actual-touch
driver (Node.js and `fb-idb`/`idb_companion` must be available):

```sh
IDB_COMPANION_PATH=/opt/homebrew/bin/idb_companion \
  node integration_test/pdfkit_hid_driver.mjs <port> <ios-simulator-id> <path-to-idb>
```

The driver checks real named-action/internal-link navigation with exactly one page
callback per tap, the HTTPS callback, blocked file URLs and grid selection. It
also sends double-tap/pinch input and saves screenshots under `build/pdfkit-hid/`
for visual zoom inspection. Native HID delivery itself depends on the installed
Xcode/runtime/companion combination.

For manual control, use `/page/1`, `/page/2`, `/page/3`, `/grid`,
`/vertical` and `/state` to position/inspect the fixture while sending real simulator
HID touches. `/done` finishes the test. It asserts one paint notification, no errors,
one HTTPS callback and a grid-tap return to vertical. This bridge is never part of
the normal example app or the production viewer.

A private local large-PDF smoke test can run without bundling the PDF:

```sh
flutter test integration_test/pdfkit_test.dart -d <ios-simulator-id> \
  --dart-define=PDFKIT_LOCAL_FILE=/absolute/local/path/document.pdf
```

This optional simulator-only test requires a file larger than 20 MiB and verifies
opening, native paint, outline parsing, last-page navigation, background search
completion, grid and reopen/cleanup. The file must be accessible to the simulator.
