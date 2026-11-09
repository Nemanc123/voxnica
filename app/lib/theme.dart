import 'package:flutter/material.dart';

const kBackground = Color(0xFF313338);
const kSidebar = Color(0xFF2B2D31);
const kRail = Color(0xFF1E1F22);
const kAccent = Color(0xFF5865F2);
const kTextPrimary = Color(0xFFF2F3F5);
const kTextMuted = Color(0xFFB5BAC1);
const kDanger = Color(0xFFED4245);
const kOnline = Color(0xFF23A55A);

ThemeData buildTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: kAccent,
      brightness: Brightness.dark,
    ),
  );

  return base.copyWith(
    scaffoldBackgroundColor: kBackground,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      surface: kSidebar,
      error: kDanger,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: kTextPrimary,
      displayColor: kTextPrimary,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1E1F22),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(color: kTextMuted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    ),
  );
}
