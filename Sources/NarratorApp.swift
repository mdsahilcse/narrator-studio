import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@main struct NarratorApp: App {
    @StateObject private var studio = Studio()
    @NSApplicationDelegateAdaptor(StudioDelegate.self) var delegate
    var body: some Scene {
        Window("Narrator Studio", id: "studio") {
            Workspace(studio: studio)
                .frame(minWidth: 850, minHeight: 645)
                .preferredColorScheme(.dark)
                .onAppear { delegate.studio = studio; NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1050, height: 750)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Voice…") { studio.choose(cleanOnly: false) }
                    .keyboardShortcut("i").disabled(studio.busy)
                Button("Generate Voiceover") { studio.generate() }
                    .keyboardShortcut(.return).disabled(studio.busy || studio.profile == nil || studio.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

@MainActor class StudioDelegate: NSObject, NSApplicationDelegate {
    weak var studio: Studio?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { studio?.cancel() }
}

struct SoundMark: View {
    var body: some View {
        HStack(spacing: 2.7) {
            ForEach(Array([10,19,13,25,17,9].enumerated()), id: \.offset) { _,h in
                Capsule().fill(Color(red:0.14,green:0.12,blue:0.23)).frame(width:3,height:CGFloat(h))
            }
        }.frame(width:43,height:43)
            .background(LinearGradient(colors:[lilac, Color(red:0.59,green:0.53,blue:0.95)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:12))
    }
}

final class LocalValue<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct Workspace: View {
    @ObservedObject var studio: Studio
    @StateObject private var dragging = LocalValue(false)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:10) {
                    SoundMark()
                    VStack(alignment:.leading,spacing:0) {
                        Text("Narrator").font(.system(size:20,weight:.semibold))
                        Text("Studio").font(.system(size:17,weight:.regular)).foregroundStyle(.secondary)
                    }
                }.padding(.top,44).padding(.bottom,30)
                ForEach(SectionName.allCases,id:\.self) { s in
                    let icon = s == .voiceover ? "waveform" : s == .cleanup ? "slider.horizontal.3" : "rectangle.stack"
                    Button {
                        studio.section = s; studio.notice = ""
                    } label: {
                        HStack(spacing:12) {
                            Image(systemName:icon).frame(width:18)
                            Text(s.rawValue).font(.system(size:14,weight:.medium))
                            Spacer()
                            if s == .takes { Text("\(studio.takes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }.padding(.horizontal,11).frame(height:38)
                            .background(studio.section == s ? lilac.opacity(0.14) : .clear,in:RoundedRectangle(cornerRadius:8))
                            .foregroundStyle(studio.section == s ? lilac : Color.white.opacity(0.73))
                    }.buttonStyle(.plain).padding(.bottom,3)
                }
                Divider().padding(.vertical,21)
                HStack {
                    Text("Voice library").font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { studio.choose(cleanOnly:false) } label: { Image(systemName:"plus") }
                        .buttonStyle(.plain).disabled(studio.busy).help("Import voice")
                        .accessibilityLabel("Import voice")
                }.padding(.horizontal,8).padding(.bottom,8)
                ScrollView {
                    VStack(spacing:3) {
                        ForEach(studio.profiles) { p in
                            Button { studio.selected = p.id } label: {
                                HStack(spacing:9) {
                                    Image(systemName:studio.selected == p.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(studio.selected == p.id ? mint : Color.secondary)
                                    Text(p.name).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                }.font(.system(size:13)).padding(.horizontal,8).padding(.vertical,8).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(studio.busy)
                        }
                        if studio.profiles.isEmpty {
                            Text("Import a recording to add your first voice.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth:.infinity,alignment:.leading).padding(8)
                        }
                    }
                }
                Button { studio.choose(cleanOnly:false) } label: {
                    Label("Import voice",systemImage:"square.and.arrow.down")
                        .frame(maxWidth:.infinity).frame(height:34)
                        .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(hairline))
                }.buttonStyle(.plain).disabled(studio.busy)
            }
            .padding(.horizontal,15).padding(.bottom,21).frame(width:193)
            .background(Color(red:0.105,green:0.111,blue:0.135))
            Rectangle().fill(hairline).frame(width:1)
            VStack(alignment:.leading,spacing:0) {
                ScrollView {
                    VStack(alignment:.leading,spacing:17) {
                        HStack {
                            Text(studio.section.rawValue).font(.system(size:32,weight:.semibold)).tracking(-1)
                            Spacer()
                            HStack(spacing:6) {
                                Circle().fill(mint).frame(width:6,height:6)
                                Text("On-device").font(.system(size:12,weight:.medium)).foregroundStyle(.secondary)
                            }
                        }.padding(.top,36).padding(.bottom,3)
                        switch studio.section {
                        case .voiceover: Voiceover(studio:studio)
                        case .cleanup: Cleanup(studio:studio)
                        case .takes: TakeList(studio:studio)
                        }
                    }.padding(.horizontal,30).padding(.bottom,22)
                }
                if studio.busy || !studio.notice.isEmpty {
                    Divider()
                    HStack(spacing:9) {
                        if studio.busy { ProgressView().controlSize(.small) }
                        else { Image(systemName:"checkmark.circle").foregroundStyle(mint) }
                        Text(studio.busy ? studio.status : studio.notice).font(.callout)
                        Spacer()
                        if studio.busy { Button("Cancel") { studio.cancel() } }
                    }.padding(.horizontal,25).padding(.vertical,11)
                }
            }.background(Color(red:0.081,green:0.085,blue:0.105))
        }
        .overlay { if dragging.value { RoundedRectangle(cornerRadius:12).strokeBorder(lilac,style:StrokeStyle(lineWidth:3,dash:[7])).allowsHitTesting(false) } }
        .onDrop(of:[UTType.fileURL.identifier],isTargeted:$dragging.value) { providers in
            guard !studio.busy, let first = providers.first else { return false }
            let cleanOnly = studio.section == .cleanup
            _ = first.loadObject(ofClass:URL.self) { url,_ in
                if let url { Task { @MainActor in studio.receive(url, cleanOnly:cleanOnly) } }
            }
            return true
        }
        .alert("Audio engine", isPresented: Binding(get:{studio.errorText != nil},set:{ if !$0 { studio.errorText = nil } })) {
            Button("OK") { studio.errorText = nil }
        } message: { Text(studio.errorText ?? "") }
    }
}

struct Waveform: View {
    let url: URL?
    @StateObject private var waveform = LocalValue<[CGFloat]>([])
    var body: some View {
        Canvas { context,size in
            let bins = waveform.value
            guard !bins.isEmpty else { return }
            let space = size.width / CGFloat(bins.count)
            for (i,bin) in bins.enumerated() {
                let h = max(2, size.height * bin)
                let rect = CGRect(x:CGFloat(i)*space, y:(size.height-h)/2, width:max(1,space*0.55), height:h)
                context.fill(Path(roundedRect:rect,cornerRadius:1.3),with:.color(lilac.opacity(0.78)))
            }
        }.accessibilityHidden(true)
        .task(id:url) {
            guard let url else { waveform.value = []; return }
            let values = await Task.detached {
                guard let file = try? AVAudioFile(forReading:url),
                      let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(min(file.length, 400000))),
                      (try? file.read(into:buffer)) != nil,
                      let floats = buffer.floatChannelData?.pointee else { return [CGFloat]() }
                let n = Int(buffer.frameLength), count = 96
                guard n >= count else { return [] }
                let rms = (0..<count).map { i -> CGFloat in
                    var sum: Float = 0
                    let start = i*n/count, end = (i+1)*n/count
                    for j in stride(from:start,to:end,by:4) { sum += floats[j]*floats[j] }
                    return CGFloat(sqrt(sum / Float(max(1,(end-start)/4))))
                }
                let peak = max(rms.max() ?? 1, 0.001)
                return rms.map { min(1, $0 / peak) }
            }.value
            if !Task.isCancelled { waveform.value = values }
        }
    }
}

struct AudioButton: View {
    @ObservedObject var transport: Transport
    var url: URL
    var action: ()->Void
    var body: some View {
        let playing = transport.current == url && transport.playing
        Button(action:action) {
            Image(systemName:playing ? "pause.fill" : "play.fill")
                .font(.system(size:12,weight:.semibold)).frame(width:31,height:31)
                .background(.white.opacity(0.10),in:Circle())
        }.buttonStyle(.plain).help(playing ? "Pause audio" : "Play audio")
        .accessibilityLabel(playing ? "Pause audio" : "Play audio")
    }
}

struct ReferenceCard: View {
    @ObservedObject var studio: Studio
    var body: some View {
        HStack(spacing:14) {
            VStack(alignment:.leading,spacing:6) {
                Text("Reference voice").font(.caption).foregroundStyle(lilac)
                Text(studio.profile?.name ?? "Add a voice").font(.system(size:19,weight:.semibold)).lineLimit(2)
                Text(studio.profile == nil ? "Drop an audio file here to begin." : "Select a voice from your library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:10)
            if let url = studio.profile?.reference {
                Waveform(url:url).frame(maxWidth:235).frame(height:48)
                AudioButton(transport:studio.audio,url:url) { studio.play(url) }
            } else {
                Button("Choose audio…") { studio.choose(cleanOnly:false) }.disabled(studio.busy)
            }
        }.padding(17).frame(minHeight:90)
        .background(LinearGradient(colors:[Color(red:0.19,green:0.17,blue:0.27),Color(red:0.14,green:0.14,blue:0.19)],startPoint:.leading,endPoint:.trailing),in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(lilac.opacity(0.18)))
    }
}

struct Voiceover: View {
    @ObservedObject var studio: Studio
    var body: some View {
        ReferenceCard(studio:studio)
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Script").font(.headline)
                Spacer()
                Text("\(studio.script.split(whereSeparator:{$0.isWhitespace}).count) words").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment:.topLeading) {
                if studio.script.isEmpty {
                    Text("Write or paste the words you want your narrator to say…")
                        .foregroundStyle(.secondary).padding(.leading,5).padding(.top,2)
                }
                TextEditor(text:$studio.script).scrollContentBackground(.hidden)
                    .font(.system(size:16)).lineSpacing(3).accessibilityLabel("Narration script")
            }.frame(minHeight:110,idealHeight:145)
            Divider()
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:5) {
                    Text("Language").font(.caption).foregroundStyle(.secondary)
                    Picker("Language",selection:$studio.language) {
                        ForEach(["Auto","English","Chinese","French","German","Italian","Japanese","Korean","Portuguese","Russian","Spanish"],id:\.self) {Text($0)}
                    }.labelsHidden().frame(width:108)
                }
                VStack(alignment:.leading,spacing:5) {
                    Text("Delivery speed").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing:6) {
                        Slider(value:$studio.speed,in:0.75...1.4,step:0.05).frame(minWidth:65,maxWidth:110)
                            .accessibilityLabel("Delivery speed")
                        Text(String(format:"%.2f×",studio.speed)).font(.caption.monospacedDigit())
                    }.frame(height:20)
                }
                Spacer(minLength:0)
                VStack(alignment:.leading,spacing:5) {
                    Text("Voice matching").font(.caption).foregroundStyle(.secondary)
                    Picker("Voice matching",selection:$studio.count) {
                        Text("Smart match").tag(0); Text("Single take").tag(1); Text("Best of 3").tag(3); Text("Best of 6").tag(6); Text("Up to 15 takes").tag(15)
                    }.labelsHidden().frame(width:128)
                }
            }
            HStack(spacing:8) {
                Text("Passage pause").font(.caption).foregroundStyle(.secondary)
                Picker("Passage pause", selection:$studio.pause) {
                    Text("None").tag(0.0); Text("Short · 0.18 s").tag(0.18)
                    Text("Medium · 0.45 s").tag(0.45); Text("Long · 0.8 s").tag(0.8)
                }.labelsHidden().fixedSize()
                Spacer()
            }
            if let edit = studio.editTake {
                HStack {
                    Text(edit.reuseSignature == nil ? "Editing a copy of this take" : "Unchanged passages can reuse their saved audio.")
                        .font(.caption).foregroundStyle(mint)
                    Spacer()
                    Button("Start fresh") { studio.editTake = nil }.buttonStyle(.link).font(.caption)
                }
            }
        }.padding(17).card()
        HStack {
            Button { studio.generate(preview:true) } label: {
                Label("Preview opening",systemImage:"play.circle")
            }.disabled(studio.busy || studio.profile == nil || studio.script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            .help("Render the opening sentence in one take")
            Spacer()
            Button { studio.generate() } label: { Label("Generate voiceover",systemImage:"waveform.badge.plus") }
                .buttonStyle(ActionStyle()).disabled(studio.busy || studio.profile == nil || studio.script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        }
        if let latest = studio.latest, latest.kind == "generate" { TakeCard(studio:studio,take:latest) }
    }
}

struct Cleanup: View {
    @ObservedObject var studio: Studio
    var source: URL? { studio.cleanSource ?? studio.profile?.originalURL }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Source recording").font(.headline)
            HStack(spacing:12) {
                if let url = source {
                    AudioButton(transport:studio.audio,url:url) { studio.play(url) }
                    Text(url.lastPathComponent).lineLimit(2)
                } else { Text("Drop audio here or choose a file.").foregroundStyle(.secondary) }
                Spacer()
                Button("Choose file…") { studio.choose(cleanOnly:true) }
            }
            Divider()
            Text("Noise reduction").font(.headline)
            Picker("Noise reduction",selection:$studio.cleanup) {
                ForEach(["Gentle","Balanced","Strong"],id:\.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Toggle("Shorten long pauses and remove detected fillers", isOn:$studio.tidySpeech)
            if studio.tidySpeech {
                TextField("Optional original script for detecting unscripted sounds",text:$studio.cleanupScript)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Level loudness for narration (−16 LUFS)",isOn:$studio.level)
            Text("Reduces steady background noise and low-frequency rumble.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).card()
        HStack { Spacer()
            Button { studio.clean() } label: { Label("Clean recording",systemImage:"slider.horizontal.3") }
                .buttonStyle(ActionStyle()).disabled(studio.busy || source == nil)
        }
        if let latest = studio.latest, latest.kind == "clean" { TakeCard(studio:studio,take:latest) }
    }
}

struct TakeList: View {
    @ObservedObject var studio: Studio
    var body: some View {
        if studio.takes.isEmpty {
            Text("Your generated voiceovers and cleaned recordings will appear here.")
                .foregroundStyle(.secondary).padding(18).frame(maxWidth:.infinity,alignment:.leading).card()
        } else {
            TextField("Search takes by script or voice",text:$studio.takeSearch)
                .textFieldStyle(.roundedBorder)
            let query = studio.takeSearch.trimmingCharacters(in:.whitespacesAndNewlines)
            let matches = studio.takes.filter { take in
                query.isEmpty || [take.name, take.text, take.profileName, take.transcript].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            if matches.isEmpty { Text("No matching takes").foregroundStyle(.secondary) }
            ForEach(matches) { take in TakeCard(studio:studio,take:take) }
        }
    }
}

struct TakeCard: View {
    @ObservedObject var studio: Studio
    let take: Take
    @StateObject private var details = LocalValue(false)
    var body: some View {
        VStack(alignment:.leading,spacing:11) {
            HStack(spacing:11) {
                AudioButton(transport:studio.audio,url:take.url) { studio.play(take.url) }
                VStack(alignment:.leading,spacing:4) {
                    Text(take.name).font(.system(size:14,weight:.semibold)).lineLimit(2)
                    Text(take.profileName ?? "Cleaned recording").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if take.kind == "generate", take.text != nil {
                    Button("Edit a copy") { studio.edit(take) }.disabled(studio.busy)
                }
                Menu("Export") {
                    ForEach(["wav","mp3","m4a"],id:\.self) { ext in
                        Button("\(ext.uppercased())…") { studio.export(take,as:ext) }
                    }
                    Button("Timed captions (.srt)…") { studio.export(take,as:"srt") }
                    Divider()
                    if take.kind == "clean" {
                        Button("Use as reference voice") { studio.start(["action":"import","source":take.url.path,"name":take.name]) }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([take.url]) }
                }.fixedSize().disabled(studio.busy)
            }
            Scrubber(transport:studio.audio,url:take.url)
            if let score = take.score {
                DisclosureGroup(isExpanded:$details.value) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("\(take.scoreScope ?? "Voice match") · WeSpeaker cosine similarity, −1 to 1.")
                        if let seconds = take.renderSeconds {
                            let reused = take.reused ?? 0
                            Text(String(format:"Rendered in %.1f seconds",seconds) + (reused > 0 ? " · Reused \(reused) passage(s)" : ""))
                        }
                        if let transcript = take.transcript { Text("Readback · " + transcript).textSelection(.enabled) }
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(.top,5)
                } label: {
                    Text(String(format:"Voice similarity  %.3f",score)).font(.caption.monospacedDigit()).foregroundStyle(mint)
                    if (take.errorRate ?? 0) > 0.10 { Text("Review wording").font(.caption).foregroundStyle(.orange) }
                }
            }
        }.padding(14).card()
    }
}

struct Scrubber: View {
    @ObservedObject var transport: Transport
    let url: URL
    var body: some View {
        if transport.current == url && transport.duration > 0 {
            HStack {
                Text(clock(transport.time)); Slider(value:Binding(get:{transport.time},set:{transport.seek($0)}),in:0...transport.duration)
                    .accessibilityLabel("Playback position")
                Text(clock(transport.duration))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    func clock(_ time:Double)->String { String(format:"%d:%02d",Int(time)/60,Int(time)%60) }
}

struct ActionStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:14,weight:.semibold))
            .padding(.horizontal,17).frame(height:38)
            .foregroundStyle(Color(red:0.13,green:0.10,blue:0.22))
            .background(lilac,in:RoundedRectangle(cornerRadius:8))
            .opacity(enabled ? (configuration.isPressed ? 0.77 : 1) : 0.43)
    }
}
extension View {
    func card()->some View { background(panel,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(hairline)) }
}
