import 'dart:convert';
import 'dart:math';

import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_adapter/persalone_halo_adapter.dart';
import 'package:test/test.dart';

const String _clearPrefix = 'frame.display.clear()';
const String _powerPrefix = 'frame.display.power_save(false)';
const String _textOpen = 'frame.display.text("';

/// Malicious or awkward caption payloads. None may alter Lua structure.
const List<String> _payloads = <String>[
  '")os.execute("rm -rf /")--',
  '\\")os.exit()--',
  'abc\\',
  '\\\\"',
  "'..os.exit()..'",
  ']]os.exit()--[[',
  '\n)os.exit()--',
  '\r\nprint(2)',
  '\x00")os.exit()--',
  '\x1b[31mred',
  '\u0085next-line',
  '\u2028line-separator',
  '\u202eoverride',
  '%s %d %n',
  r'$(reboot)',
  'frame.display.text("x",1,1)print(1)',
  '"',
  "'",
  '\\',
  '\\999',
  '\\x41\\u{41}\\z   ',
  '\x7f\x08\t',
  'ñáé€ 🔥 中文',
  '',
];

void main() {
  group('HaloBoundedDisplay.text', () {
    test('builds the fixed template with layout coordinates', () {
      final String lua =
          HaloBoundedDisplay.text('Hola, ¿qué tal?', powerOn: false).lua;
      expect(
        lua,
        'frame.display.clear()frame.display.text("Hola, ¿qué tal?",24,168)'
        'print(1)',
      );
      expect(
        HaloBoundedDisplay.text('x',
                layout: HaloCaptionLayout.upperBand, powerOn: false)
            .lua,
        contains('",24,72)print(1)'),
      );
    });

    test('prepends power_save(false) only when requested', () {
      expect(HaloBoundedDisplay.text('a', powerOn: true).lua,
          startsWith('$_powerPrefix$_clearPrefix'));
      expect(HaloBoundedDisplay.text('a', powerOn: false).lua,
          startsWith(_clearPrefix));
    });

    test('escapes quotes, backslash, newlines and control sequences', () {
      final String body = _lex(
        HaloBoundedDisplay.text('"\'\\\n\r\t\x00\x1b\x7f\u0085', powerOn: false)
            .lua,
      ).body;
      expect(body, r'\"' r"\'" r'\\\010\013\009\000\027\127\194\133');
      expect(body.codeUnits.where((int u) => u < 0x20 || u == 0x7f), isEmpty);
    });

    for (final String payload in _payloads) {
      test('keeps payload inside the literal: ${jsonEncode(payload)}', () {
        _expectStructurallySafe(payload, powerOn: payload.isEmpty);
      });
    }

    test('fuzz: 5000 random strings never alter Lua structure', () {
      final Random random = Random(20260924);
      final List<int> alphabet = <int>[
        for (int c = 0; c < 128; c++) c,
        0x80,
        0x85,
        0x9F,
        0xA0,
        0xE9,
        0x20AC,
        0x2028,
        0x202E,
        0x1F525,
      ];
      int accepted = 0;
      for (int i = 0; i < 5000; i++) {
        final String text = String.fromCharCodes(<int>[
          for (int j = random.nextInt(41); j > 0; j--)
            alphabet[random.nextInt(alphabet.length)],
        ]);
        HaloDisplayCommand command;
        try {
          command = HaloBoundedDisplay.text(text, powerOn: random.nextBool());
        } on RuntimeError catch (error) {
          expect(error.code, RuntimeErrorCode.invalidContract);
          continue;
        }
        accepted++;
        _expectStructurallySafe(text, lua: command.lua);
      }
      expect(accepted, greaterThan(2500));
    });

    test('enforces explicit length limits', () {
      expect(
          HaloBoundedDisplay.text('a' * HaloBoundedDisplay.maxTextBytes,
              powerOn: false),
          isA<HaloDisplayCommand>());
      expect(HaloBoundedDisplay.text('€' * 32, powerOn: false),
          isA<HaloDisplayCommand>());
      _expectInvalid(() => HaloBoundedDisplay.text(
          'a' * (HaloBoundedDisplay.maxTextBytes + 1),
          powerOn: false));
      _expectInvalid(
          () => HaloBoundedDisplay.text('\x01' * 96, powerOn: false));
    });

    test('rejects invalid Unicode (lone surrogates)', () {
      _expectInvalid(() => HaloBoundedDisplay.text('a\uD800b', powerOn: false));
      _expectInvalid(() => HaloBoundedDisplay.text('\uDC00', powerOn: false));
      _expectInvalid(() => HaloBoundedDisplay.text('\uD83D', powerOn: false));
    });

    test('keeps every layout inside the 256x256 display', () {
      for (final HaloCaptionLayout layout in HaloCaptionLayout.values) {
        expect(
            HaloBoundedDisplay.coordinatesInRange(layout.x, layout.y), isTrue);
      }
      expect(HaloBoundedDisplay.coordinatesInRange(0, 1), isFalse);
      expect(HaloBoundedDisplay.coordinatesInRange(1, 0), isFalse);
      expect(HaloBoundedDisplay.coordinatesInRange(257, 1), isFalse);
      expect(HaloBoundedDisplay.coordinatesInRange(1, 257), isFalse);
      expect(HaloBoundedDisplay.coordinatesInRange(256, 256), isTrue);
    });
  });

  group('HaloBoundedDisplay.isAcceptable', () {
    test('accepts only the bounded clear and text templates', () {
      expect(HaloBoundedDisplay.isAcceptable(HaloBoundedDisplay.clear.lua),
          isTrue);
      for (final String forged in <String>[
        'print(1)',
        'os.execute("x")',
        'frame.display.clear()frame.display.text("a"..os.exit().."",24,168)print(1)',
        'frame.display.clear()frame.display.text("a\n",24,168)print(1)',
        'frame.display.clear()frame.display.text("a",0,168)print(1)',
        'frame.display.clear()frame.display.text("a",257,1)print(1)',
        'frame.display.clear()frame.display.text("a",24,168)print(1)os.exit()',
        'frame.display.power_save(true)frame.display.clear()frame.display.text("a",24,168)print(1)',
        'frame.display.clear()frame.display.text("a\\",24,168)print(1)',
      ]) {
        expect(HaloBoundedDisplay.isAcceptable(forged), isFalse,
            reason: forged);
      }
    });
  });

  group('SIMULATED fixture vs HALO_REAL separation', () {
    test('fixture uses the same builder but only claims SIMULATED', () async {
      final ScriptedHaloFixture fixture =
          ScriptedHaloFixture(nowMicros: () => 100);
      addTearDown(fixture.dispose);
      final Future<DeviceDiscovery> discovered = fixture.discoveries.first;
      await fixture.startDiscovery();
      await fixture.connect(await discovered);

      final HaloLuaResult first = await fixture
          .executeAllowedLua(HaloLuaQuery.displayText, text: _payloads.first);
      final String firstLua = fixture.lastDisplayCommand!.lua;
      await fixture.executeAllowedLua(HaloLuaQuery.displayText, text: 'b');

      expect(first.truthLabel, TruthLabel.simulated);
      expect(firstLua, startsWith(_powerPrefix));
      expect(fixture.lastDisplayCommand!.lua, startsWith(_clearPrefix));
      _expectStructurallySafe(_payloads.first, lua: firstLua);
    });
  });
}

