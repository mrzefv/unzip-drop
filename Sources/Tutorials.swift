//
//  Tutorials.swift
//  Step-by-step guides shown from Settings › Tutorials. Content is static;
//  code blocks are copyable.
//

import SwiftUI
import UIKit

// MARK: - Model

struct Tutorial: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let minutes: Int
    let steps: [TutorialStep]
}

struct TutorialStep: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    var code: String? = nil
    var codeTitle: String? = nil
    var tip: String? = nil
}

// MARK: - Content

enum TutorialLibrary {
    static let all: [Tutorial] = [phoneOnly, certs, flex, hooking, pipeline]

    // 0. Phone-only setup
    static let phoneOnly = Tutorial(
        id: "phone", icon: "iphone", title: "Set up with just your phone",
        subtitle: "No computer. Sign in to GitHub, link a repo, done", minutes: 5,
        steps: [
            TutorialStep(
                title: "What you need",
                body: "An iPhone with this app, a GitHub account, and a domain you control (optional — zefv.dev is preconfigured). That's the whole list. No Mac, no Xcode, no server, no terminal — every build, sign, install and cert renewal runs on GitHub Actions or on the phone itself."),
            TutorialStep(
                title: "Sign in to GitHub and make a token",
                body: "On github.com (Safari is fine): Settings › Developer settings › Fine-grained tokens › Generate. Repository access: the repo(s) you'll use. Permissions — Contents, Actions, Workflows: Read and write. Copy it.",
                code: "https://github.com/settings/personal-access-tokens/new",
                codeTitle: "Token page"),
            TutorialStep(
                title: "Paste the token",
                body: "Settings › Access token › paste. It's stored in the Keychain and only ever sent to api.github.com."),
            TutorialStep(
                title: "Link a repo",
                body: "Create an empty repo on github.com (private is fine). Settings › Repository: owner + repo + branch. That's where zips you drop get pushed and where the Build tab watches runs."),
            TutorialStep(
                title: "Link the certs folder (one tap)",
                body: "Settings › OTA Domain › Cert repo: same owner/repo (or a separate one), your Let's Encrypt email, tap Link repo. First link-up installs the certbot workflow into the repo and creates the `certs` folder (a branch) automatically. Nothing to create by hand.",
                tip: "Linking is idempotent — tap it again any time; it only adds what's missing."),
            TutorialStep(
                title: "Point your domain (optional)",
                body: "Skip this to use zefv.dev. For your own domain: at your DNS host add an A record `*` → 127.0.0.1 (and `@` → 127.0.0.1). Then Settings › OTA Domain: type the domain, tap Check — it should say → 127.0.0.1 ✓. Save."),
            TutorialStep(
                title: "Issue the cert",
                body: "Tap Renew now. Within a minute the DNS challenge card shows a TXT name and value — add it at your DNS host, the workflow notices and continues; a second value follows for the apex, add it too (keep both). When it finishes, Pull latest. Done — installs now go over https://mr.<your domain>."),
            TutorialStep(
                title: "Daily loop",
                body: "Drop zip → Push → Build tab shows the run → tap the IPA artifact → Sign tab → Sign → Install. Certs auto-refresh from the certs folder before they expire."),
        ])

    // 0b. Certs in depth
    static let certs = Tutorial(
        id: "certs", icon: "lock.shield.fill", title: "How the OTA cert works",
        subtitle: "Loopback domain + Let's Encrypt wildcard, issued by Actions", minutes: 6,
        steps: [
            TutorialStep(
                title: "Why a public cert for 127.0.0.1",
                body: "iOS only installs from itms-services manifests served over HTTPS with a trusted cert. A hostname that resolves to loopback but carries a real Let's Encrypt cert satisfies that: the phone talks to a server on itself, over TLS iOS already trusts."),
            TutorialStep(
                title: "DNS-01 is the only way for wildcards",
                body: "Let's Encrypt won't issue *.domain over HTTP; it needs a TXT record at _acme-challenge.<domain>. certbot gives one value for the wildcard and another for the apex — both on the same record name.",
                code: "_acme-challenge.example.com  TXT  \"<value A>\"\n_acme-challenge.example.com  TXT  \"<value B>\"",
                codeTitle: "Two records, same name"),
            TutorialStep(
                title: "The wait-before-validate hook",
                body: "certs.yml runs certbot with a manual auth hook. The hook publishes the value to challenge.json, then polls Cloudflare and Google DNS-over-HTTPS every 20s. Only when the record is visible does it return and let certbot ask Let's Encrypt — so a slow DNS edit never burns a validation attempt.",
                code: "curl -H 'accept: application/dns-json' \\\n  'https://cloudflare-dns.com/dns-query?name=_acme-challenge.example.com&type=TXT'",
                codeTitle: "What the hook checks"),
            TutorialStep(
                title: "Where the files go",
                body: "server.crt (fullchain), server.pem (private key), pack.json (expiry + hashes) on the `certs` branch. The app pulls them with your token; Build.yml bakes the latest pair into every IPA so fresh installs work offline."),
            TutorialStep(
                title: "Renewal",
                body: "Weekly cron re-issues when < 30 days remain (needs repo variable LE_EMAIL for unattended runs), or tap Renew now. The app auto-pulls when within 21 days of expiry at install time."),
        ])

