import Foundation
import Security
import UIKit

final class BackgroundUploadCoordinator: NSObject {
  static let shared = BackgroundUploadCoordinator()
  static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.sudiptab2100.localdrive_app"

  typealias Reply = (Result<Any?, BackgroundUploadFailure>) -> Void

  private let queue = DispatchQueue(label: "localdrive.background-upload.coordinator")
  private let delegateQueue: OperationQueue
  private var sessions: [String: URLSession] = [:]
  private var journal: BackgroundUploadJournal?
  private var staging: BackgroundUploadStaging?
  private var started = false
  private var enumerating: Set<String> = []
  private var restoredTasks: [String: [URLSessionTask]] = [:]
  private var observedTasks: [String: [URLSessionTask]] = [:]
  private var recoveryReconciled = false
  private var afterEnumeration: [() -> Void] = []
  private var liveTasks: [String: URLSessionTask] = [:]
  private var ignoredTasks: Set<String> = []
  private var cancellingAttempts: Set<String> = []
  private var unpersisted: [String: (BackgroundUploadRecord, BackgroundUploadCompletion)] = [:]
  private var lastStorageFailure: BackgroundUploadFailure?
  private var retryScheduled = false
  private var protectedDataObserver: NSObjectProtocol?
  private var listeners: [UUID: ([String: Any]) -> Void] = [:]
  private var eventGate = BackgroundUploadEventGate()

