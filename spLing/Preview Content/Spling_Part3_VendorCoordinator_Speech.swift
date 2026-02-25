// ============================================================
// SPLING — FULL STACK v5
// AccessibilityPathways_Part1.swift
// Contains:
// • VendorContextCoordinator (QR → AI menu bridge)
// • SpeechRecognitionManager (Adaptive ML Speech pathway)
// • AdaptiveSpeechViewModel
// • AdaptiveSpeechView
// ADD this file to your Xcode target.
// ============================================================
import SwiftUI
import Speech
import AVFoundation

// ─────────────────────────────────────────────────────────────
// MARK: - Vendor Context Coordinator (QR → Menu Bridge)
// ─────────────────────────────────────────────────────────────

enum CoordinatorLoadState: Equatable {
    case idle, loading, loaded, failed
}

@MainActor
final class VendorContextCoordinator: ObservableObject {
    @Published var loadState: CoordinatorLoadState = .idle
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var pendingVendorName: String?

    private var lastInput: VendorContextInput?

    // MARK: - Public API

    /// Entry point called from HomeView after QR scan is parsed.
    func loadVendorFromQR(
        input: VendorContextInput,
        vendorVM: VendorViewModel,
        cart: CartViewModel,
        session: UserSessionViewModel
    ) async {
        lastInput = input
        loadState = .loading
        errorMessage = nil
        showError = false
        pendingVendorName = input.vendorName

        let urlString = input.vendorURL.absoluteString
        do {
            let cache = try await AIMenuService.shared.fetchMenu(
                from: urlString,
                vendorName: input.vendorName
            )
            let categories = cache.categories
            let vendor = Vendor(
                id: input.vendorID ?? generateVendorID(from: urlString),
                name: cache.vendorName,
                address: "",
                menuCategories: categories,
                supportsOrderHistory: true,
                personalizedRecommendations: false
            )
            cart.vendorID = vendor.id
            cart.vendorName = vendor.name
            if let terminalType = input.terminalType {
                cart.activeTerminalType = terminalType
            }
            vendorVM.loadFromAIResult(vendor: vendor)
            vendorVM.orderHistoryAtVendor = session.savedOrders(for: vendor.id)
            loadState = .loaded
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            loadState = .failed
        }
    }

    /// Retry after failure — clears cache to force fresh AI call.
    func retry(vendorVM: VendorViewModel, cart: CartViewModel, session: UserSessionViewModel) async {
        guard let input = lastInput else { return }
        await AIMenuService.shared.clearCache(for: input.vendorURL.absoluteString)
        await loadVendorFromQR(input: input, vendorVM: vendorVM, cart: cart, session: session)
    }

    func reset() {
        loadState = .idle
        errorMessage = nil
        showError = false
        pendingVendorName = nil
    }

    // MARK: - Helpers

