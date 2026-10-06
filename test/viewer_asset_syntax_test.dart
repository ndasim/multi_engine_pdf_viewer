import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Resolves the shipped `assets/viewer` directory whatever working directory
/// the suite was started from.
///
/// `flutter test` inside the package runs with the package as the working
/// directory, while `flutter test package/multi_engine_pdf_viewer` from the repo
/// root runs with the root — and a bare relative path silently fails in one of
/// the two. This suite is the guard for the ES5 floor, and it was passing from
/// the package and failing all 40 of its tests from the root, which is the
/// worst of both: a guard that reports green where a developer runs it and red
/// where CI does.
Directory _viewerAssets() {
  const candidates = ['assets/viewer', 'package/multi_engine_pdf_viewer/assets/viewer'];
  for (final candidate in candidates) {
    final directory = Directory(candidate);
    if (directory.existsSync()) return directory;
  }
  throw StateError(
    'cannot find assets/viewer from ${Directory.current.path}; tried ${candidates.join(', ')}',
  );
}

/// Holds the JavaScript floor of the shipped viewer assets.
///
/// `assets/viewer/bootstrap.js` used to *claim* "plain ES5" in a comment while
/// using `globalThis` twice. On Android 9's stock System WebView
/// (66.0.3359.158, Chrome 66) that file parsed — `globalThis` is a valid
/// identifier — installed its listeners, and then threw `ReferenceError` on
/// the first call into them, so the failure detector died before it could
/// report anything and the user got an infinite spinner instead of an error.
/// A comment cannot hold a floor, so this test does.
///
/// Checks are textual on purpose: there is no JavaScript engine in the Dart
/// test runner, and a parser dependency would have to be kept in step with the
/// floor anyway. Comments and string literals are removed first so prose about
/// `?.` does not fail the suite.
void main() {
  final assets = _viewerAssets();
  File asset(String name) => File('${assets.path}/$name');

  final bootstrap = asset('bootstrap.js');
  final indexHtml = asset('index.html');
  final probeLegacy = asset('probe_legacy.mjs');
  final probeCompat = asset('probe_compat.mjs');

  // The only reference to `globalThis` this file is allowed to contain: both
  // occurrences sit inside a `typeof` guard, so neither can throw on an engine
  // without it. Whitespace-insensitive, because the file is dart-format-free
  // JavaScript and the guard spans several lines.
  final allowedGlobalThisGuard = RegExp(r'typeof\s+globalThis\s*!==\s*""\s*\?\s*globalThis\s*:');

  group('bootstrap.js holds the ES5 floor', () {
    late String stripped;

    setUp(() {
      stripped = _stripCommentsAndStrings(bootstrap.readAsStringSync());
    });

    test('exists and is a classic script, not a module', () {
      expect(bootstrap.existsSync(), isTrue);
      expect(
        _stripCommentsAndStrings(indexHtml.readAsStringSync()),
        isNot(contains('type="module"')),
        reason:
            'bootstrap.js must be the only script in index.html; it injects the module '
            'itself once the capability probe has chosen a bundle',
      );
      expect(indexHtml.readAsStringSync(), contains('src="bootstrap.js"'));
    });

    test('no template literals', () {
      // Checked on the stripped source: the stripper removes comments and
      // quoted strings but not backtick-delimited ones, so a surviving
      // backtick is a real template literal.
      expect(
        stripped,
        isNot(contains('`')),
        reason: 'template literals are ES2015 (Chrome 41 / Safari 9)',
      );
    });

    test('references globalThis only inside a typeof guard', () {
      final withoutGuard = stripped.replaceAll(allowedGlobalThisGuard, '');
      expect(
        allowedGlobalThisGuard.hasMatch(stripped),
        isTrue,
        reason:
            'the guarded global lookup must stay; without it the file has no way to '
            'reach the bridge channel on an old engine',
      );
      expect(
        withoutGuard,
        isNot(contains('globalThis')),
        reason:
            'globalThis is Chrome 71 / Safari 12.1, above this file\'s floor; this is '
            'the exact bug that made Android 9 report nothing at all',
      );
    });

    // Every entry names the feature and the first engine that has it, so a
    // failure says what to do rather than just that something matched.
    final banned = <String, (RegExp, String)>{
      'optional chaining': (RegExp(r'\?\.'), 'Chrome 80 / Safari 13.1'),
      'nullish coalescing': (RegExp(r'\?\?'), 'Chrome 80 / Safari 13.1'),
      'logical OR assignment': (RegExp(r'\|\|='), 'Chrome 85 / Safari 14'),
      'logical AND assignment': (RegExp(r'&&='), 'Chrome 85 / Safari 14'),
      'arrow function': (RegExp(r'=>'), 'Chrome 45 / Safari 10'),
      'let declaration': (RegExp(r'\blet\s'), 'Chrome 49 / Safari 10'),
      'const declaration': (RegExp(r'\bconst\s'), 'Chrome 49 / Safari 10'),
      'class declaration': (RegExp(r'\bclass\s'), 'Chrome 49 / Safari 10'),
      'async function': (RegExp(r'\basync\b'), 'Chrome 55 / Safari 10.1'),
      'await': (RegExp(r'\bawait\b'), 'Chrome 55 / Safari 10.1'),
      'generator': (RegExp(r'function\s*\*'), 'Chrome 39 / Safari 10'),
      'spread or rest': (RegExp(r'\.\.\.'), 'Chrome 46 / Safari 10'),
      'exponentiation': (RegExp(r'\*\*'), 'Chrome 52 / Safari 10.1'),
      'class private member': (RegExp(r'#[A-Za-z_]'), 'Chrome 84 / Safari 15'),
      'for...of': (
        RegExp(r'\bfor\s*\(\s*(?:var\s+)?[A-Za-z_$][\w$]*\s+of\b'),
        'Chrome 38 / Safari 10',
      ),
      'Promise': (RegExp(r'\bPromise\b'), 'Chrome 32 / Safari 8'),
      'Symbol': (RegExp(r'\bSymbol\b'), 'Chrome 38 / Safari 9'),
    };

    for (final entry in banned.entries) {
      test('no ${entry.key}', () {
        final match = entry.value.$1.firstMatch(stripped);
        expect(
          match,
          isNull,
          reason:
              '${entry.key} needs ${entry.value.$2}, above the ES5 floor. Found near: '
              '${match == null ? '' : _context(stripped, match.start)}',
        );
      });
    }

    test('no eval and no new Function', () {
      // Not a floor question: the CSP is `script-src \'self\'` with no
      // `unsafe-eval`, so both are blocked at runtime anyway, and PDF.js runs
      // with `isEvalSupported: false` for CVE-2024-4367. Capability detection
      // must never reintroduce string compilation.
      expect(stripped, isNot(matches(RegExp(r'\beval\s*\('))));
      expect(stripped, isNot(matches(RegExp(r'\bnew\s+Function\b'))));
    });

    test('references Map only behind a typeof guard', () {
      // `Map.prototype.getOrInsertComputed` is how the `current` tier is
      // detected. ES5 engines have no Map at all, so the reference has to be
      // short-circuited by a typeof check in the same expression.
      final uses = RegExp(r'\bMap\b').allMatches(stripped).length;
      final guarded = RegExp(
        r'typeof Map !== "" &&[^;]*\bMap\.prototype\b',
      ).allMatches(stripped).length;
      expect(uses, 2, reason: 'exactly the two references in the guarded expression');
      expect(guarded, 1);
    });
  });

  group('viewer.mjs holds the Chrome 85 / Safari 14 floor', () {
    // The host page is loaded with whichever bundle the probe chose, including
    // the oldest one, so its floor has to be the OLDEST bundle's floor. That
    // floor was measured by grepping the vendored pdfjs-dist 4.1.392 build,
    // not read off a support matrix: it already contains logical assignment
    // (Chrome 85 / Safari 14), class private methods (Chrome 84 / Safari 15)
    // and optional chaining (Chrome 80 / Safari 13.1), and polyfills the
    // runtime APIs it uses above that.
    //
    // This is also the answer to "transpile, hand-write, or ship a second host
    // page for legacy": none of the three. The host page is already at the
    // floor — its highest feature is `??=`, exactly Chrome 85 — so all three
    // options would buy nothing and cost a build step, readability in a
    // 700-line file, or a doubled surface for the bridge protocol and named
    // actions to be verified against. What was missing was enforcement.
    late String stripped;

    setUp(() {
      stripped = _stripCommentsAndStrings(asset('viewer.mjs').readAsStringSync());
    });

    final aboveFloor = <String, (RegExp, String)>{
      'class static block': (RegExp(r'static\s*\{'), 'Chrome 94 / Safari 16.4'),
      'class private member': (RegExp(r'#[A-Za-z_]'), 'Chrome 84 but Safari 15'),
      'Array.prototype.at': (RegExp(r'\.at\('), 'Chrome 92 / Safari 15.4'),
      'Object.hasOwn': (RegExp(r'\bObject\.hasOwn\b'), 'Chrome 93 / Safari 15.4'),
      'structuredClone': (RegExp(r'\bstructuredClone\b'), 'Chrome 98 / Safari 15.4'),
      'findLast': (RegExp(r'\bfindLast\b'), 'Chrome 97 / Safari 15.4'),
      'change-by-copy array methods': (
        RegExp(r'\b(toSorted|toReversed|toSpliced)\b'),
        'Chrome 110 / Safari 16',
      ),
      'Object.groupBy': (RegExp(r'\bObject\.groupBy\b'), 'Chrome 117 / Safari 17.4'),
      'Array.fromAsync': (RegExp(r'\bArray\.fromAsync\b'), 'Chrome 121 / Safari 16.4'),
      'WeakRef or FinalizationRegistry': (
        RegExp(r'\b(WeakRef|FinalizationRegistry)\b'),
        'Chrome 84 but Safari 14.1',
      ),
      'Promise.any or AggregateError': (
        RegExp(r'\b(Promise\.any|AggregateError)\b'),
        'Chrome 85 but Safari 14',
      ),
      'Map.prototype.getOrInsertComputed': (
        RegExp(r'\bgetOrInsertComputed\b'),
        'iOS 26 — this is what gates the `current` tier and must never be used '
            'by the shared host page',
      ),
    };

    for (final entry in aboveFloor.entries) {
      test('no ${entry.key}', () {
        final match = entry.value.$1.firstMatch(stripped);
        expect(
          match,
          isNull,
          reason:
              '${entry.key} needs ${entry.value.$2}, above the Chrome 85 / Safari 14 '
              'floor set by the oldest vendored bundle. Found near: '
              '${match == null ? '' : _context(stripped, match.start)}',
        );
      });
    }

    test('still uses the features that define the floor', () {
      // A guard against the floor being raised silently by someone "cleaning
      // up" these, which would make the test above vacuous.
      expect(stripped, contains('??='), reason: 'logical assignment, Chrome 85 / Safari 14');
      expect(stripped, contains('?.'), reason: 'optional chaining, Chrome 80 / Safari 13.1');
    });

    test('keeps isEvalSupported false for CVE-2024-4367', () {
      expect(stripped, contains('isEvalSupported: false'));
      expect(stripped, contains('enableXfa: false'));
    });
  });

  group('capability probe modules', () {
    test('both exist', () {
      expect(probeLegacy.existsSync(), isTrue);
      expect(probeCompat.existsSync(), isTrue);
    });

    test('probe_legacy.mjs stays at the legacy bundle floor', () {
      final source = _stripCommentsAndStrings(probeLegacy.readAsStringSync());
      // A class static block in this file would raise the probe above the tier
      // it is supposed to describe, so every engine that can run `legacy`
      // would be told it cannot.
      expect(
        source,
        isNot(matches(RegExp(r'static\s*\{'))),
        reason:
            'class static blocks are Chrome 94 / Safari 16.4 — that is what separates '
            'compat from legacy and must only appear in probe_compat.mjs',
      );
      // The features it must contain, because the vendored legacy build does.
      expect(source, contains('??='));
      expect(source, contains('||='));
      expect(source, contains('&&='));
      expect(source, contains('?.'));
      expect(source, matches(RegExp(r'#\w')));
      expect(source, matches(RegExp(r'catch\s*\{')));
      expect(source, contains('self.__pdfjsProbe.legacy'));
    });

    test('probe_compat.mjs adds exactly the class static block', () {
      final source = _stripCommentsAndStrings(probeCompat.readAsStringSync());
      expect(source, matches(RegExp(r'static\s*\{')));
      expect(source, contains('self.__pdfjsProbe.compat'));
    });

    test('bootstrap.js loads both probes and no third one', () {
      final source = bootstrap.readAsStringSync();
      expect(source, contains('probe_legacy.mjs'));
      expect(source, contains('probe_compat.mjs'));
      expect(
        source,
        isNot(contains('probe_current.mjs')),
        reason:
            'compat and current are syntactically identical in the vendored builds; '
            'current is gated on Map.prototype.getOrInsertComputed instead',
      );
    });
  });
}

String _context(String source, int index) {
  final start = (index - 40).clamp(0, source.length);
  final end = (index + 40).clamp(0, source.length);
  return source.substring(start, end).replaceAll('\n', ' ');
}

/// Removes block comments, line comments and string literals, replacing each
/// string with `""` so token boundaries survive.
String _stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';

    if (char == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (char == '/' && next == '*') {
      i += 2;
      while (i + 1 < source.length && !(source[i] == '*' && source[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (char == '"' || char == "'") {
      i++;
      while (i < source.length && source[i] != char) {
        if (source[i] == r'\') i++;
        i++;
      }
      i++;
      out.write('""');
      continue;
    }
    out.write(char);
    i++;
  }
  return out.toString();
}
