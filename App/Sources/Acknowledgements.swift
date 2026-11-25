import Foundation

/// One third-party component, parsed from the bundled THIRD_PARTY_NOTICES.md.
struct Acknowledgement: Identifiable, Hashable, Sendable {
    let name: String
    let version: String
    let licence: String
    let source: String
    let use: String
    let licenceText: String

    var id: String { name }
}

enum AcknowledgementsError: Error, Equatable {
    case fileMissing
    case noTable
    case missingLicenceText(String)
    case licenceTextWithoutRow(String)
}

enum Acknowledgements {
    static let resourceName = "THIRD_PARTY_NOTICES"

    /// Entries from the copy of docs/THIRD_PARTY_NOTICES.md bundled into the app.
    static func bundled(in bundle: Bundle = .main) throws -> [Acknowledgement] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "md") else {
            throw AcknowledgementsError.fileMissing
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// Parses the notices file: a table whose first column names a `###` section holding the licence text.
    static func parse(_ markdown: String) throws -> [Acknowledgement] {
        let lines = markdown.components(separatedBy: "\n")

        // Table rows: the lines after the "|---" separator, until the first non-table line.
        guard let separator = lines.firstIndex(where: { $0.hasPrefix("|---") }) else { throw AcknowledgementsError.noTable }
        var rows: [[String]] = []
        for line in lines[(separator + 1)...] {
            guard line.hasPrefix("|") else { break }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count == 5 { rows.append(cells) }
        }
        guard !rows.isEmpty else { throw AcknowledgementsError.noTable }

        // Licence texts: the fenced block under each "### Name" heading.
        var texts: [String: String] = [:]
        var current: String?
        var inFence = false
        var buffer: [String] = []
        for line in lines {
            if !inFence, line.hasPrefix("### ") {
                current = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("```") {
                if inFence, let name = current {
                    texts[name] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    current = nil
                }
                inFence.toggle()
                buffer = []
            } else if inFence, current != nil {
                buffer.append(line)
            }
        }

        let entries = try rows.map { cells in
            guard let text = texts[cells[0]], !text.isEmpty else { throw AcknowledgementsError.missingLicenceText(cells[0]) }
            return Acknowledgement(name: cells[0], version: cells[1], licence: cells[2], source: cells[3], use: cells[4], licenceText: text)
        }
        if let orphan = texts.keys.sorted().first(where: { name in !rows.contains { $0[0] == name } }) {
            throw AcknowledgementsError.licenceTextWithoutRow(orphan)
        }
        return entries
    }
}
