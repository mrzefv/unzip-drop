//
//  SearchAndFilter.swift
//  Advanced search and filtering for certificates.
//

import Foundation
import SwiftUI

enum CertificateFilter: String, CaseIterable {
    case all = "All"
    case active = "Active"
    case expiringSoon = "Expiring Soon"
    case expired = "Expired"
    case byTeam = "By Team"
    
    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .active: return "checkmark.seal.fill"
        case .expiringSoon: return "exclamationmark.triangle"
        case .expired: return "xmark.circle"
        case .byTeam: return "person.2"
        }
    }
}

enum SortOption: String, CaseIterable {
    case dateAdded = "Date Added"
    case expiryDate = "Expiry Date"
    case name = "Name"
    case team = "Team"
    
    var icon: String {
        switch self {
        case .dateAdded: return "calendar"
        case .expiryDate: return "clock"
        case .name: return "abc"
        case .team: return "person"
        }
    }
}

@MainActor
final class CertificateSearchManager: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedFilter: CertificateFilter = .all
    @Published var selectedSort: SortOption = .dateAdded
    @Published var selectedTeam: String? = nil
    @Published var sortAscending: Bool = false
    
    func filter(_ certificates: [Certificate], store: CertificateStore) -> [Certificate] {
        var filtered = certificates
        let infoByID = Dictionary(uniqueKeysWithValues: certificates.map { ($0.id, store.cachedProfileInfo(for: $0)) })
        func info(for cert: Certificate) -> ProfileInfo { infoByID[cert.id] ?? ProfileInfo() }
        
        // Apply text search
        if !searchText.isEmpty {
            filtered = filtered.filter { cert in
                if cert.name.localizedCaseInsensitiveContains(searchText) { return true }
                let profile = info(for: cert)
                return [profile.team, profile.name].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        
        // Apply status filter
        switch selectedFilter {
        case .all:
            break
        case .active:
            filtered = filtered.filter { $0.id == store.activeID }
        case .expiringSoon:
            filtered = filtered.filter { info(for: $0).isExpiringSoon }
        case .expired:
            filtered = filtered.filter { info(for: $0).isExpired }
        case .byTeam:
            if let team = selectedTeam {
                filtered = filtered.filter { info(for: $0).team == team }
            }
        }
        
        // Apply sorting
        filtered.sort { cert1, cert2 in
            let result: Bool
            
            switch selectedSort {
            case .dateAdded:
                result = cert1.addedAt > cert2.addedAt
            case .expiryDate:
                let exp1 = info(for: cert1).expirationDate
                let exp2 = info(for: cert2).expirationDate
                result = (exp1 ?? Date.distantFuture) > (exp2 ?? Date.distantFuture)
            case .name:
                result = cert1.name < cert2.name
            case .team:
                let team1 = info(for: cert1).team ?? ""
                let team2 = info(for: cert2).team ?? ""
                result = team1 < team2
            }
            
            return sortAscending ? !result : result
        }
        
        return filtered
    }
    
    func getTeams(from certificates: [Certificate]) -> [String] {
        var teams = Set<String>()
        for cert in certificates {
            if let provData = try? Data(contentsOf: cert.provisionURL) {
                let info = CertificateStore.profileInfo(provData)
                if let team = info.team {
                    teams.insert(team)
                }
            }
        }
        return Array(teams).sorted()
    }
}
