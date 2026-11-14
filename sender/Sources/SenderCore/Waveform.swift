import AVFoundation
import Foundation

/// Three-band waveforms in the format LJ Link already draws for CDJ-3000 style players
/// (`WaveformEncoder.encodeDetail`, style "threeband"): 4 bytes per entry = low, mid, high height (0-255), 0.
/// Heights are scaled to the loudest value of the track, like LJ Link does for player waveforms.
public struct Waveforms: Sendable {
    /// Entries per second of the detail waveform (rekordbox and LJ Link use 150).
    public static let detailRate = 150
    /// Entries of the overview (whole track).
    public static let overviewCount = 400

    public let detail: [UInt8]
    public let overview: [UInt8]
    public let durationMs: Int64
    public var detailFrames: Int { detail.count / 4 }

    public init(detail: [UInt8], overview: [UInt8], durationMs: Int64) {
        self.detail = detail
        self.overview = overview
        self.durationMs = durationMs
    }
}

public enum WaveformError: Error, CustomStringConvertible {
    case cannotOpen(URL, Error)
    case empty(URL)
    public var description: String {
        switch self {
        case .cannotOpen(let u, let e): return "cannot open \(u.lastPathComponent): \(e.localizedDescription)"
        case .empty(let u): return "no audio in \(u.lastPathComponent)"
        }
    }

    /// For the log: what went wrong, never the file's name (the log goes into problem reports).
    public var kind: String {
        switch self {
        case .cannotOpen(_, let e): return "cannot open the file (\((e as NSError).domain) \((e as NSError).code))"
        case .empty: return "no audio in the file"
        }
    }
}

/// Second-order filter (RBJ audio EQ cookbook), direct form I.
struct Biquad {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func lowPass(_ f: Double, rate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    static func highPass(_ f: Double, rate: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * f / rate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    @inline(__always) mutating func run(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

public enum WaveformBuilder {
    /// Band edges in Hz: low below 200, mid 200-2500, high above 2500 (concept 5.2).
    static let lowEdge = 200.0, highEdge = 2500.0

    /// Decodes the file (macOS decodes MP3, AAC/M4A, ALAC, WAV, AIFF and FLAC) and builds both waveforms.
    /// Reads the file only; the audio never leaves this function.
    public static func build(from url: URL) throws -> Waveforms {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw WaveformError.cannotOpen(url, error) }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        let total = file.length
        guard total > 0, channels > 0 else { throw WaveformError.empty(url) }

        let perFrame = rate / Double(Waveforms.detailRate)
        let frameCount = Int((Double(total) / perFrame).rounded(.up))
        var low = [Float](repeating: 0, count: frameCount)
        var mid = [Float](repeating: 0, count: frameCount)
        var high = [Float](repeating: 0, count: frameCount)

        var lp = Biquad.lowPass(lowEdge, rate: rate)
        var hpMid = Biquad.highPass(lowEdge, rate: rate)
        var lpMid = Biquad.lowPass(highEdge, rate: rate)
        var hp = Biquad.highPass(highEdge, rate: rate)

        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw WaveformError.empty(url) }
        var sampleIndex: Int64 = 0
        var sumL = 0.0, sumM = 0.0, sumH = 0.0, n = 0
        var frame = 0
        var nextBoundary = perFrame

        func flush() {
            guard n > 0, frame < frameCount else { return }
            // RMS per band; sqrt(2) brings a sine to its peak, which is closer to how player waveforms look.
            let k = 1.0 / Double(n)
            low[frame] = Float((sumL * k).squareRoot() * 1.4142)
            mid[frame] = Float((sumM * k).squareRoot() * 1.4142)
            high[frame] = Float((sumH * k).squareRoot() * 1.4142)
            sumL = 0; sumM = 0; sumH = 0; n = 0
        }

        while file.framePosition < total {
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let len = Int(buf.frameLength)
            if len == 0 { break }
            guard let data = buf.floatChannelData else { break }
            for i in 0..<len {
                var x = 0.0
                for c in 0..<channels { x += Double(data[c][i]) }
                x /= Double(channels)
                let l = lp.run(x)
                let m = lpMid.run(hpMid.run(x))
                let h = hp.run(x)
                sumL += l * l; sumM += m * m; sumH += h * h; n += 1
                sampleIndex += 1
                if Double(sampleIndex) >= nextBoundary {
                    flush()
                    frame += 1
                    nextBoundary += perFrame
                }
            }
        }
        flush()

        // Each band is scaled to its own loud level (99th percentile, so a single click does not shrink the rest) and
        // then weighted, so the picture nests like a CDJ-3000 three-band waveform: low (blue) outside, mid (amber),
        // high (white) inside. LJ Link paints low, then mid, then high on top (app.js drawDetail).
        let refs = [low, mid, high].map { percentile($0, 0.99) }
        var detail = [UInt8](repeating: 0, count: frameCount * 4)
        for i in 0..<frameCount {
            for (b, band) in [low, mid, high].enumerated() {
                let v = min(1, band[i] / refs[b]) * bandWeight[b]
                detail[i * 4 + b] = UInt8((v * 255).rounded())
            }
        }
        return Waveforms(detail: detail, overview: overview(of: detail, count: Waveforms.overviewCount),
                         durationMs: Int64(Double(total) / rate * 1000))
    }

    /// Height of low, mid and high at their loud level (fraction of the full height).
    static let bandWeight: [Float] = [1.0, 0.75, 0.5]

    static func percentile(_ v: [Float], _ p: Double) -> Float {
        let s = v.filter { $0 > 0 }.sorted()
        guard !s.isEmpty else { return 1e-9 }
        return max(1e-9, s[min(s.count - 1, Int(Double(s.count - 1) * p))])
    }

    /// Overview in LJ Link's three-band preview format: cumulative heights (low, low+mid, low+mid+high), painted from
    /// the outermost to the innermost (app.js drawOverview). Per slice of the track the loudest value of each band.
    public static func overview(of detail: [UInt8], count: Int) -> [UInt8] {
        let frames = detail.count / 4
        guard frames > 0 else { return [] }
        // Stacked: low, low + mid, low + mid + high; the loudest slice's sum fills the full height, so the outer
        // rings (mid, high) keep their room instead of being cut off at 255.
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: count)
        var top = 1.0
        for o in 0..<count {
            let a = o * frames / count, b = max(a + 1, (o + 1) * frames / count)
            var m = [Double](repeating: 0, count: 3)
            for f in a..<min(b, frames) { for band in 0..<3 { m[band] = max(m[band], Double(detail[f * 4 + band])) } }
            sums[o] = (m[0], m[0] + m[1], m[0] + m[1] + m[2])
            top = max(top, sums[o].2)
        }
        var out = [UInt8](repeating: 0, count: count * 4)
        for o in 0..<count {
            out[o * 4] = UInt8((sums[o].0 / top * 255).rounded())
            out[o * 4 + 1] = UInt8((sums[o].1 / top * 255).rounded())
            out[o * 4 + 2] = UInt8((sums[o].2 / top * 255).rounded())
        }
        return out
    }
}
