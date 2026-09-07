import CoreFoundation
import Foundation
import Darwin
import LocalAuthentication
import Security

struct BackgroundUploadFailure: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }
}

enum BackgroundUploadPolicy: String, CaseIterable {
  case wifi = "wifi"
  case wifiTrusted = "wifi.trusted"
  case connected = "connected"
  case connectedTrusted = "connected.trusted"

  var wifiOnly: Bool { self == .wifi || self == .wifiTrusted }
  var trustSelfSigned: Bool { self == .wifiTrusted || self == .connectedTrusted }

  static func policy(wifiOnly: Bool, trustSelfSigned: Bool) -> Self {
    if wifiOnly { return trustSelfSigned ? .wifiTrusted : .wifi }
    return trustSelfSigned ? .connectedTrusted : .connected
  }

  func identifier(bundleIdentifier: String) -> String {
    "\(bundleIdentifier).background-upload.\(rawValue).v1"
  }
}

struct BackgroundUploadOrigin: Codable, Equatable {
  let scheme: String
  let host: String
  let port: Int

  init(_ string: String, originOnly: Bool = true) throws {
    guard let parts = URLComponents(string: string),
      let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      !originOnly || parts.path.isEmpty || parts.path == "/",
      let url = parts.url, url.baseURL == nil
    else {
      throw BackgroundUploadFailure(code: "invalid_origin", message: "An explicit HTTP or HTTPS server origin is required.")
    }
    let port = parts.port ?? (scheme == "https" ? 443 : 80)
    guard (1...65535).contains(port) else {
      throw BackgroundUploadFailure(code: "invalid_origin", message: "The server port is invalid.")
    }
    self.scheme = scheme
    self.host = Self.normalizedHost(host)
    self.port = port
  }

  static func normalizedHost(_ host: String) -> String {
    host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
  }

  func matches(_ url: URL) -> Bool {
    (try? BackgroundUploadOrigin(url.absoluteString, originOnly: false)) == self
  }

  func uploadURL(_ string: String) throws -> URL {
    guard let parts = URLComponents(string: string), let url = parts.url,
      matches(url), parts.percentEncodedPath == parts.path,
      parts.path.hasPrefix("/api/upload/")
    else {
      throw BackgroundUploadFailure(code: "unapproved_upload_url", message: "The upload URL must use the approved server origin and canonical tus endpoint.")
    }
    let identifier = String(parts.path.dropFirst("/api/upload/".count))
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    guard !identifier.isEmpty, identifier != ".", identifier != "..",
      identifier.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw BackgroundUploadFailure(code: "unapproved_upload_url", message: "The upload URL is not a canonical tus resource.")
    }
    return url
  }
}

enum BackgroundUploadDisk {
  static func prepareDirectory(_ url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes(directory: true))
    try manager.setAttributes(attributes(directory: true), ofItemAtPath: url.path)
    var directory = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
  }

  static func attributes(directory: Bool) -> [FileAttributeKey: Any] {
    var result: [FileAttributeKey: Any] = [.posixPermissions: directory ? 0o700 : 0o600]
    #if os(iOS)
    result[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    return result
  }

  static func isMissing(_ error: Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
      || (error.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
  }

  static func protectExistingDatabase(in documents: URL) throws {
    let directory = documents.resolvingSymlinksInPath().standardizedFileURL
    // sqflite_darwin uses Documents; keep this filename aligned with LocalDb.
    for suffix in ["", "-wal", "-shm", "-journal"] {
      let file = directory.appendingPathComponent("localdrive.db" + suffix)
      do {
        let existing = try FileManager.default.attributesOfItem(atPath: file.path)
        guard existing[.type] as? FileAttributeType == .typeRegular else {
          throw BackgroundUploadFailure(
            code: "invalid_database_file",
            message: "The local backup database and sidecars must be owned regular files."
          )
        }
        try FileManager.default.setAttributes(attributes(directory: false), ofItemAtPath: file.path)
      } catch {
        // SQLite can remove a sidecar between its metadata lookup and update.
        if !isMissing(error) { throw error }
      }
    }
  }

  static func atomicWrite(_ data: Data, to url: URL) throws {
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
    options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: url, options: options)
    try FileManager.default.setAttributes(attributes(directory: false), ofItemAtPath: url.path)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
    guard directory >= 0 else { throw POSIXError(.EIO) }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw POSIXError(.EIO) }
  }
}

