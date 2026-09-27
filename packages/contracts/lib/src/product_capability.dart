import 'caption.dart';
import 'runtime_event.dart';

/// Lifecycle of a product capability.
///
/// Only [verified] counts toward readiness, and only an [EvidenceRecord] for
/// that capability and environment makes it verified. Code that exists, an
/// import that succeeds, an endpoint, a UI or a granted permission can reach
/// at most [available]. [active] and [degraded] are runtime states: they
/// never appear in the static manifest.
enum CapabilityStatus {
  /// No code for it.
  unavailable,

  /// Code exists but no app composes it.
  installed,

  /// Composed, but off unless a build or setting enables it.
  dormant,

  /// Composed and reachable in the default build.
  available,

  /// Running now (runtime only).
  active,

  /// Running with reduced function (runtime only).
  degraded,

  /// A recorded measurement proves it in a given environment.
  verified,
}

/// What the product claims it can do, at the level a person would test.
enum ProductCapability {
  /// STT -> translation -> speech on the phone with the real providers.
  liveTranslation,

  /// Turn latency, including the audible-output stages.
  speechLatency,

  /// Self-echo detection and the AEC capture-source A/B.
  echoControl,

  /// Stop and Panic: microphone and speech stop, the display clears.
  stopPanic,

  /// Bounded Lua caption rendering on the Halo display.
  captionRendering,

  /// A translated turn reaching the Halo display.
  translationToDisplay,

  /// BLE discovery/connection to a Halo, behind the runtime permissions.
  haloConnection,

  /// Halo button gestures reaching the app.
  haloButton,

  /// Halo microphone/speaker (LC3) audio.
  haloAudio,

  /// Battery and identity read from the Halo.
  deviceTelemetry,

  /// The redacted runtime event stream served to Studio.
  runtimeStream,

  /// Studio's Hello Halo journey through the Companion.
  studioHelloHalo,
}

/// One catalogue entry: the implementation state (never [CapabilityStatus.
/// verified], [active] or [degraded]) and the product targets it must be
/// verified in.
final class CapabilityDeclaration {
  const CapabilityDeclaration({
    required this.capability,
    required this.implementation,
    required this.requiredFor,
    required this.where,
  });

  final ProductCapability capability;
  final CapabilityStatus implementation;
  final Set<ExecutionEnvironment> requiredFor;

  /// Where it is composed or why it is not (short, for reviewers).
  final String where;
}

/// The catalogue is declared by hand and reviewed with the code; evidence is
/// not: it comes only from [EvidenceRecord]s.
abstract final class ProductCapabilities {
  static const Set<ExecutionEnvironment> androidReal = <ExecutionEnvironment>{
    ExecutionEnvironment.androidReal,
  };
  static const Set<ExecutionEnvironment> haloReal = <ExecutionEnvironment>{
    ExecutionEnvironment.haloReal,
  };

