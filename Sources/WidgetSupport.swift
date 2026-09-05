//
//  WidgetSupport.swift
//  Lock screen and home screen widget support.
//

import Foundation
import WidgetKit

// App Groups identifier for widgets
let appGroupID = "group.com.mrzefv.unzipDrop"

struct WidgetData: Codable {
    struct CertificateWidget: Codable {
        let name: String
        let team: String?
        let daysUntilExpiry: Int?
        let isExpired: Bool
        let isActive: Bool
    }
    
    let activeCertificate: CertificateWidget?
    let totalCertificates: Int
    let certificatesExpiringSoon: Int
    let lastUpdated: Date
}

@MainActor
final class WidgetDataManager {
    static let shared = WidgetDataManager()
    
    func updateWidgetData(from store: CertificateStore) {
        guard let userDefaults = UserDefaults(suiteName: appGroupID) else { return }
        
        let activeCert = store.active
        let activeCertData: WidgetData.CertificateWidget?
        
        if let cert = activeCert,
           let provisionData = try? Data(contentsOf: cert.provisionURL) {
            let profileInfo = CertificateStore.profileInfo(provisionData)
            activeCertData = WidgetData.CertificateWidget(
                name: cert.name,
                team: profileInfo.team,
                daysUntilExpiry: profileInfo.daysUntilExpiry,
                isExpired: profileInfo.isExpired,
                isActive: true
            )
        } else {
            activeCertData = nil
        }
        
        let expiringSoon = store.certificates.filter { cert in
            guard let provisionData = try? Data(contentsOf: cert.provisionURL) else { return false }
            let profileInfo = CertificateStore.profileInfo(provisionData)
            return profileInfo.isExpiringSoon
        }.count
        
        let widgetData = WidgetData(
            activeCertificate: activeCertData,
            totalCertificates: store.certificates.count,
            certificatesExpiringSoon: expiringSoon,
            lastUpdated: Date()
        )
        
        if let encoded = try? JSONEncoder().encode(widgetData) {
            userDefaults.set(encoded, forKey: "widgetData")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    
    func retrieveWidgetData() -> WidgetData? {
        guard let userDefaults = UserDefaults(suiteName: appGroupID),
              let data = userDefaults.data(forKey: "widgetData"),
              let widgetData = try? JSONDecoder().decode(WidgetData.self, from: data) else {
            return nil
        }
        return widgetData
    }
}
