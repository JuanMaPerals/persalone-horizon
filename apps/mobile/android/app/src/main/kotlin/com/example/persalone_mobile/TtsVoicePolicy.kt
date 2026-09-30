package com.example.persalone_mobile

/**
 * What the policy needs to know about one platform voice, so the decision is
 * testable on the JVM (android.speech.tts.Voice cannot be built there).
 */
data class TtsVoiceInfo(
    val name: String,
    val language: String,
    val networkRequired: Boolean,
    val installed: Boolean,
)

/**
 * The provider declares on-device processing, so synthesis must never use a
 * voice that sends text to a server. Keep the engine's default voice when it
 * is local and installed; otherwise pick an installed local voice of the same
 * language (deterministically, by name); otherwise refuse (fail closed).
 */
object TtsVoicePolicy {
    const val refusedReason = "tts_network_voice_refused"

    fun select(language: String, current: TtsVoiceInfo?, voices: Collection<TtsVoiceInfo>): TtsVoiceInfo? {
        fun usable(voice: TtsVoiceInfo) =
            !voice.networkRequired && voice.installed && voice.language.equals(language, ignoreCase = true)
        if (current != null && usable(current)) return current
        return voices.filter(::usable).minByOrNull { it.name }
    }
}
