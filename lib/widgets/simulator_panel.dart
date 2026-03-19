import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../theme/app_theme.dart';
import '../providers/ecg_provider.dart';

/// ──────────────────────────────────────────────────────────────────────────────
/// Simulator Control Panel — Live/Sim toggle + Heart condition selector
/// ──────────────────────────────────────────────────────────────────────────────
class SimulatorPanel extends StatefulWidget {
  final EcgProvider ecg;
  const SimulatorPanel({super.key, required this.ecg});

  @override
  State<SimulatorPanel> createState() => _SimulatorPanelState();
}

class _SimulatorPanelState extends State<SimulatorPanel> {
  bool _showSimPanel = false;

  @override
  void didUpdateWidget(covariant SimulatorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync panel visibility with sim state from provider
    // If sim stopped externally (disconnect, firmware stop), close panel
    if (!widget.ecg.isSimulating && _showSimPanel) {
      // Keep panel open so user can pick another condition
      // Only close if explicitly stopped
    }
  }

  void _switchToLive() {
    // Always send SIM_STOP regardless of local state
    if (widget.ecg.isSimulating) {
      widget.ecg.stopSimulation();
    }
    setState(() => _showSimPanel = false);
  }

  void _showSim() {
    setState(() => _showSimPanel = true);
  }

  @override
  Widget build(BuildContext context) {
    final ecg = widget.ecg;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: (_showSimPanel
                      ? AppColors.plasmaViolet
                      : AppColors.mintGlow)
                  .withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Mode Toggle ──
              _buildModeToggle(),
              // ── Content ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SizeTransition(
                      sizeFactor: animation,
                      axisAlignment: -1,
                      child: child,
                    ),
                  );
                },
                child: _showSimPanel
                    ? _SimContent(
                        key: const ValueKey('sim'),
                        ecg: ecg,
                        onStop: _switchToLive,
                      )
                    : _LiveContent(key: const ValueKey('live'), ecg: ecg),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.deepSpace.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ToggleTab(
              icon: Icons.monitor_heart_rounded,
              label: 'LIVE',
              isActive: !_showSimPanel,
              activeColor: AppColors.mintGlow,
              onTap: _switchToLive,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _ToggleTab(
              icon: Icons.science_rounded,
              label: 'SIMULATE',
              isActive: _showSimPanel,
              activeColor: AppColors.plasmaViolet,
              onTap: _showSim,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;

  const _ToggleTab({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: isActive
                ? LinearGradient(
                    colors: [
                      activeColor.withValues(alpha: 0.25),
                      activeColor.withValues(alpha: 0.12),
                    ],
                  )
                : null,
            border: isActive
                ? Border.all(color: activeColor.withValues(alpha: 0.5), width: 1)
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: isActive
                    ? activeColor
                    : AppColors.textSecondary.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isActive
                      ? activeColor
                      : AppColors.textSecondary.withValues(alpha: 0.5),
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Live Mode Content ────────────────────────────────────────────────────────
class _LiveContent extends StatelessWidget {
  final EcgProvider ecg;
  const _LiveContent({super.key, required this.ecg});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.mintGlow.withValues(alpha: 0.2),
                  AppColors.mintGlow.withValues(alpha: 0.05),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.mintGlow.withValues(alpha: 0.2),
              ),
            ),
            child: const Icon(
              Icons.sensors_rounded,
              color: AppColors.mintGlow,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Live ECG — MAX30003",
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  "Hardware sensor at 128 SPS",
                  style: TextStyle(
                    color: AppColors.textSecondary.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          _PulseDot(color: AppColors.mintGlow),
        ],
      ),
    );
  }
}

// ── Simulation Mode Content ──────────────────────────────────────────────────
class _SimContent extends StatelessWidget {
  final EcgProvider ecg;
  final VoidCallback onStop;
  const _SimContent({super.key, required this.ecg, required this.onStop});

  static const List<_ConditionStyle> _styles = [
    _ConditionStyle(            // N — Normal
      icon: Icons.favorite_rounded,
      color: AppColors.mintGlow,
    ),
    _ConditionStyle(            // S — Supraventricular
      icon: Icons.electric_bolt_rounded,
      color: AppColors.cosmicGold,
    ),
    _ConditionStyle(            // V — Ventricular
      icon: Icons.warning_amber_rounded,
      color: AppColors.stellarRose,
    ),
    _ConditionStyle(            // F — Fusion
      icon: Icons.merge_type_rounded,
      color: AppColors.plasmaViolet,
    ),
    _ConditionStyle(            // Q — Unknown
      icon: Icons.help_outline_rounded,
      color: AppColors.iceBlue,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final isRunning = ecg.isSimulating;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.plasmaViolet.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.science_rounded,
                    color: AppColors.plasmaViolet,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isRunning ? "Simulation Active" : "ECG Simulator",
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        isRunning
                            ? "Tap another condition to switch"
                            : "Select a condition to generate",
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isRunning)
                  _StopButton(onTap: onStop),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // ── Condition Cards ──
          ...List.generate(simConditions.length, (i) {
            final condition = simConditions[i];
            final style = _styles[i];
            final isActive = isRunning && ecg.activeSimCondition == condition.id;

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ConditionCard(
                condition: condition,
                style: style,
                isActive: isActive,
                onTap: () => ecg.startSimulation(condition.id),
              ),
            );
          }),

