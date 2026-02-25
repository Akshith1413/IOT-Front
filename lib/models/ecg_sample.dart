class EcgSample {
  final DateTime timestamp;
  final double ecgValue;
  final String status; // "normal" | "peak"

  EcgSample({
    required this.timestamp,
    required this.ecgValue,
    required this.status,
  });

  factory EcgSample.fromJson(Map<String, dynamic> json) {
    return EcgSample(
      timestamp: DateTime.parse(json['timestamp'] as String),
      ecgValue:  (json['ecg_value'] as num).toDouble(),
      status:    json['status'] as String? ?? 'normal',
    );
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'ecg_value': ecgValue,
    'status':    status,
  };
}
