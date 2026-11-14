import CoreGraphics
import Foundation

/// Reads Serato's time display ("04:18.3", "-03:09:9") without Vision once it has learned one field.
///
/// Serato draws the time with fixed-width digits, so every character of a field always sits at the same place (the
/// same "slot"). The reader takes the slots once from Vision (which reports where each character is), and the digit
/// shapes from Vision readings of this very field. Then each frame it cuts every digit slot out of the binarised crop
/// and compares it with the learned shapes. Splitting the text at gaps does not work here: at 1× the small digits and
/// the colon touch. Anything unsure returns nil; the caller asks Vision again and teaches the reader with the answer.
/// Vision costs 20-40 ms per field, this well under 1 ms.
public final class DigitReader {
    static let glyphW = 12, glyphH = 18
    /// "dd:dd.d" or "-dd:dd:d": the characters that are not digits, digits as "d".
    private(set) var format: [Character] = []
    /// Per character: x range in the tight crop (pixels).
    private(set) var slots: [ClosedRange<Int>] = []
    private(set) var cropWidth = 0
    /// Rows of the text line in the binarised crop (fixed, so a needle crossing the field cannot stretch a glyph).
    private(set) var band: ClosedRange<Int> = 0...0
    /// Shapes per digit "0"..."9" (up to 6 variants each, e.g. with and without the platter needle near it).
    private(set) var templates: [Character: [[UInt8]]] = [:]
    public var learnedDigits: Int { templates.count }
    /// Reads only once all 10 digits are known: an unknown digit would be taken for the most similar known one (a 9
    /// read as 3 in the tests). A playing deck shows every digit in its seconds and tenths within 10-20 s. The caller
    /// also checks every 20th own reading against Vision (ScreenTimeReader.read).
    public var ready: Bool { templates.count == 10 && !slots.isEmpty }

    /// Forgets everything (after own readings disagreed with Vision).
    public func reset() { format = []; slots = []; templates = [:]; cropWidth = 0 }

    public init() {}

    /// Binarised crop at its own size: 1 = text. The text colour is the minority (dark digits on Serato's white
    /// platter, light digits on the dark stack/library rows); the cut is Otsu's threshold.
    /// Crops are enlarged 3× first: at 1× the digits are only about 8 px wide and the gaps between them 1 px.
    static let upscale = 3

