# PDF.js Android Profiling Harness

This Android-only Flutter app isolates `pdfjs_viewer_flutter` from CrewApp login, routing, analytics, and document download work. It opens the supplied `6474643.pdf` fixture and reports asset-copy, first-page-ready, and outline-ready durations in both the UI and the Dart timeline.

The fixture is intentionally ignored. Before analysis or a device run, install it as an app asset:

```sh
node profiling/copy_fixture.mjs
flutter analyze
```

See [profiling/README.md](profiling/README.md) for the profile-mode Android workflow and CPU-profile reporting commands.# pdfjs_perf_harness

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
