//
//  LocalBinaryScanner.swift
//  SIPA / msign
//
//  On-device replacement for msign.party/api/avx/scan. Extracts the app's
//  main Mach-O, reads the __TEXT,__cstring (and __objc_methname) string
//  tables, and categorises each string with paywall / settings / watermark
//  heuristics — no server. Also exposes Mach-O segment tools so binary
//  patches can be applied locally (VA → file offset).
//

import Foundation
import ZIPFoundation

// MARK: - Scan hit models (ported from mSign IPAScanView; local-only, no server)

struct AVXScanHit: Identifiable, Decodable, Hashable {
    let id:       Int
    let address:  String
    let string:   String
    let category: String      // "settings" | "premium" | "other"
    let score:    Int
    let kind:     String?
    let section:  String?
    let bytes:    String?
    let mnemonic: String?
    let operands: String?
    let xref:     String?
    var editable:   String? = nil   // "yes" | "limited" | "resource" | "no"
    var editReason: String? = nil
}

struct AVXScanStats: Decodable {
    let total:    Int
    let settings: Int
    let premium:  Int
    let other:    Int
    var breakdown:     [String: Int]? = nil
    var editableCount: Int? = nil
    var riskyCount:    Int? = nil
}


// MARK: - Low-level little/big-endian Data reads (alignment-safe)

private extension Data {
    func u32le(_ off: Int) -> UInt32 {
        let i = startIndex + off
        guard i + 4 <= endIndex else { return 0 }
        return UInt32(self[i]) | (UInt32(self[i+1]) << 8) | (UInt32(self[i+2]) << 16) | (UInt32(self[i+3]) << 24)
    }
    func u64le(_ off: Int) -> UInt64 { UInt64(u32le(off)) | (UInt64(u32le(off + 4)) << 32) }
    func u32be(_ off: Int) -> UInt32 {
        let i = startIndex + off
        guard i + 4 <= endIndex else { return 0 }
        return (UInt32(self[i]) << 24) | (UInt32(self[i+1]) << 16) | (UInt32(self[i+2]) << 8) | UInt32(self[i+3])
    }
    func cString(at off: Int, max: Int) -> String? {
        let s = startIndex + off
        guard s < endIndex else { return nil }
        var e = s
        let limit = Swift.min(s + max, endIndex)
        while e < limit, self[e] != 0 { e = index(after: e) }
        guard e > s else { return nil }
        return String(data: self[s..<e], encoding: .utf8)
    }
}

// MARK: - Mach-O tools (shared by scanner + patcher)

enum MachOTools {

    struct Section { let segment: String; let name: String; let addr: UInt64; let offset: UInt64; let size: UInt64 }
    struct Segment { let name: String; let vmaddr: UInt64; let vmsize: UInt64; let fileoff: UInt64; let filesize: UInt64 }

    /// Return the arm64 slice of a fat binary (or the data itself if thin).
    static func thinArm64(_ data: Data) -> Data {
        guard data.count > 8 else { return data }
        let magic = data.u32be(0)
        guard magic == 0xCAFEBABE else { return data }   // not fat → already thin
        let n = Int(data.u32be(4))
        var first: Data?
        for i in 0..<n {
            let base = 8 + i * 20
            guard base + 20 <= data.count else { break }
            let cpu = Int32(bitPattern: data.u32be(base))
            let off = Int(data.u32be(base + 8))
            let sz  = Int(data.u32be(base + 12))
            guard off >= 0, sz > 0, off + sz <= data.count else { continue }
            let slice = data.subdata(in: off..<off + sz)
            if first == nil { first = slice }
            if cpu == 0x0100000C { return slice }   // CPU_TYPE_ARM64
        }
        return first ?? data
    }

    private static func is64(_ d: Data) -> Bool {
        let m = d.u32le(0); return m == 0xFEEDFACF
    }

