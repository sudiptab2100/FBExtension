#if os(macOS)
import Darwin
import XCTest

final class NativeTestReporter: NSObject, XCTestObservation {
  func testCase(
    _ testCase: XCTestCase, didFailWithDescription description: String,
    inFile filePath: String?, atLine lineNumber: Int
  ) {
    print("\(testCase.name):\(lineNumber): \(description)")
  }
}

let reporter = NativeTestReporter()
XCTestObservationCenter.shared.addTestObserver(reporter)
let suite = RunnerTests.defaultTestSuite
suite.run()
let run = suite.testRun
print("Native XCTest: \(run?.executionCount ?? 0) tests, \(run?.totalFailureCount ?? 0) failures")
exit(run?.hasSucceeded == true && (run?.executionCount ?? 0) > 0 ? 0 : 1)
#endif
