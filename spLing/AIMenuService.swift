//
// AIMenuService.swift
// Spling
//
// Scrapes a vendor's website and uses the Claude API to extract
// structured menu data (categories, items, prices, descriptions).
// Menus are cached on disk so they survive app restarts.
//
import Foundation
import CryptoKit

// MARK: - Errors

enum AIMenuError: LocalizedError {
    case invalidURL
    case fetchFailed(String)
    case noUsableContent
    case parseFailed(String)
    case rateLimited
    case apiKeyMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return "That doesn't look like a valid website address."
        case .fetchFailed(let msg): return "Couldn't load the website: \(msg)"
        case .noUsableContent:      return "The website didn't contain readable menu content. Try linking directly to the /menu page, or paste a static version of the URL."
        case .parseFailed(let msg): return "AI couldn't extract a menu: \(msg)"
        case .rateLimited:          return "Too many requests. Please wait a moment and try again."
        case .apiKeyMissing:        return "Anthropic API key not configured. Add it in Settings → API Key."
        }
    }
}

// MARK: - Cache Entry

struct ScrapedMenuCache: Codable {
    let vendorURL:  String
    let vendorName: String
    let categories: [MenuCategory]
    let scrapedAt:  Date
    let expiresAt:  Date
    let confidence: String   // "high" | "medium" | "low"
    let notes:      String?

    var isExpired: Bool { Date() > expiresAt }

    var confidenceColor: String {
        switch confidence {
        case "high":   return "green"
        case "medium": return "orange"
        default:       return "red"
        }
    }
}

// MARK: - Claude Wire Types (private)

private struct ClaudeRequest: Encodable {
    let model:      String
    let max_tokens: Int
    let system:     String
    let messages:   [ClaudeMessage]
}
private struct ClaudeMessage: Encodable { let role: String; let content: String }
private struct ClaudeResponse: Decodable { let content: [ClaudeContent]; let stop_reason: String? }
private struct ClaudeContent: Decodable  { let type: String; let text: String? }

private struct AIExtractedMenu: Decodable {
    let vendorName:  String
    let currency:    String
    let categories:  [AIMenuCategory]
    let confidence:  String
    let notes:       String?
}
private struct AIMenuCategory: Decodable { let name: String; let items: [AIMenuItem] }
private struct AIMenuItem: Decodable {
    let name:         String
    let description:  String
    let priceCents:   Int
    let priceDisplay: String
    let calories:     Int?
    let allergens:    [String]
    let isAvailable:  Bool
}

// MARK: - AI Menu Service

