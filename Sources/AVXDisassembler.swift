//
//  AVXDisassembler.swift
//  SIPA / msign
//
//  On-device ARM64 disassembler, ADRP xref scanner, and known-encoding
//  assembler — a faithful Swift port of the avxscan/arm64_decode.cpp engine
//  used by the server's /api/avx/scan/disasm + /xref endpoints, plus the
//  avxasm known-encoding table for assembling patches. Pure bit-math, no
//  clang / Capstone — runs entirely on device.
//

import Foundation

struct DecodedInsn {
    var va: UInt64
    var raw: UInt32
    var mnem: String
    var ops: String
    var branchTgt: UInt64?
    /// "68 83 00 b0" little-endian byte string for the UI / patch editor.
    var byteString: String {
        String(format: "%02x %02x %02x %02x", raw & 0xFF, (raw >> 8) & 0xFF, (raw >> 16) & 0xFF, (raw >> 24) & 0xFF)
    }
}

enum AVXDisassembler {

    // MARK: - Core decode (port of avx::arm64::decode)

    static func signExtend(_ val: UInt64, _ bits: Int) -> Int64 {
        let s = Int64(bitPattern: val)
        let shift = 64 - bits
        return (s << shift) >> shift
    }

    static func decode(va: UInt64, insn: UInt32) -> DecodedInsn {
        var d = DecodedInsn(va: va, raw: insn, mnem: "", ops: "", branchTgt: nil)

        // ADRP
        if (insn & 0x9F000000) == 0x90000000 {
            let immlo = UInt64((insn >> 29) & 3)
            let immhi = UInt64((insn >> 5) & 0x7FFFF)
            let imm21 = (immhi << 2) | immlo
            let off = signExtend(imm21, 21) << 12
            let page = UInt64(bitPattern: (Int64(bitPattern: va) & ~0xFFF) + off)
            d.mnem = "ADRP"; d.ops = String(format: "x%u, #0x%llx (page)", insn & 0x1F, page); return d
        }
        // ADD (immediate, width-aware)
        if (insn & 0x7F800000) == 0x11000000 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F
            let imm = (insn >> 10) & 0xFFF, shifted = (insn >> 22) & 1
            let rdN = rd == 31 ? (sf == 1 ? "sp" : "wsp") : "\(wx(sf))\(rd)"
            let rnN = rn == 31 ? (sf == 1 ? "sp" : "wsp") : "\(wx(sf))\(rn)"
            let immS = shifted == 1 ? String(format: "#0x%x, lsl #12", imm) : String(format: "#0x%x", imm)
            d.mnem = "ADD"; d.ops = "\(rdN), \(rnN), \(immS)"; return d
        }
        // SUB (immediate, width-aware)
        if (insn & 0x7F800000) == 0x51000000 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F
            let imm = (insn >> 10) & 0xFFF, shifted = (insn >> 22) & 1
            let rdN = rd == 31 ? (sf == 1 ? "sp" : "wsp") : "\(wx(sf))\(rd)"
            let rnN = rn == 31 ? (sf == 1 ? "sp" : "wsp") : "\(wx(sf))\(rn)"
            let immS = shifted == 1 ? String(format: "#0x%x, lsl #12", imm) : String(format: "#0x%x", imm)
            d.mnem = "SUB"; d.ops = "\(rdN), \(rnN), \(immS)"; return d
        }
        // LDR / STR (unsigned offset, size-aware: B/H/W/X incl. signed loads)
        if (insn & 0x3F000000) == 0x39000000 {
            let size = (insn >> 30) & 3, opc = (insn >> 22) & 3
            let rt = insn & 0x1F, rn = (insn >> 5) & 0x1F
            let imm = ((insn >> 10) & 0xFFF) << size
            let suffix = size == 0 ? "B" : (size == 1 ? "H" : "")
            let wide = size == 3 || (opc == 2 && size < 3)
            let rtN = (wide ? "x" : "w") + "\(rt)"
            let rnN = rn == 31 ? "sp" : "x\(rn)"
            switch opc {
            case 0:  d.mnem = "STR" + suffix
            case 1:  d.mnem = "LDR" + suffix
            default: d.mnem = size == 2 ? "LDRSW" : "LDRS" + suffix
            }
            d.ops = String(format: "%@, [%@, #0x%x]", rtN, rnN, imm)
            return d
        }
        // BL
        if (insn >> 26) == 0b100101 {
            let off = signExtend(UInt64(insn & 0x3FFFFFF), 26) * 4
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + off)
            d.mnem = "BL"; d.ops = String(format: "0x%llx", tgt); d.branchTgt = tgt; return d
        }
        // B (unconditional)
        if (insn >> 26) == 0b000101 {
            let off = signExtend(UInt64(insn & 0x3FFFFFF), 26) * 4
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + off)
            d.mnem = "B"; d.ops = String(format: "0x%llx", tgt); d.branchTgt = tgt; return d
        }
        // BLR
        if (insn & 0xFFFFFC1F) == 0xD63F0000 {
            d.mnem = "BLR"; d.ops = String(format: "x%u", (insn >> 5) & 0x1F); return d
        }
        // BR
        if (insn & 0xFFFFFC1F) == 0xD61F0000 {
            d.mnem = "BR"; d.ops = String(format: "x%u", (insn >> 5) & 0x1F); return d
        }
        // RET
        if (insn & 0xFFFFFC1F) == 0xD65F0000 { d.mnem = "RET"; d.ops = ""; return d }
        // CBZ / CBNZ
        if (insn & 0x7F000000) == 0x34000000 || (insn & 0x7F000000) == 0x35000000 {
            let off = signExtend(UInt64((insn >> 5) & 0x7FFFF), 19) * 4
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + off)
            d.mnem = (insn & 0x7F000000) == 0x34000000 ? "CBZ" : "CBNZ"
            let w = ((insn >> 31) & 1) == 1 ? "x" : "w"
            d.ops = String(format: "%@%u, 0x%llx", w, insn & 0x1F, tgt); d.branchTgt = tgt; return d
        }
        // TBZ / TBNZ
        if (insn & 0x7F000000) == 0x36000000 || (insn & 0x7F000000) == 0x37000000 {
            let bit = (((insn >> 31) & 1) << 5) | ((insn >> 19) & 0x1F)
            let off = signExtend(UInt64((insn >> 5) & 0x3FFF), 14) * 4
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + off)
            let w = ((insn >> 31) & 1) == 1 ? "x" : "w"
            d.mnem = (insn & 0x7F000000) == 0x36000000 ? "TBZ" : "TBNZ"
            d.ops = String(format: "%@%u, #%u, 0x%llx", w, insn & 0x1F, bit, tgt); d.branchTgt = tgt; return d
        }
        // B.cond — decode the condition so it reads (and flips) correctly.
        if (insn & 0xFF000010) == 0x54000000 {
            let off = signExtend(UInt64((insn >> 5) & 0x7FFFF), 19) * 4
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + off)
            d.mnem = "B." + condName(insn & 0xF)
            d.ops = String(format: "0x%llx", tgt); d.branchTgt = tgt; return d
        }
        // STP
        if (insn & 0xFFC00000) == 0xA9000000 || (insn & 0xFFC00000) == 0xA9800000 {
            d.mnem = "STP"; d.ops = ""; return d
        }
        // MOVN / MOVZ / MOVK (move wide, width-aware)
        if (insn & 0x1F800000) == 0x12800000 {
            let sf = (insn >> 31) & 1, opc = (insn >> 29) & 3
            let imm16 = (insn >> 5) & 0xFFFF, shift = ((insn >> 21) & 3) * 16
            let name = opc == 0 ? "MOVN" : (opc == 2 ? "MOVZ" : (opc == 3 ? "MOVK" : "MOV?"))
            let shiftStr = shift == 0 ? "" : String(format: ", lsl #%u", shift)
            d.mnem = name; d.ops = String(format: "%@%u, #0x%x%@", wx(sf), insn & 0x1F, imm16, shiftStr); return d
        }
        // MOV (register) — ORR Rd, ZR, Rm (both widths)
        if (insn & 0x7FE0FFE0) == 0x2A0003E0 {
            let sf = (insn >> 31) & 1
            d.mnem = "MOV"; d.ops = String(format: "%@%u, %@%u", wx(sf), insn & 0x1F, wx(sf), (insn >> 16) & 0x1F); return d
        }
        // NOP
        if insn == 0xD503201F { d.mnem = "NOP"; d.ops = ""; return d }

        // SUBS / CMP (immediate) — the classic compare before a conditional branch.
        if (insn & 0x7F800000) == 0x71000000 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F
            let imm = (insn >> 10) & 0xFFF, shifted = (insn >> 22) & 1
            let rnName = rn == 31 ? (sf == 1 ? "sp" : "wsp") : "\(wx(sf))\(rn)"
            let immStr = shifted == 1 ? String(format: "#0x%x, lsl #12", imm) : String(format: "#0x%x", imm)
            if rd == 31 { d.mnem = "CMP"; d.ops = "\(rnName), \(immStr)" }
            else        { d.mnem = "SUBS"; d.ops = "\(wx(sf))\(rd), \(rnName), \(immStr)" }
            return d
        }
        // ADDS / CMN (immediate)
        if (insn & 0x7F800000) == 0x31000000 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F
            let imm = (insn >> 10) & 0xFFF, shifted = (insn >> 22) & 1
            let rnName = rn == 31 ? (sf == 1 ? "sp" : "wsp") : "\(wx(sf))\(rn)"
            let immStr = shifted == 1 ? String(format: "#0x%x, lsl #12", imm) : String(format: "#0x%x", imm)
            if rd == 31 { d.mnem = "CMN"; d.ops = "\(rnName), \(immStr)" }
            else        { d.mnem = "ADDS"; d.ops = "\(wx(sf))\(rd), \(rnName), \(immStr)" }
            return d
        }
        // SUBS / CMP (shifted register)
        if (insn & 0x7FE00000) == 0x6B000000 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F, rm = (insn >> 16) & 0x1F
            if rd == 31 { d.mnem = "CMP"; d.ops = "\(wx(sf))\(rn), \(wx(sf))\(rm)" }
            else        { d.mnem = "SUBS"; d.ops = "\(wx(sf))\(rd), \(wx(sf))\(rn), \(wx(sf))\(rm)" }
            return d
        }
        // ANDS / TST (shifted register)
        if (insn & 0x7FE00000) == 0x6A000000 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F, rm = (insn >> 16) & 0x1F
            if rd == 31 { d.mnem = "TST"; d.ops = "\(wx(sf))\(rn), \(wx(sf))\(rm)" }
            else        { d.mnem = "ANDS"; d.ops = "\(wx(sf))\(rd), \(wx(sf))\(rn), \(wx(sf))\(rm)" }
            return d
        }
        // ADR (PC-relative, no page)
        if (insn & 0x9F000000) == 0x10000000 {
            let immlo = UInt64((insn >> 29) & 3), immhi = UInt64((insn >> 5) & 0x7FFFF)
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + signExtend((immhi << 2) | immlo, 21))
            d.mnem = "ADR"; d.ops = String(format: "x%u, 0x%llx", insn & 0x1F, tgt); return d
        }
        // LDR (literal, PC-relative)
        if (insn & 0x3B000000) == 0x18000000 {
            let off = signExtend(UInt64((insn >> 5) & 0x7FFFF), 19) * 4
            let tgt = UInt64(bitPattern: Int64(bitPattern: va) + off)
            let w = ((insn >> 30) & 1) == 1 ? "x" : "w"
            d.mnem = "LDR"; d.ops = String(format: "%@%u, 0x%llx", w, insn & 0x1F, tgt); d.branchTgt = tgt; return d
        }
        // CSEL — conditional select
        if (insn & 0x7FE00C00) == 0x1A800000 {
            let sf = (insn >> 31) & 1, cond = (insn >> 12) & 0xF
            d.mnem = "CSEL"
            d.ops = String(format: "%@%u, %@%u, %@%u, %@", wx(sf), insn & 0x1F, wx(sf), (insn >> 5) & 0x1F, wx(sf), (insn >> 16) & 0x1F, condName(cond))
            return d
        }
        // CSINC / CSET / CINC — Rd = (cond ? Rn : Rn+1); CSET when Rn=Rm=ZR
        if (insn & 0x7FE00C00) == 0x1A800400 {
            let sf = (insn >> 31) & 1, rd = insn & 0x1F, rn = (insn >> 5) & 0x1F, rm = (insn >> 16) & 0x1F
            let cond = (insn >> 12) & 0xF
            if rn == 31 && rm == 31 {
                // CSET Rd, invert(cond): Rd = 1 when cond holds, else 0
                d.mnem = "CSET"; d.ops = String(format: "%@%u, %@", wx(sf), rd, condName(cond ^ 1))
            } else {
                d.mnem = "CSINC"
                d.ops = String(format: "%@%u, %@%u, %@%u, %@", wx(sf), rd, wx(sf), rn, wx(sf), rm, condName(cond))
            }
            return d
        }

        d.mnem = String(format: ".word 0x%08X", insn); d.ops = ""
        return d
    }

    // MARK: - Helpers + in-place flip + string resolution

    private static func condName(_ c: UInt32) -> String {
        let names = ["EQ","NE","CS","CC","MI","PL","VS","VC","HI","LS","GE","LT","GT","LE","AL","NV"]
        return names[Int(c & 0xF)]
    }
    private static func wx(_ sf: UInt32) -> String { sf == 1 ? "x" : "w" }

    /// Invert a conditional branch in place — toggles one bit and preserves the
    /// branch target, so the user can flip a premium check without recomputing
    /// any offset. Returns nil for non-conditional instructions.
    static func flip(_ insn: UInt32) -> UInt32? {
        if (insn & 0x7F000000) == 0x34000000 || (insn & 0x7F000000) == 0x35000000 { return insn ^ 0x01000000 } // CBZ↔CBNZ
        if (insn & 0x7F000000) == 0x36000000 || (insn & 0x7F000000) == 0x37000000 { return insn ^ 0x01000000 } // TBZ↔TBNZ
        if (insn & 0xFF000010) == 0x54000000 { return insn ^ 1 }                                               // B.cond invert
        return nil
    }

    /// Read a C string at a VA (for ADRP+ADD/LDR annotation). nil if unmapped
    /// or not a printable string.
    static func stringAt(va: UInt64, thin: Data, segments: [MachOTools.Segment]) -> String? {
        guard let off = MachOTools.fileOffset(forVA: va, segments: segments) else { return nil }
        let start = thin.startIndex + off
        guard start < thin.endIndex else { return nil }
        var e = start
        let limit = Swift.min(start + 180, thin.endIndex)
        while e < limit, thin[e] != 0 { e = thin.index(after: e) }
        guard e > start, let s = String(data: thin[start..<e], encoding: .utf8),
              s.count >= 2, s.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return s
    }

    // MARK: - Window disassembly at a VA

    /// Disassemble `count` instructions starting at `va` (reads from the thin
    /// slice via the segment map). Returns [] if the VA isn't mapped.
    static func disassemble(atVA va: UInt64, count: Int, thin: Data, segments: [MachOTools.Segment]) -> [DecodedInsn] {
        guard let off = MachOTools.fileOffset(forVA: va, segments: segments) else { return [] }
        var out: [DecodedInsn] = []
        var p = thin.startIndex + off
        for i in 0..<count {
            guard p + 4 <= thin.endIndex else { break }
            let insn = UInt32(thin[p]) | (UInt32(thin[p+1]) << 8) | (UInt32(thin[p+2]) << 16) | (UInt32(thin[p+3]) << 24)
            out.append(decode(va: va + UInt64(i * 4), insn: insn))
            p += 4
        }
        return out
    }

    /// Walk backwards from `xrefVA` to find the enclosing function entry
    /// (STP x29,x30 prologue or SUB sp,sp,#imm). Port of infer_function_entry.
    static func inferFunctionEntry(textVA: UInt64, textData: Data, xrefVA: UInt64, searchBack: Int = 256) -> UInt64 {
        guard xrefVA >= textVA else { return xrefVA }
        let nInsns = textData.count / 4
        let idx = Int((xrefVA - textVA) / 4)
        guard idx < nInsns else { return xrefVA }
        let start = max(0, idx - searchBack)
        var k = idx
        while k >= start {
            let p = textData.startIndex + k * 4
            let insn = UInt32(textData[p]) | (UInt32(textData[p+1]) << 8) | (UInt32(textData[p+2]) << 16) | (UInt32(textData[p+3]) << 24)
            if (insn & 0x003FFFFF) == 0x003D7BFD { return textVA + UInt64(k * 4) }  // STP x29,x30,[sp,#-N]!
            if (insn & 0xFFC003FF) == 0xD10003FF { return textVA + UInt64(k * 4) }  // SUB sp,sp,#imm
            k -= 1
        }
        return xrefVA
    }

    // MARK: - Xref scan (port of find_xrefs)

    struct Xref { let xrefVA: UInt64; let targetVA: UInt64 }

    /// Find ADRP(+ADD/LDR) sequences in __text that compute any of `targetVAs`.
    static func findXrefs(targetVAs: Set<UInt64>, textVA: UInt64, textData: Data) -> [Xref] {
        guard textData.count % 4 == 0, !targetVAs.isEmpty else { return [] }
        let buf = [UInt8](textData)          // flat buffer — far faster than Data subscripts
        let n = buf.count / 4
        @inline(__always) func u32(_ i: Int) -> UInt32 {
            let b = i * 4
            return UInt32(buf[b]) | (UInt32(buf[b+1]) << 8) | (UInt32(buf[b+2]) << 16) | (UInt32(buf[b+3]) << 24)
        }
        var pages: Set<UInt64> = []
        for t in targetVAs { pages.insert(t & ~0xFFF) }

        var result: [Xref] = []
        var seen: Set<UInt64> = []
        var i = 0
        while i + 1 < n {
            let insn = u32(i)
            if (insn & 0x9F000000) != 0x90000000 { i += 1; continue }   // ADRP only
            let immlo = UInt64((insn >> 29) & 3), immhi = UInt64((insn >> 5) & 0x7FFFF)
            let imm21 = (immhi << 2) | immlo
            let va = textVA + UInt64(i * 4)
            let pageOff = signExtend(imm21, 21) << 12
            let rpage = UInt64(bitPattern: (Int64(bitPattern: va) & ~0xFFF) + pageOff)
            guard pages.contains(rpage) else { i += 1; continue }
            let rd = insn & 0x1F
            let next = u32(i + 1)
            var tgt: UInt64 = 0; var ok = false
            if (next & 0xFF800000) == 0x91000000 && ((next >> 5) & 0x1F) == rd {        // ADD
                tgt = rpage + UInt64((next >> 10) & 0xFFF); ok = true
            } else if (next & 0xFFC00000) == 0xF9400000 && ((next >> 5) & 0x1F) == rd { // LDR
                tgt = rpage + (UInt64((next >> 10) & 0xFFF) << 3); ok = true
            }
            if ok, targetVAs.contains(tgt), !seen.contains(va) {
                seen.insert(va)
                result.append(Xref(xrefVA: va, targetVA: tgt))
            }
            i += 1
        }
        return result
    }

    // MARK: - Assemble (port of avxasm known-encoding table)

    /// Assemble a small set of common patch instructions to little-endian
    /// bytes. Returns nil on miss (UI then keeps server/manual hex).
    static func assemble(_ text: String) -> [UInt8]? {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\r", with: "")

        // Multi-line bool-return stubs.
        if s == "mov w0, #0\nret" || s == "mov w0, #0; ret" { return [0x00,0x00,0x80,0x52, 0xC0,0x03,0x5F,0xD6] }
        if s == "mov w0, #1\nret" || s == "mov w0, #1; ret" { return [0x20,0x00,0x80,0x52, 0xC0,0x03,0x5F,0xD6] }
        if s == "mov x0, #0\nret"                            { return [0x00,0x00,0x80,0xD2, 0xC0,0x03,0x5F,0xD6] }

        let table: [String: UInt32] = [
            "nop": 0xD503201F, "ret": 0xD65F03C0,
            "mov w0, #0": 0x52800000, "mov w0, #1": 0x52800020,
            "mov w0, #0x0": 0x52800000, "mov w0, #0x1": 0x52800020,
            "mov x0, #0": 0xD2800000, "mov x0, #1": 0xD2800020,
            "mov x0, #0x0": 0xD2800000, "mov x0, #0x1": 0xD2800020,
            "b .": 0x14000000, "b.n .": 0x14000000,
            "brk #0": 0xD4200000, "brk #0x0": 0xD4200000,
            "b #4": 0x14000001, "b #8": 0x14000002, "b #0xc": 0x14000003,
        ]
        guard let enc = table[s] else { return nil }
        return [UInt8(enc & 0xFF), UInt8((enc >> 8) & 0xFF), UInt8((enc >> 16) & 0xFF), UInt8((enc >> 24) & 0xFF)]
    }
}
