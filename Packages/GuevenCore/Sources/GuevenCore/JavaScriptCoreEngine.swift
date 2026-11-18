import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore

/// `JSEngine` auf Apple-Systemen: ein eigener `JSContext` ohne DOM, Netzwerk oder Dateizugriff (nur ECMAScript,
/// keine Brücke zu Swift-Objekten). **Ungetestet bis zum ersten Mac-Lauf** – hier unter Linux nicht übersetzbar.
///
/// - Jede Ausführung läuft auf einem eigenen Thread mit 64 MB Stack: Die Analyse des Player-Skripts
///   (meriyah/astring) rekursiert tief, GCD-Threads haben nur 512 KB.
/// - JavaScriptCore bietet in der öffentlichen API keine Unterbrechung. Bei Zeitüberschreitung wird die Engine
///   verworfen; ein hängender Thread läuft im Hintergrund aus (Speicher kommt mit dem Kontext frei).
/// - JIT gibt es in einem `JSContext` für normale Apps nicht (Interpreter): die erste Analyse eines neuen
///   Players kann spürbar dauern; das Ergebnis liegt danach auf der Platte (`EJSChallengeSolver`).
public final class JavaScriptCoreEngine: JSEngine, @unchecked Sendable {
    static let stackBytes = 64 * 1024 * 1024

    private let lock = NSLock()
    private var context: JSContext?
    private var dead = false

    public init() throws {
        guard let context = JSContext() else { throw JSEngineError.failed("JSContext nicht verfügbar") }
        self.context = context
    }

    public func setGlobal(_ name: String, string: String) async throws {
        _ = try await run(timeoutMs: 30_000) { context in
            context.setObject(string as NSString, forKeyedSubscript: name as NSString)
            return ""
        }
    }

    public func evaluate(_ code: String, timeoutMs: Int64) async throws -> String {
        try await run(timeoutMs: timeoutMs) { context in
            var thrown: String?
            context.exceptionHandler = { _, exception in thrown = exception?.toString() ?? "unbekannter Fehler" }
            let value = context.evaluateScript(code)
            context.exceptionHandler = nil
            if let thrown { throw JSEngineError.failed(String(thrown.prefix(160))) }
            guard let value, !value.isUndefined, !value.isNull else { return "" }
            return value.toString() ?? ""
        }
    }

    public func close() {
        lock.lock(); dead = true; context = nil; lock.unlock()
    }

    private func currentContext() throws -> JSContext {
        lock.lock(); defer { lock.unlock() }
        guard !dead, let context else { throw JSEngineError.failed("Engine geschlossen") }
        return context
    }

    private func run(timeoutMs: Int64, _ work: @escaping @Sendable (JSContext) throws -> String) async throws -> String {
        let context = try currentContext()
        let gate = OnceGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let thread = Thread {
                let result: Result<String, Error>
                do { result = .success(try work(context)) } catch { result = .failure(error) }
                if gate.claim() { continuation.resume(with: result) }
            }
            thread.stackSize = Self.stackBytes
            thread.qualityOfService = .userInitiated
            thread.name = "GuevenTube.JSEngine"
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) { [weak self] in
                if gate.claim() {
                    self?.close()
                    continuation.resume(throwing: JSEngineError.timeout)
                }
            }
        }
    }
}

/// Erlaubt genau einer Seite (Ergebnis oder Zeitablauf) die Fortsetzung.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
}
#endif