    private func generateVendorID(from urlString: String) -> String {
        let clean = urlString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "/", with: "-")
        return String(clean.prefix(40))
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Speech Recognition Manager (Adaptive ML Speech)
// ─────────────────────────────────────────────────────────────

/// Wraps Apple's SFSpeechRecognizer and overlays Spling's personal
/// ML phrase matching on top of the raw transcript.
@MainActor
final class SpeechRecognitionManager: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    @Published var transcript: String = ""
    @Published var permissionDenied: Bool = false
    @Published var recognitionError: String?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale.current)
    }

    // MARK: - Public API

    func requestPermissionsIfNeeded() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.permissionDenied = (status != .authorized)
            }
        }
    }

    func startListening() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            recognitionError = "Speech recognition is not available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            request = SFSpeechAudioBufferRecognitionRequest()
            guard let request else { return }
            request.shouldReportPartialResults = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result {
                        self?.transcript = result.bestTranscription.formattedString
                    }
                    if error != nil || result?.isFinal == true {
                        self?.stopListening()
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            HapticManager.shared.impact(.medium)
        } catch {
            recognitionError = error.localizedDescription
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        HapticManager.shared.impact(.light)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Adaptive Speech ViewModel
// ─────────────────────────────────────────────────────────────

@MainActor
class AdaptiveSpeechViewModel: ObservableObject {
    @Published var matchedItem: MenuItem?
    @Published var confirmationNeeded: Bool = false
    @Published var orderConfirmed: Bool = false
    @Published var attempts: [SpeechRecognitionAttempt] = []

    private var voiceProfile: VoiceMLProfile
    private let allItems: [MenuItem]

    init(menuItems: [MenuItem], voiceProfile: VoiceMLProfile) {
        self.allItems = menuItems
        self.voiceProfile = voiceProfile
    }

    /// Called when speech recognition produces a transcript.
    func processTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Check personal ML model first
        if let matchedID = voiceProfile.bestMatch(for: trimmed),
           let item = allItems.first(where: { $0.id == matchedID }) {
            let attempt = SpeechRecognitionAttempt(
                rawTranscript: trimmed,
                confidence: 0.9,
                matchedMenuItemID: item.id,
                timestamp: Date()
            )
            attempts.append(attempt)
            matchedItem = item
            confirmationNeeded = true
            HapticManager.shared.impact(.medium)
            return
        }

        // 2. Fallback: fuzzy name match against menu items
        let lower = trimmed.lowercased()
        if let item = allItems.first(where: { lower.contains($0.name.lowercased()) }) {
            let attempt = SpeechRecognitionAttempt(
                rawTranscript: trimmed,
                confidence: 0.7,
                matchedMenuItemID: item.id,
                timestamp: Date()
            )
            attempts.append(attempt)
            matchedItem = item
            confirmationNeeded = true
            HapticManager.shared.impact(.medium)
        }
    }

    /// User taps photo or says "yes" — confirms the matched item.
    func confirmMatch(cart: CartViewModel) {
        guard let item = matchedItem else { return }
        cart.add(item)
        if let lastAttempt = attempts.last {
            voiceProfile.learn(phrase: lastAttempt.rawTranscript, menuItemID: item.id)
        }
        orderConfirmed = true
        confirmationNeeded = false
        HapticManager.shared.notification(.success)
    }

    func rejectMatch() {
        matchedItem = nil
        confirmationNeeded = false
        orderConfirmed = false
        HapticManager.shared.impact(.light)
    }

    func updatedProfile() -> VoiceMLProfile { voiceProfile }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Adaptive Speech View
// ─────────────────────────────────────────────────────────────

struct AdaptiveSpeechView: View {
    let menuItems: [MenuItem]
    let voiceProfile: VoiceMLProfile
    let onConfirm: (MenuItem, VoiceMLProfile) -> Void
    let onDismiss: () -> Void

    @StateObject private var speechManager = SpeechRecognitionManager()
    @StateObject private var vm: AdaptiveSpeechViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    init(menuItems: [MenuItem], voiceProfile: VoiceMLProfile,
         onConfirm: @escaping (MenuItem, VoiceMLProfile) -> Void,
         onDismiss: @escaping () -> Void) {
        self.menuItems = menuItems
        self.voiceProfile = voiceProfile
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        _vm = StateObject(wrappedValue: AdaptiveSpeechViewModel(
            menuItems: menuItems,
            voiceProfile: voiceProfile
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 52))
                        .foregroundStyle(.purple)
                        .symbolEffect(.variableColor.iterative, isActive: speechManager.isListening)

                    Text("Speak Your Order")
                        .font(.system(size: accessibility.dynamicFontSize + 6, weight: .bold))

                    Text("Say any way you can — I'll understand you")
                        .font(.system(size: accessibility.dynamicFontSize - 2))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // Transcript live display
                if !speechManager.transcript.isEmpty {
                    Text("\"\(speechManager.transcript)\"")
                        .font(.system(size: accessibility.dynamicFontSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)
                }

                // Confirmation screen — large photo + Yes/No
                if vm.confirmationNeeded, let item = vm.matchedItem {
                    confirmationCard(item: item)
                } else {
                    micButton
                }

                if speechManager.permissionDenied {
                    Label("Microphone access denied. Enable in Settings.", systemImage: "mic.slash.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: accessibility.dynamicFontSize - 3))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .navigationTitle("Adaptive Speech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        speechManager.stopListening()
                        onDismiss()
                    }
                }
            }
            .onAppear { speechManager.requestPermissionsIfNeeded() }
            .onChange(of: speechManager.transcript) { _, transcript in
                guard !speechManager.isListening else { return }
                vm.processTranscript(transcript)
            }
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        Button {
            if speechManager.isListening {
                speechManager.stopListening()
                vm.processTranscript(speechManager.transcript)
            } else {
                speechManager.transcript = ""
                speechManager.startListening()
                accessibility.announceForVoiceOver("Listening. Speak your order now.")
            }
        } label: {
            VStack(spacing: 12) {
                Circle()
                    .fill(speechManager.isListening ? Color.red : Color.purple)
                    .frame(width: 100, height: 100)
                    .overlay {
                        Image(systemName: speechManager.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                    }
                    .shadow(
                        color: speechManager.isListening ? .red.opacity(0.4) : .purple.opacity(0.3),
                        radius: speechManager.isListening ? 20 : 8
                    )

                Text(speechManager.isListening ? "Tap to stop" : "Tap to speak")
                    .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                    .foregroundStyle(speechManager.isListening ? .red : .purple)
            }
        }
        .accessibilityLabel(speechManager.isListening
            ? "Stop listening"
            : "Start speaking your order. Say anything — slurred speech and partial words are OK.")
    }

    // MARK: - Confirmation Card

    private func confirmationCard(item: MenuItem) -> some View {
        VStack(spacing: 20) {
            Text("Did you mean?")
                .font(.system(size: accessibility.dynamicFontSize - 1))
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 20)
                .fill(Color.blue.opacity(0.12))
                .frame(height: 180)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "fork.knife.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.blue)
                        Text(item.name)
                            .font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                        Text(item.formattedPrice)
                            .font(.system(size: accessibility.dynamicFontSize))
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal)

            HStack(spacing: 20) {
                Button {
                    HapticManager.shared.notification(.error)
                    vm.rejectMatch()
                    accessibility.announceForVoiceOver("Rejected. Tap mic to try again.")
                } label: {
                    Label("No", systemImage: "xmark.circle.fill")
                        .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("No — try again")

                // FIX: onConfirm is called inside the button action, not a separate gesture
                Button {
                    accessibility.announceForVoiceOver("\(item.name) added to order.")
                    onConfirm(item, vm.updatedProfile())
                } label: {
                    Label("Yes", systemImage: "checkmark.circle.fill")
                        .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .accessibilityLabel("Yes — add \(item.name) to order")
            }
            .padding(.horizontal)
        }
    }
}
