import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../providers/ecg_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/particle_background.dart';



class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_ChatMessage> _messages = [];
  bool _isLoading = false;


  @override
  void initState() {
    super.initState();
    // Welcome message
    _messages.add(_ChatMessage(
      text: "Hi! I'm your Heart Health Assistant 💓\n\n"
          "I can answer questions about your ECG data, heart rate, "
          "HRV metrics, and general heart health.\n\n"
          "Try asking me:\n"
          "• How is my heart?\n"
          "• What is my BPM?\n"
          "• Is my RMSSD normal?\n"
          "• Explain SDNN",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;

    setState(() {
      _messages.add(_ChatMessage(
        text: text.trim(),
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
    });
    _textController.clear();
    _scrollToBottom();

    final ecg = context.read<EcgProvider>();
    String response;

    response = _getLocalResponse(text.trim(), ecg);

    setState(() {
      _messages.add(_ChatMessage(
        text: response,
        isUser: false,
        timestamp: DateTime.now(),
      ));
      _isLoading = false;
    });
    _scrollToBottom();
  }

  // ── Local Rule-Based Engine ──────────────────────────────────────────────
  String _getLocalResponse(String query, EcgProvider ecg) {
    final q = query.toLowerCase();
    final isConnected = ecg.bleState == BleConnectionState.connected;

    // BPM queries
    if (q.contains('bpm') || q.contains('heart rate') || q.contains('pulse')) {
      if (!isConnected) {
        return "Your ECG sensor isn't connected right now. Connect your device to see your heart rate.";
      }
      if (ecg.bpm == 0) {
        return "I'm still waiting for heart rate data. Give it a moment — the sensor needs a few beats to calculate BPM.";
      }
      String status;
      if (ecg.bpm < 60) {
        status = "Your heart rate is ${ecg.bpm} BPM, which is classified as **bradycardia** (below 60 BPM). "
            "This can be normal for athletes, but if you experience dizziness or fatigue, consult a doctor.";
      } else if (ecg.bpm > 100) {
        status = "Your heart rate is ${ecg.bpm} BPM, which is classified as **tachycardia** (above 100 BPM). "
            "This could be due to exercise, stress, or caffeine. If persistent at rest, consult a doctor.";
      } else {
        status = "Your heart rate is ${ecg.bpm} BPM — that's within the **normal range** (60–100 BPM). Looking good! 💚";
      }
      return status;
    }

    // SDNN queries
    if (q.contains('sdnn')) {
      if (!isConnected) {
        return "Connect your ECG sensor first to get SDNN measurements.";
      }
      if (ecg.sdnn <= 0) {
        return "SDNN data isn't available yet. The system needs several heartbeats to compute HRV metrics.";
      }
      String info = "Your SDNN is **${ecg.sdnn.toStringAsFixed(1)} ms**.\n\n"
          "**SDNN** (Standard Deviation of NN intervals) measures overall heart rate variability.\n\n";
      if (ecg.sdnn < 50) {
        info += "⚠️ This is **below normal** (<50 ms). Low SDNN may indicate reduced autonomic nervous system function. "
            "Stress, poor sleep, or certain conditions can cause this.";
      } else if (ecg.sdnn <= 200) {
        info += "✅ This is **within the normal range** (50–200 ms). Your autonomic nervous system appears to be functioning well!";
      } else {
        info += "📊 This is **above typical range** (>200 ms). Very high SDNN can indicate excellent fitness, "
            "but in some cases may warrant further evaluation.";
      }
      return info;
    }

    // RMSSD queries
    if (q.contains('rmssd')) {
      if (!isConnected) {
        return "Connect your ECG sensor first to get RMSSD measurements.";
      }
      if (ecg.rmssd <= 0) {
        return "RMSSD data isn't available yet. The system needs several heartbeats to compute this metric.";
      }
      String info = "Your RMSSD is **${ecg.rmssd.toStringAsFixed(1)} ms**.\n\n"
          "**RMSSD** (Root Mean Square of Successive Differences) measures parasympathetic (vagal) activity.\n\n";
      if (ecg.rmssd < 20) {
        info += "⚠️ This is **below normal** (<20 ms). Low RMSSD suggests reduced vagal tone. "
            "This can be caused by stress, fatigue, or dehydration.";
      } else if (ecg.rmssd <= 100) {
        info += "✅ This is **within the normal range** (20–100 ms). Your parasympathetic nervous system is functioning well!";
      } else {
        info += "📊 This is **above typical range** (>100 ms). High RMSSD generally indicates strong vagal tone, "
            "common in athletes and well-rested individuals.";
      }
      return info;
    }

    // HRV general
    if (q.contains('hrv') || q.contains('variability')) {
      return "**Heart Rate Variability (HRV)** measures the variation in time between heartbeats.\n\n"
          "Higher HRV generally indicates better cardiovascular fitness and stress resilience.\n\n"
          "Your current metrics:\n"
          "• **SDNN**: ${ecg.sdnn > 0 ? '${ecg.sdnn.toStringAsFixed(1)} ms' : 'Not available'}\n"
          "• **RMSSD**: ${ecg.rmssd > 0 ? '${ecg.rmssd.toStringAsFixed(1)} ms' : 'Not available'}\n\n"
          "Ask me about SDNN or RMSSD specifically for detailed explanations!";
    }

    // AI classification
    if (q.contains('ai') || q.contains('classification') || q.contains('arrhythmia') || q.contains('predict')) {
      if (!ecg.aiAvailable) {
        return "AI classification data isn't available yet. The edge AI model needs ECG data to make predictions.";
      }
      return "🤖 **AI Classification Result**\n\n"
          "• **Class**: ${ecg.aiLabel} (${ecg.aiClass})\n"
          "• **Confidence**: ${(ecg.aiConfidence * 100).toStringAsFixed(1)}%\n\n"
          "The AI model classifies heartbeats into 5 categories:\n"
          "• **N** — Normal\n"
          "• **S** — Supraventricular\n"
          "• **V** — Ventricular (PVC)\n"
          "• **F** — Fusion\n"
          "• **Q** — Unknown\n\n"
          "${ecg.aiClass == 'N' ? '✅ Your heartbeat appears normal!' : '⚠️ An abnormality was detected. Consult a healthcare professional for proper diagnosis.'}";
    }

    // How is my heart / summary
    if (q.contains('how') && (q.contains('heart') || q.contains('health')) ||
        q.contains('summary') || q.contains('status') || q.contains('overall')) {
      if (!isConnected) {
        return "I can't assess your heart health without data. Please connect your ECG sensor!";
      }

      final buf = StringBuffer("💓 **Heart Health Summary**\n\n");

      if (ecg.bpm > 0) {
        String bpmStatus = ecg.bpm < 60
            ? "Bradycardia ⚠️"
            : ecg.bpm > 100
                ? "Tachycardia ⚠️"
                : "Normal ✅";
        buf.writeln("• **Heart Rate**: ${ecg.bpm} BPM ($bpmStatus)");
      } else {
        buf.writeln("• **Heart Rate**: Awaiting data...");
      }

      if (ecg.sdnn > 0) {
        String sdnnStatus = ecg.sdnn < 50
            ? "Low ⚠️"
            : ecg.sdnn <= 200
                ? "Normal ✅"
                : "High 📊";
        buf.writeln("• **SDNN**: ${ecg.sdnn.toStringAsFixed(1)} ms ($sdnnStatus)");
      }

      if (ecg.rmssd > 0) {
        String rmssdStatus = ecg.rmssd < 20
            ? "Low ⚠️"
            : ecg.rmssd <= 100
                ? "Normal ✅"
                : "High 📊";
        buf.writeln("• **RMSSD**: ${ecg.rmssd.toStringAsFixed(1)} ms ($rmssdStatus)");
      }

      if (ecg.aiAvailable) {
        buf.writeln("• **AI Classification**: ${ecg.aiLabel} (${(ecg.aiConfidence * 100).toStringAsFixed(0)}% confidence)");
      }

      buf.writeln("\n*Note: This is for informational purposes only and not a medical diagnosis.*");
      return buf.toString();
    }

    // Peaks
    if (q.contains('peak') || q.contains('beats')) {
      return "So far, I've detected **${ecg.peakCount} R-peaks** (heartbeats) in this session. "
          "R-peaks are the tallest spikes in the ECG waveform, representing ventricular contraction.";
    }

    // ECG explanation
    if (q.contains('ecg') || q.contains('electrocardiogram')) {
      return "An **ECG (Electrocardiogram)** records the electrical activity of your heart.\n\n"
          "The waveform has several key components:\n"
          "• **P wave** — Atrial depolarization\n"
          "• **QRS complex** — Ventricular depolarization (the tall spike)\n"
          "• **T wave** — Ventricular repolarization\n\n"
          "Your device samples at 128 SPS (samples per second) and uses an AD8232 analog front-end.";
    }

    // Recording
    if (q.contains('record') || q.contains('save') || q.contains('csv')) {
      if (ecg.isRecording) {
        return "Your device is currently **recording data to the SD card** as `${ecg.recordingFilename}.csv`.\n\n"
               "To stop recording, exit the chat and tap the red Stop button on the main monitor screen.";
      } else {
        return "You can record your live ECG data directly to the device's SD card!\n\n"
               "Just exit this chat, tap the **Record** button on the main screen, and enter a filename. "
               "The data will be saved as a CSV file for later analysis.";
      }
    }

    // Stress / Relaxation
    if (q.contains('stress') || q.contains('relax') || q.contains('tired') || q.contains('fatigue')) {
      if (!isConnected) {
         return "I need to see your active heart data to estimate your stress levels. Please connect your sensor.";
      }
      if (ecg.rmssd <= 0 || ecg.bpm <= 0) {
         return "I need a few more seconds of stable heart data to estimate your stress levels.";
      }
      
      // Basic heuristic: High HR + Low RMSSD = Stressed
      if (ecg.bpm > 85 && ecg.rmssd < 25) {
        return "Based on your high heart rate (${ecg.bpm} BPM) and low HRV (RMSSD: ${ecg.rmssd.toStringAsFixed(1)} ms), "
               "your body shows signs of **elevated stress or fatigue**.\n\n"
               "Consider taking a few deep breaths, drinking water, or resting.";
      } else if (ecg.bpm < 75 && ecg.rmssd > 40) {
        return "Your heart rate (${ecg.bpm} BPM) and HRV (RMSSD: ${ecg.rmssd.toStringAsFixed(1)} ms) indicate that you are "
               "in a **relaxed and well-rested state**. Keep it up! 🧘‍♂️";
      } else {
        return "Your body is in a **balanced and neutral state** right now. \n\n"
               "Heart Rate: ${ecg.bpm} BPM\n"
               "HRV: ${ecg.rmssd.toStringAsFixed(1)} ms";
      }
    }

    // Greetings
    if (q == 'hi' || q == 'hello' || q == 'hey' || q == 'greetings') {
      return "Hello there! 👋 I'm analyzing your heart data in real-time. "
             "Feel free to ask me for a summary, or ask about specific metrics like your BPM or HRV.";
    }

    // Help
    if (q.contains('help') || q.contains('what can you do') || q.contains('options')) {
      return "Here are some things you can ask me:\n\n"
             "• **\"How is my heart?\"** (get a full status summary)\n"
             "• **\"What is my BPM?\"** (check heart rate)\n"
             "• **\"Explain HRV\"** (learn about SDNN/RMSSD)\n"
             "• **\"Am I stressed?\"** (check stress levels)\n"
             "• **\"What are the AI results?\"** (see arrhythmia checks)\n"
             "• **\"How do I record data?\"** (saving to SD card)\n"
             "• **\"What is an ECG?\"** (learn about the hardware)";
    }

    // Default fallback
    return "I'm not exactly sure what you mean. Try asking me:\n\n"
        "• \"How is my overall heart health?\"\n"
        "• \"What is my heart rate?\"\n"
        "• \"Am I stressed today?\"\n"
        "• \"Tell me about my HRV.\"\n"
        "• \"What is an ECG?\"";
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.deepSpace,
      body: ParticleBackground(
        particleCount: 12,
        baseColor: AppColors.iceBlue,
        accentColor: AppColors.plasmaViolet,
        connectionDistance: 80,
        opacity: 0.25,
        child: SafeArea(
          child: Column(
            children: [
              // ── Header ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.surfaceWhite,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.cardBorder.withValues(alpha: 0.3),
                        ),
                      ),
                      child: IconButton(
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: AppColors.textPrimary,
                          size: 18,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Heart Assistant",
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: AppColors.textPrimary,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Messages ──
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: _messages.length + (_isLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _messages.length && _isLoading) {
                      return _buildTypingIndicator();
                    }
                    return _buildMessageBubble(_messages[index], index);
                  },
                ),
              ),

              // ── Quick action chips ──
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _quickChip("How is my heart?", Icons.favorite),
                    _quickChip("What is my BPM?", Icons.speed),
                    _quickChip("Explain SDNN", Icons.show_chart),
                    _quickChip("Explain RMSSD", Icons.timeline),
                    _quickChip("Am I stressed?", Icons.self_improvement),
                    _quickChip("Record Data", Icons.sd_storage_rounded),
                    _quickChip("What can you do?", Icons.help_outline_rounded),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // ── Input bar ──
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceWhite,
                  border: Border(
                    top: BorderSide(
                      color: AppColors.cardBorder.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: "Ask about your heart...",
                          hintStyle: TextStyle(
                            color: AppColors.textSecondary.withValues(alpha: 0.5),
                          ),
                          filled: true,
                          fillColor: AppColors.deepSpace,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                        onSubmitted: _sendMessage,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.auroraTeal, AppColors.iceBlue],
                        ),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.auroraTeal.withValues(alpha: 0.3),
                            blurRadius: 8,
                            spreadRadius: -2,
                          ),
                        ],
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.send_rounded,
                            color: AppColors.deepSpace, size: 20),
                        onPressed: () => _sendMessage(_textController.text),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickChip(String label, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _sendMessage(label),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.iceBlue.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppColors.iceBlue),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg, int index) {
    final isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.auroraTeal.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.favorite_rounded,
                  color: AppColors.auroraTeal, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser
                    ? AppColors.auroraTeal.withValues(alpha: 0.15)
                    : AppColors.surfaceWhite,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isUser ? 18 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 18),
                ),
                border: Border.all(
                  color: isUser
                      ? AppColors.auroraTeal.withValues(alpha: 0.3)
                      : AppColors.cardBorder.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MarkdownText(text: msg.text),
                  const SizedBox(height: 4),
                  Text(
                    "${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}",
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.textSecondary.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
          ).animate().fadeIn(duration: 300.ms).slideX(
                begin: isUser ? 0.1 : -0.1,
                end: 0,
              ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.auroraTeal.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.favorite_rounded,
                color: AppColors.auroraTeal, size: 16),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomRight: Radius.circular(18),
                bottomLeft: Radius.circular(4),
              ),
              border: Border.all(
                color: AppColors.cardBorder.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DotAnimation(delay: 0),
                const SizedBox(width: 4),
                _DotAnimation(delay: 200),
                const SizedBox(width: 4),
                _DotAnimation(delay: 400),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Simple Markdown-like text rendering ─────────────────────────────────────
class _MarkdownText extends StatelessWidget {
  final String text;
  const _MarkdownText({required this.text});

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    final lines = text.split('\n');

    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));

      String line = lines[i];

      // Bold **text**
      final parts = line.split('**');
      for (int j = 0; j < parts.length; j++) {
        if (j % 2 == 1) {
          spans.add(TextSpan(
            text: parts[j],
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ));
        } else {
          spans.add(TextSpan(
            text: parts[j],
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              height: 1.5,
            ),
          ));
        }
      }
    }

    return RichText(
      text: TextSpan(children: spans),
    );
  }
}

// ── Chat message model ──────────────────────────────────────────────────────
class _ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  _ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}

// ── Typing dot animation ────────────────────────────────────────────────────
class _DotAnimation extends StatefulWidget {
  final int delay;
  const _DotAnimation({required this.delay});

  @override
  State<_DotAnimation> createState() => _DotAnimationState();
}

class _DotAnimationState extends State<_DotAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, -4 * _animation.value),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: AppColors.auroraTeal.withValues(alpha: 0.5 + _animation.value * 0.5),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}