struct BackgroundUploadStaging {
  let root: URL

  init(applicationSupport: URL) throws {
    let root = applicationSupport.appendingPathComponent("LocalDriveBackups", isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw BackgroundUploadFailure(code: "invalid_staging", message: "Backup staging must be an owned directory.")
      }
    }
    try BackgroundUploadDisk.prepareDirectory(root)
    self.root = root.resolvingSymlinksInPath().standardizedFileURL
  }

  func protectExistingFiles() throws {
    let manager = FileManager.default
    do {
      let attributes = try manager.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw BackgroundUploadFailure(code: "invalid_staging", message: "Backup staging must remain an owned directory.")
      }
    } catch {
      if BackgroundUploadDisk.isMissing(error) { return }
      throw error
    }
    try BackgroundUploadDisk.prepareDirectory(root)
    var enumerationError: Error?
    guard let entries = manager.enumerator(
      at: root, includingPropertiesForKeys: nil, options: [],
      errorHandler: { _, error in
        if BackgroundUploadDisk.isMissing(error) { return true }
        enumerationError = error
        return false
      }
    ) else {
      throw BackgroundUploadFailure(code: "invalid_staging", message: "The owned backup staging directory could not be inspected.")
    }
    while let file = entries.nextObject() as? URL {
      do {
        let attributes = try manager.attributesOfItem(atPath: file.path)
        let type = attributes[.type] as? FileAttributeType
        guard type != .typeSymbolicLink,
          file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/")
        else {
          entries.skipDescendants()
          continue
        }
        guard type == .typeRegular || type == .typeDirectory else { continue }
        try manager.setAttributes(
          BackgroundUploadDisk.attributes(directory: type == .typeDirectory), ofItemAtPath: file.path
        )
      } catch {
        // Dart owns cleanup and may remove an acknowledged job during this pass.
        if !BackgroundUploadDisk.isMissing(error) { throw error }
      }
    }
    if let error = enumerationError { throw error }
  }

  func validate(path: String, remainingBytes: Int64) throws -> (url: URL, relativePath: String) {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw BackgroundUploadFailure(code: "invalid_staging", message: "The upload body must be an owned staged file.")
    }
    let source = URL(fileURLWithPath: path).standardizedFileURL
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    let prefix = root.path + "/"
    guard resolved.path.hasPrefix(prefix), source.lastPathComponent != ".",
      remainingBytes >= 0
    else {
      throw BackgroundUploadFailure(code: "invalid_staging", message: "The upload body must remain beneath Application Support/LocalDriveBackups.")
    }
    let manager = FileManager.default
    let attributes = try manager.attributesOfItem(atPath: source.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.int64Value == remainingBytes
    else {
      throw BackgroundUploadFailure(code: "staged_size_mismatch", message: "The staged body must contain exactly totalBytes minus offset bytes.")
    }
    var ancestor = source.deletingLastPathComponent()
    while ancestor.resolvingSymlinksInPath().path.hasPrefix(prefix)
      || ancestor.resolvingSymlinksInPath().path == root.path {
      let attributes = try manager.attributesOfItem(atPath: ancestor.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw BackgroundUploadFailure(code: "invalid_staging", message: "Symbolic links are not allowed within backup staging.")
      }
      try manager.setAttributes(BackgroundUploadDisk.attributes(directory: true), ofItemAtPath: ancestor.path)
      if ancestor.resolvingSymlinksInPath().path == root.path { break }
      ancestor.deleteLastPathComponent()
    }
    try manager.setAttributes(BackgroundUploadDisk.attributes(directory: false), ofItemAtPath: resolved.path)
    return (resolved, String(resolved.path.dropFirst(prefix.count)))
  }
}

struct BackgroundUploadRecord: Codable, Equatable {
  let jobId: String
  let attemptId: String
  let sessionId: String
  var taskId: Int?
  let url: String
  let relativePath: String
  let origin: BackgroundUploadOrigin
  let offset: Int64
  let totalBytes: Int64
  let wifiOnly: Bool
  let trustSelfSigned: Bool
  var cancellationRequested = false
  var completionEventId: String?

  var eventId: String { "\(jobId):\(attemptId)" }

