import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Narrator Studio", isDirectory: true)
let lilac = Color(red: 0.75, green: 0.70, blue: 1.0)
let mint = Color(red: 0.55, green: 0.87, blue: 0.77)
let panel = Color(red: 0.13, green: 0.14, blue: 0.17)
let hairline = Color.white.opacity(0.10)

struct Reference: Codable { var file: String; var text: String }
struct Tuning: Codable { var order: [Int] }
struct Profile: Codable, Identifiable {
    var id: String; var name: String; var original: String; var refs: [Reference]
    var language: String; var created: Double; var tuning: Tuning?
    var directory: URL { library.appendingPathComponent("Profiles").appendingPathComponent(id) }
    var originalURL: URL { directory.appendingPathComponent(original) }
    var reference: URL? {
        let index = tuning?.order.first ?? 0
        return refs.indices.contains(index) ? directory.appendingPathComponent(refs[index].file) : nil
    }
}
struct Take: Codable, Identifiable {
    var id: String; var name: String; var file: String; var kind: String; var created: Double
    var score: Double?; var scoreScope: String?; var transcript: String?; var errorRate: Double?
    var profileName: String?
    var profile: String?; var text: String?; var language: String?
    var speed: Double?; var pause: Double?; var attempts: Int?; var adaptive: Bool?
    var renderSeconds: Double?; var reused: Int?; var reuseSignature: String?
    var url: URL { library.appendingPathComponent("Takes").appendingPathComponent(id).appendingPathComponent(file) }
}

func readLibrary<T: Decodable>(_ directory: String, _ name: String, _: T.Type) -> [T] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: library.appendingPathComponent(directory),
        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    return urls.compactMap { url in
        guard let data = try? Data(contentsOf: url.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor final class Transport: ObservableObject {
    @Published var current: URL?
    @Published var playing = false
    @Published var time = 0.0
    @Published var duration = 0.0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    func toggle(_ url: URL) throws {
        if current == url, playing {
            player?.pause(); playing = false; return
        }
        if current != url || player == nil {
            let next = try AVAudioPlayer(contentsOf: url)
            stop()
            player = next; current = url; duration = next.duration
        }
        guard let player else { return }
        if player.currentTime >= duration - 0.04 { player.currentTime = 0 }
        playing = player.play()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, let player = self.player else { t.invalidate(); return }
                self.time = player.currentTime
                if !player.isPlaying {
                    self.playing = false
                    t.invalidate()
                }
            }
        }
    }
    func seek(_ value: Double) { player?.currentTime = value; time = value }
    func stop() { timer?.invalidate(); player?.stop(); player = nil; playing = false; current = nil; time = 0 }
}

enum SectionName: String, CaseIterable { case voiceover = "Voiceover", cleanup = "Cleanup", takes = "Takes" }

