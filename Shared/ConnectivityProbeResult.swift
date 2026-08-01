import Foundation

enum ConnectivityProbeResult: Equatable {
    case unknown
    case ok
    case failed(String)
}
