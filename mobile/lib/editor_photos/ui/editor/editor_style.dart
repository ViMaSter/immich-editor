// Colours and theme of the photo editor (dark, like Google Photos; see editor.css).
import 'package:flutter/material.dart';

abstract final class EditorColors {
  static const stage = Color(0xFF000000);
  static const panel = Color(0xFF1B1B1F);
  static const panel2 = Color(0xFF26272B);
  static const panelHover = Color(0xFF303136);
  static const text = Color(0xFFE3E3E8);
  static const muted = Color(0xFFA7A9B4);
  static const accent = Color(0xFFA8C7FA);
  static const accentText = Color(0xFF062E6F);
  static const track = Color(0xFF0B3A5C);
  static const danger = Color(0xFFF2B8B5);
  static const divider = Color(0xFF2E2F33);
  static const dialog = Color(0xFF2B2C30);
  static const outline = Color(0xFF5F6368);
  static const curveBackground = Color(0xFF141417);
}

ThemeData editorTheme(ThemeData base) {
  const scheme = ColorScheme.dark(
    primary: EditorColors.accent,
    onPrimary: EditorColors.accentText,
    secondary: EditorColors.accent,
    onSecondary: EditorColors.accentText,
    surface: EditorColors.panel,
    onSurface: EditorColors.text,
    surfaceContainerHigh: EditorColors.dialog,
    error: EditorColors.danger,
    outline: EditorColors.outline,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: base.textTheme.bodyMedium?.fontFamily,
    scaffoldBackgroundColor: EditorColors.stage,
    dividerColor: EditorColors.divider,
    iconTheme: const IconThemeData(color: EditorColors.text),
    dialogTheme: const DialogThemeData(
      backgroundColor: EditorColors.dialog,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
      titleTextStyle: TextStyle(fontSize: 22, fontWeight: FontWeight.w400, color: EditorColors.text),
      contentTextStyle: TextStyle(fontSize: 15, color: EditorColors.muted),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: EditorColors.accent,
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: EditorColors.accent,
        foregroundColor: EditorColors.accentText,
        disabledBackgroundColor: EditorColors.accent.withValues(alpha: 0.38),
        disabledForegroundColor: EditorColors.accentText.withValues(alpha: 0.6),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: EditorColors.accent,
        side: const BorderSide(color: EditorColors.outline),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: EditorColors.accent,
      linearTrackColor: Color(0x33FFFFFF),
    ),
  );
}

/// "Suggested for this photo", "Aspect Ratio", …
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.top = 0});

  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 14),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: EditorColors.muted),
    ),
  );
}

/// Muted explanatory text in the panels
class PanelNote extends StatelessWidget {
  const PanelNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: const TextStyle(fontSize: 14, color: EditorColors.muted)),
  );
}
