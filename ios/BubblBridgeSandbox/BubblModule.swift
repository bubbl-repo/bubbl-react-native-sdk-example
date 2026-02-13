import Foundation
import UIKit
import MapKit
import Combine
import React
import UserNotifications
import CoreLocation
import Bubbl

@objc(Bubbl)
class BubblModule: RCTEventEmitter, BubblPluginDelegate {
  private enum Keys {
    static let tenantApiKey = "bubbl_api_key"
    static let tenantEnvironment = "bubbl_environment"
  }

  private struct BootConfig: Equatable {
    let apiKey: String
    let environment: String
    let segmentationTags: [String]
    let geoPollIntervalMs: Double?
  }

  private struct TenantConfig: Equatable {
    let apiKey: String
    let environment: String
  }

  private struct GeofenceCircle {
    let centerLatitude: Double
    let centerLongitude: Double
    let radiusMeters: Double
  }

  private var hasListeners = false
  private var hasInitialized = false
  private var hasAuthenticated = false
  private var hasPendingGeofenceRefresh = false
  private var pendingGeofenceCoordinates: (Double, Double)?

  private var activeBootConfig: BootConfig?
  private var geofenceSubscription: AnyCancellable?
  private var notificationDetailsSubscription: AnyCancellable?
  private var locationAuthorizationSubscription: AnyCancellable?
  private var locationAuthorizationTimeout: DispatchWorkItem?
  private var notificationReceivedObserver: NSObjectProtocol?
  private var notificationOpenedObserver: NSObjectProtocol?

  private var pendingNotificationPayloads: [[String: Any]] = []

  private var deviceLogTimer: DispatchSourceTimer?
  private var lastDeviceLogFingerprint = ""

  override init() {
    super.init()
    bindNotificationSources()
    bootstrapFromStoredTenantIfAvailable()
  }

  deinit {
    stopDeviceLogStream()
    stopGeofenceUpdates()
    clearLocationAuthorizationWait()
    notificationDetailsSubscription?.cancel()
    notificationDetailsSubscription = nil

    if let observer = notificationReceivedObserver {
      NotificationCenter.default.removeObserver(observer)
      notificationReceivedObserver = nil
    }

    if let observer = notificationOpenedObserver {
      NotificationCenter.default.removeObserver(observer)
      notificationOpenedObserver = nil
    }
  }

  override static func requiresMainQueueSetup() -> Bool {
    false
  }

  override func supportedEvents() -> [String]! {
    ["bubbl_notification", "bubbl_geofence", "bubbl_device_log"]
  }

  override func startObserving() {
    hasListeners = true
    flushPendingNotificationPayloads()
  }

  override func stopObserving() {
    hasListeners = false
  }

  @objc override func addListener(_ eventName: String!) {
    super.addListener(eventName)
  }

  @objc override func removeListeners(_ count: Double) {
    super.removeListeners(count)
  }

  override func invalidate() {
    stopDeviceLogStream()
    stopGeofenceUpdates()
    clearLocationAuthorizationWait()
    super.invalidate()
  }

  // MARK: - Notification Bridge

  private func bindNotificationSources() {
    if notificationDetailsSubscription == nil {
      NotificationManager.shared.setAsNotificationDelegate()
      notificationDetailsSubscription = NotificationManager.shared.publisher
        .receive(on: DispatchQueue.main)
        .sink { [weak self] details in
          self?.handleNotificationDetails(details)
        }
    }

    if notificationReceivedObserver == nil {
      notificationReceivedObserver = NotificationCenter.default.addObserver(
        forName: NSNotification.Name("BubblNotificationReceived"),
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let userInfo = notification.userInfo else { return }
        self?.handleNotificationUserInfo(userInfo, source: "received")
      }
    }

    if notificationOpenedObserver == nil {
      notificationOpenedObserver = NotificationCenter.default.addObserver(
        forName: NSNotification.Name("BubblNotificationOpened"),
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard let userInfo = notification.userInfo else { return }
        self?.handleNotificationUserInfo(userInfo, source: "opened")
      }
    }
  }

  private func handleNotificationDetails(_ details: BubblNotificationDetails) {
    var payload: [String: Any] = [
      "id": details.notifID,
      "headline": details.headline,
      "body": details.body,
      "locationId": String(details.locationID),
    ]

    if let mediaURL = details.mediaURL {
      payload["mediaUrl"] = mediaURL
    }

    if let mediaType = details.mediaType {
      payload["mediaType"] = mediaType
    }

    if let ctaLabel = details.ctaLabel {
      payload["ctaLabel"] = ctaLabel
    }

    if let ctaURL = details.ctaURL {
      payload["ctaUrl"] = ctaURL
    }

    if let completionMessage = details.completionMessage {
      payload["postMessage"] = completionMessage
    }

    if let questions = mapQuestions(details.questions) {
      payload["questions"] = questions
    } else {
      payload["questions"] = NSNull()
    }

    payload["raw"] = serializeJSON(payload) ?? "{}"
    emitNotificationPayload(payload)
  }

