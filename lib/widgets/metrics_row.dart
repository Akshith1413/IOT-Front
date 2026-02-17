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
          subLabel: ecg.bpmStatus,
          subColor: ecg.bpmStatus == "Normal"
              ? const Color(0xFF00FF88)
              : ecg.bpmStatus == "Tachycardia"
                  ? const Color(0xFFFF4466)
                  : const Color(0xFFFFAA00),
          icon: Icons.favorite_rounded,
          iconColor: const Color(0xFFFF4466),
        ),
        const SizedBox(width: 12),
        _MetricCard(
          label: "SDNN",
          value: ecg.sdnn > 0 ? "${ecg.sdnn.toStringAsFixed(1)} ms" : "—",
          subLabel: "HRV metric",
          subColor: const Color(0xFF888888),
          icon: Icons.show_chart,
          iconColor: const Color(0xFF5599FF),
        ),
        const SizedBox(width: 12),
        _MetricCard(
          label: "RMSSD",
          value: ecg.rmssd > 0 ? "${ecg.rmssd.toStringAsFixed(1)} ms" : "—",
          subLabel: "HRV metric",
          subColor: const Color(0xFF888888),
          icon: Icons.timeline,
          iconColor: const Color(0xFFAA55FF),
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
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: iconColor),
                const SizedBox(width: 6),
                Text(label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF888888),
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Text(subLabel,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: subColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
