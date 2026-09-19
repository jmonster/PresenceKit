#if os(macOS)
import XCTest
import AVFoundation
@testable import PresenceKit

final class NativeRecoveryTests: XCTestCase {
    func testAVFoundationFailureReasonsUseDomainAndCode() {
        let cases: [(AVError.Code, PresenceError)] = [
            (.deviceWasDisconnected, .captureFailure(.disconnected)),
            (.deviceInUseByAnotherApplication, .captureFailure(.deviceInUse)),
            (.mediaServicesWereReset, .captureFailure(.mediaServicesReset)),
            (.applicationIsNotAuthorizedToUseDevice, .cameraPermissionDenied)
        ]
        for (code, expected) in cases {
            let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "arbitrary localized text"])
            XCTAssertEqual(CameraPresenceSource.classify(error), expected)
        }
    }
    func testUnknownDriverDomainCannotMasqueradeAsRetryableAVError() {
        let error = NSError(domain: "CustomDriver", code: AVError.Code.deviceWasDisconnected.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "disconnected"])
        let classified = CameraPresenceSource.classify(error)
        XCTAssertEqual(classified, .cameraUnavailable("disconnected"))
        XCTAssertFalse(classified.isRetryable)
    }
}
#endif
