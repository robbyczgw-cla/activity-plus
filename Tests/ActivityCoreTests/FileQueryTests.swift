import Foundation
import Testing
@testable import ActivityCore

private let queryNow = Date(timeIntervalSince1970: 1_800_000_000)

private struct QuerySample {
    var name = "Invoice 2026.pdf"
    var bytes: UInt64 = 1_000
    var modifiedDays = 10.0
    var openedDays: Double? = 5
    var kind = FileKind.document
}

private func queryHits(_ text: String, _ sample: QuerySample = QuerySample()) -> Bool {
    FileQuery.parse(text).matches(
        name: sample.name,
        bytes: sample.bytes,
        modified: queryNow.addingTimeInterval(-sample.modifiedDays * 86_400),
        accessed: sample.openedDays.map { queryNow.addingTimeInterval(-$0 * 86_400) },
        kind: sample.kind,
        now: queryNow)
}

@Suite("File search query")
struct FileQueryTests {
    @Test func emptyQueryMatchesEverything() {
        for text in ["", "   ", "\t"] {
            #expect(FileQuery.parse(text).isEmpty)
            #expect(queryHits(text, QuerySample(name: "anything")))
        }
        #expect(FileQuery.parse("\"\"").isEmpty)
        #expect(FileQuery.parse("-").isEmpty)
        #expect(!FileQuery.parse("invoice").isEmpty)
    }

    @Test func plainWordsAreCaseAndDiacriticInsensitive() {
        #expect(queryHits("invoice"))
        #expect(queryHits("INVOICE 2026"))
        #expect(!queryHits("receipt"))
        #expect(queryHits("ecole", QuerySample(name: "École notes.txt")))
    }

    @Test func quotedPhraseIsOneToken() {
        #expect(queryHits("\"invoice 2026\""))
        #expect(!queryHits("\"2026 invoice\""))
        #expect(queryHits("invoice \"2026.pdf\""))
        #expect(queryHits("\"invoice"), "unbalanced quote runs to the end")
    }

    @Test func unknownKeysAreWords() {
        #expect(!queryHits("foo:bar"))
        #expect(queryHits("foo:bar", QuerySample(name: "my foo:bar file")))
        #expect(queryHits("note:x", QuerySample(name: "note:x.txt")))
    }

    @Test func extensionFilters() {
        #expect(queryHits("ext:pdf"))
        #expect(queryHits("EXT:PDF"))
        #expect(queryHits("ext:dmg,pdf"))
        #expect(!queryHits("ext:dmg,zip"))
        #expect(queryHits("ext:.pdf"))
        #expect(queryHits(".pdf"))
        #expect(queryHits(".PDF"))
        #expect(!queryHits(".dmg"))
        #expect(queryHits("ext:jpg", QuerySample(name: "IMG_0001.JPG")))
        #expect(queryHits("ext:gz", QuerySample(name: "archive.tar.gz")))
        #expect(!queryHits("ext:tar", QuerySample(name: "archive.tar.gz")))
        #expect(!queryHits("ext:pdf", QuerySample(name: "README")))
        #expect(FileQuery.parse("ext:pdf") == FileQuery.parse(".pdf"))
    }

    @Test func negationInvertsEveryToken() {
        #expect(!queryHits("-ext:pdf"))
        #expect(queryHits("-ext:dmg"))
        #expect(!queryHits("-invoice"))
        #expect(queryHits("-receipt"))
        #expect(queryHits("-.dmg"))
        #expect(!queryHits("-.pdf"))
        #expect(!queryHits("-\"invoice 2026\""))
        #expect(queryHits("-kind:video"))
        #expect(!queryHits("-kind:document"))
        #expect(!queryHits("-size:>500b"))
        #expect(!queryHits("-age:>5d"))
        #expect(!queryHits("-opened:>180d", QuerySample(openedDays: 200)))
    }

    @Test func kindAliases() {
        let cases: [(String, FileKind)] = [
            ("video", .video), ("videos", .video),
            ("image", .image), ("images", .image), ("photos", .image),
            ("audio", .audio), ("music", .audio),
            ("archive", .archive), ("archives", .archive),
            ("code", .code),
            ("docs", .document), ("documents", .document),
            ("apps", .app),
            ("cache", .dataCache), ("caches", .dataCache), ("data", .dataCache),
            ("other", .other),
        ]
        for (word, kind) in cases {
            #expect(queryHits("kind:\(word)", QuerySample(kind: kind)), "\(word) matches its kind")
            #expect(!queryHits("kind:\(word)", QuerySample(kind: kind == .other ? .code : .other)), "\(word) excludes others")
        }
        #expect(queryHits("KIND:Videos", QuerySample(kind: .video)))
        #expect(queryHits("kind:video,document"))
        #expect(!queryHits("kind:video"))
    }

    @Test func malformedKindIsIgnored() {
        #expect(FileQuery.parse("kind:bogus").isEmpty)
        #expect(queryHits("kind:bogus", QuerySample(name: "x")))
        #expect(FileQuery.parse("kind:video,bogus").isEmpty)
    }

    @Test func sizeComparisons() {
        #expect(queryHits("size:>300mb", QuerySample(bytes: 400_000_000)))
        #expect(!queryHits("size:>300mb", QuerySample(bytes: 300_000_000)))
        #expect(queryHits("size:>=300mb", QuerySample(bytes: 300_000_000)))
        #expect(queryHits("size:<1gb", QuerySample(bytes: 999_999_999)))
        #expect(!queryHits("size:<1gb", QuerySample(bytes: 1_000_000_000)))
        #expect(queryHits("size:<=1gb", QuerySample(bytes: 1_000_000_000)))
        #expect(queryHits("size:>=2g", QuerySample(bytes: 2_000_000_000)))
        #expect(!queryHits("size:>=2g", QuerySample(bytes: 1_999_999_999)))
        #expect(queryHits("size:>1.5gb", QuerySample(bytes: 1_500_000_001)))
        #expect(!queryHits("size:>1.5gb", QuerySample(bytes: 1_500_000_000)))
    }

