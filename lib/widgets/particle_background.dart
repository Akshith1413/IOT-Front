import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// ──────────────────────────────────────────────────────────────
/// Animated particle field with proximity connection lines.
/// Renders on a CustomPainter at 60 fps — lightweight enough
/// to sit behind glassmorphism cards on any screen.
/// ──────────────────────────────────────────────────────────────
class ParticleBackground extends StatefulWidget {
  /// Total number of floating particles.
  final int particleCount;

  /// Primary accent colour used for particles & lines.
  final Color baseColor;

  /// Optional secondary accent — some particles will use this.
  final Color accentColor;

  /// Maximum distance at which two particles draw a connecting line.
  final double connectionDistance;

  /// Global opacity multiplier (0..1). Use lower values on data-heavy screens.
  final double opacity;

  /// The child widget rendered on top of the particle field.
  final Widget? child;

  const ParticleBackground({
    super.key,
    this.particleCount = 50,
    this.baseColor = AppColors.auroraTeal,
    this.accentColor = AppColors.plasmaViolet,
    this.connectionDistance = 120,
    this.opacity = 1.0,
    this.child,
  });

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Particle> _particles;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _particles = List.generate(widget.particleCount, (_) => _spawnParticle());
  }

  _Particle _spawnParticle() {
    final useAccent = _rng.nextDouble() < 0.3;
    return _Particle(
      x: _rng.nextDouble(),
      y: _rng.nextDouble(),
      vx: (_rng.nextDouble() - 0.5) * 0.3,
      vy: (_rng.nextDouble() - 0.5) * 0.3,
      radius: _rng.nextDouble() * 2.0 + 0.8,
      color: useAccent ? widget.accentColor : widget.baseColor,
      alpha: _rng.nextDouble() * 0.6 + 0.2,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppDecorations.spaceGradient,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _ParticlePainter(
              particles: _particles,
              connectionDistance: widget.connectionDistance,
              opacity: widget.opacity,
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

// ── Particle data ──────────────────────────────────────────────
class _Particle {
  double x, y;    // normalized 0..1
  double vx, vy;  // velocity per frame (pixels-ish, scaled later)
  double radius;
  Color color;
  double alpha;

  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.radius,
    required this.color,
    required this.alpha,
  });
}

// ── Painter ────────────────────────────────────────────────────
class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double connectionDistance;
  final double opacity;

  _ParticlePainter({
    required this.particles,
    required this.connectionDistance,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final w = size.width;
    final h = size.height;

    // Update positions
    for (final p in particles) {
      p.x += p.vx / w;
      p.y += p.vy / h;

      // Wrap around edges
      if (p.x < 0) p.x += 1;
      if (p.x > 1) p.x -= 1;
      if (p.y < 0) p.y += 1;
      if (p.y > 1) p.y -= 1;
    }

    // Draw connection lines
    final linePaint = Paint()..strokeWidth = 0.6;
    for (int i = 0; i < particles.length; i++) {
      for (int j = i + 1; j < particles.length; j++) {
        final a = particles[i];
        final b = particles[j];
        final dx = (a.x - b.x) * w;
        final dy = (a.y - b.y) * h;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist < connectionDistance) {
          final strength = (1 - dist / connectionDistance);
          linePaint.color = a.color.withValues(
            alpha: strength * 0.15 * opacity,
          );
          canvas.drawLine(
            Offset(a.x * w, a.y * h),
            Offset(b.x * w, b.y * h),
            linePaint,
          );
        }
      }
    }

    // Draw particles with glow
    for (final p in particles) {
      final px = p.x * w;
      final py = p.y * h;
      final glowAlpha = p.alpha * 0.25 * opacity;
      final dotAlpha = p.alpha * opacity;

      // Outer glow
      final glowPaint = Paint()
        ..color = p.color.withValues(alpha: glowAlpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(Offset(px, py), p.radius * 4, glowPaint);

      // Core dot
      final dotPaint = Paint()
        ..color = p.color.withValues(alpha: dotAlpha);
      canvas.drawCircle(Offset(px, py), p.radius, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}
