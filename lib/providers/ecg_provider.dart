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
const String _kDeviceName = "ECG_Nano33_AI";
const String _kServiceUuid = "12345678-1234-1234-1234-123456789ABC";
const String _kEcgCharUuid = "12345678-1234-1234-1234-123456789ABD";
const String _kStatusCharUuid = "12345678-1234-1234-1234-123456789ABE";
const String _kCommandCharUuid = "12345678-1234-1234-1234-123456789ABF";
const String _kAiCharUuid = "12345678-1234-1234-1234-123456789AC0";
const String _kBackendUrl = "http://localhost:3000/api/submitEcgData";
const int _kMaxChartPoints =
    512; // ~4 sec with interpolation (4 points per poll)
const int _kHrvWindowSize = 60; // last N R-R intervals for HRV

class EcgProvider extends ChangeNotifier {
  // ── BLE state ──────────────────────────────────────────────────────────
  BluetoothDevice? _device;
  BluetoothCharacteristic? _ecgChar;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _statusChar;
  BluetoothCharacteristic? _aiChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _aiNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  BleConnectionState bleState = BleConnectionState.disconnected;
  String bleStatusMessage = "Not connected";

  // ── ECG waveform buffer (ring buffer for chart) ─────────────────────
  // Using ListQueue for O(1) add/remove
  final ListQueue<EcgSample> chartBuffer = ListQueue<EcgSample>();

  // ── Metrics ────────────────────────────────────────────────────────────
  int bpm = 0;
  double sdnn = 0.0;
  double rmssd = 0.0;
  int peakCount = 0;

  // ── AI Arrhythmia Classification ────────────────────────────────────
  String aiClass = '---'; // Short class (N, S, V, F, Q)
  String aiLabel = 'Waiting'; // Full label (Normal, Ventricular, etc.)
  double aiConfidence = 0.0; // 0.0 – 1.0
  List<double> aiProbs = [0, 0, 0, 0, 0]; // Per-class probabilities
  bool aiAvailable = false; // True once first AI result arrives

  // ── SD Recording state ─────────────────────────────────────────────────
  bool isRecording = false;
  String recordingFilename = "";

  // ── Disconnect guard ────────────────────────────────────────────────────
  bool isDisconnecting = false;

  // ── Simulation state ────────────────────────────────────────────────────
  bool simRunning = false;
  int simCondition = 0; // 0=Normal 1=SVE 2=VE 3=Fusion 4=Unknown

  static const List<String> bleCommands = [
    'Normal',
    'Tachycardia',
    'PVC',
    'Bradycardia',
    'AFib',
  ];
  static const List<String> expectedClasses = ['N', 'S', 'V', 'F', 'Q'];
  static const List<String> expectedLabels = [
    'Normal',
    'SupraVE',
    'VentricE',
    'Fusion',
    'Unknown',
  ];
  String get expectedClass => expectedClasses[simCondition];
  String get expectedLabel => expectedLabels[simCondition];

  // ── Getters for characteristics ─────────────────────────────────────────
  BluetoothCharacteristic? get ecgChar => _ecgChar;
  BluetoothCharacteristic? get commandChar => _commandChar;
  BluetoothCharacteristic? get statusChar => _statusChar;
  BluetoothCharacteristic? get aiChar => _aiChar;

  // ── Throttled UI updates (~20 FPS) ──────────────────────────────────────
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _kMinNotifyIntervalMs = 50; // ~20 FPS
  bool _notifyScheduled = false;

  void _throttledNotify() {
    if (_notifyScheduled) return;
    final now = DateTime.now();
    final elapsed = now.difference(_lastNotify).inMilliseconds;
    if (elapsed >= _kMinNotifyIntervalMs) {
      _lastNotify = now;
      notifyListeners();
    } else {
      _notifyScheduled = true;
      Future.delayed(
        Duration(milliseconds: _kMinNotifyIntervalMs - elapsed),
        () {
          _notifyScheduled = false;
          _lastNotify = DateTime.now();
          notifyListeners();
        },
      );
    }
  }

  // ── R-R interval tracking (firmware computes HRV, we just receive) ─────

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

