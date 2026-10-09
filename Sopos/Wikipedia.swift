import Foundation

/// Looks up songs/artists via the public MediaWiki search API (no key needed).
enum Wikipedia {
    /// Prefers the song's article (a result mentioning the artist), falls back to the artist's article.
    static func article(artist: String?, title: String?) async throws -> URL? {
        let artist = artist.map(mainArtist)
        let title = title.map(cleanTitle)

        if let title, let artist,
           let page = try await search("\(title) \(artist)").first(where: { $0.mentions(artist) }) {
            return page.url
        }
        if let artist, let page = try await search(artist).first(where: { $0.mentions(artist) }) {
            return page.url
        }
        if artist == nil, let title {
            return try await search("\(title) song").first?.url
        }
        return nil
    }

    private struct Page: Decodable {
        let title: String
        let snippet: String

        var url: URL? {
            let path = title.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return URL(string: "https://en.wikipedia.org/wiki/\(path)")
        }

        func mentions(_ name: String) -> Bool {
            // Snippets contain highlight markup like <span class="searchmatch">Amy</span>.
            let text = (title + " " + snippet).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return Wikipedia.normalized(text).contains(Wikipedia.normalized(name))
        }
    }

    /// Loose comparison form: "The B-52's", "the B-52&#039;s" and "The B-52s" all become "theb52s".
    private static func normalized(_ text: String) -> String {
        let decoded = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#[0-9]+;|&[a-z]+;", with: "", options: .regularExpression)
        return decoded.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private struct Response: Decodable {
        struct Query: Decodable { let search: [Page] }
        let query: Query?
    }

    private static func search(_ query: String) async throws -> [Page] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "srprop", value: "snippet"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        // Wikimedia asks API clients to identify themselves.
        request.setValue("Sopos/1.0 (https://github.com/philippkeller/sopos)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Response.self, from: data).query?.search ?? []
    }

    /// "Rehab (Remastered 2011) - Radio Edit" → "Rehab"
    private static func cleanTitle(_ title: String) -> String {
        let withoutBrackets = title.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "",
                                                        options: .regularExpression)
        let main = withoutBrackets.components(separatedBy: " - ").first ?? withoutBrackets
        let trimmed = main.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// "Mark Ronson feat. Amy Winehouse" → "Mark Ronson" (duos like "Simon & Garfunkel" stay intact)
    private static func mainArtist(_ artist: String) -> String {
        let separators = [" feat. ", " feat ", " ft. ", " featuring "]
        var main = artist
        for separator in separators {
            if let range = main.range(of: separator, options: .caseInsensitive) {
                main = String(main[..<range.lowerBound])
            }
        }
        let trimmed = main.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }
}
