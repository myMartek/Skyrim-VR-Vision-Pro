// The start window and the settings page. A Klepton-style front (Start, Settings, status, version stamp), shown instead of booting straight into
// the game when the build asks for it (Info.plist VXStartWindow, VXLaunchGate). Start applies the settings to the environment and only then opens
// the display window, whose view starts the program (main.m vxrt_boot), so everything the runtime reads at first use sees the chosen values.
//
// Layout and wording adapted from Klepton (MIT, Copyright (c) 2026 Max Thomas; fork https://github.com/myMartek/Klepton at
// a7bad301c10b03e7d615ae8d51033146c373bcb5; license text third_party/klepton_openxr/LICENSE), visionos/Sources/KleptonApp.swift: BootView.startFront
// (:1132-1300: title, large Start, Settings, status line, version stamp in the corner), BootView.settingsPage (:1342-1415: NavigationStack, GroupBox
// sections, grey callout explanations, an Advanced DisclosureGroup, Done), PlayerSettingsView (:719-840: Picture, Your hands, "Changes to the picture
// apply the next time you start the game"), KleptonTuning.swift TuningView (:106) for the alignment sliders. Reimplemented, in English and German as
// Klepton's window (vxT); the Klepton runtime seams (kl_*) are not used. Branding is text only: no game art.
import SwiftUI

#if XRIZER_XROS_FIXTURE
private func loadStage() -> Int { Int(vx_xros_load_stage()) }
#else
private func loadStage() -> Int { 0 }
#endif

// What the start window knows about the run. The program starts once per process (Klepton: "the guest boots once per process").
final class VXLauncher: ObservableObject {
    static let shared = VXLauncher()
    enum Phase { case idle, countdown(Int), started }
    @Published var phase: Phase = .idle
    var started: Bool { if case .started = phase { return true }; return false }
    private(set) var startedAt: Date?
    // Apply the settings to the environment, then let the display view appear (it starts the program). Once.
    func start(openDisplay: () -> Void) {
        guard !started else { return }
        let r = VXSettings.shared.applyEnvironment()
        vxrt_jlog("settings_applied", "\"set\":\"\(r.set.joined(separator: " "))\",\"kept\":\"\(r.kept.joined(separator: " "))\"")
        VXStatsPanel.shared.setVisible(VXSettings.shared.statsPanel, why: "setting")
        phase = .started
        startedAt = Date()
        openDisplay()
        vxrt_boot_fallback()      // (the program still starts after a few seconds if the display view never appears)
    }
}

