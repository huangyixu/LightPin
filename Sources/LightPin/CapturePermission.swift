import Foundation
import ScreenCaptureKit

struct CapturePermissionState {
    private(set) var requiresUserRecovery = false
    mutating func record(_ error: Error) {
        if Self.isDenied(error) { requiresUserRecovery = true }
    }
    mutating func retryRequested() { requiresUserRecovery = false }
    static func isDenied(_ error: Error) -> Bool {
        var current = error as NSError
        for _ in 0..<8 {
            if current.domain == SCStreamErrorDomain && current.code == SCStreamError.Code.userDeclined.rawValue { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = underlying
        }
        return false
    }
}
