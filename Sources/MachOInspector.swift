//
//  MachOInspector.swift
//  Hand-rolled Mach-O reader for the signer. Answers, before you sign:
//    • Is the binary still FairPlay-encrypted? (LC_ENCRYPTION_INFO_64 cryptid ≠ 0
//      → re-signing produces an app that fails to install or crashes at launch)
//    • Which architectures are in it (FAT vs thin), is arm64 present
//    • Minimum iOS version it declares (LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS)
//    • Every LC_LOAD_DYLIB / WEAK / RPATH entry (what it links against)
//    • Whether an LC_CODE_SIGNATURE is present and how big
//  No external deps — reads headers only, never maps the whole file.
//

import Foundation

nonisolated struct MachOSlice: Sendable, Identifiable {
    var id: String { arch }
    let arch: String
    let offset: Int
    let size: Int
    let fileType: String
    let encrypted: Bool
    let cryptID: UInt32
    let minOS: String?
    let sdk: String?
    let platform: String?
    let dylibs: [String]
    let weakDylibs: [String]
    let rpaths: [String]
    let hasCodeSignature: Bool
    let codeSignatureSize: Int
    let loadCommandCount: Int
    let pie: Bool
}

nonisolated struct MachOReport: Sendable {
    let path: String
    let isFat: Bool
    let slices: [MachOSlice]
    let warnings: [String]

    var arm64: MachOSlice? { slices.first { $0.arch == "arm64" || $0.arch == "arm64e" } }
    var encrypted: Bool { slices.contains { $0.encrypted } }
}