  private func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any], source: String) {
    guard var payload = mapNotificationPayload(userInfo, source: source) else {
      return
    }

    if payload["raw"] == nil {
      payload["raw"] = serializeJSON(payload) ?? "{}"
    }

    emitNotificationPayload(payload)
  }

  private func emitNotificationPayload(_ payload: [String: Any]) {
    if hasListeners {
      sendEvent(withName: "bubbl_notification", body: payload)
      return
    }

    pendingNotificationPayloads.append(payload)
    if pendingNotificationPayloads.count > 20 {
      pendingNotificationPayloads.removeFirst(pendingNotificationPayloads.count - 20)
    }
  }

  private func flushPendingNotificationPayloads() {
    guard hasListeners else { return }
    guard !pendingNotificationPayloads.isEmpty else { return }

    let pending = pendingNotificationPayloads
    pendingNotificationPayloads.removeAll()

    pending.forEach { payload in
      sendEvent(withName: "bubbl_notification", body: payload)
    }
  }

  private func mapNotificationPayload(
    _ userInfo: [AnyHashable: Any],
    source: String
  ) -> [String: Any]? {
    var payload: [String: Any] = extractPayloadJSON(userInfo) ?? [:]
    payload["source"] = source

    var out: [String: Any] = [:]

    if let id = firstValue(
      payload,
      keys: [
        "id",
        "n_id",
        "notification_id",
        "notificationId",
        "curatedNotificationID",
        "curatedNotificationId",
        "curated_notification_id",
      ]
    ) {
      out["id"] = id
    }

    if let headline = firstStringValue(payload, keys: ["headline", "title", "notificationTitle"]) {
      out["headline"] = headline
    }

    if let body = firstStringValue(payload, keys: ["body", "message", "notificationBody"]) {
      out["body"] = body
    }

    if let mediaURL = firstStringValue(payload, keys: ["mediaUrl", "mediaURL", "media_url"]) {
      out["mediaUrl"] = mediaURL
    }

    if let mediaType = firstStringValue(payload, keys: ["mediaType", "media_type"]) {
      out["mediaType"] = mediaType
    }

    if let activation = firstStringValue(
      payload,
      keys: ["activation", "geofence_activation", "geofenceActivation", "trigger", "eventType", "event_type"]
    ) {
      out["activation"] = activation
    }

    if let ctaLabel = firstStringValue(payload, keys: ["ctaLabel", "cta_label"]) {
      out["ctaLabel"] = ctaLabel
    }

    if let ctaURL = firstStringValue(payload, keys: ["ctaUrl", "cta_url"]) {
      out["ctaUrl"] = ctaURL
    }

    if let locationId = firstValue(payload, keys: ["locationId", "location_id", "locationID", "location_id_str"]) {
      out["locationId"] = locationId
    }

    if let campaignId = firstValue(payload, keys: ["campaignId", "campaign_id", "geofenceId", "geofence_id"]) {
      out["campaignId"] = campaignId
    }

    if let postMessage = firstStringValue(
      payload,
      keys: ["postMessage", "post_message", "completion_message", "completionMessage"]
    ) {
      out["postMessage"] = postMessage
    }

    if let questions = normalizeQuestions(payload["questions"]) {
      out["questions"] = questions
    } else {
      out["questions"] = NSNull()
    }

    if let aps = payload["aps"] as? [String: Any] {
      if out["headline"] == nil || out["body"] == nil {
        if let alert = aps["alert"] as? [String: Any] {
          if out["headline"] == nil, let title = alert["title"] as? String {
            out["headline"] = title
          }

          if out["body"] == nil, let body = alert["body"] as? String {
            out["body"] = body
          }
        } else if let alertText = aps["alert"] as? String {
          if out["headline"] == nil {
            out["headline"] = "Notification"
          }

          if out["body"] == nil {
            out["body"] = alertText
          }
        }
      }
    }

    if let sourceValue = firstStringValue(payload, keys: ["source", "eventSource", "notification_source"]) {
      out["source"] = sourceValue
    }

    let sourceLower = (out["source"] as? String)?.lowercased()
    let transport: String = {
      if sourceLower == "received" || sourceLower == "opened" || sourceLower == "remote" ||
        sourceLower == "apns" || sourceLower == "fcm" || sourceLower == "push" {
        return "remote"
      }

      if sourceLower == "local" || sourceLower == "sdk" {
        return "local"
      }

      if payload["aps"] != nil {
        return "remote"
      }

      return "unknown"
    }()
    out["transport"] = transport

    let activationRaw = (out["activation"] as? String)?.uppercased() ?? ""
    let isGeofenceRelated = activationRaw == "ON_ENTER" || activationRaw == "ON_EXIT" ||
      payload["campaignId"] != nil || payload["campaign_id"] != nil ||
      payload["geofenceId"] != nil || payload["geofence_id"] != nil ||
      ((firstStringValue(payload, keys: ["trigger", "eventType", "event_type", "event"])?.lowercased()
        .contains("geofence")) == true)
    out["isGeofenceRelated"] = isGeofenceRelated
    out["isRemoteGeofenceFallback"] = transport == "remote" && isGeofenceRelated

    out["raw"] = serializeJSON(payload) ?? "{}"

    if out.isEmpty {
      return nil
    }

    return out
  }

  private func extractPayloadJSON(_ userInfo: [AnyHashable: Any]) -> [String: Any]? {
    let direct = userInfo.reduce(into: [String: Any]()) { result, entry in
      result[String(describing: entry.key)] = entry.value
    }

    let keys = ["payload", "notification_payload", "data"]
    for key in keys {
      guard let value = direct[key] else { continue }

      if let string = value as? String,
         let data = string.data(using: .utf8),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return object
      }

      if let dictionary = value as? [String: Any] {
        return dictionary
      }

      if let dictionary = value as? NSDictionary {
        return dictionary as? [String: Any]
      }
    }

    return direct
  }

  private func firstStringValue(_ payload: [String: Any], keys: [String]) -> String? {
    for key in keys {
      guard let value = payload[key] else { continue }

      if let string = value as? String, !string.isEmpty {
        return string
      }

      if let number = value as? NSNumber {
        return number.stringValue
      }
    }

    return nil
  }

  private func firstValue(_ payload: [String: Any], keys: [String]) -> Any? {
    for key in keys {
      guard let value = payload[key] else { continue }

      if let string = value as? String {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          return string
        }
        continue
      }

      if value is NSNull {
        continue
      }

      return value
    }

    return nil
  }

  private func normalizeQuestions(_ value: Any?) -> [[String: Any]]? {
    guard let value = value else { return nil }

    if let array = value as? [Any] {
      return mapQuestionArray(array)
    }

    if let string = value as? String,
       let data = string.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
      return mapQuestionArray(parsed)
    }

    return nil
  }

  private func mapQuestionArray(_ questions: [Any]) -> [[String: Any]] {
    var mappedQuestions: [[String: Any]] = []

    for item in questions {
      guard let q = item as? [String: Any] else { continue }
      var mapped: [String: Any] = [:]

      if let id = q["id"] {
        mapped["id"] = id
      }

      if let question = q["question"] as? String {
        mapped["question"] = question
      }

      if let questionType = q["question_type"] ?? q["questionType"] {
        mapped["question_type"] = questionType
      }

      if let hasChoices = q["has_choices"] ?? q["hasChoices"] {
        mapped["has_choices"] = hasChoices
      }

      if let position = q["position"] {
        mapped["position"] = position
      }

      if let rawChoices = q["choices"] as? [Any] {
        var mappedChoices: [[String: Any]] = []

        for choiceValue in rawChoices {
          guard let choice = choiceValue as? [String: Any] else { continue }

          var mappedChoice: [String: Any] = [:]
          if let id = choice["id"] {
            mappedChoice["id"] = id
          }
          if let label = choice["choice"] {
            mappedChoice["choice"] = label
          }
          if let position = choice["position"] {
            mappedChoice["position"] = position
          }
          mappedChoices.append(mappedChoice)
        }

        mapped["choices"] = mappedChoices
      } else {
        mapped["choices"] = []
      }

      mappedQuestions.append(mapped)
    }

    return mappedQuestions
  }

  private func mapQuestions(_ questions: [SurveyQuestion]?) -> [[String: Any]]? {
    guard let questions = questions else { return nil }

    return questions.map { question in
      var mapped: [String: Any] = [
        "id": question.id,
        "question": question.question,
        "has_choices": question.hasChoices,
        "position": question.position,
      ]

      if let questionType = question.questionType {
        mapped["question_type"] = questionType.rawValue
      }

      if let choices = question.choices {
        mapped["choices"] = choices.map { choice in
          [
            "id": choice.id,
            "choice": choice.choice,
            "position": choice.position,
          ]
        }
      } else {
        mapped["choices"] = []
      }

      return mapped
    }
  }

  // MARK: - Boot / Init

  private func normalizedBootConfig(
    apiKey: String,
    environment: String,
    segmentationTags: [String],
    geoPollIntervalMs: Double?
  ) -> BootConfig {
    let normalizedTags = segmentationTags
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let normalizedPollMs: Double?
    if let geoPollIntervalMs, geoPollIntervalMs > 0 {
      normalizedPollMs = geoPollIntervalMs
    } else {
      normalizedPollMs = nil
    }

    return BootConfig(
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
      environment: environment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
      segmentationTags: normalizedTags,
      geoPollIntervalMs: normalizedPollMs
    )
  }

  private func environmentFrom(_ value: String) -> Config.Environment {
    switch value.uppercased() {
    case "PRODUCTION":
      return .production
    case "DEVELOPMENT":
      return .development
    default:
      return .staging
    }
  }

  private func initializeBubbl(with config: BootConfig) {
    hasInitialized = true
    hasAuthenticated = false
    activeBootConfig = config

    applyPollingOverrideIfSupported(config: config)

    BubblPlugin.shared.start(
      apiKey: config.apiKey,
      env: environmentFrom(config.environment),
      segmentations: config.segmentationTags,
      delegate: self
    )
  }

  private func bootstrapFromStoredTenantIfAvailable() {
    guard let tenant = loadTenantConfig() else {
      return
    }

    if hasInitialized {
      return
    }

    initializeBubbl(
      with: BootConfig(
        apiKey: tenant.apiKey,
        environment: tenant.environment,
        segmentationTags: [],
        geoPollIntervalMs: nil
      )
    )
  }

  // MARK: - BubblPluginDelegate

  func bubblPlugin(_ plugin: BubblPlugin, didAuthenticate deviceID: String, bubblID: String) {
    hasAuthenticated = true

    if hasPendingGeofenceRefresh {
      let pendingCoordinates = pendingGeofenceCoordinates
      hasPendingGeofenceRefresh = false
      pendingGeofenceCoordinates = nil
      triggerGeofenceRefresh(
        reason: "postAuthenticationPendingRefresh",
        latitude: pendingCoordinates?.0,
        longitude: pendingCoordinates?.1
      )
    }
  }

  func bubblPlugin(_ plugin: BubblPlugin, didFailWith error: Error) {
    hasAuthenticated = false
    NSLog("[Bubbl] Authentication failed: %@", error.localizedDescription)
  }

  // MARK: - Shared helpers

  private func requireInitialized(
    _ reject: RCTPromiseRejectBlock? = nil,
    functionName: String
  ) -> Bool {
    if hasInitialized {
      return true
    }

    reject?("BUBBL_NOT_INITIALIZED", "Call Bubbl.boot(...) before calling \(functionName)().", nil)
    return false
  }

  private func applyPollingOverrideIfSupported(config: BootConfig) {
    guard let pollMs = config.geoPollIntervalMs else {
      return
    }

    let foregroundSeconds = max(60.0, pollMs / 1000.0)
    let backgroundSeconds = max(foregroundSeconds, foregroundSeconds * 6.0)
    let selector = NSSelectorFromString(
      "configureGeofencePollingWithForegroundInterval:backgroundInterval:"
    )
    let target = BubblPlugin.shared as NSObject

    guard target.responds(to: selector) else {
      NSLog(
        "[Bubbl] iOS SDK does not expose polling override yet; ignoring geoPollIntervalMs=%@",
        NSNumber(value: pollMs)
      )
      return
    }

    _ = target.perform(
      selector,
      with: NSNumber(value: foregroundSeconds),
      with: NSNumber(value: backgroundSeconds)
    )
  }

  private func refetchGeofenceWithCoordinatesIfAvailable(latitude: Double, longitude: Double) -> Bool {
    let selector = NSSelectorFromString("refetchGeofenceWithLatitude:longitude:")
    let target = BubblPlugin.shared as NSObject

    guard target.responds(to: selector) else {
      return false
    }

    _ = target.perform(
      selector,
      with: NSNumber(value: latitude),
      with: NSNumber(value: longitude)
    )
    return true
  }

  private func triggerGeofenceRefresh(
    reason: String,
    latitude: Double? = nil,
    longitude: Double? = nil
  ) {
    let explicitCoordinates: (Double, Double)? = {
      guard let latitude, let longitude else { return nil }
      return (latitude, longitude)
    }()

    if !hasInitialized {
      hasPendingGeofenceRefresh = true
      pendingGeofenceCoordinates = explicitCoordinates ?? pendingGeofenceCoordinates
      NSLog("[Bubbl] Queued geofence refresh (%@) until SDK init.", reason)
      return
    }

    if !hasAuthenticated {
      hasPendingGeofenceRefresh = true
      pendingGeofenceCoordinates = explicitCoordinates ?? pendingGeofenceCoordinates
      NSLog("[Bubbl] Queued geofence refresh (%@) until authentication.", reason)
      return
    }

    pendingGeofenceCoordinates = nil

    if let coordinates = explicitCoordinates,
       refetchGeofenceWithCoordinatesIfAvailable(
         latitude: coordinates.0,
         longitude: coordinates.1
       ) {
      return
    }

    BubblPlugin.shared.refetchGeofence()
  }

  private func clearLocationAuthorizationWait() {
    locationAuthorizationSubscription?.cancel()
    locationAuthorizationSubscription = nil
    locationAuthorizationTimeout?.cancel()
    locationAuthorizationTimeout = nil
  }

  private func serializeJSON(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value) else {
      return nil
    }

    guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  private func saveTenantConfig(apiKey: String, environment: String) {
    UserDefaults.standard.set(apiKey, forKey: Keys.tenantApiKey)
    UserDefaults.standard.set(environment, forKey: Keys.tenantEnvironment)
  }

  private func loadTenantConfig() -> TenantConfig? {
    guard
      let apiKey = UserDefaults.standard.string(forKey: Keys.tenantApiKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !apiKey.isEmpty,
      let environment = UserDefaults.standard.string(forKey: Keys.tenantEnvironment)
    else {
      return nil
    }

    return TenantConfig(apiKey: apiKey, environment: environment)
  }

  private func clearTenantConfigInternal() {
    UserDefaults.standard.removeObject(forKey: Keys.tenantApiKey)
    UserDefaults.standard.removeObject(forKey: Keys.tenantEnvironment)
  }

  private func maskApiKey(_ apiKey: String) -> String {
    if apiKey.count <= 8 {
      return "****"
    }

    let start = apiKey.prefix(4)
    let end = apiKey.suffix(4)
    return "\(start)****\(end)"
  }

  private func currentDeviceIdentifier() -> String {
    UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
  }

  private func currentDeviceSuffix() -> String {
    let normalized = currentDeviceIdentifier().replacingOccurrences(
      of: "[^A-Za-z0-9]",
      with: "",
      options: .regularExpression
    )

    if normalized.isEmpty {
      return "-----"
    }

    return String(normalized.suffix(5))
  }

  private func campaignCountFromCurrentPolygons() -> Int {
    GeofenceService.shared.currentPolygons.count
  }

  // MARK: - Geofence stream

  private func deriveGeofenceCircle(vertices: [CLLocationCoordinate2D]) -> GeofenceCircle? {
    guard !vertices.isEmpty else { return nil }

    let centerLatitude = vertices.reduce(0.0) { $0 + $1.latitude } / Double(vertices.count)
    let centerLongitude = vertices.reduce(0.0) { $0 + $1.longitude } / Double(vertices.count)

    let centerLocation = CLLocation(latitude: centerLatitude, longitude: centerLongitude)
    var radiusMeters = 0.0

    vertices.forEach { vertex in
      let location = CLLocation(latitude: vertex.latitude, longitude: vertex.longitude)
      radiusMeters = max(radiusMeters, centerLocation.distance(from: location))
    }

    return GeofenceCircle(
      centerLatitude: centerLatitude,
      centerLongitude: centerLongitude,
      radiusMeters: radiusMeters
    )
  }

  private func emitGeofenceSnapshot(polygons: [MKPolygon]) {
    let mappedPolygons: [[String: Any]] = polygons.enumerated().map { index, polygon in
      let vertices = polygon.coordinates.map { coord in
        [
          "latitude": coord.latitude,
          "longitude": coord.longitude,
        ]
      }

      let campaignName = polygon.title ?? "campaign-\(index)"

      return [
        "campaignId": index,
        "campaignName": campaignName,
        "vertices": vertices,
      ]
    }

    let mappedCircles: [[String: Any]] = polygons.enumerated().compactMap { index, polygon in
      guard let circle = deriveGeofenceCircle(vertices: polygon.coordinates) else { return nil }
      let campaignName = polygon.title ?? "campaign-\(index)"

      return [
        "campaignId": index,
        "campaignName": campaignName,
        "center": [
          "latitude": circle.centerLatitude,
          "longitude": circle.centerLongitude,
        ],
        "radius": circle.radiusMeters,
      ]
    }

    let payload: [String: Any] = [
      "stats": [
        "campaignsTotal": mappedPolygons.count,
        "polygonsTotal": mappedPolygons.count,
      ],
      "polygons": mappedPolygons,
      "circles": mappedCircles,
    ]

    if hasListeners {
      sendEvent(withName: "bubbl_geofence", body: payload)
    }
  }

  // MARK: - Device logs

  private func readDeviceLogTail(maxLines: Int) -> [String] {
    let url = Logger.shared.logFileURL

    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
      return []
    }

    let lines = content.split(whereSeparator: \.isNewline).map(String.init)
    if lines.count <= maxLines {
      return lines
    }

    return Array(lines.suffix(maxLines))
  }

  private func emitDeviceLogSnapshot(maxLines: Int, force: Bool) {
    let lines = readDeviceLogTail(maxLines: maxLines)
    let fingerprint = lines.joined(separator: "\n")

    if !force && fingerprint == lastDeviceLogFingerprint {
      return
    }

    lastDeviceLogFingerprint = fingerprint

    guard hasListeners else {
      return
    }

    let payload: [String: Any] = [
      "deviceType": "ios",
      "deviceId": currentDeviceIdentifier(),
      "deviceIdSuffix": currentDeviceSuffix(),
      "timestamp": Date().timeIntervalSince1970 * 1000,
      "lines": lines,
    ]

    DispatchQueue.main.async { [weak self] in
      self?.sendEvent(withName: "bubbl_device_log", body: payload)
    }
  }

  // MARK: - Event mapping helpers

  private func parseNotificationType(_ raw: String) -> NotificationType? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "notification":
      return .notification
    case "location":
      return .location
    case "geofence":
      return .geofence
    default:
      return nil
    }
  }

  private func parseActivityType(_ raw: String) -> ActivityType? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "cta_engagement":
      return .ctaEngagement
    case "notification_sent":
      return .notificationSent
    case "notification_delivered":
      return .notificationDelivered
    case "media_viewed":
      return .mediaViewed
    case "location_update":
      return .location_update
    case "geofence_exit":
      return .geofence_exit
    case "geofence_entry":
      return .geofence_entry
    default:
      return nil
    }
  }

  private func normalizeSurveyType(_ type: String, choiceCount: Int) -> String {
    let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonical = trimmed
      .lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")

    if canonical.isEmpty {
      return choiceCount > 0 ? "singleChoice" : "openEnded"
    }

    switch canonical {
    case "choice":
      return choiceCount > 1 ? "multipleChoice" : "singleChoice"
    case "singlechoice", "radio":
      return "singleChoice"
    case "multiplechoice", "checkbox", "checkboxes":
      return "multipleChoice"
    case "text", "openended", "openendedtext":
      return "openEnded"
    case "number", "numeric", "integer", "int":
      return "number"
    case "boolean", "bool", "yesno":
      return "boolean"
    case "rating", "star", "stars":
      return "rating"
    case "slider", "range":
      return "slider"
    default:
      return trimmed
    }
  }

  private func parseSurveyAnswers(_ answers: NSArray) -> [SurveyAnswer] {
    var parsed: [SurveyAnswer] = []

    for case let dictionary as NSDictionary in answers {
      let questionIDValue = dictionary["question_id"]
      let questionID: Int
      if let value = questionIDValue as? NSNumber {
        questionID = value.intValue
      } else if let value = questionIDValue as? Int {
        questionID = value
      } else {
        continue
      }

      let rawType = (dictionary["type"] as? String) ?? ""
      let value = (dictionary["value"] as? String) ?? ""

      var selections: [ChoiceSelection]? = nil
      if let choices = dictionary["choice"] as? [NSDictionary] {
        let mappedSelections = choices.compactMap { choice -> ChoiceSelection? in
          if let choiceId = choice["choice_id"] as? NSNumber {
            return ChoiceSelection(choiceId: choiceId.intValue)
          }

          if let choiceId = choice["choice_id"] as? Int {
            return ChoiceSelection(choiceId: choiceId)
          }

          return nil
        }

        if !mappedSelections.isEmpty {
          selections = mappedSelections
        }
      }

      let normalizedType = normalizeSurveyType(rawType, choiceCount: selections?.count ?? 0)

      parsed.append(
        SurveyAnswer(
          questionId: questionID,
          type: normalizedType,
          value: value,
          choice: selections
        )
      )
    }

    return parsed
  }

  // MARK: - React methods

  @objc(init:withOptions:withResolver:withRejecter:)
  func `init`(
    _ apiKey: String,
    withOptions options: NSDictionary,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let environment = options["environment"] as? String ?? "STAGING"
    boot(apiKey, environment: environment, options: options, resolver: resolve, rejecter: reject)
  }

  @objc(boot:environment:options:withResolver:withRejecter:)
  func boot(
    _ apiKey: String,
    environment: String,
    options: NSDictionary,
    resolver resolve: @escaping RCTPromiseResolveBlock,
    rejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let tags = options["segmentationTags"] as? [String] ?? []
    let geoPollIntervalMs = (options["geoPollIntervalMs"] as? NSNumber)?.doubleValue
    let nextConfig = normalizedBootConfig(
      apiKey: apiKey,
      environment: environment,
      segmentationTags: tags,
      geoPollIntervalMs: geoPollIntervalMs
    )

    if nextConfig.apiKey.isEmpty {
      reject("BUBBL_BOOT_FAILED", "apiKey is required.", nil)
      return
    }

    let previousTenant = loadTenantConfig()
    let tenantChanged = previousTenant?.apiKey != nextConfig.apiKey ||
      previousTenant?.environment.uppercased() != nextConfig.environment

    saveTenantConfig(apiKey: nextConfig.apiKey, environment: nextConfig.environment)

    let alreadyInitialized = hasInitialized && !tenantChanged && activeBootConfig == nextConfig
    if alreadyInitialized {
      resolve([
        "initializedNow": false,
        "alreadyInitialized": true,
      ])
      return
    }

    if tenantChanged {
      stopGeofenceUpdates()
      hasAuthenticated = false
      hasPendingGeofenceRefresh = false
      pendingGeofenceCoordinates = nil
    }

    initializeBubbl(with: nextConfig)

    resolve([
      "initializedNow": true,
      "alreadyInitialized": false,
    ])
  }

  @objc(requiredPermissions:withRejecter:)
  func requiredPermissions(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    resolve(["locationWhenInUse", "locationAlways", "pushNotifications"])
  }

  @objc(locationGranted:withRejecter:)
  func locationGranted(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let status = CLLocationManager.authorizationStatus()
    let granted = status == .authorizedAlways || status == .authorizedWhenInUse
    resolve(granted)
  }

  @objc(notificationGranted:withRejecter:)
  func notificationGranted(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let granted =
        settings.authorizationStatus == .authorized ||
        settings.authorizationStatus == .provisional ||
        settings.authorizationStatus == .ephemeral
      resolve(granted)
    }
  }

  @objc(requestPushPermission:withRejecter:)
  func requestPushPermission(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted,
      error in
      if let error = error {
        reject("BUBBL_PUSH_PERMISSION_FAILED", error.localizedDescription, error)
        return
      }

      if granted {
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }

      resolve(granted)
    }
  }

  @objc(startLocationTracking:withRejecter:)
  func startLocationTracking(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "startLocationTracking") {
      return
    }

    let initialStatus = CLLocationManager.authorizationStatus()
    if initialStatus == .authorizedAlways {
      triggerGeofenceRefresh(reason: "startLocationTracking")
      resolve(true)
      return
    }

    if initialStatus == .denied || initialStatus == .restricted {
      NSLog("[Bubbl] startLocationTracking denied: Always location authorization is required.")
      resolve(false)
      return
    }

    BubblPlugin.shared.requestLocationWhenInUse()
    BubblPlugin.shared.requestLocationAlways()
    clearLocationAuthorizationWait()

    let timeoutWorkItem = DispatchWorkItem { [weak self] in
      guard let self else {
        return
      }

      self.clearLocationAuthorizationWait()
      let status = CLLocationManager.authorizationStatus()
      if status == .authorizedAlways {
        self.triggerGeofenceRefresh(reason: "startLocationTracking")
        resolve(true)
      } else {
        NSLog("[Bubbl] Background significant-change refresh requires Always location authorization.")
        resolve(false)
      }
    }

    locationAuthorizationTimeout = timeoutWorkItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: timeoutWorkItem)

    locationAuthorizationSubscription = BubblPlugin.locationAuthorizationPublisher
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] status in
        guard let self else {
          return
        }

        switch status {
        case .authorizedAlways:
          self.clearLocationAuthorizationWait()
          self.triggerGeofenceRefresh(reason: "startLocationTracking")
          resolve(true)
        case .authorizedWhenInUse, .denied, .restricted:
          self.clearLocationAuthorizationWait()
          NSLog("[Bubbl] Background significant-change refresh requires Always location authorization.")
          resolve(false)
        case .notDetermined:
          break
        @unknown default:
          self.clearLocationAuthorizationWait()
          resolve(false)
        }
      }
  }

  @objc(refreshGeofence:lng:)
  func refreshGeofence(_ lat: NSNumber, lng: NSNumber) {
    if !requireInitialized(nil, functionName: "refreshGeofence") {
      return
    }

    triggerGeofenceRefresh(
      reason: "refreshGeofence",
      latitude: lat.doubleValue,
      longitude: lng.doubleValue
    )
  }

  @objc(getDeviceLogStreamInfo:withRejecter:)
  func getDeviceLogStreamInfo(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    resolve([
      "deviceType": "ios",
      "deviceId": currentDeviceIdentifier(),
      "deviceIdSuffix": currentDeviceSuffix(),
    ])
  }

  @objc(getDeviceLogTail:withResolver:withRejecter:)
  func getDeviceLogTail(
    _ maxLines: NSNumber,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let clamped = max(10, min(200, maxLines.intValue))
    resolve(readDeviceLogTail(maxLines: clamped))
  }

  @objc(startDeviceLogStream:withResolver:withRejecter:)
  func startDeviceLogStream(
    _ options: NSDictionary,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let intervalRaw = (options["intervalMs"] as? NSNumber)?.doubleValue ?? 2500
    let maxLinesRaw = (options["maxLines"] as? NSNumber)?.intValue ?? 80
    let targetSuffix = ((options["targetDeviceSuffix"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    let intervalMs = max(1000.0, min(30000.0, intervalRaw))
    let maxLines = max(10, min(200, maxLinesRaw))
    let currentSuffix = currentDeviceSuffix().lowercased()

    if !targetSuffix.isEmpty && targetSuffix != currentSuffix {
      resolve([
        "started": false,
        "reason": "device_suffix_mismatch",
        "deviceIdSuffix": currentDeviceSuffix(),
      ])
      return
    }

    stopDeviceLogStream()
    lastDeviceLogFingerprint = ""
    emitDeviceLogSnapshot(maxLines: maxLines, force: true)

    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(
      deadline: .now() + .milliseconds(Int(intervalMs)),
      repeating: .milliseconds(Int(intervalMs))
    )
    timer.setEventHandler { [weak self] in
      self?.emitDeviceLogSnapshot(maxLines: maxLines, force: false)
    }
    timer.resume()
    deviceLogTimer = timer

    resolve([
      "started": true,
      "reason": "ok",
      "deviceIdSuffix": currentDeviceSuffix(),
    ])
  }

  @objc(stopDeviceLogStream)
  func stopDeviceLogStream() {
    deviceLogTimer?.setEventHandler {}
    deviceLogTimer?.cancel()
    deviceLogTimer = nil
  }

  @objc(updateSegments:withResolver:withRejecter:)
  func updateSegments(
    _ segmentations: [String],
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "updateSegments") {
      return
    }

    BubblPlugin.shared.updateSegments(segmentations: segmentations) { result in
      switch result {
      case .success:
        resolve(true)
      case .failure(let error):
        reject("BUBBL_SEGMENTS_FAILED", error.localizedDescription, error)
      }
    }
  }

  @objc(setCorrelationId:withResolver:withRejecter:)
  func setCorrelationId(
    _ correlationId: String,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "setCorrelationId") {
      return
    }

    BubblPlugin.shared.setCorrelationId(correlationId)
    resolve(true)
  }

  @objc(getCorrelationId:withRejecter:)
  func getCorrelationId(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "getCorrelationId") {
      return
    }

    resolve(BubblPlugin.shared.getCorrelationId())
  }

  @objc(clearCorrelationId:withRejecter:)
  func clearCorrelationId(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "clearCorrelationId") {
      return
    }

    BubblPlugin.shared.clearCorrelationId()
    resolve(true)
  }

  @objc(getPrivacyText:withRejecter:)
  func getPrivacyText(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    resolve(BubblPlugin.shared.getPrivacyText())
  }

  @objc(refreshPrivacyText:withRejecter:)
  func refreshPrivacyText(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    BubblPlugin.shared.refreshPrivacyText { result in
      switch result {
      case .success(let text):
        resolve(text)
      case .failure(let error):
        reject("BUBBL_PRIVACY_FAILED", error.localizedDescription, error)
      }
    }
  }

  @objc(getCurrentConfiguration:withRejecter:)
  func getCurrentConfiguration(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard let config = BubblPlugin.shared.getCurrentConfiguration() else {
      resolve(nil)
      return
    }

    resolve([
      "notificationsCount": config.notificationsCount,
      "daysCount": config.daysCount,
      "batteryCount": config.batteryCount,
      "privacyText": config.privacyText,
    ])
  }

  @objc(hasCampaigns:withRejecter:)
  func hasCampaigns(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "hasCampaigns") {
      return
    }

    resolve(campaignCountFromCurrentPolygons() > 0)
  }

  @objc(getCampaignCount:withRejecter:)
  func getCampaignCount(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "getCampaignCount") {
      return
    }

    resolve(campaignCountFromCurrentPolygons())
  }

  @objc(forceRefreshCampaigns:withRejecter:)
  func forceRefreshCampaigns(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "forceRefreshCampaigns") {
      return
    }

    triggerGeofenceRefresh(reason: "forceRefreshCampaigns")
    resolve(true)
  }

  @objc(clearCachedCampaigns)
  func clearCachedCampaigns() {
    if !requireInitialized(nil, functionName: "clearCachedCampaigns") {
      return
    }

    // No-op. iOS SDK does not expose a public geofence cache clear method.
  }

  @objc(getApiKey:withRejecter:)
  func getApiKey(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let apiKey = UserDefaults.standard.string(forKey: Keys.tenantApiKey) ?? ""
    resolve(apiKey)
  }

  @objc(sayHello:withRejecter:)
  func sayHello(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    resolve("Hello from Bubbl iOS bridge")
  }

  @objc(sendEvent:locationId:type:activity:latitude:longitude:withResolver:withRejecter:)
  func sendEvent(
    _ curatedNotificationID: String,
    locationId: String,
    type: String,
    activity: String,
    latitude: NSNumber,
    longitude: NSNumber,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "sendEvent") {
      return
    }

    let parsedNotificationType = parseNotificationType(type)
    let parsedActivityType = parseActivityType(activity)
    let parsedLocationID = Int(locationId)
    let parsedNotificationID = Int(curatedNotificationID)

    if let notificationType = parsedNotificationType,
       let activityType = parsedActivityType,
       let locationID = parsedLocationID,
       let notificationID = parsedNotificationID {
      NotificationManager.shared.reportNotification(
        activity: activityType,
        locationID: locationID,
        curatedNotificationID: notificationID,
        type: notificationType
      )
      resolve(true)
      return
    }

    BubblPlugin.shared.trackSurveyEvent(
      notificationId: curatedNotificationID,
      locationId: locationId,
      activity: activity
    ) { result in
      switch result {
      case .success(let success):
        resolve(success)
      case .failure(let error):
        reject("BUBBL_SEND_EVENT_FAILED", error.localizedDescription, error)
      }
    }
  }

  @objc(cta:locationId:)
  func cta(_ notificationId: NSNumber, locationId: String) {
    if !requireInitialized(nil, functionName: "cta") {
      return
    }

    if let parsedLocationID = Int(locationId) {
      NotificationManager.shared.trackCTAEngagement(
        notificationID: notificationId.intValue,
        locationID: parsedLocationID
      )
      return
    }

    BubblPlugin.shared.trackSurveyEvent(
      notificationId: String(notificationId.intValue),
      locationId: locationId,
      activity: "cta_engagement"
    ) { _ in }
  }

  @objc(trackSurveyEvent:locationId:activity:withResolver:withRejecter:)
  func trackSurveyEvent(
    _ notificationId: String,
    locationId: String,
    activity: String,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "trackSurveyEvent") {
      return
    }

    BubblPlugin.shared.trackSurveyEvent(
      notificationId: notificationId,
      locationId: locationId,
      activity: activity
    ) { result in
      switch result {
      case .success(let success):
        resolve(success)
      case .failure(let error):
        reject("BUBBL_SURVEY_EVENT_FAILED", error.localizedDescription, error)
      }
    }
  }

  @objc(submitSurveyResponse:locationId:answers:withResolver:withRejecter:)
  func submitSurveyResponse(
    _ notificationId: String,
    locationId: String,
    answers: NSArray,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    if !requireInitialized(reject, functionName: "submitSurveyResponse") {
      return
    }

    let parsedAnswers = parseSurveyAnswers(answers)

    BubblPlugin.shared.submitSurveyResponse(
      notificationId: notificationId,
      locationId: locationId,
      answers: parsedAnswers
    ) { result in
      switch result {
      case .success(let success):
        resolve(success)
      case .failure(let error):
        reject("BUBBL_SURVEY_SUBMIT_FAILED", error.localizedDescription, error)
      }
    }
  }

  @objc(startGeofenceUpdates)
  func startGeofenceUpdates() {
    if !requireInitialized(nil, functionName: "startGeofenceUpdates") {
      return
    }

    if geofenceSubscription != nil {
      return
    }

    geofenceSubscription = GeofenceService.shared.polygonsPublisherPublic
      .receive(on: DispatchQueue.main)
      .sink { [weak self] polygons in
        self?.emitGeofenceSnapshot(polygons: polygons)
      }

    emitGeofenceSnapshot(polygons: GeofenceService.shared.currentPolygons)
  }

  @objc(stopGeofenceUpdates)
  func stopGeofenceUpdates() {
    geofenceSubscription?.cancel()
    geofenceSubscription = nil
  }

  @objc(clearStoredConfig:withRejecter:)
  func clearStoredConfig(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    clearTenantConfigInternal()
    hasInitialized = false
    hasAuthenticated = false
    hasPendingGeofenceRefresh = false
    activeBootConfig = nil
    stopGeofenceUpdates()
    resolve(true)
  }

  @objc(getTenantConfig:withRejecter:)
  func getTenantConfig(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    guard let tenant = loadTenantConfig() else {
      resolve(nil)
      return
    }

    resolve([
      "apiKeyMasked": maskApiKey(tenant.apiKey),
      "environment": tenant.environment,
    ])
  }

  @objc(setTenantConfig:environment:withResolver:withRejecter:)
  func setTenantConfig(
    _ apiKey: String,
    environment: String,
    withResolver resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let normalizedApiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedEnvironment = environment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    if normalizedApiKey.isEmpty {
      reject("BUBBL_TENANT_SET_FAILED", "apiKey is required.", nil)
      return
    }

    saveTenantConfig(apiKey: normalizedApiKey, environment: normalizedEnvironment)
    resolve(true)
  }

  @objc(clearTenantConfig:withRejecter:)
  func clearTenantConfig(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    clearTenantConfigInternal()
    resolve(true)
  }

  @objc(testNotification:withRejecter:)
  func testNotification(
    _ resolve: @escaping RCTPromiseResolveBlock,
    withRejecter reject: @escaping RCTPromiseRejectBlock
  ) {
    let id = Int(Date().timeIntervalSince1970)
    let payload: [String: Any] = [
      "id": id,
      "headline": "Test Notification",
      "body": "This is a local test notification.",
      "locationId": "test-location",
      "postMessage": "Thanks for testing!",
    ]

    var emitPayload = payload
    emitPayload["raw"] = serializeJSON(payload) ?? "{}"
    emitNotificationPayload(emitPayload)

    let content = UNMutableNotificationContent()
    content.title = "Test Notification"
    content.body = "This is a local test notification."
    content.sound = .default
    content.userInfo = ["payload": payload]

    let request = UNNotificationRequest(
      identifier: "bubbl_test_\(id)",
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        reject("BUBBL_TEST_NOTIFICATION_FAILED", error.localizedDescription, error)
        return
      }

      resolve(true)
    }
  }
}
