package com.example.persalone_mobile

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File

/**
 * G5 speech output. When the TTS engine streams synthesized audio to the app
 * (probed in [prepare]), each utterance is played through an AudioTrack owned
 * here, so the presentation of its first non-silent frame is observable with
 * AudioTrack timestamps on CLOCK_MONOTONIC: the clock of System.nanoTime,
 * AudioRecord timestamps and the STT speech boundaries. Otherwise the engine
 * plays the utterance itself and its presentation is reported unavailable.
 *
 * "Presented" is what AudioTrack reports for the output path, not acoustic
 * arrival and not human perception. A frame's time is only ever interpolated
 * back from a timestamp that already covers it (see [TtsPresentation]).
 *
 * Events on the TTS channel carry no text or audio: started, completed,
 * presented, presentation_unavailable, error.
 */
class MeasuredTtsOutput(private val emit: (Map<String, Any>) -> Unit) {
    companion object {
        private const val pollIntervalMs = 10L
        private const val stallTimeoutNanos = 3_000_000_000L
        private const val probeTimeoutMs = 3_000L
        private const val probePrefix = "horizon-probe-"
        private const val maxRememberedSequences = 32
    }

    private class Utterance(val id: String, val sequence: Int?, val queuedAtNanos: Long) {
        var track: AudioTrack? = null
        var sampleRateHz = 0
        var channels = 1
        var framesWritten = 0L
        var audibleFrame = -1L
        var synthesisDone = false
        var firstFrameAtNanos: Long? = null
        var audibleAtNanos: Long? = null
        var reported = false
        var lastFramePosition = -1L
        var lastProgressNanos = queuedAtNanos
    }

    private val lock = Any()
    private val worker = HandlerThread("persalone-tts-output").apply { start() }
    private val handler = Handler(worker.looper)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sequences = LinkedHashMap<String, Int>()
    private var sink: ParcelFileDescriptor? = null
    private var current: Utterance? = null
    private var polling = false
    private var probeId: String? = null
    private var probeDone: ((Boolean, String) -> Unit)? = null
    @Volatile private var measured = false