    static func sections(in thin: Data) -> [Section] {
        guard is64(thin) else { return [] }
        var out: [Section] = []
        let ncmds = Int(thin.u32le(16))
        var off = 32
        for _ in 0..<ncmds {
            guard off + 8 <= thin.count else { break }
            let cmd = thin.u32le(off); let size = Int(thin.u32le(off + 4))
            guard size >= 8, off + size <= thin.count else { break }
            if cmd == 0x19 {   // LC_SEGMENT_64
                let segName = thin.cString(at: off + 8, max: 16) ?? ""
                let nsects = Int(thin.u32le(off + 64))
                var s = off + 72
                for _ in 0..<nsects {
                    guard s + 80 <= thin.count else { break }
                    let sect = thin.cString(at: s, max: 16) ?? ""
                    let addr = thin.u64le(s + 32)
                    let secsize = thin.u64le(s + 40)
                    let offset = UInt64(thin.u32le(s + 48))
                    out.append(Section(segment: segName, name: sect, addr: addr, offset: offset, size: secsize))
                    s += 80
                }
            }
            off += size
        }
        return out
    }

    static func segments(in thin: Data) -> [Segment] {
        guard is64(thin) else { return [] }
        var out: [Segment] = []
        let ncmds = Int(thin.u32le(16))
        var off = 32
        for _ in 0..<ncmds {
            guard off + 8 <= thin.count else { break }
            let cmd = thin.u32le(off); let size = Int(thin.u32le(off + 4))
            guard size >= 8, off + size <= thin.count else { break }
            if cmd == 0x19 {
                out.append(Segment(
                    name:     thin.cString(at: off + 8, max: 16) ?? "",
                    vmaddr:   thin.u64le(off + 24),
                    vmsize:   thin.u64le(off + 32),
                    fileoff:  thin.u64le(off + 40),
                    filesize: thin.u64le(off + 48)))
            }
            off += size
        }
        return out
    }

    /// Map a virtual address to a file offset *within the thin slice*.
    static func fileOffset(forVA va: UInt64, segments: [Segment]) -> Int? {
        for s in segments where va >= s.vmaddr && va < s.vmaddr + s.filesize {
            return Int(s.fileoff + (va - s.vmaddr))
        }
        return nil
    }

    /// Extract the __TEXT,__text code section data + its VM address.
    static func textSection(_ sections: [Section], in thin: Data) -> (data: Data, vmaddr: UInt64)? {
        guard let s = sections.first(where: { $0.segment == "__TEXT" && $0.name == "__text" }) else { return nil }
        let start = thin.startIndex + Int(s.offset)
        let end = Swift.min(start + Int(s.size), thin.endIndex)
        guard start < end else { return nil }
        return (thin.subdata(in: start..<end), s.addr)
    }

    /// Return the arm64 slice AND its base offset inside the original (possibly
    /// fat) file, so a slice-relative file offset can be turned back into an
    /// offset in the on-disk binary for patching.
    static func arm64SliceWithOffset(_ data: Data) -> (slice: Data, base: Int) {
        guard data.count > 8, data.u32be(0) == 0xCAFEBABE else { return (data, 0) }
        let n = Int(data.u32be(4))
        var first: (Data, Int)?
        for i in 0..<n {
            let b = 8 + i * 20
            guard b + 20 <= data.count else { break }
            let cpu = Int32(bitPattern: data.u32be(b))
            let off = Int(data.u32be(b + 8))
            let sz  = Int(data.u32be(b + 12))
            guard off >= 0, sz > 0, off + sz <= data.count else { continue }
            let slice = data.subdata(in: off..<off + sz)
            if first == nil { first = (slice, off) }
            if cpu == 0x0100000C { return (slice, off) }
        }
        return first ?? (data, 0)
    }
}

// MARK: - Scanner

enum LocalBinaryScanner {

    struct ScanResult { let hits: [AVXScanHit]; let stats: AVXScanStats; let elapsedMs: Int }

