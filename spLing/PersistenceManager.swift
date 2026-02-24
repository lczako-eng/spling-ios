//
// PersistenceManager.swift
// Spling
//
// JSON-file-backed persistence for UserProfile and ScrapedMenuCache.
// This gives data survival across app restarts without the overhead of
// CoreData for a v1 build. Swap to CoreData or CloudKit for multi-device sync.
//
import Foundation

final class PersistenceManager {
    static let shared = PersistenceManager()
    private init() {}

    private let fm = FileManager.default

    // MARK: - Directories

    private var documentsURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func url(for filename: String) -> URL {
        documentsURL.appendingPathComponent(filename)
    }

    // MARK: - UserProfile

    private let profileFilename = "user_profile.json"

    func saveProfile(_ profile: UserProfile) {
        save(profile, to: profileFilename)
    }

    func loadProfile() -> UserProfile {
        load(UserProfile.self, from: profileFilename) ?? UserProfile()
    }

    // MARK: - Scraped Menu Cache

    private let menuCacheFilename = "menu_cache.json"

    func saveMenuCache(_ cache: [String: ScrapedMenuCache]) {
        save(cache, to: menuCacheFilename)
    }

    func loadMenuCache() -> [String: ScrapedMenuCache] {
        load([String: ScrapedMenuCache].self, from: menuCacheFilename) ?? [:]
    }

    // MARK: - Generic Helpers

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save<T: Encodable>(_ value: T, to filename: String) {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url(for: filename), options: .atomicWrite)
        } catch {
            #if DEBUG
            print("[PersistenceManager] Save error (\(filename)): \(error)")
            #endif
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let fileURL = url(for: filename)
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(type, from: data)
        } catch {
            #if DEBUG
            print("[PersistenceManager] Load error (\(filename)): \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Clear All (used on sign-out)

    func clearAll() {
        for filename in [profileFilename, menuCacheFilename] {
            try? fm.removeItem(at: url(for: filename))
        }
    }
}
