package com.bubbl.bridgesandbox

import android.app.Application
import tech.bubbl.sdk.BubblSdk
import tech.bubbl.sdk.config.BubblConfig

object BubblInitManager {
    @Volatile private var initialized = false

    fun isInitialized(): Boolean = initialized

    fun markInitialized() {
        initialized = true
    }

    fun ensureInit(app: Application, config: BubblConfig): Boolean {
        if (initialized) return false
        synchronized(this) {
            if (initialized) return false
            BubblSdk.init(app, config)
            initialized = true
            return true
        }
    }
}