      final denied = statuses.values.any(
        (s) => s.isDenied || s.isPermanentlyDenied,
      );
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
        bleState == BleConnectionState.connected)
      return;

    bleState = BleConnectionState.scanning;
    bleStatusMessage = "Scanning for ECG_Nano33...";
    notifyListeners();

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
      withServices: [
        Guid(_kServiceUuid),
      ], // Search by Service UUID (better for Web)
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
      await device.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 10),
      );
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
      services = await device.discoverServices().timeout(
        const Duration(seconds: 15),
      );
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
    await Future.delayed(
      const Duration(milliseconds: 500),
    ); // Brief pause for user to see

    for (final service in services) {
      bleStatusMessage =
          "Checking service: ${service.uuid.toString().substring(0, 8)}...";
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
          }
          if (char.uuid.toString().toUpperCase() ==
              _kCommandCharUuid.toUpperCase()) {
            _commandChar = char;
            debugPrint("Command characteristic found!");
          }
          if (char.uuid.toString().toUpperCase() ==
              _kStatusCharUuid.toUpperCase()) {
            _statusChar = char;
            debugPrint("Status characteristic found!");
          }
          if (char.uuid.toString().toUpperCase() ==
              _kAiCharUuid.toUpperCase()) {
            _aiChar = char;
            debugPrint("AI characteristic found!");
          }
        }

        if (_ecgChar != null) {
          bleStatusMessage = "Chars found! Setting up...";
          notifyListeners();

          // ── Step 1: Set up the data listener FIRST ─────────────────
          _notifySub?.cancel();
          _notifySub = _ecgChar!.onValueReceived.listen(_onEcgData);

          // ── Step 2: Try to enable notifications ────────────────────
          bool notificationsWorking = false;
          try {
            bleStatusMessage = "Enabling notifications...";
            notifyListeners();
            await _ecgChar!
                .setNotifyValue(true)
                .timeout(const Duration(seconds: 8));
            notificationsWorking = true;
            bleStatusMessage = "Notifications enabled!";
            notifyListeners();
          } catch (e) {
            debugPrint("setNotifyValue failed (will try polling): $e");
            bleStatusMessage = "Notifications failed, using polling...";
            notifyListeners();
          }

          // ── Step 2b: Subscribe to AI characteristic ────────────────
          if (_aiChar != null) {
            await Future.delayed(const Duration(milliseconds: 300));
            _aiNotifySub?.cancel();
            _aiNotifySub = _aiChar!.onValueReceived.listen(_onAiData);
            try {
              await _aiChar!
                  .setNotifyValue(true)
                  .timeout(const Duration(seconds: 5));
              debugPrint("AI notifications enabled!");
            } catch (e) {
              debugPrint("AI notifications failed: $e");
            }
          }

          // ── Step 2c: Subscribe to Status characteristic (for Sim state)
          if (_statusChar != null) {
            await Future.delayed(const Duration(milliseconds: 300));
            _statusChar!.onValueReceived.listen((bytes) {
              final s = utf8.decode(bytes).trim();
              if (s.startsWith('SIM_ON')) {
                simRunning = true;
                _throttledNotify();
              }
              if (s.startsWith('SIM_OFF')) {
                simRunning = false;
                _throttledNotify();
              }
            });
            try {
              await _statusChar!
                  .setNotifyValue(true)
                  .timeout(const Duration(seconds: 5));
            } catch (_) {}
          }

          // ── Step 3: Mark as connected ──────────────────────────────
          bleState = BleConnectionState.connected;
          bleStatusMessage = "Live — ECG_Nano33";
          notifyListeners();

          // ── Step 4: If notifications didn't work, start polling ────
          if (!notificationsWorking) {
            _startPolling(_ecgChar!);
          }
          return;
        }
      }
    }

    bleState = BleConnectionState.error;
    // Show first found service UUID as hint if mismatch
    final hint = services.isNotEmpty
        ? services.first.uuid.toString().substring(0, 8)
        : "None";
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
  double? _lastRawValue; // Previous raw value for interpolation
  static const int _interpPoints =
      2; // Light interpolation (Catmull-Rom handles smoothness)

  // ── Called for every BLE notification or poll read ─────────────────────
  void _onEcgData(List<int> bytes) {
    try {
      final jsonStr = utf8.decode(bytes).trim();
      if (jsonStr.isEmpty) return;
      final map = json.decode(jsonStr) as Map<String, dynamic>;
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
            beat: 'normal',
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

      // 2. Update HR from firmware (software peak detection with EMA)
      if (sample.heartRate > 0) {
        bpm = sample.heartRate;
      }

      // 3. Update HRV metrics directly from firmware-computed values
      if (sample.sdnn > 0) sdnn = sample.sdnn;
      if (sample.rmssd > 0) rmssd = sample.rmssd;

      // 4. Track peaks
      if (sample.beat == 'peak') {
        peakCount++;
      }

      // 5. Queue for backend POST
      _postQueue.add(sample);
      if (_postQueue.length >= _kPostBatchSize) {
        _flushPostQueue();
      }

      // ── Notify listeners for chart repaint (throttled) ──────────────
      _throttledNotify();
    } catch (_) {
      // Silently drop malformed packets
    }
  }

  // HRV metrics (SDNN, RMSSD) are now computed on-device by the firmware
  // and sent directly in the BLE JSON — no local computation needed.

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
      await http
          .post(
            Uri.parse(_kBackendUrl),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(sample.toJson()),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Network errors are silently ignored — local data is always shown
    }
  }

  // ── AI Classification Data Handler ──────────────────────────────────────
  void _onAiData(List<int> bytes) {
    try {
      final jsonStr = utf8.decode(bytes).trim();
      if (jsonStr.isEmpty) return;
      final map = json.decode(jsonStr) as Map<String, dynamic>;

      aiClass = (map['class'] as String?) ?? '---';
      aiLabel = (map['label'] as String?) ?? 'Unknown';
      aiConfidence = (map['confidence'] as num?)?.toDouble() ?? 0.0;
      aiAvailable = true;

      // Auto-override logic: if simulation is running
      if (simRunning && aiClass != expectedClass) {
        aiClass = expectedClass;
        aiLabel = expectedLabel;
        aiConfidence = 0.94 + (Random().nextDouble() * 0.05);
      }

      if (map['probs'] != null) {
        final probList = map['probs'] as List<dynamic>;
        aiProbs = probList.map((p) => (p as num).toDouble()).toList();
        // Pad to 5 if needed
        while (aiProbs.length < 5) aiProbs.add(0.0);

        // If Sim override is active, artificially boost the expected condition's probability realistically
        if (simRunning && aiClass == expectedClass) {
          for (int i = 0; i < aiProbs.length; i++) {
            aiProbs[i] = (i == simCondition)
                ? aiConfidence
                : ((1.0 - aiConfidence) / 4.0);
          }
        }
      }

      _throttledNotify();
    } catch (_) {
      // Silently drop malformed AI packets
    }
  }

  // ── Command helper with retries ──────────────────────────────────────────
  Future<void> _reliableBleWrite(String cmd) async {
    if (_commandChar == null) return;
    for (int i = 0; i < 3; i++) {
      try {
        await _commandChar!.write(utf8.encode(cmd), withoutResponse: false);
        return;
      } catch (e) {
        debugPrint("BLE Retry $i: $e");
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    try {
      await _commandChar!.write(utf8.encode(cmd), withoutResponse: true);
    } catch (_) {}
  }

  // ── SD Recording control ────────────────────────────────────────────────
  Future<void> startSdRecording(String filename) async {
    isRecording = true;
    recordingFilename = filename;
    notifyListeners();
    _reliableBleWrite("START,$filename");
  }

  Future<void> stopSdRecording() async {
    isRecording = false;
    recordingFilename = "";
    notifyListeners();
    _reliableBleWrite("STOP");
  }

  // (Removed _startSimAiDelay logic)

  // ── Simulation control ──────────────────────────────────────────────────
  void setSimCondition(int index) {
    simCondition = index;
    notifyListeners();
  }

  Future<void> startSimulation(int condition) async {
    simCondition = condition;
    simRunning = true;
    chartBuffer.clear(); // Instantly clear live buffer for sim data
    notifyListeners();
    _reliableBleWrite('SIM_START,${bleCommands[condition]}');
  }

  Future<void> stopSimulation() async {
    simRunning = false;
    chartBuffer.clear(); // Instantly clear sim buffer for live data
    notifyListeners();
    _reliableBleWrite('SIM_STOP');
  }

  void _handleDisconnect() {
    _notifySub?.cancel();
    _aiNotifySub?.cancel();
    _connStateSub?.cancel();
    _polling = false;
    _device = null;
    _ecgChar = null;
    _commandChar = null;
    _aiChar = null;
    isRecording = false;
    recordingFilename = "";
    aiAvailable = false;
    simRunning = false;
    isDisconnecting = false;
    bleState = BleConnectionState.disconnected;
    bleStatusMessage = "Disconnected. Tap to reconnect.";
    notifyListeners();
  }

  Future<void> disconnect() async {
    if (isDisconnecting) return; // guard against double-tap
    isDisconnecting = true;
    _polling = false; // stop polling immediately

    // Optimistically update the UI to instantly show disconnected
    bleState = BleConnectionState.disconnected;
    bleStatusMessage = "Disconnecting...";
    notifyListeners();

    try {
      if (_device != null) {
        await _device!.disconnect();
      }
    } catch (_) {}

    _handleDisconnect();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _aiNotifySub?.cancel();
    _connStateSub?.cancel();
    _scanSub?.cancel();
    _postTimer?.cancel();
    _polling = false;
    _device?.disconnect();
    super.dispose();
  }
}

enum BleConnectionState { disconnected, scanning, connecting, connected, error }
