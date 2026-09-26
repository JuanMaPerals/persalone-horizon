import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:persalone_contracts/persalone_contracts.dart';
import 'package:persalone_halo_core/persalone_halo_core.dart';

import 'api_error.dart';

/// Capabilities an app may declare (architecture §5). V1 resolves DISPLAY and
/// BUTTON on the emulator; the rest are known names, not granted features.
const List<String> knownCapabilities = <String>[
  'DISPLAY', 'MICROPHONE', 'SPEAKER', 'CAMERA', 'IMU', 'BUTTON', 'BLE', //
  'STT', 'TRANSLATION', 'TTS', 'STORAGE', 'NETWORK', 'EXTERNAL_CONNECTOR',
];

/// Button gestures a hello-display app can bind to "next page".
const List<String> buttonGestures = <String>['single', 'double', 'long'];

/// Targets V1 can run. HALO_REAL needs physical validation (V10) and is
/// refused, never silently mapped to the emulator.
const List<String> v1Targets = <String>['EMULATED'];

/// HorizonAppManifest v1 — minimal subset used by the hello-display slice.
///
/// Parsing is strict: unknown keys, wrong types and out-of-range values are
/// refused with a coded [ApiError]. V1 apps carry no host code and no device
/// Lua (`entrypoints` must be null): content is text and validated parameters
/// rendered through the caption composer and bounded display commands only.
final class HorizonAppManifest {
  const HorizonAppManifest({
    required this.appId,
    required this.version,
    required this.name,
    required this.description,
    required this.template,
    required this.requiredCapabilities,
    required this.optionalCapabilities,
    required this.deviceTargets,
    required this.caption,
    required this.advanceOn,
    required this.tests,
  });

  static const int schemaVersion = 1;
  static final RegExp _appId = RegExp(r'^[a-z0-9][a-z0-9.-]{2,63}$');
  static final RegExp _semver = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
  static const List<String> _keys = <String>[
    'schemaVersion', 'appId', 'version', 'name', 'description', 'template', //
    'entrypoints', 'capabilities', 'deviceTargets', 'permissions', 'content',
    'tests',
  ];

  final String appId;
  final String version;
  final String name;
  final String description;
  final String template;
  final List<String> requiredCapabilities;
  final List<String> optionalCapabilities;
  final List<String> deviceTargets;
  final String caption;
  final String advanceOn;
  final List<String> tests;

  HaloCaptionComposition get composition => HaloCaptionComposer.compose(caption);

  static HorizonAppManifest parse(Object? raw) {
    final Map<String, Object?> m = _object(raw, 'manifest');
    _exactKeys(m, _keys, 'manifest');
    if (m['schemaVersion'] != schemaVersion) {
      throw const ApiError(422, 'manifestSchemaUnsupported',
          <String, Object>{'supported': schemaVersion});
    }
    final String appId = _string(m['appId'], 'appId', max: 64);
    if (!_appId.hasMatch(appId)) _invalid('appId');
    final String version = _string(m['version'], 'version', max: 14);
    if (!_semver.hasMatch(version)) _invalid('version');
    final String name = _text(m['name'], 'name', max: 60, min: 1);
    final String description = _text(m['description'], 'description', max: 200);
    final String template = _string(m['template'], 'template', max: 40);
    if (template != 'hello-display') _invalid('template');

    final Map<String, Object?> entry = _object(m['entrypoints'], 'entrypoints');
    _exactKeys(entry, const <String>['host', 'deviceLua'], 'entrypoints');
    if (entry['host'] != null || entry['deviceLua'] != null) {
      // Architecture §9: no host code or free Lua until OS isolation is proven.
      throw const ApiError(422, 'codeEntrypointsNotSupported');
    }

    final Map<String, Object?> caps = _object(m['capabilities'], 'capabilities');
    _exactKeys(caps, const <String>['required', 'optional'], 'capabilities');
    final List<String> required = _names(caps['required'], 'capabilities.required');
    final List<String> optional = _names(caps['optional'], 'capabilities.optional');
    for (final String c in <String>[...required, ...optional]) {
      if (!knownCapabilities.contains(c)) {
        throw ApiError(422, 'capabilityUnknown', <String, Object>{'capability': c});
      }
    }
    if (!required.contains('DISPLAY') || !required.contains('BUTTON')) {
      throw const ApiError(422, 'capabilityMissing',
          <String, Object>{'required': 'DISPLAY,BUTTON'});
    }
    for (final String c in required) {
      if (c != 'DISPLAY' && c != 'BUTTON') {
        // A required capability V1 cannot grant blocks the app; it is not
        // silently dropped.
        throw ApiError(422, 'capabilityNotSupportedInV1',
            <String, Object>{'capability': c});
      }
    }

    final List<String> targets = _names(m['deviceTargets'], 'deviceTargets');
    if (targets.isEmpty) _invalid('deviceTargets');
    for (final String t in targets) {
      if (!v1Targets.contains(t)) {
        throw ApiError(422, 'targetNotAvailable', <String, Object>{'target': t});
      }
    }
    final Map<String, Object?> permissions = _object(m['permissions'], 'permissions');
    if (permissions.isNotEmpty) {
      throw const ApiError(422, 'permissionsNotSupportedInV1');
    }

    final Map<String, Object?> content = _object(m['content'], 'content');
    _exactKeys(content, const <String>['caption', 'advanceOn'], 'content');
    final String caption = validateCaption(content['caption']);
    final String advanceOn = _string(content['advanceOn'], 'content.advanceOn', max: 8);
    if (!buttonGestures.contains(advanceOn)) _invalid('content.advanceOn');

    final List<String> tests = _names(m['tests'], 'tests');
    if (tests.length != 1 || tests.single != 'hello-display.default') {
      _invalid('tests');
    }
    return HorizonAppManifest(
      appId: appId,
      version: version,
      name: name,
      description: description,
      template: template,
      requiredCapabilities: required,
      optionalCapabilities: optional,
      deviceTargets: targets,
      caption: caption,
      advanceOn: advanceOn,
      tests: tests,
    );
  }

