//
//  CertificateAnalytics.swift
//  Analytics and statistics for certificates and signing.
//

import Foundation
import SwiftUI

struct SigningSession: Codable, Identifiable {
    let id: String
    let appName: String
    let bundleID: String
    let certificateName: String
    let startTime: Date
    let endTime: Date
    let success: Bool
    let ipaSize: Int
    let errorMessage: String?
    
    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
    var formattedDuration: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            return String(format: "%.1f min", duration / 60)
        }
    }
}

@MainActor
final class AnalyticsManager: ObservableObject {
    static let shared = AnalyticsManager()
    
    @Published private(set) var sessions: [SigningSession] = []
    @Published private(set) var stats: AnalyticsStats = .empty
    
    private let analyticsURL = AppPaths.dir("analytics").appendingPathComponent("sessions.json")
    
    struct AnalyticsStats {
        var totalSessions: Int = 0
        var successfulSessions: Int = 0
        var failedSessions: Int = 0
        var averageSigningTime: TimeInterval = 0
        var mostUsedCertificate: String = "None"
        var totalDataSigned: Int = 0
        var successRate: Double = 0
        
        static let empty = AnalyticsStats()
    }
    
    private init() {
        loadSessions()
        calculateStats()
    }
    
    /// Record a signing session
    func recordSession(
        appName: String,
        bundleID: String,
        certificateName: String,
        startTime: Date,
        ipaSize: Int,
        success: Bool,
        error: String? = nil
    ) {
        let session = SigningSession(
            id: UUID().uuidString,
            appName: appName,
            bundleID: bundleID,
            certificateName: certificateName,
            startTime: startTime,
            endTime: Date(),
            success: success,
            ipaSize: ipaSize,
            errorMessage: error
        )
        
        sessions.insert(session, at: 0)
        saveSessions()
        calculateStats()
    }
    
    /// Get sessions for date range
    func sessionsInRange(_ range: ClosedRange<Date>) -> [SigningSession] {
        sessions.filter { $0.startTime >= range.lowerBound && $0.startTime <= range.upperBound }
    }
    
    /// Get sessions for specific certificate
    func sessionsForCertificate(_ name: String) -> [SigningSession] {
        sessions.filter { $0.certificateName == name }
    }
    
    /// Get sessions for specific app
    func sessionsForApp(_ bundleID: String) -> [SigningSession] {
        sessions.filter { $0.bundleID == bundleID }
    }
    
    /// Export analytics as CSV
    func exportAsCSV() -> String {
        var csv = "Date,App,Bundle ID,Certificate,Duration,Size,Status,Error\n"
        for session in sessions {
            let dateStr = session.startTime.formatted(date: .abbreviated, time: .shortened)
            let sizeStr = formatBytes(session.ipaSize)
            let status = session.success ? "Success" : "Failed"
            let error = session.errorMessage ?? ""
            csv += "\(dateStr),\(session.appName),\(session.bundleID),\(session.certificateName),\(session.formattedDuration),\(sizeStr),\(status),\(error)\n"
        }
        return csv
    }
    
    /// Clear old sessions (older than 90 days)
    func clearOldSessions() {
        let ninetyDaysAgo = Date().addingTimeInterval(-90 * 24 * 3600)
        sessions.removeAll { $0.startTime < ninetyDaysAgo }
        saveSessions()
    }
    
    private func calculateStats() {
        guard !sessions.isEmpty else {
            stats = .empty
            return
        }
        
        let successful = sessions.filter { $0.success }.count
        let failed = sessions.filter { !$0.success }.count
        let avgTime = sessions.map { $0.duration }.reduce(0, +) / Double(sessions.count)
        
        let certCounts = Dictionary(grouping: sessions, by: { $0.certificateName })
        let mostUsed = certCounts.max { $0.value.count < $1.value.count }?.key ?? "None"
        
        let totalSize = sessions.reduce(0) { $0 + $1.ipaSize }
        let successRate = Double(successful) / Double(sessions.count)
        
        stats = AnalyticsStats(
            totalSessions: sessions.count,
            successfulSessions: successful,
            failedSessions: failed,
            averageSigningTime: avgTime,
            mostUsedCertificate: mostUsed,
            totalDataSigned: totalSize,
            successRate: successRate
        )
    }
    
    private func loadSessions() {
        guard let data = try? Data(contentsOf: analyticsURL),
              let decoded = try? JSONDecoder().decode([SigningSession].self, from: data) else {
            sessions = []
            return
        }
        sessions = decoded.sorted { $0.startTime > $1.startTime }
    }
    
    private func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            try? encoded.write(to: analyticsURL)
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