    @Test func bareSizeMeansAtLeast() {
        #expect(queryHits("size:300mb", QuerySample(bytes: 1_000_000_000)))
        #expect(queryHits("size:300mb", QuerySample(bytes: 300_000_000)))
        #expect(!queryHits("size:300mb", QuerySample(bytes: 299_999_999)))
        #expect(queryHits("size:1.5gb", QuerySample(bytes: 1_500_000_000)))
        #expect(!queryHits("size:1.5gb", QuerySample(bytes: 1_499_999_999)))
    }

    @Test func sizeRangesAndUnits() {
        #expect(queryHits("size:500mb..2gb", QuerySample(bytes: 500_000_000)))
        #expect(queryHits("size:500mb..2gb", QuerySample(bytes: 2_000_000_000)))
        #expect(!queryHits("size:500mb..2gb", QuerySample(bytes: 499_999_999)))
        #expect(!queryHits("size:500mb..2gb", QuerySample(bytes: 2_000_000_001)))
        #expect(queryHits("size:1..2kb", QuerySample(bytes: 1_500)), "low side takes the high unit")
        #expect(!queryHits("size:1..2kb", QuerySample(bytes: 2_001)))
        #expect(queryHits("size:>1k", QuerySample(bytes: 1_001)))
        #expect(!queryHits("size:>1KB", QuerySample(bytes: 1_000)))
        #expect(queryHits("size:>2M", QuerySample(bytes: 2_000_001)))
        #expect(queryHits("size:>1t", QuerySample(bytes: 1_000_000_000_001)))
        #expect(queryHits("size:>1b", QuerySample(bytes: 2)))
        #expect(!queryHits("size:>1b", QuerySample(bytes: 1)))
    }

    @Test func ageComparisons() {
        #expect(queryHits("age:>90d", QuerySample(modifiedDays: 100)))
        #expect(!queryHits("age:>90d", QuerySample(modifiedDays: 50)))
        #expect(!queryHits("age:>90d", QuerySample(modifiedDays: 90)))
        #expect(queryHits("age:<7d", QuerySample(modifiedDays: 3)))
        #expect(!queryHits("age:<7d", QuerySample(modifiedDays: 10)))
        #expect(queryHits("age:>=7d", QuerySample(modifiedDays: 7)))
        #expect(queryHits("age:>12w", QuerySample(modifiedDays: 85)))
        #expect(!queryHits("age:>12w", QuerySample(modifiedDays: 80)))
        #expect(queryHits("age:>3m", QuerySample(modifiedDays: 91)))
        #expect(!queryHits("age:>3m", QuerySample(modifiedDays: 89)))
        #expect(queryHits("age:>1y", QuerySample(modifiedDays: 366)))
        #expect(!queryHits("age:>1y", QuerySample(modifiedDays: 300)))
        #expect(queryHits("age:>2Y", QuerySample(modifiedDays: 731)))
        #expect(queryHits("age:90d", QuerySample(modifiedDays: 120)), "bare value means at least")
        #expect(!queryHits("age:90d", QuerySample(modifiedDays: 30)))
        #expect(queryHits("age:5..30d", QuerySample(modifiedDays: 10)))
        #expect(!queryHits("age:5..30d", QuerySample(modifiedDays: 31)))
        #expect(queryHits("-age:<7d", QuerySample(modifiedDays: 10)))
    }

    @Test func openedUsesAccessDate() {
        #expect(queryHits("opened:>180d", QuerySample(openedDays: 200)))
        #expect(!queryHits("opened:>180d", QuerySample(openedDays: 5)))
        #expect(queryHits("opened:<7d", QuerySample(openedDays: 5)))
        #expect(!queryHits("opened:<7d", QuerySample(openedDays: 200)))
        #expect(queryHits("opened:>180d", QuerySample(openedDays: nil)), "never opened matches opened:>N")
        #expect(!queryHits("opened:<7d", QuerySample(openedDays: nil)), "never opened does not match opened:<N")
        #expect(queryHits("-opened:<7d", QuerySample(openedDays: nil)))
    }

    @Test func malformedValuesAreIgnored() {
        let malformed = [
            "size:>abc", "size:>", "size:5xb", "size:", "size:>1..2gb", "size:3..1gb",
            "age:>abc", "age:", "age:5xd", "age:9..3d",
            "opened:>", "opened:<x",
            "ext:", "kind:",
        ]
        for text in malformed {
            #expect(FileQuery.parse(text).isEmpty, "\(text) is ignored")
            #expect(queryHits(text, QuerySample(name: "anything")), "\(text) matches everything")
        }
    }

    @Test func allTokensMustMatch() {
        let text = "ext:pdf size:<2kb age:>5d invoice -receipt"
        #expect(queryHits(text, QuerySample(bytes: 1_000)))
        #expect(!queryHits(text, QuerySample(bytes: 5_000)))
        #expect(!queryHits(text, QuerySample(name: "Invoice.dmg", bytes: 1_000)))
        #expect(!queryHits(text, QuerySample(name: "invoice receipt.pdf", bytes: 1_000)))
        #expect(!queryHits(text, QuerySample(bytes: 1_000, modifiedDays: 1)))
    }
}
