package com.example.persalone_mobile

/**
 * Decision for the Halo BLE path, kept free of Android runtime state so it
 * runs as a JVM unit test. Anything other than "granted" is fail-closed: the
 * caller must not touch Bluetooth.
 */
object BlePermissions {
    /** BLUETOOTH_SCAN / BLUETOOTH_CONNECT exist from Android 12 (API 31). */
    const val minSdk = 31

    const val scan = "android.permission.BLUETOOTH_SCAN"
    const val connect = "android.permission.BLUETOOTH_CONNECT"
    val required = listOf(scan, connect)

    /** Permissions still to request; empty below [minSdk] (nothing to ask). */
    fun missing(sdk: Int, isGranted: (String) -> Boolean): List<String> =
        if (sdk < minSdk) emptyList() else required.filterNot(isGranted)

    /**
     * Coded result for the platform channel: `granted`, `reason` and, when
     * denied, the short names of the missing permissions. Older Android would
     * need a location permission to scan, which this app does not request.
     */
    fun decide(sdk: Int, isGranted: (String) -> Boolean): Map<String, Any> {
        if (sdk < minSdk) {
            return mapOf("granted" to false, "reason" to "bleRequiresAndroid12")
        }
        val missing = missing(sdk, isGranted)
        if (missing.isEmpty()) return mapOf("granted" to true, "reason" to "granted")
        return mapOf(
            "granted" to false,
            "reason" to "permissionDenied",
            "missing" to missing.map { it.substringAfterLast('.') },
        )
    }
}
