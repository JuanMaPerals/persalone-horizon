import 'dart:math';

import 'package:persalone_contracts/persalone_contracts.dart';

import 'halo_bounded_display.dart';

/// Lays translated text out for Halo's 256x256 round display.
///
/// State: EMULATED_PREPARED. Layout is verified on the official emulator only.
/// UNICODE LIMIT: the device fonts draw printable ASCII only. Characters
/// outside it are degraded, never supported: accented Latin is folded to ASCII
/// and everything else (CJK, Cyrillic, Arabic, emoji...) becomes `?`. The
/// composition counts both, and the caption delivery reports them.
///
/// Metrics come from the official halo-emulator's port of the firmware
/// `canvas_draw_char` (pinned SDK 462dff4): the only fonts (Dogica, Dogica
/// Bold) cover printable ASCII 0x20-0x7E, are monospaced with an 8 px
/// advance and a 10 px line advance, and silently skip any other code point.
/// The composer therefore folds common Latin diacritics to ASCII and
/// replaces anything else with `?`, and reports both counts: nothing is lost
/// silently. Lines are word-wrapped to the chord of a circle with a safe
/// margin, centred, and grouped into pages of up to three lines that fit the
/// bounded command budget. Every character of the normalised text appears on
/// some page; a word longer than a line is split with a hyphen.
abstract final class HaloCaptionComposer {
  static const int glyphAdvance = 8;
  static const int glyphRows = 9;
  static const double safeRadius = 120;
  static const List<int> lineTops = <int>[146, 156, 166];
  static const int maxInputChars = 400;
  static const int maxPages = 8;

  static List<int> get lineCapacities => <int>[
        for (final int top in lineTops) _capacity(top),
      ];

  static HaloCaptionComposition compose(String text) {
    final _Normalised normalised = _normalise(text);
    if (normalised.text.length > maxInputChars) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption exceeds $maxInputChars characters.',
      );
    }
    final List<List<HaloTextLine>> pages = <List<HaloTextLine>>[];
    if (normalised.text.isNotEmpty) {
      _layout(normalised.text, pages);
    }
    if (pages.length > maxPages) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption needs more than $maxPages pages.',
      );
    }
    return HaloCaptionComposition._(
      pages: List<List<HaloTextLine>>.unmodifiable(pages),
      normalisedText: normalised.text,
      foldedChars: normalised.folded,
      unrenderableChars: normalised.unrenderable,
    );
  }

  static int _capacity(int top) {
    // Rows covered by a glyph box: top-1 .. top-1+glyphRows-1 (0-based).
    final double centre = 127.5;
    final double dy =
        max((top - 1 - centre).abs(), (top - 1 + glyphRows - 1 - centre).abs());
    final double half = sqrt(safeRadius * safeRadius - dy * dy);
    return (2 * half / glyphAdvance).floor();
  }

  static HaloTextLine _line(String text, int index, {bool continues = false}) {
    final int width = text.length * glyphAdvance;
    final int x = max(1, 128 - width ~/ 2 + 1);
    return HaloTextLine(text, x, lineTops[index], continues: continues);
  }

  static void _layout(String text, List<List<HaloTextLine>> pages) {
    final List<int> caps = lineCapacities;
    final List<String> queue = text.split(' ');
    List<HaloTextLine> page = <HaloTextLine>[];
    String line = '';

    void commit(String value, {bool continues = false}) {
      HaloTextLine positioned = _line(value, page.length, continues: continues);
      if (page.isNotEmpty &&
          HaloBoundedDisplay.pageBytes(<HaloTextLine>[...page, positioned],
                  powerOn: true) >
              HaloBoundedDisplay.maxCommandBytes) {
        // Over the command budget: this line opens the next page (row 0 has
        // the widest chord, so a line built for a lower row always fits).
        pages.add(page);
        page = <HaloTextLine>[];
        positioned = _line(value, 0, continues: continues);
      }
      page.add(positioned);
      if (page.length == lineTops.length) {
        pages.add(page);
        page = <HaloTextLine>[];
      }
    }

    int i = 0;
    while (i < queue.length) {
      final String word = queue[i];
      final int cap = caps[page.length];
      if (line.isEmpty && word.length > cap) {
        // A word wider than the line: split it with a visible hyphen.
        final int take = max(1, cap - 1);
        commit('${word.substring(0, take)}-', continues: true);
        queue[i] = word.substring(take);
        continue;
      }
      final String candidate = line.isEmpty ? word : '$line $word';
      if (candidate.length <= cap) {
        line = candidate;
        i++;
      } else {
        commit(line);
        line = '';
      }
    }
    if (line.isNotEmpty) commit(line);
    if (page.isNotEmpty) pages.add(page);
  }

  static const Map<String, String> _fold = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', //
    'Á': 'A', 'À': 'A', 'Â': 'A', 'Ä': 'A', 'Ã': 'A', 'Å': 'A', //
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
    'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E', //
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', //
    'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I', //
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', //
    'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Ö': 'O', 'Õ': 'O', 'Ø': 'O', //
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', //
    'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U', //
    'ñ': 'n', 'Ñ': 'N', 'ç': 'c', 'Ç': 'C', 'ý': 'y', 'ÿ': 'y', 'Ý': 'Y', //
    'ß': 'ss', 'æ': 'ae', 'Æ': 'AE', 'œ': 'oe', 'Œ': 'OE', //
    '¿': '?', '¡': '!', '«': '"', '»': '"', '“': '"', '”': '"', '„': '"', //
    '‘': "'", '’': "'", '‚': "'", '–': '-', '—': '-', '…': '...', //
    '€': 'EUR', '·': '.', ' ': ' ',
  };

  static _Normalised _normalise(String text) {
    if (_hasLoneSurrogate(text)) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Caption text is not valid Unicode.',
      );
    }
    final StringBuffer out = StringBuffer();
    int folded = 0;
    int unrenderable = 0;
    for (final int rune in text.runes) {
      final String char = String.fromCharCode(rune);
      if (rune >= 0x20 && rune <= 0x7E) {
        out.write(char);
      } else if (rune < 0x20 ||
          rune == 0x7F ||
          (rune >= 0x80 && rune <= 0x9F) ||
          rune == 0x2028 ||
          rune == 0x2029) {
        out.write(' ');
      } else if ((rune >= 0x200B && rune <= 0x200F) ||
          (rune >= 0x202A && rune <= 0x202E) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          rune == 0xFEFF) {
        // Zero-width and bidi format controls have no glyph; dropping them
        // cannot change what the reader sees.
      } else if (_fold.containsKey(char)) {
        out.write(_fold[char]);
        folded++;
      } else {
        out.write('?');
        unrenderable++;
      }
    }
    final String collapsed =
        out.toString().replaceAll(RegExp(r' {2,}'), ' ').trim();
    return _Normalised(collapsed, folded, unrenderable);
  }

  static bool _hasLoneSurrogate(String value) {
    for (int i = 0; i < value.length; i++) {
      final int unit = value.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= value.length) return true;
        final int next = value.codeUnitAt(i + 1);
        if (next < 0xDC00 || next > 0xDFFF) return true;
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return true;
      }
    }
    return false;
  }
}

