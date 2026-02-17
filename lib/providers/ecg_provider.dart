import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../models/ecg_sample.dart';

// ── Constants ──────────────────────────────────────────────────────────────
const String _kDeviceName      = "ECG_Nano33";
const String _kServiceUuid     = "12345678-1234-1234-1234-123456789ABC";
const String _kEcgCharUuid     = "12345678-1234-1234-1234-123456789ABD";
const String _kStatusCharUuid  = "12345678-1234-1234-1234-123456789ABE";
const String _kBackendUrl      = "https://iot-ecg-backend.vercel.app/api/submitEcgData";
const int    _kMaxChartPoints  = 512; // ~4 sec with interpolation (4 points per poll)
const int    _kHrvWindowSize   = 60;  // last N R-R intervals for HRV

class EcgProvider extends ChangeNotifier {
  // ── BLE state ──────────────────────────────────────────────────────────
  BluetoothDevice? _device;
  BluetoothCharacteristic? _ecgChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  BleConnectionState bleState = BleConnectionState.disconnected;
  String bleStatusMessage = "Not connected";

  // ── ECG waveform buffer (ring buffer for chart) ─────────────────────
  // Using ListQueue for O(1) add/remove
  final ListQueue<EcgSample> chartBuffer = ListQueue<EcgSample>();

  // ── Metrics ────────────────────────────────────────────────────────────
  int    bpm        = 0;
  double sdnn       = 0.0;
  double rmssd      = 0.0;
  String bpmStatus  = "—";   // "Normal" | "Tachycardia" | "Bradycardia"
  int    peakCount  = 0;

  // ── R-R interval tracking for HRV ──────────────────────────────────────
  DateTime? _lastPeakTime;
  final ListQueue<double> _rrIntervals = ListQueue<double>(); // ms

  // ── HTTP post queue (fire-and-forget, non-blocking) ─────────────────
  // We batch post every N samples to avoid flooding the backend at 128 SPS
  final List<EcgSample> _postQueue = [];
  static const int _kPostBatchSize = 5;
  Timer? _postTimer;

  // ── Public API ──────────────────────────────────────────────────────────

  Future<void> requestPermissionsAndScan() async {
    // Request BT + location permissions
    if (!kIsWeb) {
      final statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final denied = statuses.values.any((s) => s.isDenied || s.isPermanentlyDenied);
      if (denied) {
        bleStatusMessage = "Bluetooth permissions denied";
        bleState = BleConnectionState.error;
        notifyListeners();
        return;
      }
    }



    await startScan();
  }

