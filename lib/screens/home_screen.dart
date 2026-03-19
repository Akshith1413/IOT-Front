import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';
import '../services/auth_service.dart';
import '../providers/ecg_provider.dart';
import '../widgets/ecg_chart.dart';
import '../providers/simulator_provider.dart';
import 'ecg_monitor_screen.dart';
import 'chat_screen.dart';
import 'simulator_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<User?>(context);
    final ecg = context.watch<EcgProvider>();
    final simProvider = context.watch<SimulatorProvider>();
    final isConnected = ecg.bleState == BleConnectionState.connected;

    return Scaffold(
      backgroundColor: AppColors.deepSpace,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: AppColors.auroraTeal.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.favorite, color: AppColors.auroraTeal, size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'CardioSync',
              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5, fontSize: 24),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
          if (isConnected) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      ecg.disconnect();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.stellarRose.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.stellarRose.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bluetooth_disabled_rounded,
                              color: AppColors.stellarRose, size: 16),
                          SizedBox(width: 8),
                          Text(
                            'Disconnect',
                            style: TextStyle(
                              color: AppColors.stellarRose,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    await context.read<AuthService>().signOut();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.stellarRose.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.stellarRose.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.logout_rounded,
                            color: AppColors.stellarRose, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Logout',
                          style: TextStyle(
                            color: AppColors.stellarRose,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: SizedBox.expand(
        child: ParticleBackground(
          particleCount: 35,
          baseColor: AppColors.auroraTeal,
          accentColor: AppColors.plasmaViolet,
          connectionDistance: 110,
          opacity: 0.7,
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Welcome header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Welcome back,',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ).animate().fadeIn(),
                        const SizedBox(height: 4),
                        Text(
                          user?.displayName ?? user?.email?.split('@')[0] ?? 'Guest',
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ).animate().fadeIn(delay: 100.ms).slideX(begin: -0.1),
                      ],
                    ),
                    // Connection Status Badge
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: (isConnected ? AppColors.mintGlow : AppColors.cardBorder).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: (isConnected ? AppColors.mintGlow : AppColors.textSecondary).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: isConnected ? AppColors.mintGlow : AppColors.textSecondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isConnected ? 'Live' : 'Offline',
                            style: TextStyle(
                              color: isConnected ? AppColors.mintGlow : AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ).animate().fadeIn(delay: 200.ms),
                  ],
                ),
                
                const SizedBox(height: 32),

                // Live Vitals Overview (Shows if connected)
                if (isConnected) ...[
                  const Text(
                    'Live Vitals',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ).animate().fadeIn(delay: 250.ms),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _buildVitalCard(
                          title: 'Heart Rate',
                          value: ecg.bpm > 0 ? '${ecg.bpm}' : '--',
                          unit: 'BPM',
                          icon: Icons.favorite,
                          color: AppColors.stellarRose,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildVitalCard(
                          title: 'HRV (RMSSD)',
                          value: ecg.rmssd > 0 ? ecg.rmssd.toStringAsFixed(0) : '--',
                          unit: 'ms',
                          icon: Icons.timeline,
                          color: AppColors.auroraTeal,
                        ),
                      ),
                    ],
                  ).animate().fadeIn(delay: 300.ms).slideY(begin: 0.1),
                  const SizedBox(height: 32),
                ] else ...[
                  // Not Connected State
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: AppDecorations.glassCard(
                      glowColor: AppColors.stellarRose.withValues(alpha: 0.2),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () {
                            if (ecg.bleState != BleConnectionState.scanning && ecg.bleState != BleConnectionState.connecting) {
                                ecg.requestPermissionsAndScan();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: AppColors.stellarRose.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.bluetooth_searching_rounded,
                              size: 48,
                              color: AppColors.stellarRose,
                            ).animate(
                              onPlay: (controller) => controller.repeat(),
                            ).shimmer(
                              duration: 2000.ms, 
                              color: AppColors.surfaceWhite.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'No Device Connected',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Tap the Bluetooth icon above to connect your ECG sensor and start monitoring your heart health in real-time.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 32),
                        
                        if (ecg.bleState == BleConnectionState.scanning || ecg.bleState == BleConnectionState.connecting)
                          Column(
                            children: [
                              const CircularProgressIndicator(color: AppColors.stellarRose),
                              const SizedBox(height: 16),
                              Text(
                                ecg.bleStatusMessage,
                                style: const TextStyle(color: AppColors.mintGlow, fontWeight: FontWeight.bold),
                              ),
                            ],
                          )
                        else if (ecg.bleState == BleConnectionState.error || ecg.bleStatusMessage.contains("failed") || ecg.bleStatusMessage.contains("not found"))
                          Text(
                            ecg.bleStatusMessage,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.stellarRose, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                      ],
                    ),
                  ).animate().fadeIn(delay: 250.ms).slideY(begin: 0.1),
                  const SizedBox(height: 32),
                ],

                // Main Action Container
                const Text(
                  'Quick Actions',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ).animate().fadeIn(delay: 400.ms),
                const SizedBox(height: 16),

                // Primary Action: ECG Monitor
                _buildDashboardCard(
                  context,
                  icon: Icons.monitor_heart_rounded,
                  title: 'Live ECG Monitor',
                  subtitle: isConnected 
                      ? 'View your real-time heart waveform' 
                      : 'Connect your device to start tracking',
                  color: AppColors.auroraTeal,
                  gradientColors: [
                    AppColors.auroraTeal.withValues(alpha: 0.2),
                    AppColors.deepSpace.withValues(alpha: 0.5),
                  ],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EcgMonitorScreen(),
                      ),
                    );
                  },
                ).animate().fadeIn(delay: 450.ms).slideX(begin: 0.1),

                const SizedBox(height: 16),

                // Secondary Actions Row
                Row(
                  children: [
                    Expanded(
                      child: _buildDashboardCard(
                        context,
                        icon: Icons.smart_toy_rounded,
                        title: 'AI Chat',
                        subtitle: 'Analyze vitals',
                        color: AppColors.plasmaViolet,
                        gradientColors: [
                          AppColors.plasmaViolet.withValues(alpha: 0.15),
                          AppColors.deepSpace.withValues(alpha: 0.5),
                        ],
                        isSmall: true,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ChatScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildDashboardCard(
                        context,
                        icon: Icons.biotech,
                        title: 'ECG Simulator',
                        subtitle: 'Test AI with synthetic signals',
                        color: AppColors.plasmaViolet,
                        gradientColors: [
                          AppColors.plasmaViolet.withValues(alpha: 0.15),
                          AppColors.nebulaIndigo.withValues(alpha: 0.7),
                        ],
                        isSmall: true,
                        trailingContent: simProvider.simRunning
                            ? Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ).animate(onPlay: (controller) => controller.repeat(reverse: true))
                               .scale(begin: const Offset(0.9, 0.9), end: const Offset(1.2, 1.2), duration: 800.ms)
                            : null,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SimulatorScreen(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ).animate().fadeIn(delay: 550.ms).slideX(begin: 0.1),
                
                const SizedBox(height: 48), // Padding at bottom
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildVitalCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required Color color,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.05),
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
                  Icon(icon, color: color.withValues(alpha: 0.8), size: 16),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    unit,
                    style: TextStyle(
                      color: AppColors.textSecondary.withValues(alpha: 0.7),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
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

  Widget _buildDashboardCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required List<Color> gradientColors,
    required VoidCallback onTap,
    Widget? trailingContent,
    bool isSmall = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: EdgeInsets.all(isSmall ? 20 : 24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradientColors,
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: color.withValues(alpha: 0.3), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.1),
                    blurRadius: 30,
                    spreadRadius: -10,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: isSmall 
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(icon, color: color, size: 24),
                          ),
                          if (trailingContent != null) trailingContent,
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          height: 1.2,
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.3),
                              blurRadius: 12,
                              spreadRadius: -4,
                            ),
                          ],
                        ),
                        child: Icon(icon, color: color, size: 36),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              subtitle,
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceWhite.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.arrow_forward_ios_rounded,
                          color: AppColors.textPrimary.withValues(alpha: 0.9),
                          size: 16,
                        ),
                      ),
                    ],
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