void _expectInvalid(Object? Function() build) {
  expect(
    build,
    throwsA(isA<RuntimeError>().having(
        (RuntimeError e) => e.code, 'code', RuntimeErrorCode.invalidContract)),
  );
}

/// Proves the payload cannot change Lua structure: an independent short-string
/// lexer (Lua 5.4 rules) must close the literal exactly before the fixed
/// suffix, and decoding the literal must yield the original text.
void _expectStructurallySafe(String text, {bool powerOn = false, String? lua}) {
  final String command =
      lua ?? HaloBoundedDisplay.text(text, powerOn: powerOn).lua;
  expect(HaloBoundedDisplay.isAcceptable(command), isTrue, reason: command);
  final ({String prefix, String body, String rest}) lexed = _lex(command);
  expect(<String>[_clearPrefix, '$_powerPrefix$_clearPrefix'],
      contains(lexed.prefix));
  expect(lexed.rest, '",24,168)print(1)');
  expect(_decode(lexed.body), text);
}

({String prefix, String body, String rest}) _lex(String lua) {
  final int open = lua.indexOf(_textOpen);
  expect(open, greaterThanOrEqualTo(0));
  final int start = open + _textOpen.length;
  int i = start;
  while (i < lua.length) {
    final int unit = lua.codeUnitAt(i);
    if (unit == 0x5C) {
      i += 2;
      continue;
    }
    if (unit == 0x22) {
      break;
    }
    if (unit == 0x0A || unit == 0x0D) {
      fail('Raw line break inside a Lua short string: $lua');
    }
    i++;
  }
  return (
    prefix: lua.substring(0, open),
    body: lua.substring(start, i),
    rest: lua.substring(i),
  );
}

String _decode(String body) {
  final List<int> bytes = <int>[];
  final List<int> runes = body.runes.toList();
  for (int i = 0; i < runes.length;) {
    if (runes[i] == 0x5C) {
      final int next = runes[i + 1];
      if (next == 0x5C || next == 0x22 || next == 0x27) {
        bytes.add(next);
        i += 2;
      } else {
        bytes.add(int.parse(String.fromCharCodes(runes.sublist(i + 1, i + 4))));
        i += 4;
      }
    } else {
      bytes.addAll(utf8.encode(String.fromCharCode(runes[i])));
      i++;
    }
  }
  return utf8.decode(bytes);
}
