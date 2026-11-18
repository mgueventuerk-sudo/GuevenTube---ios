import SwiftUI
import AVFoundation
import GuevenCore

/// Fernbedienung für den Android-TV: Geräte suchen/koppeln, dann Wiedergabe steuern. Apple-only, ungetestet.
struct RemoteView: View {
    @ObservedObject private var link = LinkModel.shared
    @State private var scanning = false
    @State private var text = ""

    var body: some View {
        List {
            statusSection
            if link.isConnected { controlSection; queueSection; textSection }
            devicesSection
        }
        .navigationTitle("Fernseher")
        .task { link.startDiscovery() }
        .onDisappear { link.stopDiscovery() }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScannerView { code in
                    scanning = false
                    if let r = LinkPairUri.parse(code) { link.pair(with: r) }
                }
                .ignoresSafeArea()
                .navigationTitle("QR-Code scannen").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Abbrechen") { scanning = false } } }
            }
        }
    }

    // MARK: Abschnitte

    @ViewBuilder private var statusSection: some View {
        Section {
            switch link.connection {
            case .idle: Text("Nicht verbunden").foregroundStyle(.secondary)
            case .connecting(let n): HStack { ProgressView(); Text("Verbinde mit \(n) …") }
            case .awaitingApproval(let n, let code):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bitte am Fernseher bestätigen: \(n)")
                    Text(code).font(.system(size: 34, weight: .bold, design: .monospaced))
                    Text("Der Code muss auf beiden Geräten gleich sein.").font(.footnote).foregroundStyle(.secondary)
                }
            case .connected(_, let n):
                HStack { Label(n, systemImage: "tv"); Spacer(); Button("Trennen") { link.disconnect() } }
            case .failed(let m): Text(m).foregroundStyle(.red)
            }
        }
    }

    private var controlSection: some View {
        let s = link.tvState
        return Section("Wiedergabe") {
            if s.videoId == nil {
                Text("Auf dem Fernseher läuft nichts.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.headline).lineLimit(2)
                    if !s.author.isEmpty { Text(s.author).font(.subheadline).foregroundStyle(.secondary) }
                }
                if s.durationMs > 0 && !s.isLive {
                    SeekBar(positionMs: s.positionMs, durationMs: s.durationMs) { link.control(LinkMessage.actionSeekTo, value: $0) }
                    HStack { Text(Self.clock(s.positionMs)); Spacer(); Text(Self.clock(s.durationMs)) }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 28) {
                    Spacer()
                    Button { link.control(LinkMessage.actionSeekBy, value: -10_000) } label: { Image(systemName: "gobackward.10") }
                    Button { link.control(LinkMessage.actionToggle) } label: {
                        Image(systemName: s.isBuffering ? "hourglass" : (s.isPlaying ? "pause.circle.fill" : "play.circle.fill")).font(.system(size: 44))
                    }
                    Button { link.control(LinkMessage.actionSeekBy, value: 10_000) } label: { Image(systemName: "goforward.10") }
                    Button { link.control(LinkMessage.actionNext) } label: { Image(systemName: "forward.end.fill") }
                    Spacer()
                }
                .font(.title2).buttonStyle(.borderless)
                Button("Wiedergabe beenden", role: .destructive) { link.control(LinkMessage.actionStop) }
            }
        }
    }

    @ViewBuilder private var queueSection: some View {
        let q = link.tvState.queue
        if !q.isEmpty {
            Section("Warteschlange") {
                ForEach(Array(q.enumerated()), id: \.offset) { _, v in
                    VStack(alignment: .leading) {
                        Text(v.title).lineLimit(2)
                        if let c = v.channelName { Text(c).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("Warteschlange leeren", role: .destructive) { link.clearQueue() }
            }
        }
    }

    private var textSection: some View {
        Section("Text an den Fernseher") {
            TextField("Suchbegriff eingeben", text: $text)
                .submitLabel(.send)
                .onSubmit { link.sendText(text, submit: true); text = "" }
                .onChange(of: text) { _, new in link.sendText(new, submit: false) }
        }
    }

    @ViewBuilder private var devicesSection: some View {
        let nearby = link.discovered.filter { d in !link.paired.contains { $0.id == d.tvId } }
        Section("Gekoppelte Fernseher") {
            if link.paired.isEmpty { Text("Noch keiner gekoppelt.").foregroundStyle(.secondary) }
            ForEach(link.paired, id: \.id) { tv in
                Button { link.connect(tv) } label: {
                    HStack {
                        Text(tv.name)
                        Spacer()
                        if link.discovered.contains(where: { $0.tvId == tv.id }) { Image(systemName: "wifi").foregroundStyle(.green) }
                    }.contentShape(Rectangle())
                }
                .swipeActions { Button("Vergessen", role: .destructive) { link.forget(tv.id) } }
            }
        }
        Section {
            ForEach(nearby) { tv in Button { link.pair(with: tv) } label: { Label(tv.name, systemImage: "tv") } }
            Button { scanning = true } label: { Label("QR-Code vom Fernseher scannen", systemImage: "qrcode.viewfinder") }
        } header: { Text("Neu koppeln") } footer: {
            Text("Am Fernseher GuevenTube öffnen. Beide Geräte müssen im selben WLAN sein; iOS fragt einmal nach dem Zugriff aufs lokale Netzwerk.")
        }
    }

    private static func clock(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Position des Fernsehers; ein Zug sendet beim Loslassen genau einen `seekTo`.
private struct SeekBar: View {
    let positionMs: Int64, durationMs: Int64
    let onSeek: (Int64) -> Void
    @State private var dragging: Double?

    var body: some View {
        Slider(value: Binding(get: { dragging ?? Double(positionMs) }, set: { dragging = $0 }),
               in: 0...Double(max(durationMs, 1))) { editing in
            if !editing, let v = dragging { onSeek(Int64(v)); dragging = nil }
        }
    }
}

/// Kamera-Scanner für den Kopplungs-QR-Code. Liefert den ersten gelesenen Text einmal.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController(); c.onCode = onCode; return c
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { if ok { self?.setUp() } else { self?.showDenied() } }
            }
        }

        private func setUp() {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return showDenied() }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return showDenied() }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        private func showDenied() {
            let l = UILabel(); l.text = "Kein Kamerazugriff. In den Einstellungen erlauben."; l.textColor = .white
            l.numberOfLines = 0; l.textAlignment = .center; l.frame = view.bounds.insetBy(dx: 24, dy: 0)
            view.addSubview(l)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.bounds }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(s)
        }
    }
}
