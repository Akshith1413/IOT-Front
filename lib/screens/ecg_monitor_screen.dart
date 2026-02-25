import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';
import '../providers/ecg_provider.dart';
import '../widgets/ecg_chart.dart';
import '../widgets/ble_status_bar.dart';
import '../widgets/metrics_row.dart';

class EcgMonitorScreen extends StatefulWidget {
  const EcgMonitorScreen({super.key});

  @override
  State<EcgMonitorScreen> createState() => _EcgMonitorScreenState();
}

class _EcgMonitorScreenState extends State<EcgMonitorScreen> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<EcgProvider>().requestPermissionsAndScan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ecg = context.watch<EcgProvider>();

    return Scaffold(
      backgroundColor: AppColors.deepSpace,
      body: ParticleBackground(
        particleCount: 18,
        baseColor: AppColors.mintGlow,
        accentColor: AppColors.iceBlue,
        connectionDistance: 90,
        opacity: 0.35,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.surfaceWhite,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.cardBorder.withValues(alpha: 0.3),
                              ),
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                color: AppColors.textPrimary,
                                size: 18,
                              ),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "ECG Monitor",
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                color: AppColors.textPrimary,
                                letterSpacing: -0.5,
                                shadows: [
                                  Shadow(
                                    color: AppColors.auroraTeal,
                                    blurRadius: 12,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "128 SPS · Real-time",
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary.withValues(alpha: 0.6),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const BleStatusBar(),
                  ],
                ),

                const SizedBox(height: 24),

                // ── ECG Chart ──
                Expanded(
                  flex: 5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceWhite,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: ecg.bleState == BleConnectionState.connected
                                ? AppColors.mintGlow.withValues(alpha: 0.3)
                                : AppColors.cardBorder.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                          boxShadow: ecg.bleState ==
                                  BleConnectionState.connected
                              ? [
                                  BoxShadow(
                                    color: AppColors.mintGlow
                                        .withValues(alpha: 0.15),
                                    blurRadius: 40,
                                    spreadRadius: -10,
                                  )
                                ]
                              : [],
                        ),
                        padding: const EdgeInsets.all(16),
                        child: ecg.chartBuffer.isEmpty
                            ? _buildPlaceholder(ecg.bleState)
                            : EcgChart(buffer: ecg.chartBuffer),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Metrics ──
                const MetricsRow()
                    .animate()
                    .fadeIn(delay: 300.ms, duration: 500.ms)
                    .slideY(begin: 0.1, end: 0),

                const SizedBox(height: 12),

                // ── AI Classification Card ──
                if (ecg.bleState == BleConnectionState.connected)
                  _buildAiCard(ecg)
                      .animate()
                      .fadeIn(delay: 400.ms, duration: 500.ms)
                      .slideY(begin: 0.1, end: 0),

                const SizedBox(height: 12),

                // ── Peak counter + recording + disconnect ──
                Row(
                  children: [
                    _InfoChip(
                      icon: Icons.bolt_rounded,
                      label: "Peaks: ${ecg.peakCount}",
                      color: AppColors.cosmicGold,
                    ),
                    const SizedBox(width: 8),
                    if (ecg.bleState == BleConnectionState.connected)
                      GestureDetector(
                        onTap: () {
                          if (ecg.isRecording) {
                            ecg.stopSdRecording();
                          } else {
                            _showRecordDialog(context, ecg);
                          }
                        },
                        child: _InfoChip(
                          icon: ecg.isRecording
                              ? Icons.stop_circle_rounded
                              : Icons.fiber_manual_record_rounded,
                          label: ecg.isRecording
                              ? "Stop (${ecg.recordingFilename})"
                              : "Record",
                          color: ecg.isRecording
                              ? AppColors.stellarRose
                              : AppColors.iceBlue,
                        ),
                      ),
                    const Spacer(),
                    if (ecg.bleState == BleConnectionState.connected)
                      GestureDetector(
                        onTap: ecg.disconnect,
                        child: const _InfoChip(
                          icon: Icons.bluetooth_disabled,
                          label: "Disconnect",
                          color: AppColors.stellarRose,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Record Dialog ──
  void _showRecordDialog(BuildContext context, EcgProvider ecg) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.nebulaIndigo,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Record ECG to SD Card",
            style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
                "Enter a name for the recording file. It will be saved as a CSV on the SD card.",
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLength: 8,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: "e.g. test1",
                hintStyle: TextStyle(
                    color: AppColors.textSecondary.withValues(alpha: 0.5)),
                suffixText: ".csv",
                suffixStyle: TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.deepSpace,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                counterStyle: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text("Cancel", style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.fiber_manual_record_rounded, size: 14),
            label: const Text("Start Recording"),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.stellarRose,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              ecg.startSdRecording(name);
              Navigator.pop(ctx);
            },
          ),
        ],
      ),
    );
  }

  // ── AI Classification Card ──
  Widget _buildAiCard(EcgProvider ecg) {
    Color classColor;
    IconData classIcon;
    switch (ecg.aiClass) {
      case 'N':
        classColor = AppColors.mintGlow;
        classIcon = Icons.auto_awesome_rounded; // Subtle check/sparkle
        break;
      case 'V':
        classColor = AppColors.stellarRose;
        classIcon = Icons.warning_rounded;
        break;
      case 'S':
        classColor = AppColors.plasmaViolet;
        classIcon = Icons.error_outline_rounded;
        break;
      case 'F':
        classColor = AppColors.cosmicGold;
        classIcon = Icons.merge_type_rounded;
        break;
      default:
        classColor = AppColors.textSecondary;
        classIcon = Icons.psychology_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: ecg.aiAvailable
              ? classColor.withValues(alpha: 0.3)
              : AppColors.cardBorder.withValues(alpha: 0.3),
        ),
        boxShadow: ecg.aiAvailable
            ? [
                BoxShadow(
                  color: classColor.withValues(alpha: 0.1),
                  blurRadius: 16,
                  spreadRadius: -4,
                )
              ]
            : [],
      ),
      child: ecg.aiAvailable
          ? Row(
              children: [
                Icon(classIcon, color: classColor, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ecg.aiLabel,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Confidence: ${(ecg.aiConfidence * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          color: classColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: classColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'AI Edge',
                    style: TextStyle(
                      color: classColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.psychology_outlined,
                    color: AppColors.textSecondary.withValues(alpha: 0.4),
                    size: 20),
                const SizedBox(width: 8),
                Text(
                  'Waiting for AI inference...',
                  style: TextStyle(
                    color: AppColors.textSecondary.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildPlaceholder(BleConnectionState state) {
    if (state == BleConnectionState.connected) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
                color: AppColors.mintGlow, strokeWidth: 3),
            SizedBox(height: 16),
            Text("Waiting for ECG data...",
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.monitor_heart_outlined,
              size: 48, color: AppColors.textSecondary.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            state == BleConnectionState.scanning
                ? "Scanning for ECG_Nano33..."
                : "Connect your ECG sensor",
            style: TextStyle(
              color: AppColors.textSecondary.withValues(alpha: 0.5),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _InfoChip(
      {required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.2),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              )),
        ],
      ),
    );
  }
}
