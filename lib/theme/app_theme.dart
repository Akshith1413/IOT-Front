import 'package:flutter/material.dart';

/// ──────────────────────────────────────────────────────────────
/// Centralized theme constants — Aurora / Deep Space palette
/// ──────────────────────────────────────────────────────────────
class AppColors {
  AppColors._();

  // ── Core Background ──
  static const Color voidBlack     = Color(0xFF0A0E1A);
  static const Color deepSpace     = Color(0xFF070B14);
  static const Color nebulaIndigo  = Color(0xFF151A35);

  // ── Primary Accents ──
  static const Color auroraTeal    = Color(0xFF00E5C3); // main accent
  static const Color plasmaViolet  = Color(0xFF8B5CF6); // secondary accent
  static const Color iceBlue       = Color(0xFF64D2FF); // info / cool accent

  // ── Semantic ──
  static const Color stellarRose   = Color(0xFFF43F8E); // alerts, heart rate
  static const Color cosmicGold    = Color(0xFFF5A623); // warnings, metrics
  static const Color mintGlow      = Color(0xFF34D399); // success / ECG trace

  // ── Neutrals ──
  static const Color textPrimary   = Color(0xFFE8ECF4);
  static const Color textSecondary = Color(0xFF8893A7);
  static const Color cardBorder    = Color(0xFF252B45);
  static const Color cardBg        = Color(0xFF141831);
  static const Color surfaceWhite  = Color(0x0AFFFFFF); // 4% white
}

class AppDecorations {
  AppDecorations._();

  /// Standard glassmorphism card
  static BoxDecoration glassCard({
    Color borderColor = AppColors.cardBorder,
    double borderRadius = 24,
    Color? glowColor,
  }) {
    return BoxDecoration(
      color: AppColors.surfaceWhite,
      borderRadius: BorderRadius.circular(borderRadius),
      border: Border.all(color: borderColor.withValues(alpha: 0.4), width: 1),
      boxShadow: glowColor != null
          ? [
              BoxShadow(
                color: glowColor.withValues(alpha: 0.12),
                blurRadius: 40,
                spreadRadius: -10,
              ),
            ]
          : [],
    );
  }

  /// Background gradient used under particle system
  static const BoxDecoration spaceGradient = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(-0.3, -0.6),
      radius: 1.8,
      colors: [
        AppColors.nebulaIndigo,
        AppColors.deepSpace,
      ],
      stops: [0.0, 1.0],
    ),
  );
}

class AppTextStyles {
  AppTextStyles._();

  static const TextStyle heading = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );

  static const TextStyle subheading = TextStyle(
    fontSize: 14,
    color: AppColors.textSecondary,
  );

  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.textSecondary,
  );

  static const TextStyle chipText = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
}
