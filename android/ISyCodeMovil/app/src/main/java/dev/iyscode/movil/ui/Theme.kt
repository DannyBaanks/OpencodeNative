package dev.iyscode.movil.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** The "Consola" theme of the iOS app (Sources/UI/DesignSystem.swift). */
object Iys {
    val accent = Color(0xFF00D7A5)
    val accentSoft = Color(0x1F00D7A5)
    val bgDeep = Color(0xFF050807)
    val bgBase = Color(0xFF101412)
    val surface = Color(0xFF151D1A)
    val surfaceHigh = Color(0xFF1B2521)
    val border = Color(0x2E00D7A5)
    val textPrimary = Color(0xFFF2F2F2)
    val textSecondary = Color(0xFFAEAEAE)
    val textFaint = Color(0xFF808080)
    val green = Color(0xFF4ADE80)
    val yellow = Color(0xFFFACC15)
    val red = Color(0xFFF87171)
    val orange = Color(0xFFFB923C)
    val purple = Color(0xFFC084FC)
    val blue = Color(0xFF60A5FA)
}

private val mono = FontFamily.Monospace

private val typography = Typography(
    titleLarge = TextStyle(fontFamily = mono, fontWeight = FontWeight.Bold, fontSize = 18.sp),
    titleMedium = TextStyle(fontFamily = mono, fontWeight = FontWeight.SemiBold, fontSize = 14.sp),
    bodyLarge = TextStyle(fontFamily = mono, fontSize = 14.sp, lineHeight = 20.sp),
    bodyMedium = TextStyle(fontFamily = mono, fontSize = 12.sp, lineHeight = 17.sp),
    bodySmall = TextStyle(fontFamily = mono, fontSize = 10.sp, lineHeight = 14.sp),
    labelLarge = TextStyle(fontFamily = mono, fontWeight = FontWeight.SemiBold, fontSize = 12.sp),
    labelMedium = TextStyle(fontFamily = mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp),
    labelSmall = TextStyle(fontFamily = mono, fontWeight = FontWeight.SemiBold, fontSize = 9.sp),
)

@Composable
fun IysTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Iys.accent,
            onPrimary = Iys.bgDeep,
            secondary = Iys.accent,
            background = Iys.bgDeep,
            onBackground = Iys.textPrimary,
            surface = Iys.bgBase,
            onSurface = Iys.textPrimary,
            surfaceVariant = Iys.surface,
            onSurfaceVariant = Iys.textSecondary,
            surfaceContainer = Iys.bgBase,
            surfaceContainerHigh = Iys.surface,
            outline = Iys.border,
            error = Iys.red,
        ),
        typography = typography,
        content = content,
    )
}
