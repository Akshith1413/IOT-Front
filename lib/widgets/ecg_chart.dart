import 'dart:collection';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/ecg_sample.dart';

/// High-performance ECG waveform using CustomPainter
/// with Catmull-Rom spline interpolation for hospital-monitor-smooth curves.
class EcgChart extends StatelessWidget {
  final ListQueue<EcgSample> buffer;
  final int windowSize;

  const EcgChart({
    super.key,
    required this.buffer,
    this.windowSize = 512,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _EcgPainter(
          samples: buffer.toList(growable: false),
          windowSize: windowSize,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _EcgPainter extends CustomPainter {
  final List<EcgSample> samples;
  final int windowSize;

  _EcgPainter({required this.samples, required this.windowSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;

    final w = size.width;
    final h = size.height;

    // ── Compute Y bounds ──────────────────────────────────────────────────
    double lo = double.infinity, hi = double.negativeInfinity;
    for (final s in samples) {
      if (s.ecgValue < lo) lo = s.ecgValue;
      if (s.ecgValue > hi) hi = s.ecgValue;
    }
    double range = hi - lo;
    if (range < 0.0001) range = 0.02;
    final pad = range * 0.15;
    final minY = lo - pad;
    final maxY = hi + pad;
    final yRange = maxY - minY;

    // ── Draw subtle grid ──────────────────────────────────────────────────
    _drawGrid(canvas, size, minY, maxY);

    // ── Map data to screen coordinates ────────────────────────────────────
    final points = <Offset>[];
    final peaks  = <Offset>[];
    final n = samples.length;
    for (int i = 0; i < n; i++) {
      final x = (i / (windowSize - 1)) * w;
      final y = h - ((samples[i].ecgValue - minY) / yRange) * h;
      points.add(Offset(x, y));
      if (samples[i].status == 'peak') {
        peaks.add(Offset(x, y));
      }
    }

    // ── Build Catmull-Rom spline path ─────────────────────────────────────
    final path = _catmullRomPath(points);

    // ── Draw gradient fill below the curve ────────────────────────────────
    final fillPath = Path.from(path);
    fillPath.lineTo(points.last.dx, h);
    fillPath.lineTo(points.first.dx, h);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(0, h),
        [
          const Color(0xFF00FF88).withOpacity(0.18),
          const Color(0xFF00FF88).withOpacity(0.0),
        ],
      );
    canvas.drawPath(fillPath, fillPaint);

    // ── Draw the main ECG line ────────────────────────────────────────────
    final linePaint = Paint()
      ..color = const Color(0xFF00FF88)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    canvas.drawPath(path, linePaint);

    // ── Draw subtle glow effect ───────────────────────────────────────────
    final glowPaint = Paint()
      ..color = const Color(0xFF00FF88).withOpacity(0.15)
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..isAntiAlias = true;
    canvas.drawPath(path, glowPaint);

    // ── Draw R-peak markers ───────────────────────────────────────────────
    if (peaks.isNotEmpty) {
      final dotPaint = Paint()..color = const Color(0xFFFF4466);
      final dotBorder = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      for (final p in peaks) {
        canvas.drawCircle(p, 4, dotPaint);
        canvas.drawCircle(p, 4, dotBorder);
      }
    }
  }

  /// Draws a subtle background grid
  void _drawGrid(Canvas canvas, Size size, double minY, double maxY) {
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..strokeWidth = 0.5;

    // Horizontal lines (4 divisions)
    for (int i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Vertical lines (every ~100 points worth of space)
    final step = size.width / 5;
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
  }

  /// Builds a smooth Catmull-Rom spline path through the given points.
  /// This produces hospital-monitor-quality smooth curves.
  Path _catmullRomPath(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts[0].dx, pts[0].dy);

    if (pts.length == 1) return path;
    if (pts.length == 2) {
      path.lineTo(pts[1].dx, pts[1].dy);
      return path;
    }

    // Catmull-Rom to cubic bezier conversion
    // tension factor (0.0 = sharp, 0.5 = standard Catmull-Rom)
    const double t = 0.5;

    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = i > 0 ? pts[i - 1] : pts[i];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = i + 2 < pts.length ? pts[i + 2] : pts[i + 1];

      // Convert Catmull-Rom control points to cubic Bezier control points
      final cp1 = Offset(
        p1.dx + (p2.dx - p0.dx) / (6 * t),
        p1.dy + (p2.dy - p0.dy) / (6 * t),
      );
      final cp2 = Offset(
        p2.dx - (p3.dx - p1.dx) / (6 * t),
        p2.dy - (p3.dy - p1.dy) / (6 * t),
      );

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }

    return path;
  }

  @override
  bool shouldRepaint(covariant _EcgPainter old) => true;
}