    public static func binarise(_ cg: CGImage) -> (bits: [UInt8], w: Int, h: Int)? {
        let w = cg.width * upscale, h = cg.height * upscale
        guard w >= 4, h >= 4 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hist = [Int](repeating: 0, count: 256)
        for g in gray { hist[Int(g)] += 1 }
        let total = gray.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, cut = 128
        for t in 0..<256 {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; cut = t }
        }
        let dark = gray.filter { Int($0) <= cut }.count
        let darkText = dark < total / 2
        // CGContext rows run bottom-up; flip so row 0 is the top (matches Vision's boxes after conversion).
        var bits = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let g = Int(gray[(h - 1 - y) * w + x])
                bits[y * w + x] = darkText ? (g <= cut ? 1 : 0) : (g > cut ? 1 : 0)
            }
        }
        return (bits, w, h)
    }

    /// One slot, sampled in a fixed box (slot × text band) to glyphW × glyphH. Fixed instead of the ink's own box:
    /// the platter needle crossing the digits would stretch an ink box. nil if the slot has no ink at all.
    static func glyph(_ b: (bits: [UInt8], w: Int, h: Int), _ slot: ClosedRange<Int>, band: ClosedRange<Int>) -> [UInt8]? {
        let x0 = max(0, slot.lowerBound), x1 = min(b.w - 1, slot.upperBound)
        let y0 = max(0, band.lowerBound), y1 = min(b.h - 1, band.upperBound)
        guard x1 > x0, y1 > y0 else { return nil }
        var bm = [UInt8](repeating: 0, count: glyphW * glyphH)
        var ink = 0
        for gy in 0..<glyphH {
            for gx in 0..<glyphW {
                // Majority of the source cell, not one sample: robust against 1-px shifts.
                let sx0 = x0 + gx * (x1 - x0 + 1) / glyphW, sx1 = max(sx0, x0 + (gx + 1) * (x1 - x0 + 1) / glyphW - 1)
                let sy0 = y0 + gy * (y1 - y0 + 1) / glyphH, sy1 = max(sy0, y0 + (gy + 1) * (y1 - y0 + 1) / glyphH - 1)
                var on = 0, all = 0
                for y in sy0...sy1 { for x in sx0...sx1 { on += Int(b.bits[y * b.w + x]); all += 1 } }
                if on * 2 >= all { bm[gy * glyphW + gx] = 1; ink += 1 }
            }
        }
        return ink > 0 ? bm : nil
    }

    /// Text rows: rows where at least 4 % of the columns carry ink.
    static func textBand(_ b: (bits: [UInt8], w: Int, h: Int)) -> ClosedRange<Int>? {
        var rows: [Int] = []
        for y in 0..<b.h {
            var n = 0
            for x in 0..<b.w { n += Int(b.bits[y * b.w + x]) }
            if n * 25 >= b.w { rows.append(y) }
        }
        guard let a = rows.first, let z = rows.last, z > a else { return nil }
        return a...z
    }

    /// Slots for a known format: digits share one width, colon/dot are narrower (ratio r), a minus has its own ratio m.
    /// Tries the ratios and keeps the split whose cuts cross the least ink. (Vision's per-character boxes are not
    /// usable: it reports the whole line's box for every character.)
    static func fitSlots(_ b: (bits: [UInt8], w: Int, h: Int), _ fmt: [Character], within: ClosedRange<Int>) -> [ClosedRange<Int>]? {
        var cols = [Int](repeating: 0, count: b.w)
        for y in 0..<b.h { for x in 0..<b.w where b.bits[y * b.w + x] == 1 { cols[x] += 1 } }
        // Ink extent inside Vision's line box (the box itself is a little loose).
        let lo = max(0, within.lowerBound), hi = min(b.w - 1, within.upperBound)
        guard hi > lo, let x0 = (lo...hi).first(where: { cols[$0] > 0 }), let x1 = (lo...hi).last(where: { cols[$0] > 0 }),
              x1 - x0 > fmt.count * 2 else { return nil }
        let total = Double(x1 - x0 + 1)
        let digits = Double(fmt.filter { $0 == "d" }.count)
        let puncts = Double(fmt.filter { $0 == ":" || $0 == "." }.count)
        let minus = fmt.contains("-")
        var best: (cost: Int, cuts: [Int])?
        for r in stride(from: 0.2, through: 0.8, by: 0.02) {
            for m in (minus ? Array(stride(from: 0.4, through: 1.1, by: 0.05)) : [0.0]) {
                let wd = total / (digits + puncts * r + (minus ? m : 0))
                var x = Double(x0)
                var cuts: [Int] = []
                for c in fmt {
                    x += c == "d" ? wd : (c == "-" ? wd * m : wd * r)
                    cuts.append(Int(x.rounded()))
                }
                cuts.removeLast()
                let cost = cuts.reduce(0) { $0 + (0 < $1 && $1 < b.w ? cols[$1] : 0) }
                if best == nil || cost < best!.cost { best = (cost, cuts) }
            }
        }
        guard let cuts = best?.cuts else { return nil }
        let edges = [x0] + cuts + [x1 + 1]
        return (0..<fmt.count).map { edges[$0]...(edges[$0 + 1] - 1) }
    }

    /// Template `a` against glyph `b`: missing ink counts 3, extra ink 1 (the needle adds ink, it never removes any).
    static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var d = 0
        for i in 0..<a.count where a[i] != b[i] { d += a[i] == 1 ? 3 : 1 }
        return d
    }

    /// Reads the tight crop, or nil when unsure (then the caller uses Vision).
    public func read(_ cg: CGImage) -> String? {
        guard ready, cg.width == cropWidth, let b = DigitReader.binarise(cg) else { return nil }
        var out = ""
        for (c, slot) in zip(format, slots) {
            guard c == "d" else { out.append(c); continue }
            guard let g = DigitReader.glyph(b, slot, band: band) else { return nil }
            var best: (Character, Int)?
            var second = Int.max
            for (digit, list) in templates {
                let d = list.map { DigitReader.distance($0, g) }.min() ?? Int.max
                if best == nil || d < best!.1 { if let bb = best { second = min(second, bb.1) }; best = (digit, d) }
                else { second = min(second, d) }
            }
            // Close to a learned shape, and clearly closer than to any other digit.
            guard let bst = best, bst.1 <= 54, second - bst.1 >= 14 else { return nil }
            out.append(bst.0)
        }
        return TimeFields.parse(out) != nil ? out : nil
    }

    /// Learns from Vision's reading of the same field. `charBoxes`: per character of `text` (spaces removed) its x
    /// range in the tight crop, from Vision. The slots are taken once; the digit shapes on every call.
    /// `line`: x range of the recognised text in `cg` (Vision's line box).
    public func learn(_ cg: CGImage, text: String, line: ClosedRange<Int>) {
        let chars = Array(text.filter { !$0.isWhitespace })
        guard TimeFields.parse(text) != nil,
              String(chars).range(of: #"^-?\d{1,2}:\d{2}[.:]\d$"#, options: .regularExpression) != nil,
              let b = DigitReader.binarise(cg) else { return }
        let fmt = chars.map { $0.isNumber ? Character("d") : $0 }
        if slots.isEmpty || fmt != format || cg.width != cropWidth {
            // New or changed layout of the field (e.g. 9:59.9 → 10:00.0 would add a digit): find the slots anew.
            let u = DigitReader.upscale
            guard let fitted = DigitReader.fitSlots(b, fmt, within: (line.lowerBound * u)...(line.upperBound * u + u - 1)),
                  let bd = DigitReader.textBand(b) else { return }
            format = fmt
            slots = fitted
            band = bd
            cropWidth = cg.width
            templates = [:]
        }
        for (c, slot) in zip(chars, slots) where c.isNumber {
            guard let g = DigitReader.glyph(b, slot, band: band) else { continue }
            var list = templates[c] ?? []
            if !list.contains(where: { DigitReader.distance($0, g) <= 9 }) {
                list.append(g)
                if list.count > 6 { list.removeFirst() }
            }
            templates[c] = list
        }
    }
}