  func matches(_ other: Self) -> Bool {
    jobId == other.jobId && attemptId == other.attemptId && sessionId == other.sessionId
      && url == other.url && relativePath == other.relativePath && origin == other.origin
      && offset == other.offset && totalBytes == other.totalBytes
      && wifiOnly == other.wifiOnly && trustSelfSigned == other.trustSelfSigned
  }

  func taskDescription() throws -> String {
    "localdrive.upload.v1:" + String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }

  static func fromTaskDescription(_ description: String?) -> Self? {
    let prefix = "localdrive.upload.v1:"
    guard let description = description, description.hasPrefix(prefix),
      let record = try? JSONDecoder().decode(Self.self, from: Data(description.dropFirst(prefix.count).utf8)),
      BackgroundUploadRequest.validIdentifier(record.jobId),
      BackgroundUploadRequest.validIdentifier(record.attemptId),
      record.offset >= 0, record.totalBytes >= record.offset,
      !record.relativePath.isEmpty, !record.relativePath.hasPrefix("/"),
      !record.relativePath.split(separator: "/").contains(".."),
      (try? record.origin.uploadURL(record.url)) != nil
    else { return nil }
    return record
  }
}

struct BackgroundUploadTaskIdentity: Hashable {
  let sessionId: String
  let taskId: Int
}

enum BackgroundUploadPendingCoverage {
  static var failure: BackgroundUploadFailure {
    BackgroundUploadFailure(
      code: "native_task_identity_unavailable",
      message: "An OS upload cannot yet be matched to a durable attempt. Wait for its cancellation to finish before retrying."
    )
  }

  static func validate(
    actual: Set<BackgroundUploadTaskIdentity>, records: [BackgroundUploadRecord]
  ) throws {
    var identified: Set<BackgroundUploadTaskIdentity> = []
    for record in records {
      guard BackgroundUploadRequest.validIdentifier(record.jobId),
        BackgroundUploadRequest.validIdentifier(record.attemptId),
        !record.sessionId.isEmpty, let taskId = record.taskId, taskId >= 0,
        record.completionEventId == nil, record.offset >= 0, record.totalBytes >= record.offset,
        identified.insert(BackgroundUploadTaskIdentity(sessionId: record.sessionId, taskId: taskId)).inserted
      else { throw failure }
    }
    guard actual == identified else { throw failure }
  }
}

struct BackgroundUploadRequest {
  let record: BackgroundUploadRecord
  let source: URL
  let request: URLRequest

  static func validIdentifier(_ string: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    return !string.isEmpty && string.utf8.count <= 128
      && string.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int64(number.stringValue)
  }

