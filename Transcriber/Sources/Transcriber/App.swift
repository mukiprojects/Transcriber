import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor var delegate: AppDelegate
    @ObservedObject var model = Model.shared

    var body: some Scene {
        Window("Transcriber", id: "main") {
            ContentView().environmentObject(model).frame(minWidth: 560, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
    // Finder "Open With", or files dropped on the Dock icon
    func application(_: NSApplication, open urls: [URL]) { MainActor.assumeIsolated { Model.shared.add(urls) } }
}

// MARK: - Model

struct Item: Identifiable {
    enum Status: Equatable { case queued, running, done, failed(String) }
    let id = UUID()
    let url: URL
    var duration: Double = 0  // from AVFoundation up front, replaced by the script's exact value
    var status = Status.queued
    var secDone: Double = 0
    var words = 0
    var started: Date?
    var finished: Date?
    var txt: URL { url.deletingPathExtension().appendingPathExtension("txt") }
}

@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    @Published var items: [Item] = []
    @Published var batch: [UUID] = []  // items handed to the running process, in script index order
    @Published var batchStart: Date?
    @Published var loadingModel = false
    @Published var models: [String] = []  // ids from `transcribe.py --list`
    @Published var selectedModel = UserDefaults.standard.string(forKey: "model") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "model") }
    }
    private var process: Process?
    private let script = Bundle.main.path(forResource: "transcribe", ofType: "py")!
    private let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv"]
        .first(where: FileManager.default.isExecutableFile)
    private var stderr = ""

    var isRunning: Bool { process != nil }

    func add(_ urls: [URL]) {
        for url in urls where !url.hasDirectoryPath && !items.contains(where: { $0.url == url }) {
            let item = Item(url: url)
            items.append(item)
            Task {
                let secs = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                update(item.id) { if $0.duration == 0, secs.isFinite { $0.duration = secs } }
            }
        }
        startIfIdle()
    }

    /// Re-reads which models Handy has downloaded (cheap; called on launch and when the app is focused).
    func loadModels() {
        guard let uv else { return }
        let script = script
        DispatchQueue.global().async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: uv)
            p.arguments = ["run", "--quiet", script, "--list"]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let ids = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            onMain {
                self.models = ids
                if !ids.contains(self.selectedModel), let first = ids.first { self.selectedModel = first }
                self.startIfIdle()  // files dropped before the list arrived
            }
        }
    }

    func remove(_ id: UUID) { if !batch.contains(id) { items.removeAll { $0.id == id } } }
    func clearFinished() { items.removeAll { $0.status != .queued && $0.status != .running } }
    func cancel() { process?.terminate() }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    private func startIfIdle() {
        guard process == nil else { return }
        let queued = items.filter { $0.status == .queued }
        guard !queued.isEmpty, !selectedModel.isEmpty else { return }

        guard let uv else {
            queued.forEach { q in update(q.id) { $0.status = .failed("uv not found. Install it: brew install uv") } }
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--quiet", script, "--model", selectedModel] + queued.map(\.url.path)
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        p.qualityOfService = .utility  // keep the Mac responsive while transcribing

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            onMain { self.receive(chunk) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            onMain { self.stderr = String((self.stderr + s).suffix(4000)) }
        }
        p.terminationHandler = { _ in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            onMain { self.finishBatch() }
        }

        batch = queued.map(\.id)
        batchStart = .now
        loadingModel = true
        stderr = ""
        do { try p.run(); process = p } catch {
            queued.forEach { q in update(q.id) { $0.status = .failed(error.localizedDescription) } }
            batch = []
        }
    }

    private var outBuffer = ""
    private func receive(_ chunk: String) {
        outBuffer += chunk
        while let nl = outBuffer.firstIndex(of: "\n") {
            handle(String(outBuffer[..<nl]))
            outBuffer.removeSubrange(...nl)
        }
    }

    private func handle(_ line: String) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 2, let i = Int(f[1]), batch.indices.contains(i) else { return }
        let id = batch[i]
        switch f[0] {
        case "START":
            update(id) { $0.status = .running; $0.started = .now }
        case "PROGRESS" where f.count == 5:
            loadingModel = false
            update(id) {
                $0.secDone = Double(f[2]) ?? 0
                $0.duration = Double(f[3]) ?? $0.duration
                $0.words = Int(f[4]) ?? 0
            }
        case "DONE":
            update(id) { $0.status = .done; $0.finished = .now; $0.secDone = $0.duration }
        case "ERR":
            update(id) { $0.status = .failed(f.dropFirst(2).joined(separator: " ")); $0.finished = .now }
        default: break
        }
    }

    private func finishBatch() {
        let reason = stderr.split(separator: "\n").last.map(String.init) ?? "Stopped"
        for id in batch {
            update(id) {
                if $0.status == .queued || $0.status == .running { $0.status = .failed(reason); $0.finished = .now }
            }
        }
        process = nil
        batch = []
        batchStart = nil
        loadingModel = false
        startIfIdle()  // files dropped while we were busy
    }

    /// Overall progress for the running batch: (audio done, audio total).
    var batchProgress: (done: Double, total: Double) {
        let b = items.filter { batch.contains($0.id) }
        return (b.reduce(0) { $0 + ($1.status == .done ? $1.duration : $1.secDone) },
                b.reduce(0) { $0 + $1.duration })
    }
}

