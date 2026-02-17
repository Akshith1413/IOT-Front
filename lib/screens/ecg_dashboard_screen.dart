import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/ecg_data.dart';
import '../services/ecg_service.dart';

class EcgDashboardScreen extends StatefulWidget {
  const EcgDashboardScreen({super.key});

  @override
  State<EcgDashboardScreen> createState() => _EcgDashboardScreenState();
}

class _EcgDashboardScreenState extends State<EcgDashboardScreen>
    with TickerProviderStateMixin {
  final EcgService _ecgService = EcgService();
  EcgSession? _session;
  bool _loading = false;
  String? _error;

  // Animation for live playback
  Timer? _playbackTimer;
  Timer? _pollTimer; // For live backend polling
  int _visibleEndIndex = 0;
  int _windowSize = 500; // points visible at once
  bool _isPlaying = false;
  bool _isLive = false;

  // Pulse animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Tab for derived graphs
  int _selectedDerivedTab = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _pollTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }



  Future<void> _fetchData() async {
    // Only block if loading initially, not during background polling
    if (_loading && _session == null) return; 
    
    try {
      final session = await _ecgService.fetchLatestData();
      if (session != null) {
        if (mounted) {
          setState(() {
            _session = session;
            if (_isLive) {
              // Snap to end to show latest data
              _visibleEndIndex = session.dataPoints.length;
            }
             _error = null;
          });
        }
      } else {
        // Handle empty/null data without breaking the loop
        if (mounted && _session == null) {
           setState(() => _error = "Waiting for data stream...");
        }
      }
    } catch (e) {
      print('Fetch error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleLive() {
    setState(() {
      _isLive = !_isLive;
    });

    if (_isLive) {
      _stopPlayback(); 
       setState(() => _loading = true);
      _fetchData(); 
      _pollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _fetchData();
      });
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      setState(() => _loading = false);
    }
  }

  void _loadSampleData() {
    setState(() {
      _loading = true;
      _error = null;
    });

    final csvContent = EcgService.generateSampleCsv();
    final session = _ecgService.parseFromCsvString(csvContent);

    if (session == null) {
      setState(() {
        _error = 'Failed to generate sample data.';
        _loading = false;
      });
      return;
    }

    setState(() {
      _session = session;
      _visibleEndIndex = min(_windowSize, session.dataPoints.length);
      _loading = false;
    });
    _startPlayback();
  }

  void _startPlayback() {
    _playbackTimer?.cancel();
    if (_session == null) return;
    setState(() => _isPlaying = true);
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_visibleEndIndex < _session!.dataPoints.length) {
        setState(() {
          _visibleEndIndex = min(
            _visibleEndIndex + 3,
            _session!.dataPoints.length,
          );
        });
      } else {
        timer.cancel();
        setState(() => _isPlaying = false);
      }
    });
  }

  void _stopPlayback() {
    _playbackTimer?.cancel();
    setState(() => _isPlaying = false);
  }

  void _resetPlayback() {
    _stopPlayback();
    setState(() {
      _visibleEndIndex = min(_windowSize, _session?.dataPoints.length ?? 0);
    });
  }

  // ---------- COLORS & THEME ----------
  static const _bg = Color(0xFF0A0E21);
  static const _cardBg = Color(0xFF1C1F2E);
  static const _cardBorder = Color(0xFF2A2D3E);
  static const _ecgGreen = Color(0xFF00E676);
  static const _heartRed = Color(0xFFFF5252);
  static const _hrvBlue = Color(0xFF448AFF);
  static const _rrOrange = Color(0xFFFFAB40);
  static const _accentPurple = Color(0xFFB388FF);
  static const _textPrimary = Color(0xFFE0E0E0);
  static const _textSecondary = Color(0xFF9E9E9E);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: _buildAppBar(),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _ecgGreen),
            )
          : _session == null
              ? _buildEmptyState()
              : _buildDashboard(),

    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _cardBg,
      foregroundColor: _textPrimary,
      elevation: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _ecgGreen.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.monitor_heart, color: _ecgGreen, size: 22),
          ),
          const SizedBox(width: 10),
          const Text(
            'ECG Monitor',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
      actions: [

        if (_session != null) ...[
          IconButton(
            icon: Icon(
              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: _ecgGreen,
            ),
            onPressed: _isPlaying ? _stopPlayback : _startPlayback,
            tooltip: _isPlaying ? 'Pause' : 'Play',
          ),
          IconButton(
            icon: const Icon(Icons.replay_rounded, color: _textSecondary),
            onPressed: _resetPlayback,
            tooltip: 'Reset',
          ),
        ],
        IconButton(
          onPressed: _toggleLive, 
          icon: Icon(
            _isLive ? Icons.cloud_sync : Icons.cloud_off, 
            color: _isLive ? _ecgGreen : _textSecondary
          ),
          tooltip: _isLive ? 'Disconnect Live' : 'Connect Live',
        ),
        IconButton(
          icon: const Icon(Icons.info_outline_rounded, color: _textSecondary),
          onPressed: _showJsonStructureDialog,
          tooltip: 'JSON Format',
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: _ecgGreen.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.monitor_heart_outlined,
                size: 72,
                color: _ecgGreen,
              ),
            ).animate().scale(duration: 600.ms, curve: Curves.easeOutBack),
            const SizedBox(height: 28),
            const Text(
              'No ECG Data Loaded',
              style: TextStyle(
                color: _textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ).animate().fadeIn(delay: 200.ms),
            const SizedBox(height: 12),
            const Text(
              'Load sample data to visualize ECG waveforms.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _textSecondary, fontSize: 14, height: 1.5),
            ).animate().fadeIn(delay: 350.ms),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _heartRed.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: _heartRed, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [


                _buildActionButton(
                  icon: Icons.cloud_sync_outlined,
                  label: 'Connect Live',
                  color: _ecgGreen,
                  onTap: _toggleLive,
                ),
                const SizedBox(width: 16),
                _buildActionButton(
                  icon: Icons.science_outlined,
                  label: 'Sample Data',
                  color: _accentPurple,
                  onTap: _loadSampleData,
                ),
              ],
            ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.2),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status bar
          _buildStatusBar().animate().fadeIn().slideY(begin: -0.1),
          const SizedBox(height: 16),

          // ECG Waveform
          _buildEcgWaveformCard().animate().fadeIn(delay: 100.ms),
          const SizedBox(height: 16),

          // Metric cards row
          _buildMetricCardsRow().animate().fadeIn(delay: 200.ms),
          const SizedBox(height: 16),

          // Derived graphs section
          _buildDerivedGraphsSection().animate().fadeIn(delay: 300.ms),
          const SizedBox(height: 16),

          // Formulas card
          _buildFormulasCard().animate().fadeIn(delay: 400.ms),
          const SizedBox(height: 16),

          // JSON structure card
          _buildJsonStructureCard().animate().fadeIn(delay: 500.ms),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ---------- STATUS BAR ----------
  Widget _buildStatusBar() {
    final s = _session!;
    final totalPoints = s.dataPoints.length;
    final duration = s.dataPoints.last.timestamp
        .difference(s.dataPoints.first.timestamp);
    final statusCounts = <String, int>{};
    for (final p in s.dataPoints) {
      statusCounts[p.status] = (statusCounts[p.status] ?? 0) + 1;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _cardBorder),
      ),
      child: Row(
        children: [
          _statusChip(
            Icons.timeline,
            '$totalPoints pts',
            _ecgGreen,
          ),
          const SizedBox(width: 12),
          _statusChip(
            Icons.timer_outlined,
            '${duration.inSeconds}s',
            _hrvBlue,
          ),
          const SizedBox(width: 12),
          _statusChip(
            Icons.favorite,
            '${s.rPeakIndices.length} beats',
            _heartRed,
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isPlaying || _isLive
                  ? _ecgGreen.withOpacity(0.15)
                  : _textSecondary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isPlaying ? Icons.fiber_manual_record : Icons.stop,
                  size: 8,
                  color: _isPlaying || _isLive ? _ecgGreen : _textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  _isLive ? 'LIVE DATA' : (_isPlaying ? 'PLAYBACK' : 'STOPPED'),
                  style: TextStyle(
                    color: _isPlaying || _isLive ? _ecgGreen : _textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ---------- ECG WAVEFORM ----------
  Widget _buildEcgWaveformCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
        boxShadow: [
          BoxShadow(
            color: _ecgGreen.withOpacity(0.05),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: _ecgGreen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'ECG Waveform',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '${_visibleEndIndex}/${_session!.dataPoints.length}',
                style: const TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 200,
            child: _buildEcgChart(),
          ),
        ],
      ),
    );
  }

  Widget _buildEcgChart() {
    final s = _session!;
    final startIdx = max(0, _visibleEndIndex - _windowSize);
    final endIdx = _visibleEndIndex;

    final spots = <FlSpot>[];
    for (int i = startIdx; i < endIdx; i++) {
      spots.add(FlSpot(i.toDouble(), s.dataPoints[i].ecgValue));
    }

    if (spots.isEmpty) return const SizedBox();

    final minY = spots.map((s) => s.y).reduce(min) - 0.1;
    final maxY = spots.map((s) => s.y).reduce(max) + 0.1;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: 0.5,
          verticalInterval: 50,
          getDrawingHorizontalLine: (value) => FlLine(
            color: _cardBorder.withOpacity(0.5),
            strokeWidth: 0.5,
          ),
          getDrawingVerticalLine: (value) => FlLine(
            color: _cardBorder.withOpacity(0.3),
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 100,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= s.dataPoints.length) return const SizedBox();
                final idx = value.toInt();
                final secs = s.dataPoints[idx].timestamp
                    .difference(s.dataPoints[0].timestamp)
                    .inMilliseconds /
                    1000;
                return Text(
                  '${secs.toStringAsFixed(1)}s',
                  style: const TextStyle(color: _textSecondary, fontSize: 9),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 0.5,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toStringAsFixed(1),
                  style: const TextStyle(color: _textSecondary, fontSize: 9),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minX: startIdx.toDouble(),
        maxX: endIdx.toDouble(),
        minY: minY,
        maxY: maxY,
        clipData: const FlClipData.all(),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: _ecgGreen,
            barWidth: 1.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _ecgGreen.withOpacity(0.15),
                  _ecgGreen.withOpacity(0.0),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) => _cardBg,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final idx = spot.x.toInt();
                if (idx >= s.dataPoints.length) return null;
                final point = s.dataPoints[idx];
                return LineTooltipItem(
                  '${point.ecgValue.toStringAsFixed(3)} mV\n${point.status}',
                  const TextStyle(color: _ecgGreen, fontSize: 11),
                );
              }).toList();
            },
          ),
        ),
      ),
      duration: const Duration(milliseconds: 0), // instant update for live feel
    );
  }

  // ---------- METRIC CARDS ----------
  Widget _buildMetricCardsRow() {
    final s = _session!;
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            icon: Icons.favorite,
            label: 'Heart Rate',
            value: '${s.averageHR.toStringAsFixed(0)}',
            unit: 'BPM',
            color: _heartRed,
            isPulsing: true,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            icon: Icons.show_chart,
            label: 'SDNN',
            value: '${s.sdnn.toStringAsFixed(1)}',
            unit: 'ms',
            color: _hrvBlue,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            icon: Icons.stacked_line_chart,
            label: 'RMSSD',
            value: '${s.rmssd.toStringAsFixed(1)}',
            unit: 'ms',
            color: _rrOrange,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required String label,
    required String value,
    required String unit,
    required Color color,
    bool isPulsing = false,
  }) {
    Widget iconWidget = Icon(icon, color: color, size: 28);
    if (isPulsing) {
      iconWidget = AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _pulseAnimation.value,
            child: child,
          );
        },
        child: iconWidget,
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          iconWidget,
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              color: _textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  unit,
                  style: TextStyle(
                    color: color.withOpacity(0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------- DERIVED GRAPHS ----------
  Widget _buildDerivedGraphsSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: _accentPurple,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Derived Metrics',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Tab selector
          Row(
            children: [
              _buildTab('Heart Rate', 0, _heartRed),
              const SizedBox(width: 8),
              _buildTab('RR Interval', 1, _rrOrange),
              const SizedBox(width: 8),
              _buildTab('HRV Trend', 2, _hrvBlue),
            ],
          ),
          const SizedBox(height: 16),

          // Graph
          SizedBox(
            height: 180,
            child: _buildDerivedChart(),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, int index, Color color) {
    final selected = _selectedDerivedTab == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedDerivedTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? color.withOpacity(0.4) : _cardBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? color : _textSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildDerivedChart() {
    final s = _session!;
    List<FlSpot> spots;
    Color chartColor;
    String yLabel;

    switch (_selectedDerivedTab) {
      case 0: // Heart Rate
        spots = s.heartRates
            .asMap()
            .entries
            .map((e) => FlSpot(e.key.toDouble(), e.value))
            .toList();
        chartColor = _heartRed;
        yLabel = 'BPM';
        break;
      case 1: // RR Interval
        spots = s.rrIntervals
            .asMap()
            .entries
            .map((e) => FlSpot(e.key.toDouble(), e.value * 1000)) // to ms
            .toList();
        chartColor = _rrOrange;
        yLabel = 'ms';
        break;
      case 2: // HRV rolling window (running SDNN over 5-beat windows)
        spots = _computeRollingHRV(s.rrIntervals);
        chartColor = _hrvBlue;
        yLabel = 'ms';
        break;
      default:
        spots = [];
        chartColor = _ecgGreen;
        yLabel = '';
    }

    if (spots.isEmpty) {
      return Center(
        child: Text(
          'Not enough data to compute',
          style: TextStyle(color: _textSecondary, fontSize: 13),
        ),
      );
    }

    final minY = spots.map((s) => s.y).reduce(min);
    final maxY = spots.map((s) => s.y).reduce(max);
    final range = maxY - minY;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          getDrawingHorizontalLine: (value) => FlLine(
            color: _cardBorder.withOpacity(0.5),
            strokeWidth: 0.5,
          ),
          getDrawingVerticalLine: (value) => FlLine(
            color: _cardBorder.withOpacity(0.3),
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: const TextStyle(color: _textSecondary, fontSize: 9),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text(
              yLabel,
              style: const TextStyle(color: _textSecondary, fontSize: 10),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toStringAsFixed(0),
                  style: const TextStyle(color: _textSecondary, fontSize: 9),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minY: minY - range * 0.1,
        maxY: maxY + range * 0.1,
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: chartColor,
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                return FlDotCirclePainter(
                  radius: 2.5,
                  color: chartColor,
                  strokeWidth: 0,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  chartColor.withOpacity(0.2),
                  chartColor.withOpacity(0.0),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          enabled: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) => _cardBg,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  '${spot.y.toStringAsFixed(1)} $yLabel',
                  TextStyle(color: chartColor, fontSize: 11),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  List<FlSpot> _computeRollingHRV(List<double> rr) {
    if (rr.length < 5) return [];
    final windowSize = 5;
    List<FlSpot> results = [];
    for (int i = windowSize; i <= rr.length; i++) {
      final window = rr.sublist(i - windowSize, i);
      final mean = window.reduce((a, b) => a + b) / window.length;
      final variance =
          window.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) /
              window.length;
      results.add(FlSpot((i - windowSize).toDouble(), sqrt(variance) * 1000));
    }
    return results;
  }

  // ---------- FORMULAS CARD ----------
  Widget _buildFormulasCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: _hrvBlue,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Derived Formulas',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildFormulaItem(
            'Heart Rate (BPM)',
            'HR = 60 / RR_interval',
            'Computed from time between successive R-peaks',
            _heartRed,
          ),
          const Divider(color: _cardBorder, height: 24),
          _buildFormulaItem(
            'SDNN (HRV)',
            'SDNN = √( Σ(RRᵢ - RR̄)² / N )',
            'Standard deviation of all NN (RR) intervals',
            _hrvBlue,
          ),
          const Divider(color: _cardBorder, height: 24),
          _buildFormulaItem(
            'RMSSD (HRV)',
            'RMSSD = √( Σ(RRᵢ₊₁ - RRᵢ)² / (N-1) )',
            'Root mean square of successive RR differences',
            _rrOrange,
          ),
          const Divider(color: _cardBorder, height: 24),
          _buildFormulaItem(
            'RR Interval',
            'RRᵢ = t(Rᵢ₊₁) - t(Rᵢ)',
            'Time difference between consecutive R-peaks',
            _accentPurple,
          ),
        ],
      ),
    );
  }

  Widget _buildFormulaItem(
    String title,
    String formula,
    String description,
    Color color,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.15)),
          ),
          child: Text(
            formula,
            style: TextStyle(
              color: color.withOpacity(0.9),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: const TextStyle(
            color: _textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  // ---------- JSON STRUCTURE ----------
  Widget _buildJsonStructureCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: _ecgGreen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'JSON Input Format',
                style: TextStyle(
                  color: _textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          iconColor: _textSecondary,
          collapsedIconColor: _textSecondary,
          children: [
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0D1117),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _cardBorder),
              ),
              child: SelectableText(
                _jsonSampleText,
                style: TextStyle(
                  color: _ecgGreen.withOpacity(0.9),
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'CSV Format: timestamp,ecg_value,status (one row per sample)',
              style: TextStyle(color: _textSecondary, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  static const _jsonSampleText = '''{
  "session_id": "session_001",
  "device_id": "ecg_sensor_01",
  "data": [
    {
      "timestamp": "2026-02-17T02:00:00.000Z",
      "ecg_value": 0.45,
      "status": "normal"
    },
    {
      "timestamp": "2026-02-17T02:00:00.004Z",
      "ecg_value": 0.52,
      "status": "normal"
    },
    {
      "timestamp": "2026-02-17T02:00:00.008Z",
      "ecg_value": 1.20,
      "status": "peak"
    }
  ]
}''';

  void _showJsonStructureDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Expected JSON Format',
          style: TextStyle(color: _textPrimary, fontSize: 18),
        ),
        content: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              _jsonSampleText,
              style: TextStyle(
                color: _ecgGreen.withOpacity(0.9),
                fontSize: 11,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: _ecgGreen)),
          ),
        ],
      ),
    );
  }

  // ---------- FAB ----------

}