  static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  init(arguments: [String: Any], staging: BackgroundUploadStaging, bundleIdentifier: String) throws {
    guard let jobId = arguments["jobId"] as? String, Self.validIdentifier(jobId),
      let attemptId = arguments["attemptId"] as? String, Self.validIdentifier(attemptId),
      let urlString = arguments["url"] as? String,
      let path = arguments["localPath"] as? String,
      let offset = Self.integer(arguments["offset"]), offset >= 0,
      let total = Self.integer(arguments["totalBytes"]), total >= offset,
      let wifiOnly = Self.boolean(arguments["wifiOnly"]),
      let trust = Self.boolean(arguments["trustSelfSigned"]),
      let originString = arguments["trustedOrigin"] as? String,
      let suppliedHeaders = arguments["headers"] as? [String: String]
    else {
      throw BackgroundUploadFailure(code: "invalid_arguments", message: "The upload identity, byte range, policies, origin and explicit headers are required.")
    }
    let origin = try BackgroundUploadOrigin(originString)
    let url = try origin.uploadURL(urlString)
    guard !trust || origin.scheme == "https" else {
      throw BackgroundUploadFailure(code: "invalid_trust_policy", message: "Self-signed trust applies only to an explicitly approved HTTPS origin.")
    }
    var headers: [String: String] = [:]
    let headerNames = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    for (key, value) in suppliedHeaders {
      let name = key.lowercased()
      guard !name.isEmpty, headers[name] == nil,
        key.unicodeScalars.allSatisfy({ headerNames.contains($0) }),
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else {
        throw BackgroundUploadFailure(code: "invalid_headers", message: "Upload headers must be unambiguous and contain no control characters.")
      }
      headers[name] = value
    }
    guard let authorization = headers["authorization"],
      authorization.hasPrefix("Bearer "), authorization.count > "Bearer ".count,
      !authorization.dropFirst("Bearer ".count).contains(where: { $0.isWhitespace })
    else {
      throw BackgroundUploadFailure(code: "authentication_required", message: "Each upload requires its own bearer authorization.")
    }
    let expected: [String: String] = [
      "tus-resumable": "1.0.0",
      "upload-offset": String(offset),
      "content-type": "application/offset+octet-stream",
      "upload-length": String(total),
      "content-length": String(total - offset)
    ]
    for (name, value) in expected where headers[name] != nil && headers[name] != value {
      throw BackgroundUploadFailure(code: "invalid_headers", message: "The tus headers must match the immutable staged byte range.")
    }
    guard headers["host"] == nil, headers["transfer-encoding"] == nil,
      headers["connection"] == nil, headers["proxy-authorization"] == nil,
      headers["content-encoding"] == nil, headers["upload-defer-length"] == nil,
      headers["upload-concat"] == nil
    else {
      throw BackgroundUploadFailure(code: "invalid_headers", message: "Transport and proxy headers cannot override the upload policy.")
    }
    let staged = try staging.validate(path: path, remainingBytes: total - offset)
    let policy = BackgroundUploadPolicy.policy(wifiOnly: wifiOnly, trustSelfSigned: trust)
    record = BackgroundUploadRecord(
      jobId: jobId, attemptId: attemptId,
      sessionId: policy.identifier(bundleIdentifier: bundleIdentifier),
      url: url.absoluteString, relativePath: staged.relativePath, origin: origin,
      offset: offset, totalBytes: total, wifiOnly: wifiOnly, trustSelfSigned: trust
    )
    source = staged.url
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
    request.httpMethod = "PATCH"
    request.httpShouldHandleCookies = false
    request.allHTTPHeaderFields = headers
    // The resource already has its immutable length from POST, not deferred PATCH creation.
    request.setValue(nil, forHTTPHeaderField: "Upload-Length")
    request.setValue("ld_view=user", forHTTPHeaderField: "Cookie")
    request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
    request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
    request.setValue(String(total - offset), forHTTPHeaderField: "Content-Length")
    request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
    request.allowsCellularAccess = !wifiOnly
    request.allowsExpensiveNetworkAccess = !wifiOnly
    request.allowsConstrainedNetworkAccess = !wifiOnly
    self.request = request
  }
}

struct BackgroundUploadCompletion: Codable, Equatable {
  let eventId: String
  let jobId: String
  let attemptId: String
  let statusCode: Int?
  let uploadOffset: Int64?
  let totalBytes: Int64
  let cancelled: Bool
  let errorCode: String?
  let errorMessage: String?
  let completedAt: String
  let responseUrl: String?

  static func make(
    record: BackgroundUploadRecord, response: HTTPURLResponse?, error: NSError?,
    recoveryError: String? = nil, now: Date = Date()
  ) -> Self {
    let rawOffset = response?.value(forHTTPHeaderField: "Upload-Offset")?
      .trimmingCharacters(in: .whitespaces)
    let offset: Int64? = rawOffset.flatMap { value in
      guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
      return Int64(value)
    }
    let cancelled = record.cancellationRequested || (error?.domain == NSURLErrorDomain && error?.code == NSURLErrorCancelled)
    let responseURL = response?.url.flatMap { try? record.origin.uploadURL($0.absoluteString) }
    var code: String?
    var message: String?
    if cancelled {
      code = "cancelled"
      message = "The upload attempt was cancelled; its logical backup remains resumable."
    } else if let recoveryError = recoveryError {
      code = recoveryError
      message = "The previous transfer outcome is unknown; recover the server receipt and offset before retrying."
    } else if let error = error {
      code = "transport_\(error.code)"
      message = "The background transfer was interrupted (transport code \(error.code))."
    } else if let response = response {
      if responseURL?.path != URL(string: record.url)?.path {
        code = "unexpected_response_url"
        message = "The background upload did not finish at its approved canonical endpoint."
      } else if response.statusCode != 204 {
        code = "http_\(response.statusCode)"
        message = "The tus PATCH did not return HTTP 204 (received \(response.statusCode))."
      } else if offset != record.totalBytes {
        code = "upload_offset_mismatch"
        message = "The server did not acknowledge the complete staged byte range."
      } else if let version = response.value(forHTTPHeaderField: "Tus-Resumable"), version != "1.0.0" {
        code = "tus_version_mismatch"
        message = "The server returned an incompatible tus version."
      }
    } else {
      code = "missing_http_response"
      message = "No HTTP upload result was received; recover the server receipt before retrying."
    }
    return Self(
      eventId: record.eventId, jobId: record.jobId, attemptId: record.attemptId,
      statusCode: response?.statusCode, uploadOffset: offset, totalBytes: record.totalBytes,
      cancelled: cancelled, errorCode: code, errorMessage: message,
      completedAt: ISO8601DateFormatter().string(from: now), responseUrl: responseURL?.absoluteString
    )
  }

