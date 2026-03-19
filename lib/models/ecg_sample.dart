class EcgSample {
  final DateTime timestamp;
  final double ecgValue;
  final String beat;        // "normal" | "peak"
  final int heartRate;      // BPM from software peak detection
  final int rrInterval;     // RR interval in ms
  final double sdnn;        // SDNN from firmware (ms)
  final double rmssd;       // RMSSD from firmware (ms)
  final bool isSimulated;   // true when data is from sim mode

  EcgSample({
    required this.timestamp,
    required this.ecgValue,
    required this.beat,
    this.heartRate = 0,
    this.rrInterval = 0,
    this.sdnn = 0.0,
    this.rmssd = 0.0,
    this.isSimulated = false,
  });

  /// Parse JSON from firmware BLE characteristic.
  /// Firmware may send either long keys (timestamp/ecg_value/sim)
  /// or short keys (ts/v/m) depending on firmware version. Support both.
  /// Examples:
  ///  Long: {"timestamp":"...","ecg_value":0.12,"beat":"normal",...,"sim":0}
  ///  Short: {"ts":"...","v":0.12,"b":"normal","m":"S",...}
  factory EcgSample.fromJson(Map<String, dynamic> json) {
    final ts = (json['timestamp'] as String?) ?? (json['ts'] as String?);
    final v  = (json['ecg_value'] as num?) ?? (json['v'] as num?);
    final b  = (json['beat'] as String?) ?? (json['b'] as String?) ?? (json['status'] as String?);
    final simFlag = json['sim'];
    final mode = (json['m'] as String?) ?? (json['mode'] as String?);

    bool sim = false;
    if (simFlag != null) {
      try {
        sim = (simFlag as int) == 1;
      } catch (_) {
        sim = simFlag.toString() == '1';
      }
    }
    if (!sim && mode != null) {
      // mode short codes: 'L' = live, 'S' = simulation, 'R' = replay
      sim = mode.toUpperCase() == 'S' || mode.toLowerCase() == 'sim';
    }

    return EcgSample(
      timestamp:    ts != null ? DateTime.parse(ts) : DateTime.now(),
      ecgValue:     v != null ? (v as num).toDouble() : 0.0,
      beat:         b ?? 'normal',
      heartRate:    (json['hr'] as int?) ?? 0,
      rrInterval:   (json['rr'] as int?) ?? 0,
      sdnn:         (json['sdnn'] as num?)?.toDouble() ?? 0.0,
      rmssd:        (json['rmssd'] as num?)?.toDouble() ?? 0.0,
      isSimulated:  sim,
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'ecg_value': ecgValue,
    'beat':      beat,
    'hr':        heartRate,
    'rr':        rrInterval,
    'sdnn':      sdnn,
    'rmssd':     rmssd,
    'sim':       isSimulated ? 1 : 0,
  };
}
