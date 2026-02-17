import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:csv/csv.dart';
import '../models/ecg_data.dart';

import 'package:http/http.dart' as http;

class EcgService {
  static const String _baseUrl = 'https://iot-ecg-backend.vercel.app/api';

  /// Fetch the latest 300 ECG data points from the backend
  Future<EcgSession?> fetchLatestData() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/getLatestEcg'));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['success'] == true && json['data'] != null) {
          final List<dynamic> data = json['data'];
          final dataPoints = data.map((d) => EcgDataPoint.fromJson(d)).toList();
          if (dataPoints.isEmpty) return null;
          
          // Sort by timestamp just in case
          dataPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          
          return EcgSession(dataPoints: dataPoints);
        }
      } else {
        print('Server error: ${response.statusCode}');
      }
      return null;
    } catch (e) {
      print('Error fetching data: $e');
      return null;
    }
  }



  /// Parse ECG data from a CSV string
  EcgSession? parseFromCsvString(String csvContent) {
    try {
      final rows = const CsvToListConverter().convert(csvContent, eol: '\n');
      if (rows.isEmpty) return null;

      // Skip header row if present
      final startIndex =
          rows[0][0].toString().toLowerCase().contains('timestamp') ? 1 : 0;

      final dataPoints = <EcgDataPoint>[];
      for (int i = startIndex; i < rows.length; i++) {
        if (rows[i].length >= 3) {
          try {
            dataPoints.add(EcgDataPoint.fromCsvRow(rows[i]));
          } catch (e) {
            print('Skipping malformed row $i: $e');
          }
        }
      }

      if (dataPoints.isEmpty) return null;
      return EcgSession(dataPoints: dataPoints);
    } catch (e) {
      print('Error parsing CSV string: $e');
      return null;
    }
  }

  /// Parse ECG data from JSON string
  /// Expected format:
  /// {
  ///   "session_id": "session_001",
  ///   "device_id": "ecg_sensor_01",
  ///   "data": [
  ///     {"timestamp": "2026-02-17T02:00:00.000Z", "ecg_value": 0.45, "status": "normal"},
  ///     ...
  ///   ]
  /// }
  EcgSession? parseFromJson(String jsonString) {
    try {
      final json = jsonDecode(jsonString);
      final List<dynamic> data = json['data'];
      final dataPoints = data.map((d) => EcgDataPoint.fromJson(d)).toList();
      if (dataPoints.isEmpty) return null;
      return EcgSession(dataPoints: dataPoints);
    } catch (e) {
      print('Error parsing JSON: $e');
      return null;
    }
  }

  /// Generate sample CSV content for testing
  static String generateSampleCsv() {
    final buffer = StringBuffer();
    buffer.writeln('timestamp,ecg_value,status');

    final now = DateTime.now();

    // Simulate 10 seconds of ECG at 250Hz
    for (int i = 0; i < 2500; i++) {
      final t = i / 250.0; // time in seconds
      final timestamp = now.add(Duration(milliseconds: (t * 1000).round()));

      // Simulate a realistic ECG waveform (simplified PQRST)
      double ecg = _simulateEcgValue(t);
      String status = ecg.abs() > 0.8 ? 'peak' : 'normal';

      buffer.writeln('${timestamp.toIso8601String()},$ecg,$status');
    }
    return buffer.toString();
  }

  static double _simulateEcgValue(double t) {
    // Heart rate ~72 bpm = 1.2 Hz, period ~0.833s
    const period = 0.833;
    final phase = (t % period) / period;

    // P wave
    if (phase >= 0.0 && phase < 0.12) {
      return 0.15 * _gaussian(phase, 0.06, 0.025);
    }
    // Q wave
    if (phase >= 0.12 && phase < 0.17) {
      return -0.1 * _gaussian(phase, 0.145, 0.012);
    }
    // R wave (tall peak)
    if (phase >= 0.17 && phase < 0.24) {
      return 1.2 * _gaussian(phase, 0.20, 0.014);
    }
    // S wave
    if (phase >= 0.24 && phase < 0.30) {
      return -0.2 * _gaussian(phase, 0.27, 0.015);
    }
    // T wave
    if (phase >= 0.38 && phase < 0.58) {
      return 0.25 * _gaussian(phase, 0.48, 0.04);
    }
    // Baseline with small noise
    return 0.0;
  }

  static double _gaussian(double x, double mu, double sigma) {
    final exponent = -0.5 * pow((x - mu) / sigma, 2);
    return exp(exponent);
  }
}
