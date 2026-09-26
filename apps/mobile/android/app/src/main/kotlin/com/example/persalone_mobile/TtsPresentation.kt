package com.example.persalone_mobile

import kotlin.math.abs

/**
 * Pure helpers for the measured G5 speech output. They turn AudioTrack
 * presentation timestamps into the time a given frame was presented, without
 * ever predicting a frame that has not been presented yet.
 */
object TtsPresentation {
    /** |sample| above this (about -40 dBFS) counts as audible, not leading silence. */
    const val audibleThreshold = 328

    /**
     * Index, in frames, of the first frame of little-endian signed 16-bit PCM
     * whose any channel exceeds [threshold]; -1 when the chunk is silent.
     */
    fun firstAudibleFrame(pcm: ByteArray, length: Int, channels: Int, threshold: Int = audibleThreshold): Int {
        require(channels > 0) { "channels must be positive" }
        val bytesPerFrame = 2 * channels
        val frames = minOf(length, pcm.size) / bytesPerFrame
        for (frame in 0 until frames) {
            for (channel in 0 until channels) {
                val offset = frame * bytesPerFrame + channel * 2
                val sample = ((pcm[offset + 1].toInt() shl 8) or (pcm[offset].toInt() and 0xff)).toShort().toInt()
                if (abs(sample) > threshold) return frame
            }
        }
        return -1
    }

    /**
     * Monotonic time (ns) at which [targetFrame] was presented, derived from an
     * AudioTimestamp reporting that [timestampFrame] was presented at
     * [timestampNanos]. Null while the target frame has not been presented:
     * the result is only ever interpolated back into frames already played.
     */
    fun presentedAtNanos(targetFrame: Long, timestampFrame: Long, timestampNanos: Long, sampleRateHz: Int): Long? {
        if (targetFrame < 0 || sampleRateHz <= 0 || timestampFrame < targetFrame) return null
        return timestampNanos - (timestampFrame - targetFrame) * 1_000_000_000L / sampleRateHz
    }

    /** Output formats the measured path can play and scan: 16-bit PCM, mono or stereo. */
    fun isSupportedFormat(pcm16: Boolean, channels: Int, sampleRateHz: Int): Boolean =
        pcm16 && (channels == 1 || channels == 2) && sampleRateHz in 8_000..48_000
}
