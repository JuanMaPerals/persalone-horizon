package com.example.persalone_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TtsVoicePolicyTest {
    private fun voice(name: String, language: String = "spa", network: Boolean = false, installed: Boolean = true) =
        TtsVoiceInfo(name, language, network, installed)

    @Test
    fun keepsALocalInstalledDefaultVoice() {
        val current = voice("es-local-default")
        assertEquals(current, TtsVoicePolicy.select("spa", current, listOf(voice("es-a"), current)))
    }

    @Test
    fun replacesANetworkDefaultWithALocalVoiceOfTheSameLanguage() {
        val network = voice("es-network", network = true)
        val chosen = TtsVoicePolicy.select(
            "spa",
            network,
            listOf(network, voice("es-z"), voice("es-b"), voice("en-local", language = "eng")),
        )
        assertEquals("es-b", chosen?.name)
    }

    @Test
    fun neverChoosesANotInstalledVoice() {
        val chosen = TtsVoicePolicy.select(
            "spa",
            voice("es-network", network = true),
            listOf(voice("es-a", installed = false), voice("es-c")),
        )
        assertEquals("es-c", chosen?.name)
    }

    @Test
    fun refusesWhenOnlyNetworkOrForeignVoicesExist() {
        assertNull(
            TtsVoicePolicy.select(
                "spa",
                voice("es-network", network = true),
                listOf(voice("es-network", network = true), voice("en-local", language = "eng")),
            ),
        )
        assertNull(TtsVoicePolicy.select("spa", null, emptyList()))
    }
}