actor AIMenuService {
    static let shared = AIMenuService()
    private init() {
        // Hydrate cache from disk on first use
        self.cache = PersistenceManager.shared.loadMenuCache()
    }

    private var cache: [String: ScrapedMenuCache] = [:]

    // MARK: - Public API

    func fetchMenu(from urlString: String, vendorName: String? = nil) async throws -> ScrapedMenuCache {
        let key = normalise(urlString)

        if let cached = cache[key], !cached.isExpired { return cached }

        guard !AppConfig.Claude.apiKey.isEmpty else { throw AIMenuError.apiKeyMissing }
        guard let url = URL(string: key) else { throw AIMenuError.invalidURL }

        let html      = try await fetchHTML(from: url)
        let text      = extractReadableText(from: html)
        guard text.count > 200 else { throw AIMenuError.noUsableContent }

        let extracted  = try await callClaude(pageText: text, siteURL: key, vendorHint: vendorName)
        let categories = mapToAppModels(extracted.categories, vendorURL: key)

        let result = ScrapedMenuCache(
            vendorURL:  key,
            vendorName: vendorName ?? extracted.vendorName,
            categories: categories,
            scrapedAt:  Date(),
            expiresAt:  Date().addingTimeInterval(AppConfig.Claude.menuCacheTTL),
            confidence: extracted.confidence,
            notes:      extracted.notes
        )
        cache[key] = result
        // Persist to disk so menus survive app restarts
        PersistenceManager.shared.saveMenuCache(cache)
        return result
    }

    func clearCache(for urlString: String) {
        cache.removeValue(forKey: normalise(urlString))
        PersistenceManager.shared.saveMenuCache(cache)
    }

    func clearAllCache() {
        cache.removeAll()
        PersistenceManager.shared.saveMenuCache(cache)
    }

    // MARK: - Step 1: Fetch HTML

    private func fetchHTML(from url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw AIMenuError.fetchFailed("No HTTP response")
            }
            if http.statusCode == 429 { throw AIMenuError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                throw AIMenuError.fetchFailed("HTTP \(http.statusCode)")
            }
            if let s = String(data: data, encoding: .utf8)      { return s }
            if let s = String(data: data, encoding: .isoLatin1) { return s }
            throw AIMenuError.fetchFailed("Could not decode page encoding")
        } catch let e as AIMenuError { throw e }
        catch { throw AIMenuError.fetchFailed(error.localizedDescription) }
    }

    // MARK: - Step 2: Strip HTML → readable text

    private func extractReadableText(from html: String) -> String {
        var t = html
        // Prefer <main> content to reduce noise
        if let mainRange = t.range(of: "<main[^>]*>", options: .regularExpression),
           let mainEnd   = t.range(of: "</main>", options: .regularExpression) {
            t = String(t[mainRange.upperBound..<mainEnd.lowerBound])
        }
        for tag in ["script","style","nav","footer","head","iframe","noscript","header","aside"] {
            t = t.replacingOccurrences(
                of: "<\(tag)[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [
            ("&amp;","&"),("&lt;","<"),("&gt;",">"),("&nbsp;"," "),
            ("&#39;","'"),("&quot;","\""),("&cent;","¢"),("&pound;","£"),
            ("&euro;","€"),("&dollar;","$"),("&frac12;","½")
        ] { t = t.replacingOccurrences(of: entity, with: char) }
        t = t.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let cap = 12_000
        if t.count > cap { t = String(t.prefix(cap)) + " [content truncated]" }
        return t
    }

    // MARK: - Step 3: Claude API call

    private func callClaude(pageText: String, siteURL: String, vendorHint: String?) async throws -> AIExtractedMenu {
        guard let apiURL = URL(string: AppConfig.Claude.apiURL) else {
            throw AIMenuError.parseFailed("Invalid Claude API URL in AppConfig")
        }
        let hint   = vendorHint.map { "The business is called \"\($0)\".\n" } ?? ""
        let system = """
        You are a menu extraction specialist for Spling, an NFC ordering app.
        Parse restaurant or retail website content and return structured JSON.

        STRICT RULES:
        1. Return ONLY valid JSON — no markdown, no explanations, no code fences.
        2. Prices MUST be integers in cents. "$5.99" → 599. "from $5" → 500. Unknown → 0.
        3. Also include the original price string in priceDisplay exactly as shown.
        4. Group items into logical categories (Drinks, Burgers, Sides, Desserts, etc.).
        5. Skip clearly non-consumable items (gift cards, merchandise, catering for >20 people).
        6. isAvailable = false for anything marked sold out, unavailable, or discontinued.
        7. allergens: only list from [Gluten, Dairy, Egg, Soy, Nuts, Fish, Shellfish, Sesame].
        8. confidence: "high" = clear prices + categories found. "medium" = partial data. "low" = guessed structure.
        9. notes: caveats like "prices may vary by location", "limited time menu", "seasonal items".

        Required JSON schema — return nothing else:
        {
          "vendorName": "string",
          "currency": "USD" | "CAD" | "GBP" | "EUR" | "AUD",
          "confidence": "high" | "medium" | "low",
          "notes": "string or null",
          "categories": [
            {
              "name": "string",
              "items": [
                {
                  "name": "string",
                  "description": "string",
                  "priceCents": integer,
                  "priceDisplay": "string",
                  "calories": integer or null,
                  "allergens": [],
                  "isAvailable": boolean
                }
              ]
            }
          ]
        }
        """
        let user = """
        \(hint)URL: \(siteURL)
        Page text:
        \(pageText)
        Extract the full menu and return as JSON only.
        """
        let payload = ClaudeRequest(
            model:      AppConfig.Claude.model,
            max_tokens: AppConfig.Claude.menuExtractionMaxTokens,
            system:     system,
            messages:   [ClaudeMessage(role: "user", content: user)]
        )
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.Claude.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(AppConfig.Claude.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(payload)
        req.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AIMenuError.parseFailed("No HTTP response from Claude API")
        }
        if http.statusCode == 429 { throw AIMenuError.rateLimited }
        guard (200...299).contains(http.statusCode) else {
            throw AIMenuError.parseFailed("Claude API HTTP \(http.statusCode)")
        }

        let claudeResp = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let raw = claudeResp.content.first(where: { $0.type == "text" })?.text,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIMenuError.parseFailed("Empty response from Claude")
        }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8) else {
            throw AIMenuError.parseFailed("Response was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(AIExtractedMenu.self, from: jsonData)
        } catch {
            throw AIMenuError.parseFailed("JSON schema mismatch: \(error.localizedDescription)")
        }
    }

    // MARK: - Step 4: Map AI output → app models

    private func mapToAppModels(_ aiCategories: [AIMenuCategory], vendorURL: String) -> [MenuCategory] {
        aiCategories.compactMap { cat in
            let items: [MenuItem] = cat.items
                .filter { $0.isAvailable }
                .map { item in
                    let desc = !item.description.isEmpty
                        ? item.description
                        : (!item.priceDisplay.isEmpty ? item.priceDisplay : "")
                    return MenuItem(
                        // Stable ID: hash of vendorURL + category + item name
                        id:             stableID(vendorURL: vendorURL, category: cat.name, itemName: item.name),
                        name:           item.name,
                        description:    desc,
                        priceCents:     item.priceCents,
                        imageURL:       nil,
                        customizations: [],
                        allergens:      item.allergens,
                        calories:       item.calories
                    )
                }
            guard !items.isEmpty else { return nil }
            return MenuCategory(
                id:    stableID(vendorURL: vendorURL, category: cat.name, itemName: ""),
                name:  cat.name,
                items: items
            )
        }
    }

    /// Generates a deterministic ID from a hash so re-scraping doesn't break cart references.
    private func stableID(vendorURL: String, category: String, itemName: String) -> String {
        let input = "\(vendorURL)|\(category)|\(itemName)"
        let hash  = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URL Normalisation

    private func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s.lowercased()
    }
}
