import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import Bubbl

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
  private enum BubblTenantKeys {
    static let apiKey = "bubbl_api_key"
    static let environment = "bubbl_environment"
  }

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?
  private var cachedLaunchOptions: [UIApplication.LaunchOptionsKey: Any]?
  private let apnsRegisteredDefaultsKey = "bubbl_apns_registered"
  private var didBootstrapBubblFromStoredTenant = false

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    cachedLaunchOptions = launchOptions
    configureFirebaseIfNeeded(context: "didFinishLaunchingWithOptions")

    if FirebaseApp.app() != nil {
      Messaging.messaging().delegate = self
    }

    UNUserNotificationCenter.current().delegate = self

    let launchedForLocation = launchOptions?[.location] != nil
    let launchedForRemoteNotification = launchOptions?[.remoteNotification] != nil
    if launchedForLocation || launchedForRemoteNotification {
      let reason = launchedForLocation ? "launch_location" : "launch_remote_notification"
      bootstrapBubblFromStoredTenantIfNeeded(reason: reason)
    }

    prepareReactNativeFactoryIfNeeded()

    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let granted =
        settings.authorizationStatus == .authorized ||
        settings.authorizationStatus == .provisional ||
        settings.authorizationStatus == .ephemeral
      if granted {
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    }

    if let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
      NotificationCenter.default.post(
        name: NSNotification.Name("BubblNotificationOpened"),
        object: nil,
        userInfo: userInfo
      )
    }

    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
  }

  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}

  func attachReactNative(to window: UIWindow) {
    prepareReactNativeFactoryIfNeeded()
    guard let factory = reactNativeFactory else { return }
    factory.startReactNative(
      withModuleName: "BubblBridgeSandbox",
      in: window,
      launchOptions: cachedLaunchOptions
    )
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    UserDefaults.standard.set(true, forKey: apnsRegisteredDefaultsKey)
    let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    NSLog("[BubblBridge] APNs token: %@", tokenString)
    Messaging.messaging().apnsToken = deviceToken
    NotificationCenter.default.post(
      name: NSNotification.Name("BubblAPNsRegistered"),
      object: nil,
      userInfo: ["apnsToken": tokenString]
    )

    fetchFCMToken(source: "postAPNs")
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    UserDefaults.standard.set(false, forKey: apnsRegisteredDefaultsKey)
#if DEBUG
#if targetEnvironment(simulator)
    // Simulator doesn't support APNs; avoid noisy logs.
    return
#endif
#endif
    NSLog("[Bubbl] APNs registration failed: \(error.localizedDescription)")
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    NSLog("[BubblBridge] Did receive remote notification in background fetch handler.")
    Messaging.messaging().appDidReceiveMessage(userInfo)
    BubblPlugin.shared.refetchGeofence()
    NotificationCenter.default.post(
      name: NSNotification.Name("BubblNotificationReceived"),
      object: nil,
      userInfo: userInfo
    )
    completionHandler(.newData)
  }

  // MARK: - UNUserNotificationCenterDelegate (DEBUG simulator)
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    Messaging.messaging().appDidReceiveMessage(notification.request.content.userInfo)
    NotificationManager.shared.userNotificationCenter(
      center,
      willPresent: notification
    ) { _ in }

    var payload = notification.request.content.userInfo
    payload["headline"] = notification.request.content.title
    payload["body"] = notification.request.content.body
    NotificationCenter.default.post(
      name: NSNotification.Name("BubblNotificationReceived"),
      object: nil,
      userInfo: payload
    )
#if DEBUG
#if targetEnvironment(simulator)
    if notification.request.content.categoryIdentifier == "bubbl_simulated" {
      completionHandler([.banner, .sound])
      return
    }
