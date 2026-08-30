import 'dart:async';

import 'package:flutter/services.dart';
import 'package:persalone_contracts/persalone_contracts.dart';

import 'android_live_translation_bridge.dart';

/// On-device Android ML Kit implementation of [TextTranslationProvider].
/// Downloading an offline model is denied unless the session consent permits it.
final class MlKitOnDeviceTranslatorProvider implements TextTranslationProvider {
  MlKitOnDeviceTranslatorProvider({
    AndroidLiveTranslationBridge? bridge,
    DateTime Function()? clock,
  })  : _bridge = bridge ?? MethodChannelAndroidLiveTranslationBridge(),
        _clock = clock ?? DateTime.now;

  final AndroidLiveTranslationBridge _bridge;
  final DateTime Function() _clock;
  final StreamController<ProviderSnapshot> _snapshots =
      StreamController<ProviderSnapshot>.broadcast();
  final StreamController<LiveTranslationDiagnostic> _diagnostics =
      StreamController<LiveTranslationDiagnostic>.broadcast();
  LiveTranslationConfig? _config;
  bool _disposed = false;

  @override
  String get providerId => 'android-mlkit-on-device-translation';

  @override
  String get sourceRevision => 'com.google.mlkit:translate:17.0.3';

  @override
  Stream<ProviderSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<LiveTranslationDiagnostic> get diagnostics => _diagnostics.stream;

  int get _nowMicros => _clock().microsecondsSinceEpoch;

  @override
  Future<void> prepare(LiveTranslationConfig config) async {
    _ensureNotDisposed();
    if (!config.consent.localProcessingAllowed) {
      throw const RuntimeError(
        RuntimeErrorCode.consentRequired,
        'On-device translation requires explicit local processing consent.',
      );
    }
    _config = config;
    _emitSnapshot(ProviderReadiness.preparing, TruthLabel.prepared);
    try {
      final result = await _bridge.prepareTranslation(
        sourceLocale: config.sourceLocale,
        targetLocale: config.targetLocale,
        allowModelDownload: config.consent.modelDownloadAllowed,
      );
      if (result['modelReady'] != true) {
        throw const RuntimeError(
          RuntimeErrorCode.translationModelUnavailable,
          'The requested on-device translation model is unavailable.',
          retryable: true,
        );
      }
      _emitSnapshot(ProviderReadiness.ready, TruthLabel.prepared);
      _emitDiagnostic(LiveTranslationDiagnosticCode.providerReady);
    } on PlatformException catch (error) {
      _emitUnavailable();
      throw RuntimeError(
        RuntimeErrorCode.translationModelUnavailable,
        'Android translation model preparation failed: ${error.code}.',
        retryable: true,
      );
    } on RuntimeError {
      _emitUnavailable();
      rethrow;
    }
  }

  @override
  Future<TranslationSegment> translate(
      TranscriptSegment finalTranscript) async {
    final config = _config;
    if (config == null || !_matches(finalTranscript.session, config.session)) {
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'Translation rejected an inactive transcript session.',
      );
    }
    if (finalTranscript.stability != TranscriptStability.finalResult) {
      throw const RuntimeError(
        RuntimeErrorCode.policyDenied,
        'The translation provider accepts final recognition segments only.',
      );
    }
    try {
      final result = await _bridge.translate(
        sourceText: finalTranscript.text,
        sourceLocale: config.sourceLocale,
        targetLocale: config.targetLocale,
      );
      final translatedText = result['translatedText'];
      if (translatedText is! String || translatedText.trim().isEmpty) {
        throw const RuntimeError(
          RuntimeErrorCode.translationModelUnavailable,
          'Android translation returned no usable output.',
          retryable: true,
        );
      }
      return TranslationSegment(
        session: config.session,
        sequence: finalTranscript.sequence,
        sourceText: finalTranscript.text,
        translatedText: translatedText,
        observedAtMicros: _nowMicros,
        truthLabel: TruthLabel.prepared,
      );
    } on PlatformException catch (error) {
      _emitUnavailable();
      throw RuntimeError(
        RuntimeErrorCode.translationModelUnavailable,
        'Android translation failed: ${error.code}.',
        retryable: true,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _config = null;
    try {
      await _bridge.disposeTranslation();
    } on PlatformException {
      _emitUnavailable();
    }
    await _snapshots.close();
    await _diagnostics.close();
  }

  bool _matches(TranslationSession first, TranslationSession second) =>
      first.sessionId == second.sessionId &&
      first.streamEpoch == second.streamEpoch &&
      first.privacyGeneration == second.privacyGeneration;

  void _emitUnavailable() {
    _emitSnapshot(ProviderReadiness.unavailable, TruthLabel.failed,
        failureReason: 'translation_model_unavailable');
    _emitDiagnostic(LiveTranslationDiagnosticCode.providerUnavailable);
  }

  void _emitSnapshot(
    ProviderReadiness readiness,
    TruthLabel truthLabel, {
    String? failureReason,
  }) {
    if (!_snapshots.isClosed) {
      _snapshots.add(ProviderSnapshot(
        providerId: providerId,
        sourceRevision: sourceRevision,
        readiness: readiness,
        truthLabel: truthLabel,
        observedAtMicros: _nowMicros,
        failureReason: failureReason,
      ));
    }
  }

  void _emitDiagnostic(LiveTranslationDiagnosticCode code) {
    if (!_diagnostics.isClosed) {
      _diagnostics.add(LiveTranslationDiagnostic(
        code: code,
        component: providerId,
        observedAtMicros: _nowMicros,
      ));
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const RuntimeError(
        RuntimeErrorCode.sessionClosed,
        'Android translation provider has been disposed.',
      );
    }
  }
}
