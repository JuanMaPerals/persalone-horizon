package com.example.persalone_mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BlePermissionsTest {
    private fun grants(vararg granted: String): (String) -> Boolean = { it in granted }

    @Test
    fun bothPermissionsOnAndroid12AreGranted() {
        val decision = BlePermissions.decide(31, grants(BlePermissions.scan, BlePermissions.connect))
        assertEquals(mapOf("granted" to true, "reason" to "granted"), decision)
    }

    @Test
    fun aPartialGrantIsDeniedAndNamesWhatIsMissing() {
        val decision = BlePermissions.decide(34, grants(BlePermissions.scan))
        assertEquals(false, decision["granted"])
        assertEquals("permissionDenied", decision["reason"])
        assertEquals(listOf("BLUETOOTH_CONNECT"), decision["missing"])
    }

    @Test
    fun nothingGrantedListsBothPermissions() {
        val decision = BlePermissions.decide(35, grants())
        assertEquals(listOf("BLUETOOTH_SCAN", "BLUETOOTH_CONNECT"), decision["missing"])
    }

    @Test
    fun olderAndroidFailsClosedWithoutAskingForLocation() {
        // Even "granted" answers cannot open the path below Android 12.
        val decision = BlePermissions.decide(30, grants(BlePermissions.scan, BlePermissions.connect))
        assertEquals(mapOf("granted" to false, "reason" to "bleRequiresAndroid12"), decision)
        assertTrue(BlePermissions.missing(30, grants()).isEmpty())
    }

    @Test
    fun onlyScanAndConnectAreEverRequested() {
        assertEquals(
            listOf("android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"),
            BlePermissions.missing(33, grants()),
        )
    }
}
