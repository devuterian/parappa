import AppKit
import SwiftUI

/// Where the caption box sits. `custom` is wherever it was last dragged to.
enum CaptionPlacement: String, CaseIterable {
    case bottom, top, custom
}

enum CaptionWeight: String, CaseIterable {
    case regular, medium, semibold, bold

    var font: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var appKit: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

/// Which speech model listens.
enum ModelChoice: String, CaseIterable {
    /// Nemotron alone: word by word as it's spoken.
    case fast
    /// Nemotron's words as a dim draft, rewritten by Cohere Transcribe once
    /// each stretch of speech ends.
    case accurate
}

/// Everything the settings window changes, saved as it changes.
@Observable
final class Prefs {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    var placement: CaptionPlacement { didSet { defaults.set(placement.rawValue, forKey: "placement") } }
    /// `NSScreen.localizedName` of the display captions go on; empty is the main display.
    var screenName: String { didSet { defaults.set(screenName, forKey: "screenName") } }
    /// Clicks pass through the box, so it can't be dragged or hovered.
    var locked: Bool { didSet { defaults.set(locked, forKey: "locked") } }
    /// Font family name; empty is the system font.
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "fontFamily") } }
    var weight: CaptionWeight { didSet { defaults.set(weight.rawValue, forKey: "fontWeight") } }
    /// The main line: captions on their own, or the translation.
    var mainSize: Double { didSet { defaults.set(mainSize, forKey: "mainSize") } }
    /// The original, shown small under its translation.
    var originalSize: Double { didSet { defaults.set(originalSize, forKey: "originalSize") } }
    /// While the speech is already in the language translated into, show it
    /// as heard instead of hiding the box.
    var showNative: Bool { didSet { defaults.set(showNative, forKey: "showNative") } }
    var model: ModelChoice { didSet { defaults.set(model.rawValue, forKey: "model") } }

    /// Set while the settings window is open: the box shows sample text so
    /// its look and place can be seen and dragged.
    var previewing = false

    private init() {
        defaults.register(defaults: [
            "placement": CaptionPlacement.bottom.rawValue,
            "fontWeight": CaptionWeight.semibold.rawValue,
            "mainSize": 22.0,
            "originalSize": 15.0,
            "showNative": true,
            "model": ModelChoice.accurate.rawValue,
        ])
        placement = CaptionPlacement(rawValue: defaults.string(forKey: "placement") ?? "") ?? .bottom
        screenName = defaults.string(forKey: "screenName") ?? ""
        locked = defaults.bool(forKey: "locked")
        fontFamily = defaults.string(forKey: "fontFamily") ?? ""
        weight = CaptionWeight(rawValue: defaults.string(forKey: "fontWeight") ?? "") ?? .semibold
        mainSize = defaults.double(forKey: "mainSize")
        originalSize = defaults.double(forKey: "originalSize")
        showNative = defaults.bool(forKey: "showNative")
        model = ModelChoice(rawValue: defaults.string(forKey: "model") ?? "") ?? .accurate
    }

    func font(size: Double) -> Font {
        fontFamily.isEmpty
            ? .system(size: size, weight: weight.font)
            : .custom(fontFamily, size: size).weight(weight.font)
    }

    private func nsFont(size: Double) -> NSFont {
        if !fontFamily.isEmpty,
           let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: Self.appKitWeight(weight), size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: weight.appKit)
    }

    /// NSFontManager's 0–15 weight scale.
    private static func appKitWeight(_ weight: CaptionWeight) -> Int {
        switch weight {
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        }
    }

    @ObservationIgnored private var lineHeights: [String: CGFloat] = [:]

    /// One line of caption text, Korean and Latin together (Korean falls
    /// back to another font in most Latin families, and is often taller).
    func lineHeight(size: Double) -> CGFloat {
        let key = "\(fontFamily)|\(weight.rawValue)|\(size)"
        if let height = lineHeights[key] { return height }
        let text = NSAttributedString(string: "가Ag", attributes: [.font: nsFont(size: size)])
        let measured = text.boundingRect(with: .init(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let height = max((size * 1.19).rounded(), measured.rounded(.up))
        lineHeights[key] = height
        return height
    }

    var screen: NSScreen? {
        // The first screen is the one with the menu bar.
        NSScreen.screens.first { $0.localizedName == screenName } ?? NSScreen.screens.first
    }
}
