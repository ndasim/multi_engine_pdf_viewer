import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bridge_message.dart';
import 'package:multi_engine_pdf_viewer/src/data/pdfjs/pdfjs_bundle.dart';

String _message(String type, [Map<String, Object?> payload = const {}]) =>
    jsonEncode({'v': pdfJsBridgeProtocolVersion, 'type': type, ...payload});

void main() {
  group('PdfJsBridgeMessage.tryParse', () {
    test('ignores malformed JSON, other protocol versions and unknown types', () {
      expect(PdfJsBridgeMessage.tryParse('not json'), isNull);
      expect(PdfJsBridgeMessage.tryParse('[]'), isNull);
      expect(PdfJsBridgeMessage.tryParse(jsonEncode({'v': 99, 'type': 'bridgeReady'})), isNull);
      expect(PdfJsBridgeMessage.tryParse(_message('unknown')), isNull);
    });

    test('parses ready and rejects invalid page values', () {
      final message = PdfJsBridgeMessage.tryParse(
        _message('ready', {'pageCount': 12, 'pageNumber': 3}),
      );
      expect(message, isA<PdfJsReadyMessage>());
      expect((message! as PdfJsReadyMessage).pageCount, 12);
      expect(
        PdfJsBridgeMessage.tryParse(_message('ready', {'pageCount': 0, 'pageNumber': 1})),
        isNull,
      );
      expect(PdfJsBridgeMessage.tryParse(_message('pageChanged', {'pageNumber': '2'})), isNull);
    });

    test('parses first visible page paint messages', () {
      final message = PdfJsBridgeMessage.tryParse(_message('firstPageRendered', {'pageNumber': 3}));
      expect(message, isA<PdfJsFirstPageRenderedMessage>());
      expect((message! as PdfJsFirstPageRenderedMessage).pageNumber, 3);
      expect(PdfJsBridgeMessage.tryParse(_message('firstPageRendered', {'pageNumber': 0})), isNull);
    });

    test('parses find state and normalizes an out-of-range current match', () {
      final message =
          PdfJsBridgeMessage.tryParse(
                _message('findState', {'current': 7, 'total': 3, 'pending': true}),
              )!
              as PdfJsFindStateMessage;
      expect(message.current, 0);
      expect(message.total, 3);
      expect(message.pending, isTrue);
    });

    test('parses outline trees and drops invalid entries', () {
      final message =
          PdfJsBridgeMessage.tryParse(
                _message('outline', {
                  'items': [
                    {
                      'title': 'Chapter',
                      'pageNumber': 2,
                      'path': [0],
                      'children': [
                        {
                          'title': 'Section',
                          'pageNumber': 2,
                          'path': [0, 0],
                          'destinationPath': [0, 0, 0],
                          'children': [],
                        },
                        {
                          'title': 42,
                          'path': [0, 1],
                        },
                      ],
                    },
                    'garbage',
                  ],
                }),
              )!
              as PdfJsOutlineMessage;

      expect(message.items, hasLength(1));
      final chapter = message.items.single;
      expect(chapter.title, 'Chapter');
      expect(chapter.pageNumber, 2);
      expect(chapter.children.single.title, 'Section');
      expect(chapter.children.single.pageNumber, 2);
      expect(chapter.children.single.path, [0, 0]);
      expect(chapter.children.single.destinationPath, [0, 0, 0]);
    });

    test('parses external links only with a scheme', () {
      final message =
          PdfJsBridgeMessage.tryParse(
                _message('externalLink', {'url': 'https://example.com/a?b=c'}),
              )!
              as PdfJsExternalLinkMessage;
      expect(message.url.host, 'example.com');
      expect(PdfJsBridgeMessage.tryParse(_message('externalLink', {'url': '/relative'})), isNull);
    });
  });

  test('pdfJsBridgeCommandScript passes the command as a string literal', () {
    final script = pdfJsBridgeCommandScript('find', {'query': "a'); alert(1); //\u2028"});
    const prefix = 'window.pdfjsBridge && window.pdfjsBridge.receive(';
    expect(script, startsWith(prefix));
    expect(script, endsWith(');'));

    final literal = script.substring(prefix.length, script.length - 2);
    final command = jsonDecode(jsonDecode(literal) as String) as Map<String, Object?>;
    expect(command, {
      'v': pdfJsBridgeProtocolVersion,
      'type': 'find',
      'query': "a'); alert(1); //\u2028",
    });
  });

  group('tier messages — the exact wire format bootstrap.js emits', () {
    // These three literals are the payloads `reportTier` builds in
    // assets/viewer/bootstrap.js, at its pinned, probe-success and
    // probe-found-nothing call sites. They are spelled out rather than
    // constructed so that a change on either side of the bridge fails here
    // instead of silently producing no telemetry on a device.
    test('probe chose a bundle', () {
      final message = PdfJsBridgeMessage.tryParse(
        '{"v":1,"type":"tier","tier":"compat","source":"probe",'
        '"capabilities":"m1.l1.c1.g0.d0","supported":"compat"}',
      );
      expect(message, isA<PdfJsTierMessage>());
      final tier = message! as PdfJsTierMessage;
      expect(tier.bundle, PdfJsBundle.compat);
      expect(tier.probeSupported, PdfJsBundle.compat);
      expect(tier.isPinned, isFalse);
      expect(tier.capabilities, 'm1.l1.c1.g0.d0');
    });

    test('tier was pinned by Dart and the probe ran alongside', () {
      final message =
          PdfJsBridgeMessage.tryParse(
                '{"v":1,"type":"tier","tier":"current","source":"pinned",'
                '"capabilities":"m1.l1.c1.g1.d1","supported":"current"}',
              )!
              as PdfJsTierMessage;
      expect(message.isPinned, isTrue);
      expect(message.bundle, PdfJsBundle.current);
      expect(message.probeSupported, PdfJsBundle.current);
    });

    test('no bundle can run: tier and supported are JSON null', () {
      // Chrome 66 lands here. `tier: null` must parse to a message with a null
      // bundle, not to a dropped message, or the engine-unsupported case is
      // invisible in telemetry.
      final message =
          PdfJsBridgeMessage.tryParse(
                '{"v":1,"type":"tier","tier":null,"source":"probe",'
                '"capabilities":"m1.l0.c0.g0.d0","supported":null}',
              )!
              as PdfJsTierMessage;
      expect(message.bundle, isNull);
      expect(message.probeSupported, isNull);
      expect(message.isPinned, isFalse);
      expect(message.capabilities, 'm1.l0.c0.g0.d0');
    });

    test('a tier message without a source is dropped', () {
      expect(PdfJsBridgeMessage.tryParse('{"v":1,"type":"tier","tier":"compat"}'), isNull);
    });

    test('bootstrap failures carry the bundle that was loading', () {
      final message =
          PdfJsBridgeMessage.tryParse(
                '{"v":1,"type":"error","name":"ViewerLoadTimeout",'
                '"message":"viewer.mjs did not initialise","tier":"current"}',
              )!
              as PdfJsErrorMessage;
      expect(message.bundle, PdfJsBundle.current);
      expect(message.isRetryableBundleFailure, isTrue);
    });

    test('EngineUnsupported is not retryable', () {
      final message =
          PdfJsBridgeMessage.tryParse(
                '{"v":1,"type":"error","name":"EngineUnsupported",'
                '"message":"no vendored build can run","tier":null}',
              )!
              as PdfJsErrorMessage;
      expect(message.bundle, isNull);
      expect(
        message.isRetryableBundleFailure,
        isFalse,
        reason: 'the probe already said no build can run; retrying only costs the user time',
      );
    });
  });
}
