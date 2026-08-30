package com.example.persalone_mobile

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.google.mlkit.nl.translate.Translation
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.util.Locale
import kotlin.concurrent.thread
import kotlin.math.max

class MainActivity : FlutterActivity() {
    companion object {
        private const val microphonePermissionRequestCode = 4101
        private const val inputChannelName = "persalone.audio/input"
        private const val inputEventsChannelName = "persalone.audio/input_events"
        private const val outputChannelName = "persalone.audio/output"
        private const val outputEventsChannelName = "persalone.audio/output_events"
        private const val sttChannelName = "persalone.stt/input"
        private const val sttEventsChannelName = "persalone.stt/events"
        private const val translationChannelName = "persalone.translation/model"
        private const val ttsChannelName = "persalone.tts/output"
        private const val ttsEventsChannelName = "persalone.tts/events"
        private const val canonicalSampleRateHz = 16_000
        private const val canonicalChannels = 1
    }

    private var inputSink: EventChannel.EventSink? = null
    private var outputSink: EventChannel.EventSink? = null
    private var sttSink: EventChannel.EventSink? = null
    private var ttsSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false

    private var speechRecognizer: SpeechRecognizer? = null
    private var sttReadPipe: ParcelFileDescriptor? = null
    private var sttWritePipe: ParcelFileDescriptor? = null
    private var sttOutput: FileOutputStream? = null
    private var sttSessionId: String? = null
    private var sttStreamEpoch: Int? = null
    private var sttSequence = 0

