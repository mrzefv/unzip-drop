//
//  App.swift
//  unzip-drop — drop a zip, extract on-device, push it to a repo.
//

import SwiftUI

@main
struct UnzipDropApp: App {
    @StateObject private var session = Session()
    @StateObject private var config = Config()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(config)
                .onOpenURL { url in session.receiveIncoming(url) }
        }
    }
}
