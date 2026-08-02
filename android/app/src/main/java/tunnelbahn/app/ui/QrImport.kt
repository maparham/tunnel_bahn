package tunnelbahn.app.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts.RequestPermission
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import tunnelbahn.app.profile.Profile
import tunnelbahn.app.profile.QRImportResult
import tunnelbahn.app.profile.parseImportedProfile
import java.util.UUID

/** Returns a callback that requests camera permission, launches the ZXing scanner, and routes
 *  the decoded payload to [onImported] or [onError]. ZXing runs without Google Play Services. */
@Composable
fun rememberQrImport(
    onImported: (Profile) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val scan = rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@rememberLauncherForActivityResult // user cancelled
        when (val r = parseImportedProfile(contents, UUID.randomUUID().toString())) {
            is QRImportResult.Ok -> onImported(r.profile)
            is QRImportResult.Error -> onError(r.reason)
        }
    }
    val options = remember {
        ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setBeepEnabled(false)
            .setOrientationLocked(false)
            .setPrompt("Scan the TunnelBahn desktop QR")
    }
    val permission = rememberLauncherForActivityResult(RequestPermission()) { granted ->
        if (granted) scan.launch(options) else onError("Camera permission is needed to scan.")
    }
    return { permission.launch(Manifest.permission.CAMERA) }
}