    val listener: UtteranceProgressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String) {
            if (utteranceId.startsWith(probePrefix)) return
            emitTyped("started", utteranceId)
        }

        override fun onDone(utteranceId: String) {
            if (utteranceId.startsWith(probePrefix)) {
                finishProbe(utteranceId, false, "noStreamedAudio")
                return
            }
            if (!measured) {
                emitTyped("completed", utteranceId)
                return
            }
            val silent = synchronized(lock) {
                val u = current
                if (u == null || u.id != utteranceId) return
                u.synthesisDone = true
                if (u.track == null) {
                    current = null
                    u
                } else {
                    null
                }
            }
            if (silent != null) {
                // Synthesis finished without producing audio for the app.
                reportUnavailable(silent, "noSynthesizedAudio")
                emitTyped("completed", silent.id)
            } else {
                schedulePoll()
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String) = onFailure(utteranceId, "tts_error")

        override fun onError(utteranceId: String, errorCode: Int) = onFailure(utteranceId, "tts_$errorCode")

        override fun onBeginSynthesis(utteranceId: String, sampleRateInHz: Int, audioFormat: Int, channelCount: Int) {
            val pcm16 = audioFormat == AudioFormat.ENCODING_PCM_16BIT
            if (utteranceId.startsWith(probePrefix)) {
                if (!TtsPresentation.isSupportedFormat(pcm16, channelCount, sampleRateInHz)) {
                    finishProbe(utteranceId, false, "unsupportedFormat")
                }
                return
            }
            val failed = synchronized(lock) {
                val u = current
                if (u == null || u.id != utteranceId || u.track != null) return
                val track = if (TtsPresentation.isSupportedFormat(pcm16, channelCount, sampleRateInHz)) {
                    buildTrack(sampleRateInHz, channelCount)
                } else {
                    null
                }
                if (track == null) {
                    current = null
                    u
                } else {
                    u.track = track
                    u.sampleRateHz = sampleRateInHz
                    u.channels = channelCount
                    u.lastProgressNanos = System.nanoTime()
                    track.play()
                    null
                }
            }
            if (failed != null) {
                // Nothing would be heard: report it loudly instead of staying silent.
                reportUnavailable(failed, "unsupportedFormat")
                emit(mapOf("type" to "error", "utteranceId" to failed.id, "code" to "tts_output_unavailable"))
            } else {
                schedulePoll()
            }
        }

        override fun onAudioAvailable(utteranceId: String, audio: ByteArray) {
            if (utteranceId.startsWith(probePrefix)) {
                if (audio.isNotEmpty()) finishProbe(utteranceId, true, "streamedAudio")
                return
            }
            val track = synchronized(lock) {
                val u = current
                val t = u?.track
                if (u == null || u.id != utteranceId || t == null) return
                if (u.audibleFrame < 0) {
                    val index = TtsPresentation.firstAudibleFrame(audio, audio.size, u.channels)
                    if (index >= 0) u.audibleFrame = u.framesWritten + index
                }
                u.framesWritten += (audio.size / (2 * u.channels)).toLong()
                t
            }
            try {
                track.write(audio, 0, audio.size, AudioTrack.WRITE_BLOCKING)
            } catch (_: IllegalStateException) {
                // Stop/Panic released the track while this chunk was being written.
            }
            schedulePoll()
        }
    }

    /**
     * Probes whether the engine streams audio to the app (API 30+ file
     * synthesis into /dev/null, so nothing is stored). [done] runs on the main
     * thread with the selected path and a coded reason.
     */
    fun prepare(tts: TextToSpeech, done: (Boolean, String) -> Unit) {
        stop(tts)
        measured = false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            done(false, "apiLevel")
            return
        }
        val fd = sink ?: openSink()
        if (fd == null) {
            done(false, "sinkUnavailable")
            return
        }
        sink = fd
        val id = probePrefix + System.nanoTime()
        synchronized(lock) {
            probeId = id
            probeDone = done
        }
        if (tts.synthesizeToFile("OK", Bundle(), fd, id) != TextToSpeech.SUCCESS) {
            finishProbe(id, false, "probeRejected")
            return
        }
        handler.postDelayed({ finishProbe(id, false, "probeTimeout") }, probeTimeoutMs)
    }

    /** Speaks with flush semantics: nothing older keeps playing. */
    fun speak(tts: TextToSpeech, text: String, utteranceId: String, sequence: Int?): Boolean {
        stop(tts)
        rememberSequence(utteranceId, sequence)
        val fd = sink
        if (!measured || fd == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val accepted = tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId) == TextToSpeech.SUCCESS
            if (accepted) {
                emit(unavailableEvent(utteranceId, sequence, "enginePlayback"))
            }
            return accepted
        }
        // "Queued" is the moment the utterance is handed to the engine.
        val utterance = Utterance(utteranceId, sequence, System.nanoTime())
        synchronized(lock) { current = utterance }
        if (tts.synthesizeToFile(text, Bundle(), fd, utteranceId) != TextToSpeech.SUCCESS) {
            synchronized(lock) { if (current === utterance) current = null }
            return false
        }
        schedulePoll()
        return true
    }

    /** Stop and Panic: stops synthesis and drops any audio not yet played. */
    fun stop(tts: TextToSpeech?) {
        val stopped = synchronized(lock) {
            val u = current
            current = null
            u
        }
        tts?.stop()
        if (stopped != null) {
            stopped.track?.let(::releaseTrack)
            if (!stopped.reported) reportUnavailable(stopped, "stopped")
        }
    }

    fun release(tts: TextToSpeech?) {
        stop(tts)
        val pendingProbe = synchronized(lock) {
            val done = probeDone
            probeId = null
            probeDone = null
            done
        }
        // A prepare still waiting on the probe must get exactly one answer.
        pendingProbe?.let { done -> mainHandler.post { done(false, "released") } }
        handler.removeCallbacksAndMessages(null)
        worker.quitSafely()
        try { sink?.close() } catch (_: Exception) { }
        sink = null
    }

    private fun onFailure(utteranceId: String, code: String) {
        if (utteranceId.startsWith(probePrefix)) {
            finishProbe(utteranceId, false, "probeError")
            return
        }
        val failed = synchronized(lock) {
            val u = current
            if (u != null && u.id == utteranceId) {
                current = null
                u
            } else {
                null
            }
        }
        if (failed != null) {
            failed.track?.let(::releaseTrack)
            if (!failed.reported) reportUnavailable(failed, "synthesisError")
        }
        emit(mapOf("type" to "error", "utteranceId" to utteranceId, "code" to code))
    }

    private fun schedulePoll() {
        synchronized(lock) {
            if (polling || current == null) return
            polling = true
        }
        handler.postDelayed(::poll, pollIntervalMs)
    }

    private fun poll() {
        var again = false
        var finished: Utterance? = null
        var presented: Utterance? = null
        var stalled: String? = null
        synchronized(lock) {
            polling = false
            val u = current ?: return
            val now = System.nanoTime()
            val track = u.track
            if (track == null) {
                if (now - u.queuedAtNanos > stallTimeoutNanos) {
                    current = null
                    finished = u
                    stalled = "noSynthesis"
                } else {
                    again = true
                }
                return@synchronized
            }
            val timestamp = AudioTimestamp()
            if (track.getTimestamp(timestamp)) {
                if (timestamp.framePosition != u.lastFramePosition) {
                    u.lastFramePosition = timestamp.framePosition
                    u.lastProgressNanos = now
                }
                if (u.firstFrameAtNanos == null) {
                    u.firstFrameAtNanos = TtsPresentation.presentedAtNanos(0, timestamp.framePosition, timestamp.nanoTime, u.sampleRateHz)
                }
                if (u.audibleFrame >= 0 && u.audibleAtNanos == null) {
                    u.audibleAtNanos = TtsPresentation.presentedAtNanos(u.audibleFrame, timestamp.framePosition, timestamp.nanoTime, u.sampleRateHz)
                }
            }
            val playedAll = u.synthesisDone && u.lastFramePosition >= u.framesWritten
            if (!u.reported && u.firstFrameAtNanos != null && (u.audibleAtNanos != null || playedAll)) {
                u.reported = true
                presented = u
            }
            when {
                playedAll -> {
                    current = null
                    finished = u
                }
                now - u.lastProgressNanos > stallTimeoutNanos -> {
                    current = null
                    finished = u
                    stalled = "noPresentationTimestamp"
                }
                else -> again = true
            }
        }
        presented?.let(::reportPresented)
        finished?.let { u ->
            u.track?.let(::releaseTrack)
            val reason = stalled
            if (reason != null && !u.reported) reportUnavailable(u, reason)
            if (reason == "noSynthesis") {
                emit(mapOf("type" to "error", "utteranceId" to u.id, "code" to "tts_no_audio"))
            } else {
                emitTyped("completed", u.id)
            }
        }
        if (again) schedulePoll()
    }

    private fun reportPresented(u: Utterance) {
        val event = mutableMapOf<String, Any>(
            "type" to "presented",
            "utteranceId" to u.id,
            "queuedAtMicros" to u.queuedAtNanos / 1_000L,
            "firstFramePresentedAtMicros" to (u.firstFrameAtNanos ?: return) / 1_000L,
            "sampleRateHz" to u.sampleRateHz,
        )
        u.audibleAtNanos?.let { event["audiblePresentedAtMicros"] = it / 1_000L }
        u.sequence?.let { event["sequence"] = it }
        emit(event)
    }

    private fun reportUnavailable(u: Utterance, reason: String) {
        u.reported = true
        emit(unavailableEvent(u.id, u.sequence, reason))
    }

    private fun unavailableEvent(utteranceId: String, sequence: Int?, reason: String): Map<String, Any> {
        val event = mutableMapOf<String, Any>(
            "type" to "presentation_unavailable",
            "utteranceId" to utteranceId,
            "reason" to reason,
        )
        sequence?.let { event["sequence"] = it }
        return event
    }

    private fun emitTyped(type: String, utteranceId: String) {
        val event = mutableMapOf<String, Any>("type" to type, "utteranceId" to utteranceId)
        synchronized(lock) { sequences[utteranceId] }?.let { event["sequence"] = it }
        emit(event)
    }

    private fun rememberSequence(utteranceId: String, sequence: Int?) {
        if (sequence == null) return
        synchronized(lock) {
            sequences.remove(utteranceId)
            while (sequences.size >= maxRememberedSequences) {
                sequences.remove(sequences.keys.first())
            }
            sequences[utteranceId] = sequence
        }
    }

    private fun finishProbe(id: String, ok: Boolean, reason: String) {
        val callback = synchronized(lock) {
            if (probeId != id) return
            probeId = null
            val done = probeDone
            probeDone = null
            measured = ok
            done
        } ?: return
        mainHandler.post { callback(ok, reason) }
    }

    private fun openSink(): ParcelFileDescriptor? = try {
        ParcelFileDescriptor.open(File("/dev/null"), ParcelFileDescriptor.MODE_WRITE_ONLY)
    } catch (_: Exception) {
        null
    }

    private fun buildTrack(sampleRateHz: Int, channels: Int): AudioTrack? {
        val channelMask = if (channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBufferBytes = AudioTrack.getMinBufferSize(sampleRateHz, channelMask, encoding)
        if (minBufferBytes <= 0) return null
        // About 100 ms of buffer: enough to absorb synthesis jitter without
        // adding more queueing delay than needed.
        val bufferBytes = maxOf(minBufferBytes, sampleRateHz / 10 * 2 * channels)
        return try {
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
                        .setChannelMask(channelMask)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(bufferBytes)
                .build()
            if (track.state == AudioTrack.STATE_INITIALIZED) {
                track
            } else {
                track.release()
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun releaseTrack(track: AudioTrack) {
        try {
            track.pause()
            track.flush()
            track.stop()
        } catch (_: IllegalStateException) {
            // Already stopped after a route or device error.
        }
        track.release()
    }
}
