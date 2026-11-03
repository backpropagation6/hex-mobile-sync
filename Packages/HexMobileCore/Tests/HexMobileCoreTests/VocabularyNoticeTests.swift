import Testing
@testable import HexMobileCore

@Suite("Vocabulary notice")
struct VocabularyNoticeTests {
    @Test("no terms and no folder: pick the folder")
    func noFolder() {
        #expect(VocabularyNotice.make(termCount: 0, folderPicked: false) == .noFolder)
    }

    @Test("a folder but no terms: nothing to pass yet")
    func noTerms() {
        #expect(VocabularyNotice.make(termCount: 0, folderPicked: true) == .noTerms)
    }

    @Test("any term, with or without a folder, says nothing")
    func withTerms() {
        #expect(VocabularyNotice.make(termCount: 1, folderPicked: false) == nil)
        #expect(VocabularyNotice.make(termCount: 63, folderPicked: true) == nil)
    }

    @Test("a negative count is treated as none")
    func negative() {
        #expect(VocabularyNotice.make(termCount: -1, folderPicked: false) == .noFolder)
    }
}
