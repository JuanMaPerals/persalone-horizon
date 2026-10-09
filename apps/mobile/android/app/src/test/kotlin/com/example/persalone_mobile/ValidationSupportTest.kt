package com.example.persalone_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ValidationSupportTest {
    @Test
    fun epochAcceptsMicrosecondTimestampsBeyond32Bits() {
        // DateTime.now().microsecondsSinceEpoch arrives over the channel as Long.
        val epoch = 1_758_700_000_000_000L
        assertEquals(epoch, ValidationSupport.epochOf(epoch))
        assertEquals(3L, ValidationSupport.epochOf(3))
    }

    @Test
    fun epochRejectsMissingNegativeOrWrongTypes() {
        assertNull(ValidationSupport.epochOf(null))
        assertNull(ValidationSupport.epochOf(-1L))
        assertNull(ValidationSupport.epochOf("1758700000000000"))
        assertNull(ValidationSupport.epochOf(1.5))
    }

    @Test
    fun captureSourceDefaultsToVoiceRecognition() {
        assertEquals(CaptureSource.VOICE_RECOGNITION, ValidationSupport.captureSourceFor(null, true))
        assertEquals(CaptureSource.VOICE_RECOGNITION, ValidationSupport.captureSourceFor(null, false))
    }

    @Test
    fun captureSourceHonoursAbRequestOnlyInDebuggableBuilds() {
        assertEquals(
            CaptureSource.VOICE_COMMUNICATION,
            ValidationSupport.captureSourceFor("voiceCommunication", true),
        )
        assertEquals(
            CaptureSource.VOICE_RECOGNITION,
            ValidationSupport.captureSourceFor("voiceCommunication", false),
        )
    }

    @Test
    fun unknownCaptureSourceFailsInsteadOfFallingBack() {
        assertNull(ValidationSupport.captureSourceFor("unprocessed", true))
        assertNull(ValidationSupport.captureSourceFor("VOICE_COMMUNICATION", true))
    }

    @Test
    fun onlyVoiceCommunicationAttachesTheEchoCanceler() {
        assertEquals(false, CaptureSource.VOICE_RECOGNITION.attachEchoCanceler)
        assertEquals(true, CaptureSource.VOICE_COMMUNICATION.attachEchoCanceler)
    }

    @Test
    fun aPhysicalPhoneIsPhysical() {
        assertEquals(
            "physical",
            ValidationSupport.deviceClass(
                "samsung/dm3qxeea/dm3q:14/UP1A.231005.007/S918BXXU3BWK7:user/release-keys",
                "qcom", "dm3qxeea", "SM-S918B",
            ),
        )
    }

    @Test
    fun anyEmulatorSignWinsSoNothingIsOverclaimedAsAndroidReal() {
        val physical = arrayOf("google/oriole/oriole:14/AP1A/1:user/release-keys", "oriole", "oriole", "Pixel 6")
        for ((index, emulatorValue) in listOf(
            "generic_x86_64/sdk_gphone64_x86_64:14/x:userdebug/dev-keys",
            "ranchu",
            "sdk_gphone64_x86_64",
            "Android SDK built for x86",
        ).withIndex()) {
            val fields = physical.copyOf()
            fields[index] = emulatorValue
            assertEquals("emulator", ValidationSupport.deviceClass(fields[0], fields[1], fields[2], fields[3]))
        }
        assertEquals("emulator", ValidationSupport.deviceClass("x", "goldfish", "x", "x"))
        assertEquals("emulator", ValidationSupport.deviceClass("x", "vbox86", "x", "x"))
    }
}