/// GCD main queue is FIFO (unlike separate Tasks), so output lines and termination arrive in order.
func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

// MARK: - Formatting

/// "handy-computer/canary-180m-flash-gguf/canary-180m-flash-Q8_0.gguf" -> "Canary 180M Flash"
/// "parakeet-tdt-0.6b-v3-int8" -> "Parakeet TDT 0.6B V3"
func modelName(_ id: String) -> String {
    let quant = ["int8", "q8_0", "q4_0", "q4_k_m", "q5_k_m", "q6_k", "f16", "bf16", "fp16"]
    return (id.split(separator: "/").last.map(String.init) ?? id)
        .replacingOccurrences(of: ".gguf", with: "")
        .split(separator: "-")
        .filter { !quant.contains($0.lowercased()) }
        .map { w in w.count <= 3 || w.first!.isNumber ? w.uppercased() : w.capitalized }
        .joined(separator: " ")
}

func clock(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "–" }
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

/// "elapsed 0:42 · ~1:10 left · 38× realtime"
func timing(done: Double, total: Double, since start: Date, now: Date) -> String {
    let elapsed = now.timeIntervalSince(start)
    guard done > 0, elapsed > 0 else { return "elapsed \(clock(elapsed))" }
    let left = elapsed / done * (total - done)
    return "elapsed \(clock(elapsed)) · ~\(clock(left)) left · \(Int(done / elapsed))× realtime"
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State var importing = false
    @State var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                dropHint
            } else {
                List(model.items) { ItemRow(item: $0) }
                if model.isRunning { BatchBar().padding() }
            }
        }
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 3).padding(6) }
        }
        .dropDestination(for: URL.self) { urls, _ in model.add(urls); return true } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.add(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.loadModels()
        }
        .toolbar {
            Picker("Model", selection: $model.selectedModel) {
                ForEach(model.models, id: \.self) { Text(modelName($0)).tag($0) }
            }
            .help("Models downloaded in Handy. Applies to the next files you add.")
            Button("Add Files…", systemImage: "plus") { importing = true }
            if model.isRunning {
                Button("Stop", systemImage: "stop.fill") { model.cancel() }
            }
            Button("Clear Finished", systemImage: "trash") { model.clearFinished() }
                .disabled(!model.items.contains { $0.status != .queued && $0.status != .running })
        }
    }

    var dropHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Drop audio files here").font(.title2)
            Text("mp3, m4a, wav… Transcripts are saved as .txt next to each file.").foregroundStyle(.secondary)
            Button("Choose Files…") { importing = true }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BatchBar: View {
    @EnvironmentObject var model: Model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (done, total) = model.batchProgress
            VStack(alignment: .leading, spacing: 4) {
                if model.loadingModel {
                    ProgressView().progressViewStyle(.linear)
                    Text("Loading model…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: min(done, total), total: max(total, 1))
                    HStack {
                        Text("All files: \(Int(done / max(total, 1) * 100))% · \(clock(done)) / \(clock(total)) of audio")
                        Spacer()
                        if let start = model.batchStart {
                            Text(timing(done: done, total: total, since: start, now: ctx.date))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: Model
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                detail.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if item.status == .done {
                Button("Open") { NSWorkspace.shared.open(item.txt) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.status == .done { NSWorkspace.shared.open(item.txt) } }
        .contextMenu {
            if item.status == .done {
                Button("Open Transcript") { NSWorkspace.shared.open(item.txt) }
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((try? String(contentsOf: item.txt, encoding: .utf8)) ?? "", forType: .string)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.status == .done ? item.txt : item.url])
            }
            Button("Remove") { model.remove(item.id) }.disabled(model.batch.contains(item.id))
        }
    }

    @ViewBuilder var icon: some View {
        switch item.status {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder var detail: some View {
        switch item.status {
        case .queued:
            Text(item.duration > 0 ? "Queued · \(clock(item.duration))" : "Queued")
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    if item.secDone == 0 {
                        Text(model.loadingModel ? "Loading model…" : "Transcribing…")
                    } else {
                        ProgressView(value: min(item.secDone, item.duration), total: max(item.duration, 1))
                        Text("\(Int(item.secDone / max(item.duration, 1) * 100))% · \(clock(item.secDone)) / \(clock(item.duration)) of audio · \(item.words.formatted()) words")
                    }
                    if let start = item.started {
                        Text(timing(done: item.secDone, total: item.duration, since: start, now: ctx.date))
                    }
                }
            }
        case .done:
            let took = item.finished.flatMap { f in item.started.map { f.timeIntervalSince($0) } } ?? 0
            Text("\(clock(item.duration)) of audio · \(item.words.formatted()) words · took \(clock(took))")
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).lineLimit(2)
        }
    }
}
