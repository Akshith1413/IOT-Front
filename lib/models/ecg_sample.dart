class EcgSample {
  final DateTime timestamp;
  final double ecgValue;
  final String beat;        // "normal" | "peak"
  final int heartRate;      // BPM from software peak detection
  final int rrInterval;     // RR interval in ms
  final double sdnn;        // SDNN from firmware (ms)
  final double rmssd;       // RMSSD from firmware (ms)

  EcgSample({
    required this.timestamp,
    required this.ecgValue,
    required this.beat,
    this.heartRate = 0,
    this.rrInterval = 0,
    this.sdnn = 0.0,
    this.rmssd = 0.0,
  });

  factory EcgSample.fromJson(Map<String, dynamic> json) {
    return EcgSample(
      timestamp:  DateTime.parse(json['timestamp'] as String),
      ecgValue:   (json['ecg_value'] as num).toDouble(),
      beat:       (json['beat'] as String?) ?? (json['status'] as String?) ?? 'normal',
      heartRate:  (json['hr'] as int?) ?? 0,
      rrInterval: (json['rr'] as int?) ?? 0,
      sdnn:       (json['sdnn'] as num?)?.toDouble() ?? 0.0,
      rmssd:      (json['rmssd'] as num?)?.toDouble() ?? 0.0,
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
  };
}
