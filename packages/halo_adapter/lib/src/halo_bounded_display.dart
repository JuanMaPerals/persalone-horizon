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

/// One positioned caption line (1-based coordinates, top of the glyph box).
/// [continues] is true when the line ends with a hyphen inserted to break a
/// word that did not fit; the next line holds the rest of that word.
final class HaloTextLine {
  const HaloTextLine(this.text, this.x, this.y, {this.continues = false});

  final String text;
  final int x;
  final int y;
  final bool continues;
}

/// A display command that only [HaloBoundedDisplay] can create. The class is
/// final and its constructor library-private, so no caller can wrap
/// arbitrary Lua in this type.
final class HaloDisplayCommand {
  const HaloDisplayCommand._(this.lua);

  final String lua;
}

/// Builds the only Lua that the caption path may send to Halo: a page
/// `local d=frame.display [d.power_save(false)]d.clear()` followed by one to
/// three `d.text("escaped",x,y)` calls and `print(1)`, drawn atomically, or a
/// bare clear.
///
/// Escaping follows the SDK `uploadScript` order (`\`, quotes, newlines) and
/// additionally encodes every C0/C1 control and DEL as a three-digit decimal
/// escape, so the literal can neither close early nor span lines.
abstract final class HaloBoundedDisplay {
  static const int displaySize = 256;
  static const int maxTextBytes = 96;
  static const int maxCommandBytes = 200;

  static const int maxPageLines = 3;
  static const String pagePrefix = 'local d=frame.display ';
  static const String _powerOn = 'd.power_save(false)';
  static const String _clearLua = 'frame.display.clear()print(1)';
  static const String _literal =
      r'"(?:[^"\x27\\\x00-\x1f\x7f\u0080-\u009f]|\\[\\"\x27]|\\[0-9]{3})*"';

  static final RegExp _pageGrammar = RegExp(
    '^${RegExp.escape(pagePrefix)}(?:${RegExp.escape(_powerOn)})?'
    r'd\.clear\(\)((?:d\.text\('
    '$_literal'
    r',[0-9]{1,3},[0-9]{1,3}\)){1,3})'
    r'print\(1\)$',
  );
  static final RegExp _lineCall =
      RegExp(r'd\.text\(' '$_literal' r',([0-9]{1,3}),([0-9]{1,3})\)');

  static const HaloDisplayCommand clear = HaloDisplayCommand._(_clearLua);

  /// Single line at a fixed layout position (one-line page).
  static HaloDisplayCommand text(
    String text, {
    HaloCaptionLayout layout = HaloCaptionLayout.lowerBand,
    required bool powerOn,
  }) =>
      page(<HaloTextLine>[HaloTextLine(text, layout.x, layout.y)],
          powerOn: powerOn);

  /// One caption page: clears the display and draws 1..[maxPageLines] lines
  /// in a single command, so a page is never shown half-drawn.
  static HaloDisplayCommand page(
    List<HaloTextLine> lines, {
    required bool powerOn,
  }) {
    if (lines.isEmpty || lines.length > maxPageLines) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'A caption page holds 1 to $maxPageLines lines.',
      );
    }
    final StringBuffer lua = StringBuffer(pagePrefix);
    if (powerOn) lua.write(_powerOn);
    lua.write('d.clear()');
    for (final HaloTextLine line in lines) {
      if (!coordinatesInRange(line.x, line.y)) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'Caption line is outside the Halo display.',
        );
      }
      if (_hasLoneSurrogate(line.text)) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'Caption text is not valid Unicode.',
        );
      }
      if (utf8.encode(line.text).length > maxTextBytes) {
        throw const RuntimeError(
          RuntimeErrorCode.invalidContract,
          'Caption line exceeds $maxTextBytes UTF-8 bytes.',
        );
      }
      lua.write('d.text("${_escape(line.text)}",${line.x},${line.y})');
    }
    lua.write('print(1)');
    final String command = lua.toString();
    if (utf8.encode(command).length > maxCommandBytes) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Escaped caption page exceeds $maxCommandBytes command bytes.',
      );
    }
    if (!isAcceptable(command)) {
      throw StateError('Bounded display builder produced a malformed command.');
    }
    return HaloDisplayCommand._(command);
  }

  /// Bytes a page would take; lets the composer paginate within the budget.
  static int pageBytes(List<HaloTextLine> lines, {required bool powerOn}) {
    int bytes = pagePrefix.length +
        (powerOn ? _powerOn.length : 0) +
        'd.clear()'.length +
        'print(1)'.length;
    for (final HaloTextLine line in lines) {
      bytes += 'd.text("",,)'.length +
          utf8.encode(_escape(line.text)).length +
          '${line.x}'.length +
          '${line.y}'.length;
    }
    return bytes;
  }

  /// Defense-in-depth check applied again by the transport before sending.
  static bool isAcceptable(String lua) {
    if (lua == _clearLua) {
      return true;
    }
    if (_hasLoneSurrogate(lua) || utf8.encode(lua).length > maxCommandBytes) {
      return false;
    }
    final RegExpMatch? page = _pageGrammar.firstMatch(lua);
    if (page == null) {
      return false;
    }
    final List<RegExpMatch> calls =
        _lineCall.allMatches(page.group(1)!).toList();
    return calls.isNotEmpty &&
        calls.length <= maxPageLines &&
        calls.every((RegExpMatch call) => coordinatesInRange(
            int.parse(call.group(1)!), int.parse(call.group(2)!)));
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
