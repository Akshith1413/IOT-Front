import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../providers/ecg_provider.dart';

class BleStatusBar extends StatelessWidget {
  const BleStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final ecg = context.watch<EcgProvider>();
    final isConnected = ecg.bleState == BleConnectionState.connected;
    final isScanning  = ecg.bleState == BleConnectionState.scanning ||
                        ecg.bleState == BleConnectionState.connecting;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isConnected ? null : ecg.requestPermissionsAndScan,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _bgColor(ecg.bleState).withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _bgColor(ecg.bleState).withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated dot
              if (isConnected)
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00FF88),
                    shape: BoxShape.circle,
                  ),
                ).animate(onPlay: (c) => c.repeat())
                 .fade(begin: 1, end: 0.2, duration: 900.ms)
              else if (isScanning)
                SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _bgColor(ecg.bleState),
                  ),
                )
              else
                Icon(Icons.bluetooth_disabled, size: 14, color: _bgColor(ecg.bleState)),

              const SizedBox(width: 8),
              Text(
                ecg.bleStatusMessage,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _bgColor(ecg.bleState),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _bgColor(BleConnectionState state) {
    switch (state) {
      case BleConnectionState.connected:   return const Color(0xFF00FF88);
      case BleConnectionState.scanning:
      case BleConnectionState.connecting:  return const Color(0xFFFFAA00);
      case BleConnectionState.error:       return const Color(0xFFFF4466);
      case BleConnectionState.disconnected:return const Color(0xFF888888);
    }
  }
}