nonisolated enum MachOInspector {

    enum InspectError: LocalizedError {
        case notMachO, unreadable
        var errorDescription: String? {
            switch self {
            case .notMachO:  return "Not a Mach-O binary."
            case .unreadable: return "Couldn't read the binary."
            }
        }
    }

    // Magic
    private static let FAT_MAGIC: UInt32   = 0xCAFEBABE
    private static let FAT_CIGAM: UInt32   = 0xBEBAFECA
    private static let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private static let MH_CIGAM_64: UInt32 = 0xCFFAEDFE
    private static let MH_MAGIC: UInt32    = 0xFEEDFACE
    private static let MH_CIGAM: UInt32    = 0xCEFAEDFE

    // Load commands
    private static let LC_LOAD_DYLIB: UInt32          = 0x0C
    private static let LC_LOAD_WEAK_DYLIB: UInt32     = 0x18 | 0x80000000
    private static let LC_REEXPORT_DYLIB: UInt32      = 0x1F | 0x80000000
    private static let LC_RPATH: UInt32               = 0x1C | 0x80000000
    private static let LC_CODE_SIGNATURE: UInt32      = 0x1D
    private static let LC_ENCRYPTION_INFO: UInt32     = 0x21
    private static let LC_ENCRYPTION_INFO_64: UInt32  = 0x2C
    private static let LC_VERSION_MIN_IPHONEOS: UInt32 = 0x25
    private static let LC_BUILD_VERSION: UInt32       = 0x32
    private static let MH_PIE: UInt32 = 0x200000

    /// Inspect the main executable of an unpacked .app (or any Mach-O path).
    static func inspect(binaryAt url: URL) throws -> MachOReport {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw InspectError.unreadable }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()).map(Int.init) ?? 0
        try? fh.seek(toOffset: 0)
        guard let head = try? fh.read(upToCount: 8), head.count >= 4 else { throw InspectError.notMachO }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }

        var slices: [MachOSlice] = []
        var isFat = false
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            isFat = true
            let be = (magic == FAT_CIGAM)    // FAT headers are big-endian on disk; CIGAM means we read them "backwards" on LE host
            try? fh.seek(toOffset: 0)
            guard let hdr = try? fh.read(upToCount: 8) else { throw InspectError.notMachO }
            let n = Int(u32(hdr, 4, bigEndian: be))
            for i in 0..<min(n, 8) {
                try? fh.seek(toOffset: UInt64(8 + i * 20))
                guard let a = try? fh.read(upToCount: 20), a.count == 20 else { break }
                let cputype = u32(a, 0, bigEndian: be)
                let off = Int(u32(a, 8, bigEndian: be))
                let size = Int(u32(a, 12, bigEndian: be))
                if let s = try? slice(fh, offset: off, size: size, cpuHint: cputype, fileSize: fileSize) { slices.append(s) }
            }
        } else if magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC || magic == MH_CIGAM {
            if let s = try? slice(fh, offset: 0, size: fileSize, cpuHint: nil, fileSize: fileSize) { slices.append(s) }
        } else {
            throw InspectError.notMachO
        }

        var warnings: [String] = []
        if slices.isEmpty { warnings.append("No readable Mach-O slices.") }
        if slices.contains(where: { $0.encrypted }) {
            warnings.append("Binary is FairPlay-ENCRYPTED (cryptid ≠ 0). This IPA was not decrypted — re-signing it will install but crash at launch, or fail to install. Use a decrypted IPA.")
        }
        if !slices.contains(where: { $0.arch == "arm64" || $0.arch == "arm64e" }) {
            warnings.append("No arm64 slice — this won't run on any modern iPhone.")
        }
        if let m = slices.compactMap(\.minOS).first, let v = Double(m.split(separator: ".").prefix(2).joined(separator: ".")), v >= 26 {
            warnings.append("Declares minimum iOS \(m) — won't install on older devices.")
        }
        for s in slices where !s.hasCodeSignature { warnings.append("\(s.arch): no LC_CODE_SIGNATURE (unsigned or stripped) — zsign will add one.") }

        return MachOReport(path: url.path, isFat: isFat, slices: slices, warnings: warnings)
    }

    /// Convenience: find the main binary inside an .app and inspect it.
    static func inspect(appBundle: URL) throws -> MachOReport {
        let info = NSDictionary(contentsOf: appBundle.appendingPathComponent("Info.plist"))
        let exe = (info?["CFBundleExecutable"] as? String) ?? appBundle.deletingPathExtension().lastPathComponent
        return try inspect(binaryAt: appBundle.appendingPathComponent(exe))
    }

    // MARK: - One slice

    private static func slice(_ fh: FileHandle, offset: Int, size: Int, cpuHint: UInt32?, fileSize: Int) throws -> MachOSlice {
        try fh.seek(toOffset: UInt64(offset))
        guard let h = try fh.read(upToCount: 32), h.count >= 28 else { throw InspectError.notMachO }
        let magic = u32(h, 0)
        let is64 = (magic == MH_MAGIC_64 || magic == MH_CIGAM_64)
        let swapped = (magic == MH_CIGAM_64 || magic == MH_CIGAM)
        let cputype = u32(h, 4, bigEndian: swapped)
        let cpusub = u32(h, 8, bigEndian: swapped)
        let filetype = u32(h, 12, bigEndian: swapped)
        let ncmds = Int(u32(h, 16, bigEndian: swapped))
        let sizeofcmds = Int(u32(h, 20, bigEndian: swapped))
        let flags = u32(h, 24, bigEndian: swapped)
        let hdrLen = is64 ? 32 : 28

        // Read all load commands in one go (bounded).
        try fh.seek(toOffset: UInt64(offset + hdrLen))
        guard let lc = try fh.read(upToCount: min(sizeofcmds, 4_000_000)) else { throw InspectError.unreadable }

        var dylibs: [String] = [], weak: [String] = [], rpaths: [String] = []
        var enc = false, cryptid: UInt32 = 0, minOS: String? = nil, sdk: String? = nil, platform: String? = nil
        var hasSig = false, sigSize = 0
        var p = 0
        for _ in 0..<min(ncmds, 512) {
            guard p + 8 <= lc.count else { break }
            let cmd = u32(lc, p, bigEndian: swapped); let cmdsize = Int(u32(lc, p + 4, bigEndian: swapped))
            guard cmdsize >= 8, p + cmdsize <= lc.count else { break }
            switch cmd {
            case LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB:
                let strOff = Int(u32(lc, p + 8, bigEndian: swapped))
                let name = cstr(lc, p + strOff, end: p + cmdsize)
                if cmd == LC_LOAD_WEAK_DYLIB { weak.append(name) } else { dylibs.append(name) }
            case LC_RPATH:
                let strOff = Int(u32(lc, p + 8, bigEndian: swapped))
                rpaths.append(cstr(lc, p + strOff, end: p + cmdsize))
            case LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64:
                cryptid = u32(lc, p + 16, bigEndian: swapped)
                enc = cryptid != 0
            case LC_VERSION_MIN_IPHONEOS:
                minOS = ver(u32(lc, p + 8, bigEndian: swapped)); sdk = ver(u32(lc, p + 12, bigEndian: swapped)); platform = "iOS"
            case LC_BUILD_VERSION:
                let plat = u32(lc, p + 8, bigEndian: swapped)
                platform = ["", "macOS", "iOS", "tvOS", "watchOS", "bridgeOS", "macCatalyst", "iOS Simulator"][safe: Int(plat)] ?? "platform \(plat)"
                minOS = ver(u32(lc, p + 12, bigEndian: swapped)); sdk = ver(u32(lc, p + 16, bigEndian: swapped))
            case LC_CODE_SIGNATURE:
                hasSig = true; sigSize = Int(u32(lc, p + 12, bigEndian: swapped))
            default: break
            }
            p += cmdsize
        }

        return MachOSlice(arch: archName(cputype, cpusub), offset: offset, size: size,
                          fileType: fileTypeName(filetype), encrypted: enc, cryptID: cryptid,
                          minOS: minOS, sdk: sdk, platform: platform,
                          dylibs: dylibs, weakDylibs: weak, rpaths: rpaths,
                          hasCodeSignature: hasSig, codeSignatureSize: sigSize,
                          loadCommandCount: ncmds, pie: flags & MH_PIE != 0)
    }

    // MARK: - helpers

    private static func u32(_ d: Data, _ at: Int, bigEndian: Bool = false) -> UInt32 {
        guard at + 4 <= d.count else { return 0 }
        let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        return bigEndian ? v.byteSwapped : v
    }
    private static func cstr(_ d: Data, _ at: Int, end: Int) -> String {
        guard at < d.count else { return "" }
        let stop = min(end, d.count)
        var bytes: [UInt8] = []
        var i = at
        while i < stop, d[d.startIndex + i] != 0 { bytes.append(d[d.startIndex + i]); i += 1 }
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func ver(_ v: UInt32) -> String {
        let a = v >> 16, b = (v >> 8) & 0xFF, c = v & 0xFF
        return c == 0 ? "\(a).\(b)" : "\(a).\(b).\(c)"
    }
    private static func archName(_ cputype: UInt32, _ sub: UInt32) -> String {
        switch cputype {
        case 0x0100000C: return (sub & 0x00FFFFFF) == 2 ? "arm64e" : "arm64"
        case 0x0000000C: return "armv7"
        case 0x01000007: return "x86_64"
        case 0x00000007: return "i386"
        default: return String(format: "cpu 0x%08X", cputype)
        }
    }
    private static func fileTypeName(_ t: UInt32) -> String {
        ["", "object", "executable", "fvmlib", "core", "preload", "dylib", "dylinker", "bundle", "dylib_stub", "dsym", "kext"][safe: Int(t)] ?? "type \(t)"
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