  /// Caption text is data rendered by the composer, never code. It must be a
  /// string the composer accepts (length, valid Unicode) and not blank.
  static String validateCaption(Object? raw) {
    if (raw is! String) _invalid('content.caption');
    try {
      final HaloCaptionComposition c = HaloCaptionComposer.compose(raw);
      if (c.isEmpty) throw const ApiError(422, 'captionEmpty');
    } on RuntimeError catch (e) {
      throw ApiError(422, 'captionRejected',
          <String, Object>{'reason': e.code.name, 'maxChars': HaloCaptionComposer.maxInputChars});
    }
    return raw;
  }

  HorizonAppManifest withContent({String? caption, String? advanceOn}) {
    final Map<String, Object?> json = toJson();
    final Map<String, Object?> content =
        Map<String, Object?>.from(json['content']! as Map<String, Object?>);
    if (caption != null) content['caption'] = caption;
    if (advanceOn != null) content['advanceOn'] = advanceOn;
    json['content'] = content;
    return parse(json);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'appId': appId,
        'version': version,
        'name': name,
        'description': description,
        'template': template,
        'entrypoints': <String, Object?>{'host': null, 'deviceLua': null},
        'capabilities': <String, Object?>{
          'required': requiredCapabilities,
          'optional': optionalCapabilities,
        },
        'deviceTargets': deviceTargets,
        'permissions': <String, Object?>{},
        'content': <String, Object?>{'caption': caption, 'advanceOn': advanceOn},
        'tests': tests,
      };

  /// Canonical JSON (sorted keys, no whitespace) — the input of [digest].
  String canonicalJson() => canonicalize(toJson());

  /// sha256 of the canonical manifest; binds runs, results and packages.
  String get digest => sha256.convert(utf8.encode(canonicalJson())).toString();

  /// Summary of how the HUD will show the caption, including the glyph limit.
  Map<String, Object?> preview() {
    final HaloCaptionComposition c = composition;
    return <String, Object?>{
      'pageCount': c.pageCount,
      'pages': <List<String>>[
        for (final List<HaloTextLine> page in c.pages)
          <String>[for (final HaloTextLine l in page) l.text],
      ],
      'normalisedChars': c.normalisedText.length,
      'foldedGlyphs': c.foldedChars,
      'replacedGlyphs': c.unrenderableChars,
      'noLoss': c.reconstructed == c.normalisedText,
      'maxInputChars': HaloCaptionComposer.maxInputChars,
    };
  }

  static HorizonAppManifest helloDisplay({
    required String appId,
    required String name,
  }) =>
      parse(<String, Object?>{
        'schemaVersion': schemaVersion,
        'appId': appId,
        'version': '0.1.0',
        'name': name,
        'description': 'Shows a caption on Halo; a button press shows the next page.',
        'template': 'hello-display',
        'entrypoints': <String, Object?>{'host': null, 'deviceLua': null},
        'capabilities': <String, Object?>{
          'required': <String>['DISPLAY', 'BUTTON'],
          'optional': <String>[],
        },
        'deviceTargets': <String>['EMULATED'],
        'permissions': <String, Object?>{},
        'content': <String, Object?>{'caption': 'Hello Halo', 'advanceOn': 'single'},
        'tests': <String>['hello-display.default'],
      });

  static Map<String, Object?> _object(Object? raw, String field) {
    if (raw is! Map) _invalid(field);
    return raw.map((Object? k, Object? v) {
      if (k is! String) _invalid(field);
      return MapEntry<String, Object?>(k, v);
    });
  }

  static void _exactKeys(Map<String, Object?> m, List<String> keys, String field) {
    for (final String k in m.keys) {
      if (!keys.contains(k)) {
        throw ApiError(422, 'manifestUnknownField', <String, Object>{'field': '$field.$k'});
      }
    }
    for (final String k in keys) {
      if (!m.containsKey(k)) {
        throw ApiError(422, 'manifestMissingField', <String, Object>{'field': '$field.$k'});
      }
    }
  }

  static String _string(Object? raw, String field, {required int max}) {
    if (raw is! String || raw.isEmpty || raw.length > max) _invalid(field);
    return raw;
  }

  /// Human text: bounded, no control characters.
  static String _text(Object? raw, String field, {required int max, int min = 0}) {
    if (raw is! String || raw.length < min || raw.length > max ||
        raw.runes.any((int r) => r < 0x20 || r == 0x7F)) {
      _invalid(field);
    }
    return raw;
  }

  static List<String> _names(Object? raw, String field) {
    if (raw is! List || raw.length > 16) _invalid(field);
    final List<String> out = <String>[];
    for (final Object? v in raw) {
      if (v is! String || v.isEmpty || v.length > 40 || out.contains(v)) _invalid(field);
      out.add(v);
    }
    return out;
  }

  static Never _invalid(String field) =>
      throw ApiError(422, 'manifestInvalidField', <String, Object>{'field': field});
}

/// Deterministic JSON: object keys sorted, no insignificant whitespace.
String canonicalize(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((String k) => '${jsonEncode(k)}:${canonicalize(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonicalize).join(',')}]';
  return jsonEncode(value);
}