@MainActor final class Studio: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var takes: [Take] = []
    @Published var selected = UserDefaults.standard.string(forKey: "voice") ?? "" {
        didSet { UserDefaults.standard.set(selected, forKey: "voice") }
    }
    @Published var section = SectionName.voiceover
    @Published var script = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet { UserDefaults.standard.set(script, forKey: "draft") }
    }
    @Published var status = ""
    @Published var busy = false
    @Published var errorText: String?
    @Published var latestID = ""
    @Published var cleanSource: URL?
    @Published var notice = ""
    @Published var language = "Auto"
    @Published var speed = 1.0
    @Published var count = 0
    @Published var pause = 0.18
    @Published var editTake: Take?
    @Published var takeSearch = ""
    @Published var cleanup = "Balanced"
    @Published var level = true
    @Published var tidySpeech = true
    @Published var cleanupScript = ""
    let audio = Transport()
    private var task: Process?
    private var poll: Timer?
    private var cancelled = false
    private var cursor: UInt64 = 0
    private var carry = Data()
    private var workerError: String?
    var profile: Profile? { profiles.first { $0.id == selected } }
    var latest: Take? { takes.first { $0.id == latestID } }
    init() {
        do { try installIncludedVoice() }
        catch { errorText = "Could not load the included narrator. " + error.localizedDescription }
        reload()
        if profile == nil { selected = profiles.first?.id ?? "" }
        latestID = takes.first?.id ?? ""
    }
    private func installIncludedVoice() throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Included Voice"),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("profile.json").path) else { return }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: source.appendingPathComponent("profile.json")))
        guard UUID(uuidString: profile.id) != nil else { return }
        let fm = FileManager.default
        let directory = library.appendingPathComponent("Profiles")
        let destination = directory.appendingPathComponent(profile.id)
        if fm.fileExists(atPath: destination.path) { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".preset-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        do { try fm.moveItem(at: staging, to: destination) }
        catch { if !fm.fileExists(atPath: destination.appendingPathComponent("profile.json").path) { throw error } }
    }
    func reload() {
        profiles = readLibrary("Profiles", "profile.json", Profile.self).sorted { $0.created > $1.created }
        takes = readLibrary("Takes", "take.json", Take.self).sorted { $0.created > $1.created }
    }
    func choose(cleanOnly: Bool) {
        guard !busy else { return }
        let open = NSOpenPanel()
        open.title = cleanOnly ? "Choose audio to clean" : "Import a voice recording"
        open.allowedContentTypes = [.audio, .movie, .mpeg4Movie]
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        receive(url, cleanOnly: cleanOnly)
    }
    func receive(_ url: URL, cleanOnly: Bool) {
        guard !busy else { return }
        if cleanOnly { cleanSource = url; cleanupScript = ""; notice = "" }
        else {
            start(["action":"import", "source":url.path, "name":url.deletingPathExtension().lastPathComponent])
        }
    }
    func generate(preview: Bool = false) {
        guard let p = profile else { return }
        var request: [String: Any] = ["action":"generate", "profile":p.id, "text":script,
            "attempts":count == 0 ? 6 : count, "adaptive":count == 0, "preview":preview,
            "language":language.lowercased(), "speed":speed, "pause":pause]
        if let take = editTake, !preview { request["editTake"] = take.id }
        start(request)
    }
    func edit(_ take: Take) {
        guard let text = take.text, let id = take.profile, profiles.contains(where: { $0.id == id }) else { return }
        selected = id; script = text; editTake = take
        language = (take.language ?? "auto").capitalized
        speed = take.speed ?? 1; pause = take.pause ?? 0.18
        count = take.adaptive == true ? 0 : (take.attempts ?? 6)
        section = .voiceover; notice = ""
    }
    func clean() {
        guard let source = cleanSource ?? profile?.originalURL else { return }
        start(["action":"clean","source":source.path,"style":cleanup,"normalize":level,"tidy":tidySpeech,"script":cleanupScript])
    }
    func export(_ take: Take, as ext: String) {
        let save = NSSavePanel()
        save.allowedContentTypes = [UTType(filenameExtension: ext) ?? (ext == "srt" ? .plainText : .audio)]
        let normal = take.name.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(separator: " ")
        save.nameFieldStringValue = String(normal.prefix(50)) + "." + ext
        if save.runModal() == .OK, let url = save.url {
            start(["action":"export","source":take.url.path,"destination":url.path, "language":take.language ?? "auto"])
        }
    }
    func play(_ url: URL) {
        do { try audio.toggle(url) } catch { errorText = error.localizedDescription }
    }
    func cancel() {
        guard let task, task.isRunning else { return }
        cancelled = true; status = "Cancelling…"; task.terminate()
    }
    private func consume(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: cursor)
            let bytes = try fh.readToEnd() ?? Data()
            cursor += UInt64(bytes.count)
            carry.append(bytes)
            while let newline = carry.firstIndex(of: 10) {
                let line = String(decoding: carry[..<newline], as: UTF8.self)
                carry.removeSubrange(...newline)
                guard line.hasPrefix("STUDIO "),
                      let data = String(line.dropFirst(7)).data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] else { continue }
                if let message = event["message"] as? String, !cancelled { status = message }
                if event["error"] as? Bool == true { workerError = status }
                if let id = event["profile"] as? String { selected = id }
                if let id = event["take"] as? String { latestID = id }
            }
        } catch { return }
    }
    func start(_ request: [String:Any]) {
        guard !busy else { return }
        let fm = FileManager.default
        let job = fm.temporaryDirectory.appendingPathComponent("narrator-" + UUID().uuidString)
        let log = job.appendingPathComponent("render.log")
        do {
            try fm.createDirectory(at: job, withIntermediateDirectories: true)
            let input = job.appendingPathComponent("request.json")
            try JSONSerialization.data(withJSONObject: request).write(to: input)
            fm.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            let res = Bundle.main.resourceURL!
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [res.appendingPathComponent("worker.sh").path, input.path]
            process.standardOutput = output; process.standardError = output
            cancelled = false; workerError = nil; cursor = 0; carry = Data()
            audio.stop(); status = "Preparing the local engine…"; notice = ""; busy = true
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    guard let self else { return }
                    try? output.close()
                    self.poll?.invalidate(); self.consume(log)
                    if self.cancelled { self.notice = "Cancelled" }
                    else if finished.terminationStatus != 0 {
                        let debug = library.appendingPathComponent("Last error.log")
                        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                        if let bytes = try? Data(contentsOf: log) { try? bytes.write(to: debug, options: .atomic) }
                        self.errorText = self.workerError ?? "The audio engine stopped. Details are in " + debug.path
                    } else { self.notice = self.status }
                    self.busy = false; self.task = nil; self.reload()
                    try? FileManager.default.removeItem(at: job)
                }
            }
            try process.run()
            task = process
            poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.consume(log) }
            }
        } catch {
            busy = false; errorText = error.localizedDescription; try? fm.removeItem(at: job)
        }
    }
}