          // ── Active Status Bar ──
          if (isRunning && ecg.activeSimCondition >= 0 && ecg.activeSimCondition < simConditions.length)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _styles[ecg.activeSimCondition].color.withValues(alpha: 0.1),
                    _styles[ecg.activeSimCondition].color.withValues(alpha: 0.03),
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _styles[ecg.activeSimCondition].color.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    color: _styles[ecg.activeSimCondition].color,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Generating ${simConditions[ecg.activeSimCondition].name}",
                    style: TextStyle(
                      color: _styles[ecg.activeSimCondition].color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    "AI active",
                    style: TextStyle(
                      color: _styles[ecg.activeSimCondition].color.withValues(alpha: 0.6),
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            )
                .animate(onPlay: (c) => c.repeat())
                .shimmer(
                  duration: 2500.ms,
                  color: _styles[ecg.activeSimCondition].color.withValues(alpha: 0.08),
                ),
        ],
      ),
    );
  }
}

// ── Condition Style ──────────────────────────────────────────────────────────
class _ConditionStyle {
  final IconData icon;
  final Color color;

  const _ConditionStyle({
    required this.icon,
    required this.color,
  });
}

// ── Condition Card ───────────────────────────────────────────────────────────
class _ConditionCard extends StatelessWidget {
  final SimCondition condition;
  final _ConditionStyle style;
  final bool isActive;
  final VoidCallback onTap;

  const _ConditionCard({
    required this.condition,
    required this.style,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            gradient: isActive
                ? LinearGradient(
                    colors: [
                      style.color.withValues(alpha: 0.2),
                      style.color.withValues(alpha: 0.06),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  )
                : null,
            color: isActive ? null : AppColors.deepSpace.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive
                  ? style.color.withValues(alpha: 0.5)
                  : AppColors.cardBorder.withValues(alpha: 0.3),
              width: isActive ? 1.5 : 1,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: style.color.withValues(alpha: 0.2),
                      blurRadius: 16,
                      spreadRadius: -4,
                    ),
                  ]
                : [],
          ),
          child: Row(
            children: [
              // ── Icon ──
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: style.color.withValues(alpha: isActive ? 0.2 : 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  style.icon,
                  size: 16,
                  color: isActive
                      ? style.color
                      : style.color.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 12),

              // ── Label + Subtitle ──
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      condition.name,
                      style: TextStyle(
                        color: isActive
                            ? style.color
                            : AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      condition.subtitle,
                      style: TextStyle(
                        color: isActive
                            ? style.color.withValues(alpha: 0.6)
                            : AppColors.textSecondary.withValues(alpha: 0.5),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),

              // ── BPM Badge ──
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: (isActive ? style.color : AppColors.textSecondary)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  condition.bpm > 0 ? "${condition.bpm} BPM" : "IRREG",
                  style: TextStyle(
                    color: isActive
                        ? style.color
                        : AppColors.textSecondary.withValues(alpha: 0.5),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),

              const SizedBox(width: 6),

              // ── Active indicator ──
              if (isActive)
                _PulseDot(color: style.color),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Stop Button ──────────────────────────────────────────────────────────────
class _StopButton extends StatelessWidget {
  final VoidCallback onTap;
  const _StopButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.stellarRose.withValues(alpha: 0.2),
                AppColors.stellarRose.withValues(alpha: 0.08),
              ],
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppColors.stellarRose.withValues(alpha: 0.4),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.stop_rounded, color: AppColors.stellarRose, size: 14),
              SizedBox(width: 4),
              Text(
                "STOP",
                style: TextStyle(
                  color: AppColors.stellarRose,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pulse Dot (animated active indicator) ────────────────────────────────────
class _PulseDot extends StatelessWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.6),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scaleXY(begin: 0.8, end: 1.2, duration: 1200.ms, curve: Curves.easeInOut)
        .fadeIn(begin: 0.5, duration: 1200.ms);
  }
}
