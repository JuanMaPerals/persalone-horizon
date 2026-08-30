import 'dart:async';
import 'package:flutter/services.dart';

/// Testable boundary over Android SpeechRecognizer, ML Kit Translation and
/// TextToSpeech. Event payloads may carry transcript/translation only on their
/// runtime data path; callers must never forward them to diagnostics or logs.
abstract interface class AndroidLiveTranslationBridge {
  Stream<Map<Object?, Object?>> get sttEvents;
  Stream<Map<Object?, Object?>> get ttsEvents;

  Future<Map<Object?, Object?>> prepareStt({
    required String sessionId,
    required int streamEpoch,
    required String locale,
    required int sampleRateHz,
    required int channels,
  });
  Future<void> pushSttPcm(Uint8List pcm);
  Future<void> stopStt();

  Future<Map<Object?, Object?>> prepareTranslation({
    required String sourceLocale,
    required String targetLocale,
    required bool allowModelDownload,
  });
  Future<Map<Object?, Object?>> translate({
    required String sourceText,
    required String sourceLocale,
    required String targetLocale,
  });
  Future<void> disposeTranslation();

  Future<Map<Object?, Object?>> prepareTts({required String locale});
  Future<void> speak({
    required String text,
    required String utteranceId,
  });
  Future<void> stopTts();
}

/// Production MethodChannel bridge for Android. These channels are intentionally
/// independent from G3/G4 channels so host-audio ownership remains canonical.
final class MethodChannelAndroidLiveTranslationBridge
    implements AndroidLiveTranslationBridge {
  MethodChannelAndroidLiveTranslationBridge({
    MethodChannel? sttChannel,
    EventChannel? sttEventChannel,
    MethodChannel? translationChannel,
    MethodChannel? ttsChannel,
    EventChannel? ttsEventChannel,
  })  : _sttChannel = sttChannel ?? const MethodChannel(_sttChannelName),
        _sttEventChannel =
            sttEventChannel ?? const EventChannel(_sttEventChannelName),
        _translationChannel =
            translationChannel ?? const MethodChannel(_translationChannelName),
        _ttsChannel = ttsChannel ?? const MethodChannel(_ttsChannelName),
        _ttsEventChannel =
            ttsEventChannel ?? const EventChannel(_ttsEventChannelName);

  static const String _sttChannelName = 'persalone.stt/input';
  static const String _sttEventChannelName = 'persalone.stt/events';
  static const String _translationChannelName = 'persalone.translation/model';
  static const String _ttsChannelName = 'persalone.tts/output';
  static const String _ttsEventChannelName = 'persalone.tts/events';

  final MethodChannel _sttChannel;
  final EventChannel _sttEventChannel;
  final MethodChannel _translationChannel;
  final MethodChannel _ttsChannel;
  final EventChannel _ttsEventChannel;

  @override
  Stream<Map<Object?, Object?>> get sttEvents =>
      _sttEventChannel.receiveBroadcastStream().map(_mapEvent);

  @override
  Stream<Map<Object?, Object?>> get ttsEvents =>
      _ttsEventChannel.receiveBroadcastStream().map(_mapEvent);

  @override
  Future<Map<Object?, Object?>> prepareStt({
    required String sessionId,
    required int streamEpoch,
    required String locale,
    required int sampleRateHz,
    required int channels,
  }) =>
      _invokeMap(_sttChannel, 'prepare', <String, Object>{
        'sessionId': sessionId,
        'streamEpoch': streamEpoch,
        'locale': locale,
        'sampleRateHz': sampleRateHz,
        'channels': channels,
      });

  @override
  Future<void> pushSttPcm(Uint8List pcm) =>
      _sttChannel.invokeMethod<void>('pushPcm', <String, Object>{'pcm': pcm});

  @override
  Future<void> stopStt() => _sttChannel.invokeMethod<void>('stop');

  @override
  Future<Map<Object?, Object?>> prepareTranslation({
    required String sourceLocale,
    required String targetLocale,
    required bool allowModelDownload,
  }) =>
      _invokeMap(_translationChannel, 'prepare', <String, Object>{
        'sourceLocale': sourceLocale,
        'targetLocale': targetLocale,
        'allowModelDownload': allowModelDownload,
      });

  @override
  Future<Map<Object?, Object?>> translate({
    required String sourceText,
    required String sourceLocale,
    required String targetLocale,
  }) =>
      _invokeMap(_translationChannel, 'translate', <String, Object>{
        'sourceText': sourceText,
        'sourceLocale': sourceLocale,
        'targetLocale': targetLocale,
      });

  @override
  Future<void> disposeTranslation() =>
      _translationChannel.invokeMethod<void>('dispose');

  @override
  Future<Map<Object?, Object?>> prepareTts({required String locale}) =>
      _invokeMap(_ttsChannel, 'prepare', <String, Object>{'locale': locale});

  @override
  Future<void> speak({required String text, required String utteranceId}) =>
      _ttsChannel.invokeMethod<void>('speak', <String, Object>{
        'text': text,
        'utteranceId': utteranceId,
      });

  @override
  Future<void> stopTts() => _ttsChannel.invokeMethod<void>('stop');

  static Future<Map<Object?, Object?>> _invokeMap(
    MethodChannel channel,
    String method,
    Map<String, Object> arguments,
  ) async {
    final result =
        await channel.invokeMapMethod<Object?, Object?>(method, arguments);
    return result ?? const <Object?, Object?>{};
  }

  static Map<Object?, Object?> _mapEvent(dynamic event) {
    if (event is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'invalid_live_translation_event',
        message: 'Native Android live translation event is not a map.',
      );
    }
    return event;
  }
}
