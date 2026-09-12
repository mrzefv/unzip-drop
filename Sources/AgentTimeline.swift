//
//  AgentTimeline.swift
//  Copilot-style step timeline used by the signing terminal, OTA install and
//  the Actions build tab: icon · title · timing, indented children on a hairline,
//  tap a child for its raw log, active step spins, finished steps auto-collapse.
//
//  Log producers can emit synthetic lines to drive the parser:
//      §step|<sf.symbol>|<title>          start a new step
//      §child|<text>                       add a child to the current step
//      §warn|<text>                        add to the yellow "Warnings" step
//      §done|<title>                       mark a step finished (title replaced)
//

import SwiftUI

// MARK: - Model

struct AgentChild: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var raw: [String] = []
}

struct AgentStep: Identifiable, Equatable {
    enum Kind: Equatable { case running, done, error, warn, info }
    let id = UUID()
    var icon: String
    var title: String
    var kind: Kind = .done
    var children: [AgentChild] = []
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var trailing: String? = nil        // explicit right-hand label (Build tab uses this)

    var duration: TimeInterval? { startedAt.flatMap { s in endedAt.map { $0.timeIntervalSince(s) } } }
}

// MARK: - Parser (zsign log + § markers → steps, with timings)

nonisolated enum AgentStepParser {
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
           .replacingOccurrences(of: "\\[[0-9;]*m", with: "", options: .regularExpression)
           .replacingOccurrences(of: "^>>>\\s*", with: "", options: .regularExpression)
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fmt(_ t: TimeInterval) -> String {
        t < 1 ? String(format: "%.0fms", t * 1000) : (t < 60 ? String(format: "%.1fs", t) : String(format: "%dm %02ds", Int(t) / 60, Int(t) % 60))
    }

    static func parse(_ raw: [String], times: [Date], error: String?, finished: Bool) -> [AgentStep] {
        var out: [AgentStep] = []
        var files: [AgentChild] = []
        var filesStart: Int?
        var lastRealloc: String?
        var warnIndex: Int?

        func time(_ i: Int) -> Date? { i < times.count ? times[i] : nil }
        func open(_ step: AgentStep, at i: Int) {
            var s = step; s.startedAt = time(i)
            if let last = out.indices.last, out[last].endedAt == nil, out[last].kind != .warn { out[last].endedAt = time(i) }
            out.append(s)
        }
        func flushFiles(at i: Int) {
            guard !files.isEmpty else { return }
            var s = AgentStep(icon: "doc.badge.gearshape", title: files.count == 1 ? "Sign 1 file" : "Sign \(files.count) files", children: files)
            s.startedAt = filesStart.flatMap(time)
            s.endedAt = time(i)
            if let last = out.indices.last, out[last].endedAt == nil, out[last].kind != .warn { out[last].endedAt = s.startedAt }
            out.append(s); files = []; filesStart = nil
        }
        func attach(_ text: String, raw r: String) {
            if !files.isEmpty { files[files.count - 1].text += "  · " + text; files[files.count - 1].raw.append(r); return }
            if let last = out.indices.last {
                // realloc/ok belongs to the most recent child (folder/file), not as a new row
                if (text.hasPrefix("realloc ") || text == "ok"), !out[last].children.isEmpty {
                    out[last].children[out[last].children.count - 1].text += "  · " + text
                    out[last].children[out[last].children.count - 1].raw.append(r)
                } else {
                    out[last].children.append(AgentChild(text: text, raw: [r]))
                }
            } else {
                out.append(AgentStep(icon: "text.alignleft", title: "Log", children: [AgentChild(text: text, raw: [r])]))
            }
        }
        func warn(_ text: String, raw r: String, at i: Int) {
            if let w = warnIndex { out[w].children.append(AgentChild(text: text, raw: [r])); return }
            var s = AgentStep(icon: "exclamationmark.triangle", title: "Warnings", kind: .warn, children: [AgentChild(text: text, raw: [r])])
            s.startedAt = time(i); s.endedAt = time(i)
            out.append(s); warnIndex = out.count - 1
        }

        for (i, r) in raw.enumerated() {
            let l = clean(r); if l.isEmpty { continue }

            // ---- synthetic markers
            if l.hasPrefix("§step|") {
                let p = l.dropFirst(6).split(separator: "|", maxSplits: 1).map(String.init)
                flushFiles(at: i); open(AgentStep(icon: p.first ?? "circle", title: p.count > 1 ? p[1] : "Step"), at: i); continue }
            if l.hasPrefix("§child|") { attach(String(l.dropFirst(7)), raw: r); continue }
            if l.hasPrefix("§warn|")  { warn(String(l.dropFirst(6)), raw: r, at: i); continue }
            if l.hasPrefix("§done|")  {
                flushFiles(at: i)
                if let last = out.indices.last { out[last].title = String(l.dropFirst(6)); out[last].endedAt = time(i); out[last].kind = .done }
                continue }

            let low = l.lowercased()
            if low.hasPrefix("signing ") && low.contains(" with ") { flushFiles(at: i); open(AgentStep(icon: "signature", title: l), at: i); continue }
            if low.hasPrefix("extracting ipa") { flushFiles(at: i); open(AgentStep(icon: "archivebox", title: "Extract IPA"), at: i); continue }
            if low.hasPrefix("signing:") {
                flushFiles(at: i)
                let path = String(l.dropFirst("signing:".count)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ...", with: "")
                open(AgentStep(icon: "doc.text.magnifyingglass", title: "Read app bundle", children: [AgentChild(text: path, raw: [r])]), at: i); continue }
            if low.hasPrefix("signfile:") {
                if files.isEmpty { filesStart = i }
                files.append(AgentChild(text: String(l.dropFirst("signfile:".count)).trimmingCharacters(in: .whitespaces), raw: [r])); lastRealloc = nil; continue }
            if low.hasPrefix("signfolder:") {
                flushFiles(at: i)
                let name = String(l.dropFirst("signfolder:".count)).trimmingCharacters(in: .whitespaces)
                open(AgentStep(icon: "folder.badge.gearshape", title: "Sign app bundle", children: [AgentChild(text: name, raw: [r])]), at: i); continue }
            if low.contains("no enough codesignature space") {
                if let m = l.range(of: "Now: ", options: .caseInsensitive) {
                    lastRealloc = "realloc " + String(l[m.upperBound...]).replacingOccurrences(of: ", Need: ", with: " → ")
                }
                continue }
            if low.contains("realloc codesignature") { continue }
            if low == "success!" { attach(lastRealloc ?? "ok", raw: r); lastRealloc = nil; continue }
            if low.hasPrefix("signed ok") {
                flushFiles(at: i)
                var t = ""
                if let o = l.firstIndex(of: "(") { t = String(l[o...]).split(separator: ",").first.map(String.init) ?? "" }
                open(AgentStep(icon: "checkmark.seal", title: "Signed OK" + (t.isEmpty ? "" : " " + t + ")")), at: i)
                if let last = out.indices.last { out[last].endedAt = time(i) }
                continue }
            if low.hasPrefix("packaging signed ipa") { flushFiles(at: i); open(AgentStep(icon: "shippingbox", title: "Package signed IPA"), at: i); continue }
            if low.hasPrefix("done") {
                flushFiles(at: i)
                if let last = out.indices.last { out[last].endedAt = time(i) }
                continue }
            if low.hasPrefix("✓ install triggered") {
                flushFiles(at: i); open(AgentStep(icon: "arrow.down.app", title: "Install", children: [AgentChild(text: "itms-services handoff → Home Screen", raw: [r])]), at: i)
                if let last = out.indices.last { out[last].endedAt = time(i) }
                continue }
            if low.contains("error") || low.contains("failed") || l.contains("❌") {
                flushFiles(at: i); open(AgentStep(icon: "xmark.octagon", title: l, kind: .error), at: i)
                if let last = out.indices.last { out[last].endedAt = time(i) }
                continue }
            attach(l, raw: r)
        }
        flushFiles(at: raw.count)
        if let error, out.last?.kind != .error { out.append(AgentStep(icon: "xmark.octagon", title: error, kind: .error, startedAt: times.last, endedAt: times.last)) }

        // Kinds: last open step is running until finished
        if !finished, let last = out.indices.last, out[last].kind == .done, out[last].endedAt == nil { out[last].kind = .running }
        if finished { for i in out.indices where out[i].endedAt == nil { out[i].endedAt = times.last } }
        return out
    }
}

// MARK: - Rows

struct AgentStepRow: View {
    let step: AgentStep
    var isActive: Bool = false
    var forceExpanded: Bool = false
    var now: Date = .now

    @State private var userCollapsed: Bool? = nil
    @State private var openRaw: Set<UUID> = []

    private var collapsed: Bool {
        if let u = userCollapsed { return u }
        return !forceExpanded && !isActive && step.kind != .error && step.kind != .warn
    }
    private var titleColor: Color {
        switch step.kind { case .error: return Color(red: 1, green: 0.35, blue: 0.3); case .warn: return Color(red: 1, green: 0.8, blue: 0.3); default: return .white.opacity(0.85) }
    }
    private var iconColor: Color {
        switch step.kind {
        case .error:   return Color(red: 1, green: 0.35, blue: 0.3)
        case .warn:    return Color(red: 1, green: 0.8, blue: 0.3)
        case .running: return Color(red: 1.0, green: 0.72, blue: 0.20)
        default:       return .white.opacity(0.65)
        }
    }
    private var timing: String? {
        if let t = step.trailing { return t }
        if let d = step.duration { return AgentStepParser.fmt(d) }
        if step.kind == .running, let s = step.startedAt { return AgentStepParser.fmt(now.timeIntervalSince(s)) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !step.children.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.15)) { userCollapsed = !collapsed }
            } label: {
                HStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: step.icon)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(iconColor)
                            .frame(width: 22, height: 22)
                        // state glyph: spinner while running, check when done, x on error
                        Group {
                            switch step.kind {
                            case .running: ProgressView().tint(iconColor).scaleEffect(0.45).frame(width: 10, height: 10)
                            case .done where step.endedAt != nil:
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                            case .error: Image(systemName: "xmark.circle.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(iconColor)
                            default: EmptyView()
                            }
                        }
                        .background(Circle().fill(Color.black).frame(width: 12, height: 12))
                        .offset(x: 4, y: 3)
                    }
                    Text(step.title)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(titleColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if let timing {
                        Text(timing).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                    }
                    if !step.children.isEmpty {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.3))
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                    }
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !step.children.isEmpty && !collapsed {
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.leading, 11).padding(.bottom, 6)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(step.children) { c in
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    guard !c.raw.isEmpty else { return }
                                    withAnimation(.easeInOut(duration: 0.15)) { if openRaw.contains(c.id) { openRaw.remove(c.id) } else { openRaw.insert(c.id) } }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(c.text)
                                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.35))
                                            .rotationEffect(.degrees(openRaw.contains(c.id) ? 90 : 0))
                                    }
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if openRaw.contains(c.id) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(Array(c.raw.enumerated()), id: \.offset) { _, line in
                                            Text(AgentStepParser.clean(line))
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.42))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .padding(.bottom, 6)
                                }
                            }
                        }
                    }
                    .padding(.leading, 24)
                }
                .padding(.bottom, 4)
            }
        }
        .onChange(of: isActive) { _ in userCollapsed = nil }
    }
}