struct VXStartView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @ObservedObject private var launcher = VXLauncher.shared
    @ObservedObject private var settings = VXSettings.shared
    @State private var showSettings = ProcessInfo.processInfo.environment["VXRT_START_SETTINGS"] == "1"   // (a scripted launch can show the settings page)

    private static let title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Skyrim VR"
    private static let versionStamp: String? = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else { return nil }
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }()

    var body: some View {
        Group { if showSettings { VXSettingsPage(done: { showSettings = false }) } else { front } }
            .task { await autoStart() }
            // After Start, once the immersive space is open, this window is closed (it used to stay, reading "Running", in front of the game),
            // and again whenever the space is confirmed open after a pause or a reopen, or if the system brought this scene back.
            .onReceive(NotificationCenter.default.publisher(for: .vxSpaceOpened)) { _ in
                if launcher.started { dismissWindow(id: "start"); vxrt_jlog("start_window_dismissed", nil) }
            }
            .onAppear { if launcher.started && VXLifecycle.spaceOpen { dismissWindow(id: "start") } }
    }

    private func startNow() { launcher.start { openWindow(id: "display") } }

    // "Start automatically": a countdown with Cancel and Settings, so that the settings stay reachable (a crown press ends the app, and the
    // next launch would otherwise start the game again before anything could be changed).
    private func autoStart() async {
        guard settings.startAutomatically, case .idle = launcher.phase, !showSettings else { return }
        for left in stride(from: VXSettings.autoStartDelay, to: 0, by: -1) {
            launcher.phase = .countdown(left)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard case .countdown = launcher.phase else { return }       // cancelled
        }
        startNow()
        dismissWindow(id: "start")
    }

    private var front: some View {
        VStack(spacing: 22) {
            Spacer()
            Text(Self.title).font(.extraLargeTitle.bold())
            Text(vxT("Skyrim VR on Apple Vision Pro, running natively with Sense controllers.", "Skyrim VR auf der Apple Vision Pro, nativ und mit Sense-Controllern."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            statusLine
            HStack(spacing: 18) {
                Button {
                    startNow()
                } label: {
                    Label(launcher.started ? vxT("Running", "Läuft") : vxT("Start", "Start"), systemImage: launcher.started ? "checkmark.circle.fill" : "play.fill").frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).tint(.white).controlSize(.extraLarge)
                .foregroundStyle(launcher.started ? Color.secondary : Color.black)
                .disabled(launcher.started)
                Button { showSettings = true } label: { Label(vxT("Settings", "Einstellungen"), systemImage: "gearshape") }
                    .controlSize(.extraLarge)
                if case .countdown = launcher.phase {
                    Button(vxT("Cancel", "Abbrechen")) { launcher.phase = .idle }.controlSize(.extraLarge)
                }
            }
            if launcher.started {
                Text(vxT("The game is in the immersive space. Changes to the picture apply the next time you open the app.", "Das Spiel läuft im immersiven Raum. Änderungen am Bild gelten beim nächsten Öffnen der App."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let stamp = Self.versionStamp {
                Text(stamp).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize().padding(.trailing, 48).padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if case .countdown(let n) = launcher.phase {
            Label(vxT("Starting in \(n) s. Cancel to change settings first.", "Start in \(n) s. Abbrechen, um vorher Einstellungen zu ändern."), systemImage: "timer").font(.headline)
        } else if launcher.started {
            // The runtime's own milestones, as the loading card in the space shows them.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let labels = [vxT("Starting", "Startet"), vxT("Preparing the game", "Spiel wird vorbereitet"), vxT("Loading the game", "Spiel wird geladen"), vxT("Almost ready", "Gleich fertig"), vxT("Ready", "Bereit")]
                Label(labels[min(max(loadStage(), 0), 4)], systemImage: "hourglass").font(.headline)
            }
        }
    }
}

// Read-only: the mods the Mac prepared (VXMods.swift, <root>/mods.json). Every toggle is disabled; nothing changes at run time.
struct VXModsList: View {
    // Read when the section appears (not once at view creation): the file may be copied while the window is open, and the root
    // folder only exists once the runtime has made it.
    @State private var file: VXModsFile?
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let file = file, !file.mods.isEmpty {
                ForEach(file.mods) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: .constant(m.enabled)) {
                            HStack {
                                Text(m.name)
                                Spacer()
                                Text(VXMods.sizeText(m.sizeBytes)).foregroundStyle(.secondary)
                                Text(VXMods.status(m)).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!VXMods.canToggle(m))
                        if m.kind == "skse" {
                            Text(vxT("SKSE: configure on the Mac", "SKSE: am Mac einrichten")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(vxT("Profile \(file.profile). Mods are chosen on the Mac and apply when the app starts; none can be switched here.", "Profil \(file.profile). Mods werden am Mac gewählt und gelten ab dem Start der App; hier lässt sich keine umschalten."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(loaded ? vxT("No mods installed. Mods are prepared on the Mac and copied to the headset.", "Keine Mods installiert. Mods werden am Mac vorbereitet und auf das Headset kopiert.") : vxT("Reading the mods list…", "Die Liste der Mods wird gelesen …")).font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { file = VXMods.load(root: VXMods.defaultRoot()); loaded = true }
    }
}

// The settings page, laid out as the settings of every game AVP Play builds with Klepton (KleptonApp.swift BootView.settingsPage and
// PlayerSettingsView): what a player may change, in Klepton's order and words (Picture, Your hands, ...), then Advanced. On top, a button
// to the game's own options, which have a page of their own (VXGameSettingsPage). English and German (vxT).
struct VXSettingsPage: View {
    let done: () -> Void
    @ObservedObject private var settings = VXSettings.shared
    @ObservedObject private var launcher = VXLauncher.shared
    @State private var sense = VXSenseValues.load()
    @State private var advancedOpen = ProcessInfo.processInfo.environment["VXRT_START_ADVANCED"] == "1"
    @State private var showGame = ProcessInfo.processInfo.environment["VXRT_START_GAME_SETTINGS"] == "1"   // (a scripted launch can show the sub-page)

    private func note(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Button { showGame = true } label: {
                        HStack {
                            Label(vxT("Game settings", "Spieleinstellungen"), systemImage: "gamecontroller").font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .controlSize(.large)
                    note(vxT("Skyrim VR's own options: turning, movement, comfort, subtitles and more.",
                             "Die eigenen Optionen von Skyrim VR: Drehen, Bewegung, Komfort, Untertitel und mehr."))
                    GroupBox(vxT("Picture", "Bild")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(vxT("Base resolution per eye", "Basisauflösung je Auge"))
                                Spacer()
                                Picker(vxT("Base resolution per eye", "Basisauflösung je Auge"), selection: $settings.baseResolution) {
                                    ForEach(VXSettings.baseResolutions, id: \.self) { v in
                                        Text(v == 0 ? "Standard (\(VXSettings.baseResolutionStandard))" : "\(v)").tag(v)
                                    }
                                }.labelsHidden()
                            }
                            note(vxT("The width in pixels of the picture each eye is drawn for; Resolution below is a share of it, and MetalFX enlarges to it. Higher is sharper and costs graphics time: the game draws about as many more pixels as the number grows, squared.",
                                     "Die Breite in Pixeln des Bildes, für das jedes Auge gezeichnet wird; die Auflösung darunter ist ein Anteil davon, und MetalFX vergrößert darauf. Höher ist schärfer und kostet Grafikzeit: Das Spiel zeichnet etwa so viel mehr Pixel, wie die Zahl wächst, im Quadrat."))
                            HStack {
                                Text(vxT("Resolution", "Auflösung"))
                                Slider(value: Binding(get: { settings.renderScale }, set: { settings.renderScale = VXSettings.clampScale($0) }),
                                       in: VXSettings.renderScaleRange, step: 0.05)
                                Text(String(format: "%.0f%%", settings.renderScale * 100)).font(.system(.body, design: .monospaced)).frame(width: 70)
                            }
                            note(vxT("How finely the game is drawn, as a share of the base resolution. Lower it if the picture stutters when you look around. With MetalFX on, the size it enlarges. 75% is the default.",
                                     "Wie fein das Spiel gezeichnet wird, als Anteil der Basisauflösung. Verringern, wenn das Bild beim Umsehen ruckelt. Mit MetalFX die Größe, die es vergrößert. Üblich sind 75 %."))
                            Picker(vxT("Upscaling", "Hochskalieren"), selection: $settings.upscale) {
                                Text("MetalFX").tag(VXUpscale.metalfx)
                                Text(vxT("Plain", "Einfach")).tag(VXUpscale.bilinear)
                            }.pickerStyle(.segmented)
                            note(settings.upscale == .metalfx
                                 ? vxT("Apple's MetalFX brings the game's picture up to the display's size: sharper than plain scaling.",
                                       "Apples MetalFX bringt das Bild des Spiels auf die Größe der Anzeige: schärfer als einfaches Skalieren.")
                                 : vxT("The picture is simply stretched: softer, with no extra work.",
                                       "Das Bild wird nur gestreckt: weicher, ohne zusätzliche Arbeit."))
                            Picker(vxT("Unseen edge", "Unsichtbarer Rand"), selection: $settings.edgeMask) {
                                Text(vxT("Draw everything", "Alles zeichnen")).tag(VXEdgeMask.off)
                                Text(vxT("Skip a little", "Wenig auslassen")).tag(VXEdgeMask.slight)
                                Text(vxT("Skip more", "Mehr auslassen")).tag(VXEdgeMask.standard)
                            }.pickerStyle(.segmented)
                            note(vxT("The game can leave out the edge of the picture that the lenses do not show, which makes it run more smoothly. If you see a black bar or black corners in the game, choose less here; “Draw everything” never shows one.",
                                     "Das Spiel kann den Rand des Bildes auslassen, den die Linsen nicht zeigen, und läuft dann flüssiger. Siehst du im Spiel einen schwarzen Balken oder schwarze Ecken, wähle hier weniger; „Alles zeichnen“ zeigt nie einen."))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(vxT("Smoothness", "Flüssigkeit")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker(vxT("Smoothness", "Flüssigkeit"), selection: $settings.latency) {
                                Text(vxT("Balanced", "Ausgewogen")).tag(VXLatency.smart)
                                Text(vxT("Fresher picture", "Frischeres Bild")).tag(VXLatency.lower)
                                Text(vxT("Most frames", "Meiste Bilder")).tag(VXLatency.throughput)
                            }.pickerStyle(.segmented).labelsHidden()
                            note(settings.latency == .smart
                                 ? vxT("The default. The game starts each frame as the display frees up: the most frames a second without older head positions. Applies at once.",
                                       "Der Standard. Das Spiel beginnt jedes Bild, sobald die Anzeige frei wird: die meisten Bilder pro Sekunde ohne ältere Kopfpositionen. Gilt sofort.")
                                 : settings.latency == .lower
                                 ? vxT("The game starts a frame only once its previous one is on its way to the display: built from a fresher head position, at fewer frames a second. Applies at once.",
                                       "Das Spiel beginnt ein Bild erst, wenn das vorige unterwegs zur Anzeige ist: aus einer frischeren Kopfposition, mit weniger Bildern pro Sekunde. Gilt sofort.")
                                 : vxT("The game runs ahead freely: the most frames a second, each built from an older head position. Applies at once.",
                                       "Das Spiel läuft frei voraus: die meisten Bilder pro Sekunde, jedes aus einer älteren Kopfposition. Gilt sofort."))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(vxT("Your hands", "Deine Hände")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(vxT("Show my real hands over the game", "Meine echten Hände über dem Spiel zeigen"), isOn: $settings.showHands)
                            note(vxT("The game draws its own hands and controllers, so your real ones would be a second pair in the same place. Applies at once.",
                                     "Das Spiel zeichnet eigene Hände und Controller; deine echten wären ein zweites Paar an derselben Stelle. Gilt sofort."))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(vxT("Performance panel", "Leistungsanzeige")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(vxT("Show from the start", "Von Anfang an zeigen"), isOn: $settings.statsPanel)
                            note(vxT("Frame rate, graphics and processor time, memory and heat, above the middle of the view. In the game, hold Create and Options (the two menu buttons of the controllers) together for a second to show it or hide it.",
                                     "Bildrate, Grafik- und Prozessorzeit, Speicher und Wärme, über der Mitte des Blickfelds. Im Spiel Create und Options (die beiden Menütasten der Controller) eine Sekunde zusammen halten, um sie zu zeigen oder auszublenden."))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Mods") {
                        VXModsList()
                    }
                    GroupBox(vxT("Start", "Start")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(vxT("Start automatically", "Automatisch starten"), isOn: $settings.startAutomatically)
                            note(vxT("Off: this window waits for Start. On: the game starts \(VXSettings.autoStartDelay) seconds after the app opens; until then you can cancel or change settings.",
                                     "Aus: Dieses Fenster wartet auf Start. An: Das Spiel startet \(VXSettings.autoStartDelay) Sekunden nach dem Öffnen der App; bis dahin kannst du abbrechen oder Einstellungen ändern."))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Label(launcher.started ? vxT("The game is running: changes to the picture apply the next time you open the app.",
                                                 "Das Spiel läuft: Änderungen am Bild gelten beim nächsten Öffnen der App.")
                                           : vxT("Changes to the picture apply the next time you start the game.",
                                                 "Änderungen am Bild gelten beim nächsten Start des Spiels."),
                          systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup(vxT("Advanced", "Erweitert"), isExpanded: $advancedOpen) {
                        VStack(alignment: .leading, spacing: 14) { advanced }.padding(.top, 10)
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 24)
            }
            .navigationTitle(vxT("Settings", "Einstellungen"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(vxT("Done", "Fertig"), action: done) } }
            .navigationDestination(isPresented: $showGame) { VXGameSettingsPage() }
        }
    }

    @ViewBuilder private var advanced: some View {
        GroupBox(vxT("Picture in detail", "Bild im Detail")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(vxT("Sharpening off", "Nachschärfen aus"), isOn: Binding(get: { settings.sharpen == nil }, set: { settings.sharpen = $0 ? nil : 0.35 }))
                if let v = settings.sharpen {
                    HStack {
                        Text(vxT("Sharpening", "Nachschärfen"))
                        Slider(value: Binding(get: { v }, set: { settings.sharpen = $0 }), in: VXSettings.unitRange, step: 0.05)
                        Text(String(format: "%.2f", v)).font(.system(.body, design: .monospaced)).frame(width: 70)
                    }
                }
                note(vxT("A light sharpening pass on the final picture. Off by default; about 0.35 is a start.",
                         "Ein leichtes Nachschärfen des fertigen Bildes. Üblicherweise aus; etwa 0,35 ist ein Anfang."))
                Toggle(vxT("High-resolution display", "Hochauflösende Anzeige"), isOn: $settings.foveation)
                note(vxT("How the finished picture is handed to the headset: at full sharpness where you look, as every other AVP Play game does it. This is not the game's own foveated rendering, and it does not change what the game draws. Off, the headset takes only a plain picture of about 2000 pixels an eye; the base resolution still counts, but less of it is seen. Turn it off only if the picture looks warped or the game does not start.",
                         "Wie das fertige Bild an das Headset übergeben wird: in voller Schärfe dort, wohin du schaust, so wie bei jedem anderen AVP-Play-Spiel. Das ist nicht das Foveated Rendering des Spiels und ändert nicht, was das Spiel zeichnet. Aus nimmt das Headset nur ein einfaches Bild von rund 2000 Pixeln je Auge an; die Basisauflösung zählt weiter, aber man sieht weniger davon. Nur ausschalten, wenn das Bild verzerrt aussieht oder das Spiel nicht startet."))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox(vxT("Controller alignment", "Controller-Ausrichtung")) {
            VStack(alignment: .leading, spacing: 10) {
                // The values land in Documents/vxrt_sense.txt, which the running game re-reads once a second.
                senseSlider(vxT("Pitch", "Neigung"), $sense.pitch, -45...45, 0.5, "°")
                senseSlider(vxT("Yaw", "Drehung"), $sense.yaw, -45...45, 0.5, "°")
                senseSlider(vxT("Roll", "Rollen"), $sense.roll, -45...45, 0.5, "°")
                senseSlider(vxT("Forward", "Vor"), Binding(get: { -sense.pos.z * 100 }, set: { sense.pos.z = -$0 / 100 }), -12...12, 0.5, " cm")
                senseSlider(vxT("Up", "Hoch"), Binding(get: { sense.pos.y * 100 }, set: { sense.pos.y = $0 / 100 }), -12...12, 0.5, " cm")
                senseSlider(vxT("Right", "Rechts"), Binding(get: { sense.pos.x * 100 }, set: { sense.pos.x = $0 / 100 }), -12...12, 0.5, " cm")
                HStack {
                    Button(vxT("Reset", "Zurücksetzen")) { sense = VXSenseValues(); VXSenseValues.reset() }
                    Text(sense.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                note(vxT("Rotates and moves the controller the game draws against your Sense controller. Applies to a running game within a second.",
                         "Dreht und verschiebt den Controller, den das Spiel zeichnet, gegen deinen Sense-Controller. Gilt im laufenden Spiel innerhalb einer Sekunde."))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox(vxT("Head prediction", "Kopf-Vorhersage")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(vxT("Automatic", "Automatisch"), isOn: Binding(get: { settings.predictMs == nil }, set: { settings.predictMs = $0 ? nil : 60 }))
                if let p = settings.predictMs {
                    HStack {
                        Slider(value: Binding(get: { p }, set: { settings.predictMs = $0 }), in: VXSettings.predictRange, step: 5)
                        Text(String(format: "%.0f ms", p)).font(.system(.body, design: .monospaced)).frame(width: 80)
                    }
                }
                note(vxT("How far ahead the game's head position is predicted. Automatic follows the measured delay of the game's pictures; a fixed value is for experiments. Applies the next time you start.",
                         "Wie weit die Kopfposition für das Spiel vorausgesagt wird. Automatisch folgt der gemessenen Verzögerung der Bilder; ein fester Wert ist für Versuche. Gilt beim nächsten Start."))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox(vxT("Eye height above the floor", "Augenhöhe über dem Boden")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(vxT("Default (1.6 m)", "Standard (1,6 m)"), isOn: Binding(get: { settings.stageEyeHeight == nil }, set: { settings.stageEyeHeight = $0 ? nil : 1.6 }))
                if let h = settings.stageEyeHeight {
                    HStack {
                        Slider(value: Binding(get: { h }, set: { settings.stageEyeHeight = $0 }), in: VXSettings.eyeHeightRange, step: 0.05)
                        Text(String(format: "%.2f m", h)).font(.system(.body, design: .monospaced)).frame(width: 80)
                    }
                }
                note(vxT("The height of your eyes above the floor that the game assumes, which sets where the floor is. Seated play wants a lower value. Applies the next time you start.",
                         "Die Höhe deiner Augen über dem Boden, von der das Spiel ausgeht; sie bestimmt, wo der Boden liegt. Im Sitzen passt ein kleinerer Wert. Gilt beim nächsten Start."))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox(vxT("Diagnostics", "Diagnose")) {
            VStack(alignment: .leading, spacing: 10) {
                let docs = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
                ForEach(["vxrt.log", "host_log.jsonl"], id: \.self) { name in
                    let path = (docs as NSString).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path) {
                        ShareLink(item: URL(fileURLWithPath: path)) { Label(vxT("Export \(name)", "\(name) exportieren"), systemImage: "square.and.arrow.up") }
                    } else {
                        Text(vxT("\(name): not written yet", "\(name): noch nicht geschrieben")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func senseSlider(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ step: Float, _ unit: String) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step, onEditingChanged: { editing in if !editing { sense.save() } })
            Text(String(format: "%+.1f%@", value.wrappedValue, unit)).font(.system(.body, design: .monospaced)).frame(width: 90)
        }
    }
}

// The game's own options (Skyrim VR's ini values, VXSettings.iniOverrides): a page of its own behind the button on top of the settings.
// "Game default" writes nothing, so the game keeps its own value.
struct VXGameSettingsPage: View {
    @ObservedObject private var settings = VXSettings.shared

    private func note(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private static var gameDefault: String { vxT("Game default", "Wie im Spiel") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(vxT("“Game default” changes nothing: the game keeps its own value. Everything here applies the next time you start the game.",
                          "„Wie im Spiel“ ändert nichts: Das Spiel behält seinen eigenen Wert. Alles hier gilt beim nächsten Start des Spiels."),
                      systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                GroupBox(vxT("Turning", "Drehen")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(vxT("Turning", "Drehen"), selection: $settings.turn) {
                            Text(Self.gameDefault).tag(VXTurn.game)
                            Text(vxT("Snap", "In Schritten")).tag(VXTurn.snap)
                            Text(vxT("Smooth", "Fließend")).tag(VXTurn.smooth)
                        }.pickerStyle(.segmented).labelsHidden()
                        note(settings.turn == .game
                             ? vxT("Leaves turning as the game has it.", "Lässt das Drehen, wie das Spiel es hat.")
                             : settings.turn == .snap
                             ? vxT("Flicking the right stick turns you in steps.", "Ein Tipp am rechten Stick dreht dich in Schritten.")
                             : vxT("Holding the right stick turns you smoothly. Some people find this uncomfortable.",
                                   "Der gehaltene rechte Stick dreht dich fließend. Manche vertragen das schlecht."))
                        Toggle(vxT("Snap angle: game default", "Schrittwinkel: wie im Spiel"),
                               isOn: Binding(get: { settings.snapAngle == nil }, set: { settings.snapAngle = $0 ? nil : VXSettings.snapAngleBuiltIn }))
                        if let a = settings.snapAngle {
                            HStack {
                                Slider(value: Binding(get: { a }, set: { settings.snapAngle = $0 }), in: VXSettings.snapAngleRange, step: 5)
                                Text(String(format: "%.0f°", a)).font(.system(.body, design: .monospaced)).frame(width: 70)
                            }
                        }
                        Toggle(vxT("Turn speed: game default", "Drehgeschwindigkeit: wie im Spiel"),
                               isOn: Binding(get: { settings.turnSpeed == nil }, set: { settings.turnSpeed = $0 ? nil : VXSettings.turnSpeedBuiltIn }))
                        if let v = settings.turnSpeed {
                            HStack {
                                Slider(value: Binding(get: { v }, set: { settings.turnSpeed = $0 }), in: VXSettings.turnSpeedRange, step: 0.1)
                                Text(String(format: "%.1f", v)).font(.system(.body, design: .monospaced)).frame(width: 70)
                            }
                        }
                        note(vxT("The angle is for turning in steps, the speed for smooth turning.",
                                 "Der Winkel gilt für das Drehen in Schritten, die Geschwindigkeit für das fließende."))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(vxT("Movement", "Bewegung")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker(vxT("Movement", "Bewegung"), selection: $settings.move) {
                            Text(Self.gameDefault).tag(VXMove.game)
                            Text(vxT("Teleport", "Teleport")).tag(VXMove.teleport)
                            Text(vxT("Walk", "Gehen")).tag(VXMove.walk)
                        }.pickerStyle(.segmented).labelsHidden()
                        note(settings.move == .game
                             ? vxT("Leaves movement as the game has it.", "Lässt die Bewegung, wie das Spiel sie hat.")
                             : settings.move == .teleport
                             ? vxT("Push the left stick forward to aim and release to jump there.",
                                   "Linken Stick nach vorn drücken, um zu zielen, und loslassen, um dorthin zu springen.")
                             : vxT("The left stick walks you around directly.", "Der linke Stick lässt dich direkt gehen."))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(VXIniSetting.Group.allCases, id: \.self) { g in
                    GroupBox(g.title) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(VXIniSetting.all.filter { $0.group == g }) { item in iniRow(item) }
                            if g == .body || g == .teleport {
                                note(vxT("The number ranges are cautious bounds, not the game's own.",
                                         "Die Zahlenbereiche sind vorsichtige Grenzen, nicht die des Spiels."))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 24)
        }
        .navigationTitle(vxT("Game settings", "Spieleinstellungen"))
    }

    @ViewBuilder private func iniRow(_ item: VXIniSetting) -> some View {
        switch item.kind {
        case .flag:
            HStack {
                Text(item.localizedTitle)
                Spacer()
                Picker(item.localizedTitle, selection: Binding(get: { settings.flag(item.id) }, set: { settings.setFlag(item.id, $0) })) {
                    Text(Self.gameDefault).tag(Bool?.none)
                    Text(vxT("On", "An")).tag(Bool?.some(true))
                    Text(vxT("Off", "Aus")).tag(Bool?.some(false))
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            }
        case .number(let range, let step, let unit):
            VStack(alignment: .leading) {
                Toggle(vxT("\(item.localizedTitle): game default", "\(item.localizedTitle): wie im Spiel"),
                       isOn: Binding(get: { settings.number(item.id) == nil },
                                     set: { settings.setNumber(item.id, $0 ? nil : (range.lowerBound + range.upperBound) / 2) }))
                if let v = settings.number(item.id) {
                    HStack {
                        Slider(value: Binding(get: { v }, set: { settings.setNumber(item.id, $0) }), in: range, step: step)
                        Text(String(format: "%g%@", v, unit)).font(.system(.body, design: .monospaced)).frame(width: 70)
                    }
                }
            }
        }
    }
}
