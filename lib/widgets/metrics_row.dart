import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ecg_provider.dart';

class MetricsRow extends StatelessWidget {
  const MetricsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final ecg = context.watch<EcgProvider>();

    return Row(
      children: [
        _MetricCard(
          label: "BPM",
          value: ecg.bpm > 0 ? "${ecg.bpm}" : "—",
          subLabel: "Heart Rate",
          subColor: const Color(0xFF888888),
          icon: Icons.favorite_rounded,
          iconColor: const Color(0xFFFF2A6D), // Neon Pink
        ),
        const SizedBox(width: 12),
        _MetricCard(
          label: "SDNN",
          value: ecg.sdnn > 0 ? "${ecg.sdnn.toStringAsFixed(1)} ms" : "—",
          subLabel: "HRV metric",
          subColor: const Color(0xFF888888),
          icon: Icons.show_chart,
          iconColor: const Color(0xFF00D4FF), // Electric Blue
        ),
        const SizedBox(width: 12),
        _MetricCard(
          label: "RMSSD",
          value: ecg.rmssd > 0 ? "${ecg.rmssd.toStringAsFixed(1)} ms" : "—",
          subLabel: "HRV metric",
          subColor: const Color(0xFF888888),
          icon: Icons.timeline,
          iconColor: const Color(0xFFB388FF), // Cyber Purple
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String subLabel;
  final Color  subColor;
  final IconData icon;
  final Color  iconColor;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.subLabel,
    required this.subColor,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
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
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, size: 16, color: iconColor),
                    ),
                    const SizedBox(width: 8),
                    Text(label,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFB0B0B0),
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(value,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(subLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: subColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
