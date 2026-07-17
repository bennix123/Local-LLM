// PDFFont — simple-font model for the MuPDF-parity text extractor.
// Handles Type1/TrueType single-byte fonts: Widths arrays, WinAnsi/Differences
// encodings, ToUnicode CMaps, and base-14 fallbacks. (CID/Type0 fonts don't
// appear in bank statements we've seen; codes are one byte.)
import Foundation
import CoreGraphics

final class PDFFont {
    let baseFont: String          // subset prefix stripped ("ABCDEF+Foo" -> "Foo")
    var widths: [Int: Double] = [:]      // code -> advance (em fraction)
    var missingWidth: Double = 0
    var toUnicode: [Int: String] = [:]   // code -> unicode string
    var differences: [Int: String] = [:] // code -> glyph name
    var isWinAnsi = true                 // base encoding (fixtures use WinAnsi; Standard≈same for ASCII)
    let ascender: Double
    let descender: Double
    let base14Widths: [Double]?

    init(dict: CGPDFDictionaryRef) {
        var namePtr: UnsafePointer<Int8>? = nil
        var base = "Helvetica"
        if CGPDFDictionaryGetName(dict, "BaseFont", &namePtr), let p = namePtr {
            base = String(cString: p)
        }
        if base.count > 7, base[base.index(base.startIndex, offsetBy: 6)] == "+" {
            base = String(base.dropFirst(7))   // strip subset tag
        }
        self.baseFont = base
        self.base14Widths = Base14.widthTables[base]
        let m = Base14.metrics[base] ?? Base14.defaultMetrics
        self.ascender = m.ascender
        self.descender = m.descender

        // Widths + FirstChar
        var firstChar: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(dict, "FirstChar", &firstChar)
        var arr: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(dict, "Widths", &arr), let arr {
            let n = CGPDFArrayGetCount(arr)
            for i in 0..<n {
                var v: CGPDFReal = 0
                var iv: CGPDFInteger = 0
                if CGPDFArrayGetNumber(arr, i, &v) {
                    widths[Int(firstChar) + i] = Double(v) / 1000.0
                } else if CGPDFArrayGetInteger(arr, i, &iv) {
                    widths[Int(firstChar) + i] = Double(iv) / 1000.0
                }
            }
        }

        // FontDescriptor / MissingWidth
        var fd: CGPDFDictionaryRef? = nil
        if CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &fd), let fd {
            var mw: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(fd, "MissingWidth", &mw) { missingWidth = Double(mw) / 1000.0 }
        }

        // Encoding: name or dict {BaseEncoding, Differences}
        var encName: UnsafePointer<Int8>? = nil
        if CGPDFDictionaryGetName(dict, "Encoding", &encName), let p = encName {
            isWinAnsi = String(cString: p) != "MacRomanEncoding"
        } else {
            var encDict: CGPDFDictionaryRef? = nil
            if CGPDFDictionaryGetDictionary(dict, "Encoding", &encDict), let encDict {
                var diffs: CGPDFArrayRef? = nil
                if CGPDFDictionaryGetArray(encDict, "Differences", &diffs), let diffs {
                    var code = 0
                    for i in 0..<CGPDFArrayGetCount(diffs) {
                        var iv: CGPDFInteger = 0
                        var np: UnsafePointer<Int8>? = nil
                        if CGPDFArrayGetInteger(diffs, i, &iv) {
                            code = Int(iv)
                        } else if CGPDFArrayGetName(diffs, i, &np), let np {
                            differences[code] = String(cString: np)
                            code += 1
                        }
                    }
                }
            }
        }