    // 1. Capture class names with FLEX
    static let flex = Tutorial(
        id: "flex", icon: "scope", title: "Capture class names with FLEX",
        subtitle: "Find the exact view, class and selector to hook", minutes: 10,
        steps: [
            TutorialStep(
                title: "Get FLEX as a dylib",
                body: "FLEX (Flipboard Explorer) is an in-app runtime inspector. You need it as a standalone dylib so it can be injected into the target IPA without rebuilding the app. Grab the latest FLEX.dylib release (or build it from the FLEX repo with the dylib template in this app — Makefile target FLEX, files from Classes/).",
                code: "https://github.com/FLEXTool/FLEX/releases",
                codeTitle: "Source",
                tip: "Keep one FLEX.dylib in Files. You'll inject it into every app you want to explore."),
            TutorialStep(
                title: "Inject FLEX into the target IPA",
                body: "In mSign, open the IPA › Sign › Extra dylibs › add FLEX.dylib. mSign copies it into the app bundle, adds an LC_LOAD_DYLIB to the main binary, signs everything with your cert and installs. No jailbreak needed — the app now loads FLEX at launch.",
                tip: "Same flow you'll use later for your own dylib. FLEX first, your tweak second."),
            TutorialStep(
                title: "Open the explorer",
                body: "Launch the app. FLEX's toolbar shows on a shake (or add a 3-finger tap trigger in your own dylib with [FLEXManager.sharedManager showExplorer]). Tap 'select' in the toolbar, then tap any UI element on screen.",
                code: "// If FLEX is silent, force it from your own dylib:\n#import <FLEX/FLEX.h>\n[[FLEXManager sharedManager] showExplorer];",
                codeTitle: "Force the explorer"),
            TutorialStep(
                title: "Read the class from the breadcrumb",
                body: "After selecting a view, FLEX shows the hierarchy chain at the top, e.g. UIWindow › UITransitionView › UIView › AMSettingsHeaderView. The last item is the exact class of what you tapped. Tap 'views' to scrub up and down the hierarchy — pick the smallest view that still contains what you want to change.",
                tip: "Prefer the view controller over the view when you want to add things: tap the view, then in the object screen scroll to 'nearest view controller'."),
            TutorialStep(
                title: "Capture the selectors",
                body: "Tap the class name to open the object explorer. Sections: ivars, properties, methods, class methods, superclass chain. Long-press any selector to copy it. viewDidLoad / viewDidAppear: / layoutSubviews are the usual entry points; app-specific ones like -configureWithModel: or -reloadData are where the interesting data flows.",
                code: "// What you leave FLEX with:\nClass:     AMSettingsViewController\nSuper:     UITableViewController\nSelector:  -viewDidAppear:\nIvar:      _headerLabel (UILabel *)",
                codeTitle: "Notes to keep"),
            TutorialStep(
                title: "Verify at runtime before hooking",
                body: "Classes get renamed between app versions. Resolve them by string at runtime and log if they're missing — a nil class must never crash the host app.",
                code: "Class c = objc_getClass(\"AMSettingsViewController\");\nif (!c) { NSLog(@\"[MRvEK] class not found\"); return; }\nNSLog(@\"[MRvEK] found %@ (super %@)\", c, class_getSuperclass(c));",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Dump everything (optional)",
                body: "For a full class list without tapping around, use FLEX › Runtime Browser, or dump from code once and read it in Console. Search the dump for the strings you saw on screen — labels usually live near the class that owns them.",
                code: "unsigned int n = 0;\nMethod *ms = class_copyMethodList(objc_getClass(\"AMSettingsViewController\"), &n);\nfor (unsigned i = 0; i < n; i++) NSLog(@\"%@\", NSStringFromSelector(method_getName(ms[i])));\nfree(ms);",
                codeTitle: "Method dump"),
        ])

