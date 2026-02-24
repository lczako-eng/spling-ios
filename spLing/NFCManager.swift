//
// NFCManager.swift
// Spling
//
// Reads NDEF-formatted NFC tags at drive-through terminals.
// Requires "Near Field Communication Tag Reading" capability in Xcode
// and the NFCReaderUsageDescription key in Info.plist.
//
import CoreNFC
import Combine

enum NFCError: LocalizedError {
    case notSupported
    case sessionInvalidated(String)
    case noNDEFFound
    case invalidPayload
    case tagDecodeError(String)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "NFC is not supported on this device."
        case .sessionInvalidated(let msg):
            return msg.isEmpty ? "NFC session ended." : msg
        case .noNDEFFound:
            return "No Spling tag found. Make sure you're holding the phone near the terminal."
        case .invalidPayload:
            return "This NFC tag isn't a Spling terminal tag."
        case .tagDecodeError(let msg):
            return "Couldn't read the tag: \(msg)"
        }
    }
}

@MainActor
final class NFCManager: NSObject, ObservableObject {

    @Published var isScanning:       Bool             = false
    @Published var detectedPayload:  NFCTagPayload?   = nil
    @Published var error:            NFCError?        = nil

    private var session: NFCNDEFReaderSession?

    // MARK: - Public API

    func startSession() {
        guard NFCNDEFReaderSession.readingAvailable else {
            error = .notSupported
            return
        }
        reset()
        session = NFCNDEFReaderSession(
            delegate: self,
            queue: .main,
            invalidateAfterFirstRead: true
        )
        session?.alertMessage = AppConfig.NFC.alertMessage
        session?.begin()
        isScanning = true
    }

    func reset() {
        isScanning      = false
        detectedPayload = nil
        error           = nil
    }
}

// MARK: - NFCNDEFReaderSessionDelegate

extension NFCManager: NFCNDEFReaderSessionDelegate {

    nonisolated func readerSession(
        _ session: NFCNDEFReaderSession,
        didInvalidateWithError error: Error
    ) {
        Task { @MainActor in
            self.isScanning = false
            if let nfcError = error as? NFCReaderError {
                switch nfcError.code {
                case .readerSessionInvalidationErrorFirstNDEFTagRead,
                     .readerSessionInvalidationErrorUserCanceled:
                    // Normal termination — don't surface as an error
                    break
                default:
                    self.error = .sessionInvalidated(nfcError.localizedDescription)
                }
            }
        }
    }

    nonisolated func readerSession(
        _ session: NFCNDEFReaderSession,
        didDetectNDEFs messages: [NFCNDEFMessage]
    ) {
        Task { @MainActor in
            self.isScanning = false
            guard let firstRecord = messages.first?.records.first else {
                self.error = .noNDEFFound
                return
            }

            // Spling tags use the "T" (text) NDEF well-known type record
            guard firstRecord.typeNameFormat == .nfcWellKnown,
                  firstRecord.type == Data([0x54])   // "T" in ASCII
            else {
                self.error = .invalidPayload
                return
            }

            do {
                let payload = try NFCTagPayload.from(ndefPayload: firstRecord.payload)
                self.detectedPayload = payload
            } catch {
                self.error = .tagDecodeError(error.localizedDescription)
            }
        }
    }
}
