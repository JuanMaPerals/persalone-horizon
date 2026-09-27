package com.example.persalone_mobile

import android.media.MediaRecorder

/**
 * Pure helpers for the physical validation path, kept free of Android
 * runtime state so they run as JVM unit tests.
 */
object ValidationSupport {
    /** Intent extra that selects the capture source (debuggable builds only). */
    const val audioSourceExtra = "horizon.audioSource"

    /**
     * Stream epochs are microsecond timestamps and exceed 32 bits. The platform
     * channel delivers them as Long (or Int when small); anything else, or a
     * negative value, is not a valid epoch.
     */
    fun epochOf(value: Any?): Long? = when (value) {
        is Long -> value.takeIf { it >= 0 }
        is Int -> value.toLong().takeIf { it >= 0 }
        else -> null
    }

    /**
     * Resolves the capture source for an A/B run. Without a request, or in a
     * non-debuggable build, the default VOICE_RECOGNITION source is used. An
     * unknown request fails (null) instead of silently falling back, so a
     * mistyped A/B run cannot be recorded as the other variant.
     */
    fun captureSourceFor(requested: String?, debuggable: Boolean): CaptureSource? {
        if (requested == null || !debuggable) return CaptureSource.VOICE_RECOGNITION
        return CaptureSource.values().firstOrNull { it.wire == requested }
    }

    /**
     * `physical` or `emulator`, from the build identifiers. Only `physical`
     * lets the app label Android measurements ANDROID_REAL, so any sign of an
     * emulator (AVD goldfish/ranchu, SDK images, Genymotion vbox86) wins.
     */
    fun deviceClass(fingerprint: String, hardware: String, product: String, model: String): String {
        val emulator = fingerprint.startsWith("generic") ||
            fingerprint.contains("emulator", ignoreCase = true) ||
            hardware in setOf("goldfish", "ranchu", "vbox86") ||
            product.contains("sdk", ignoreCase = true) ||
            product.contains("emulator", ignoreCase = true) ||
            model.contains("Emulator", ignoreCase = true) ||
            model.contains("Android SDK built for", ignoreCase = true)
        return if (emulator) "emulator" else "physical"
    }
}

enum class CaptureSource(val wire: String, val androidSource: Int, val attachEchoCanceler: Boolean) {
    VOICE_RECOGNITION("voiceRecognition", MediaRecorder.AudioSource.VOICE_RECOGNITION, false),
    VOICE_COMMUNICATION("voiceCommunication", MediaRecorder.AudioSource.VOICE_COMMUNICATION, true),
}
