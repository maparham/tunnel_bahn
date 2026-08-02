package tunnelbahn.app.profile

import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

sealed interface QRImportResult {
    data class Ok(val profile: Profile) : QRImportResult
    data class Error(val reason: String) : QRImportResult
}

@Serializable
private data class QRPayload(
    val kind: String = "",
    val name: String = "",
    val transport: String = "",
    val ssh: QRSsh? = null,
    val wg: QRWg? = null,
)

@Serializable
private data class QRSsh(val addr: String = "", val user: String = "", val privateKeyPEM: String = "")

@Serializable
private data class QRWg(
    val privateKey: String = "",
    val peerPublicKey: String = "",
    val presharedKey: String = "",
    val localAddrs: List<String> = emptyList(),
    val dns: List<String> = emptyList(),
    val mtu: Int = 1280,
    val wsURL: String = "",
    val forwardHost: String = "",
    val forwardPort: Int = 0,
)

private val importJson = Json { ignoreUnknownKeys = true }

/** Parses a scanned QR payload into a [Profile] with id [newId]. [newId] is injected so this
 *  stays pure and unit-testable. */
fun parseImportedProfile(raw: String, newId: String): QRImportResult {
    val payload = try {
        importJson.decodeFromString(QRPayload.serializer(), raw)
    } catch (_: SerializationException) {
        return QRImportResult.Error("Not a valid TunnelBahn QR code.")
    } catch (_: IllegalArgumentException) {
        return QRImportResult.Error("Not a valid TunnelBahn QR code.")
    }
    if (payload.kind != "tunnelbahn.profile") {
        return QRImportResult.Error("Not a TunnelBahn profile QR code.")
    }
    return when (payload.transport) {
        "ssh" -> {
            val s = payload.ssh ?: return QRImportResult.Error("QR is missing SSH details.")
            QRImportResult.Ok(
                Profile(
                    id = newId,
                    name = payload.name,
                    transport = Transport.SSH,
                    endpoint = s.addr,
                    sshUser = s.user,
                    sshPrivateKeyPem = s.privateKeyPEM,
                    sshHostKeyAuthorized = "", // TOFU on first connect
                )
            )
        }
        "wgws" -> {
            val w = payload.wg ?: return QRImportResult.Error("QR is missing WireGuard details.")
            QRImportResult.Ok(
                Profile(
                    id = newId,
                    name = payload.name,
                    transport = Transport.WGWS,
                    wgPrivateKey = w.privateKey,
                    wgPeerPublicKey = w.peerPublicKey,
                    wgPresharedKey = w.presharedKey,
                    wgLocalAddrs = w.localAddrs,
                    wgDns = w.dns,
                    wgMtu = w.mtu,
                    wsUrl = w.wsURL,
                    wsForwardHost = w.forwardHost,
                    wsForwardPort = w.forwardPort,
                )
            )
        }
        else -> QRImportResult.Error("Unknown transport in QR code.")
    }
}