  private override init() {
    delegateQueue = OperationQueue()
    super.init()
    delegateQueue.name = "localdrive.background-upload.delegates"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = queue
    protectedDataObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
    ) { [weak self] _ in
      self?.queue.async {
        try? self?.protectOwnedFilesForBackground()
        self?.retryPersistence()
      }
    }
  }

  func restore() {
    queue.async {
      self.startIfNeeded()
      try? self.protectOwnedFilesForBackground()
      self.retryPersistence()
    }
  }

  func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) -> Bool {
    guard BackgroundUploadPolicy.allCases.contains(where: {
      $0.identifier(bundleIdentifier: Self.bundleIdentifier) == identifier
    }) else { return false }
    queue.async {
      self.eventGate.register(sessionId: identifier, completion: completion)
      self.startIfNeeded()
      self.finishBackgroundHandlersIfDurable()
    }
    return true
  }

  func addListener(id: UUID, listener: @escaping ([String: Any]) -> Void) {
    queue.async { self.listeners[id] = listener }
  }

  func removeListener(id: UUID) {
    queue.async { self.listeners.removeValue(forKey: id) }
  }

  func perform(method: String, arguments: Any?, reply: @escaping Reply) {
    queue.async {
      if method == "setTokenBackgroundAccess" {
        self.respond(reply) {
          guard let args = arguments as? [String: Any], let key = args["key"] as? String,
            let enabled = BackgroundUploadRequest.boolean(args["enabled"])
          else { throw self.invalidArguments() }
          try BackgroundUploadTokenAccessibility.update(key: key, enabled: enabled)
          if enabled {
            self.queue.async { try? self.protectOwnedFilesForBackground() }
          }
          return nil
        }
        return
      }
      self.startIfNeeded()
      if self.enumerating.isEmpty && (method == "pending" || method == "enqueue") {
        self.beginTaskEnumeration()
      }
      let operation = {
        self.respond(reply) {
          if method == "cancel" {
            guard let args = arguments as? [String: Any], let ids = args["jobIds"] as? [String],
              ids.allSatisfy(BackgroundUploadRequest.validIdentifier)
            else { throw self.invalidArguments() }
            try self.cancelCurrentAttempts(jobIds: Set(ids))
            return nil
          }
          self.retryPersistence()
          guard self.recoveryReconciled, self.unpersisted.isEmpty,
            let journal = self.journal, let staging = self.staging
          else {
            throw self.lastStorageFailure ?? BackgroundUploadFailure(
              code: "native_journal_unavailable",
              message: "Native backup recovery is waiting for protected storage. Unlock the device or free storage, then retry."
            )
          }
          switch method {
          case "enqueue":
            guard let args = arguments as? [String: Any] else { throw self.invalidArguments() }
            _ = try self.verifiedPendingRecords(journal: journal)
            try self.protectOwnedFilesForBackground()
            let request = try BackgroundUploadRequest(
              arguments: args, staging: staging, bundleIdentifier: Self.bundleIdentifier
            )
            return try self.enqueue(request, journal: journal)
          case "pending":
            return try self.verifiedPendingRecords(journal: journal)
              .sorted { $0.attemptId < $1.attemptId }
              .map { record -> [String: Any] in
                guard let task = self.liveTasks[record.attemptId],
                  let taskId = record.taskId
                else { throw BackgroundUploadPendingCoverage.failure }
                return [
                  "jobId": record.jobId, "attemptId": record.attemptId,
                  "taskId": taskId, "sessionId": record.sessionId,
                  "bytesSent": self.bytesSent(task.countOfBytesSent, record: record),
                  "totalBytes": record.totalBytes, "offset": record.offset,
                  "state": self.stateName(task.state)
                ]
              }
          case "readCompletions":
            return journal.snapshot.completions.values.sorted {
              ($0.completedAt, $0.eventId) < ($1.completedAt, $1.eventId)
            }.map(\.channelValue)
          case "ackCompletions":
            guard let args = arguments as? [String: Any], let ids = args["eventIds"] as? [String],
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 257 })
            else { throw self.invalidArguments() }
            try journal.acknowledge(eventIds: Set(ids))
            self.cancellingAttempts = self.cancellingAttempts.filter {
              journal.snapshot.attempts[$0] != nil
            }
            return nil
          default:
            throw BackgroundUploadFailure(code: "unsupported_method", message: "The native upload method is not supported.")
          }
        }
      }
      if self.enumerating.isEmpty { operation() } else { self.afterEnumeration.append(operation) }
    }
  }

  private func respond(_ reply: @escaping Reply, operation: () throws -> Any?) {
    let result: Result<Any?, BackgroundUploadFailure>
    do {
      result = .success(try operation())
    } catch let error as BackgroundUploadFailure {
      result = .failure(error)
    } catch {
      result = .failure(persistenceFailure())
    }
    DispatchQueue.main.async { reply(result) }
  }

  private func invalidArguments() -> BackgroundUploadFailure {
    BackgroundUploadFailure(code: "invalid_arguments", message: "The native upload arguments are invalid.")
  }

  private func persistenceFailure() -> BackgroundUploadFailure {
    BackgroundUploadFailure(
      code: "native_storage_error",
      message: "The native backup journal or staged file is unavailable. Unlock the device or free storage, then retry."
    )
  }

  private func loadStorage() throws {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      throw persistenceFailure()
    }
    if staging == nil { staging = try BackgroundUploadStaging(applicationSupport: support) }
    if journal == nil {
      journal = try BackgroundUploadJournal(
        directory: support.appendingPathComponent("LocalDriveBackgroundUploads", isDirectory: true)
      )
    }
  }

  private func protectOwnedFilesForBackground() throws {
    let manager = FileManager.default
    guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first,
      let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw persistenceFailure()
    }
    try BackgroundUploadDisk.protectExistingDatabase(in: documents)
    if staging == nil { staging = try BackgroundUploadStaging(applicationSupport: support) }
    try staging?.protectExistingFiles()
  }

  static func configuration(for policy: BackgroundUploadPolicy) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.background(
      withIdentifier: policy.identifier(bundleIdentifier: bundleIdentifier)
    )
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.allowsCellularAccess = !policy.wifiOnly
    configuration.allowsExpensiveNetworkAccess = !policy.wifiOnly
    configuration.allowsConstrainedNetworkAccess = !policy.wifiOnly
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.timeoutIntervalForRequest = 120
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return configuration
  }

  private func startIfNeeded() {
    guard !started else { return }
    started = true
    try? loadStorage()
    for policy in BackgroundUploadPolicy.allCases {
      let id = policy.identifier(bundleIdentifier: Self.bundleIdentifier)
      let session = URLSession(configuration: Self.configuration(for: policy), delegate: self, delegateQueue: delegateQueue)
      sessions[id] = session
    }
    beginTaskEnumeration()
  }

  private func beginTaskEnumeration() {
    guard enumerating.isEmpty else { return }
    recoveryReconciled = false
    restoredTasks.removeAll()
    enumerating = Set(sessions.keys)
    for (id, session) in sessions {
      session.getAllTasks { [weak self] tasks in
        guard let self = self else { return }
        self.queue.async {
          self.restoredTasks[id] = tasks
          self.enumerating.remove(id)
          guard self.enumerating.isEmpty else { return }
          self.retryPersistence()
          let operations = self.afterEnumeration
          self.afterEnumeration.removeAll()
          for operation in operations { operation() }
        }
      }
    }
  }

  private func enqueue(_ request: BackgroundUploadRequest, journal: BackgroundUploadJournal) throws -> [String: Any] {
    guard let session = sessions[request.record.sessionId] else { throw persistenceFailure() }
    if let existing = try journal.reserve(request.record) {
      guard let taskId = existing.taskId else {
        throw BackgroundUploadFailure(code: "handoff_pending", message: "Recover the existing native handoff before retrying.")
      }
      return ["taskId": taskId, "sessionId": existing.sessionId]
    }
    let task = session.uploadTask(with: request.request, fromFile: request.source)
    observedTasks[request.record.sessionId, default: []].append(task)
    var record = request.record
    record.taskId = task.taskIdentifier
    do {
      task.taskDescription = try record.taskDescription()
      try journal.bind(record)
      liveTasks[record.attemptId] = task
      task.resume()
      return ["taskId": task.taskIdentifier, "sessionId": record.sessionId]
    } catch {
      task.cancel()
      persistCompletion(record, event: .make(
        record: record, response: nil, error: nil, recoveryError: "handoff_interrupted"
      ))
      throw error
    }
  }

  private func taskKey(sessionId: String, task: URLSessionTask) -> String {
    "\(sessionId):\(task.taskIdentifier)"
  }

  private func verifiedPendingRecords(journal: BackgroundUploadJournal) throws -> [BackgroundUploadRecord] {
    var actual: Set<BackgroundUploadTaskIdentity> = []
    var records: [BackgroundUploadRecord] = []
    for (sessionId, tasks) in observedTasks {
      for task in tasks where task.state != .completed {
        actual.insert(BackgroundUploadTaskIdentity(sessionId: sessionId, taskId: task.taskIdentifier))
        guard let record = journal.snapshot.attempts.values.first(where: {
          $0.sessionId == sessionId && $0.taskId == task.taskIdentifier && $0.completionEventId == nil
        }), liveTasks[record.attemptId]?.taskIdentifier == task.taskIdentifier
        else { throw BackgroundUploadPendingCoverage.failure }
        records.append(record)
      }
    }
    try BackgroundUploadPendingCoverage.validate(actual: actual, records: records)
    return records
  }

  private func persistedRecord(for task: URLSessionTask, sessionId: String) -> BackgroundUploadRecord? {
    journal?.snapshot.attempts.values.first {
      $0.sessionId == sessionId && $0.taskId == task.taskIdentifier
    }
  }

  private func record(for task: URLSessionTask, sessionId: String) -> BackgroundUploadRecord? {
    let persisted = persistedRecord(for: task, sessionId: sessionId)
    let described = BackgroundUploadRecord.fromTaskDescription(task.taskDescription)
    guard var result = persisted ?? described.flatMap({ journal?.snapshot.attempts[$0.attemptId] ?? $0 }),
      result.sessionId == sessionId,
      result.taskId == nil || result.taskId == task.taskIdentifier,
      BackgroundUploadPolicy.policy(wifiOnly: result.wifiOnly, trustSelfSigned: result.trustSelfSigned)
        .identifier(bundleIdentifier: Self.bundleIdentifier) == sessionId,
      described == nil || result.matches(described!),
      task.originalRequest?.httpMethod == "PATCH",
      let originalURL = task.originalRequest?.url,
      result.origin.matches(originalURL), originalURL.path == URL(string: result.url)?.path,
      task.originalRequest?.value(forHTTPHeaderField: "Upload-Offset") == String(result.offset)
    else { return nil }
    result.taskId = task.taskIdentifier
    if cancellingAttempts.contains(result.attemptId) { result.cancellationRequested = true }
    return result
  }

  private func cancelCurrentAttempts(jobIds: Set<String>) throws {
    guard !jobIds.isEmpty else { return }
    var tasks: [String: URLSessionTask] = liveTasks
    for (sessionId, restored) in restoredTasks {
      for task in restored {
        if let record = record(for: task, sessionId: sessionId)
          ?? persistedRecord(for: task, sessionId: sessionId) {
          tasks[record.attemptId] = task
        }
      }
    }
    var records: [String: BackgroundUploadRecord] = journal?.snapshot.attempts ?? [:]
    for task in tasks.values {
      if let record = BackgroundUploadRecord.fromTaskDescription(task.taskDescription),
        records[record.attemptId] == nil {
        records[record.attemptId] = record
      }
    }
    let matching = records.values.filter { jobIds.contains($0.jobId) && $0.completionEventId == nil }
    cancellingAttempts.formUnion(matching.map(\.attemptId))
    var storageError: Error?
    do {
      try loadStorage()
      guard let journal = journal else { throw persistenceFailure() }
      _ = try journal.cancel(jobIds: jobIds)
    } catch {
      storageError = error
    }
    // Revoking an account must stop its network attempts even if storage is full.
    for var record in matching {
      record.cancellationRequested = true
      if let task = tasks[record.attemptId] {
        task.cancel()
      } else {
        persistCompletion(record, event: .make(
          record: record, response: nil, error: nil, recoveryError: "task_not_found"
        ))
      }
    }
    if let error = storageError { throw error }
    if !unpersisted.isEmpty { throw persistenceFailure() }
  }

  private func reconcileRecovery() throws {
    guard !recoveryReconciled, enumerating.isEmpty, let journal = journal else { return }
    var recovered: [String: URLSessionTask] = [:]
    var resumable: [URLSessionTask] = []
    for (sessionId, tasks) in restoredTasks {
      for task in tasks {
        let key = taskKey(sessionId: sessionId, task: task)
        guard !ignoredTasks.contains(key) else { continue }
        guard let record = record(for: task, sessionId: sessionId) else {
          ignoredTasks.insert(key)
          task.cancel()
          continue
        }
        if journal.snapshot.acknowledgedEventIds.contains(record.eventId) || record.completionEventId != nil {
          ignoredTasks.insert(key)
          task.cancel()
          continue
        }
        if recovered[record.attemptId] != nil || journal.snapshot.attempts.values.contains(where: {
          $0.jobId == record.jobId && $0.attemptId != record.attemptId && $0.completionEventId == nil
        }) {
          ignoredTasks.insert(key)
          task.cancel()
          if journal.snapshot.attempts[record.attemptId] == nil {
            try journal.complete(record, event: .make(
              record: record, response: nil, error: nil, recoveryError: "duplicate_native_attempt"
            ))
          }
          continue
        }
        try journal.bind(record)
        recovered[record.attemptId] = task
        if record.cancellationRequested {
          task.cancel()
        } else if task.state == .suspended {
          resumable.append(task)
        }
      }
    }
    liveTasks = recovered
    for record in Array(journal.snapshot.attempts.values)
      where record.completionEventId == nil && recovered[record.attemptId] == nil {
      try journal.complete(record, event: .make(
        record: record, response: nil, error: nil,
        recoveryError: record.taskId == nil ? "handoff_interrupted" : "task_not_found"
      ))
    }
    recoveryReconciled = true
    observedTasks = restoredTasks
    restoredTasks.removeAll()
    for task in resumable { task.resume() }
  }

  private func persistCompletion(_ record: BackgroundUploadRecord, event: BackgroundUploadCompletion) {
    unpersisted[event.eventId] = unpersisted[event.eventId] ?? (record, event)
    retryPersistence()
  }

  private func retryPersistence() {
    guard started else { return }
    do {
      try loadStorage()
      guard let journal = journal else { throw persistenceFailure() }
      for (id, pending) in Array(unpersisted) {
        try journal.complete(pending.0, event: pending.1)
        unpersisted.removeValue(forKey: id)
      }
      try reconcileRecovery()
      lastStorageFailure = nil
      finishBackgroundHandlersIfDurable()
    } catch {
      lastStorageFailure = error as? BackgroundUploadFailure ?? persistenceFailure()
      guard !retryScheduled else { return }
      retryScheduled = true
      queue.asyncAfter(deadline: .now() + 5) {
        self.retryScheduled = false
        self.retryPersistence()
      }
    }
  }

  private func finishBackgroundHandlersIfDurable() {
    let handlers = eventGate.takeReady(
      persistenceIsDurable: recoveryReconciled && unpersisted.isEmpty && journal != nil
    )
    guard !handlers.isEmpty else { return }
    DispatchQueue.main.async {
      for handler in handlers { handler() }
    }
  }

  private func bytesSent(_ value: Int64, record: BackgroundUploadRecord) -> Int64 {
    max(0, min(value, record.totalBytes - record.offset))
  }

  private func stateName(_ state: URLSessionTask.State) -> String {
    switch state {
    case .running: return "running"
    case .suspended: return "suspended"
    case .canceling: return "canceling"
    case .completed: return "completed"
    @unknown default: return "unknown"
    }
  }
}

