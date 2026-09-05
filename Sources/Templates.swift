//
//  Templates.swift
//  Ready-to-push project templates. Each renders to a file list that Session
//  loads as the workspace; Push sends it to a repo; the Build tab runs it.
//

import Foundation

enum ProjectTemplate {

    // MARK: - Dylib (Theos, runtime swizzling, no Substrate needed)

    /// `name`: tweak name, e.g. MRvEKAware. `target`: bundle id of the app the
    /// dylib is injected into (used for the filter plist + README).
    static func dylib(name rawName: String, target: String, author: String = "MRzefv") -> [(path: String, content: String)] {
        let name = sanitize(rawName, fallback: "MRvEKTweak")
        let lower = name.lowercased()
        let target = target.isEmpty ? "com.example.app" : target

        let makefile = """
        TARGET := iphone:clang:latest:15.0
        ARCHS := arm64
        THEOS_PACKAGE_SCHEME := rootless

        include $(THEOS)/makefiles/common.mk

        TWEAK_NAME = \(name)

        \(name)_FILES = Tweak.xm
        \(name)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
        \(name)_FRAMEWORKS = UIKit Foundation
        # No libsubstrate: hooks below use the ObjC runtime directly so the dylib
        # also works when sideloaded (mSign / DELvEK inject it as an extra dylib).
        \(name)_LOGOSFLAGS = -c generator=internal

        include $(THEOS)/makefiles/tweak.mk
        """

        let tweak = """
        //
        //  Tweak.xm — \(name)
        //  Target: \(target)
        //
        //  Pattern: pure ObjC-runtime swizzle (no Substrate), so the same dylib
        //  works jailbroken AND sideloaded. Class names come from FLEX — see the
        //  "Capture class names with FLEX" tutorial in Unzip Drop › Settings.
        //

        #import <UIKit/UIKit.h>
        #import <objc/runtime.h>

        #define TWEAK_LOG(fmt, ...) NSLog(@"[\(name)] " fmt, ##__VA_ARGS__)

        // ---------------------------------------------------------------------
        // MARK: Swizzle helper
        // ---------------------------------------------------------------------
        static void \(lower)_swizzle(Class cls, SEL orig, SEL repl) {
            if (!cls) { TWEAK_LOG(@"class missing for %@", NSStringFromSelector(orig)); return; }
            Method m1 = class_getInstanceMethod(cls, orig);
            Method m2 = class_getInstanceMethod(cls, repl);
            if (!m1 || !m2) { TWEAK_LOG(@"method missing: %@", NSStringFromSelector(orig)); return; }
            if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
                class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
            } else {
                method_exchangeImplementations(m1, m2);
            }
        }

        // ---------------------------------------------------------------------
        // MARK: Overlay (edit freely)
        // ---------------------------------------------------------------------
        static UIView *\(lower)_badge(void) {
            UILabel *l = [[UILabel alloc] init];
            l.text = @"  \(name) · by \(author)  ";
            l.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
            l.textColor = [UIColor colorWithRed:0.18 green:0.85 blue:0.76 alpha:1];
            l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
            l.layer.cornerRadius = 8; l.clipsToBounds = YES;
            [l sizeToFit];
            l.frame = CGRectInset(l.frame, -4, -4);
            l.tag = 0x\(stableTag(name));
            return l;
        }

        // ---------------------------------------------------------------------
        // MARK: Hooks — replace UIViewController with the class FLEX showed you
        // (e.g. "AMSettingsViewController") and viewDidAppear: with the method.
        // ---------------------------------------------------------------------
        @interface UIViewController (\(name))
        - (void)\(lower)_viewDidAppear:(BOOL)animated;
        @end

        @implementation UIViewController (\(name))
        - (void)\(lower)_viewDidAppear:(BOOL)animated {
            [self \(lower)_viewDidAppear:animated];   // call original

            // Only decorate the screen you care about.
            NSString *cls = NSStringFromClass([self class]);
            if (![cls containsString:@"Settings"]) return;

            NSInteger tag = 0x\(stableTag(name));
            if ([self.view viewWithTag:tag]) return;
            UIView *b = \(lower)_badge();
            CGFloat top = self.view.safeAreaInsets.top + 8;
            b.center = CGPointMake(self.view.bounds.size.width / 2, top + b.bounds.size.height / 2);
            b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
            [self.view addSubview:b];
            TWEAK_LOG(@"badge added on %@", cls);
        }
        @end

        // ---------------------------------------------------------------------
        // MARK: Entry
        // ---------------------------------------------------------------------
        __attribute__((constructor))
        static void \(lower)_init(void) {
            TWEAK_LOG(@"loaded into %@", [NSBundle mainBundle].bundleIdentifier);

            // Swizzle a UIKit class: always present, safe on any app.
            \(lower)_swizzle([UIViewController class], @selector(viewDidAppear:), @selector(\(lower)_viewDidAppear:));

            // Hook an app-private class captured with FLEX (resolved by name so a
            // missing class never crashes the app):
            //   Class c = objc_getClass("AMSettingsViewController");
            //   \(lower)_swizzle(c, @selector(viewDidLoad), @selector(\(lower)_viewDidLoad));
        }
        """

        let filter = """
        {
            Filter = {
                Bundles = ( "\(target)" );
            };
        }
        """

        let control = """
        Package: com.\(author.lowercased()).\(lower)
        Name: \(name)
        Version: 1.0.0
        Architecture: iphoneos-arm64
        Description: \(name) — runtime overlay for \(target)
        Maintainer: \(author)
        Author: \(author)
        Section: Tweaks
        Depends: firmware (>= 15.0)
        """

        let workflow = """
        name: build-dylib

        on:
          push:
            branches: [ main ]
          workflow_dispatch:

        jobs:
          build:
            runs-on: macos-14
            env:
              THEOS: /Users/runner/theos
            steps:
              - name: Checkout
                uses: actions/checkout@v4

              - name: Select newest Xcode
                run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"

              - name: Install Theos
                run: |
                  git clone --recursive https://github.com/theos/theos.git "$THEOS"
                  curl -sL https://github.com/theos/sdks/archive/master.zip -o sdks.zip
                  unzip -q sdks.zip
                  mkdir -p "$THEOS/sdks"
                  cp -R sdks-master/*.sdk "$THEOS/sdks/"
                  ls "$THEOS/sdks"

              - name: Build \(name).dylib
                run: |
                  export PATH="$THEOS/bin:$PATH"
                  make clean
                  make DEBUG=0 FINALPACKAGE=1 2>&1 | tee build.log
                  mkdir -p out
                  cp .theos/obj/\(name).dylib out/\(name).dylib
                  cp \(name).plist out/\(name).plist || true
                  ls -la out

              - name: Upload dylib
                uses: actions/upload-artifact@v4
                with:
                  name: \(name)-dylib
                  path: out/

              - name: Error summary (on failure)
                if: failure()
                run: grep -nE "error:|fatal error:|Command .* failed" build.log | head -40 || true
        """

        let readme = """
        # \(name)

        Runtime overlay dylib for `\(target)`. Built by GitHub Actions (Theos, arm64,
        no Substrate) — download `\(name)-dylib` from the workflow run, then inject it
        with mSign / DELvEK as an extra dylib, or drop it into a jailbroken device.

        ## Files
        - `Tweak.xm` — swizzle helper + hooks. Replace the example class/selector with
          the ones you captured in FLEX.
        - `\(name).plist` — bundle filter (only loads inside `\(target)`).
        - `Makefile` — Theos build, `generator=internal` so no libsubstrate dependency.
        - `.github/workflows/build.yml` — builds on push and on manual dispatch.

        ## Capture class names
        1. Inject FLEX.dylib into the target IPA (mSign › extra dylibs), sideload.
        2. Shake → FLEX › Select → tap the view → note the class in the breadcrumb.
        3. Tap the class → Methods → find the selector you want to hook.
        4. `objc_getClass("TheClass")` + `\(lower)_swizzle(...)` in `\(lower)_init`.

        See the tutorials inside Unzip Drop › Settings for the full walkthrough.

        — \(author)
        """

        return [
            ("Makefile", makefile),
            ("Tweak.xm", tweak),
            ("\(name).plist", filter),
            ("control", control),
            (".github/workflows/build.yml", workflow),
            ("README.md", readme),
            (".gitignore", ".theos/\npackages/\nout/\n*.dylib\n.DS_Store\n"),
        ]
    }

