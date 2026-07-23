import Foundation
import NIOSSH

// Temporary: proves NIOSSH links into the system-extension target. Deleted in Task 4.
enum SSHLinkSmoke {
    static func referenceSymbol() -> String {
        String(describing: SSHClientConfiguration.self)
    }
}
