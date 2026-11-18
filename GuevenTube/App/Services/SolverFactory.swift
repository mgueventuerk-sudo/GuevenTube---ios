import Foundation
import GuevenCore

/// Verdrahtet den Entschlüssler: JavaScriptCore + die beiden EJS-Skripte aus dem App-Bündel (bitgleich mit Android).
enum SolverFactory {
    enum Missing: Error { case resource(String) }

    static func make(playerScripts: PlayerScriptRepository, directory: URL) -> EJSChallengeSolver {
        EJSChallengeSolver(
            directory: directory,
            makeEngine: { try JavaScriptCoreEngine() },
            libSource: { try resource("yt.solver.lib.min") },
            coreSource: { try resource("yt.solver.core.min") },
            playerScript: { try await playerScripts.script($0) }
        )
    }

    private static func resource(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "solver")
            ?? Bundle.main.url(forResource: name, withExtension: "js") else { throw Missing.resource(name) }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
