//
//  NotificationManager.swift
//  Certificate expiry notifications and alerts.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    private init() {
        requestAuthorization()
    }
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }
    
    /// Schedule certificate expiry notifications
    func scheduleExpiryNotifications(for certificates: [Certificate]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        
        for cert in certificates {
            guard let provisionData = try? Data(contentsOf: cert.provisionURL) else { continue }
            let profileInfo = CertificateStore.profileInfo(provisionData)
            guard let expiryDate = profileInfo.expirationDate else { continue }
            
            let daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day ?? 0
            
            // Schedule 7-day warning
            if daysRemaining == 7 {
                scheduleNotification(
                    title: "Certificate Expiring Soon",
                    body: "\(cert.name) expires in 7 days",
                    date: expiryDate.addingTimeInterval(-7 * 24 * 3600),
                    id: "cert-7day-\(cert.id)"
                )
            }
            
            // Schedule 1-day warning
            if daysRemaining == 1 {
                scheduleNotification(
                    title: "Certificate Expires Tomorrow",
                    body: "\(cert.name) expires tomorrow at \(expiryDate.formatted(time: .shortened))",
                    date: expiryDate.addingTimeInterval(-24 * 3600),
                    id: "cert-1day-\(cert.id)"
                )
            }
            
            // Schedule expiry notification
            if daysRemaining <= 0 {
                scheduleNotification(
                    title: "Certificate Expired",
                    body: "\(cert.name) has expired and can no longer sign apps",
                    date: expiryDate,
                    id: "cert-expired-\(cert.id)"
                )
            }
        }
    }
    
    /// Schedule backup reminder (monthly)
    func scheduleBackupReminder() {
        var dateComponents = DateComponents()
        dateComponents.day = 1
        dateComponents.hour = 9
        dateComponents.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let content = UNMutableNotificationContent()
        content.title = "Monthly Backup Reminder"
        content.body = "Back up your certificates to prevent data loss"
        content.sound = .default
        content.badge = NSNumber(value: UIApplication.shared.applicationIconBadgeNumber + 1)
        
        let request = UNNotificationRequest(identifier: "backup-reminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    
    /// Schedule failed signing alert
    func scheduleFailedSigningAlert(appName: String, reason: String) {
        scheduleNotification(
            title: "Signing Failed",
            body: "Failed to sign \(appName): \(reason)",
            date: Date().addingTimeInterval(2),
            id: "failed-sign-\(UUID().uuidString)"
        )
    }
    
    /// Schedule renewal reminder
    func scheduleRenewalReminder(for certificate: Certificate, daysUntilExpiry: Int) {
        if daysUntilExpiry <= 30 && daysUntilExpiry > 0 {
            scheduleNotification(
                title: "Renew Certificate",
                body: "Time to renew \(certificate.name) - expires in \(daysUntilExpiry) days",
                date: Date().addingTimeInterval(86400),
                id: "renew-\(certificate.id)"
            )
        }
    }
    
    private func scheduleNotification(title: String, body: String, date: Date, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: UIApplication.shared.applicationIconBadgeNumber + 1)
        content.userInfo = ["certID": id]
        
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date),
            repeats: false
        )
        
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }
}
