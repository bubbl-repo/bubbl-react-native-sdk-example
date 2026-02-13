@file:Suppress("DEPRECATION")

package com.bubbl.bridgesandbox

import android.app.Application
import com.facebook.react.bridge.*
import com.facebook.react.modules.core.DeviceEventManagerModule
import kotlinx.coroutines.*
import android.Manifest
import android.os.Build
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.location.Location
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import org.json.JSONArray
import org.json.JSONObject
import com.bubbl.bridgesandbox.TenantConfigStore
import com.bubbl.bridgesandbox.BubblInitManager
import tech.bubbl.sdk.notifications.NotificationRouter
import tech.bubbl.sdk.models.SurveyQuestion
import tech.bubbl.sdk.config.BubblConfig
import tech.bubbl.sdk.config.Environment
import tech.bubbl.sdk.models.ChoiceSelection
import tech.bubbl.sdk.models.SurveyAnswer
import tech.bubbl.sdk.BubblSdk
import tech.bubbl.sdk.utils.Logger
import java.util.Locale


@Suppress("DEPRECATION")
class BubblModule(private val rc: ReactApplicationContext) :
    ReactContextBaseJavaModule(rc){

    override fun getName() = "Bubbl"
    override fun initialize() {
        super.initialize()
        ensureNotificationBridge()
    }

    private var notifRegistered = false

    private val activityListener: ActivityEventListener = object : BaseActivityEventListener() {
        override fun onNewIntent(intent: Intent) {
            handleNotificationIntent(intent)
        }
    }

    private fun requireInitialized(
    promise: Promise? = null,
    functionName: String? = null
    ): Boolean {
    if (BubblInitManager.isInitialized()) return true

    val msg = if (functionName != null)
        "Call Bubbl.boot(...) before calling $functionName()."
    else
        "Call Bubbl.boot(...) before using Bubbl methods."

    promise?.reject("BUBBL_NOT_INITIALIZED", msg)
    return false
    }


    private fun extractPayload(intent: Intent?): String? {
        if (intent == null) return null
        return intent.getStringExtra("payload")
            ?: intent.getStringExtra("notification_payload")
            ?: intent.getStringExtra("data")
    }


    private val notifReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val json =  intent?.getStringExtra("payload") ?: return
            scope.launch { emitNotification(json) }

        }
    }

    private fun runOnUi(block: () -> Unit) = rc.runOnUiQueueThread(block)

    private fun runOnJs(block: () -> Unit) = rc.runOnJSQueueThread(block)

    private fun hasTenantChanged(
        previous: TenantConfigStore.TenantConfig?,
        apiKey: String,
        environment: Environment
    ): Boolean {
        if (previous == null) return true
        return previous.apiKey != apiKey || previous.environment != environment
    }

    private fun restartAppForTenantSwitch() {
        val appContext = rc.applicationContext
        val launchIntent = appContext.packageManager
            .getLaunchIntentForPackage(appContext.packageName)

        if (launchIntent == null) {
            Logger.log("BubblModule", "tenant switch restart skipped: launch intent missing")
            return
        }

        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)

        Handler(Looper.getMainLooper()).post {
            appContext.startActivity(launchIntent)
            rc.currentActivity?.finishAffinity()
            Runtime.getRuntime().exit(0)
        }
    }

    private fun emit(event: String, params: WritableMap) {
        runOnJs {
            rc.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
                .emit(event, params)
        }
    }

    @ReactMethod
    fun testNotification(promise: Promise) {
        val id = (System.currentTimeMillis() / 1000L).toInt()
        val payload = JSONObject().apply {
            put("id", id)
            put("headline", "Test Notification")
            put("body", "This is a local test notification.")
            put("locationId", "test-location")
            put("postMessage", "Thanks for testing!")
        }

        val json = payload.toString()

        // Emit in-app event so the modal can show immediately.
        scope.launch { emitNotification(json) }

        val channelId = "bubbl_test"
        val manager = rc.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Bubbl Test",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            manager.createNotificationChannel(channel)
        }

        val intent = Intent(rc, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("payload", json)
        }

        val pendingIntent = PendingIntent.getActivity(
            rc,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        )

        val notification = NotificationCompat.Builder(rc, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Test Notification")
            .setContentText("This is a local test notification.")
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        manager.notify(id, notification)
        promise.resolve(true)
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var geofenceJob: Job? = null
    private var deviceLogJob: Job? = null
    @Volatile private var lastDeviceLogFingerprint: String = ""


    private fun ensureNotificationBridge() {
        if (notifRegistered) return
        notifRegistered = true

        // listen for Bubbl SDK local broadcast
        LocalBroadcastManager.getInstance(rc).registerReceiver(
            notifReceiver,
            IntentFilter(NotificationRouter.BROADCAST)
        )
        runOnUi {

        // listen for "opened from notification" intents
        rc.addActivityEventListener(activityListener)

        // handle cold-start intent if app was launched from notification
        handleNotificationIntent(rc.currentActivity?.intent)
        }
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val json = extractPayload(intent) ?: return
        intent?.removeExtra("payload")
        scope.launch { emitNotification(json) }
    }


    private fun emitNotification(json: String) {
        try {
            val obj = JSONObject(json)

            val map = Arguments.createMap().apply {
                putInt("id", obj.optInt("id"))
                putNullableString("headline", obj.optNullableString("headline"))
                putNullableString("body", obj.optNullableString("body"))
                putNullableString("mediaUrl", obj.optNullableString("mediaUrl"))
                putNullableString("mediaType", obj.optNullableString("mediaType"))
                putNullableString("activation", obj.optNullableString("activation"))
                putNullableString("ctaLabel", obj.optNullableString("ctaLabel"))
                putNullableString("ctaUrl", obj.optNullableString("ctaUrl"))
                putNullableString("locationId", obj.optNullableString("locationId"))
                putNullableString("postMessage", obj.optNullableString("postMessage"))

                val questionsArr = obj.optJSONArray("questions")
                if (questionsArr == null) {
                    putNull("questions")
                } else {
                    putArray("questions", jsonQuestionsToWritableArray(questionsArr))
                }

                putString("raw", json)
            }

            emit("bubbl_notification", map)
        } catch (t: Throwable) {
            val map = Arguments.createMap().apply { putString("raw", json) }
            emit("bubbl_notification", map)
        }
    }

    private fun WritableMap.putNullableString(key: String, value: String?) {
        if (value == null) {
            putNull(key)
        } else {
            putString(key, value)
        }
    }

    private fun JSONObject.optNullableString(key: String): String? {
        return if (!has(key) || isNull(key)) null else optString(key)
    }

    private fun jsonQuestionsToWritableArray(arr: JSONArray): WritableArray {
        val out = Arguments.createArray()
        for (i in 0 until arr.length()) {
            val q = arr.optJSONObject(i) ?: continue
            val qm = Arguments.createMap().apply {
                putInt("id", q.optInt("id"))
                putNullableString("question", q.optNullableString("question"))
                putNullableString("question_type", q.optNullableString("question_type"))
                putBoolean("has_choices", q.optBoolean("has_choices", false))
                putInt("position", q.optInt("position"))

                val choices = q.optJSONArray("choices")
                if (choices == null) {
                    putArray("choices", Arguments.createArray())
                } else {
                    val choicesOut = Arguments.createArray()
                    for (j in 0 until choices.length()) {
                        val c = choices.optJSONObject(j) ?: continue
                        val cm = Arguments.createMap().apply {
                            putInt("id", c.optInt("id"))
                            putNullableString("choice", c.optNullableString("choice"))
                            putInt("position", c.optInt("position"))
                        }
                        choicesOut.pushMap(cm)
                    }
                    putArray("choices", choicesOut)
                }
            }
            out.pushMap(qm)
        }
        return out
    }

    private fun currentDeviceId(): String {
        return Settings.Secure.getString(rc.contentResolver, Settings.Secure.ANDROID_ID) ?: "unknown"
    }

    private fun currentDeviceSuffix(): String {
        val normalized = currentDeviceId().replace(Regex("[^A-Za-z0-9]"), "")
        if (normalized.isEmpty()) {
            return "-----"
        }
        return normalized.takeLast(5)
    }

    private fun readDeviceLogTail(maxLines: Int): List<String> {
        val file = Logger.getLogFile() ?: return emptyList()
        if (!file.exists()) {
            return emptyList()
        }

        return runCatching {
            file.readLines().takeLast(maxLines)
        }.getOrDefault(emptyList())
    }

    private fun emitDeviceLogSnapshot(maxLines: Int, force: Boolean = false) {
        val lines = readDeviceLogTail(maxLines)
        val fingerprint = lines.joinToString("\n")

        if (!force && fingerprint == lastDeviceLogFingerprint) {
            return
        }

        lastDeviceLogFingerprint = fingerprint

        val payload = Arguments.createMap().apply {
            putString("deviceType", "android")
            putString("deviceId", currentDeviceId())
            putString("deviceIdSuffix", currentDeviceSuffix())
            putDouble("timestamp", System.currentTimeMillis().toDouble())

            val linesArray = Arguments.createArray()
            lines.forEach { line ->
                linesArray.pushString(line)
            }
            putArray("lines", linesArray)
        }

        emit("bubbl_device_log", payload)
    }

    private data class GeofenceCircle(
        val centerLatitude: Double,
        val centerLongitude: Double,
        val radiusMeters: Double,
    )

    private fun deriveGeofenceCircle(vertices: List<com.google.android.gms.maps.model.LatLng>): GeofenceCircle? {
        if (vertices.isEmpty()) {
            return null
        }

        val centroid = vertices.fold(Pair(0.0, 0.0)) { acc, point ->
            Pair(acc.first + point.latitude, acc.second + point.longitude)
        }

        val centerLat = centroid.first / vertices.size
        val centerLng = centroid.second / vertices.size

        var radius = 0.0
        vertices.forEach { point ->
            val distances = FloatArray(1)
            Location.distanceBetween(
                centerLat,
                centerLng,
                point.latitude,
                point.longitude,
                distances,
            )
            radius = maxOf(radius, distances[0].toDouble())
        }

        return GeofenceCircle(centerLatitude = centerLat, centerLongitude = centerLng, radiusMeters = radius)
    }


    @ReactMethod
    fun init(apiKey: String, options: ReadableMap, promise: Promise) {
        boot(apiKey, options.getString("environment") ?: "STAGING", options, promise)
    }

    @ReactMethod
    fun startLocationTracking(promise: Promise) {
        if (!requireInitialized(promise, "startLocationTracking")) return
        try {
            Logger.log("BubblModule", "startLocationTracking requested from RN bridge")
            BubblSdk.startLocationTracking(rc)
            promise.resolve(true)
        } catch (t: Throwable) {
            promise.reject("BUBBL_START_LOCATION_FAILED", t.message, t)
        }
    }


    @ReactMethod
    fun refreshGeofence(lat: Double, lng: Double) {
        if (!requireInitialized(functionName = "refreshGeofence")) return
        Logger.log(
            "BubblModule",
            "refreshGeofence requested lat=$lat lng=$lng"
        )
        BubblSdk.refreshGeofence(lat, lng)
    }

    @ReactMethod
    fun getDeviceLogStreamInfo(promise: Promise) {
        val map = Arguments.createMap().apply {
            putString("deviceType", "android")
            putString("deviceId", currentDeviceId())
            putString("deviceIdSuffix", currentDeviceSuffix())
        }
        promise.resolve(map)
    }

    @ReactMethod
    fun getDeviceLogTail(maxLines: Int, promise: Promise) {
        val clampedMaxLines = maxLines.coerceIn(10, 200)
        val lines = readDeviceLogTail(clampedMaxLines)
        val arr = Arguments.createArray()
        lines.forEach { line ->
            arr.pushString(line)
        }
        promise.resolve(arr)
    }

    @ReactMethod
    fun startDeviceLogStream(options: ReadableMap, promise: Promise) {
        val requestedInterval = when {
            options.hasKey("intervalMs") && !options.isNull("intervalMs") ->
                options.getDouble("intervalMs").toLong()
            else -> 2500L
        }
        val requestedLines = when {
            options.hasKey("maxLines") && !options.isNull("maxLines") ->
                options.getInt("maxLines")
            else -> 80
        }
        val targetSuffix = when {
            options.hasKey("targetDeviceSuffix") && !options.isNull("targetDeviceSuffix") ->
                options.getString("targetDeviceSuffix")?.trim().orEmpty()
            else -> ""
        }.lowercase(Locale.US)

        val intervalMs = requestedInterval.coerceIn(1000L, 30000L)
        val maxLines = requestedLines.coerceIn(10, 200)
        val deviceSuffix = currentDeviceSuffix().lowercase(Locale.US)

        if (targetSuffix.isNotEmpty() && targetSuffix != deviceSuffix) {
            val result = Arguments.createMap().apply {
                putBoolean("started", false)
                putString("reason", "device_suffix_mismatch")
                putString("deviceIdSuffix", currentDeviceSuffix())
            }
            promise.resolve(result)
            return
        }

        deviceLogJob?.cancel()
        lastDeviceLogFingerprint = ""
        emitDeviceLogSnapshot(maxLines, force = true)

        deviceLogJob = scope.launch {
            while (isActive) {
                delay(intervalMs)
                emitDeviceLogSnapshot(maxLines)
            }
        }

        val result = Arguments.createMap().apply {
            putBoolean("started", true)
            putString("reason", "ok")
            putString("deviceIdSuffix", currentDeviceSuffix())
        }
        promise.resolve(result)
    }

    @ReactMethod
    fun stopDeviceLogStream() {
        deviceLogJob?.cancel()
        deviceLogJob = null
    }

    @ReactMethod
    fun updateSegments(tags: ReadableArray, promise: Promise) {
        if (!requireInitialized(promise, "updateSegments")) return
        val list = (0 until tags.size()).mapNotNull { tags.getString(it) }.filter { it.isNotBlank() }
        BubblSdk.updateSegments(list) { ok ->
            if (ok) promise.resolve(true)
            else promise.reject("BUBBL_SEGMENTS_FAILED", "updateSegments failed")
        }
    }

    @ReactMethod
    fun setCorrelationId(correlationId: String, promise: Promise) {
        if (!requireInitialized(promise, "setCorrelationId")) return
        BubblSdk.setCorrelationId(correlationId) { ok ->
            if (ok) promise.resolve(true)
            else promise.reject("BUBBL_CORRELATION_ID_FAILED", "setCorrelationId failed")
        }
    }

    @ReactMethod
    fun getCorrelationId(promise: Promise) {
        if (!requireInitialized(promise, "getCorrelationId")) return
        promise.resolve(BubblSdk.getCorrelationId())
    }

    @ReactMethod
    fun clearCorrelationId(promise: Promise) {
        if (!requireInitialized(promise, "clearCorrelationId")) return
        BubblSdk.clearCorrelationId { ok ->
            if (ok) promise.resolve(true)
            else promise.reject("BUBBL_CORRELATION_ID_FAILED", "clearCorrelationId failed")
        }
    }


    @ReactMethod
    fun getPrivacyText(promise: Promise) {
        promise.resolve(BubblSdk.getPrivacyText())
    }


    @ReactMethod
    fun refreshPrivacyText(promise: Promise) {
        BubblSdk.refreshPrivacyText { txt ->
            if (txt != null) promise.resolve(txt) else promise.reject("BUBBL_PRIVACY_FAILED", "refreshPrivacyText failed")
        }
    }

    @ReactMethod
    fun getApiKey(promise: Promise) {
        promise.resolve(BubblSdk.getApiKey)
    }

    @ReactMethod
    fun sayHello(promise: Promise) {
        promise.resolve(BubblSdk.sayHello())
    }

    @ReactMethod
    fun sendEvent(
        curatedNotificationID: String,
        locationID: String,
        type: String,
        activity: String,
        latitude: Double,
        longitude: Double,
        promise: Promise
    ) {
        if (!requireInitialized(promise, "sendEvent")) return
        BubblSdk.sendEvent(
            curatedNotificationID = curatedNotificationID,
            locationID = locationID,
            type = type,
            activity = activity,
            latitude = latitude,
            longitude = longitude
        ) { ok ->
            promise.resolve(ok)
        }
    }

    @ReactMethod fun startGeofenceUpdates() {
        if (!requireInitialized(functionName = "startGeofenceUpdates")) return
        if (geofenceJob != null) return
        geofenceJob = scope.launch {
            BubblSdk.geofenceFlow.collect { snap ->
                snap ?: return@collect
                Logger.log(
                    "BubblModule",
                    "geofence snapshot received campaigns=${snap.stats.campaignsTotal} polygons=${snap.polygons.size}"
                )
                val payload = Arguments.createMap().apply {
                    val stats = Arguments.createMap().apply {
                        putInt("campaignsTotal", snap.stats.campaignsTotal)
                        putInt("polygonsTotal", snap.stats.polygonsTotal)
                    }
                    putMap("stats", stats)

                    val polygonsArr = Arguments.createArray()
                    val circlesArr = Arguments.createArray()
                    snap.polygons.forEach { p ->
                        val poly = Arguments.createMap().apply {
                            putInt("campaignId", p.campaignId)
                            putString("campaignName", p.campaignName)

                            val verticesArr = Arguments.createArray()
                            p.vertices.forEach { v ->
                                val vMap = Arguments.createMap().apply {
                                    putDouble("latitude", v.latitude)
                                    putDouble("longitude", v.longitude)
                                }
                                verticesArr.pushMap(vMap)
                            }
                            putArray("vertices", verticesArr)
                        }
                        polygonsArr.pushMap(poly)

                        deriveGeofenceCircle(p.vertices)?.let { circle ->
                            val circleMap = Arguments.createMap().apply {
                                putInt("campaignId", p.campaignId)
                                putString("campaignName", p.campaignName)
                                val centerMap = Arguments.createMap().apply {
                                    putDouble("latitude", circle.centerLatitude)
                                    putDouble("longitude", circle.centerLongitude)
                                }
                                putMap("center", centerMap)
                                putDouble("radius", circle.radiusMeters)
                            }
                            circlesArr.pushMap(circleMap)
                        }
                    }
                    putArray("polygons", polygonsArr)
                    putArray("circles", circlesArr)
                }
                Logger.log(
                    "BubblModule",
                    "emitting geofence payload polygons=${snap.polygons.size} circles=${payload.getArray("circles")?.size() ?: 0}"
                )
                emit("bubbl_geofence", payload)
            }
        }
    }

    @ReactMethod fun hasCampaigns(promise: Promise) {
        if (!requireInitialized(promise, "hasCampaigns")) return
        promise.resolve(BubblSdk.hasCampaigns())
    }

    @ReactMethod fun getCampaignCount(promise: Promise) {
        if (!requireInitialized(promise, "getCampaignCount")) return
        promise.resolve(BubblSdk.getCampaignCount())
    }

    @ReactMethod
    fun forceRefreshCampaigns(promise: Promise) {
        if (!requireInitialized(promise, "forceRefreshCampaigns")) return
        BubblSdk.forceRefreshCampaigns()
        promise.resolve(true)
    }

    @ReactMethod fun clearCachedCampaigns() {
        if (!requireInitialized(functionName = "clearCachedCampaigns")) return
        BubblSdk.clearCachedCampaigns()
    }

    @ReactMethod
    fun trackSurveyEvent(notificationId: String, locationId: String, activity: String, promise: Promise) {
        if (!requireInitialized(promise, "trackSurveyEvent")) return
        BubblSdk.trackSurveyEvent(
            notificationId = notificationId,
            locationId = locationId,
            activity = activity
        ) { success ->
            promise.resolve(success)
        }
    }


    @ReactMethod
    fun submitSurveyResponse(
        notificationId: String,
        locationId: String,
        answers: ReadableArray,
        promise: Promise
    ) {
        if (!requireInitialized(promise, "submitSurveyResponse")) return
        try {
            val parsed = mutableListOf<SurveyAnswer>()

            for (i in 0 until answers.size()) {
                val m = answers.getMap(i) ?: continue

                val qid = m.getInt("question_id")
                val type = m.getString("type") ?: ""
                val value = m.getString("value") ?: ""

                val choiceList = if (m.hasKey("choice") && !m.isNull("choice")) {
                    val choiceArr = m.getArray("choice")
                    val list = mutableListOf<ChoiceSelection>()
                    if (choiceArr != null) {
                        for (j in 0 until choiceArr.size()) {
                            val cm = choiceArr.getMap(j) ?: continue
                            if (cm.hasKey("choice_id") && !cm.isNull("choice_id")) {
                                list.add(ChoiceSelection(choice_id = cm.getInt("choice_id")))
                            }
                        }
                    }
                    list
                } else null

                parsed.add(
                    SurveyAnswer(
                        question_id = qid,
                        type = type,
                        value = value,
                        choice = choiceList
                    )
                )
            }

            BubblSdk.submitSurveyResponse(
                notificationId = notificationId,
                locationId = locationId,
                answers = parsed
            ) { success ->
                promise.resolve(success)
            }
        } catch (t: Throwable) {
            promise.reject("BUBBL_SURVEY_SUBMIT_FAILED", t.message, t)
        }
    }


    @ReactMethod
    fun getCurrentConfiguration(promise: Promise) {
        try {
            val cfg = BubblSdk.getCurrentConfiguration()
            if (cfg == null) {
                promise.resolve(null)
                return
            }
            val map = Arguments.createMap().apply {
                putInt("notificationsCount", cfg.notificationsCount)
                putInt("daysCount", cfg.daysCount)
                putInt("batteryCount", cfg.batteryCount)
                putString("privacyText", cfg.privacyText)
            }
            promise.resolve(map)
        } catch (t: Throwable) {
            promise.reject("BUBBL_GET_CONFIG_FAILED", t.message, t)
        }
    }

    @ReactMethod
    fun requiredPermissions(promise: Promise) {
        val arr = Arguments.createArray()
        arr.pushString(Manifest.permission.ACCESS_FINE_LOCATION)
        arr.pushString(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arr.pushString(Manifest.permission.POST_NOTIFICATIONS)
        }
        promise.resolve(arr)
    }

    @ReactMethod
    fun locationGranted(promise: Promise) {
        val fine = ContextCompat.checkSelfPermission(rc, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(rc, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        promise.resolve(fine || coarse)
    }

    @ReactMethod
    fun notificationGranted(promise: Promise) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            promise.resolve(true)
            return
        }
        val ok = ContextCompat.checkSelfPermission(rc, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        promise.resolve(ok)
    }

    @ReactMethod
    fun cta(nId: Int, locationId: String) {
        if (!requireInitialized(functionName = "cta")) return
        runOnUi {
            BubblSdk.cta(nId = nId, locationId = locationId)
        }
    }


    @ReactMethod
    fun stopGeofenceUpdates() {
        geofenceJob?.cancel()
        geofenceJob = null
    }

    @ReactMethod
    fun clearStoredConfig(promise: Promise) {
        try {
            TenantConfigStore.clear(rc)
            promise.resolve(true)
        } catch (t: Throwable) {
            promise.reject("BUBBL_CLEAR_CONFIG_FAILED", t.message, t)
        }
    }


    //TenantSwitch
    @ReactMethod
    fun getTenantConfig(promise: Promise) {
        try {
            val cfg = TenantConfigStore.load(rc)
            if (cfg == null) {
                promise.resolve(null)
                return
            }

            val masked = maskApiKey(cfg.apiKey)
            val map = Arguments.createMap().apply {
                putString("apiKeyMasked", masked)
                putString("environment", cfg.environment.name)
            }
            promise.resolve(map)
        } catch (t: Throwable) {
            promise.reject("BUBBL_TENANT_GET_FAILED", t.message, t)
        }
    }

    private fun maskApiKey(apiKey: String): String {
        if (apiKey.length <= 8) return "****"
        val start = apiKey.take(4)
        val end = apiKey.takeLast(4)
        return "$start••••$end"
    }

    @ReactMethod
    fun setTenantConfig(apiKey: String, environment: String, promise: Promise) {
        try {
            val env = try {
                tech.bubbl.sdk.config.Environment.valueOf(environment)
            } catch (_: IllegalArgumentException) {
                tech.bubbl.sdk.config.Environment.STAGING
            }

            TenantConfigStore.save(rc, apiKey.trim(), env)
            promise.resolve(true)
        } catch (t: Throwable) {
            promise.reject("BUBBL_TENANT_SET_FAILED", t.message, t)
        }
    }

    @ReactMethod
    fun clearTenantConfig(promise: Promise) {
        try {
            TenantConfigStore.clear(rc)
            promise.resolve(true)
        } catch (t: Throwable) {
            promise.reject("BUBBL_TENANT_CLEAR_FAILED", t.message, t)
        }
    }


    @ReactMethod
    fun boot(apiKey: String, environment: String, options: ReadableMap, promise: Promise) {
        try {
            val env = try { Environment.valueOf(environment) } catch (_: IllegalArgumentException) { Environment.STAGING }
            val normalizedApiKey = apiKey.trim()
            val previousTenant = TenantConfigStore.load(rc)
            val tenantChanged = hasTenantChanged(previousTenant, normalizedApiKey, env)

            TenantConfigStore.save(rc, normalizedApiKey, env)

            val tags = mutableListOf<String>()
            options.getArray("segmentationTags")?.let { arr ->
                for (i in 0 until arr.size()) arr.getString(i)?.let(tags::add)
            }

            val pollMs =
                if (options.hasKey("geoPollIntervalMs")) options.getDouble("geoPollIntervalMs").toLong()
                else 300_000L

            val defaultDistance =
                if (options.hasKey("defaultDistance")) options.getInt("defaultDistance")
                else 25

            if (BubblInitManager.isInitialized() && tenantChanged) {
                ensureNotificationBridge()
                Logger.log(
                    "BubblModule",
                    "boot detected tenant change after SDK init; restarting app to reinitialize runtime"
                )
                promise.resolve(Arguments.createMap().apply {
                    putBoolean("initializedNow", false)
                    putBoolean("alreadyInitialized", true)
                    putBoolean("restartingForTenantChange", true)
                })
                restartAppForTenantSwitch()
                return
            }

            val app = rc.applicationContext as Application
            val didInit = BubblInitManager.ensureInit(
                app,
                BubblConfig(
                    apiKey = normalizedApiKey,
                    environment = env,
                    segmentationTags = tags,
                    geoPollInterval = pollMs,
                    defaultDistance = defaultDistance
                )
            )

            ensureNotificationBridge()

            Logger.log(
                "BubblModule",
                "boot completed env=$env initializedNow=$didInit tags=${tags.size} pollMs=$pollMs defaultDistance=$defaultDistance"
            )

            promise.resolve(Arguments.createMap().apply {
                putBoolean("initializedNow", didInit)
                putBoolean("alreadyInitialized", !didInit)
            })
        } catch (t: Throwable) {
            promise.reject("BUBBL_BOOT_FAILED", t.message, t)
        }
    }


    override fun invalidate() {
        try {
            if (notifRegistered) {
                LocalBroadcastManager.getInstance(rc).unregisterReceiver(notifReceiver)
                rc.removeActivityEventListener(activityListener)
                notifRegistered = false
            }
        } catch (_: Throwable) {}
        deviceLogJob?.cancel()
        deviceLogJob = null
        scope.cancel()
        super.invalidate()
    }
}
