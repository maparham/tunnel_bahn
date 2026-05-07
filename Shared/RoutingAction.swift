import Foundation

enum RoutingAction: String, Codable, CaseIterable {
    case routeVPN = "route_vpn"
    case bypass = "bypass"

    var title: String {
        switch self {
        case .routeVPN:
            return "Route via VPN"
        case .bypass:
            return "Bypass VPN"
        }
    }
}

