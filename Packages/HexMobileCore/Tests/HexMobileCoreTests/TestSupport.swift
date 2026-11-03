import Foundation
import Synchronization
import Testing

/// Loads a JSON fixture from the test bundle.
func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "Missing fixture \(name).json"
    )
    return try Data(contentsOf: url)
}

/// Encodes a JSON literal written in a test.
func json(_ string: String) -> Data {
    Data(string.utf8)
}

/// A manually advanced clock for retention tests.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    /// A Sendable closure suitable for `HistoryStore(now:)`.
    var closure: @Sendable () -> Date {
        { [self] in now }
    }
}

/// A fresh empty directory under the system temporary directory, removed by `cleanup()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HexMobileCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A fixed reference date: 2026-11-01T10:00:00Z.
let referenceDate = Date(timeIntervalSince1970: 1_793_527_200)

/// The first element of `stream`, or `nil` if none arrives within `timeout`.
func firstElement<Element: Sendable>(
    of stream: AsyncStream<Element>,
    timeout: Duration
) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
