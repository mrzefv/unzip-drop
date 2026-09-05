//
//  AppModels.swift
//  SIPA
//
//  JSON-based app repository models
//

import Foundation

// MARK: - App Repository Structure

struct AppRepository: Codable {
    let apps: [String] // References to app JSON files
}

struct AppRepositoryApp: Codable {
    let id: String
    let name: String
    let version: String
    let bundle: String
    let subtitle: String
    let description: String
    let iconURL: URL
    let sizeMB: String
    let downloadURL: URL?
    let sha256: String?
    let requiresSigning: Bool
    let minIOSVersion: String
    let screenshots: [URL]
    let updated: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, version, bundle, subtitle, description
        case iconURL = "icon"
        case sizeMB = "size"
        case downloadURL = "ipa_url"
        case sha256
        case requiresSigning = "requires_signing"
        case minIOSVersion = "min_ios_version"
        case screenshots
        case updated
    }
}