    private var translator: Translator? = null
    private var translatorSourceLocale: String? = null
    private var translatorTargetLocale: String? = null
    private var textToSpeech: TextToSpeech? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, inputEventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    inputSink = events
                }
                override fun onCancel(arguments: Any?) {
                    inputSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, inputChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> requestMicrophonePermission(result)
                    "start" -> startInput(call, result)
                    "stop" -> stopInput(result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, outputEventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    outputSink = events
                }
                override fun onCancel(arguments: Any?) {
                    outputSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, outputChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> startOutput(call, result)
                    "write" -> writeOutput(call, result)
                    "stop" -> stopOutput(result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, sttEventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sttSink = events
                }
                override fun onCancel(arguments: Any?) {
                    sttSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, sttChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> prepareStt(call, result)
                    "pushPcm" -> pushSttPcm(call, result)
                    "stop" -> stopStt(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, translationChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> prepareTranslation(call, result)
                    "translate" -> translate(call, result)
                    "dispose" -> disposeTranslation(result)
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, ttsEventsChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    ttsSink = events
                }
                override fun onCancel(arguments: Any?) {
                    ttsSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> prepareTts(call, result)
                    "speak" -> speak(call, result)
                    "stop" -> stopTts(result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        stopCaptureInternal()
        stopPlaybackInternal()
        stopSttInternal()
        translator?.close()
        translator = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != microphonePermissionRequestCode) return
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        emitInputEvent(mapOf("type" to if (granted) "permission_granted" else "permission_denied"))
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_in_flight", "A microphone permission request is already active.", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            microphonePermissionRequestCode,
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun startInput(call: MethodCall, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission_required", "RECORD_AUDIO permission has not been granted.", null)
            return
        }
        if (capturing) {
            result.error("already_capturing", "Android microphone capture is already active.", null)
            return
        }
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val sampleRateHz = arguments["sampleRateHz"] as? Int ?: canonicalSampleRateHz
        val channels = arguments["channels"] as? Int ?: canonicalChannels
        val bytesPerSample = arguments["bytesPerSample"] as? Int ?: 2
        if (sampleRateHz <= 0 || channels != canonicalChannels || bytesPerSample != 2) {
            result.error("unsupported_pcm_format", "G3 requires positive-rate, mono, signed 16-bit PCM.", null)
            return
        }

        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBufferBytes = AudioRecord.getMinBufferSize(sampleRateHz, channelConfig, encoding)
        if (minBufferBytes <= 0) {
            result.error("buffer_unavailable", "AudioRecord did not provide a minimum buffer size.", null)
            return
        }
        val chunkBytes = max(sampleRateHz / 50 * bytesPerSample, 320)
        val bufferBytes = max(minBufferBytes * 2, chunkBytes * 4)
        val recorder = AudioRecord.Builder()
            .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(encoding)
                    .setSampleRate(sampleRateHz)
                    .setChannelMask(channelConfig)
                    .build(),
            )
            .setBufferSizeInBytes(bufferBytes)
            .build()
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            result.error("record_uninitialized", "AudioRecord did not initialize.", null)
            return
        }

        audioRecord = recorder
        capturing = true
        recorder.startRecording()
        captureThread = thread(name = "persalone-audio-record", isDaemon = true) {
            readPcmLoop(recorder, sampleRateHz, bytesPerSample, chunkBytes)
        }
        emitInputEvent(
            mapOf(
                "type" to "capture_started",
                "sampleRateHz" to sampleRateHz,
                "bufferBytes" to bufferBytes,
                "chunkBytes" to chunkBytes,
            ),
        )
        result.success(mapOf("sampleRateHz" to sampleRateHz, "bufferBytes" to bufferBytes, "chunkBytes" to chunkBytes))
    }

    private fun readPcmLoop(
        recorder: AudioRecord,
        sampleRateHz: Int,
        bytesPerSample: Int,
        chunkBytes: Int,
    ) {
        val buffer = ByteArray(chunkBytes)
        var sequence = 0
        var droppedFrames = 0
        while (capturing) {
            val bytesRead = recorder.read(buffer, 0, buffer.size)
            val receivedAtMicros = System.nanoTime() / 1_000L
            when {
                bytesRead > 0 -> {
                    val frameCount = bytesRead / bytesPerSample
                    val durationMicros = frameCount * 1_000_000 / sampleRateHz
                    emitInputEvent(
                        mapOf(
                            "type" to "frame",
                            "pcm" to buffer.copyOf(bytesRead),
                            "sequence" to sequence,
                            "capturedAtMicros" to receivedAtMicros,
                            "durationMicros" to durationMicros,
                            "discontinuity" to (droppedFrames > 0),
                        ),
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        val timestamp = AudioTimestamp()
                        if (recorder.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS) {
                            emitInputEvent(mapOf("type" to "capture_timestamp", "framePosition" to timestamp.framePosition, "timestampMicros" to timestamp.nanoTime / 1_000L))
                        } else {
                            emitInputEvent(mapOf("type" to "capture_timestamp_unavailable"))
                        }
                    } else {
                        emitInputEvent(mapOf("type" to "capture_timestamp_unavailable"))
                    }
                    sequence += 1
                    droppedFrames = 0
                }
                bytesRead == 0 -> {
                    droppedFrames += 1
                    emitInputEvent(mapOf("type" to "input_drop", "sequence" to sequence, "droppedFrames" to droppedFrames))
                }
                else -> {
                    droppedFrames += 1
                    emitInputEvent(mapOf("type" to "capture_error", "code" to "audio_record_$bytesRead"))
                    if (bytesRead == AudioRecord.ERROR_DEAD_OBJECT) capturing = false
                }
            }
        }
    }

    private fun stopInput(result: MethodChannel.Result) {
        stopCaptureInternal()
        result.success(null)
    }

    private fun stopCaptureInternal() {
        capturing = false
        val recorder = audioRecord
        try {
            recorder?.stop()
        } catch (_: IllegalStateException) {
            // The recorder can already be stopped after a device error.
        }
        val thread = captureThread
        if (thread != null && thread != Thread.currentThread()) thread.join(500)
        captureThread = null
        recorder?.release()
        audioRecord = null
        emitInputEvent(mapOf("type" to "capture_stopped"))
    }

    @Suppress("UNCHECKED_CAST")
    private fun startOutput(call: MethodCall, result: MethodChannel.Result) {
        if (audioTrack != null) {
            result.error("already_playing", "Android speaker playback is already active.", null)
            return
        }
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val sampleRateHz = arguments["sampleRateHz"] as? Int ?: canonicalSampleRateHz
        val channels = arguments["channels"] as? Int ?: canonicalChannels
        val bytesPerSample = arguments["bytesPerSample"] as? Int ?: 2
        if (sampleRateHz <= 0 || channels != canonicalChannels || bytesPerSample != 2) {
            result.error("unsupported_pcm_format", "G4 requires positive-rate, mono, signed 16-bit PCM.", null)
            return
        }

        val channelConfig = AudioFormat.CHANNEL_OUT_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBufferBytes = AudioTrack.getMinBufferSize(sampleRateHz, channelConfig, encoding)
        if (minBufferBytes <= 0) {
            result.error("buffer_unavailable", "AudioTrack did not provide a minimum buffer size.", null)
            return
        }
        val chunkBytes = max(sampleRateHz / 50 * bytesPerSample, 320)
        val bufferBytes = max(minBufferBytes * 2, chunkBytes * 4)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(encoding)
                    .setSampleRate(sampleRateHz)
                    .setChannelMask(channelConfig)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(bufferBytes)
            .build()
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            result.error("track_uninitialized", "AudioTrack did not initialize.", null)
            return
        }

        audioTrack = track
        track.play()
        emitOutputEvent(mapOf("type" to "playback_started", "sampleRateHz" to sampleRateHz, "bufferBytes" to bufferBytes, "chunkBytes" to chunkBytes))
        result.success(mapOf("sampleRateHz" to sampleRateHz, "bufferBytes" to bufferBytes, "chunkBytes" to chunkBytes))
    }

    private fun writeOutput(call: MethodCall, result: MethodChannel.Result) {
        val track = audioTrack
        if (track == null || track.playState != AudioTrack.PLAYSTATE_PLAYING) {
            result.error("output_not_ready", "Android speaker playback is not ready.", null)
            return
        }
        val pcm = call.argument<ByteArray>("pcm")
        if (pcm == null || pcm.isEmpty() || pcm.size % 2 != 0) {
            result.error("invalid_pcm", "Output expects non-empty 16-bit PCM bytes.", null)
            return
        }
        val writtenBytes = track.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
        if (writtenBytes < 0) {
            emitOutputEvent(mapOf("type" to "output_error", "code" to "audio_track_$writtenBytes"))
            result.error("audio_track_write", "AudioTrack write failed: $writtenBytes", null)
            return
        }

        val response = mutableMapOf<String, Any>("writtenBytes" to writtenBytes)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) response["underrunCount"] = track.underrunCount
        val timestamp = AudioTimestamp()
        if (track.getTimestamp(timestamp)) {
            response["presentationTimestampMicros"] = timestamp.nanoTime / 1_000L
            response["framePosition"] = timestamp.framePosition
            emitOutputEvent(mapOf("type" to "output_timestamp", "framePosition" to timestamp.framePosition, "timestampMicros" to timestamp.nanoTime / 1_000L))
        } else {
            emitOutputEvent(mapOf("type" to "output_timestamp_unavailable"))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && track.underrunCount > 0) {
            emitOutputEvent(mapOf("type" to "output_underrun", "underrunCount" to track.underrunCount))
        }
        result.success(response)
    }

    private fun stopOutput(result: MethodChannel.Result) {
        stopPlaybackInternal()
        result.success(null)
    }

    private fun stopPlaybackInternal() {
        val track = audioTrack ?: return
        try {
            track.pause()
            track.flush()
            track.stop()
        } catch (_: IllegalStateException) {
            // The track may have been stopped after a device or route error.
        }
        track.release()
        audioTrack = null
        emitOutputEvent(mapOf("type" to "playback_stopped"))
    }

    @Suppress("UNCHECKED_CAST")
    private fun prepareStt(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val sessionId = arguments["sessionId"] as? String
        val streamEpoch = arguments["streamEpoch"] as? Int
        val locale = arguments["locale"] as? String
        val sampleRateHz = arguments["sampleRateHz"] as? Int
        val channels = arguments["channels"] as? Int
        if (sessionId.isNullOrBlank() || streamEpoch == null || locale.isNullOrBlank() ||
            sampleRateHz != canonicalSampleRateHz || channels != canonicalChannels
        ) {
            result.error("invalid_stt_contract", "STT requires a canonical session, locale and 16 kHz mono PCM.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        ) {
            result.success(mapOf("ready" to false, "reason" to "on_device_pfd_recognition_unavailable"))
            return
        }
        stopSttInternal()
        try {
            speechRecognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this).also { recognizer ->
                recognizer.setRecognitionListener(createRecognitionListener())
            }
            val pipe = ParcelFileDescriptor.createPipe()
            sttReadPipe = pipe[0]
            sttWritePipe = pipe[1]
            sttOutput = FileOutputStream(sttWritePipe!!.fileDescriptor)
            sttSessionId = sessionId
            sttStreamEpoch = streamEpoch
            sttSequence = 0
            startListeningFromPipe(locale)
            result.success(mapOf("ready" to true, "source" to "on_device_pfd"))
        } catch (_: Exception) {
            stopSttInternal()
            result.success(mapOf("ready" to false, "reason" to "recognizer_initialization_failed"))
        }
    }

    private fun startListeningFromPipe(locale: String) {
        val recognizer = speechRecognizer ?: return
        val readPipe = sttReadPipe ?: return
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, readPipe)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, canonicalChannels)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, canonicalSampleRateHz)
        }
        recognizer.startListening(intent)
    }

    private fun createRecognitionListener(): RecognitionListener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = Unit
        override fun onBeginningOfSpeech() = Unit
        override fun onRmsChanged(rmsdB: Float) = Unit
        override fun onBufferReceived(buffer: ByteArray?) = Unit
        override fun onEndOfSpeech() = Unit
        override fun onError(error: Int) {
            emitSttEvent(mapOf("type" to "error", "code" to "speech_recognizer_$error"))
        }
        override fun onResults(results: Bundle?) {
            emitRecognitionResult("final", results)
        }
        override fun onPartialResults(partialResults: Bundle?) {
            emitRecognitionResult("partial", partialResults)
        }
        override fun onEvent(eventType: Int, params: Bundle?) = Unit
    }

    private fun emitRecognitionResult(type: String, results: Bundle?) {
        val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
        if (text.isNullOrBlank()) return
        val confidence = results.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)?.firstOrNull()
        val event = mutableMapOf<String, Any>(
            "type" to type,
            "sessionId" to (sttSessionId ?: return),
            "streamEpoch" to (sttStreamEpoch ?: return),
            "sequence" to sttSequence++,
            "text" to text,
            "observedAtMicros" to System.nanoTime() / 1_000L,
        )
        if (confidence != null) event["confidence"] = confidence.toDouble()
        emitSttEvent(event)
    }

    private fun pushSttPcm(call: MethodCall, result: MethodChannel.Result) {
        val pcm = call.argument<ByteArray>("pcm")
        val output = sttOutput
        if (pcm == null || pcm.isEmpty() || output == null) {
            result.error("stt_not_ready", "On-device STT PCM pipe is not ready.", null)
            return
        }
        thread(name = "persalone-stt-pipe", isDaemon = true) {
            try {
                output.write(pcm)
                output.flush()
                runOnUiThread { result.success(null) }
            } catch (_: Exception) {
                emitSttEvent(mapOf("type" to "error", "code" to "pcm_pipe_write_failed"))
                runOnUiThread { result.error("stt_pipe_write_failed", "Unable to write a PCM frame to STT.", null) }
            }
        }
    }

    private fun stopStt(result: MethodChannel.Result) {
        stopSttInternal()
        result.success(null)
    }

    private fun stopSttInternal() {
        try {
            speechRecognizer?.cancel()
            speechRecognizer?.destroy()
        } catch (_: Exception) {
            // The recognition service can already be unavailable after a platform error.
        }
        speechRecognizer = null
        try { sttOutput?.close() } catch (_: Exception) { }
        try { sttReadPipe?.close() } catch (_: Exception) { }
        try { sttWritePipe?.close() } catch (_: Exception) { }
        sttOutput = null
        sttReadPipe = null
        sttWritePipe = null
        sttSessionId = null
        sttStreamEpoch = null
    }

    @Suppress("UNCHECKED_CAST")
    private fun prepareTranslation(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val sourceLocale = arguments["sourceLocale"] as? String
        val targetLocale = arguments["targetLocale"] as? String
        val allowModelDownload = arguments["allowModelDownload"] as? Boolean ?: false
        val sourceLanguage = sourceLocale?.let(::translateLanguageForLocale)
        val targetLanguage = targetLocale?.let(::translateLanguageForLocale)
        if (sourceLanguage == null || targetLanguage == null || sourceLanguage == targetLanguage) {
            result.error("unsupported_translation_locale", "Only distinct supported local translation locales are accepted.", null)
            return
        }
        if (!allowModelDownload) {
            result.success(mapOf("modelReady" to false, "reason" to "model_download_consent_required"))
            return
        }
        translator?.close()
        translator = Translation.getClient(
            TranslatorOptions.Builder()
                .setSourceLanguage(sourceLanguage)
                .setTargetLanguage(targetLanguage)
                .build(),
        )
        translatorSourceLocale = sourceLocale
        translatorTargetLocale = targetLocale
        translator!!.downloadModelIfNeeded()
            .addOnSuccessListener { result.success(mapOf("modelReady" to true)) }
            .addOnFailureListener { result.success(mapOf("modelReady" to false, "reason" to "model_download_or_load_failed")) }
    }

    @Suppress("UNCHECKED_CAST")
    private fun translate(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val sourceText = arguments["sourceText"] as? String
        val sourceLocale = arguments["sourceLocale"] as? String
        val targetLocale = arguments["targetLocale"] as? String
        val activeTranslator = translator
        if (sourceText.isNullOrBlank() || activeTranslator == null ||
            sourceLocale != translatorSourceLocale || targetLocale != translatorTargetLocale
        ) {
            result.error("translation_not_ready", "The requested on-device translation model is not ready.", null)
            return
        }
        activeTranslator.translate(sourceText)
            .addOnSuccessListener { translatedText -> result.success(mapOf("translatedText" to translatedText)) }
            .addOnFailureListener { result.error("translation_failed", "On-device translation failed.", null) }
    }

    private fun disposeTranslation(result: MethodChannel.Result) {
        translator?.close()
        translator = null
        translatorSourceLocale = null
        translatorTargetLocale = null
        result.success(null)
    }

    @Suppress("UNCHECKED_CAST")
    private fun prepareTts(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val localeTag = arguments["locale"] as? String
        if (localeTag.isNullOrBlank()) {
            result.error("invalid_tts_locale", "TTS requires a target locale.", null)
            return
        }
        textToSpeech?.shutdown()
        textToSpeech = TextToSpeech(this) { status ->
            if (status != TextToSpeech.SUCCESS) {
                result.success(mapOf("ready" to false, "reason" to "tts_initialization_failed"))
                return@TextToSpeech
            }
            val tts = textToSpeech
            val locale = Locale.forLanguageTag(localeTag)
            val availability = tts?.isLanguageAvailable(locale) ?: TextToSpeech.LANG_NOT_SUPPORTED
            if (availability == TextToSpeech.LANG_MISSING_DATA || availability == TextToSpeech.LANG_NOT_SUPPORTED) {
                result.success(mapOf("ready" to false, "reason" to "tts_locale_unavailable"))
                return@TextToSpeech
            }
            if (tts?.setLanguage(locale) != TextToSpeech.SUCCESS) {
                result.success(mapOf("ready" to false, "reason" to "tts_locale_set_failed"))
                return@TextToSpeech
            }
            tts.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
                override fun onStart(utteranceId: String) {
                    emitTtsEvent(mapOf("type" to "started", "utteranceId" to utteranceId))
                }
                override fun onDone(utteranceId: String) {
                    emitTtsEvent(mapOf("type" to "completed", "utteranceId" to utteranceId))
                }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String) {
                    emitTtsEvent(mapOf("type" to "error", "utteranceId" to utteranceId))
                }
                override fun onError(utteranceId: String, errorCode: Int) {
                    emitTtsEvent(mapOf("type" to "error", "utteranceId" to utteranceId, "code" to "tts_$errorCode"))
                }
            })
            result.success(mapOf("ready" to true))
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
        val text = arguments["text"] as? String
        val utteranceId = arguments["utteranceId"] as? String
        val tts = textToSpeech
        if (text.isNullOrBlank() || utteranceId.isNullOrBlank() || tts == null) {
            result.error("tts_not_ready", "Android TTS is not ready for this session.", null)
            return
        }
        val status = tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (status != TextToSpeech.SUCCESS) {
            result.error("tts_speak_failed", "Android TTS rejected the utterance.", null)
            return
        }
        result.success(null)
    }

    private fun stopTts(result: MethodChannel.Result) {
        textToSpeech?.stop()
        result.success(null)
    }

    private fun translateLanguageForLocale(locale: String): String? = when (locale.substringBefore('-').lowercase()) {
        "en" -> TranslateLanguage.ENGLISH
        "es" -> TranslateLanguage.SPANISH
        else -> null
    }

    private fun emitInputEvent(event: Map<String, Any>) {
        runOnUiThread { inputSink?.success(event) }
    }
    private fun emitOutputEvent(event: Map<String, Any>) {
        runOnUiThread { outputSink?.success(event) }
    }
    private fun emitSttEvent(event: Map<String, Any>) {
        runOnUiThread { sttSink?.success(event) }
    }
    private fun emitTtsEvent(event: Map<String, Any>) {
        runOnUiThread { ttsSink?.success(event) }
    }
}
