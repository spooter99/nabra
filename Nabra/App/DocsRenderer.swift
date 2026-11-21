import AppKit
import SwiftUI

/// Renders the recording indicator to image files for the documentation
/// (`Nabra --render-indicator <folder>`), so screenshots never include anyone's desktop.
enum DocsRenderer {
    @MainActor
    static func renderIndicator(to directory: String) -> Int32 {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let meter = LevelMeter()
        feedSpeechLikeLevels(into: meter)

        func model(_ configure: (HUDModel) -> Void) -> HUDModel {
            let model = HUDModel()
            model.placement = .bottom
            model.meter = meter
            configure(model)
            return model
        }
        var states: [(String, HUDModel)] = [
            ("indicator-listening", model { $0.mode = .listening }),
            ("indicator-hands-free", model { $0.mode = .listening; $0.isHandsFree = true }),
            ("indicator-processing", model { $0.mode = .processing }),
            ("indicator-learned", model {
                $0.mode = .notice
                $0.noticeText = "Learned “Darwish”"
                $0.noticeSymbol = "character.book.closed.fill"
            }),
        ]
        // Not part of the documentation set: the moment before the microphone is heard.
        if ProcessInfo.processInfo.environment["NABRA_RENDER_STARTING"] != nil {
            states.append(("indicator-starting", model { $0.mode = .listening; $0.isLive = false; $0.meter = LevelMeter() }))
        }
        var failed = false
        for (name, state) in states {
            let view = ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.24), Color(red: 0.09, green: 0.10, blue: 0.14)],
                               startPoint: .top, endPoint: .bottom)
                NotchView(model: state)
            }
            .frame(width: 340, height: 84)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                failed = true
                continue
            }
            try? png.write(to: folder.appendingPathComponent(name + ".png"))
        }
        // Banner for the top of the README.
        let banner = ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.05, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.55, green: 0.38, blue: 0.95).opacity(0.35), .clear],
                           center: .init(x: 0.5, y: 0.2), startRadius: 10, endRadius: 520)
            VStack(spacing: 20) {
                NabraMark(size: 104)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                Text("Nabra")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Hold a key and speak. Arabic, English, or both in one sentence.\nTyped wherever your cursor is, entirely on your Mac.")
                    .font(.system(size: 21, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
                NotchView(model: model { $0.mode = .listening })
                    .frame(width: 320, height: 54)
            }
            .padding(.top, 6)
        }
        .frame(width: 1280, height: 540)
        let bannerRenderer = ImageRenderer(content: banner)
        bannerRenderer.scale = 2
        if let image = bannerRenderer.nsImage, let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("banner.png"))
        } else {
            failed = true
        }

        print(failed ? "some images could not be rendered" : "rendered \(states.count + 1) images to \(folder.path)")
        return failed ? 1 : 0
    }

    /// Fills the meter with a loudness curve shaped like a few spoken words.
    private static func feedSpeechLikeLevels(into meter: LevelMeter) {
        let sampleRate = Double(SpeechEngine.sampleRate)
        var samples = [Float](repeating: 0, count: Int(sampleRate * 2))
        for index in samples.indices {
            let time = Double(index) / sampleRate
            let syllables = 0.5 + 0.5 * sin(time * 2 * .pi * 5.4 + 2.1)
            let phrase = 0.6 + 0.4 * sin(time * 2 * .pi * 1.7 + 0.4)
            let amplitude = 0.01 + 0.22 * pow(syllables, 1.3) * phrase
            samples[index] = Float(amplitude * sin(time * 2 * .pi * 180))
        }
        samples.withUnsafeBufferPointer { meter.push($0.baseAddress!, count: $0.count) }
    }
}
