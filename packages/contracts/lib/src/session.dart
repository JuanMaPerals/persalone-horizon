import 'runtime_error.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Direction of one translated conversational turn.
enum TranslationDirection { englishToSpanish, spanishToEnglish }

/// Immutable identity for work belonging to exactly one conversational turn.
/// It deliberately excludes transcript sequence because sequence is correlation
/// evidence, not a cancellation or authorization generation.
final class TranslationExecutionToken {
  const TranslationExecutionToken({
    required this.sessionId,
    required this.streamEpoch,
    required this.privacyGeneration,
    required this.turnGeneration,
  });

  final String sessionId;
  final int streamEpoch;
  final int privacyGeneration;
  final int turnGeneration;

  bool matches(TranslationExecutionToken other) =>
      sessionId == other.sessionId &&
      streamEpoch == other.streamEpoch &&
      privacyGeneration == other.privacyGeneration &&
      turnGeneration == other.turnGeneration;

  void validate() {
    if (sessionId.trim().isEmpty ||
        streamEpoch < 0 ||
        privacyGeneration < 0 ||
        turnGeneration < 0) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Translation execution token is invalid.',
      );
    }
  }
}

/// Parsed opaque utterance identity. It carries only execution correlation and
/// a non-content nonce; no transcript, translation, locale, voice, or account
/// data is encoded.
final class OpaqueUtteranceIdentity {
  const OpaqueUtteranceIdentity({
    required this.sessionFingerprint,
    required this.streamEpoch,
    required this.privacyGeneration,
    required this.turnGeneration,
    required this.nonce,
  });

  final String sessionFingerprint;
  final int streamEpoch;
  final int privacyGeneration;
  final int turnGeneration;
  final int nonce;

  bool matches(OpaqueUtteranceIdentity other) =>
      sessionFingerprint == other.sessionFingerprint &&
      streamEpoch == other.streamEpoch &&
      privacyGeneration == other.privacyGeneration &&
      turnGeneration == other.turnGeneration &&
      nonce == other.nonce;

  bool matchesToken(TranslationExecutionToken token) =>
      sessionFingerprint ==
          OpaqueUtteranceIdentityCodec.sessionFingerprint(token) &&
      streamEpoch == token.streamEpoch &&
      privacyGeneration == token.privacyGeneration &&
      turnGeneration == token.turnGeneration;
}

/// The only codec allowed to create or parse Android TTS utterance identities.
/// Android receives the resulting string verbatim and never parses fragments.
final class OpaqueUtteranceIdentityCodec {
  const OpaqueUtteranceIdentityCodec._();

  static const String _prefix = 'persalone.tts/1.';

  static String encode({
    required TranslationExecutionToken token,
    required int nonce,
  }) {
    token.validate();
    if (nonce < 0) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Utterance nonce must not be negative.',
      );
    }
    final payload = jsonEncode(<String, Object>{
      'h': sessionFingerprint(token),
      'e': token.streamEpoch,
      'p': token.privacyGeneration,
      't': token.turnGeneration,
      'n': nonce,
    });
    return '$_prefix${base64Url.encode(utf8.encode(payload)).replaceAll('=', '')}';
  }

  static String sessionFingerprint(TranslationExecutionToken token) {
    token.validate();
    return sha256.convert(utf8.encode(token.sessionId)).toString();
  }

  static OpaqueUtteranceIdentity decode(String encoded) {
    if (!encoded.startsWith(_prefix)) {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Utterance identity has an unsupported schema.',
      );
    }
    try {
      final decoded = utf8.decode(
        base64Url
            .decode(base64Url.normalize(encoded.substring(_prefix.length))),
      );
      final value = jsonDecode(decoded);
      if (value is! Map<Object?, Object?> ||
          value['h'] is! String ||
          value['e'] is! int ||
          value['p'] is! int ||
          value['t'] is! int ||
          value['n'] is! int) {
        throw const FormatException('Invalid utterance identity payload.');
      }
      final fingerprint = value['h']! as String;
      final streamEpoch = value['e']! as int;
      final privacyGeneration = value['p']! as int;
      final turnGeneration = value['t']! as int;
      final nonce = value['n']! as int;
      if (fingerprint.length != 64 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint) ||
          streamEpoch < 0 ||
          privacyGeneration < 0 ||
          turnGeneration < 0 ||
          nonce < 0) {
        throw const FormatException('Invalid utterance identity payload.');
      }
      return OpaqueUtteranceIdentity(
        sessionFingerprint: fingerprint,
        streamEpoch: streamEpoch,
        privacyGeneration: privacyGeneration,
        turnGeneration: turnGeneration,
        nonce: nonce,
      );
    } on FormatException {
      throw const RuntimeError(
        RuntimeErrorCode.invalidContract,
        'Utterance identity is malformed.',
      );
    }
  }
}

/// Transport-neutral audio metadata. Audio payloads are intentionally absent
/// from the shared contract and must never enter logs or telemetry by default.
final class AudioFrameMetadata {
  const AudioFrameMetadata({
    required this.sessionId,
    required this.streamId,
    required this.streamEpoch,
    required this.sequence,
    required this.capturedAtMicros,
    required this.sampleRateHz,
    required this.channels,
    required this.durationMicros,
    required this.codec,
    this.discontinuity = false,
  });

  final String sessionId;
  final String streamId;
  final int streamEpoch;
  final int sequence;
  final int capturedAtMicros;
  final int sampleRateHz;
  final int channels;
  final int durationMicros;
  final String codec;
  final bool discontinuity;
}

/// Session identity and cancellation generation for a translation turn.
final class TranslationSession {
  const TranslationSession({
    required this.sessionId,
    required this.streamEpoch,
    required this.direction,
    required this.privacyGeneration,
    this.turnGeneration = 0,
  });

  final String sessionId;
  final int streamEpoch;
  final TranslationDirection direction;
  final int privacyGeneration;
  final int turnGeneration;

  TranslationExecutionToken get executionToken => TranslationExecutionToken(
        sessionId: sessionId,
        streamEpoch: streamEpoch,
        privacyGeneration: privacyGeneration,
        turnGeneration: turnGeneration,
      );

  void validateFrame(AudioFrameMetadata frame) {
    if (frame.sessionId != sessionId || frame.streamEpoch != streamEpoch) {
      throw const RuntimeError(
        RuntimeErrorCode.staleStreamEpoch,
        'Frame belongs to an inactive session generation.',
      );
    }
  }
}