#endif
#endif
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Messaging.messaging().appDidReceiveMessage(response.notification.request.content.userInfo)
    NotificationManager.shared.userNotificationCenter(
      center,
      didReceive: response
    ) {}

    var payload = response.notification.request.content.userInfo
    payload["headline"] = response.notification.request.content.title
    payload["body"] = response.notification.request.content.body
    NotificationCenter.default.post(
      name: NSNotification.Name("BubblNotificationOpened"),
      object: nil,
      userInfo: payload
    )
    completionHandler()
  }

  // MARK: - MessagingDelegate
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    guard let token = fcmToken, !token.isEmpty else {
      NSLog("[BubblBridge] Messaging delegate token unavailable.")
      return
    }
    publishFCMToken(token, source: "messagingDelegate")
  }

  private func fetchFCMToken(source: String) {
    guard FirebaseApp.app() != nil else { return }
    if Messaging.messaging().apnsToken == nil {
      NSLog("[BubblBridge] Deferring FCM token fetch (%@): APNs token not set yet.", source)
      return
    }
    Messaging.messaging().token { [weak self] token, error in
      if let error = error {
        NSLog("[BubblBridge] FCM token fetch (%@) failed: %@", source, error.localizedDescription)
        return
      }
      guard let token = token, !token.isEmpty else {
        NSLog("[BubblBridge] FCM token fetch (%@) returned empty token.", source)
        return
      }
      self?.publishFCMToken(token, source: source)
    }
  }

  private func publishFCMToken(_ token: String, source: String) {
    NSLog("[BubblBridge] FCM token (%@): %@", source, token)
    BubblPlugin.updateFCMToken(token)
    NotificationCenter.default.post(
      name: NSNotification.Name("BubblFCMTokenRefreshed"),
      object: nil,
      userInfo: ["token": token]
    )
  }

  private func configureFirebaseIfNeeded(context: String) {
    guard FirebaseApp.app() == nil else { return }
    if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
      FirebaseApp.configure()
      NSLog("[BubblBridge] Firebase configured (%@).", context)
    } else {
      NSLog("[Bubbl] Skipping FirebaseApp.configure(): GoogleService-Info.plist not found.")
    }
  }

  private func bootstrapBubblFromStoredTenantIfNeeded(reason: String) {
    if didBootstrapBubblFromStoredTenant {
      return
    }

    guard let tenant = loadStoredTenantConfig() else {
      NSLog("[BubblBridge] Bubbl bootstrap skipped (%@): no stored tenant config.", reason)
      return
    }

    didBootstrapBubblFromStoredTenant = true
    BubblPlugin.shared.start(
      apiKey: tenant.apiKey,
      env: tenant.environment,
      segmentations: [],
      delegate: nil
    )
    NSLog("[BubblBridge] Bubbl bootstrap started from stored tenant (%@).", reason)
  }

  private func loadStoredTenantConfig() -> (apiKey: String, environment: Config.Environment)? {
    guard
      let rawApiKey = UserDefaults.standard.string(forKey: BubblTenantKeys.apiKey),
      !rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    let normalizedApiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawEnvironment = UserDefaults.standard.string(forKey: BubblTenantKeys.environment) ?? "STAGING"
    let environment = environmentFromStoredValue(rawEnvironment)

    return (apiKey: normalizedApiKey, environment: environment)
  }

  private func environmentFromStoredValue(_ value: String) -> Config.Environment {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "PRODUCTION":
      return .production
    case "DEVELOPMENT":
      return .development
    default:
      return .staging
    }
  }

  private func prepareReactNativeFactoryIfNeeded() {
    if reactNativeFactory != nil { return }
    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()
    reactNativeDelegate = delegate
    reactNativeFactory = factory
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    self.window = window

    if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
      appDelegate.attachReactNative(to: window)
    }
    window.makeKeyAndVisible()

    if let response = connectionOptions.notificationResponse {
      var payload = response.notification.request.content.userInfo
      payload["headline"] = response.notification.request.content.title
      payload["body"] = response.notification.request.content.body
      NotificationCenter.default.post(
        name: NSNotification.Name("BubblNotificationOpened"),
        object: nil,
        userInfo: payload
      )
    }
  }
}
