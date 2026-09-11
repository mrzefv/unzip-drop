//
//  MV1ELiveView.swift
//  3D view-debugger for a captured live hierarchy — an exploded stack of textured
//  planes (one per view) spaced by hierarchy depth, orbit/zoom, tap to inspect.
//  Also a flat tree list. Data comes from MV1ELive (VPS relay or local HTTP).
//

import SwiftUI
import SceneKit
import UIKit

struct MV1ELiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index: [LiveIndexEntry] = []
    @State private var capture: LiveCapture?
    @State private var loading = false
    @State private var error: String?
    @State private var localURL = ""
    @State private var mode = 0     // 0 = 3D, 1 = tree
    @State private var selected: LiveNode?
    @State private var dumped: [MV1E.DumpedClass] = []
    @State private var localIPA: URL?
    @State private var dumping = false
    @State private var copilotTarget: MV1E.DumpedClass?
    @State private var jumpClass: MV1E.DumpedClass?
    @EnvironmentObject private var config: Config

    private let blue = Color(red: 0.25, green: 0.55, blue: 1.0)

    var body: some View {
        NavigationStack {
            Group {
                if let cap = capture { renderView(cap) } else { pickerView }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("mv1E Live").navigationBarTitleDisplayMode(.inline)
            .sheet(item: $jumpClass) { c in NavigationStack { staticDetail(c) }.preferredColorScheme(.dark) }
            .sheet(item: $copilotTarget) { c in
                NavigationStack {
                    CopilotView(app: capture?.app ?? c.name, bundleID: capture?.bundle ?? "", cls: c,
                                ipaURL: localIPA ?? URL(fileURLWithPath: "/dev/null"), stageDylib: { _ in })
                }.preferredColorScheme(.dark)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if capture != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Picker("", selection: $mode) { Text("3D").tag(0); Text("Tree").tag(1) }.pickerStyle(.segmented)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await refreshIndex() }
    }

    // MARK: Picker (choose a capture)

    private var pickerView: some View {
        List {
            Section {
                Text("Inject mv1E Live into an app, sign & install it, then tap the floating mv1E button in that app. Its live view hierarchy + screenshots appear here.")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }.listRowBackground(Color(white: 0.08))

            Section("Captures on VPS") {
                if loading { HStack { ProgressView().tint(blue); Text("Loading…").foregroundStyle(Theme.subtle) } }
                else if index.isEmpty { Text("None yet. Tap the mv1E button inside an injected app.").font(.caption).foregroundStyle(Theme.subtle) }
                ForEach(index) { e in
                    Button { Task { await load(bundle: e.bundle) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.app).foregroundStyle(Theme.text)
                            Text(e.bundle).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                    }
                }
                Button { Task { await refreshIndex() } } label: { Label("Refresh", systemImage: "arrow.clockwise").foregroundStyle(blue) }
            }.listRowBackground(Color(white: 0.08))

            Section("Local (same Wi-Fi)") {
                TextField("http://<device-ip>:8770", text: $localURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(size: 13, design: .monospaced))
                Button { Task { await loadLocal() } } label: { Label("Pull local", systemImage: "wifi").foregroundStyle(blue) }
                    .disabled(localURL.isEmpty)
            }.listRowBackground(Color(white: 0.08))

            if let error { Section { Text(error).font(.caption).foregroundStyle(.orange) }.listRowBackground(Color(white: 0.08)) }
        }
        .scrollContentBackground(.hidden).background(Color.black)
    }

    // MARK: Render

    private func renderView(_ cap: LiveCapture) -> some View {
        Group {
            if mode == 0 {
                ZStack(alignment: .bottom) {
                    SceneView(scene: buildScene(cap), options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .background(Color.black)
                    if let s = selected {
                        let match = MV1EBridge.match(s.cls, in: dumped)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.cls).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(blue)
                            Text(String(format: "{%.0f, %.0f, %.0f × %.0f}", s.x, s.y, s.w, s.h))
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                            if let t = s.text, !t.isEmpty { Text("\"\(t)\"").font(.caption).foregroundStyle(Theme.subtle).lineLimit(2) }
                            if dumping { HStack(spacing: 6) { ProgressView().tint(blue); Text("Dumping classes…").font(.caption2).foregroundStyle(Theme.subtle) } }
                            else if let m = match {
                                HStack(spacing: 10) {
                                    Button { jumpClass = m } label: { Label("\(m.methods.count) methods", systemImage: "list.bullet.rectangle").font(.caption) }
                                    Button { copilotTarget = m } label: { Label("Ask Copilot", systemImage: "sparkles").font(.caption).foregroundStyle(blue) }
                                }
                            } else if !dumped.isEmpty {
                                Text("No static match — class may be private/stripped.").font(.caption2).foregroundStyle(.orange)
                            } else if localIPA == nil {
                                Text("Import this app's IPA to Library to link static classes.").font(.caption2).foregroundStyle(Theme.subtle)
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12)).padding()
                    }
                }
            } else {
                treeList(cap)
            }
        }
    }

    private func treeList(_ cap: LiveCapture) -> some View {
        List(MV1ELive.flatten(cap.root)) { n in
            HStack(spacing: 8) {
                ForEach(0..<min(n.depth, 8), id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.08)).frame(width: 2) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.cls).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(n.hidden ? Theme.subtle : Theme.text)
                    Text(String(format: "{%.0f, %.0f, %.0f × %.0f}", n.x, n.y, n.w, n.h)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                if n.png != nil { Image(systemName: "photo").font(.caption).foregroundStyle(blue) }
            }
            .listRowBackground(Color.black)
            .onTapGesture { selected = n; mode = 0 }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.black)
    }

    // MARK: SceneKit — exploded plane stack

    private func buildScene(_ cap: LiveCapture) -> SCNScene {
        let scene = SCNScene()
        let flat = MV1ELive.flatten(cap.root)
        let screenW = max(cap.screen?.w ?? 390, 1)
        let screenH = max(cap.screen?.h ?? 844, 1)
        let scale = 6.0 / screenW          // world units across the screen width
        let zStep: Float = 0.35

        for n in flat where n.w > 0 && n.h > 0 && !n.hidden {
            let pw = CGFloat(n.w * scale), ph = CGFloat(n.h * scale)
            let plane = SCNPlane(width: pw, height: ph)
            let mat = SCNMaterial()
            if let b64 = n.png, let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                mat.diffuse.contents = img
            } else {
                mat.diffuse.contents = UIColor(hue: CGFloat((n.depth * 47) % 360) / 360.0, saturation: 0.5, brightness: 0.9, alpha: 0.85)
            }
            mat.isDoubleSided = true
            mat.transparency = CGFloat(max(0.35, n.alpha))
            plane.materials = [mat]
            let node = SCNNode(geometry: plane)
            // center the view in world space; y is flipped (UIKit origin top-left)
            let cx = (n.x + n.w/2 - screenW/2) * scale
            let cy = -(n.y + n.h/2 - screenH/2) * scale
            node.position = SCNVector3(Float(cx), Float(cy), Float(n.depth) * zStep)
            node.name = n.id
            scene.rootNode.addChildNode(node)

            // thin outline
            let outline = SCNBox(width: pw, height: ph, length: 0.001, chamferRadius: 0)
            let om = SCNMaterial(); om.diffuse.contents = UIColor.white.withAlphaComponent(0.10); om.fillMode = .lines
            outline.materials = [om]
            let on = SCNNode(geometry: outline); on.position = node.position
            scene.rootNode.addChildNode(on)
        }

        // camera
        let cam = SCNCamera(); cam.zFar = 400
        let camNode = SCNNode(); camNode.camera = cam
        camNode.position = SCNVector3(0, 0, Float(flat.count) * 0.0 + 9)
        camNode.eulerAngles = SCNVector3(-0.25, 0.55, 0)   // slight iso angle
        scene.rootNode.addChildNode(camNode)
        return scene
    }


    // Static class detail reached by tapping a live object (reuses the dump).
    private func staticDetail(_ cls: MV1E.DumpedClass) -> some View {
        List {
            Section("@interface") {
                Text("\(cls.name)\(cls.superName.map { " : \($0)" } ?? "")")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                if !cls.protocols.isEmpty {
                    Text("<\(cls.protocols.joined(separator: ", "))>").font(.system(size: 12, design: .monospaced)).foregroundStyle(blue)
                }
            }.listRowBackground(Color(white: 0.08))
            if !cls.ivars.isEmpty {
                Section("Ivars (\(cls.ivars.count))") {
                    ForEach(cls.ivars) { iv in
                        HStack { Text(iv.name).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                            Spacer(); Text(iv.type).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1) }
                    }.listRowBackground(Color(white: 0.08))
                }
            }
            Section("Methods (\(cls.methods.count))") {
                ForEach(cls.methods) { m in
                    Text(m.signature).font(.system(size: 13, design: .monospaced)).foregroundStyle(m.isClassMethod ? blue : Theme.text)
                }.listRowBackground(Color(white: 0.08))
            }
            Section {
                Button { copilotTarget = cls; jumpClass = nil } label: { Label("Ask Copilot to write a dylib", systemImage: "sparkles") }
                    .listRowBackground(Color(white: 0.08))
            }
        }
        .scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle(cls.name).navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Data

    private func refreshIndex() async { loading = true; index = await MV1ELive.index(); loading = false }
    private func load(bundle: String) async {
        loading = true; error = nil
        do { capture = try await MV1ELive.fetch(bundle: bundle); await autoDump(bundle: bundle) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    /// Background class-dump of the SAME app's local IPA, so live taps can jump to
    /// the static class + Copilot. Silent if the IPA isn't in the inbox.
    private func autoDump(bundle: String) async {
        guard let ipa = MV1EBridge.localIPA(forBundle: bundle) else { dumped = []; localIPA = nil; return }
        localIPA = ipa; dumping = true
        if let r = await MV1E.dump(ipaURL: ipa) { dumped = r.classes }
        dumping = false
    }
    private func loadLocal() async {
        loading = true; error = nil
        do { let c = try await MV1ELive.fetchLocal(urlString: localURL); capture = c; await autoDump(bundle: c.bundle) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}
