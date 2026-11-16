// The picture presets of the settings window (VXSettingsWindow.swift): what a preset holds, the three that come with the app,
// the player's own, and which Vision Pro this is. Values and rules only, checked on a Mac with VXSettings.swift
// (tests/xros_presets_test.swift, `make xros-presets-check`).
//
// The same idea as Klepton's games in AVP Play (its KleptonPictureProfile.swift, reimplemented here): "Vision Pro M5" is what a
// new player starts with (VXSettings' defaults, found good on an M5 on 2026-11-13). "Performance" is 75 % with MetalFX – which is
// what Skyrim already starts with, so here it also draws for one base resolution smaller. "Quality" is the next larger base
// resolution, the whole picture drawn (no unseen edge left out) and the finest display quality. Nobody has played these on an M2:
// its owners are asked to make presets of their own and share them as text. A preset sets the picture only; the frame rate,
// smoothness and the game's own options stay as the player chose them.
import Foundation

struct VXPicture: Codable, Equatable {
    var baseResolution: Int
    var renderScale: Double
    var upscale: String             // VXUpscale
    var displayQuality: Double      // one of VXSettings.displayQualities
    var plainResample: Bool
    var foveatedRendering: String   // VXFoveatedRendering
    var edgeMask: String            // VXEdgeMask

    /// A copy within the ranges the window offers – for a preset read from text.
    func clamped() -> VXPicture {
        var p = self
        if !VXSettings.baseResolutions.contains(p.baseResolution) { p.baseResolution = VXSettings.baseResolutionDefault }
        p.renderScale = (VXSettings.clampScale(renderScale) * 20).rounded() / 20
        if VXUpscale(rawValue: p.upscale) == nil { p.upscale = VXUpscale.metalfx.rawValue }
        p.displayQuality = VXSettings.displayQualities.min { abs($0 - displayQuality) < abs($1 - displayQuality) } ?? VXSettings.displayQualityDefault
        if VXFoveatedRendering(rawValue: p.foveatedRendering) == nil { p.foveatedRendering = VXSettings.foveatedRenderingDefault.rawValue }
        if VXEdgeMask(rawValue: p.edgeMask) == nil { p.edgeMask = VXEdgeMask.slight.rawValue }
        return p
    }
}

extension VXSettings {
    /// The picture as it is set now.
    var picture: VXPicture {
        VXPicture(baseResolution: baseResolution, renderScale: (renderScale * 20).rounded() / 20, upscale: upscale.rawValue,
                  displayQuality: displayQuality, plainResample: plainResample,
                  foveatedRendering: foveatedRendering.rawValue, edgeMask: edgeMask.rawValue)
    }

    /// Sets the picture (next start, like every picture setting).
    func apply(_ p: VXPicture) {
        let p = p.clamped()
        baseResolution = p.baseResolution
        renderScale = p.renderScale
        upscale = VXUpscale(rawValue: p.upscale) ?? .metalfx
        displayQuality = p.displayQuality
        plainResample = p.plainResample
        foveatedRendering = VXFoveatedRendering(rawValue: p.foveatedRendering) ?? VXSettings.foveatedRenderingDefault
        edgeMask = VXEdgeMask(rawValue: p.edgeMask) ?? .slight
    }

    /// What a new player starts with: these settings with nothing saved and no launch overrides.
    static func standardPicture(info: [String: Any]) -> VXPicture {
        let name = "vxrt.presets.standard.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        return VXSettings(defaults: store, info: info, environment: [:]).picture
    }
}

enum VXBuiltInPreset: String, CaseIterable, Identifiable {
    case standard = "m5", performance = "m5.performance", quality = "m5.quality"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .standard: return "Vision Pro M5"
        case .performance: return vxT("M5 Performance", "M5 Leistung")
        case .quality: return vxT("M5 Quality", "M5 Qualität")
        }
    }
}

enum VXPresetRules {
    /// The base resolution a step from `base` (0, the standard, counts as `baseResolutionStandard`); clamped at the ends.
    static func baseStep(_ base: Int, by step: Int) -> Int {
        let sizes = VXSettings.baseResolutions.filter { $0 > 0 }
        let now = base > 0 ? base : VXSettings.baseResolutionStandard
        let i = sizes.firstIndex(of: now) ?? sizes.firstIndex { $0 >= now } ?? 0
        return sizes[min(max(i + step, 0), sizes.count - 1)]
    }

