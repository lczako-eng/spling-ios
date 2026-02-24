//
// AuthManager.swift
// Spling
//
import LocalAuthentication
import Foundation

enum AuthError: LocalizedError {
    case cancelled
    case biometryNotAvailable
    case biometryNotEnrolled
    case biometryLockout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentication was cancelled."
        case .biometryNotAvailable:
            return "Face ID / Touch ID is not available on this device."
        case .biometryNotEnrolled:
            return "No biometrics are enrolled. Please set up Face ID or Touch ID in Settings."
        case .biometryLockout:
            return "Biometry is locked after too many failed attempts. Please use your passcode."
        case .failed(let msg):
            return "Authentication failed: \(msg)"
        }
    }
}

final class AuthManager {
    static let shared = AuthManager()
    private init() {}

    // MARK: - Biometric Auth

    /// Authenticates the user with Face ID, Touch ID, or passcode fallback.
    /// Throws `AuthError.cancelled` if the user dismisses the prompt.
    func authenticate(reason: String = "Sign in to Spling") async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var authError: NSError?

        // Check whether biometry is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            throw mapLAError(authError)
        }

        // Perform evaluation — wraps callback-based API in async/await
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if !success {
                throw AuthError.failed("Authentication returned false without an error.")
            }
        } catch let laError as LAError {
            throw mapLAError(laError as NSError)
        }
    }

    // MARK: - Biometry Type

    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var biometryName: String {
        switch biometryType {
        case .faceID:   return "Face ID"
        case .touchID:  return "Touch ID"
        case .opticID:  return "Optic ID"
        default:        return "Biometrics"
        }
    }

    // MARK: - Private Helpers

    private func mapLAError(_ error: NSError?) -> AuthError {
        guard let error else { return .failed("Unknown authentication error.") }
        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .appCancel, .systemCancel:
            return .cancelled
        case .biometryNotAvailable, .passcodeNotSet:
            return .biometryNotAvailable
        case .biometryNotEnrolled:
            return .biometryNotEnrolled
        case .biometryLockout:
            return .biometryLockout
        default:
            return .failed(error.localizedDescription)
        }
    }
}
