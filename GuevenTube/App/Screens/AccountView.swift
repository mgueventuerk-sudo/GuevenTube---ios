import SwiftUI
import GuevenCore

struct AccountView: View {
    @StateObject private var model = AccountModel()
    @AppStorage(DeviceLock.defaultsKey) private var lockEnabled = false
    @State private var unlocked = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if lockEnabled && !unlocked {
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Konto und Einstellungen sind gesperrt")
                Button("Entsperren") { Task { unlocked = await DeviceLock.confirm("Konto und Einstellungen öffnen") } }
                    .buttonStyle(.borderedProminent)
            }
            .task { if !unlocked { unlocked = await DeviceLock.confirm("Konto und Einstellungen öffnen") } }
        } else {
            content.onChange(of: scenePhase) { _, p in if p == .background { unlocked = false } }
        }
    }

    private var content: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Einstellungen") { SettingsView() }
                    NavigationLink("Downloads") { DownloadsView() }
                    NavigationLink("Fernseher (Fernbedienung)") { RemoteView() }
                }
                Section("Anmeldung") { signInSection }
                Section("Konten") {
                    Button { Task { await model.select(nil) } } label: { check("Gast (ohne Konto)", model.activeId == nil) }
                    ForEach(model.accounts, id: \.accountId) { a in
                        Button { Task { await model.select(a.accountId) } } label: {
                            check(a.displayName + (a.needsReauth ? " – neu anmelden" : ""), model.activeId == a.accountId)
                        }
                        .swipeActions { Button("Entfernen", role: .destructive) { Task { await model.remove(a.accountId) } } }
                    }
                }
            }
            .navigationTitle("Konto")
            .task { await model.refresh() }
        }
    }

    private func check(_ text: String, _ on: Bool) -> some View {
        HStack { Text(text); Spacer(); if on { Image(systemName: "checkmark") } }.contentShape(Rectangle())
    }

    @ViewBuilder private var signInSection: some View {
        switch model.state {
        case .idle:
            Button("Mit Google-Konto anmelden") { model.startSignIn() }
        case .requestingCode, .completing:
            HStack { ProgressView(); Text("Bitte warten …").padding(.leading, 8) }
        case .awaitingUser(let code, let url, let qr, _):
            VStack(alignment: .leading, spacing: 8) {
                Text("Öffne die Seite und gib diesen Code ein:")
                Text(code).font(.system(.largeTitle, design: .monospaced).bold()).textSelection(.enabled)
                if let u = URL(string: qr) { Link(url, destination: u) }
                Button("Abbrechen", role: .cancel) { model.cancelSignIn() }
            }
        case .success(_, let name):
            VStack(alignment: .leading) {
                Text("Angemeldet als \(name)")
                Button("OK") { model.cancelSignIn() }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.red)
                Button("Erneut versuchen") { model.startSignIn() }
            }
        }
    }
}
