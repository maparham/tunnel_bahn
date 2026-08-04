package tunnelbahn.app.ui.icons

import androidx.compose.material.icons.Icons
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Icons vendored from androidx.compose.material:material-icons-extended.
 *
 * Only these three glyphs are used by the app and none of them ship in
 * material-icons-core, so we inline them here and depend on -core instead of
 * pulling the whole ~34 MB extended set into the build. Path data is a
 * verbatim reconstruction of the library's own ImageVectors; do not edit the
 * coordinates by hand. To add another icon, copy its path calls from the
 * material-icons-extended source rather than hand-writing coordinates.
 */

private var _speed: ImageVector? = null

val Icons.Filled.Speed: ImageVector
    get() {
        _speed?.let { return it }
        return ImageVector.Builder(
            name = "Filled.Speed",
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(20.38f, 8.57f)
                lineToRelative(-1.23f, 1.85f)
                arcToRelative(8.0f, 8.0f, 0.0f, false, true, -0.22f, 7.58f)
                lineTo(5.07f, 18.0f)
                arcTo(8.0f, 8.0f, 0.0f, false, true, 15.58f, 6.85f)
                lineToRelative(1.85f, -1.23f)
                arcTo(10.0f, 10.0f, 0.0f, false, false, 3.35f, 19.0f)
                arcToRelative(2.0f, 2.0f, 0.0f, false, false, 1.72f, 1.0f)
                horizontalLineToRelative(13.85f)
                arcToRelative(2.0f, 2.0f, 0.0f, false, false, 1.74f, -1.0f)
                arcToRelative(10.0f, 10.0f, 0.0f, false, false, -0.27f, -10.44f)
                close()
                moveTo(10.59f, 15.41f)
                arcToRelative(2.0f, 2.0f, 0.0f, false, false, 2.83f, 0.0f)
                lineToRelative(5.66f, -8.49f)
                lineToRelative(-8.49f, 5.66f)
                arcToRelative(2.0f, 2.0f, 0.0f, false, false, 0.0f, 2.83f)
                close()
            }
        }.build().also { _speed = it }
    }

private var _qrCodeScanner: ImageVector? = null

val Icons.Filled.QrCodeScanner: ImageVector
    get() {
        _qrCodeScanner?.let { return it }
        return ImageVector.Builder(
            name = "Filled.QrCodeScanner",
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
        ).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(9.5f, 6.5f)
                verticalLineToRelative(3.0f)
                horizontalLineToRelative(-3.0f)
                verticalLineToRelative(-3.0f)
                horizontalLineTo(9.5f)
                moveTo(11.0f, 5.0f)
                horizontalLineTo(5.0f)
                verticalLineToRelative(6.0f)
                horizontalLineToRelative(6.0f)
                verticalLineTo(5.0f)
                lineTo(11.0f, 5.0f)
                close()
                moveTo(9.5f, 14.5f)
                verticalLineToRelative(3.0f)
                horizontalLineToRelative(-3.0f)
                verticalLineToRelative(-3.0f)
                horizontalLineTo(9.5f)
                moveTo(11.0f, 13.0f)
                horizontalLineTo(5.0f)
                verticalLineToRelative(6.0f)
                horizontalLineToRelative(6.0f)
                verticalLineTo(13.0f)
                lineTo(11.0f, 13.0f)
                close()
                moveTo(17.5f, 6.5f)
                verticalLineToRelative(3.0f)
                horizontalLineToRelative(-3.0f)
                verticalLineToRelative(-3.0f)
                horizontalLineTo(17.5f)
                moveTo(19.0f, 5.0f)
                horizontalLineToRelative(-6.0f)
                verticalLineToRelative(6.0f)
                horizontalLineToRelative(6.0f)
                verticalLineTo(5.0f)
                lineTo(19.0f, 5.0f)
                close()
                moveTo(13.0f, 13.0f)
                horizontalLineToRelative(1.5f)
                verticalLineToRelative(1.5f)
                horizontalLineTo(13.0f)
                verticalLineTo(13.0f)
                close()
                moveTo(14.5f, 14.5f)
                horizontalLineTo(16.0f)
                verticalLineTo(16.0f)
                horizontalLineToRelative(-1.5f)
                verticalLineTo(14.5f)
                close()
                moveTo(16.0f, 13.0f)
                horizontalLineToRelative(1.5f)
                verticalLineToRelative(1.5f)
                horizontalLineTo(16.0f)
                verticalLineTo(13.0f)
                close()
                moveTo(13.0f, 16.0f)
                horizontalLineToRelative(1.5f)
                verticalLineToRelative(1.5f)
                horizontalLineTo(13.0f)
                verticalLineTo(16.0f)
                close()
                moveTo(14.5f, 17.5f)
                horizontalLineTo(16.0f)
                verticalLineTo(19.0f)
                horizontalLineToRelative(-1.5f)
                verticalLineTo(17.5f)
                close()
                moveTo(16.0f, 16.0f)
                horizontalLineToRelative(1.5f)
                verticalLineToRelative(1.5f)
                horizontalLineTo(16.0f)
                verticalLineTo(16.0f)
                close()
                moveTo(17.5f, 14.5f)
                horizontalLineTo(19.0f)
                verticalLineTo(16.0f)
                horizontalLineToRelative(-1.5f)
                verticalLineTo(14.5f)
                close()
                moveTo(17.5f, 17.5f)
                horizontalLineTo(19.0f)
                verticalLineTo(19.0f)
                horizontalLineToRelative(-1.5f)
                verticalLineTo(17.5f)
                close()
                moveTo(22.0f, 7.0f)
                horizontalLineToRelative(-2.0f)
                verticalLineTo(4.0f)
                horizontalLineToRelative(-3.0f)
                verticalLineTo(2.0f)
                horizontalLineToRelative(5.0f)
                verticalLineTo(7.0f)
                close()
                moveTo(22.0f, 22.0f)
                verticalLineToRelative(-5.0f)
                horizontalLineToRelative(-2.0f)
                verticalLineToRelative(3.0f)
                horizontalLineToRelative(-3.0f)
                verticalLineToRelative(2.0f)
                horizontalLineTo(22.0f)
                close()
                moveTo(2.0f, 22.0f)
                horizontalLineToRelative(5.0f)
                verticalLineToRelative(-2.0f)
                horizontalLineTo(4.0f)
                verticalLineToRelative(-3.0f)
                horizontalLineTo(2.0f)
                verticalLineTo(22.0f)
                close()
                moveTo(2.0f, 2.0f)
                verticalLineToRelative(5.0f)
                horizontalLineToRelative(2.0f)
                verticalLineTo(4.0f)
                horizontalLineToRelative(3.0f)
                verticalLineTo(2.0f)
                horizontalLineTo(2.0f)
                close()
            }
        }.build().also { _qrCodeScanner = it }
    }

