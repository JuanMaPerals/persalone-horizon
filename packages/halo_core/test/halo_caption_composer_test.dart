import 'dart:convert';
import 'dart:math';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_core/persalone_halo_core.dart';
import 'package:test/test.dart';

void main() {
  test('line capacities follow the circle chord with a safe margin', () {
    expect(HaloCaptionComposer.lineCapacities, <int>[29, 28, 27]);
  });

  test('short phrase: one centred line on one page', () {
    final HaloCaptionComposition c = HaloCaptionComposer.compose('Hello world');
    expect(c.pageCount, 1);
    expect(c.pages.single.single.text, 'Hello world');
    final HaloTextLine line = c.pages.single.single;
    expect(line.x, 128 - (11 * 8) ~/ 2 + 1);
    _expectInsideSafeCircle(c);
  });

  test('two lines wrap on word boundaries', () {
    final HaloCaptionComposition c = HaloCaptionComposer.compose(
        'The quick brown fox jumps over the lazy dog');
    expect(c.pages.single.map((HaloTextLine l) => l.text), <String>[
      'The quick brown fox jumps',
      'over the lazy dog',
    ]);
    _expectNoLoss(c);
  });

  test('maximum safe page: three full lines still fit the command budget', () {
    final String text = List<String>.filled(21, 'abc').join(' ');
    final HaloCaptionComposition c = HaloCaptionComposer.compose(text);
    expect(c.pageCount, 1);
    expect(c.pages.single, hasLength(3));
    expect(utf8.encode(c.command(0, powerOn: true).lua).length,
        lessThanOrEqualTo(HaloBoundedDisplay.maxCommandBytes));
    _expectNoLoss(c);
  });

  test('a word wider than a line is split with a visible hyphen', () {
    final String word = 'Pneumonoultramicroscopicsilicovolcanoconiosis';
    final HaloCaptionComposition c = HaloCaptionComposer.compose(word);
    final List<HaloTextLine> lines = c.pages.expand((p) => p).toList();
    expect(lines.first.text, endsWith('-'));
    expect(lines.first.continues, isTrue);
    expect(lines.first.text.length, HaloCaptionComposer.lineCapacities.first);
    _expectNoLoss(c);
  });

  test('Unicode: Latin diacritics folded, other scripts reported, never silent',
      () {
    final HaloCaptionComposition c =
        HaloCaptionComposer.compose('Español ¿qué tal? 中文 €5');
    expect(c.normalisedText, 'Espanol ?que tal? ?? EUR5');
    expect(c.foldedChars, 4);
    expect(c.unrenderableChars, 2);
    for (final HaloTextLine line in c.pages.expand((p) => p)) {
      expect(line.text.runes.every((int r) => r >= 0x20 && r <= 0x7E), isTrue);
    }
    _expectNoLoss(c);
  });

  test('long text needs page 2; pages are ordered and none is empty', () {
    final String text =
        List<String>.generate(40, (int i) => 'word$i').join(' ');
    final HaloCaptionComposition c = HaloCaptionComposer.compose(text);
    expect(c.pageCount, greaterThanOrEqualTo(2));
    expect(c.pages.every((p) => p.isNotEmpty), isTrue);
    expect(c.pages.first.first.text, startsWith('word0'));
    expect(c.pages.last.last.text, endsWith('word39'));
    expect(HaloCaptionComposition.resultValue(c), 'page:1/${c.pageCount}');
    _expectNoLoss(c);
    _expectInsideSafeCircle(c);
  });

  test('UNICODE LIMIT: degradation is reported in the result, never hidden',
      () {
    final HaloCaptionComposition ascii = HaloCaptionComposer.compose('Hello');
    expect(HaloCaptionComposition.resultValue(ascii), 'page:1/1');
    final HaloCaptionComposition folded =
        HaloCaptionComposer.compose('Qué tal señor');
    expect(HaloCaptionComposition.resultValue(folded), 'page:1/1;folded:2');
    final HaloCaptionComposition replaced =
        HaloCaptionComposer.compose('Привет 中文 ok');
    expect(HaloCaptionComposition.resultValue(replaced),
        'page:1/1;replaced:8');
    final HaloCaptionComposition both = HaloCaptionComposer.compose('Año 中');
    expect(HaloCaptionComposition.resultValue(both),
        'page:1/1;folded:1;replaced:1');
  });

  test('empty or whitespace-only captions compose to nothing', () {
    expect(HaloCaptionComposer.compose('  \n\t ').isEmpty, isTrue);
    expect(HaloCaptionComposition.resultValue(HaloCaptionComposer.compose('')),
        'page:0/0');
  });

  test('explicit limits: input length, pages and invalid Unicode', () {
    expect(
      () => HaloCaptionComposer.compose('a' * 401),
      throwsA(isA<RuntimeError>()
          .having((e) => e.code, 'code', RuntimeErrorCode.invalidContract)),
    );
    expect(
      () => HaloCaptionComposer.compose('a\uD800'),
      throwsA(isA<RuntimeError>()
          .having((e) => e.code, 'code', RuntimeErrorCode.invalidContract)),
    );
  });

  test('adversarial payloads: every page is a bounded, accepted command', () {
    for (final String payload in <String>[
      '")os.execute("rm -rf /")--',
      'local d=os d.exit()',
      '\\")print(2)--',
      'd.text("x",1,1)',
      '\n)os.exit()--\r',
      '"' * 90,
      '\\' * 120,
    ]) {
      final HaloCaptionComposition c = HaloCaptionComposer.compose(payload);
      for (int p = 0; p < c.pageCount; p++) {
        final String lua = c.command(p, powerOn: p == 0).lua;
        expect(HaloBoundedDisplay.isAcceptable(lua), isTrue, reason: lua);
        expect(utf8.encode(lua).length,
            lessThanOrEqualTo(HaloBoundedDisplay.maxCommandBytes));
      }
      _expectNoLoss(c);
    }
  });

  test('fuzz: 3000 random captions keep every invariant', () {
    final Random random = Random(20260926);
    const String alphabet =
        'abcdefghijklmnopqrstuvwxyz ABC  "\'\\-.,?!0123456789ñáé€中\n\t';
    for (int i = 0; i < 3000; i++) {
      final int length = random.nextInt(360);
      final String text = String.fromCharCodes(<int>[
        for (int j = 0; j < length; j++)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
      final HaloCaptionComposition c;
      try {
        c = HaloCaptionComposer.compose(text);
      } on RuntimeError catch (e) {
        expect(e.code, RuntimeErrorCode.invalidContract);
        continue;
      }
      expect(c.pageCount, lessThanOrEqualTo(HaloCaptionComposer.maxPages));
      _expectNoLoss(c);
      _expectInsideSafeCircle(c);
      for (int p = 0; p < c.pageCount; p++) {
        expect(HaloBoundedDisplay.isAcceptable(c.command(p, powerOn: true).lua),
            isTrue);
      }
      expect(HaloCaptionComposer.compose(text).reconstructed, c.reconstructed,
          reason: 'deterministic');
    }
  });
}

void _expectNoLoss(HaloCaptionComposition c) {
  expect(c.reconstructed, c.normalisedText, reason: 'no silent truncation');
}

void _expectInsideSafeCircle(HaloCaptionComposition c) {
  final List<int> caps = HaloCaptionComposer.lineCapacities;
  for (final List<HaloTextLine> page in c.pages) {
    for (int i = 0; i < page.length; i++) {
      final HaloTextLine line = page[i];
      expect(line.y, HaloCaptionComposer.lineTops[i]);
      expect(line.text.length, lessThanOrEqualTo(caps[i]));
      final int left = line.x - 1;
      final int right = left + line.text.length * 8 - 1;
      for (final int x in <int>[left, right]) {
        for (final int y in <int>[line.y - 1, line.y + 7]) {
          final double d = sqrt(pow(x - 127.5, 2) + pow(y - 127.5, 2));
          expect(d, lessThanOrEqualTo(128), reason: '${line.text} @($x,$y)');
        }
      }
    }
  }
}