  Future<void> startScan() async {
    if (bleState == BleConnectionState.scanning ||
        bleState == BleConnectionState.connected) return;

    bleState = BleConnectionState.scanning;
    bleStatusMessage = "Scanning for ECG_Nano33...";
    notifyListeners();

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
      withServices: [Guid(_kServiceUuid)], // Search by Service UUID (better for Web)
      // withNames: [_kDeviceName], // Name can be unreliable in advertising packets
    );

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        // On Web, the user explicitly selects the device in the browser picker, so accept any result.
        // On Mobile, we filter by name or if it advertises the service.
        final name = r.device.platformName;
        if (kIsWeb || name == _kDeviceName || name.contains("Arduino")) {
          // If multiple devices found, pick the first one that matches
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });

    // Scan timeout handler
    FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && bleState == BleConnectionState.scanning) {
        bleState = BleConnectionState.disconnected;
        bleStatusMessage = "Device not found. Tap to retry.";
        notifyListeners();
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _device = device;
    bleState = BleConnectionState.connecting;
    bleStatusMessage = "Connecting to ECG_Nano33...";
    notifyListeners();

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "Connection failed: $e";
      notifyListeners();
      return;
    }

    // Listen for disconnect events
    _connStateSub?.cancel();
    _connStateSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _handleDisconnect();
      }
    });

    await _discoverAndSubscribe(device);
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    bleStatusMessage = "Discovering services...";
    notifyListeners();

    List<BluetoothService> services;
    try {
      services = await device
          .discoverServices()
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "Discovery failed/timed out: $e";
      notifyListeners();
      return;
    }

    if (services.isEmpty) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "No services found on device.";
      notifyListeners();
      return;
    }

    // DEBUG: print found services to console/status
    bleStatusMessage = "Found ${services.length} services...";
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 500)); // Brief pause for user to see

    for (final service in services) {
      bleStatusMessage = "Checking service: ${service.uuid.toString().substring(0, 8)}...";
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 300)); // Visual delay

      if (service.uuid.toString().toUpperCase() ==
          _kServiceUuid.toUpperCase()) {
        bleStatusMessage = "Service matched! Checking chars...";
        notifyListeners();

        for (final char in service.characteristics) {
          if (char.uuid.toString().toUpperCase() ==
              _kEcgCharUuid.toUpperCase()) {
            _ecgChar = char;
            bleStatusMessage = "Char found! Setting up...";
            notifyListeners();

            // ── Step 1: Set up the data listener FIRST ─────────────────
            _notifySub?.cancel();
            _notifySub = char.onValueReceived.listen(_onEcgData);

            // ── Step 2: Try to enable notifications ────────────────────
            // On Web Bluetooth, setNotifyValue often times out due to
            // flutter_blue_plus Web implementation limitations.
            // We treat this as non-fatal and fall back to polling.
            bool notificationsWorking = false;
            try {
              bleStatusMessage = "Enabling notifications...";
              notifyListeners();
              await char.setNotifyValue(true)
                  .timeout(const Duration(seconds: 8));
              notificationsWorking = true;
              bleStatusMessage = "Notifications enabled!";
              notifyListeners();
            } catch (e) {
              debugPrint("setNotifyValue failed (will try polling): $e");
              bleStatusMessage = "Notifications failed, using polling...";
              notifyListeners();
            }

            // ── Step 3: Mark as connected ──────────────────────────────
            bleState = BleConnectionState.connected;
            bleStatusMessage = "Live — ECG_Nano33";
            notifyListeners();

            // ── Step 4: If notifications didn't work, start polling ────
            if (!notificationsWorking) {
              _startPolling(char);
            }
            return;
          }
        }
      }
    }



    bleState = BleConnectionState.error;
    // Show first found service UUID as hint if mismatch
    final hint = services.isNotEmpty ? services.first.uuid.toString().substring(0, 8) : "None";
    bleStatusMessage = "ECG Svc/Char not found. Found: $hint...";
    notifyListeners();
  }

  // ── Polling fallback for Web Bluetooth ───────────────────────────────────
  bool _polling = false;

  void _startPolling(BluetoothCharacteristic char) {
    if (_polling) return;
    _polling = true;
    _pollLoop(char);
  }

  Future<void> _pollLoop(BluetoothCharacteristic char) async {
    // Sequential polling loop — no Timer.periodic, no callback pile-ups
    while (_polling && bleState == BleConnectionState.connected) {
      try {
        final value = await char.read().timeout(const Duration(seconds: 3));
        if (value.isNotEmpty) {
          _onEcgData(value);
        }
      } catch (e) {
        debugPrint("Poll read error: $e");
        // Small backoff on error to avoid hammering
        await Future.delayed(const Duration(milliseconds: 200));
      }
      // ~5 Hz polling — very gentle on Arduino BLE stack
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _polling = false;
  }

  // ── Interpolation state ─────────────────────────────────────────────────
  double? _lastRawValue;      // Previous raw value for interpolation
  static const int _interpPoints = 2;  // Light interpolation (Catmull-Rom handles smoothness)

  // ── Called for every BLE notification or poll read ─────────────────────
  void _onEcgData(List<int> bytes) {
    try {
      final jsonStr = utf8.decode(bytes).trim();
      if (jsonStr.isEmpty) return;
      final map    = json.decode(jsonStr) as Map<String, dynamic>;
      final sample = EcgSample.fromJson(map);

      final rawVal = sample.ecgValue;

      // ── Interpolation: insert points between samples for density ───────
      // NO smoothing applied — preserves sharp QRS peaks
      // Catmull-Rom spline in chart handles visual smoothness
      if (_lastRawValue != null && (_lastRawValue! - rawVal).abs() > 0.0001) {
        for (int j = 1; j <= _interpPoints; j++) {
          final t = j / (_interpPoints + 1);
          final interpVal = _lastRawValue! + (rawVal - _lastRawValue!) * t;

          final interpSample = EcgSample(
            timestamp: sample.timestamp,
            ecgValue: interpVal,
            status: 'normal',
          );
          chartBuffer.addLast(interpSample);
          if (chartBuffer.length > _kMaxChartPoints) {
            chartBuffer.removeFirst();
          }
        }
      }
      _lastRawValue = rawVal;

      // 1. Update waveform chart buffer (raw value, no smoothing)
      chartBuffer.addLast(sample);
      if (chartBuffer.length > _kMaxChartPoints) {
        chartBuffer.removeFirst();
      }

      // 2. Update HRV & BPM on peaks
      if (sample.status == 'peak') {
        _processPeak(sample.timestamp);
      }

      // 3. Queue for backend POST
      _postQueue.add(sample);
      if (_postQueue.length >= _kPostBatchSize) {
        _flushPostQueue();
      }

      // ── Notify listeners for chart repaint ──────────────────────────
      scheduleMicrotask(() => notifyListeners());

    } catch (_) {
      // Silently drop malformed packets
    }
  }

  void _processPeak(DateTime peakTime) {
    peakCount++;
    if (_lastPeakTime != null) {
      final rrMs = peakTime.difference(_lastPeakTime!).inMilliseconds.toDouble();
      if (rrMs > 300 && rrMs < 2000) { // valid R-R: 30–200 BPM
        _rrIntervals.addLast(rrMs);
        if (_rrIntervals.length > _kHrvWindowSize) {
          _rrIntervals.removeFirst();
        }
        _updateMetrics(rrMs);
      }
    }
    _lastPeakTime = peakTime;
  }

  void _updateMetrics(double latestRrMs) {
    if (_rrIntervals.isEmpty) return;

    // BPM from latest R-R
    bpm = (60000 / latestRrMs).round().clamp(20, 250);
    bpmStatus = bpm > 100 ? "Tachycardia"
              : bpm < 60  ? "Bradycardia"
                           : "Normal";

    if (_rrIntervals.length < 2) return;

    final list = _rrIntervals.toList();
    final mean = list.reduce((a, b) => a + b) / list.length;

    // SDNN
    final variance = list.map((x) => pow(x - mean, 2)).reduce((a, b) => a + b) / list.length;
    sdnn = sqrt(variance);

    // RMSSD
    double sumSqDiff = 0;
    for (int i = 1; i < list.length; i++) {
      sumSqDiff += pow(list[i] - list[i - 1], 2);
    }
    rmssd = sqrt(sumSqDiff / (list.length - 1));
  }

  // ── Backend POST (batched, fire-and-forget) ─────────────────────────────
  void _flushPostQueue() {
    if (_postQueue.isEmpty) return;
    final batch = List<EcgSample>.from(_postQueue);
    _postQueue.clear();

    // Post each sample individually to match your existing backend schema
    for (final sample in batch) {
      _postSample(sample);
    }
  }

  Future<void> _postSample(EcgSample sample) async {
    try {
      await http.post(
        Uri.parse(_kBackendUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(sample.toJson()),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Network errors are silently ignored — local data is always shown
    }
  }

  void _handleDisconnect() {
    _notifySub?.cancel();
    _connStateSub?.cancel();
    _polling = false;
    _device = null;
    _ecgChar = null;
    bleState = BleConnectionState.disconnected;
    bleStatusMessage = "Disconnected. Tap to reconnect.";
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _handleDisconnect();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _connStateSub?.cancel();
    _scanSub?.cancel();
    _postTimer?.cancel();
    _polling = false;
    _device?.disconnect();
    super.dispose();
  }
}

enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}