/// "⠿ mSign is working…" with a drifting shimmer and live elapsed time.
struct AgentWorkingRow: View {
    let text: String
    var since: Date? = nil
    var now: Date = .now
    @State private var phase: CGFloat = -1
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.grid.3x3.fill").font(.system(size: 13, weight: .regular)).foregroundStyle(.white.opacity(0.7)).frame(width: 22, height: 22)
            Text(text).font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                .overlay {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6).offset(x: phase * g.size.width)
                            .mask(Text(text).font(.system(size: 17, weight: .medium)))
                    }
                }
                .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 } }
            Spacer()
            if let since { Text(AgentStepParser.fmt(now.timeIntervalSince(since))).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.35)) }
        }
        .padding(.vertical, 9)
    }
}

// MARK: - End-of-run summary card (Copilot "PR description" style) + markdown copy

struct AgentSummary {
    var app: String; var bundle: String; var version: String
    var cert: String; var sizeBefore: Int64; var sizeAfter: Int64
    var filesSigned: Int; var duration: TimeInterval; var warnings: Int
    var mdid: String

    private static func bytes(_ n: Int64) -> String { n > 0 ? ByteCountFormatter.string(fromByteCount: n, countStyle: .file) : "—" }
    var sizeLine: String { sizeBefore > 0 && sizeAfter > 0 ? "\(Self.bytes(sizeBefore)) → \(Self.bytes(sizeAfter))" : Self.bytes(sizeAfter) }
    var markdown: String {
        """
        **\(app)** `\(bundle)` v\(version)
        • Cert: \(cert)
        • Size: \(sizeLine)
        • Files signed: \(filesSigned)\(warnings > 0 ? "  • Warnings: \(warnings)" : "")
        • Time: \(AgentStepParser.fmt(duration))
        • Signed with mSign · MDID \(mdid)
        """
    }
}

struct AgentSummaryCard: View {
    let summary: AgentSummary
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.white.opacity(0.7))
                Text("Summary").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button {
                    UIPasteboard.general.string = summary.markdown
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { copied = true }
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .bold))
                        Text(copied ? "Copied" : "Copy summary").font(.system(size: 11, weight: .bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.08)).foregroundStyle(.white.opacity(0.85)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            row("App", "\(summary.app) · v\(summary.version)")
            row("Bundle", summary.bundle)
            row("Cert", summary.cert)
            row("Size", summary.sizeLine)
            row("Files signed", "\(summary.filesSigned)")
            if summary.warnings > 0 { row("Warnings", "\(summary.warnings)") }
            row("Time", AgentStepParser.fmt(summary.duration))
        }
        .padding(14)
        .background(Color.white.opacity(0.04))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).frame(width: 84, alignment: .leading)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
        }
    }
}