    static func performance(from s: VXPicture) -> VXPicture {
        var p = s
        p.renderScale = 0.75
        p.upscale = VXUpscale.metalfx.rawValue
        // Skyrim's standard is 75 % with MetalFX already; what is left to make it lighter is the base it scales from.
        if s.renderScale <= 0.75 + 0.001, s.upscale == VXUpscale.metalfx.rawValue { p.baseResolution = baseStep(s.baseResolution, by: -1) }
        return p
    }

    static func quality(from s: VXPicture) -> VXPicture {
        var p = s
        p.baseResolution = baseStep(s.baseResolution, by: 1)
        p.edgeMask = VXEdgeMask.off.rawValue
        p.displayQuality = VXSettings.displayQualities.max() ?? 1.0
        return p
    }

    static func picture(_ k: VXBuiltInPreset, standard: VXPicture) -> VXPicture {
        switch k {
        case .standard: return standard
        case .performance: return performance(from: standard)
        case .quality: return quality(from: standard)
        }
    }

    static func matching(_ now: VXPicture, standard: VXPicture, custom: [VXCustomPreset]) -> VXPresetID? {
        for k in VXBuiltInPreset.allCases where picture(k, standard: standard) == now { return .builtIn(k) }
        return custom.first { $0.picture == now }.map { .custom($0.id) }
    }
}

enum VXPresetID: Hashable { case builtIn(VXBuiltInPreset), custom(UUID) }

struct VXCustomPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var picture: VXPicture
    var device: String
}

struct VXPresetStore {
    static let key = "vxrt.presets.custom"
    static let shareHeader = "AVP Play Skyrim VR picture preset v1"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var presets: [VXCustomPreset] {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([VXCustomPreset].self, from: $0) } ?? [] }
        nonmutating set {
            if newValue.isEmpty { defaults.removeObject(forKey: Self.key) }
            else if let d = try? JSONEncoder().encode(newValue) { defaults.set(d, forKey: Self.key) }
        }
    }

    @discardableResult
    func save(name: String, picture: VXPicture, device: String) -> VXCustomPreset {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var all = presets
        if let i = all.firstIndex(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            all[i].picture = picture; all[i].device = device; presets = all; return all[i]
        }
        let p = VXCustomPreset(id: UUID(), name: clean, picture: picture, device: device)
        presets = all + [p]
        return p
    }
    func delete(_ id: UUID) { presets = presets.filter { $0.id != id } }
    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        presets = presets.map { var p = $0; if p.id == id { p.name = clean }; return p }
    }

    static func shareText(_ p: VXCustomPreset) -> String {
        struct Shared: Codable { let name: String; let device: String; let picture: VXPicture }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = (try? enc.encode(Shared(name: p.name, device: p.device, picture: p.picture))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return shareHeader + "\n" + body
    }
    static func parse(_ text: String) -> (name: String, device: String, picture: VXPicture)? {
        struct Shared: Codable { let name: String; let device: String?; let picture: VXPicture }
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let s = try? JSONDecoder().decode(Shared.self, from: Data(text[a...b].utf8)) else { return nil }
        let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Preset" : String(name.prefix(40)), s.device ?? "", s.picture.clamped())
    }
}

/// Which Vision Pro: the first, with the M2 ("RealityDevice14,1"), or the one with the M5 ("RealityDevice17,1") or later.
enum VXDeviceKind: String {
    case m2 = "M2", m5 = "M5"
    static func from(model: String, override: String? = nil) -> VXDeviceKind {
        switch override?.lowercased() { case "m2": return .m2; case "m5": return .m5; default: break }
        guard model.hasPrefix("RealityDevice"), let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return .m5 }
        return major < 17 ? .m2 : .m5
    }
    /// The mixed space's and the full space's highest rate: 100/120 on the M5; the M2's display has no 120 Hz.
    var rates: (mixed: Int, full: Int) { self == .m2 ? (90, 100) : (100, 120) }
}
