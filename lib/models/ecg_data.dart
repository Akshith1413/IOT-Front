import 'dart:math';

class EcgDataPoint {
  final DateTime timestamp;
  final double ecgValue;
  final String status;

  EcgDataPoint({
    required this.timestamp,
    required this.ecgValue,
    required this.status,
  });

  factory EcgDataPoint.fromCsvRow(List<dynamic> row) {
    return EcgDataPoint(
      timestamp: DateTime.parse(row[0].toString().trim()),
      ecgValue: double.parse(row[1].toString().trim()),
      status: row[2].toString().trim(),
    );
  }

  factory EcgDataPoint.fromJson(Map<String, dynamic> json) {
    return EcgDataPoint(
      timestamp: DateTime.parse(json['timestamp']),
      ecgValue: (json['ecg_value'] as num).toDouble(),
      status: json['status'] ?? 'unknown',
    );
  }

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'ecg_value': ecgValue,
        'status': status,
      };
}

class EcgSession {
  final List<EcgDataPoint> dataPoints;
  late final List<int> rPeakIndices;
  late final List<double> rrIntervals; // in seconds
  late final List<double> heartRates; // BPM at each RR interval
  late final double averageHR;
  late final double sdnn; // HRV metric
  late final double rmssd; // HRV metric

  EcgSession({required this.dataPoints}) {
    rPeakIndices = _detectRPeaks();
    rrIntervals = _computeRRIntervals();
    heartRates = _computeHeartRates();
    averageHR = heartRates.isEmpty ? 0 : heartRates.reduce((a, b) => a + b) / heartRates.length;
    sdnn = _computeSDNN();
    rmssd = _computeRMSSD();
  }

  /// Simple R-peak detection using threshold-based approach
  /// Finds local maxima above a dynamic threshold
  List<int> _detectRPeaks() {
    if (dataPoints.length < 5) return [];

    final values = dataPoints.map((p) => p.ecgValue).toList();
    final mean = values.reduce((a, b) => a + b) / values.length;
    final stdDev = sqrt(values.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / values.length);
    final threshold = mean + 0.6 * stdDev;

    // Minimum distance between peaks (assuming ~250Hz sampling, ~150ms refractory)
    final minDistance = max(5, (dataPoints.length / (dataPoints.length > 1
        ? dataPoints.last.timestamp.difference(dataPoints.first.timestamp).inSeconds
        : 1) * 0.2).round());

    List<int> peaks = [];
    for (int i = 2; i < values.length - 2; i++) {
      if (values[i] > threshold &&
          values[i] > values[i - 1] &&
          values[i] > values[i + 1] &&
          values[i] > values[i - 2] &&
          values[i] > values[i + 2]) {
        if (peaks.isEmpty || (i - peaks.last) >= minDistance) {
          peaks.add(i);
        } else if (values[i] > values[peaks.last]) {
          peaks[peaks.length - 1] = i;
        }
      }
    }
    return peaks;
  }

  /// RR Intervals in seconds
  /// Formula: RR_i = timestamp(R_{i+1}) - timestamp(R_i)
  List<double> _computeRRIntervals() {
    if (rPeakIndices.length < 2) return [];
    List<double> intervals = [];
    for (int i = 1; i < rPeakIndices.length; i++) {
      final dt = dataPoints[rPeakIndices[i]]
          .timestamp
          .difference(dataPoints[rPeakIndices[i - 1]].timestamp);
      intervals.add(dt.inMicroseconds / 1000000.0);
    }
    return intervals;
  }

  /// Heart Rate (BPM) from each RR interval
  /// Formula: HR = 60 / RR_interval
  List<double> _computeHeartRates() {
    return rrIntervals
        .where((rr) => rr > 0)
        .map((rr) => 60.0 / rr)
        .toList();
  }

  /// SDNN — Standard Deviation of NN (RR) intervals
  /// Formula: SDNN = sqrt( sum((RR_i - mean_RR)^2) / N )
  double _computeSDNN() {
    if (rrIntervals.length < 2) return 0;
    final mean = rrIntervals.reduce((a, b) => a + b) / rrIntervals.length;
    final variance = rrIntervals
            .map((rr) => pow(rr - mean, 2))
            .reduce((a, b) => a + b) /
        rrIntervals.length;
    return sqrt(variance) * 1000; // convert to ms
  }

  /// RMSSD — Root Mean Square of Successive Differences
  /// Formula: RMSSD = sqrt( sum((RR_{i+1} - RR_i)^2) / (N-1) )
  double _computeRMSSD() {
    if (rrIntervals.length < 2) return 0;
    double sumSquaredDiffs = 0;
    for (int i = 1; i < rrIntervals.length; i++) {
      sumSquaredDiffs += pow(rrIntervals[i] - rrIntervals[i - 1], 2);
    }
    return sqrt(sumSquaredDiffs / (rrIntervals.length - 1)) * 1000; // ms
  }
}