    static func scan(ipaURL: URL?, localPath: String?) async -> ScanResult? {
        let start = Date()
        guard let url = await resolveURL(ipaURL: ipaURL, localPath: localPath),
              let archive = Archive(url: url, accessMode: .read),
              let binary = mainBinaryData(from: archive) else { return nil }
        let thin = MachOTools.thinArm64(binary)
        let sections = MachOTools.sections(in: thin)
        let segments = MachOTools.segments(in: thin)

        var hits: [AVXScanHit] = []
        var id = 0
        var breakdown: [String: Int] = [:]
        var settings = 0, premium = 0, other = 0
        let cap = 100_000          // effectively unlimited; UI renders lazily

        func add(_ s: String, va: String, section: String, kind: String, editable: String, reason: String) {
            guard hits.count < cap, isPrintable(s) else { return }
            id += 1
            let (c, score) = categorize(s) ?? ("other", 1)
            var k = kind, why = reason
            // Runtime/remote signal — the value is fetched at runtime, but the
            // endpoint/config key is statically visible (and, in a cstring,
            // redirectable).
            if isRemoteString(s) {
                k = "remote"
                why = editable == "yes"
                    ? "Remote endpoint — runtime value isn't static, but this URL/key is editable (redirectable)"
                    : "Remote/runtime — value fetched at runtime; endpoint is visible"
            }
            hits.append(AVXScanHit(id: id, address: va, string: s, category: c, score: score,
                kind: k, section: section, bytes: nil, mnemonic: nil, operands: nil, xref: nil,
                editable: editable, editReason: why))
            switch c { case "premium": premium += 1; case "settings": settings += 1; default: other += 1 }
            breakdown[k, default: 0] += 1
        }

        // 1. UTF-8 null-terminated string tables (classic + ObjC + Swift refl).
        let utf8Tables: [(name: String, kind: String)] = [
            ("__cstring", "cstring"), ("__objc_methname", "objc-sel"),
            ("__objc_classname", "objc-class"), ("__objc_methtype", "objc-type"),
            ("__oslogstring", "oslog"), ("__swift5_reflstr", "swift-refl"),
        ]
        for t in utf8Tables {
            guard let sec = sections.first(where: { $0.name == t.name }) else { continue }
            let (ed, why) = editability(t.kind)
            scanUTF8(thin, sec) { s, off in
                add(s, va: String(format: "0x%llx", sec.addr + UInt64(off)),
                    section: "\(sec.segment)/\(t.name)", kind: t.kind, editable: ed, reason: why)
            }
        }
        // 2. UTF-16 string table.
        if let sec = sections.first(where: { $0.name == "__ustring" }) {
            scanUTF16(thin, sec) { s, off in
                add(s, va: String(format: "0x%llx", sec.addr + UInt64(off)),
                    section: "\(sec.segment)/__ustring", kind: "ustring", editable: "yes",
                    reason: "UTF-16 string — in-place patch (≤ original length)")
            }
        }
        // 3. __cfstring (NSString literals) — resolve each struct's data pointer.
        if let sec = sections.first(where: { $0.name == "__cfstring" }) {
            scanCFString(thin, sec, segments: segments) { s, va in
                add(s, va: String(format: "0x%llx", va),
                    section: "\(sec.segment)/__cfstring", kind: "cfstring", editable: "yes",
                    reason: "CFString literal — backing bytes are in-place editable")
            }
        }
        // 4. Resources, compiled NIB/Storyboard, and Assets.car.
        scanResources(archive) { s, file, source in
            let prefix: String, ed: String, why: String
            switch source {
            case "nib":    prefix = "nib";    ed = "limited";  why = "Compiled NIB — binary-plist string, in-place edit only"
            case "assets": prefix = "assets"; ed = "limited";  why = "Assets.car — compiled catalog name, not freely editable"
            default:       prefix = "resource"; ed = "resource"; why = "Resource file — can be rewritten freely"
            }
            add(s, va: "—", section: "\(prefix):\(file)", kind: source, editable: ed, reason: why)
        }

        var stats = AVXScanStats(total: hits.count, settings: settings, premium: premium, other: other)
        stats.breakdown     = breakdown
        stats.editableCount = hits.filter { $0.editable == "yes" || $0.editable == "resource" }.count
        stats.riskyCount    = hits.filter { $0.editable == "limited" }.count
        return ScanResult(hits: hits, stats: stats, elapsedMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    // MARK: Section editability + filters

    private static func editability(_ kind: String) -> (String, String) {
        switch kind {
        case "cstring", "cfstring", "ustring", "objc-sel", "objc-class", "objc-type", "oslog":
            return ("yes", "C/CF/ObjC string — in-place patch (≤ original length)")
        case "swift-refl", "swift", "const":
            return ("limited", "Swift reflection / const — patch is risky, verify first")
        default:
            return ("limited", "Verify before patching")
        }
    }

    private static func isPrintable(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 400, s.rangeOfCharacter(from: .letters) != nil else { return false }
        let ok = s.unicodeScalars.filter { ($0.value >= 0x20 && $0.value < 0x7F) || $0.value > 0xA0 }.count
        return ok * 4 >= s.unicodeScalars.count * 3   // ≥75% printable
    }

    // MARK: Section readers

    private static func scanUTF8(_ thin: Data, _ sec: MachOTools.Section, _ emit: (String, Int) -> Void) {
        let secStart = Int(sec.offset)
        let secEnd = Swift.min(secStart + Int(sec.size), thin.count)
        guard secStart < secEnd else { return }
        var p = secStart
        while p < secEnd {
            guard let s = thin.cString(at: p, max: 512), !s.isEmpty else { p += 1; continue }
            emit(s, p - secStart)
            p += s.utf8.count + 1
        }
    }

    private static func scanUTF16(_ thin: Data, _ sec: MachOTools.Section, _ emit: (String, Int) -> Void) {
        let base = thin.startIndex
        let secStart = base + Int(sec.offset)
        let secEnd = Swift.min(secStart + Int(sec.size), thin.endIndex)
        guard secStart + 1 < secEnd else { return }
        var p = secStart
        while p + 1 < secEnd {
            var units: [UInt16] = []
            var q = p
            while q + 1 < secEnd {
                let u = UInt16(thin[q]) | (UInt16(thin[q+1]) << 8)
                if u == 0 { break }
                units.append(u); q += 2
                if units.count > 1024 { break }
            }
            if !units.isEmpty { emit(String(utf16CodeUnits: units, count: units.count), p - secStart) }
            p = q + 2   // skip the 0x0000 terminator
        }
    }

    private static func scanCFString(_ thin: Data, _ sec: MachOTools.Section, segments: [MachOTools.Segment], _ emit: (String, UInt64) -> Void) {
        let entrySize = 32
        let secStart = Int(sec.offset)
        let count = Int(sec.size) / entrySize
        for i in 0..<count {
            let off = secStart + i * entrySize
            guard off + entrySize <= thin.count else { break }
            let flags   = thin.u64le(off + 8)
            let dataPtr = thin.u64le(off + 16)
            let length  = Int(thin.u64le(off + 24))
            guard dataPtr != 0, length > 0, length < 4096,
                  let foff = MachOTools.fileOffset(forVA: dataPtr, segments: segments) else { continue }
            let structVA = sec.addr + UInt64(i * entrySize)
            let unicode = (flags & 0x10) != 0   // CFString info bit 4 = 16-bit
            if unicode {
                guard foff + length * 2 <= thin.count else { continue }
                var units: [UInt16] = []
                var q = thin.startIndex + foff
                for _ in 0..<length { units.append(UInt16(thin[q]) | (UInt16(thin[q+1]) << 8)); q += 2 }
                emit(String(utf16CodeUnits: units, count: units.count), structVA)
            } else {
                guard foff + length <= thin.count else { continue }
                let lo = thin.startIndex + foff
                if let str = String(data: thin.subdata(in: lo..<lo + length), encoding: .utf8) { emit(str, structVA) }
            }
        }
    }

    // MARK: Resource strings

    private static func scanResources(_ archive: Archive, _ emit: (_ string: String, _ file: String, _ source: String) -> Void) {
        var count = 0
        for entry in archive {
            guard count < 100_000 else { break }
            let lower = entry.path.lowercased()
            guard lower.hasPrefix("payload/") else { continue }
            let file = (entry.path as NSString).lastPathComponent

            let isResource = lower.hasSuffix(".strings") || lower.hasSuffix(".stringsdict")
                          || (lower.hasSuffix("/info.plist") && lower.contains(".app/"))
            let isNib = lower.hasSuffix(".nib")     // includes *.storyboardc/*.nib
            let isCar = lower.hasSuffix("assets.car")
            guard isResource || isNib || isCar else { continue }

            var data = Data()
            guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil, !data.isEmpty else { continue }

            if isCar {
                // Compiled asset catalog — proprietary CoreUI format; pull
                // printable runs (rendition/asset names: "paywall_bg", etc.).
                for s in rawStrings(data, minLen: 4) {
                    emit(s, file, "assets"); count += 1; if count >= 100_000 { break }
                }
            } else if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                // .strings / .stringsdict / Info.plist / compiled .nib are all
                // binary/XML plists — walk the object graph for strings.
                collectStrings(obj) { s in
                    if isNib && !isNibUIText(s) { return }
                    emit(s, file, isNib ? "nib" : "resource"); count += 1
                }
            } else if isResource, let text = String(data: data, encoding: .utf8) {
                for v in textStringsValues(text) { emit(v, file, "resource"); count += 1 }
            }
        }
    }

    /// True for URLs / remote-config / feature-flag / GraphQL endpoints — the
    /// statically-visible side of runtime-fetched strings.
    private static func isRemoteString(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("ws://") || l.hasPrefix("wss://") { return true }
        let markers = ["remoteconfig", "remote_config", "firebaseremote", ".firebaseio.", "graphql",
                       "feature_flag", "featureflag", "/api/", "/v1/", "/v2/", "/v3/",
                       "launchdarkly", "optimizely", "experiment", "config.json", "flags.json", "appcenter"]
        return markers.contains { l.contains($0) }
    }

    /// Filter NSKeyedArchiver structural noise + bare framework class names so
    /// NIB results are actual UI text (labels, titles, placeholders).
    private static func isNibUIText(_ s: String) -> Bool {
        if s.hasPrefix("$") || s.hasPrefix("NS.") { return false }
        if s.range(of: #"^_?(UI|NS|CA|CF|_)[A-Z][A-Za-z0-9]*$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Printable-ASCII run extractor for opaque binaries (Assets.car).
    private static func rawStrings(_ data: Data, minLen: Int) -> [String] {
        let bytes = [UInt8](data)
        var out: [String] = []
        var cur: [UInt8] = []; cur.reserveCapacity(64)
        for b in bytes {
            if b >= 0x20 && b < 0x7F { cur.append(b) }
            else {
                if cur.count >= minLen, let s = String(bytes: cur, encoding: .utf8) { out.append(s) }
                cur.removeAll(keepingCapacity: true)
            }
            if out.count >= 5000 { break }
        }
        if cur.count >= minLen, let s = String(bytes: cur, encoding: .utf8) { out.append(s) }
        return out
    }

    private static func collectStrings(_ obj: Any, _ emit: (String) -> Void) {
        switch obj {
        case let s as String where !s.isEmpty: emit(s)
        case let a as [Any]: for v in a { collectStrings(v, emit) }
        case let d as [String: Any]: for (_, v) in d { collectStrings(v, emit) }
        default: break
        }
    }

    private static func textStringsValues(_ text: String) -> [String] {
        // Old-style  "key" = "value";  — pull the quoted values.
        guard let re = try? NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m = m, m.numberOfRanges >= 2 { out.append(ns.substring(with: m.range(at: 1))) }
        }
        return out
    }

    // MARK: Heuristics

    private static let premium = ["premium","subscri","purchase","paywall","unlock","upgrade",
        "in-app","in app","iap","restore","free trial","trial","lifetime","membership",
        "pro version","full version","unlimited","activate","license","entitlement","billing",
        "checkout"," plan","upgrade to","pricing","price","paid","buy "]
    private static let settings = ["setting","preference","account","profile","config","sign in",
        "signin","log in","login","logout","register","general","option","about","privacy",
        "notification","appearance","language","theme","feedback","support"]
    private static let watermark = ["cracked","signed by","crack by"," by @","t.me/","discord.gg",
        "telegram","appdb","scarlet","esign","leaked","@mrzefv","mrzefv","delvek"]

    /// Returns (category, score 0–100) for an interesting string, or nil to skip.
    static func categorize(_ s: String) -> (String, Int)? {
        guard s.count >= 4, s.count <= 256, s.rangeOfCharacter(from: .letters) != nil else { return nil }
        let l = s.lowercased()
        if let k = premium.first(where: l.contains)  { return ("premium",  min(40 + k.count, 100)) }
        if watermark.contains(where: l.contains)     { return ("other",    90) }   // surfaced by WATERMARK filter
        if let k = settings.first(where: l.contains) { return ("settings", min(30 + k.count, 100)) }
        return nil
    }

    // MARK: Main-binary extraction

    /// Cached (thin slice, sections, segments) for the last-scanned binary, so
    /// disasm/xref don't re-extract the executable from the IPA on every call.
    private static var ctxCache: (key: String, thin: Data, sections: [MachOTools.Section], segments: [MachOTools.Segment])?

    /// Applies raw byte patches to the app's main Mach-O on disk. `fileOffset` in each
    /// patch is into the THIN arm64 slice; we add the slice's base offset within the fat
    /// binary so the write lands in the right place. Verifies `original` bytes when provided.
    /// Returns the count successfully written.
    @discardableResult
    static func applyPatches(_ patches: [BinaryPatch], toBinaryAt path: String) -> Int {
        guard !patches.isEmpty, var data = FileManager.default.contents(atPath: path) else { return 0 }
        let (_, base) = MachOTools.arm64SliceWithOffset(data)
        var wrote = 0
        for p in patches {
            let at = base + p.fileOffset
            guard at >= 0, at + p.bytes.count <= data.count else { continue }
            if !p.original.isEmpty {
                let current = Array(data[at ..< at + p.original.count])
                if current != p.original { continue }   // moved / already patched — skip
            }
            for (i, b) in p.bytes.enumerated() { data[at + i] = b }
            wrote += 1
        }
        guard wrote > 0 else { return 0 }
        do { try data.write(to: URL(fileURLWithPath: path)); return wrote } catch { return 0 }
    }

        static func binaryContext(ipaURL: URL?, localPath: String?) async
        -> (thin: Data, sections: [MachOTools.Section], segments: [MachOTools.Segment])? {
        let key = localPath ?? ipaURL?.absoluteString ?? ""
        if let c = ctxCache, c.key == key { return (c.thin, c.sections, c.segments) }
        guard let bin = await mainBinary(ipaURL: ipaURL, localPath: localPath) else { return nil }
        let thin = MachOTools.thinArm64(bin)
        let sections = MachOTools.sections(in: thin)
        let segments = MachOTools.segments(in: thin)
        ctxCache = (key, thin, sections, segments)
        return (thin, sections, segments)
    }


    private static func resolveURL(ipaURL: URL?, localPath: String?) async -> URL? {
        if let p = localPath, !p.isEmpty { return URL(fileURLWithPath: p) }
        if let u = ipaURL, u.isFileURL { return u }
        if let u = ipaURL { return try? await download(u) }
        return nil
    }

    private static func mainBinary(ipaURL: URL?, localPath: String?) async -> Data? {
        guard let url = await resolveURL(ipaURL: ipaURL, localPath: localPath),
              let archive = Archive(url: url, accessMode: .read) else { return nil }
        return mainBinaryData(from: archive)
    }

    /// Extract the app's main Mach-O from an already-open archive.
    private static func mainBinaryData(from archive: Archive) -> Data? {
        for entry in archive {
            let lower = entry.path.lowercased()
            guard lower.hasPrefix("payload/"), lower.hasSuffix(".app/info.plist") else { continue }
            var pdata = Data()
            guard (try? archive.extract(entry, consumer: { pdata.append($0) })) != nil,
                  let plist = (try? PropertyListSerialization.propertyList(from: pdata, options: [], format: nil)) as? [String: Any],
                  let exec = plist["CFBundleExecutable"] as? String, !exec.isEmpty else { return nil }
            let appFolder = (entry.path as NSString).deletingLastPathComponent
            let exePath = "\(appFolder)/\(exec)"
            guard let exeEntry = archive[exePath] ?? archive.first(where: { $0.path.lowercased() == exePath.lowercased() }) else { return nil }
            var bin = Data()
            guard (try? archive.extract(exeEntry, consumer: { bin.append($0) })) != nil else { return nil }
            return bin
        }
        return nil
    }

    private static func download(_ url: URL) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("ipa")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