  var channelValue: [String: Any] {
    [
      "eventId": eventId, "jobId": jobId, "attemptId": attemptId,
      "statusCode": statusCode as Any? ?? NSNull(),
      "uploadOffset": uploadOffset as Any? ?? NSNull(),
      "totalBytes": totalBytes, "cancelled": cancelled,
      "errorCode": errorCode as Any? ?? NSNull(),
      "errorMessage": errorMessage as Any? ?? NSNull(),
      "completedAt": completedAt, "responseUrl": responseUrl as Any? ?? NSNull()
    ]
  }
}

enum BackgroundUploadTokenAccessibility {
  static func update(
    key: String, enabled: Bool,
    updater: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
  ) throws {
    guard key.hasPrefix("ld.token."), key.count > "ld.token.".count,
      !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw BackgroundUploadFailure(code: "invalid_token_key", message: "Only an existing LocalDrive token can change background accessibility.")
    }
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "flutter_secure_storage_service",
      kSecAttrAccount: key,
      kSecAttrSynchronizable: false,
      kSecUseAuthenticationContext: context
    ]
    let attributes: [CFString: Any] = [
      kSecAttrAccessible: enabled
        ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlocked
    ]
    let status = updater(query as CFDictionary, attributes as CFDictionary)
    guard status == errSecSuccess else {
      throw BackgroundUploadFailure(
        code: status == errSecItemNotFound ? "keychain_item_not_found" : "keychain_\(status)",
        message: "The existing token's protection could not be updated. Unlock the device and retry; the token was not recreated."
      )
    }
  }
}

struct BackgroundUploadEventGate {
  private var handlers: [String: [() -> Void]] = [:]
  private var finished: Set<String> = []

  mutating func register(sessionId: String, completion: @escaping () -> Void) {
    handlers[sessionId, default: []].append(completion)
  }

  mutating func receivedCompletion(sessionId: String) {
    finished.remove(sessionId)
  }

  mutating func finishedEvents(sessionId: String) {
    finished.insert(sessionId)
  }

  mutating func takeReady(persistenceIsDurable: Bool) -> [() -> Void] {
    guard persistenceIsDurable else { return [] }
    var ready: [() -> Void] = []
    for id in Array(finished) {
      guard let callbacks = handlers.removeValue(forKey: id) else { continue }
      finished.remove(id)
      ready.append(contentsOf: callbacks)
    }
    return ready
  }
}

final class BackgroundUploadJournal {
  struct Snapshot: Codable, Equatable {
    var version = 1
    var attempts: [String: BackgroundUploadRecord] = [:]
    var completions: [String: BackgroundUploadCompletion] = [:]
    // Compact tombstones prevent acknowledged callbacks from resurrecting after an OS replay.
    var acknowledgedEventIds: Set<String> = []
  }

  private(set) var snapshot: Snapshot
  let file: URL
  private let write: (Data, URL) throws -> Void

  init(directory: URL, writer: @escaping (Data, URL) throws -> Void = BackgroundUploadDisk.atomicWrite) throws {
    try BackgroundUploadDisk.prepareDirectory(directory)
    file = directory.appendingPathComponent("journal-v1.json")
    write = writer
    if FileManager.default.fileExists(atPath: file.path) {
      let data = try Data(contentsOf: file)
      do {
        snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
      } catch {
        throw BackgroundUploadFailure(
          code: "invalid_journal",
          message: "The native backup journal is unreadable. It has been preserved; recovery is required before new transfers can start."
        )
      }
      guard snapshot.version == 1,
        snapshot.attempts.allSatisfy({
          $0.key == $0.value.attemptId && ($0.value.completionEventId == nil
            || snapshot.completions[$0.value.completionEventId!]?.attemptId == $0.key)
        }),
        snapshot.completions.allSatisfy({
          $0.key == $0.value.eventId && !snapshot.acknowledgedEventIds.contains($0.key)
            && snapshot.attempts[$0.value.attemptId]?.completionEventId == $0.key
        })
      else {
        throw BackgroundUploadFailure(code: "invalid_journal", message: "The native backup journal requires recovery before new transfers can start.")
      }
    } else {
      snapshot = Snapshot()
      try write(try JSONEncoder().encode(snapshot), file)
    }
  }

