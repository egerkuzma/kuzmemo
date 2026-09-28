import Foundation

/// Helpers around the user's glossary of brands and names.
public enum Glossary {
    /// Replaces known misspellings ("нотион") with the canonical form ("Notion"), whole words only,
    /// case-insensitively. Longer aliases are applied first so "гитхаб" wins over "гит".
    public static func applyAliases(to text: String, terms: [GlossaryTerm]) -> String {
        let pairs = terms.filter(\.enabled).flatMap { term in
            term.aliases.map { (alias: $0.trimmingCharacters(in: .whitespaces), canonical: term.canonical) }
        }
        .filter { !$0.alias.isEmpty }
        .sorted { $0.alias.count > $1.alias.count }

        var result = text
        for pair in pairs {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: pair.alias) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: pair.canonical)
            )
        }
        return result
    }

    /// One line for the LLM prompt: "Notion (нотион, ношн); GitHub (гитхаб)".
    public static func promptLine(terms: [GlossaryTerm], limit: Int = 60) -> String {
        terms.filter(\.enabled).prefix(limit).map { term in
            term.aliases.isEmpty ? term.canonical : "\(term.canonical) (\(term.aliases.joined(separator: ", ")))"
        }.joined(separator: "; ")
    }

    /// Text prepared for a speech synthesizer: brand names swapped for their spoken (usually Cyrillic) form.
    public static func spokenForm(of text: String, terms: [GlossaryTerm]) -> String {
        var result = text
        for term in terms.filter(\.enabled) {
            guard let spoken = term.spoken, !spoken.isEmpty else { continue }
            result = result.replacingOccurrences(of: term.canonical, with: spoken, options: .caseInsensitive)
        }
        return result
    }
}
