import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
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
    // Auto-start scan on screen open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<EcgProvider>().requestPermissionsAndScan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ecg = context.watch<EcgProvider>();

    return Scaffold(
      backgroundColor: Colors.black, // Fallback
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.5, -0.8),
            radius: 1.5,
            colors: [
              Color(0xFF141933), // Deep Indigo
              Color(0xFF07090F), // True Black edge
            ],
            stops: [0.0, 1.0],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ─────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 12.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("ECG Monitor",
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: -0.5,
                          shadows: [
                            Shadow(
                              color: Color(0xFF00FF9D),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text("128 SPS · Real-time",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.4),
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

              // ── ECG Chart ───────────────────────────────────────────────
              Expanded(
                flex: 5,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: ecg.bleState == BleConnectionState.connected
                              ? const Color(0xFF00FF9D).withValues(alpha: 0.3)
                              : Colors.white.withValues(alpha: 0.1),
                          width: 1.5,
                        ),
                        boxShadow: ecg.bleState == BleConnectionState.connected
                            ? [BoxShadow(
                                color: const Color(0xFF00FF9D).withValues(alpha: 0.15),
                                blurRadius: 40,
                                spreadRadius: -10,
                              )]
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

              // ── Metrics ─────────────────────────────────────────────────
              const MetricsRow()
                  .animate()
                  .fadeIn(delay: 300.ms, duration: 500.ms)
                  .slideY(begin: 0.1, end: 0),

              const SizedBox(height: 16),

              // ── Peak counter + recording + disconnect ────────────────────
              Row(
                children: [
                  _InfoChip(
                    icon: Icons.bolt_rounded,
                    label: "Peaks: ${ecg.peakCount}",
                    color: const Color(0xFFFFAA00),
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
                            ? const Color(0xFFFF2A6D)
                            : const Color(0xFF00D4FF),
                      ),
                    ),
                  const Spacer(),
                  if (ecg.bleState == BleConnectionState.connected)
                    GestureDetector(
                      onTap: ecg.disconnect,
                      child: const _InfoChip(
                        icon: Icons.bluetooth_disabled,
                        label: "Disconnect",
                        color: Color(0xFFFF2A6D),
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

  // ── Record Dialog ─────────────────────────────────────────────────────
  void _showRecordDialog(BuildContext context, EcgProvider ecg) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1F2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Record ECG to SD Card",
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Enter a name for the recording file. It will be saved as a CSV on the SD card.",
              style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLength: 8,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "e.g. test1",
                hintStyle: TextStyle(color: Colors.grey[600]),
                suffixText: ".csv",
                suffixStyle: TextStyle(color: Colors.grey[500]),
                filled: true,
                fillColor: const Color(0xFF0F1520),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                counterStyle: TextStyle(color: Colors.grey[600]),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Cancel", style: TextStyle(color: Colors.grey[500])),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.fiber_manual_record_rounded, size: 14),
            label: const Text("Start Recording"),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF4466),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

  Widget _buildPlaceholder(BleConnectionState state) {
    if (state == BleConnectionState.connected) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF00FF9D), strokeWidth: 3),
            SizedBox(height: 16),
            Text("Waiting for ECG data...",
              style: TextStyle(color: Color(0xFF888888), fontSize: 14)),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.monitor_heart_outlined,
            size: 48,
            color: Colors.white.withValues(alpha: 0.1)),
          const SizedBox(height: 16),
          Text(
            state == BleConnectionState.scanning
                ? "Scanning for ECG_Nano33..."
                : "Connect your ECG sensor",
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
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

  const _InfoChip({required this.icon, required this.label, required this.color});

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
        ]
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
            ),
          ),
        ],
      ),
    );
  }
}