  private func commit(_ next: Snapshot) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try write(try encoder.encode(next), file)
    snapshot = next
  }

  func reserve(_ record: BackgroundUploadRecord) throws -> BackgroundUploadRecord? {
    guard !snapshot.acknowledgedEventIds.contains(record.eventId) else {
      throw BackgroundUploadFailure(code: "attempt_acknowledged", message: "An acknowledged attempt cannot be submitted again; create a new attempt.")
    }
    if let existing = snapshot.attempts[record.attemptId] {
      guard existing.matches(record) else {
        throw BackgroundUploadFailure(code: "attempt_conflict", message: "The attempt identity is already bound to different immutable upload metadata.")
      }
      return existing
    }
    if let existing = snapshot.attempts.values.first(where: { $0.jobId == record.jobId }) {
      throw BackgroundUploadFailure(
        code: existing.completionEventId == nil ? "job_in_flight" : "completion_pending",
        message: "Reconcile the existing native attempt before starting another attempt for this job."
      )
    }
    var next = snapshot
    next.attempts[record.attemptId] = record
    try commit(next)
    return nil
  }

  func bind(_ record: BackgroundUploadRecord) throws {
    if let existing = snapshot.attempts[record.attemptId] {
      guard existing.matches(record), existing.taskId == nil || existing.taskId == record.taskId else {
        throw BackgroundUploadFailure(code: "task_identity_conflict", message: "The OS task identity conflicts with its durable backup attempt.")
      }
      if existing == record { return }
    }
    guard !snapshot.acknowledgedEventIds.contains(record.eventId) else { return }
    guard record.taskId == nil || !snapshot.attempts.values.contains(where: {
      $0.attemptId != record.attemptId && $0.sessionId == record.sessionId && $0.taskId == record.taskId
    }) else {
      throw BackgroundUploadFailure(code: "task_identity_conflict", message: "This session task identifier already belongs to another upload attempt.")
    }
    var next = snapshot
    next.attempts[record.attemptId] = record
    try commit(next)
  }

  func complete(_ record: BackgroundUploadRecord, event: BackgroundUploadCompletion) throws {
    guard !snapshot.acknowledgedEventIds.contains(event.eventId),
      snapshot.completions[event.eventId] == nil
    else { return }
    guard event.eventId == record.eventId, event.attemptId == record.attemptId,
      event.jobId == record.jobId, event.totalBytes == record.totalBytes
    else {
      throw BackgroundUploadFailure(code: "completion_identity_conflict", message: "The completion does not belong to this upload attempt.")
    }
    var next = snapshot
    var completed = snapshot.attempts[record.attemptId] ?? record
    guard completed.matches(record) else {
      throw BackgroundUploadFailure(code: "completion_identity_conflict", message: "The completion metadata does not match the durable upload attempt.")
    }
    completed.taskId = record.taskId ?? completed.taskId
    completed.completionEventId = event.eventId
    next.attempts[record.attemptId] = completed
    next.completions[event.eventId] = event
    try commit(next)
  }

  func cancel(jobIds: Set<String>) throws -> [BackgroundUploadRecord] {
    var next = snapshot
    var cancelled: [BackgroundUploadRecord] = []
    for (id, var record) in snapshot.attempts where jobIds.contains(record.jobId) && record.completionEventId == nil {
      record.cancellationRequested = true
      next.attempts[id] = record
      cancelled.append(record)
    }
    if next != snapshot { try commit(next) }
    return cancelled
  }

  func acknowledge(eventIds: Set<String>) throws {
    var next = snapshot
    for id in eventIds {
      guard let event = next.completions.removeValue(forKey: id) else { continue }
      next.acknowledgedEventIds.insert(id)
      if next.attempts[event.attemptId]?.completionEventId == id {
        next.attempts.removeValue(forKey: event.attemptId)
      }
    }
    if next != snapshot { try commit(next) }
  }
}