final class _Normalised {
  const _Normalised(this.text, this.folded, this.unrenderable);
  final String text;
  final int folded;
  final int unrenderable;
}

/// Ordered caption pages. Page navigation on the device is not wired yet:
/// the caption path shows page 1 and reports [pageCount].
final class HaloCaptionComposition {
  const HaloCaptionComposition._({
    required this.pages,
    required this.normalisedText,
    required this.foldedChars,
    required this.unrenderableChars,
  });

  final List<List<HaloTextLine>> pages;
  final String normalisedText;
  final int foldedChars;
  final int unrenderableChars;

  int get pageCount => pages.length;

  /// Result value of a displayText query: `page:<shown>/<total>`, followed by
  /// `;folded:<n>` and/or `;replaced:<n>` when glyphs were degraded.
  static String resultValue(HaloCaptionComposition composition) {
    final StringBuffer value = StringBuffer(composition.isEmpty
        ? 'page:0/0'
        : 'page:1/${composition.pageCount}');
    if (composition.foldedChars > 0) {
      value.write(';folded:${composition.foldedChars}');
    }
    if (composition.unrenderableChars > 0) {
      value.write(';replaced:${composition.unrenderableChars}');
    }
    return value.toString();
  }
  bool get isEmpty => pages.isEmpty;

  HaloDisplayCommand command(int page, {required bool powerOn}) =>
      HaloBoundedDisplay.page(pages[page], powerOn: powerOn);

  /// Text reconstructed from the pages (hyphenated breaks re-joined); equals
  /// [normalisedText] when nothing was dropped.
  String get reconstructed {
    final StringBuffer out = StringBuffer();
    bool joinNext = false;
    for (final List<HaloTextLine> page in pages) {
      for (final HaloTextLine line in page) {
        if (out.isNotEmpty && !joinNext) out.write(' ');
        out.write(line.continues
            ? line.text.substring(0, line.text.length - 1)
            : line.text);
        joinNext = line.continues;
      }
    }
    return out.toString();
  }
}
