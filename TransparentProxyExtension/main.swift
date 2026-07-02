import Foundation
import NetworkExtension
import os.log

func main() -> Never {
    autoreleasepool {
        let logger = AppLog(subsystem: "com.tunnelbahn.mac.transparentproxy", category: "main")
        logger.log("Extension process started")
        NEProvider.startSystemExtensionMode()
    }
    dispatchMain()
}

main()
