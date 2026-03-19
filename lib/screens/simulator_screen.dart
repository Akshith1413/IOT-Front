import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../providers/ecg_provider.dart';
import '../providers/simulator_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';

Color classColor(String cls) => switch (cls) {
  'N' => Colors.greenAccent,
  'S' => Colors.orange,
  'V' => Colors.redAccent,
  'F' => Colors.purpleAccent,
  'Q' => Colors.grey,
  _   => Colors.white,
};

class SimulatorScreen extends StatefulWidget {
  const SimulatorScreen({super.key});

  @override
  State<SimulatorScreen> createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  StreamSubscription? _ecgSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _aiSub;
  
  BluetoothCharacteristic? commandChar;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBle();
    });
  }

  void _initBle() {
    final ecgProvider = context.read<EcgProvider>();
    final provider = context.read<SimulatorProvider>();

    final ecgChar = ecgProvider.ecgChar;
    commandChar = ecgProvider.commandChar;
    final statusChar = ecgProvider.statusChar;
    final aiChar = ecgProvider.aiChar;

    if (ecgChar != null) {
      try { ecgChar.setNotifyValue(true); } catch (_) {}
      _ecgSub = ecgChar.lastValueStream.listen((raw) {
        if (raw.isEmpty) return;
        try {
          final j = jsonDecode(utf8.decode(raw));
          final val = (j['ecg_value'] as num).toDouble();
          final peak = j['beat'] == 'peak';
          final hr = (j['hr'] as num?)?.toInt() ?? 0;
          final rr = (j['rr'] as num?)?.toInt() ?? 0;
          provider.addEcgSample(val, peak);
          provider.updateVitals(hr, rr);
        } catch (_) {}
      });
    }

    if (aiChar != null) {
      try { aiChar.setNotifyValue(true); } catch (_) {}
      _aiSub = aiChar.lastValueStream.listen((raw) {
        if (raw.isEmpty) return;
        try {
          final j = jsonDecode(utf8.decode(raw));
          final cls = j['class'] as String? ?? '---';
          final lbl = j['label'] as String? ?? '---';
          final conf = (j['confidence'] as num).toDouble();
          final probs = (j['probs'] as List).map((e) => (e as num).toDouble()).toList();
          provider.updateAi(cls, lbl, conf, probs);
        } catch (_) {}
      });
    }

    if (statusChar != null) {
      try { statusChar.setNotifyValue(true); } catch (_) {}
      _statusSub = statusChar.lastValueStream.listen((raw) {
        if (raw.isEmpty) return;
        final s = utf8.decode(raw);
        if (s.startsWith('SIM_ON')) provider.setSimRunning(true);
        if (s == 'SIM_OFF') provider.setSimRunning(false);
        if (s == 'DISCONNECTED') provider.setSimRunning(false);
      });
    }
  }

  @override
  void dispose() {
    _ecgSub?.cancel();
    _aiSub?.cancel();
    _statusSub?.cancel();
    
    final provider = context.read<SimulatorProvider>();
    if (provider.simRunning) {
      _stopSimDirect(provider);
    }
    super.dispose();
  }

  void _startSim(SimulatorProvider provider) async {
    if (commandChar == null) return;
    final cmd = 'SIM_START,${SimulatorProvider.bleCommands[provider.selectedCondition]}';
    provider.setSimRunning(true);
    try {
      await commandChar!.write(utf8.encode(cmd), withoutResponse: false);
    } catch (_) {
      provider.setSimRunning(false);
    }
  }

  void _stopSimDirect(SimulatorProvider provider) async {
    if (commandChar == null) return;
    provider.setSimRunning(false);
    try {
      await commandChar!.write(utf8.encode('SIM_STOP'), withoutResponse: false);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SimulatorProvider>();
    final bleConnected = context.watch<EcgProvider>().bleState == BleConnectionState.connected;

    return Scaffold(
      backgroundColor: AppColors.deepSpace,
      appBar: _buildAppBar(provider),
      body: ParticleBackground(
        particleCount: 20,
        baseColor: AppColors.plasmaViolet,
        accentColor: AppColors.nebulaIndigo,
        connectionDistance: 100,
        opacity: 0.25,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildConditionSelector(provider),
                const SizedBox(height: 16),
                _buildEcgChart(provider),
                const SizedBox(height: 16),
                _buildVitalsRow(provider),
                const SizedBox(height: 16),
                _buildAiCard(provider),
                const SizedBox(height: 32),
                _buildControls(provider, bleConnected),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(SimulatorProvider provider) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: AppColors.textPrimary,
      title: const Text('ECG Simulator', style: TextStyle(fontWeight: FontWeight.bold)),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          Navigator.pop(context);
        },
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.cardBorder.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: provider.simRunning ? AppColors.mintGlow : Colors.grey,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  provider.simRunning ? 'LIVE' : 'IDLE',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: provider.simRunning ? AppColors.mintGlow : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConditionSelector(SimulatorProvider provider) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: List.generate(5, (index) {
          final isSelected = provider.selectedCondition == index;
          final color = _getConditionColor(index);
          return Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ActionChip(
              backgroundColor: isSelected ? color.withValues(alpha: 0.2) : Colors.transparent,
              side: BorderSide(color: isSelected ? color : AppColors.cardBorder),
              label: Text(
                ['Normal', 'SVE', 'VE', 'Fusion', 'Unknown'][index],
                style: TextStyle(
                  color: isSelected ? color : AppColors.textSecondary,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              onPressed: provider.simRunning ? null : () => provider.setCondition(index),
            ),
          );
        }),
      ),
    );
  }

  Color _getConditionColor(int index) {
    switch (index) {
      case 0: return Colors.greenAccent;
      case 1: return Colors.orange;
      case 2: return Colors.redAccent;
      case 3: return Colors.purpleAccent;
      case 4: return Colors.grey;
      default: return Colors.white;
    }
  }

  Widget _buildEcgChart(SimulatorProvider provider) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          height: 200,
          padding: const EdgeInsets.all(16),
          decoration: AppDecorations.glassCard(),
          child: provider.simRunning && provider.ecgPoints.isNotEmpty
            ? LineChart(
                LineChartData(
                  minY: -1.0,
                  maxY: 1.5,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    getDrawingHorizontalLine: (_) => FlLine(color: AppColors.cardBorder.withValues(alpha: 0.5), strokeWidth: 0.5),
                    getDrawingVerticalLine: (_) => FlLine(color: AppColors.cardBorder.withValues(alpha: 0.3), strokeWidth: 0.5),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 32,
                        getTitlesWidget: (value, meta) {
                          if ([-1.0, 0.0, 0.5, 1.0, 1.5].contains(value)) {
                            return Text(value.toStringAsFixed(1), style: const TextStyle(color: AppColors.textSecondary, fontSize: 9));
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: provider.ecgPoints,
                      color: Colors.cyanAccent,
                      barWidth: 1.5,
                      isCurved: false,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                  extraLinesData: ExtraLinesData(
                    verticalLines: provider.peakIndices
                        .where((i) => provider.ecgPoints.any((p) => p.x == i.toDouble()))
                        .map((i) => VerticalLine(
                              x: i.toDouble(),
                              color: Colors.redAccent.withValues(alpha: 0.6),
                              strokeWidth: 1,
                              dashArray: [4, 4],
                            ))
                        .toList(),
                  ),
                ),
                duration: Duration.zero,
              )
            : const Center(
                child: Text(
                  "Start simulation to see waveform",
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
        ),
      ),
    );
  }

  Widget _buildVitalsRow(SimulatorProvider provider) {
    return Row(
      children: [
        Expanded(
          child: _buildVitalCard(
            Icons.favorite,
            "Heart Rate",
            provider.heartRate > 0 ? "${provider.heartRate} bpm" : "--",
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildVitalCard(
            Icons.timeline,
            "RR Interval",
            provider.rrMs > 0 ? "${provider.rrMs} ms" : "--",
          ),
        ),
      ],
    );
  }

  Widget _buildVitalCard(IconData icon, String label, String value) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: AppDecorations.glassCard(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.auroraTeal, size: 24),
              const SizedBox(height: 12),
              Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAiCard(SimulatorProvider provider) {
    final displayClass = provider.overrideEnabled ? provider.expectedClass : provider.aiClass;
    final displayLabel = provider.overrideEnabled ? provider.expectedLabel : provider.aiLabel;
    final displayConf = provider.overrideEnabled ? 1.0 : provider.aiConfidence;
    final highlightCol = classColor(displayClass);

    int maxIdx = 0;
    double maxProb = -1.0;
    for (int i = 0; i < provider.aiProbs.length; i++) {
        if (provider.aiProbs[i] > maxProb) { maxProb = provider.aiProbs[i]; maxIdx = i; }
    }
    if (provider.aiProbs.isEmpty || maxProb == 0) maxIdx = -1;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: AppDecorations.glassCard(),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Model output", style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: highlightCol.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          "$displayLabel  ${(displayConf * 100).toStringAsFixed(0)}%",
                          style: TextStyle(color: highlightCol, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      if (provider.overrideEnabled)
                        const Padding(
                          padding: EdgeInsets.only(top: 4, right: 4),
                          child: Text("(overridden)", style: TextStyle(color: AppColors.textSecondary, fontSize: 10, fontStyle: FontStyle.italic)),
                        )
                    ],
                  ),
                ],
              ),
              if (provider.simRunning) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Expected", style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.bold)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: classColor(provider.expectedClass)),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        provider.expectedLabel,
                        style: TextStyle(color: classColor(provider.expectedClass), fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Override display", style: TextStyle(color: AppColors.textPrimary)),
                  Switch(
                    value: provider.overrideEnabled,
                    onChanged: provider.simRunning ? (_) => provider.toggleOverride() : null,
                    activeColor: AppColors.plasmaViolet,
                  ),
                ],
              ),
              const Divider(color: AppColors.cardBorder, height: 32),
              ...List.generate(5, (i) {
                final shortLabel = SimulatorProvider.expectedClasses[i];
                final prob = provider.aiProbs.length > i ? provider.aiProbs[i] : 0.0;
                final isHighlight = i == maxIdx && !provider.overrideEnabled;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: Text(shortLabel, style: TextStyle(color: classColor(shortLabel), fontWeight: FontWeight.bold))),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Align(
                                alignment: Alignment.centerLeft,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 400),
                                  width: constraints.maxWidth * prob,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: classColor(shortLabel).withValues(alpha: isHighlight ? 1.0 : 0.4),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                            );
                          }
                        ),
                      ),
                      SizedBox(width: 48, child: Text("${(prob * 100).toStringAsFixed(1)}%", textAlign: TextAlign.right, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12))),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(SimulatorProvider provider, bool bleConnected) {
    if (!bleConnected) {
      return const Center(child: Text("Connect your device first", style: TextStyle(color: Colors.orange)));
    }

    if (!provider.simRunning) {
      return Center(
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Colors.green, Colors.teal]),
            borderRadius: BorderRadius.circular(30),
          ),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow, color: Colors.white),
            label: const Text("Start Simulation", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: () => _startSim(provider),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ),
      );
    } else {
      return Center(
        child: ElevatedButton.icon(
          icon: const Icon(Icons.stop, color: Colors.white),
          label: const Text("Stop", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          onPressed: () => _stopSimDirect(provider),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          ),
        ),
      );
    }
  }
}