    // 2. Hook without Substrate
    static let hooking = Tutorial(
        id: "hook", icon: "link", title: "Hook a class without Substrate",
        subtitle: "ObjC runtime swizzling that works sideloaded", minutes: 8,
        steps: [
            TutorialStep(
                title: "Why not %hook",
                body: "Logos %hook compiles to MSHookMessageEx, which needs libsubstrate on the device. Sideloaded apps don't have it. Use generator=internal in the Makefile (the dylib template does this) or write the swizzle yourself — same result, zero dependencies, runs jailbroken or not."),
            TutorialStep(
                title: "The swizzle helper",
                body: "Add the replacement method to the class if it isn't there, otherwise exchange the two implementations. This copes with methods inherited from a superclass.",
                code: "static void mrvek_swizzle(Class cls, SEL orig, SEL repl) {\n    Method m1 = class_getInstanceMethod(cls, orig);\n    Method m2 = class_getInstanceMethod(cls, repl);\n    if (!cls || !m1 || !m2) return;\n    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2)))\n        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));\n    else\n        method_exchangeImplementations(m1, m2);\n}",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Write the replacement as a category",
                body: "Declare the new selector in a category on the class you captured (or on its UIKit superclass if the app class is private). Call the original by calling the swizzled name — after the exchange, that resolves to the real implementation.",
                code: "@interface UIViewController (MRvEK)\n- (void)mrvek_viewDidAppear:(BOOL)a;\n@end\n@implementation UIViewController (MRvEK)\n- (void)mrvek_viewDidAppear:(BOOL)a {\n    [self mrvek_viewDidAppear:a];   // original\n    if ([NSStringFromClass([self class]) isEqualToString:@\"AMSettingsViewController\"]) {\n        // your overlay here\n    }\n}\n@end",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Install from a constructor",
                body: "A __attribute__((constructor)) runs when the dylib loads, before the app's main. Resolve private classes by name here.",
                code: "__attribute__((constructor))\nstatic void mrvek_init(void) {\n    Class c = objc_getClass(\"AMSettingsViewController\") ?: [UIViewController class];\n    mrvek_swizzle(c, @selector(viewDidAppear:), @selector(mrvek_viewDidAppear:));\n}",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Read private ivars",
                body: "FLEX showed you _headerLabel. Pull it with the runtime instead of a header you don't have.",
                code: "Ivar iv = class_getInstanceVariable([self class], \"_headerLabel\");\nUILabel *label = iv ? object_getIvar(self, iv) : nil;\nlabel.text = @\"MRvEK Edition\";",
                codeTitle: "Ivar access"),
            TutorialStep(
                title: "Keep it idempotent",
                body: "viewDidAppear: fires every time the screen shows. Tag your added views and bail if the tag already exists, or you'll stack overlays.",
                code: "if ([self.view viewWithTag:0x4D5245]) return;\nbadge.tag = 0x4D5245;\n[self.view addSubview:badge];",
                codeTitle: "Guard"),
        ])

