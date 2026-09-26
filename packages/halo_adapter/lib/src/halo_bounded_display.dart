import 'dart:convert';

import 'package:persalone_contracts/persalone_contracts.dart';

/// Fixed caption positions on Halo's 256x256 round display. Coordinates are
/// 1-based, per the pinned Brilliant SDK `frame.display.text(str, x, y)`
/// reference. Callers choose a layout; they never supply coordinates or Lua.
enum HaloCaptionLayout {
  upperBand(x: 24, y: 72),
  lowerBand(x: 24, y: 168);

  const HaloCaptionLayout({required this.x, required this.y});

  final int x;
  final int y;
}

/// A display command that only [HaloBoundedDisplay] can create. The class is
/// final and its constructor library-private, so no caller can wrap
/// arbitrary Lua in this type.
final class HaloDisplayCommand {
  const HaloDisplayCommand._(this.lua);

  final String lua;
}

/// Builds the only Lua that the caption path may send to Halo:
/// `[power_save(false)]clear()text("<escaped>",x,y)print(1)` or a bare clear.
///
/// Escaping follows the SDK `uploadScript` order (`\`, quotes, newlines) and
/// additionally encodes every C0/C1 control and DEL as a three-digit decimal
/// escape, so the literal can neither close early nor span lines.
abstract final class HaloBoundedDisplay {
  static const int displaySize = 256;
  static const int maxTextBytes = 96;
  static const int maxCommandBytes = 200;

  static const String _powerOn = 'frame.display.power_save(false)';
  static const String _clearLua = 'frame.display.clear()print(1)';

  static final RegExp _textGrammar = RegExp(
    '^(?:${RegExp.escape(_powerOn)})?'
    '${RegExp.escape('frame.display.clear()')}'
    r'frame\.display\.text\("((?:[^"\x27\\\x00-\x1f\x7f\u0080-\u009f]'
    r'|\\[\\"\x27]|\\[0-9]{3})*)",([0-9]{1,3}),([0-9]{1,3})\)print\(1\)$',
  );

  static const HaloDisplayCommand clear = HaloDisplayCommand._(_clearLua);

  static HaloDisplayCommand text(
    String text, {
    HaloCaptionLayout layout = HaloCaptionLayout.lowerBand,
    required bool powerOn,
  }) {
    if (!coordinatesInRange(layout.x, layout.y)) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption layout is outside the Halo display.',
      );
    }
    if (_hasLoneSurrogate(text)) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption text is not valid Unicode.',
      );
    }
    if (utf8.encode(text).length > maxTextBytes) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption text exceeds $maxTextBytes UTF-8 bytes.',
      );
    }
    final String lua = '${powerOn ? _powerOn : ''}frame.display.clear()'
        'frame.display.text("${_escape(text)}",${layout.x},${layout.y})'
        'print(1)';
    if (utf8.encode(lua).length > maxCommandBytes) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Escaped caption exceeds $maxCommandBytes command bytes.',
      );
    }
    if (!isAcceptable(lua)) {
      throw StateError('Bounded display builder produced a malformed command.');
    }
    return HaloDisplayCommand._(lua);
  }

  /// Defense-in-depth check applied again by the transport before sending.
  static bool isAcceptable(String lua) {
    if (lua == _clearLua) {
      return true;
    }
    if (_hasLoneSurrogate(lua) || utf8.encode(lua).length > maxCommandBytes) {
      return false;
    }
    final RegExpMatch? match = _textGrammar.firstMatch(lua);
    if (match == null) {
      return false;
    }
    return coordinatesInRange(
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  static bool coordinatesInRange(int x, int y) =>
      x >= 1 && x <= displaySize && y >= 1 && y <= displaySize;

  static String _escape(String text) {
    final StringBuffer out = StringBuffer();
    for (final int rune in text.runes) {
      if (rune == 0x5C) {
        out.write(r'\\');
      } else if (rune == 0x22) {
        out.write(r'\"');
      } else if (rune == 0x27) {
        out.write(r"\'");
      } else if (rune < 0x20 ||
          rune == 0x7F ||
          (rune >= 0x80 && rune <= 0x9F)) {
        for (final int byte in utf8.encode(String.fromCharCode(rune))) {
          out.write('\\${byte.toString().padLeft(3, '0')}');
        }
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  static bool _hasLoneSurrogate(String value) {
    for (int i = 0; i < value.length; i++) {
      final int unit = value.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= value.length) {
          return true;
        }
        final int next = value.codeUnitAt(i + 1);
        if (next < 0xDC00 || next > 0xDFFF) {
          return true;
        }
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return true;
      }
    }
    return false;
  }
}
