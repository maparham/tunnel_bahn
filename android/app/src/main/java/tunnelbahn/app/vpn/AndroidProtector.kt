package tunnelbahn.app.vpn

import android.net.VpnService
import tunnelbahn.mobile.Protector

/**
 * Bridges the Go core's Protector to VpnService.protect(fd), keeping the carrier and
 * bypass sockets outside the tunnel so they do not route back into the tun.
 */
class AndroidProtector(private val vpn: VpnService) : Protector {
    override fun protect(fd: Long) {
        if (!vpn.protect(fd.toInt())) {
            throw IllegalStateException("VpnService.protect($fd) returned false")
        }
    }
}
