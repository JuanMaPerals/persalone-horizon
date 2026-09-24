import 'dart:typed_data';

abstract interface class HaloAudioTransport {
  Stream<Uint8List> get encodedMicrophoneAudio;

  Future<void> startMicrophone({
    int gain = 10,
    bool echoCancellation = true,
    bool voiceMode = true,
  });
  Future<void> stopMicrophone();

  Future<void> startSpeaker({int volume = 100});
  Future<void> sendEncodedSpeakerAudio(Uint8List lc3Frame);
  Future<void> stopSpeaker();
}