import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';
import '../services/auth_service.dart';
import 'ecg_monitor_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<User?>(context);

    return Scaffold(
      backgroundColor: AppColors.deepSpace,
      appBar: AppBar(
        title: const Text(
          'IoT Dashboard',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        actions: [
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
      body: ParticleBackground(
        particleCount: 35,
        baseColor: AppColors.auroraTeal,
        accentColor: AppColors.iceBlue,
        connectionDistance: 110,
        opacity: 0.7,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Welcome header
                Text(
                  'Welcome back,',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ).animate().fadeIn(),
                const SizedBox(height: 4),
                Text(
                  user?.displayName ?? user?.email ?? 'Guest',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ).animate().fadeIn(delay: 100.ms).slideX(begin: -0.1),
                const SizedBox(height: 28),

                // ECG Monitor card
                _buildDashboardCard(
                  context,
                  icon: Icons.monitor_heart_rounded,
                  title: 'ECG Monitor',
                  subtitle: 'Real-time ECG visualization & analysis',
                  color: AppColors.auroraTeal,
                  gradientColors: [
                    AppColors.auroraTeal.withValues(alpha: 0.15),
                    AppColors.plasmaViolet.withValues(alpha: 0.05),
                  ],
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EcgMonitorScreen(),
                      ),
                    );
                  },
                ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.1),
              ],
            ),
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
              padding: const EdgeInsets.all(24),
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
                    color: color.withValues(alpha: 0.15),
                    blurRadius: 30,
                    spreadRadius: -10,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
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
                            fontSize: 14,
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
                      color: AppColors.surfaceWhite,
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