  static const List<CapabilityDeclaration> catalogue = <CapabilityDeclaration>[
    CapabilityDeclaration(
      capability: ProductCapability.liveTranslation,
      implementation: CapabilityStatus.available,
      requiredFor: androidReal,
      where: 'apps/mobile main.dart: Android STT, ML Kit, Android TTS',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.speechLatency,
      implementation: CapabilityStatus.available,
      requiredFor: androidReal,
      where: 'runtime latency samples; audible stages via MeasuredTtsOutput',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.echoControl,
      implementation: CapabilityStatus.available,
      requiredFor: androidReal,
      where: 'selfEchoSuspected diagnostic; capture source A/B in debug builds',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.stopPanic,
      implementation: CapabilityStatus.available,
      requiredFor: <ExecutionEnvironment>{
        ExecutionEnvironment.androidReal,
        ExecutionEnvironment.haloReal,
      },
      where: 'HorizonRuntimeController; phone buttons',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.captionRendering,
      implementation: CapabilityStatus.dormant,
      requiredFor: haloReal,
      where: 'HaloCaptionComposer via HaloCaptionPath (HORIZON_HALO_CAPTIONS)',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.translationToDisplay,
      implementation: CapabilityStatus.dormant,
      requiredFor: haloReal,
      where: 'HaloCaptionPath (HORIZON_HALO_CAPTIONS)',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.haloConnection,
      implementation: CapabilityStatus.dormant,
      requiredFor: haloReal,
      where: 'Brilliant BLE transport + BLE permission gate '
          '(HORIZON_HALO_CAPTIONS)',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.haloButton,
      implementation: CapabilityStatus.installed,
      requiredFor: <ExecutionEnvironment>{},
      where: 'Companion emulator path only; not composed in the phone app',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.haloAudio,
      implementation: CapabilityStatus.installed,
      requiredFor: <ExecutionEnvironment>{},
      where: 'halo_real_audio_adapters; unwired, device Lua app not deployed',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.deviceTelemetry,
      implementation: CapabilityStatus.installed,
      requiredFor: <ExecutionEnvironment>{},
      where: 'HaloDeviceAdapter battery/identity; not shown by any app',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.runtimeStream,
      implementation: CapabilityStatus.dormant,
      requiredFor: <ExecutionEnvironment>{},
      where: 'RuntimeEventServer in validation builds (HORIZON_VALIDATION_LOG)',
    ),
    CapabilityDeclaration(
      capability: ProductCapability.studioHelloHalo,
      implementation: CapabilityStatus.available,
      requiredFor: <ExecutionEnvironment>{},
      where: 'Companion API + Studio Hello Halo panel (emulator target)',
    ),
  ];
}

final class EvidenceError implements Exception {
  const EvidenceError(this.message);

  final String message;

  @override
  String toString() => 'EvidenceError: $message';
}

/// One recorded measurement. It proves [capability] in [environment] for the
/// source tree [tree] (the commit may be squashed away; the tree is not), and
/// names the artifact by its sha256 so anyone holding it can check it.
final class EvidenceRecord {
  const EvidenceRecord({
    required this.capability,
    required this.environment,
    required this.commit,
    required this.tree,
    required this.method,
    required this.artifactName,
    required this.artifactSha256,
    required this.artifactSource,
    required this.recordedAt,
    required this.recorder,
  });

  final ProductCapability capability;
  final ExecutionEnvironment environment;
  final String commit;
  final String tree;
  final String method;
  final String artifactName;
  final String artifactSha256;
  final String artifactSource;
  final String recordedAt;
  final String recorder;

  static const Set<String> _keys = <String>{
    'capability',
    'environment',
    'commit',
    'tree',
    'method',
    'artifact',
    'recordedAt',
    'recorder',
  };
  static final RegExp _sha1 = RegExp(r'^[0-9a-f]{40}$');
  static final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static final RegExp _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final RegExp _text = RegExp(r'^[^\n\r]{3,200}$');

  /// Strict: exactly the known fields; a simulation is never verification.
  static EvidenceRecord parse(Object? raw) {
    if (raw is! Map || raw.length != _keys.length || !raw.keys.every(_keys.contains)) {
      throw const EvidenceError('record must have exactly the v1 fields');
    }
    final ProductCapability? capability = ProductCapability.values
        .where((ProductCapability c) => c.name == raw['capability'])
        .firstOrNull;
    final ExecutionEnvironment? environment = ExecutionEnvironment.values
        .where((ExecutionEnvironment e) =>
            RuntimeEvent.environmentWire(e) == raw['environment'])
        .firstOrNull;
    final Object? artifact = raw['artifact'];
    if (capability == null) throw const EvidenceError('unknown capability');
    if (environment == null) throw const EvidenceError('unknown environment');
    if (environment == ExecutionEnvironment.simulated) {
      throw const EvidenceError('a simulation is not verification');
    }
    if (artifact is! Map ||
        artifact.length != 3 ||
        artifact['name'] is! String ||
        artifact['sha256'] is! String ||
        artifact['source'] is! String) {
      throw const EvidenceError('artifact needs exactly name, sha256, source');
    }
    String field(Map<Object?, Object?> map, String key, RegExp shape) {
      final Object? value = map[key];
      if (value is! String || !shape.hasMatch(value)) {
        throw EvidenceError('invalid $key');
      }
      return value;
    }

    final CapabilityDeclaration? declared = ProductCapabilities.catalogue
        .where((CapabilityDeclaration d) => d.capability == capability)
        .firstOrNull;
    if (declared == null ||
        declared.implementation == CapabilityStatus.unavailable) {
      throw const EvidenceError('cannot verify a capability without code');
    }
    return EvidenceRecord(
      capability: capability,
      environment: environment,
      commit: field(raw, 'commit', _sha1),
      tree: field(raw, 'tree', _sha1),
      method: field(raw, 'method', _text),
      artifactName: field(artifact, 'name', _text),
      artifactSha256: field(artifact, 'sha256', _sha256),
      artifactSource: field(artifact, 'source', _text),
      recordedAt: field(raw, 'recordedAt', _date),
      recorder: field(raw, 'recorder', _text),
    );
  }
}

