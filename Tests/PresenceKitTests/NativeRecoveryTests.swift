#if os(macOS)
import XCTest
import AVFoundation
@testable import PresenceKit

final class NativeRecoveryTests: XCTestCase {
    func testAVFoundationFailureReasonsUseDomainAndCode() {
        let cases: [(AVError.Code, PresenceError)] = [
            (.deviceWasDisconnected, .captureFailure(.disconnected)),
            (.deviceInUseByAnotherApplication, .captureFailure(.deviceInUse)),
            (.applicationIsNotAuthorizedToUseDevice, .cameraPermissionDenied)
        ]
        for (code, expected) in cases {
            let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "arbitrary localized text"])
            XCTAssertEqual(CameraPresenceSource.classify(error), expected)
        }
    }
    func testTypedResetReasonFromCustomSourcesIsPreserved() {
        // The portable contract supports explicit custom-source reset failures,
        // without referring to an AVError symbol absent from the macOS SDK.
        let error = PresenceError.captureFailure(.mediaServicesReset)
        XCTAssertEqual(CameraPresenceSource.classify(error), error)
        XCTAssertTrue(error.isRetryable)
    }
    func testUnknownAVFoundationCodeRemainsTerminal() {
        let error = NSError(domain: AVFoundationErrorDomain, code: Int.max,
                            userInfo: [NSLocalizedDescriptionKey: "media services reset"])
        let classified = CameraPresenceSource.classify(error)
        XCTAssertEqual(classified, .cameraUnavailable("media services reset"))
        XCTAssertFalse(classified.isRetryable)
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
