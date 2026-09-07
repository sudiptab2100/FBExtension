import Foundation
import LocalAuthentication
import Security
import XCTest

#if os(iOS)
@testable import Runner
#endif

final class RunnerTests: XCTestCase {
  private var fixture: URL!
  private var staging: BackgroundUploadStaging!
  private var source: URL!

  override func setUpWithError() throws {
    #if os(iOS)
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeBackupRegressionFixtures", isDirectory: true)
    #else
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".native-checks/fixtures", isDirectory: true)
    #endif
    fixture = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    staging = try BackgroundUploadStaging(applicationSupport: fixture)
    source = staging.root.appendingPathComponent("remaining.bin")
    try Data("suffix".utf8).write(to: source)
  }

  override func tearDownWithError() throws {
    if let fixture = fixture { try FileManager.default.removeItem(at: fixture) }
  }

  private func arguments(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var values: [String: Any] = [
      "jobId": "test-job", "attemptId": "test-attempt",
      "url": "https://backup.local:5443/api/upload/resource-1",
      "localPath": source.path,
      "offset": Int64(4), "totalBytes": Int64(10),
      "headers": ["Authorization": "Bearer native-test-secret", "Cookie": "ld_view=admin"],
      "wifiOnly": true, "trustSelfSigned": false,
      "trustedOrigin": "https://backup.local:5443"
    ]
    values.merge(overrides) { _, new in new }
    return values
  }

  private func request(_ overrides: [String: Any] = [:]) throws -> BackgroundUploadRequest {
    try BackgroundUploadRequest(arguments: arguments(overrides), staging: staging, bundleIdentifier: "test.localdrive")
  }

  private func record() throws -> BackgroundUploadRecord {
    var record = try request().record
    record.taskId = 7
    return record
  }

  private func response(_ status: Int = 204, offset: String? = "10", url: String? = nil) -> HTTPURLResponse {
    var headers = ["Tus-Resumable": "1.0.0"]
    headers["Upload-Offset"] = offset
    return HTTPURLResponse(
      url: URL(string: url ?? "https://backup.local:5443/api/upload/resource-1")!,
      statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
    )!
  }

  private func journalDirectory() -> URL {
    fixture.appendingPathComponent("journal", isDirectory: true)
  }

  func testFileBackedSuffixRequestUsesExplicitAuthAndUserScope() throws {
    let upload = try request()
    XCTAssertEqual(upload.source, source)
    XCTAssertEqual(upload.request.httpMethod, "PATCH")
    XCTAssertNil(upload.request.httpBody)
    XCTAssertNil(upload.request.httpBodyStream)
    XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Authorization"), "Bearer native-test-secret")
    XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Cookie"), "ld_view=user")
    XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")
    XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Type"), "application/offset+octet-stream")
    XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Upload-Offset"), "4")
    XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Content-Length"), "6")
    XCTAssertFalse(upload.request.httpShouldHandleCookies)
    XCTAssertFalse(upload.request.allowsCellularAccess)
    XCTAssertFalse(upload.request.allowsExpensiveNetworkAccess)
    XCTAssertFalse(upload.request.allowsConstrainedNetworkAccess)
    let knownLength = try request(["headers": [
      "Authorization": "Bearer native-test-secret", "Upload-Length": "10"
    ]])
    XCTAssertNil(knownLength.request.value(forHTTPHeaderField: "Upload-Length"))
  }

  func testOffsetsRequireAnExactRemainingFileAndIntegerRange() throws {
    for override: [String: Any] in [
      ["offset": -1], ["offset": 11], ["offset": true],
      ["offset": 4.5], ["totalBytes": -1], ["totalBytes": "10"],
      ["offset": 0], ["totalBytes": 9]
    ] {
      XCTAssertThrowsError(try request(override))
    }
    try Data().write(to: source)
    XCTAssertNoThrow(try request(["offset": 0, "totalBytes": 0]))
  }

  func testHeaderConflictsAndMissingAuthorizationAreRejected() throws {
    for headers in [
      ["Cookie": "ld_view=user"],
      ["Authorization": "Bearer native-test-secret", "authorization": "Bearer other"],
      ["Authorization": "Bearer native-test-secret\r\nInjected: true"],
      ["Authorization": "Bearer native-test-secret", "Upload-Offset": "0"],
      ["Authorization": "Bearer native-test-secret", "Content-Length": "10"],
      ["Authorization": "Bearer native-test-secret", "Upload-Length": "9"],
      ["Authorization": "Bearer native-test-secret", "Content-Type": "application/octet-stream"],
      ["Authorization": "Bearer native-test-secret", "Host": "other.local"],
      ["Authorization": "Bearer native-test-secret", "Content-Encoding": "gzip"]
    ] {
      XCTAssertThrowsError(try request(["headers": headers]))
    }
  }

  func testApprovedOriginAndCanonicalResourceAreRequired() throws {
    for url in [
      "http://backup.local:5443/api/upload/resource-1",
      "https://backup.local/api/upload/resource-1",
      "https://other.local:5443/api/upload/resource-1",
      "https://user:password@backup.local:5443/api/upload/resource-1",
      "https://backup.local:5443/api/upload/resource-1?token=secret",
      "https://backup.local:5443/api/upload/resource-1#fragment",
      "https://backup.local:5443/api/upload/",
      "https://backup.local:5443/api/upload/resource-1/",
      "https://backup.local:5443/api/upload/%2e%2e",
      "https://backup.local:5443/api/upload/../other"
    ] {
      XCTAssertThrowsError(try request(["url": url]))
    }
    XCTAssertThrowsError(try request(["trustedOrigin": "https://backup.local:5443/not-an-origin"]))
    XCTAssertNoThrow(try request(["trustedOrigin": "https://BACKUP.local:5443/"]))
    let ipv6 = try BackgroundUploadOrigin("http://[fd00::1]:3100")
    XCTAssertEqual(ipv6.host, "fd00::1")
    XCTAssertTrue(ipv6.matches(URL(string: "http://[fd00::1]:3100/api/upload/resource")!))
    XCTAssertFalse(ipv6.matches(URL(string: "http://[fd00::1]:3101/api/upload/resource")!))
  }

  func testStagingRejectsOutsideFilesAndSymlinks() throws {
    let outside = fixture.appendingPathComponent("outside.bin")
    try Data("suffix".utf8).write(to: outside)
    XCTAssertThrowsError(try request(["localPath": outside.path]))
    let link = staging.root.appendingPathComponent("linked.bin")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try request(["localPath": link.path]))
    let internalLink = staging.root.appendingPathComponent("inside-link.bin")
    try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: source)
    XCTAssertThrowsError(try request(["localPath": internalLink.path]))
    let linkedDirectory = staging.root.appendingPathComponent("self-link")
    try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: staging.root)
    XCTAssertThrowsError(try request(["localPath": linkedDirectory.appendingPathComponent("remaining.bin").path]))
  }

  func testApplicationSupportAliasesResolveToTheSameOwnedStagingRoot() throws {
    let realSupport = fixture.appendingPathComponent("real-support", isDirectory: true)
    let aliasSupport = fixture.appendingPathComponent("support-alias", isDirectory: true)
    try FileManager.default.createDirectory(at: realSupport, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: aliasSupport, withDestinationURL: realSupport)
    let canonical = try BackgroundUploadStaging(applicationSupport: realSupport)
    let aliased = try BackgroundUploadStaging(applicationSupport: aliasSupport)
    XCTAssertEqual(aliased.root, canonical.root)
    let file = canonical.root.appendingPathComponent("body")
    try Data("suffix".utf8).write(to: file)
    let fromAlias = try BackgroundUploadRequest(
      arguments: arguments(["localPath": aliasSupport.appendingPathComponent("LocalDriveBackups/body").path]),
      staging: aliased, bundleIdentifier: "test.localdrive"
    )
    let fromCanonical = try BackgroundUploadRequest(
      arguments: arguments(["localPath": file.path]), staging: canonical, bundleIdentifier: "test.localdrive"
    )
    XCTAssertEqual(fromAlias.source, file)
    XCTAssertTrue(fromAlias.record.matches(fromCanonical.record))
  }

  func testNetworkAndTrustPoliciesUseSmallStableSeparateSessions() throws {
    let policies = BackgroundUploadPolicy.allCases
    XCTAssertEqual(policies.count, 4)
    XCTAssertEqual(Set(policies.map { $0.identifier(bundleIdentifier: "test.localdrive") }).count, 4)
    XCTAssertNotEqual(try request().record.sessionId, try request(["trustSelfSigned": true]).record.sessionId)
    let connected = try request(["wifiOnly": false])
    XCTAssertTrue(connected.request.allowsCellularAccess)
    XCTAssertTrue(connected.request.allowsExpensiveNetworkAccess)
    XCTAssertTrue(connected.request.allowsConstrainedNetworkAccess)
    XCTAssertThrowsError(try request([
      "url": "http://backup.local:3100/api/upload/resource-1",
      "trustedOrigin": "http://backup.local:3100", "trustSelfSigned": true
    ]))
  }

  func testOnlyHTTP204WithCompleteOffsetIsTransportSuccess() throws {
    let record = try record()
    let success = BackgroundUploadCompletion.make(record: record, response: response(), error: nil)
    XCTAssertNil(success.errorCode)
    XCTAssertEqual(success.statusCode, 204)
    XCTAssertEqual(success.uploadOffset, 10)
    XCTAssertFalse(success.cancelled)
    for status in [200, 201, 301, 401, 403, 404, 409, 500, 503] {
      let event = BackgroundUploadCompletion.make(record: record, response: response(status), error: nil)
      XCTAssertEqual(event.errorCode, "http_\(status)")
    }
    XCTAssertEqual(
      BackgroundUploadCompletion.make(record: record, response: nil, error: nil).errorCode,
      "missing_http_response"
    )
  }

  func testMissingPartialOverflowAndMalformedOffsetsAreNotSuccess() throws {
    for offset: String? in [nil, "", "4", "9", "11", "-1", "10.0", "+10", "999999999999999999999999"] {
      let event = BackgroundUploadCompletion.make(record: try record(), response: response(offset: offset), error: nil)
      XCTAssertEqual(event.errorCode, "upload_offset_mismatch")
    }
  }

  func testTransportErrorsAndCancellationAreNeverSuccess() throws {
    let error = NSError(
      domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
      userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer native-test-secret"]
    )
    let event = BackgroundUploadCompletion.make(record: try record(), response: response(), error: error)
    XCTAssertEqual(event.errorCode, "transport_\(NSURLErrorNetworkConnectionLost)")
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("native-test-secret"))
    var cancelledRecord = try record()
    cancelledRecord.cancellationRequested = true
    XCTAssertTrue(BackgroundUploadCompletion.make(record: cancelledRecord, response: response(), error: nil).cancelled)
    XCTAssertTrue(BackgroundUploadCompletion.make(
      record: try record(), response: nil,
      error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    ).cancelled)
  }

  func testRedirectedAndCredentialBearingResponseURLsAreNotAcceptedOrPersisted() throws {
    for url in [
      "https://other.local:5443/api/upload/resource-1",
      "http://backup.local:5443/api/upload/resource-1",
      "https://backup.local:5443/api/upload/resource-2",
      "https://backup.local:5443/api/upload/resource-1?token=native-test-secret"
    ] {
      let event = BackgroundUploadCompletion.make(record: try record(), response: response(url: url), error: nil)
      XCTAssertEqual(event.errorCode, "unexpected_response_url")
      XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("native-test-secret"))
    }
  }

  func testTaskDescriptionAndJournalNeverContainHeaders() throws {
    let record = try record()
    let description = try record.taskDescription()
    XCTAssertEqual(BackgroundUploadRecord.fromTaskDescription(description), record)
    XCTAssertNil(BackgroundUploadRecord.fromTaskDescription("not-a-localdrive-task"))
    XCTAssertFalse(description.contains("native-test-secret"))
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    _ = try journal.reserve(record)
    let encoded = try String(contentsOf: journal.file, encoding: .utf8)
    XCTAssertFalse(encoded.contains("native-test-secret"))
    XCTAssertFalse(encoded.lowercased().contains("authorization"))
    XCTAssertFalse(encoded.lowercased().contains("cookie"))
  }

  func testReservationsSurviveProcessDeathAndDeduplicateEngines() throws {
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    let unbound = try request().record
    XCTAssertNil(try journal.reserve(unbound))
    let restarted = try BackgroundUploadJournal(directory: journalDirectory())
    XCTAssertNil(restarted.snapshot.attempts[unbound.attemptId]?.taskId)
    try restarted.bind(try record())
    XCTAssertEqual(try restarted.reserve(unbound)?.taskId, 7)
    XCTAssertThrowsError(try restarted.reserve(try request(["attemptId": "second-attempt"]).record))
    XCTAssertThrowsError(try restarted.reserve(try request(["jobId": "different-job"]).record))
    XCTAssertThrowsError(try restarted.reserve(try request(["wifiOnly": false]).record))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testTaskDescriptionCanRecoverAnUnjournaledOSTask() throws {
    let original = try record()
    let recovered = try XCTUnwrap(BackgroundUploadRecord.fromTaskDescription(try original.taskDescription()))
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    try journal.bind(recovered)
    let restarted = try BackgroundUploadJournal(directory: journalDirectory())
    XCTAssertEqual(restarted.snapshot.attempts[original.attemptId], original)
  }

  func testOSTaskIdentifiersAreScopedBySessionAndCannotRebindActiveAttempts() throws {
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    let first = try record()
    _ = try journal.reserve(first)
    var second = try request(["jobId": "other-job", "attemptId": "other-attempt", "wifiOnly": false]).record
    _ = try journal.reserve(second)
    second.taskId = first.taskId
    try journal.bind(second)
    XCTAssertEqual(journal.snapshot.attempts.count, 2)
    var conflicting = try request(["jobId": "third-job", "attemptId": "third-attempt"]).record
    _ = try journal.reserve(conflicting)
    conflicting.taskId = first.taskId
    XCTAssertThrowsError(try journal.bind(conflicting))
    XCTAssertNil(journal.snapshot.attempts[conflicting.attemptId]?.taskId)
    XCTAssertEqual(journal.snapshot.attempts[first.attemptId], first)
  }

  func testMissingOSTaskRecoveryDoesNotInventHTTPCompletion() throws {
    let record = try record()
    for reason in ["task_not_found", "handoff_interrupted"] {
      let event = BackgroundUploadCompletion.make(record: record, response: nil, error: nil, recoveryError: reason)
      XCTAssertEqual(event.eventId, record.eventId)
      XCTAssertEqual(event.jobId, record.jobId)
      XCTAssertEqual(event.attemptId, record.attemptId)
      XCTAssertEqual(event.totalBytes, record.totalBytes)
      XCTAssertEqual(event.errorCode, reason)
      XCTAssertNil(event.statusCode)
      XCTAssertNil(event.uploadOffset)
      XCTAssertFalse(event.cancelled)
      XCTAssertNotNil(ISO8601DateFormatter().date(from: event.completedAt))
    }
  }

  func testPendingCoverageRequiresEveryActualTaskToHaveAnIdentity() throws {
    let record = try record()
    let known = BackgroundUploadTaskIdentity(sessionId: record.sessionId, taskId: 7)
    let unidentified = BackgroundUploadTaskIdentity(sessionId: record.sessionId, taskId: 8)
    XCTAssertNoThrow(try BackgroundUploadPendingCoverage.validate(actual: [known], records: [record]))
    XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: [known, unidentified], records: [record])) { error in
      XCTAssertEqual((error as? BackgroundUploadFailure)?.code, "native_task_identity_unavailable")
    }
    XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: [unidentified], records: []))
    XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: [known], records: [record, record]))
    XCTAssertNoThrow(try BackgroundUploadPendingCoverage.validate(actual: [], records: []))
  }

  func testPendingCoverageRejectsMalformedAndCompletedRecords() throws {
    let original = try record()
    let actual: Set<BackgroundUploadTaskIdentity> = [
      BackgroundUploadTaskIdentity(sessionId: original.sessionId, taskId: 7)
    ]
    for key in ["jobId", "attemptId"] {
      var fields = try XCTUnwrap(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(original)
      ) as? [String: Any])
      fields[key] = ""
      let malformed = try JSONDecoder().decode(
        BackgroundUploadRecord.self, from: JSONSerialization.data(withJSONObject: fields)
      )
      XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: actual, records: [malformed]))
    }
    var unbound = original
    unbound.taskId = nil
    XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: actual, records: [unbound]))
    var completed = original
    completed.completionEventId = original.eventId
    XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: actual, records: [completed]))
  }

  func testPendingCoverageScopesTaskIdsAndKeepsCancellationAttempts() throws {
    var first = try record()
    first.cancellationRequested = true
    var second = try request([
      "jobId": "other-job", "attemptId": "other-attempt", "wifiOnly": false,
      "url": "https://backup.local:5443/api/upload/resource-2"
    ]).record
    second.taskId = 7
    let actual: Set<BackgroundUploadTaskIdentity> = [
      BackgroundUploadTaskIdentity(sessionId: first.sessionId, taskId: 7),
      BackgroundUploadTaskIdentity(sessionId: second.sessionId, taskId: 7)
    ]
    XCTAssertNoThrow(try BackgroundUploadPendingCoverage.validate(actual: actual, records: [first, second]))
    XCTAssertThrowsError(try BackgroundUploadPendingCoverage.validate(actual: actual, records: [first]))
  }

  func testCompletionReadReplayAndAcknowledgementAreDurable() throws {
    let record = try record()
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    _ = try journal.reserve(record)
    let event = BackgroundUploadCompletion.make(record: record, response: response(), error: nil)
    try journal.complete(record, event: event)
    let restarted = try BackgroundUploadJournal(directory: journalDirectory())
    XCTAssertEqual(restarted.snapshot.completions[event.eventId], event)
    XCTAssertEqual(restarted.snapshot.completions[event.eventId], event)
    XCTAssertEqual(restarted.snapshot.attempts[record.attemptId]?.completionEventId, event.eventId)
    XCTAssertThrowsError(try restarted.reserve(try request(["attemptId": "retry-before-ack"]).record))
    try restarted.acknowledge(eventIds: [event.eventId])
    try restarted.acknowledge(eventIds: [event.eventId, "unknown-event"])
    let acknowledged = try BackgroundUploadJournal(directory: journalDirectory())
    XCTAssertTrue(acknowledged.snapshot.completions.isEmpty)
    XCTAssertTrue(acknowledged.snapshot.attempts.isEmpty)
    try acknowledged.complete(record, event: event)
    XCTAssertTrue(acknowledged.snapshot.completions.isEmpty)
    XCTAssertThrowsError(try acknowledged.reserve(record))
    XCTAssertNil(try acknowledged.reserve(try request(["attemptId": "next-attempt"]).record))
    XCTAssertEqual(try Data(contentsOf: source), Data("suffix".utf8))
  }

  func testFailedWritesDoNotPublishCompletionsOrDestructivelyAcknowledge() throws {
    var failWrites = false
    let journal = try BackgroundUploadJournal(directory: journalDirectory()) { data, url in
      if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
      try BackgroundUploadDisk.atomicWrite(data, to: url)
    }
    let record = try record()
    _ = try journal.reserve(record)
    let event = BackgroundUploadCompletion.make(record: record, response: response(), error: nil)
    failWrites = true
    XCTAssertThrowsError(try journal.complete(record, event: event))
    XCTAssertTrue(journal.snapshot.completions.isEmpty)
    XCTAssertNil(journal.snapshot.attempts[record.attemptId]?.completionEventId)
    failWrites = false
    try journal.complete(record, event: event)
    failWrites = true
    XCTAssertThrowsError(try journal.acknowledge(eventIds: [event.eventId]))
    XCTAssertEqual(journal.snapshot.completions[event.eventId], event)
    let restarted = try BackgroundUploadJournal(directory: journalDirectory())
    XCTAssertEqual(restarted.snapshot.completions[event.eventId], event)
  }

  func testCancellationPersistsWithoutDeletingSourceOrLogicalIdentity() throws {
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    let record = try record()
    _ = try journal.reserve(record)
    XCTAssertTrue(try journal.cancel(jobIds: ["different-job"]).isEmpty)
    let cancelled = try XCTUnwrap(try journal.cancel(jobIds: [record.jobId]).first)
    XCTAssertTrue(cancelled.cancellationRequested)
    let restarted = try BackgroundUploadJournal(directory: journalDirectory())
    XCTAssertTrue(try XCTUnwrap(restarted.snapshot.attempts[record.attemptId]).cancellationRequested)
    XCTAssertTrue(restarted.snapshot.completions.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testCorruptJournalIsNeverReplacedByAnEmptySuccess() throws {
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    try Data("invalid native journal".utf8).write(to: journal.file)
    XCTAssertThrowsError(try BackgroundUploadJournal(directory: journalDirectory()))
    XCTAssertEqual(try String(contentsOf: journal.file, encoding: .utf8), "invalid native journal")
  }

  func testStagingAndJournalDirectoriesAreExcludedFromBackup() throws {
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    for directory in [staging.root, journal.file.deletingLastPathComponent()] {
      let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
      XCTAssertEqual(values.isExcludedFromBackup, true)
    }
  }

  func testRetainedSourceAndSuffixProtectionDoesNotChangeTheirContents() throws {
    let directory = staging.root.appendingPathComponent("retained-job", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fullSource = directory.appendingPathComponent("source")
    let suffix = directory.appendingPathComponent("suffix-4")
    try Data("fullsuffix".utf8).write(to: fullSource)
    try Data("suffix".utf8).write(to: suffix)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fullSource.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: suffix.path)
    try staging.protectExistingFiles()
    XCTAssertEqual(try Data(contentsOf: fullSource), Data("fullsuffix".utf8))
    XCTAssertEqual(try Data(contentsOf: suffix), Data("suffix".utf8))
    for file in [fullSource, suffix] {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
  }

  func testStagingProtectionDoesNotFollowLinksOutsideOwnedFiles() throws {
    let outside = fixture.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let file = outside.appendingPathComponent("untouched")
    try Data("outside".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    let link = staging.root.appendingPathComponent("linked-directory")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    try staging.protectExistingFiles()
    XCTAssertEqual(try Data(contentsOf: file), Data("outside".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o644)
  }

  func testDatabaseProtectionPreservesExistingSidecarsAndDoesNotCreateMissingFiles() throws {
    let documents = fixture.appendingPathComponent("Documents", isDirectory: true)
    try BackgroundUploadDisk.protectExistingDatabase(in: documents)
    XCTAssertFalse(FileManager.default.fileExists(atPath: documents.path))
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let names = ["localdrive.db", "localdrive.db-wal", "localdrive.db-shm"]
    for name in names {
      let file = documents.appendingPathComponent(name)
      try Data(name.utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
    let unrelated = documents.appendingPathComponent("unrelated.db")
    try Data("unrelated".utf8).write(to: unrelated)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: unrelated.path)
    try BackgroundUploadDisk.protectExistingDatabase(in: documents)
    for name in names {
      let file = documents.appendingPathComponent(name)
      XCTAssertEqual(try Data(contentsOf: file), Data(name.utf8))
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("localdrive.db-journal").path))
    XCTAssertEqual(try Data(contentsOf: unrelated), Data("unrelated".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: unrelated.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
  }

  func testDatabaseProtectionRejectsSymlinksWithoutModifyingTheirTargets() throws {
    let documents = fixture.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let outside = fixture.appendingPathComponent("outside.db")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
    try FileManager.default.createSymbolicLink(
      at: documents.appendingPathComponent("localdrive.db"), withDestinationURL: outside
    )
    XCTAssertThrowsError(try BackgroundUploadDisk.protectExistingDatabase(in: documents)) { error in
      XCTAssertEqual((error as? BackgroundUploadFailure)?.code, "invalid_database_file")
    }
    XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: outside.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o644)
  }

  func testOSCompletionWaitsForPersistenceAndRunsOnlyOnce() {
    var gate = BackgroundUploadEventGate()
    var calls = 0
    gate.register(sessionId: "wifi") { calls += 1 }
    XCTAssertTrue(gate.takeReady(persistenceIsDurable: true).isEmpty)
    gate.finishedEvents(sessionId: "wifi")
    XCTAssertTrue(gate.takeReady(persistenceIsDurable: false).isEmpty)
    let ready = gate.takeReady(persistenceIsDurable: true)
    XCTAssertEqual(ready.count, 1)
    ready.forEach { $0() }
    XCTAssertEqual(calls, 1)
    XCTAssertTrue(gate.takeReady(persistenceIsDurable: true).isEmpty)
    gate.finishedEvents(sessionId: "wifi")
    XCTAssertTrue(gate.takeReady(persistenceIsDurable: true).isEmpty)
  }

  func testOSFinishCanArriveBeforeAppDelegateHandler() {
    var gate = BackgroundUploadEventGate()
    var calls = 0
    gate.finishedEvents(sessionId: "wifi")
    XCTAssertTrue(gate.takeReady(persistenceIsDurable: true).isEmpty)
    gate.register(sessionId: "wifi") { calls += 1 }
    gate.takeReady(persistenceIsDurable: true).forEach { $0() }
    XCTAssertEqual(calls, 1)
    gate.register(sessionId: "wifi") { calls += 1 }
    gate.receivedCompletion(sessionId: "wifi")
    XCTAssertTrue(gate.takeReady(persistenceIsDurable: true).isEmpty)
    gate.finishedEvents(sessionId: "wifi")
    gate.takeReady(persistenceIsDurable: true).forEach { $0() }
    XCTAssertEqual(calls, 2)
  }

  func testTokenProtectionUsesOneAttributeOnlyUpdateWithoutReadingSecret() throws {
    var calls = 0
    for enabled in [true, false] {
      try BackgroundUploadTokenAccessibility.update(key: "ld.token.instance::alice", enabled: enabled) { query, attributes in
        calls += 1
        let query = query as NSDictionary
        let attributes = attributes as NSDictionary
        XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService] as? String, "flutter_secure_storage_service")
        XCTAssertEqual(query[kSecAttrAccount] as? String, "ld.token.instance::alice")
        XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
        XCTAssertNil(query[kSecAttrAccessible])
        XCTAssertNil(query[kSecValueData])
        XCTAssertNil(query[kSecReturnData])
        XCTAssertEqual((query[kSecUseAuthenticationContext] as? LAContext)?.interactionNotAllowed, true)
        XCTAssertEqual(attributes.count, 1)
        XCTAssertEqual(
          attributes[kSecAttrAccessible] as? String,
          (enabled ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlocked) as String
        )
        return errSecSuccess
      }
    }
    XCTAssertEqual(calls, 2)
  }

  func testKeychainFailureIsNotRetriedWithSecretRecreation() {
    var calls = 0
    for status in [errSecInteractionNotAllowed, errSecItemNotFound] {
      XCTAssertThrowsError(try BackgroundUploadTokenAccessibility.update(key: "ld.token.instance::alice", enabled: true) { _, _ in
        calls += 1
        return status
      }) { error in
        XCTAssertEqual(
          (error as? BackgroundUploadFailure)?.code,
          status == errSecItemNotFound ? "keychain_item_not_found" : "keychain_\(status)"
        )
      }
    }
    XCTAssertEqual(calls, 2)
    for key in ["unrelated-item", "ld.token."] {
      XCTAssertThrowsError(try BackgroundUploadTokenAccessibility.update(key: key, enabled: true) { _, _ in
        calls += 1
        return errSecSuccess
      }) { error in
        XCTAssertEqual((error as? BackgroundUploadFailure)?.code, "invalid_token_key")
      }
    }
    XCTAssertEqual(calls, 2)
  }

  #if os(iOS)
  func testStableSessionConfigurationsDoNotShareCookieOrCredentialState() {
    for policy in BackgroundUploadPolicy.allCases {
      let configuration = BackgroundUploadCoordinator.configuration(for: policy)
      XCTAssertEqual(configuration.allowsCellularAccess, !policy.wifiOnly)
      XCTAssertEqual(configuration.allowsExpensiveNetworkAccess, !policy.wifiOnly)
      XCTAssertEqual(configuration.allowsConstrainedNetworkAccess, !policy.wifiOnly)
      XCTAssertNil(configuration.httpCookieStorage)
      XCTAssertNil(configuration.urlCredentialStorage)
      XCTAssertFalse(configuration.httpShouldSetCookies)
      XCTAssertFalse(configuration.isDiscretionary)
      XCTAssertTrue(configuration.sessionSendsLaunchEvents)
    }
  }

  func testStagingAndJournalProtectionAllowsOnlyAfterFirstUnlock() throws {
    _ = try request()
    let journal = try BackgroundUploadJournal(directory: journalDirectory())
    let retained = staging.root.appendingPathComponent("retained-source")
    try Data("retained".utf8).write(to: retained)
    try staging.protectExistingFiles()
    let documents = fixture.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let databaseFiles = ["", "-wal", "-shm", "-journal"].map {
      documents.appendingPathComponent("localdrive.db" + $0)
    }
    for file in databaseFiles { try Data("test".utf8).write(to: file) }
    try BackgroundUploadDisk.protectExistingDatabase(in: documents)
    for url in [staging.root, source!, retained, journal.file.deletingLastPathComponent(), journal.file] + databaseFiles {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
    }
  }
  #endif

  #if os(macOS)
  func testEarlyRegistrationAndMinimalLANATSRemainWired() throws {
    let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let delegate = try String(contentsOf: ios.appendingPathComponent("Runner/AppDelegate.swift"), encoding: .utf8)
    let launch = try XCTUnwrap(delegate.range(of: "return super.application"))
    let early = String(delegate[..<launch.lowerBound])
    XCTAssertTrue(early.contains("WorkmanagerPlugin.setPluginRegistrantCallback"))
    XCTAssertTrue(early.contains("WorkmanagerPlugin.registerBGProcessingTask"))
    XCTAssertTrue(early.contains("WorkmanagerPlugin.registerPeriodicTask"))
    XCTAssertTrue(early.contains("WorkmanagerPlugin.registerLaunchHandlers"))
    XCTAssertTrue(early.contains("BackgroundUploadCoordinator.shared.restore()"))
    XCTAssertTrue(delegate.contains("didInitializeImplicitFlutterEngine"))
    XCTAssertEqual(delegate.components(separatedBy: "BackgroundUploadPlugin.registerIfNeeded").count - 1, 2)
    XCTAssertTrue(delegate.contains("application, handleEventsForBackgroundURLSession: identifier"))
    let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
      from: Data(contentsOf: ios.appendingPathComponent("Runner/Info.plist")),
      options: [], format: nil
    ) as? [String: Any])
    let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
    XCTAssertNil(ats["NSAllowsArbitraryLoads"])
    XCTAssertNil(ats["NSAllowsArbitraryLoadsForMedia"])
    XCTAssertNil(ats["NSAllowsArbitraryLoadsInWebContent"])
    XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
    let ranges = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: [String: Any]])
    XCTAssertEqual(Set(ranges.keys), ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10"])
    for attributes in ranges.values {
      XCTAssertEqual(attributes.count, 1)
      XCTAssertEqual(attributes["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
    }
  }

  #endif
}