private var _helpOutline: ImageVector? = null

val Icons.AutoMirrored.Filled.HelpOutline: ImageVector
    get() {
        _helpOutline?.let { return it }
        return ImageVector.Builder(
            name = "AutoMirrored.Filled.HelpOutline",
            defaultWidth = 24.dp,
            defaultHeight = 24.dp,
            viewportWidth = 24f,
            viewportHeight = 24f,
            autoMirror = true,
        ).apply {
            path(fill = SolidColor(Color.Black)) {
                moveTo(11.0f, 18.0f)
                horizontalLineToRelative(2.0f)
                verticalLineToRelative(-2.0f)
                horizontalLineToRelative(-2.0f)
                verticalLineToRelative(2.0f)
                close()
                moveTo(12.0f, 2.0f)
                curveTo(6.48f, 2.0f, 2.0f, 6.48f, 2.0f, 12.0f)
                reflectiveCurveToRelative(4.48f, 10.0f, 10.0f, 10.0f)
                reflectiveCurveToRelative(10.0f, -4.48f, 10.0f, -10.0f)
                reflectiveCurveTo(17.52f, 2.0f, 12.0f, 2.0f)
                close()
                moveTo(12.0f, 20.0f)
                curveToRelative(-4.41f, 0.0f, -8.0f, -3.59f, -8.0f, -8.0f)
                reflectiveCurveToRelative(3.59f, -8.0f, 8.0f, -8.0f)
                reflectiveCurveToRelative(8.0f, 3.59f, 8.0f, 8.0f)
                reflectiveCurveToRelative(-3.59f, 8.0f, -8.0f, 8.0f)
                close()
                moveTo(12.0f, 6.0f)
                curveToRelative(-2.21f, 0.0f, -4.0f, 1.79f, -4.0f, 4.0f)
                horizontalLineToRelative(2.0f)
                curveToRelative(0.0f, -1.1f, 0.9f, -2.0f, 2.0f, -2.0f)
                reflectiveCurveToRelative(2.0f, 0.9f, 2.0f, 2.0f)
                curveToRelative(0.0f, 2.0f, -3.0f, 1.75f, -3.0f, 5.0f)
                horizontalLineToRelative(2.0f)
                curveToRelative(0.0f, -2.25f, 3.0f, -2.5f, 3.0f, -5.0f)
                curveToRelative(0.0f, -2.21f, -1.79f, -4.0f, -4.0f, -4.0f)
                close()
            }
        }.build().also { _helpOutline = it }
    }
