import Foundation
import GuevenCore

/// Lädt die eingefrorenen Antworten (gzip) aus den Testressourcen; entpackt über `gzip -dc` (Linux und macOS).
enum Fixtures {
    static func json(_ name: String) throws -> JSON {
        let url = try XCTUnwrapURL(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gzip", "-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONParser.parse(data)
    }

    private static func XCTUnwrapURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json.gz", subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture fehlt: \(name)"])
        }
        return url
    }
}
