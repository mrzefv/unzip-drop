//
//  AppBrowseView.swift
//  SIPA
//
//  App Signer & OTA Distribution - Browse Tab
//  Inline expandable rows with screenshot carousel, no sheet navigation
//

import SwiftUI
import SDWebImageSwiftUI

// MARK: - App Browse View Store

@MainActor
final class AppBrowseStore: ObservableObject {
    @Published var apps: [AppRepositoryApp] = []
    @Published var isLoading = false
    @Published var error: String? = nil
    
    func loadApps() async {
        isLoading = true
        error = nil
        
        do {
            // Load repository.json from Bundle
            guard let repoURL = Bundle.main.url(forResource: "repository", withExtension: "json") else {
                error = "Repository config not found"
                isLoading = false
                return
            }
            
            let repoData = try Data(contentsOf: repoURL)
            let repo = try JSONDecoder().decode(AppRepository.self, from: repoData)
            
            var loadedApps: [AppRepositoryApp] = []
            
            // Load each app JSON file
            for appFileName in repo.apps {
                let name = appFileName.replacingOccurrences(of: ".json", with: "")
                if let appURL = Bundle.main.url(forResource: name, withExtension: "json") {
                    let appData = try Data(contentsOf: appURL)
                    let app = try JSONDecoder().decode(AppRepositoryApp.self, from: appData)
                    loadedApps.append(app)
                }
            }
            
            self.apps = loadedApps.sorted { a, b in
                a.updated ?? "" > b.updated ?? ""
            }
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - Main Browse View

struct AppBrowseView: View {
    @StateObject private var store = AppBrowseStore()
    @State private var expandedAppId: String? = nil
    @State private var searchText = ""
    
    @AppStorage("appAppearance") private var appAppearance = "dark"
    @AppStorage("appTintColorHex") private var appTintColorHex = "2EF262"
    
    private var accent: Color {
        Color(hex: appTintColorHex) ?? .green
    }
    
    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
    
    var filteredApps: [AppRepositoryApp] {
        if searchText.isEmpty {
            return store.apps
        }
        return store.apps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
            app.bundle.localizedCaseInsensitiveContains(searchText) ||
            app.subtitle.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        ZStack {
            // Background
            Color(red: 0.06, green: 0.06, blue: 0.06)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 10) {
                    Text("App Repository")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    // Search Bar
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white.opacity(0.5))
                        
                        TextField("Search apps...", text: $searchText)
                            .foregroundColor(.white)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                
                // Content
                if store.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(accent)
                        Text("Loading apps...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red.opacity(0.8))
                        Text("Error")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: { Task { await store.loadApps() } }) {
                            Text("Retry")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                                .background(accent)
                                .cornerRadius(8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if filteredApps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No apps found")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(filteredApps, id: \.id) { app in
                                AppRowView(
                                    app: app,
                                    isExpanded: expandedAppId == app.id,
                                    accent: accent,
                                    onTap: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedAppId = expandedAppId == app.id ? nil : app.id
                                        }
                                    }
                                )
                                
                                if app.id != filteredApps.last?.id {
                                    Divider()
                                        .opacity(0.12)
                                        .padding(.horizontal, 16)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .task {
            await store.loadApps()
        }
    }
}

// MARK: - App Row View (Expandable)

struct AppRowView: View {
    let app: AppRepositoryApp
    let isExpanded: Bool
    let accent: Color
    let onTap: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Tap to expand
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // App Icon
                    WebImage(url: app.iconURL)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .cornerRadius(14)
                        .background(Color.white.opacity(0.08))
                    
                    // App Info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Text(app.bundle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.white.opacity(0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            
            // Expanded Details
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().opacity(0.12)
                    
                    // Description
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                        
                        Text(app.description)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(3)
                    }
                    
                    // Screenshot Carousel
                    if !app.screenshots.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Screenshots")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                            
                            ScreenshotCarouselView(screenshots: app.screenshots, accent: accent)
                        }
                    }
                    
                    // App Metadata
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Version")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            Text(app.version)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        Divider().frame(height: 24)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Size")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            Text(app.sizeMB)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        Divider().frame(height: 24)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iOS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            Text(app.minIOSVersion)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        Spacer()
                    }
                    
                    // Download & Sign Button
                    Button(action: {}) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download & Sign")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(accent)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(12)
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Screenshot Carousel

struct ScreenshotCarouselView: View {
    let screenshots: [URL]
    let accent: Color
    
    @State private var currentIndex = 0
    
    var body: some View {
        VStack(spacing: 10) {
            // Carousel
            TabView(selection: $currentIndex) {
                ForEach(0..<screenshots.count, id: \.self) { index in
                    WebImage(url: screenshots[index])
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 250)
                        .cornerRadius(12)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 250)
            .cornerRadius(12)
            
            // Dot Indicators
            HStack(spacing: 6) {
                ForEach(0..<screenshots.count, id: \.self) { index in
                    Capsule()
                        .fill(index == currentIndex ? accent : Color.white.opacity(0.3))
                        .frame(width: index == currentIndex ? 24 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
                Spacer()
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Preview

#Preview {
    AppBrowseView()
        .preferredColorScheme(.dark)
}
