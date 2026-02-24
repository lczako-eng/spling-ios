//
// HapticManager.swift
// Spling
//
import UIKit

/// Centralised haptic feedback wrapper.
/// All call sites check AccessibilitySettings.hapticFeedbackEnabled
/// before calling into UIKit generators, so haptics respect the user's preference.
final class HapticManager {
    static let shared = HapticManager()
    private init() {}

    // Pre-warmed generators — avoids first-use latency
    private let light   = UIImpactFeedbackGenerator(style: .light)
    private let medium  = UIImpactFeedbackGenerator(style: .medium)
    private let heavy   = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid   = UIImpactFeedbackGenerator(style: .rigid)
    private let soft    = UIImpactFeedbackGenerator(style: .soft)
    private let notify  = UINotificationFeedbackGenerator()
    private let select  = UISelectionFeedbackGenerator()

    // MARK: - Impact

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        switch style {
        case .light:  light.impactOccurred()
        case .medium: medium.impactOccurred()
        case .heavy:  heavy.impactOccurred()
        case .rigid:  rigid.impactOccurred()
        case .soft:   soft.impactOccurred()
        @unknown default: medium.impactOccurred()
        }
    }

    // MARK: - Notification

    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notify.notificationOccurred(type)
    }

    // MARK: - Selection

    func selection() {
        select.selectionChanged()
    }

    // MARK: - Prepare (reduces latency on next call)

    func prepare() {
        light.prepare()
        medium.prepare()
        notify.prepare()
        select.prepare()
    }
}
