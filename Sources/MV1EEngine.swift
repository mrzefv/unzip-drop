//
//  MV1EEngine.swift
//  mv1E Engine — static Objective-C + Swift class dump (Flex-style, read from the
//  binary, no live emulation). Walks __objc_classlist → class_ro_t → method / ivar
//  / property / protocol lists, plus __swift5_types for Swift type names.
//
//  arm64e/arm64 Mach-O, iOS layout. Pointers in __objc_* are either raw VAs or,
//  in modern chained-fixup binaries, rebased — we mask the top bits and resolve
//  via segment VA→file-offset (same trick class-dump-dyld uses).
//

import Foundation

nonisolated enum MV1E {

    // MARK: Models

    struct DumpedMethod: Identifiable, Hashable {
        let id = UUID()
        let name: String            // selector
        let types: String           // ObjC type encoding
        let isClassMethod: Bool
        /// Human-ish signature: "- (ret)sel:(arg)…" reconstructed from the encoding.
        var signature: String { (isClassMethod ? "+ " : "- ") + name }
    }
    struct DumpedIvar: Identifiable, Hashable {
        let id = UUID(); let name: String; let type: String; let offset: Int
    }
    struct DumpedProperty: Identifiable, Hashable {
        let id = UUID(); let name: String; let attributes: String
    }
    struct DumpedClass: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let superName: String?
        var methods: [DumpedMethod]
        var ivars: [DumpedIvar]
        var properties: [DumpedProperty]
        var protocols: [String]
        var kind: String            // "ObjC" | "Swift"
        var methodCount: Int { methods.count }
    }
    struct DumpResult {
        var classes: [DumpedClass]
        var swiftTypes: [String]
        var elapsedMs: Int
    }

    // MARK: Entry

    static func dump(ipaURL: URL) async -> DumpResult? {
        let start = Date()
        guard let full = await LocalBinaryScanner.rawMainBinary(ipaURL: ipaURL) else { return nil }
        let thin = MachOTools.thinArm64(full)
        let segs = MachOTools.segments(in: thin)
        let secs = MachOTools.sections(in: thin)
        guard !segs.isEmpty else { return nil }

        var classes = parseObjC(thin: thin, segs: segs, secs: secs)
        let swift = parseSwiftTypeNames(thin: thin, segs: segs, secs: secs)
        classes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return DumpResult(classes: classes, swiftTypes: swift.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                          elapsedMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    // MARK: ObjC walk

    private static func parseObjC(thin: Data, segs: [MachOTools.Segment], secs: [MachOTools.Section]) -> [DumpedClass] {
        guard let classlist = secs.first(where: { $0.name == "__objc_classlist" }) else { return [] }
        func off(_ va: UInt64) -> Int? { MachOTools.fileOffset(forVA: clean(va), segments: segs) }
        func ptr(_ at: Int) -> UInt64 { at + 8 <= thin.count ? readU64(thin, at) : 0 }
        func cstr(_ va: UInt64) -> String { guard let o = off(va) else { return "" }; return readCString(thin, o) }

        var out: [DumpedClass] = []
        let base = Int(classlist.offset)
        let n = Int(classlist.size / 8)
        for i in 0..<n {
            let clsVA = ptr(base + i * 8)
            guard clsVA != 0, let c = parseClass(clsVA, thin: thin, segs: segs, off: off, ptr: ptr, cstr: cstr) else { continue }
            out.append(c)
        }
        return out
    }

    private static func parseClass(_ clsVA: UInt64, thin: Data, segs: [MachOTools.Segment],
                                   off: (UInt64) -> Int?, ptr: (Int) -> UInt64, cstr: (UInt64) -> String) -> DumpedClass? {
        guard let clsOff = off(clsVA) else { return nil }
        // objc_class: isa, superclass, cache, vtable, data(class_rw/ro)
        let superVA = ptr(clsOff + 8)
        let dataVA = ptr(clsOff + 32) & ~UInt64(3)     // low bits are flags
        guard let roOff = off(dataVA) else { return nil }
        // class_ro_t: flags(4) instanceStart(4) instanceSize(4) reserved(4) ivarLayout(8) name(8) baseMethods(8) baseProtocols(8) ivars(8) weakIvarLayout(8) baseProperties(8)
        let nameVA = ptr(roOff + 24)
        let name = cstr(nameVA)
        guard !name.isEmpty else { return nil }

        var superName: String? = nil
        if superVA != 0, let sOff = off(superVA) { let snVA = ptr(sOff + 32) & ~UInt64(3); if let rn = off(snVA) { superName = readCString(thin, rn + 24 <= thin.count ? Int(readU64(thin, rn + 24)) : 0) } }
        // Simpler superclass name: follow superVA→ro→name
        if superVA != 0, let sOff = off(superVA) {
            let sRo = ptr(sOff + 32) & ~UInt64(3)
            if let sRoOff = off(sRo) { let n = cstr(ptr(sRoOff + 24)); if !n.isEmpty { superName = n } }
        }

        let methods = parseMethodList(ptr(roOff + 32), thin: thin, off: off, ptr: ptr, cstr: cstr, classMethods: false)
        let ivars = parseIvarList(ptr(roOff + 48), thin: thin, off: off, ptr: ptr, cstr: cstr)
        let props = parsePropList(ptr(roOff + 64), thin: thin, off: off, ptr: ptr, cstr: cstr)
        let protos = parseProtocolList(ptr(roOff + 40), thin: thin, off: off, ptr: ptr, cstr: cstr)

        // Class (meta) methods: isa → ro → baseMethods
        var classMethods: [DumpedMethod] = []
        let isaVA = ptr(clsOff + 0)
        if isaVA != 0, let mOff = off(isaVA) {
            let mRo = ptr(mOff + 32) & ~UInt64(3)
            if let mRoOff = off(mRo) {
                classMethods = parseMethodList(ptr(mRoOff + 32), thin: thin, off: off, ptr: ptr, cstr: cstr, classMethods: true)
            }
        }

        return DumpedClass(name: name, superName: superName,
                           methods: classMethods + methods, ivars: ivars, properties: props,
                           protocols: protos, kind: "ObjC")
    }

    private static func parseMethodList(_ listVA: UInt64, thin: Data, off: (UInt64) -> Int?, ptr: (Int) -> UInt64,
                                        cstr: (UInt64) -> String, classMethods: Bool) -> [DumpedMethod] {
        guard listVA != 0, let lOff = off(listVA) else { return [] }
        let entsize = readU32(thin, lOff) & ~UInt32(0x80000003)   // small-list flag in low bits
        let smallList = (readU32(thin, lOff) & 0x80000000) != 0
        let count = Int(readU32(thin, lOff + 4))
        var out: [DumpedMethod] = []
        var p = lOff + 8
        for _ in 0..<min(count, 4096) {
            if smallList {
                // entsize 12: name(rel int32) types(rel int32) imp(rel int32)
                let nameRel = Int(Int32(bitPattern: readU32(thin, p)))
                let nameRefVA = /* &field + rel */ 0
                // small method list: name field is a relative offset to a selref (pointer to selector)
                let selRefOff = p + nameRel
                var selName = ""
                if selRefOff + 8 <= thin.count {
                    let selPtr = readU64(thin, selRefOff)
                    if let so = off(selPtr) { selName = readCString(thin, so) }
                }
                let typesRel = Int(Int32(bitPattern: readU32(thin, p + 4)))
                var types = ""
                let tOff = p + 4 + typesRel
                if tOff >= 0 && tOff < thin.count { types = readCString(thin, tOff) }
                _ = nameRefVA
                if !selName.isEmpty { out.append(DumpedMethod(name: selName, types: types, isClassMethod: classMethods)) }
                p += 12
            } else {
                let nameVA = ptr(p); let typesVA = ptr(p + 8)
                let selName = cstr(nameVA); let types = cstr(typesVA)
                if !selName.isEmpty { out.append(DumpedMethod(name: selName, types: types, isClassMethod: classMethods)) }
                p += Int(entsize == 0 ? 24 : entsize)
            }
        }
        return out
    }

    private static func parseIvarList(_ listVA: UInt64, thin: Data, off: (UInt64) -> Int?, ptr: (Int) -> UInt64, cstr: (UInt64) -> String) -> [DumpedIvar] {
        guard listVA != 0, let lOff = off(listVA) else { return [] }
        let entsize = Int(readU32(thin, lOff)); let count = Int(readU32(thin, lOff + 4))
        var out: [DumpedIvar] = []; var p = lOff + 8
        for _ in 0..<min(count, 2048) {
            // ivar_t: offsetPtr(8) name(8) type(8) alignment(4) size(4)
            let offPtrVA = ptr(p)
            var ivOffset = 0
            if let oo = off(offPtrVA), oo + 4 <= thin.count { ivOffset = Int(readU32(thin, oo)) }
            let name = cstr(ptr(p + 8)); let type = cstr(ptr(p + 16))
            if !name.isEmpty { out.append(DumpedIvar(name: name, type: type, offset: ivOffset)) }
            p += (entsize == 0 ? 32 : entsize)
        }
        return out
    }

    private static func parsePropList(_ listVA: UInt64, thin: Data, off: (UInt64) -> Int?, ptr: (Int) -> UInt64, cstr: (UInt64) -> String) -> [DumpedProperty] {
        guard listVA != 0, let lOff = off(listVA) else { return [] }
        let entsize = Int(readU32(thin, lOff)); let count = Int(readU32(thin, lOff + 4))
        var out: [DumpedProperty] = []; var p = lOff + 8
        for _ in 0..<min(count, 2048) {
            let name = cstr(ptr(p)); let attrs = cstr(ptr(p + 8))
            if !name.isEmpty { out.append(DumpedProperty(name: name, attributes: attrs)) }
            p += (entsize == 0 ? 16 : entsize)
        }
        return out
    }

    private static func parseProtocolList(_ listVA: UInt64, thin: Data, off: (UInt64) -> Int?, ptr: (Int) -> UInt64, cstr: (UInt64) -> String) -> [String] {
        guard listVA != 0, let lOff = off(listVA) else { return [] }
        let count = Int(readU64(thin, lOff))                 // protocol_list_t: count(uintptr) then ptrs
        var out: [String] = []; var p = lOff + 8
        for _ in 0..<min(count, 512) {
            let protoVA = ptr(p)
            if let po = off(protoVA) { let nameVA = ptr(po + 8); let n = cstr(nameVA); if !n.isEmpty { out.append(n) } }
            p += 8
        }
        return out
    }

    // MARK: Swift type names (best-effort)

    private static func parseSwiftTypeNames(thin: Data, segs: [MachOTools.Segment], secs: [MachOTools.Section]) -> [String] {
        guard let types = secs.first(where: { $0.name == "__swift5_types" }) else { return [] }
        func off(_ va: UInt64) -> Int? { MachOTools.fileOffset(forVA: clean(va), segments: segs) }
        var out: [String] = []
        let base = Int(types.offset); let n = Int(types.size / 4)
        for i in 0..<n {
            let p = base + i * 4
            guard p + 4 <= thin.count else { break }
            // each entry is a relative pointer to a nominal type descriptor
            let rel = Int(Int32(bitPattern: readU32(thin, p)))
            let descOff = p + rel
            guard descOff >= 0, descOff + 16 <= thin.count else { continue }
            // TypeContextDescriptor: flags(4) parent(rel4) name(rel4)…
            let nameRel = Int(Int32(bitPattern: readU32(thin, descOff + 8)))
            let nameOff = descOff + 8 + nameRel
            if nameOff >= 0, nameOff < thin.count {
                let nm = readCString(thin, nameOff)
                if !nm.isEmpty, nm.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { out.append(nm) }
            }
        }
        return Array(Set(out))
    }

    // MARK: Low-level

    /// Strip chained-fixup / tagged-pointer high bits so a stored pointer resolves as a VA.
    private static func clean(_ va: UInt64) -> UInt64 {
        // Clear PAC/high tag bits above bit 47 that appear in fixed-up pointers.
        va & 0x0000_00FF_FFFF_FFFF
    }
    private static func readU32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | (UInt32(d[o+1]) << 8) | (UInt32(d[o+2]) << 16) | (UInt32(d[o+3]) << 24)
    }
    private static func readU64(_ d: Data, _ o: Int) -> UInt64 {
        guard o >= 0, o + 8 <= d.count else { return 0 }
        return UInt64(readU32(d, o)) | (UInt64(readU32(d, o+4)) << 32)
    }
    private static func readCString(_ d: Data, _ o: Int) -> String {
        guard o >= 0, o < d.count else { return "" }
        var end = o
        while end < d.count, d[end] != 0, end - o < 1024 { end += 1 }
        return String(decoding: d[o..<end], as: UTF8.self)
    }
}