extension BackgroundUploadCoordinator: URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    guard let id = session.configuration.identifier,
      !ignoredTasks.contains(taskKey(sessionId: id, task: task)),
      let record = record(for: task, sessionId: id), record.completionEventId == nil
    else { return }
    let progress: [String: Any] = [
      "jobId": record.jobId, "attemptId": record.attemptId,
      "bytesSent": self.bytesSent(totalBytesSent, record: record),
      "totalBytes": record.totalBytes, "offset": record.offset
    ]
    let callbacks = Array(listeners.values)
    DispatchQueue.main.async {
      for callback in callbacks { callback(progress) }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let id = session.configuration.identifier else { return }
    observedTasks[id]?.removeAll { $0.taskIdentifier == task.taskIdentifier }
    eventGate.receivedCompletion(sessionId: id)
    guard !ignoredTasks.contains(taskKey(sessionId: id, task: task)),
      var record = record(for: task, sessionId: id) ?? persistedRecord(for: task, sessionId: id)
    else { return }
    if cancellingAttempts.contains(record.attemptId) { record.cancellationRequested = true }
    if liveTasks[record.attemptId]?.taskIdentifier == task.taskIdentifier {
      liveTasks.removeValue(forKey: record.attemptId)
    }
    persistCompletion(record, event: .make(
      record: record, response: task.response as? HTTPURLResponse, error: error as NSError?
    ))
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let id = session.configuration.identifier else { return }
    eventGate.finishedEvents(sessionId: id)
    retryPersistence()
  }

  // Do not implement the session-level challenge callback: Foundation forwards
  // server-trust challenges here so approval stays attached to a specific task.
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let id = session.configuration.identifier,
      let record = record(for: task, sessionId: id),
      record.trustSelfSigned, !record.cancellationRequested,
      record.origin.scheme == "https",
      challenge.protectionSpace.protocol?.lowercased() == "https",
      BackgroundUploadOrigin.normalizedHost(challenge.protectionSpace.host) == record.origin.host,
      challenge.protectionSpace.port == record.origin.port,
      let currentURL = task.currentRequest?.url, record.origin.matches(currentURL),
      let trust = challenge.protectionSpace.serverTrust, challenge.previousFailureCount == 0
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Background sessions may bypass this callback; enqueue accepts only canonical
    // endpoints and the completion validator also rejects a changed endpoint.
    completionHandler(nil)
  }
}
