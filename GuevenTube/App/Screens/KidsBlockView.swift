import SwiftUI
import GuevenCore

/// Vollbild-Sperre des Kindermodus; mit der Profil-PIN für 30 Minuten aufhebbar.
struct KidsBlockView: View {
    @EnvironmentObject private var kids: KidsModel
    let reason: String
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 56))
            Text(reason).multilineTextAlignment(.center).font(.headline)
            SecureField("PIN", text: $pin).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Button("Entsperren") {
                Task { error = await kids.unlock(pin: pin); pin = "" }
            }.buttonStyle(.borderedProminent).disabled(pin.count < 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
