package com.bubbl.bridgesandbox

import android.app.Application
import com.facebook.react.PackageList
import com.facebook.react.ReactApplication
import com.facebook.react.ReactHost
import com.google.firebase.FirebaseApp
import com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative
import com.facebook.react.defaults.DefaultReactHost.getDefaultReactHost
import com.bubbl.bridgesandbox.BubblPackage
import tech.bubbl.sdk.BubblSdk
import tech.bubbl.sdk.utils.Logger
import tech.bubbl.sdk.config.BubblConfig
import tech.bubbl.sdk.config.Environment
import com.bubbl.bridgesandbox.TenantConfigStore

class MainApplication : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    getDefaultReactHost(
      context = applicationContext,
      packageList =
        PackageList(this).packages.apply {
          // Packages that cannot be autolinked yet can be added manually here, for example:
            add(BubblPackage())

        },
    )
  }

    override fun onCreate() {
        super.onCreate()

        if (FirebaseApp.getApps(this).isEmpty()) {
            FirebaseApp.initializeApp(this)
        }
        

        val cfg = TenantConfigStore.load(this)
        if (cfg != null) {
            BubblInitManager.ensureInit(
                app = this,
                config = TenantConfigStore.toBubblConfig(cfg)
            )
        }

        loadReactNative(this)
    }
}