/// Builds the machine-readable manifest (`horizon.capabilities.v1`) from the
/// catalogue and the evidence. Readiness is computed, never declared.
abstract final class ProductCapabilityManifest {
  static const String schema = 'horizon.capabilities.v1';

  /// The product targets readiness is computed for.
  static const List<ExecutionEnvironment> targets = <ExecutionEnvironment>[
    ExecutionEnvironment.androidReal,
    ExecutionEnvironment.haloReal,
  ];

  static Map<String, Object?> build(List<EvidenceRecord> evidence) {
    for (final CapabilityDeclaration d in ProductCapabilities.catalogue) {
      if (const <CapabilityStatus>{
        CapabilityStatus.verified,
        CapabilityStatus.active,
        CapabilityStatus.degraded,
      }.contains(d.implementation)) {
        throw EvidenceError(
            '${d.capability.name}: implementation cannot be ${d.implementation.name}');
      }
    }
    String wire(ExecutionEnvironment e) => RuntimeEvent.environmentWire(e);
    bool verifiedIn(ProductCapability c, ExecutionEnvironment e) =>
        evidence.any((EvidenceRecord r) => r.capability == c && r.environment == e);

    final List<Map<String, Object?>> capabilities = <Map<String, Object?>>[
      for (final CapabilityDeclaration d in ProductCapabilities.catalogue)
        <String, Object?>{
          'id': d.capability.name,
          'implementation': d.implementation.name,
          'requiredFor': <String>[
            for (final ExecutionEnvironment e in ExecutionEnvironment.values)
              if (d.requiredFor.contains(e)) wire(e),
          ],
          'where': d.where,
          'status': <String, String>{
            for (final ExecutionEnvironment e in ExecutionEnvironment.values)
              if (e != ExecutionEnvironment.simulated)
                wire(e): verifiedIn(d.capability, e)
                    ? CapabilityStatus.verified.name
                    : d.implementation.name,
          },
          'evidence': <Map<String, Object?>>[
            for (final EvidenceRecord r in evidence)
              if (r.capability == d.capability)
                <String, Object?>{
                  'environment': wire(r.environment),
                  'tree': r.tree,
                  'artifactSha256': r.artifactSha256,
                  'recordedAt': r.recordedAt,
                },
          ],
        },
    ];

    int required = 0;
    int verified = 0;
    final Map<String, Object?> readiness = <String, Object?>{};
    for (final ExecutionEnvironment target in targets) {
      final List<ProductCapability> needed = <ProductCapability>[
        for (final CapabilityDeclaration d in ProductCapabilities.catalogue)
          if (d.requiredFor.contains(target)) d.capability,
      ];
      final List<ProductCapability> done = <ProductCapability>[
        for (final ProductCapability c in needed)
          if (verifiedIn(c, target)) c,
      ];
      required += needed.length;
      verified += done.length;
      readiness[wire(target)] = <String, Object?>{
        'required': needed.length,
        'verified': done.length,
        'missing': <String>[
          for (final ProductCapability c in needed)
            if (!done.contains(c)) c.name,
        ],
      };
    }

    return <String, Object?>{
      'schema': schema,
      'rule': 'Only a recorded measurement (evidence/registry.v1.json) makes '
          'a capability verified; code, imports, endpoints, UI or permissions '
          'never do.',
      'capabilities': capabilities,
      'readiness': readiness,
      'productFinished': <String, Object?>{
        'verified': verified,
        'required': required,
        'finished': required > 0 && verified == required,
      },
    };
  }
}