        // ToUnicode CMap
        var stream: CGPDFStreamRef? = nil
        if CGPDFDictionaryGetStream(dict, "ToUnicode", &stream), let stream {
            var fmt = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &fmt) as Data? ,
               let text = String(data: data, encoding: .isoLatin1) {
                parseToUnicode(text)
            }
        }
    }

    private func parseToUnicode(_ text: String) {
        // bfchar: <src> <dst>; bfrange: <lo> <hi> <dstStart> | <lo> <hi> [<dst>...]
        let hexToken = PyRegex("<([0-9A-Fa-f]+)>")
        func scalars(fromHex hex: String) -> String {
            var s = ""
            var i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
                if let v = UInt32(hex[i..<j], radix: 16), let sc = Unicode.Scalar(v) {
                    s.unicodeScalars.append(sc)
                }
                i = j
            }
            return s
        }
        // bfchar sections
        for section in extractSections(text, "beginbfchar", "endbfchar") {
            let toks = hexToken.findall(section)
            var i = 0
            while i + 1 < toks.count {
                if let code = Int(toks[i], radix: 16) {
                    toUnicode[code] = scalars(fromHex: toks[i + 1])
                }
                i += 2
            }
        }
        // bfrange sections (contiguous form only; array form is rare and absent here)
        for section in extractSections(text, "beginbfrange", "endbfrange") {
            let toks = hexToken.findall(section)
            var i = 0
            while i + 2 < toks.count {
                if let lo = Int(toks[i], radix: 16), let hi = Int(toks[i + 1], radix: 16),
                   let dst = UInt32(toks[i + 2], radix: 16) {
                    for c in lo...max(lo, hi) {
                        if let sc = Unicode.Scalar(dst + UInt32(c - lo)) {
                            toUnicode[c] = String(Character(sc))
                        }
                    }
                }
                i += 3
            }
        }
    }

    private func extractSections(_ text: String, _ open: String, _ close: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let r0 = rest.range(of: open) {
            let after = rest[r0.upperBound...]
            guard let r1 = after.range(of: close) else { break }
            out.append(String(after[..<r1.lowerBound]))
            rest = after[r1.upperBound...]
        }
        return out
    }

    /// Unicode string for a byte code (MuPDF precedence: ToUnicode, then glyph
    /// name from Differences, then the base encoding table).
    func unicode(for code: Int) -> String {
        if let u = toUnicode[code] { return u }
        if let g = differences[code], let u = Self.glyphNameToUnicode(g) { return u }
        let table = Base14.winAnsi
        if code < table.count, table[code] != 0xFFFD, let sc = Unicode.Scalar(UInt32(table[code])) {
            return String(Character(sc))
        }
        return "\u{FFFD}"
    }

    /// Glyph advance for a byte code, as a fraction of em.
    func advance(for code: Int) -> Double {
        if let w = widths[code] { return w }
        if let t = base14Widths, code < t.count { return t[code] }
        return missingWidth
    }

    static func glyphNameToUnicode(_ name: String) -> String? {
        if name.count == 1, let ch = name.first, ch.isLetter { return String(ch) }
        if name.hasPrefix("uni"), name.count >= 7,
           let v = UInt32(name.dropFirst(3).prefix(4), radix: 16), let sc = Unicode.Scalar(v) {
            return String(Character(sc))
        }
        if name.hasPrefix("u"), name.count >= 5, name.count <= 7,
           let v = UInt32(name.dropFirst(1), radix: 16), let sc = Unicode.Scalar(v) {
            return String(Character(sc))
        }
        return agl[name]
    }

    /// Compact Adobe Glyph List subset (ASCII + common latin punctuation/currency).
    static let agl: [String: String] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$",
        "percent": "%", "ampersand": "&", "quotesingle": "'", "parenleft": "(", "parenright": ")",
        "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "period": ".", "slash": "/",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "colon": ":", "semicolon": ";", "less": "<",
        "equal": "=", "greater": ">", "question": "?", "at": "@", "bracketleft": "[",
        "backslash": "\\", "bracketright": "]", "asciicircum": "^", "underscore": "_",
        "grave": "`", "braceleft": "{", "bar": "|", "braceright": "}", "asciitilde": "~",
        "sterling": "\u{00A3}", "yen": "\u{00A5}", "cent": "\u{00A2}", "currency": "\u{00A4}",
        "Euro": "\u{20AC}", "degree": "\u{00B0}", "bullet": "\u{2022}", "endash": "\u{2013}",
        "emdash": "\u{2014}", "quoteleft": "\u{2018}", "quoteright": "\u{2019}",
        "quotedblleft": "\u{201C}", "quotedblright": "\u{201D}", "ellipsis": "\u{2026}",
        "copyright": "\u{00A9}", "registered": "\u{00AE}", "trademark": "\u{2122}",
        "section": "\u{00A7}", "paragraph": "\u{00B6}", "middot": "\u{00B7}",
        "periodcentered": "\u{00B7}", "multiply": "\u{00D7}", "divide": "\u{00F7}",
        "nbspace": "\u{00A0}",
    ]
}