    // 3. Build + inject pipeline
    static let pipeline = Tutorial(
        id: "pipeline", icon: "arrow.triangle.branch", title: "Build & inject from your phone",
        subtitle: "Template → Push → Build tab → mSign", minutes: 6,
        steps: [
            TutorialStep(
                title: "Generate the dylib template",
                body: "Settings › Templates › Dylib. Name it, paste the target bundle id (FLEX › Info shows it, or mSign's IPA info), Generate. The workspace now holds Makefile, Tweak.xm, filter plist, control and a build.yml."),
            TutorialStep(
                title: "Push it",
                body: "Create an empty repo on github.com, set it in Settings › Repository, then Push. Your token needs Contents + Workflows: Read and write (the template contains .github/workflows)."),
            TutorialStep(
                title: "Watch it build",
                body: "Build tab › the run appears within seconds. Steps: Install Theos › Build › Upload dylib. Tap a run to follow the steps live. Red step = tap Open on GitHub for the log, fix Tweak.xm in Contents, Push again."),
            TutorialStep(
                title: "Download the artifact",
                body: "When the run completes, the artifacts list shows the build output. IPA artifacts jump straight into the Sign tab; a dylib artifact opens the share sheet — Save to Files, then add it as an extra dylib when signing."),
            TutorialStep(
                title: "Sign & install",
                body: "Sign tab › pick the target IPA › Sign with your cert › Install. The install runs over the on-device loopback OTA server, same as mSign. For dylib injection keep using mSign's extra-dylibs step (keep FLEX in while iterating). Console / FLEX › System Log shows your [Tweak] loaded line first.",
                tip: "Iterate: edit Tweak.xm in Contents → Push → Build → re-sign. Whole loop runs from the phone."),
            TutorialStep(
                title: "Ship",
                body: "Remove FLEX from the extra dylibs, bump Version in control, tag the release. Keep the handle only in About/credits — no real names in shipped builds."),
        ])
}

// MARK: - Tutorials list (table) — tap a row to open the tutorial

struct TutorialsListScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                        Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    Text("Tutorials").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
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

                List {
                    Section {
                        ForEach(TutorialLibrary.all) { t in
                            NavigationLink(value: t.id) {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14))
                                        Image(systemName: t.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                                    }.frame(width: 38, height: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                                        Text(t.subtitle).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(2)
                                        Text("\(t.steps.count) steps · ~\(t.minutes) min").font(.caption2.monospaced()).foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowBackground(Theme.card)
                        }
                    } header: {
                        Text("GUIDES").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                    } footer: {
                        Text("Everything here is done from the phone: GitHub sign-in, one linked repo, and this app. Check steps off as you go.")
                            .font(.caption2).foregroundStyle(Theme.subtle)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                TutorialScreen(tutorial: TutorialLibrary.all.first { $0.id == id } ?? TutorialLibrary.phoneOnly, pushed: true)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .tint(Theme.accent)
    }
}

// MARK: - Tutorial screen

struct TutorialScreen: View {
    let tutorial: Tutorial
    var pushed: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var done: Set<UUID> = []
    @State private var copied: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                }
                Text("Tutorial").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: pushed ? "chevron.left" : "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.bg)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(Array(tutorial.steps.enumerated()), id: \.element.id) { i, step in
                        stepCard(i + 1, step)
                    }
                    Text("Progress is per session. Work through the steps in order — each one assumes the previous.")
                        .font(.caption2).foregroundStyle(Theme.subtle).padding(.top, 4)
                }
                .padding(16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var header: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.14))
                    Image(systemName: tutorial.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                }.frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tutorial.title).font(.headline).foregroundStyle(Theme.text)
                    Text(tutorial.subtitle).font(.caption).foregroundStyle(Theme.subtle)
                    Text("\(tutorial.steps.count) steps · ~\(tutorial.minutes) min · \(done.count)/\(tutorial.steps.count) done")
                        .font(.caption2.monospaced()).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
        }
    }

    private func stepCard(_ n: Int, _ step: TutorialStep) -> some View {
        let isDone = done.contains(step.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if isDone { done.remove(step.id) } else { done.insert(step.id) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    ZStack {
                        Circle().fill(isDone ? Theme.accent : Theme.accent.opacity(0.14)).frame(width: 28, height: 28)
                        if isDone { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black) }
                        else { Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent) }
                    }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        .strikethrough(isDone, color: Theme.subtle)
                    Text(step.body).font(.system(size: 14)).foregroundStyle(Theme.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let code = step.code {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(step.codeTitle ?? "Code").font(.caption2.weight(.semibold)).foregroundStyle(Theme.subtle)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = code
                            copied = step.id
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == step.id { copied = nil } }
                        } label: {
                            Label(copied == step.id ? "Copied" : "Copy", systemImage: copied == step.id ? "checkmark" : "doc.on.doc")
                                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                            .padding(10)
                    }
                    .background(Theme.bg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.leading, 40)
            }
            if let tip = step.tip {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(.yellow)
                    Text(tip).font(.caption).foregroundStyle(Theme.subtle)
                }
                .padding(.leading, 40)
            }
        }
        .padding(14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isDone ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
