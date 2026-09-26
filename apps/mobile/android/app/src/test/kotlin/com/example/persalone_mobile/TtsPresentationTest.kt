package com.example.persalone_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TtsPresentationTest {
    private fun pcm(vararg samples: Int): ByteArray {
        val bytes = ByteArray(samples.size * 2)
        samples.forEachIndexed { i, s ->
            bytes[i * 2] = (s and 0xff).toByte()
            bytes[i * 2 + 1] = ((s shr 8) and 0xff).toByte()
        }
        return bytes
    }

    @Test
    fun leadingSilenceIsSkippedInBothPolarities() {
        assertEquals(3, TtsPresentation.firstAudibleFrame(pcm(0, 12, -300, 5000, 0), 10, 1))
        assertEquals(2, TtsPresentation.firstAudibleFrame(pcm(0, 0, -5000), 6, 1))
    }

    @Test
    fun silentOrTruncatedChunkHasNoAudibleFrame() {
        assertEquals(-1, TtsPresentation.firstAudibleFrame(pcm(0, 100, -328, 328), 8, 1))
        // The loud sample lies beyond the declared length: not scanned.
        assertEquals(-1, TtsPresentation.firstAudibleFrame(pcm(0, 0, 9000), 4, 1))
    }

    @Test
    fun stereoFramesAreAudibleWhenEitherChannelIs() {
        assertEquals(1, TtsPresentation.firstAudibleFrame(pcm(0, 0, 0, -9000), 8, 2))
    }

    @Test
    fun presentationIsInterpolatedBackIntoPlayedFrames() {
        // Frame 16000 presented at t=2s at 16 kHz: frame 8000 was presented 0.5 s earlier.
        assertEquals(1_500_000_000L, TtsPresentation.presentedAtNanos(8_000, 16_000, 2_000_000_000L, 16_000))
        assertEquals(2_000_000_000L, TtsPresentation.presentedAtNanos(16_000, 16_000, 2_000_000_000L, 16_000))
    }

    @Test
    fun aFrameNotYetPresentedIsNeverPredicted() {
        assertNull(TtsPresentation.presentedAtNanos(16_001, 16_000, 2_000_000_000L, 16_000))
        assertNull(TtsPresentation.presentedAtNanos(-1, 16_000, 2_000_000_000L, 16_000))
        assertNull(TtsPresentation.presentedAtNanos(0, 16_000, 2_000_000_000L, 0))
    }

    @Test
    fun onlyPcm16MonoOrStereoIsPlayable() {
        assertTrue(TtsPresentation.isSupportedFormat(true, 1, 22_050))
        assertTrue(TtsPresentation.isSupportedFormat(true, 2, 24_000))
        assertFalse(TtsPresentation.isSupportedFormat(false, 1, 22_050))
        assertFalse(TtsPresentation.isSupportedFormat(true, 6, 22_050))
        assertFalse(TtsPresentation.isSupportedFormat(true, 1, 0))
    }
}
