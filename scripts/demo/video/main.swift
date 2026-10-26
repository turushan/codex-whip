// Deterministic marketing film renderer. No Codex process or session is read.
// Build and run through python3 scripts/render_demo.py.
//
// render-film --icon PATH --avatar PATH --message TEXT --retry SECONDS --check SECONDS [--grain AMOUNT] MODE
//   plan PATH                 write the timeline and sound cues as JSON
//   stills TIMES DIRECTORY    write PNG stills at comma-separated times
//   raw [--fps N] [--from S] [--to S] [--gif]
//                             stream BGRA frames (1920 × 1080) to standard output
// --grain sets the display-space dither (0 for clean stills); --gif also freezes ambient motion.
import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
func required(_ name: String) -> String {
    guard let value = option(name) else { FileHandle.standardError.write("Missing \(name)\n".data(using: .utf8)!); exit(2) }
    return value
}
func loadImage(_ path: String) -> CGImage {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("Cannot read image \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return cg
}

let settings = Settings(message: required("--message"), retrySeconds: Int(required("--retry"))!, checkSeconds: Int(required("--check"))!)
let film = Film(settings: settings)
let director = Director(film: film, icon: loadImage(required("--icon")), avatar: loadImage(required("--avatar")))
if let grain = option("--grain").flatMap(Double.init) {
    director.grain = grain
}
let origin = "Codex Whip illustrated marketing film, rendered by scripts/demo/video with AppKit, CoreGraphics and Core Image. "
    + "Synthetic sessions; typing illustrated; time compressed. The reset post is an illustrated example; the app checks Codex quota, "
    + "not posts, and sends one local continuation message. No live session data or model requests."

func savePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let metadata: [CFString: Any] = [kCGImagePropertyPNGDictionary: [
        kCGImagePropertyPNGTitle: "Codex Whip · Same model. Keep going.",
        kCGImagePropertyPNGAuthor: "Codex Whip",
        kCGImagePropertyPNGDescription: origin,
        kCGImagePropertyPNGSoftware: "Native AppKit, CoreGraphics and Core Image deterministic renderer",
    ]]
    CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
}

if let path = option("plan") {
    var cues: [[String: Any]] = []
    let entries = film.cues(passes: director.passes) { strike in
        let pass = director.passes.first { $0.strikes.contains { $0.impact == strike.impact } }!
        let x = pass.space == .screen ? strike.target.x : director.camera(strike.impact).toScreen(strike.target).x
        return ((x / 1920 * 2 - 1) * 0.8 * 100).rounded() / 100
    }
    for cue in entries {
        var entry: [String: Any] = ["time": (cue.time * 10000).rounded() / 10000, "type": cue.type]
        for (key, value) in cue.extra { entry[key] = value }
        cues.append(entry)
    }
    let plan: [String: Any] = [
        "duration": Film.duration, "fps": Film.fps, "bpm": Film.bpm, "beatsPerBar": 4,
        "sections": film.sections.map { ["name": $0.name, "start": $0.start, "end": $0.end] },
        "chords": film.chords.enumerated().map { ["bar": $0.offset + 1, "start": Double($0.offset) * 2, "symbol": $0.element] },
        "cues": cues,
    ]
    let data = try! JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
    print("Wrote \(cues.count) cues to \(path)")
} else if let index = arguments.firstIndex(of: "stills"), arguments.indices.contains(index + 2) {
    let times = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
    let directory = URL(fileURLWithPath: arguments[index + 2], isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for t in times {
        autoreleasepool {
            let image = director.compositor.cgImage(director.frame(t, index: Int(t * Double(Film.fps))))
            savePNG(image, to: directory.appendingPathComponent(String(format: "still-%06.3f.png", t)))
        }
    }
    print("Wrote \(times.count) stills to \(directory.path)")
} else if arguments.contains("raw") {
    let fps = Double(option("--fps") ?? "") ?? Double(Film.fps)
    let start = Double(option("--from") ?? "") ?? 0
    let end = Double(option("--to") ?? "") ?? Film.duration
    if arguments.contains("--gif") {
        director.freezeAmbient = true
    }
    let first = Int((start * fps).rounded()), last = Int((end * fps).rounded())
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1920 * 1080 * 4, alignment: 64)
    defer { buffer.deallocate() }
    let began = Date()
    for frame in first..<last {
        autoreleasepool {
            let t = Double(frame) / fps
            director.compositor.render(director.frame(t, index: frame), into: buffer)
            var written = 0
            while written < 1920 * 1080 * 4 {
                let result = fwrite(buffer + written, 1, 1920 * 1080 * 4 - written, stdout)
                if result <= 0 { exit(1) }
                written += result
            }
        }
        if (frame - first) % 300 == 299 {
            let elapsed = Date().timeIntervalSince(began)
            let done = frame - first + 1
            FileHandle.standardError.write(String(format: "Rendered %d/%d frames · %.1f fps\n", done, last - first, Double(done) / elapsed).data(using: .utf8)!)
        }
    }
    fflush(stdout)
} else {
    FileHandle.standardError.write("Choose a mode: --plan PATH, stills TIMES DIR, or raw\n".data(using: .utf8)!)
    exit(2)
}
