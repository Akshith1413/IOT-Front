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
      backgroundColor: const Color(0xFF0A0D14),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ─────────────────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("ECG Monitor",
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: -0.5,
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
                  const BleStatusBar(),
                ],
              ),

              const SizedBox(height: 24),

              // ── ECG Chart ───────────────────────────────────────────────
              Expanded(
                flex: 5,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1520),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: ecg.bleState == BleConnectionState.connected
                          ? const Color(0xFF00FF88).withOpacity(0.2)
                          : Colors.white.withOpacity(0.06),
                    ),
                    boxShadow: ecg.bleState == BleConnectionState.connected
                        ? [BoxShadow(
                            color: const Color(0xFF00FF88).withOpacity(0.08),
                            blurRadius: 24,
                            spreadRadius: 2,
                          )]
                        : [],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: ecg.chartBuffer.isEmpty
                      ? _buildPlaceholder(ecg.bleState)
                      : EcgChart(buffer: ecg.chartBuffer),
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
                            ? const Color(0xFFFF4466)
                            : const Color(0xFF00AAFF),
                      ),
                    ),
                  const Spacer(),
                  if (ecg.bleState == BleConnectionState.connected)
                    GestureDetector(
                      onTap: ecg.disconnect,
                      child: const _InfoChip(
                        icon: Icons.bluetooth_disabled,
                        label: "Disconnect",
                        color: Color(0xFFFF4466),
                      ),
                    ),
                ],
              ),
            ],
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
            CircularProgressIndicator(color: Color(0xFF00FF88), strokeWidth: 2),
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
          Icon(Icons.bluetooth_searching,
            size: 48,
            color: Colors.white.withOpacity(0.1)),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
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
