import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ecg_provider.dart';
import '../theme/app_theme.dart';

class MetricsRow extends StatelessWidget {
  const MetricsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final ecg = context.watch<EcgProvider>();

    // Determine health status for SDNN
    String sdnnStatus = '—';
    Color sdnnStatusColor = AppColors.textSecondary;
    if (ecg.sdnn > 0) {
      if (ecg.sdnn < 50) {
        sdnnStatus = 'Low';
        sdnnStatusColor = AppColors.stellarRose;
      } else if (ecg.sdnn <= 200) {
        sdnnStatus = 'Normal';
        sdnnStatusColor = AppColors.mintGlow;
      } else {
        sdnnStatus = 'High';
        sdnnStatusColor = AppColors.cosmicGold;
      }
    }

    // Determine health status for RMSSD
    String rmssdStatus = '—';
    Color rmssdStatusColor = AppColors.textSecondary;
    if (ecg.rmssd > 0) {
      if (ecg.rmssd < 20) {
        rmssdStatus = 'Low';
        rmssdStatusColor = AppColors.stellarRose;
      } else if (ecg.rmssd <= 100) {
        rmssdStatus = 'Normal';
        rmssdStatusColor = AppColors.mintGlow;
      } else {
        rmssdStatus = 'High';
        rmssdStatusColor = AppColors.cosmicGold;
      }
    }

    return Row(
      children: [
        _MetricCard(
          label: "BPM",
          value: ecg.bpm > 0 ? "${ecg.bpm}" : "\u2014",
          subLabel: "Heart Rate",
          icon: Icons.favorite_rounded,
          iconColor: AppColors.stellarRose,
        ),
        const SizedBox(width: 12),
        _MetricCard(
          label: "SDNN",
          value: ecg.sdnn > 0 ? "${ecg.sdnn.toStringAsFixed(1)}" : "—",
          unit: "ms",
          subLabel: sdnnStatus,
          subColor: sdnnStatusColor,
          icon: Icons.show_chart,
          iconColor: AppColors.iceBlue,
          tooltip: "SDNN: Standard Deviation of NN intervals.\n"
              "Measures overall HRV.\n\n"
              "Normal: 50–200 ms\n"
              "Low (<50): Reduced autonomic function\n"
              "High (>200): Very high variability",
        ),
        const SizedBox(width: 12),
        _MetricCard(
          label: "RMSSD",
          value: ecg.rmssd > 0 ? "${ecg.rmssd.toStringAsFixed(1)}" : "—",
          unit: "ms",
          subLabel: rmssdStatus,
          subColor: rmssdStatusColor,
          icon: Icons.timeline,
          iconColor: AppColors.plasmaViolet,
          tooltip: "RMSSD: Root Mean Square of Successive Differences.\n"
              "Measures parasympathetic (vagal) activity.\n\n"
              "Normal: 20–100 ms\n"
              "Low (<20): Reduced vagal tone\n"
              "High (>100): Strong parasympathetic activity",
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final String subLabel;
  final Color? subColor;
  final IconData icon;
  final Color iconColor;
  final String? tooltip;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.subLabel,
    required this.icon,
    required this.iconColor,
    this.unit,
    this.subColor,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: iconColor.withValues(alpha: 0.3),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: iconColor.withValues(alpha: 0.1),
                  blurRadius: 20,
                  spreadRadius: -5,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(icon, size: 14, color: iconColor),
                    ),
                    const SizedBox(width: 6),
                    Text(label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                        letterSpacing: 1.2,
                      ),
                    ),
                    if (tooltip != null) ...[
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _showInfoDialog(context),
                        child: Icon(
                          Icons.info_outline_rounded,
                          size: 14,
                          color: AppColors.textSecondary.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color: AppColors.textPrimary,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (unit != null) ...[
                      const SizedBox(width: 2),
                      Text(unit!,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(subLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: subColor ?? AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.nebulaIndigo,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ],
        ),
        content: Text(
          tooltip ?? '',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Got it",
                style: TextStyle(color: iconColor, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
