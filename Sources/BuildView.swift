//
//  BuildView.swift
//  Build tab — GitHub Actions runs for the target repo, presented like the
//  GitHub job page: status glyph · step name · duration, live-polled while the
//  run is active, with artifact (IPA) download and share.
//

import SwiftUI
import UIKit
import ZIPFoundation

// MARK: - Status glyph (mirrors GitHub's job page)

private struct StatusGlyph: View {
    let status: String
    let conclusion: String?
    var size: CGFloat = 18
    @State private var spin = false

    var body: some View {
        Group {
            if status == "completed" {
                switch conclusion {
                case "success":
                    ZStack { Circle().fill(Color(white: 0.55)); Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.black) }
                case "failure", "timed_out", "startup_failure":
                    ZStack { Circle().fill(Color.red); Image(systemName: "xmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white) }
                case "cancelled":
                    ZStack { Circle().fill(Color(white: 0.45)); Image(systemName: "exclamationmark").font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(.black) }
                case "skipped":
                    ZStack { Circle().stroke(Color(white: 0.45), lineWidth: 2); Image(systemName: "arrow.right").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(Color(white: 0.45)) }
                default:
                    Circle().stroke(Color(white: 0.45), lineWidth: 2)
                }
            } else if status == "in_progress" {
                ZStack {
                    Circle().stroke(Color.yellow.opacity(0.35), lineWidth: 3)
                    Circle().trim(from: 0, to: 0.3).stroke(Color.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    Circle().fill(Color.yellow).frame(width: size * 0.45, height: size * 0.45)
                }
                .onAppear { spin = true }
            } else {
                Circle().stroke(Color(white: 0.45), lineWidth: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

private func fmtDuration(_ start: Date?, _ end: Date?, now: Date = Date()) -> String {
    guard let start else { return "" }
    let s = Int(max(0, (end ?? now).timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

private func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}

// MARK: - Build tab (runs list)

struct BuildView: View {
    @EnvironmentObject var config: Config
    @State private var runs: [WorkflowRun] = []
    @State private var workflows: [Workflow] = []
    @State private var loading = false
    @State private var dispatching = false
    @State private var error: String?
    @State private var selected: WorkflowRun?
    @State private var timer: Timer?

    private var client: ActionsClient? {
        guard !config.owner.isEmpty, !config.repo.isEmpty, config.hasToken else { return nil }
        return ActionsClient(owner: config.owner, repo: config.repo, token: config.token)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if client == nil {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Not configured", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline).foregroundStyle(.orange)
                                Text("Set the repo and a token with Actions: Read (and write to trigger builds) in Settings.")
                                    .font(.caption).foregroundStyle(Theme.subtle)
                            }
                        }
                    } else {
                        dispatchCard
                        if let error {
                            Card { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                        runsList
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .fullScreenCover(item: $selected) { run in
            RunDetailScreen(run: run, client: client!)
                .environmentObject(config)
                .preferredColorScheme(.dark)
        }
        .onAppear { Task { await load() }; startPolling() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private var header: some View {
        HStack {
            Text("Build").font(.title2.bold()).foregroundStyle(Theme.text)
            Spacer()
            if loading { ProgressView().tint(Theme.accent) }
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(Theme.accent)
            }
        }
    }

    private var dispatchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Run workflow", systemImage: "play.circle.fill").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(config.owner)/\(config.repo) @ \(config.branch.isEmpty ? "main" : config.branch)")
                        .font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                }
                if workflows.isEmpty {
                    Text("No workflows found in .github/workflows.").font(.caption).foregroundStyle(Theme.subtle)
                } else {
                    ForEach(workflows) { wf in
                        Button { Task { await dispatch(wf) } } label: {
                            HStack {
                                Image(systemName: "bolt.fill")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(wf.name).fontWeight(.semibold)
                                    Text(wf.path).font(.caption2.monospaced()).opacity(0.7)
                                }
                                Spacer()
                                if dispatching { ProgressView().tint(.black) } else { Image(systemName: "arrow.right") }
                            }
                            .padding(.vertical, 10).padding(.horizontal, 12)
                            .background(Theme.accent).foregroundStyle(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(dispatching)
                    }
                    Text("Needs `workflow_dispatch:` in the workflow's `on:` block. Pushes trigger runs automatically either way.")
                        .font(.caption2).foregroundStyle(Theme.subtle)
                }
            }
        }
    }

    private var runsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT RUNS").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
            if runs.isEmpty && !loading {
                Card { Text("No runs yet. Push something or trigger a workflow.").font(.caption).foregroundStyle(Theme.subtle) }
            }
            ForEach(runs) { run in
                Button { selected = run } label: {
                    HStack(spacing: 12) {
                        StatusGlyph(status: run.status, conclusion: run.conclusion, size: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.title.isEmpty ? run.name : run.title)
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                            HStack(spacing: 6) {
                                Text("\(run.name) #\(run.runNumber)")
                                Text("·")
                                Text(run.headBranch)
                                Text("·")
                                Text(run.shortSha).font(.caption.monospaced())
                            }
                            .font(.caption).foregroundStyle(Theme.subtle).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(run.isActive ? "running" : relative(run.updatedAt)).font(.caption).foregroundStyle(Theme.subtle)
                            Text(fmtDuration(run.createdAt, run.isActive ? nil : run.updatedAt))
                                .font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.subtle)
                    }
                    .padding(12)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Data

    private func load() async {
        guard let client else { return }
        loading = true; error = nil
        do {
            async let r = client.runs()
            async let w = client.workflows()
            runs = try await r
            workflows = try await w.filter { $0.state == "active" }
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func dispatch(_ wf: Workflow) async {
        guard let client else { return }
        dispatching = true; error = nil
        do {
            try await client.dispatch(workflowID: wf.id, ref: config.branch.isEmpty ? "main" : config.branch)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await load()
        } catch {
            let m = error.localizedDescription
            self.error = m.contains("422") ? "Workflow has no `workflow_dispatch` trigger, or the branch doesn't exist. (\(m))" : m
        }
        dispatching = false
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
            guard runs.contains(where: \.isActive) else { return }
            Task { await load() }
        }
    }
}

// MARK: - Run detail (the GitHub job page)

private struct RunDetailScreen: View {
    let run: WorkflowRun
    let client: ActionsClient
    @Environment(\.dismiss) private var dismiss

    @State private var live: WorkflowRun
    @State private var jobs: [WorkflowJob] = []
    @State private var artifacts: [RunArtifact] = []
    @State private var expanded: Set<Int> = []
    @State private var error: String?
    @State private var busy = false
    @State private var downloading: Int?
    @State private var share: URLItem?
    @State private var now = Date()
    @State private var timer: Timer?

    init(run: WorkflowRun, client: ActionsClient) {
        self.run = run; self.client = client
        _live = State(initialValue: run)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    runHeader
                    ForEach(jobs) { job in jobSection(job) }
                    if jobs.isEmpty && error == nil {
                        HStack { Spacer(); ProgressView().tint(Theme.accent).padding(30); Spacer() }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.orange).padding(16)
                    }
                    artifactsSection
                }
                .padding(.bottom, 30)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .onAppear { Task { await refresh() }; startTimer() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    // MARK: Header

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                Spacer()
            }
            Text("\(live.name) #\(live.runNumber)")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                .frame(maxWidth: .infinity).padding(.horizontal, 140).lineLimit(1)
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.bg)
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)
    }

    private var runHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StatusGlyph(status: live.status, conclusion: live.conclusion, size: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.title.isEmpty ? live.name : live.title)
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                    Text("#\(live.runNumber)").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.subtle)
                }
            }
            HStack(spacing: 8) {
                tag(live.headBranch, "arrow.triangle.branch")
                tag(live.shortSha, "number")
                tag(live.event, "bolt")
                Spacer()
            }
            HStack(spacing: 10) {
                if live.isActive {
                    actionButton("Cancel", "xmark.circle", .red) { try await client.cancel(runID: live.id) }
                } else {
                    actionButton("Re-run", "arrow.clockwise", Theme.accent) { try await client.rerun(runID: live.id) }
                }
                if let u = URL(string: live.htmlURL) {
                    Link(destination: u) {
                        Label("Open on GitHub", systemImage: "safari").font(.caption.weight(.semibold))
                            .padding(.vertical, 8).padding(.horizontal, 12)
                            .background(Theme.card).foregroundStyle(Theme.accent)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.card.opacity(0.5))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)
    }

    private func tag(_ s: String, _ icon: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon); Text(s) }
            .font(.caption.monospaced()).foregroundStyle(Theme.subtle)
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(Theme.bg).clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    private func actionButton(_ title: String, _ icon: String, _ color: Color, _ op: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                busy = true
                do { try await op(); try? await Task.sleep(nanoseconds: 1_500_000_000); await refresh() }
                catch { self.error = error.localizedDescription }
                busy = false
            }
        } label: {
            Label(title, systemImage: icon).font(.caption.weight(.semibold))
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(color.opacity(0.18)).foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .disabled(busy)
    }

