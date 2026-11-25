import Foundation
import Testing
@testable import Epistoli

@Suite struct AcknowledgementsTests {
    /// The repository copy of the notices file (the simulator can read the Mac's filesystem).
    private static let repoFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/THIRD_PARTY_NOTICES.md")

    /// Component names straight from the file's table, with a deliberately simple scan
    /// that is independent of the app's parser.
    private static func tableNames(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Component ") }
            .map { $0.split(separator: "|")[0].trimmingCharacters(in: .whitespaces) }
    }

    private static func sectionNames(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("### ") }
            .map { String($0.dropFirst(4)) }
    }

    @Test func bundledFileMatchesRepository() throws {
        let repo = try Data(contentsOf: Self.repoFile)
        let url = try #require(Bundle.main.url(forResource: Acknowledgements.resourceName, withExtension: "md"))
        #expect(try Data(contentsOf: url) == repo)
    }

    @Test func screenListsEveryEntryInTheFile() throws {
        let text = try String(contentsOf: Self.repoFile, encoding: .utf8)
        let expected = Self.tableNames(text)
        #expect(expected.count == 10)
        #expect(Set(Self.sectionNames(text)) == Set(expected), "every table row needs a licence text section and vice versa")

        let screen = AcknowledgementsView()
        #expect(screen.entries.map(\.name) == expected)
        #expect(screen.entries.allSatisfy { !$0.licenceText.isEmpty && !$0.version.isEmpty && !$0.licence.isEmpty })
    }

    @Test func requiredComponentsAreAcknowledged() throws {
        let names = try Acknowledgements.bundled().map(\.name)
        for required in ["GopenPGP", "go-crypto", "CIRCL", "gomobile", "Go", "GRDB.swift", "SQLCipher Community Edition", "SQLite"] {
            #expect(names.contains(required), "\(required) missing from Acknowledgements")
        }
    }

    @Test func bsdNoticesCarryTheirCopyrightLines() throws {
        for entry in try Acknowledgements.bundled() where entry.licence.hasPrefix("BSD") {
            #expect(entry.licenceText.contains("Copyright"), "\(entry.name) licence text has no copyright notice")
            #expect(entry.licenceText.contains("Redistribution and use"), "\(entry.name) licence text looks truncated")
        }
    }

    @Test func parserRejectsRowWithoutLicenceText() {
        let md = """
        | Component | Version | Licence | Source | Used for |
        |---|---|---|---|---|
        | Thing | 1 | MIT | x | y |

        """
        #expect(throws: AcknowledgementsError.missingLicenceText("Thing")) { try Acknowledgements.parse(md) }
    }

    @Test func parserRejectsLicenceTextWithoutRow() {
        let md = """
        | Component | Version | Licence | Source | Used for |
        |---|---|---|---|---|
        | A | 1 | MIT | x | y |

        ### A

        ```text
        a
        ```

        ### B

        ```text
        b
        ```
        """
        #expect(throws: AcknowledgementsError.licenceTextWithoutRow("B")) { try Acknowledgements.parse(md) }
    }
}