    // MARK: - IPA app (SwiftUI, XcodeGen, unsigned build via Actions)

    static func ipaApp(name rawName: String, bundleID rawBundle: String, author: String = "MRzefv") -> [(path: String, content: String)] {
        let name = sanitize(rawName, fallback: "MRvEKApp")
        let bundle = rawBundle.isEmpty ? "party.mrvek.\(name.lowercased())" : rawBundle

        let projectYML = """
        name: \(name)
        options:
          bundleIdPrefix: \(bundle.split(separator: ".").dropLast().joined(separator: "."))
          deploymentTarget:
            iOS: "16.0"
          createIntermediateGroups: true
        settings:
          base:
            SWIFT_VERSION: "5.9"
            TARGETED_DEVICE_FAMILY: "1"
            CODE_SIGNING_ALLOWED: "NO"
            CODE_SIGNING_REQUIRED: "NO"
            CODE_SIGN_IDENTITY: ""
            DEVELOPMENT_TEAM: ""
            MARKETING_VERSION: "1.0"
            CURRENT_PROJECT_VERSION: "1"
        targets:
          \(name):
            type: application
            platform: iOS
            sources:
              - path: Sources
              - path: Assets.xcassets
            info:
              path: Info.plist
              properties:
                CFBundleDisplayName: \(name)
                CFBundleIdentifier: \(bundle)
                UILaunchScreen:
                  UIColorName: LaunchBackground
                UIRequiresFullScreen: true
                UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
                UIStatusBarStyle: UIStatusBarStyleLightContent
                UIViewControllerBasedStatusBarAppearance: true
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: \(bundle)
                ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
                ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
                GENERATE_INFOPLIST_FILE: "NO"
        """

        let app = """
        //
        //  \(name)App.swift
        //

        import SwiftUI

        @main
        struct \(name)App: App {
            var body: some Scene {
                WindowGroup {
                    RootView().preferredColorScheme(.dark)
                }
            }
        }
        """

        let theme = """
        //
        //  Theme.swift
        //

        import SwiftUI

        enum Theme {
            static let bg     = Color(red: 0.04, green: 0.05, blue: 0.06)
            static let card   = Color(red: 0.09, green: 0.11, blue: 0.12)
            static let stroke = Color.white.opacity(0.06)
            static let accent = Color(red: 0.18, green: 0.85, blue: 0.76)
            static let text   = Color(red: 0.92, green: 0.95, blue: 0.95)
            static let subtle = Color(red: 0.55, green: 0.60, blue: 0.62)
            static let appName = "\(name)"
            static let owner   = "\(author)"
        }

        struct Card<Content: View>: View {
            @ViewBuilder var content: Content
            var body: some View {
                content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        """

        let root = """
        //
        //  RootView.swift — custom shell: pinned header, content, docked tab bar.
        //

        import SwiftUI

        struct RootView: View {
            @State private var tab = 0

            var body: some View {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                        Text(Theme.appName.uppercased())
                            .font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1)
                            .foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

                    ZStack {
                        switch tab {
                        case 0: HomeView()
                        default: SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    HStack(spacing: 0) {
                        tabButton(0, "Home", "house.fill")
                        tabButton(1, "Settings", "gearshape.fill")
                    }
                    .frame(height: 50).padding(.top, 8)
                    .background(Theme.bg.overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .top).ignoresSafeArea(edges: .bottom))
                }
                .background(Theme.bg.ignoresSafeArea())
            }

            private func tabButton(_ i: Int, _ label: String, _ icon: String) -> some View {
                Button { tab = i } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 20))
                        Text(label).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tab == i ? Theme.accent : Theme.subtle)
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        struct HomeView: View {
            var body: some View {
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Hello from \(name)").font(.title2.bold()).foregroundStyle(Theme.text)
                                Text("Built unsigned by GitHub Actions. Sign with mSign and install.")
                                    .font(.caption).foregroundStyle(Theme.subtle)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }

        struct SettingsView: View {
            var body: some View {
                ScrollView {
                    VStack(spacing: 14) {
                        Card {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Theme.appName).font(.headline).foregroundStyle(Theme.text)
                                    Text("by \\(Theme.owner)").font(.caption).foregroundStyle(Theme.subtle)
                                }
                                Spacer()
                                Image(systemName: "signature").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        """

        let assetsRoot = "{ \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }\n"
        let accent = """
        {
          "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "red" : "0.180", "green" : "0.850", "blue" : "0.760", "alpha" : "1.000" } }, "idiom" : "universal" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let launchBG = """
        {
          "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "red" : "0.040", "green" : "0.050", "blue" : "0.060", "alpha" : "1.000" } }, "idiom" : "universal" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let appIcon = """
        {
          "images" : [ { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """

        let workflow = """
        name: build-ipa

        on:
          push:
            branches: [ main ]
          workflow_dispatch:

        env:
          SCHEME: \(name)
          CONFIG: Release

        jobs:
          build:
            runs-on: macos-14
            steps:
              - name: Checkout
                uses: actions/checkout@v4

              - name: Select newest Xcode
                run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"

              - name: Generate Xcode project
                run: |
                  brew install xcodegen
                  xcodegen generate

              - name: Build (unsigned, device)
                run: |
                  set -o pipefail
                  xcodebuild -project \(name).xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \\
                    -destination 'generic/platform=iOS' -derivedDataPath build \\
                    ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \\
                    CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" clean build 2>&1 | tee build.log

              - name: Package .ipa
                run: |
                  APP=$(find build/Build/Products/$CONFIG-iphoneos -maxdepth 1 -name "*.app" | head -1)
                  mkdir -p Payload && cp -R "$APP" Payload/
                  zip -qr "\(name).ipa" Payload
                  ls -la "\(name).ipa"

              - name: Upload IPA
                uses: actions/upload-artifact@v4
                with:
                  name: \(name)-ipa
                  path: \(name).ipa

              - name: Error summary (on failure)
                if: failure()
                run: grep -nE "error:|fatal error:|Command .* failed" build.log | head -40 || true
        """

        let readme = """
        # \(name)

        SwiftUI iOS app, bundle id `\(bundle)`. The Xcode project is generated on the
        runner with XcodeGen from `project.yml`, built unsigned, and uploaded as
        `\(name)-ipa`. Download from the Build tab, sign with mSign, install.

        Add Swift files under `Sources/` — they're picked up automatically.

        — \(author)
        """

        return [
            ("project.yml", projectYML),
            ("Sources/\(name)App.swift", app),
            ("Sources/Theme.swift", theme),
            ("Sources/RootView.swift", root),
            ("Assets.xcassets/Contents.json", assetsRoot),
            ("Assets.xcassets/AccentColor.colorset/Contents.json", accent),
            ("Assets.xcassets/LaunchBackground.colorset/Contents.json", launchBG),
            ("Assets.xcassets/AppIcon.appiconset/Contents.json", appIcon),
            (".github/workflows/build.yml", workflow),
            ("README.md", readme),
            (".gitignore", "build/\n*.xcodeproj\n*.ipa\nPayload/\n.DS_Store\n"),
        ]
    }

    // MARK: - Helpers

    /// Deterministic 6-hex-digit view tag derived from the name (hashValue is per-process).
    private static func stableTag(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(format: "%06X", h & 0xFFFFFF)
    }

    private static func sanitize(_ s: String, fallback: String) -> String {
        let allowed = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        var out = String(String.UnicodeScalarView(allowed))
        if let f = out.first, f.isNumber { out = "X" + out }
        return out.isEmpty ? fallback : out
    }
}