    // MARK: Jobs + steps

    private func jobSection(_ job: WorkflowJob) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text(jobSubtitle(job)).font(.caption).foregroundStyle(Theme.subtle)
                }
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(Theme.subtle)
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

            ForEach(job.steps) { step in stepRow(step) }
        }
    }

    private func jobSubtitle(_ job: WorkflowJob) -> String {
        if job.status == "completed" {
            let c = job.conclusion ?? "completed"
            return "\(c.capitalized) · \(fmtDuration(job.startedAt, job.completedAt))"
        }
        if job.status == "in_progress", let s = job.startedAt { return "Started \(relative(s))" }
        return "Queued"
    }

    private func stepRow(_ step: WorkflowStep) -> some View {
        let done = step.status == "completed"
        let active = step.status == "in_progress"
        return HStack(spacing: 14) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                .rotationEffect(.degrees(expanded.contains(step.number) ? 90 : 0))
                .opacity(done || active ? 1 : 0)
            StatusGlyph(status: step.status, conclusion: step.conclusion, size: 20)
            Text(step.name)
                .font(.system(size: 16)).foregroundStyle(done || active ? Theme.text : Theme.subtle)
                .lineLimit(1)
            Spacer()
            Text(fmtDuration(step.startedAt, step.completedAt, now: now))
                .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.subtle)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded.contains(step.number) { expanded.remove(step.number) } else { expanded.insert(step.number) }
        }
    }

    // MARK: Artifacts

    @ViewBuilder
    private var artifactsSection: some View {
        if !artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("ARTIFACTS").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                ForEach(artifacts) { a in
                    Button { Task { await download(a) } } label: {
                        HStack(spacing: 12) {
                            Image(systemName: a.name.lowercased().contains("ipa") ? "app.badge.checkmark" : "doc.zipper")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(a.expired ? "expired" : ByteCountFormatter.string(fromByteCount: a.sizeBytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(a.expired ? .orange : Theme.subtle)
                            }
                            Spacer()
                            if downloading == a.id { ProgressView().tint(Theme.accent) }
                            else { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent) }
                        }
                        .padding(12).background(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(a.expired || downloading != nil)
                }
                Text("Tap an IPA artifact and it goes straight to the Sign tab — sign with your cert and install over the air. Other artifacts open the share sheet.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
            .padding(16)
        }
    }

    private func download(_ a: RunArtifact) async {
        downloading = a.id; error = nil
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(a.name).zip")
        do {
            try await client.downloadArtifact(id: a.id, to: dest) { _ in }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Artifact zips wrap the real file. If there's an IPA inside, hand it to the Sign tab.
            if let ipa = try? Self.extractIPA(from: dest) {
                dismiss()
                SignQueue.shared.enqueue(ipa)
            } else {
                share = URLItem(url: dest)
            }
        } catch { self.error = error.localizedDescription }
        downloading = nil
    }

    /// Unzip an artifact and return the first .ipa found (or nil).
    nonisolated private static func extractIPA(from zip: URL) throws -> URL? {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("art-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.unzipItem(at: zip, to: out)
        guard let en = fm.enumerator(at: out, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in en where u.pathExtension.lowercased() == "ipa" { return u }
        return nil
    }

    // MARK: Refresh

    private func refresh() async {
        do {
            async let r = client.run(id: run.id)
            async let j = client.jobs(runID: run.id)
            live = try await r
            jobs = try await j
            if !live.isActive { artifacts = (try? await client.artifacts(runID: run.id)) ?? [] }
            // Expand the step that's currently running so it reads like GitHub
            for job in jobs { for s in job.steps where s.status == "in_progress" { expanded.insert(s.number) } }
        } catch { self.error = error.localizedDescription }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            now = Date()
            if live.isActive, Int(now.timeIntervalSince1970) % 5 == 0 { Task { await refresh() } }
        }
    }
}
