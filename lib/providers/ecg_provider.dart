import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import '../models/ecg_sample.dart';

// ── Constants ──────────────────────────────────────────────────────────────
const String _kDeviceName      = "ECG_Nano33_AI";
const String _kServiceUuid     = "12345678-1234-1234-1234-123456789ABC";
const String _kEcgCharUuid     = "12345678-1234-1234-1234-123456789ABD";
const String _kStatusCharUuid  = "12345678-1234-1234-1234-123456789ABE";
const String _kCommandCharUuid = "12345678-1234-1234-1234-123456789ABF";
const String _kAiCharUuid      = "12345678-1234-1234-1234-123456789AC0";
const String _kBackendUrl      = "http://localhost:3000/api/submitEcgData";
const int    _kMaxChartPoints  = 512; // ~4 sec with interpolation

// ── Simulation Conditions ────────────────────────────────────────────────
class SimCondition {
  final int id;
  final String name;
  final String subtitle;
  final int bpm;

  const SimCondition({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.bpm,
  });
}

const List<SimCondition> simConditions = [
  SimCondition(id: 0, name: 'Normal',        subtitle: 'Clean sinus rhythm (N)',             bpm: 72),
  SimCondition(id: 1, name: 'SupraVE',       subtitle: 'Supraventricular ectopic (S)',       bpm: 72),
  SimCondition(id: 2, name: 'VentricE',      subtitle: 'Ventricular ectopic (V)',            bpm: 72),
  SimCondition(id: 3, name: 'Fusion',        subtitle: 'Fusion beat (F)',                    bpm: 72),
  SimCondition(id: 4, name: 'Unknown',       subtitle: 'Noisy / unclassifiable (Q)',         bpm: 0),
];

class EcgProvider extends ChangeNotifier {
  // ── BLE state ──────────────────────────────────────────────────────────
  BluetoothDevice? _device;
  BluetoothCharacteristic? _ecgChar;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _aiChar;
  BluetoothCharacteristic? _statusChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _aiNotifySub;
  StreamSubscription<List<int>>? _statusNotifySub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;

  // ── Live stream control / recovery ─────────────────────────────────────
  bool _livePaused = false;
  bool _usingPolling = false;
  DateTime _lastEcgPacketAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _ecgWatchdog;
  static const Duration _kFreezeTimeout = Duration(seconds: 4);

  // ── Auto-reconnect ──────────────────────────────────────────────────────
  bool _userInitiatedDisconnect = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const int _kMaxReconnectAttempt = 6;

  BleConnectionState bleState = BleConnectionState.disconnected;
  String bleStatusMessage = "Not connected";

  // ── ECG waveform buffer (ring buffer for chart) ─────────────────────
  final ListQueue<EcgSample> chartBuffer = ListQueue<EcgSample>();

  // ── Metrics ────────────────────────────────────────────────────────────
  int    bpm        = 0;
  double sdnn       = 0.0;
  double rmssd      = 0.0;
  int    peakCount  = 0;

  // ── AI Arrhythmia Classification ────────────────────────────────────
  String aiClass      = '---';     // Short class (N, S, V, F, Q)
  String aiLabel      = 'Waiting'; // Full label (Normal, Ventricular, etc.)
  double aiConfidence = 0.0;       // 0.0 – 1.0
  List<double> aiProbs = [0, 0, 0, 0, 0]; // Per-class probabilities
  bool   aiAvailable  = false;     // True once first AI result arrives

  // ── Simulation Mode ─────────────────────────────────────────────────────
  bool   isSimulating       = false;
  int    activeSimCondition = -1;   // 0-4, corresponds to simConditions[i].id

  // ── SD Recording state ─────────────────────────────────────────────────
  bool   isRecording     = false;
  String recordingFilename = "";
  bool   isStoppingRecording = false;

  // ── Disconnect guard ────────────────────────────────────────────────────
  bool isDisconnecting = false;

  // ── Throttled UI updates (~20 FPS) ──────────────────────────────────────
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _kMinNotifyIntervalMs = 50;
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
      Future.delayed(Duration(milliseconds: _kMinNotifyIntervalMs - elapsed), () {
        _notifyScheduled = false;
        _lastNotify = DateTime.now();
        notifyListeners();
      });
    }
  }

  // ── HTTP post queue (fire-and-forget, non-blocking) ─────────────────
  final List<EcgSample> _postQueue = [];
  static const int _kPostBatchSize = 5;
  Timer? _postTimer;

  // ── Public API ──────────────────────────────────────────────────────────

  Future<void> requestPermissionsAndScan() async {
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
        bleState == BleConnectionState.connected) {
      return;
    }

    bleState = BleConnectionState.scanning;
    bleStatusMessage = "Scanning for ECG_Nano33...";
    notifyListeners();

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
      withServices: [Guid(_kServiceUuid)],
    );

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        if (kIsWeb || name == _kDeviceName || name.contains("Arduino")) {
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });

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
    _userInitiatedDisconnect = false;
    bleState = BleConnectionState.connecting;
    bleStatusMessage = "Connecting…";
    notifyListeners();

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "Couldn't connect. Tap to retry.";
      notifyListeners();
      return;
    }

    _connStateSub?.cancel();
    _connStateSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _handleDisconnect();
      }
    });

    await _discoverAndSubscribe(device);
  }

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    bleStatusMessage = "Connecting...";

    List<BluetoothService> services;
    try {
      services = await device
          .discoverServices()
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "Connection lost. Reconnecting…";
      notifyListeners();
      _scheduleReconnect();
      return;
    }

    if (services.isEmpty) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "No services found on device.";
      notifyListeners();
      return;
    }

    debugPrint("Found ${services.length} services...");
    await Future.delayed(const Duration(milliseconds: 500));

    for (final service in services) {
      debugPrint("Checking service: ${service.uuid.toString().substring(0, 8)}...");
      await Future.delayed(const Duration(milliseconds: 300));

      if (service.uuid.toString().toUpperCase() ==
          _kServiceUuid.toUpperCase()) {
        debugPrint("Service matched! Checking chars...");

        for (final char in service.characteristics) {
          if (char.uuid.toString().toUpperCase() == _kEcgCharUuid.toUpperCase()) {
            _ecgChar = char;
          }
          if (char.uuid.toString().toUpperCase() == _kCommandCharUuid.toUpperCase()) {
            _commandChar = char;
            debugPrint("Command characteristic found!");
          }
          if (char.uuid.toString().toUpperCase() == _kAiCharUuid.toUpperCase()) {
            _aiChar = char;
            debugPrint("AI characteristic found!");
          }
          if (char.uuid.toString().toUpperCase() == _kStatusCharUuid.toUpperCase()) {
            _statusChar = char;
            debugPrint("Status characteristic found!");
          }
        }

        if (_ecgChar != null) {
            debugPrint("Chars found! Setting up...");

            // ── Step 1: Set up the data listener FIRST ─────────────────
            _notifySub?.cancel();
            _notifySub = _ecgChar!.onValueReceived.listen(
              _onEcgData,
              onError: (_) => _scheduleEcgRecovery(),
              onDone: _scheduleEcgRecovery,
              cancelOnError: false,
            );

            // ── Step 2: Try to enable notifications ────────────────────
            bool notificationsWorking = false;
            try {
              bleStatusMessage = "Enabling notifications...";
              notifyListeners();
              await _ecgChar!.setNotifyValue(true)
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
              _aiNotifySub?.cancel();
              _aiNotifySub = _aiChar!.onValueReceived.listen(_onAiData);
              try {
                await _aiChar!.setNotifyValue(true)
                    .timeout(const Duration(seconds: 5));
                debugPrint("AI notifications enabled!");
              } catch (e) {
                debugPrint("AI notifications failed: $e");
              }
            }

            // ── Step 2c: Subscribe to Status characteristic ────────────
            if (_statusChar != null) {
              _statusNotifySub?.cancel();
              _statusNotifySub = _statusChar!.onValueReceived.listen(_onStatusData);
              try {
                await _statusChar!.setNotifyValue(true)
                    .timeout(const Duration(seconds: 5));
                debugPrint("Status notifications enabled!");
              } catch (e) {
                debugPrint("Status notifications failed: $e");
              }
            }

            // ── Step 3: Mark as connected ──────────────────────────────
            bleState = BleConnectionState.connected;
            bleStatusMessage = "Live — ECG_Nano33";
            _reconnectAttempt = 0;
            notifyListeners();

            // ── Step 4: If notifications didn't work, start polling ────
            if (!notificationsWorking) {
              debugPrint("Falling back to polling");
              _usingPolling = true;
              _startPolling(_ecgChar!);
            } else {
              _usingPolling = false;
            }

            _startEcgWatchdog();
            return;
        }
      }
    }

    bleState = BleConnectionState.error;
    bleStatusMessage = "Device services not found";
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
    while (_polling && bleState == BleConnectionState.connected) {
      try {
        final value = await char.read().timeout(const Duration(seconds: 3));
        if (value.isNotEmpty) {
          _onEcgData(value);
        }
      } catch (e) {
        debugPrint("Poll read error: $e");
        await Future.delayed(const Duration(milliseconds: 200));
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _polling = false;
  }

  // ── Interpolation state ─────────────────────────────────────────────────
  double? _lastRawValue;
  static const int _interpPoints = 2;

  // ── RX framing (newline-delimited JSON) ────────────────────────────────
  final List<int> _ecgRxBuffer = <int>[];
  int _consecutiveEcgParseFailures = 0;
  static const int _kMaxRxBufferBytes = 16 * 1024;

  // ── Called for every BLE notification or poll read ─────────────────────
  void _onEcgData(List<int> bytes) {
    if (bytes.isEmpty) return;
    _ecgRxBuffer.addAll(bytes);
    if (_ecgRxBuffer.length > _kMaxRxBufferBytes) {
      _ecgRxBuffer.clear();
      _consecutiveEcgParseFailures++;
      if (_consecutiveEcgParseFailures >= 5) {
        _scheduleEcgRecovery();
      }
      return;
    }

    while (true) {
      final start = _ecgRxBuffer.indexOf(123); // '{'
      if (start == -1) {
        if (_ecgRxBuffer.length > 1024) _ecgRxBuffer.clear();
        break;
      }
      if (start > 0) {
        _ecgRxBuffer.removeRange(0, start);
      }

      final nl = _ecgRxBuffer.indexOf(10); // '\n'
      if (nl != -1) {
        final frameBytes = _ecgRxBuffer.sublist(0, nl);
        _ecgRxBuffer.removeRange(0, nl + 1);
        _tryProcessEcgFrame(frameBytes);
        continue;
      }

      int depth = 0;
      bool inString = false;
      bool escape = false;
      int end = -1;
      for (int i = 0; i < _ecgRxBuffer.length; i++) {
        final b = _ecgRxBuffer[i];
        if (escape) { escape = false; continue; }
        if (b == 92) { if (inString) escape = true; continue; }
        if (b == 34) { inString = !inString; continue; }
        if (inString) continue;
        if (b == 123) { depth++; }
        else if (b == 125) { depth--; if (depth == 0) { end = i; break; } }
      }

      if (end == -1) break;

      final frameBytes = _ecgRxBuffer.sublist(0, end + 1);
      _ecgRxBuffer.removeRange(0, end + 1);
      _tryProcessEcgFrame(frameBytes);
    }
  }

  void _tryProcessEcgFrame(List<int> frameBytes) {
    try {
      final jsonStr = utf8.decode(frameBytes, allowMalformed: true).trim();
      if (jsonStr.isEmpty) return;

      final map = json.decode(jsonStr) as Map<String, dynamic>;
      final sample = EcgSample.fromJson(map);
      _consecutiveEcgParseFailures = 0;
      _lastEcgPacketAt = DateTime.now();

      final rawVal = sample.ecgValue;

      // ── Update chart buffer ────────────────────────────────────────────
      if (!isRecording) {
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
            if (chartBuffer.length > _kMaxChartPoints) chartBuffer.removeFirst();
          }
        }
        chartBuffer.addLast(sample);
        if (chartBuffer.length > _kMaxChartPoints) chartBuffer.removeFirst();
      }
      _lastRawValue = rawVal;

      // ── Update metrics ─────────────────────────────────────────────────
      if (sample.heartRate > 0) bpm = sample.heartRate;
      if (sample.sdnn > 0) sdnn = sample.sdnn;
      if (sample.rmssd > 0) rmssd = sample.rmssd;
      if (sample.beat == 'peak') peakCount++;

      // NOTE: Sim state is managed by startSimulation()/stopSimulation()
      // and confirmed by the firmware's SIM_ON/SIM_OFF status messages.
      // We intentionally do NOT override isSimulating from the ECG packet's
      // sim flag here — there is a race window where live packets (sim=0)
      // arrive after startSimulation() was called but before the firmware
      // processes SIM_START, which would incorrectly flip isSimulating back.

      // ── Queue for backend POST ─────────────────────────────────────────
      _postQueue.add(sample);
      if (_postQueue.length >= _kPostBatchSize) _flushPostQueue();

      _throttledNotify();
    } catch (_) {
      _consecutiveEcgParseFailures++;
      if (_consecutiveEcgParseFailures >= 5) _scheduleEcgRecovery();
    }
  }

  // ── Backend POST (batched, fire-and-forget) ─────────────────────────────
  void _flushPostQueue() {
    if (_postQueue.isEmpty) return;
    final batch = List<EcgSample>.from(_postQueue);
    _postQueue.clear();
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
    } catch (_) {}
  }

  // ── AI Classification Data Handler ──────────────────────────────────────
  void _onAiData(List<int> bytes) {
    try {
      final jsonStr = utf8.decode(bytes).trim();
      if (jsonStr.isEmpty) return;
      final map = json.decode(jsonStr) as Map<String, dynamic>;

      aiClass      = (map['class']      as String?) ?? '---';
      aiLabel      = (map['label']      as String?) ?? 'Unknown';
      aiConfidence = (map['confidence'] as num?)?.toDouble() ?? 0.0;

      if (map['probs'] != null) {
        final probList = map['probs'] as List<dynamic>;
        aiProbs = probList.map((p) => (p as num).toDouble()).toList();
        while (aiProbs.length < 5) aiProbs.add(0.0);
      }

      aiAvailable = true;
      _throttledNotify();
    } catch (_) {}
  }

  // ── Status Characteristic Handler ──────────────────────────────────────
  void _onStatusData(List<int> bytes) {
    try {
      final statusStr = utf8.decode(bytes).trim();
      if (statusStr.isEmpty) return;
      debugPrint("BLE Status: $statusStr");

      if (statusStr.startsWith("SIM_ON:")) {
        final condName = statusStr.substring(7);
        debugPrint("Simulation started: $condName");
        isSimulating = true;
        // Try to match condition name to ID
        for (final c in simConditions) {
          if (c.name.toLowerCase().contains(condName.toLowerCase()) ||
              condName.toLowerCase().contains(c.name.split(' ').first.toLowerCase())) {
            activeSimCondition = c.id;
            break;
          }
        }
        _throttledNotify();
      } else if (statusStr == "SIM_OFF") {
        debugPrint("Simulation stopped");
        isSimulating = false;
        activeSimCondition = -1;
        _throttledNotify();
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Simulation Control — Direct BLE Commands to Nano
  // ══════════════════════════════════════════════════════════════════════════

  /// Send a BLE command string to the Nano
  Future<void> _sendBleCommand(String cmd) async {
    if (_commandChar == null) {
      debugPrint("Command characteristic not available");
      return;
    }
    try {
      await _commandChar!.write(utf8.encode(cmd), withoutResponse: true);
    } catch (e) {
      debugPrint("Failed to send BLE command '$cmd': $e");
    }
  }

  /// Start simulation with a given condition (0-4)
  Future<void> startSimulation(int conditionId) async {
    isSimulating = true;
    activeSimCondition = conditionId;
    chartBuffer.clear();
    // Reset metrics for clean start
    bpm = 0;
    sdnn = 0.0;
    rmssd = 0.0;
    peakCount = 0;
    aiAvailable = false;
    aiClass = '---';
    aiLabel = 'Waiting';
    aiConfidence = 0.0;
    bleStatusMessage = "Sim — ${simConditions[conditionId].name}";
    notifyListeners();
    await _sendBleCommand('SIM_START,$conditionId');
  }

  /// Stop simulation and return to live
  Future<void> stopSimulation() async {
    await _sendBleCommand('SIM_STOP');
    isSimulating = false;
    activeSimCondition = -1;
    chartBuffer.clear();
    bpm = 0;
    sdnn = 0.0;
    rmssd = 0.0;
    peakCount = 0;
    aiAvailable = false;
    aiClass = '---';
    aiLabel = 'Waiting';
    aiConfidence = 0.0;
    bleStatusMessage = "Live — ECG_Nano33";
    // Newer firmware (v4+) expects 'MODE_SIM,<id>' which is forwarded
    // to the ESP32 bridge. Use that form to be compatible with recent builds.
    await _sendBleCommand('MODE_SIM,$conditionId');
  }

  // ── SD Recording control ────────────────────────────────────────────────

  Future<void> startSdRecording(String filename) async {
    if (_commandChar == null) {
      debugPrint("Command characteristic not available");
      return;
    }
    final cmd = "START,$filename";
    isRecording = true;
    recordingFilename = filename;
    isStoppingRecording = false;
    notifyListeners();
    try {
      await _commandChar!.write(utf8.encode(cmd), withoutResponse: true);
      await pauseLiveEcg();
    } catch (e) {
      debugPrint("Failed to send START command: $e");
      isRecording = false;
      recordingFilename = "";
      await resumeLiveEcg();
      notifyListeners();
    }
  }

  Future<void> stopSdRecording() async {
    if (_commandChar == null) return;
    if (isStoppingRecording) return;
    isStoppingRecording = true;
    notifyListeners();

    isRecording = false;
    recordingFilename = "";

    try {
      Object? lastErr;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          await _commandChar!.write(utf8.encode("STOP"), withoutResponse: true);
          lastErr = null;
          break;
        } catch (e) {
          lastErr = e;
          await Future.delayed(Duration(milliseconds: 120 * (attempt + 1)));
        }
      }
      if (lastErr != null) {
        debugPrint("Failed to send STOP command after retries: $lastErr");
      }
    } catch (e) {
      debugPrint("Failed to send STOP command: $e");
    } finally {
      await resumeLiveEcg();
      isStoppingRecording = false;
      notifyListeners();
    }
        // Legacy: SIM_ON:<name> / SIM_OFF
        if (statusStr.startsWith("SIM_ON:")) {
          final condName = statusStr.substring(7);
          debugPrint("Simulation started: $condName");
          isSimulating = true;
          // Try to match condition name to ID
          for (final c in simConditions) {
            if (c.name.toLowerCase().contains(condName.toLowerCase()) ||
                condName.toLowerCase().contains(c.name.split(' ').first.toLowerCase())) {
              activeSimCondition = c.id;
              break;
            }
          }
          _throttledNotify();
        } else if (statusStr == "SIM_OFF") {
          debugPrint("Simulation stopped");
          isSimulating = false;
          activeSimCondition = -1;
          _throttledNotify();
        // Newer firmware (v4+) reports MODE_* messages when switching modes
        } else if (statusStr == "MODE_SIMULATION") {
          debugPrint("Mode: SIMULATION");
          isSimulating = true;
          _throttledNotify();
        } else if (statusStr == "MODE_LIVE") {
          debugPrint("Mode: LIVE");
          isSimulating = false;
          activeSimCondition = -1;
          bleStatusMessage = "Live — ECG_Nano33";
          _throttledNotify();
        } else if (statusStr == "MODE_REPLAY") {
          debugPrint("Mode: REPLAY");
          isSimulating = false;
          activeSimCondition = -1;
          _throttledNotify();
  Future<void> resumeLiveEcg() async {
    if (!_livePaused) return;
    if (bleState != BleConnectionState.connected) {
      _livePaused = false;
      return;
    }
    _livePaused = false;

    if (_ecgChar == null) return;

    _notifySub?.cancel();
    _notifySub = _ecgChar!.onValueReceived.listen(
      _onEcgData,
      onError: (_) => _scheduleEcgRecovery(),
      onDone: _scheduleEcgRecovery,
      cancelOnError: false,
    );

    bool notificationsWorking = false;
    try {
      await _ecgChar!.setNotifyValue(true).timeout(const Duration(seconds: 6));
      notificationsWorking = true;
    } catch (_) {}

    if (!notificationsWorking) {
      _usingPolling = true;
      _startPolling(_ecgChar!);
    } else {
      _usingPolling = false;
    }

    _startEcgWatchdog();
    _throttledNotify();
  }

  void _startEcgWatchdog() {
    _ecgWatchdog?.cancel();
    _ecgWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (bleState != BleConnectionState.connected) return;
      if (_livePaused || isRecording) return;

      final age = DateTime.now().difference(_lastEcgPacketAt);
      if (age >= _kFreezeTimeout) {
        _scheduleEcgRecovery();
      }
    });
  }

  bool _recovering = false;
  void _scheduleEcgRecovery() {
    if (_recovering) return;
    if (bleState != BleConnectionState.connected) return;
    if (_livePaused || isRecording) return;
    _recovering = true;

    Future<void>(() async {
      try {
        if (_ecgChar == null) return;

        if (_usingPolling) {
          _polling = false;
          await Future.delayed(const Duration(milliseconds: 50));
          _startPolling(_ecgChar!);
        } else {
          try { await _ecgChar!.setNotifyValue(false); } catch (_) {}
          _notifySub?.cancel();
          _notifySub = _ecgChar!.onValueReceived.listen(
            _onEcgData,
            onError: (_) => _scheduleEcgRecovery(),
            onDone: _scheduleEcgRecovery,
            cancelOnError: false,
          );
          try {
            await _ecgChar!.setNotifyValue(true).timeout(const Duration(seconds: 6));
          } catch (_) {
            _usingPolling = true;
            _startPolling(_ecgChar!);
          }
        }
      } finally {
        _lastEcgPacketAt = DateTime.now();
        _recovering = false;
      }
    });
  }

  void _handleDisconnect() {
    _notifySub?.cancel();
    _aiNotifySub?.cancel();
    _statusNotifySub?.cancel();
    _connStateSub?.cancel();
    _ecgWatchdog?.cancel();
    _polling = false;
    _ecgRxBuffer.clear();
    _consecutiveEcgParseFailures = 0;
    _ecgChar = null;
    _commandChar = null;
    _aiChar = null;
    _statusChar = null;
    isRecording = false;
    recordingFilename = "";
    isStoppingRecording = false;
    aiAvailable = false;
    isDisconnecting = false;
    _livePaused = false;
    _usingPolling = false;
    _recovering = false;
    // Reset sim state on disconnect
    isSimulating = false;
    activeSimCondition = -1;
    bleState = BleConnectionState.disconnected;
    bleStatusMessage = _userInitiatedDisconnect
        ? "Disconnected"
        : "Disconnected. Reconnecting…";
    notifyListeners();

    if (!_userInitiatedDisconnect) {
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() async {
    if (isDisconnecting) return;
    isDisconnecting = true;
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _polling = false;

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

  void _scheduleReconnect() {
    if (bleState == BleConnectionState.connected ||
        bleState == BleConnectionState.scanning ||
        bleState == BleConnectionState.connecting) {
      return;
    }
    if (_userInitiatedDisconnect) return;
    if (_reconnectAttempt >= _kMaxReconnectAttempt) {
      bleStatusMessage = "Disconnected. Tap to reconnect.";
      notifyListeners();
      return;
    }

    _reconnectTimer?.cancel();
    final backoffMs = (500 * (1 << _reconnectAttempt)).clamp(500, 8000);
    _reconnectTimer = Timer(Duration(milliseconds: backoffMs), () async {
      if (_userInitiatedDisconnect) return;
      _reconnectAttempt++;

      final dev = _device;
      if (dev != null) {
        try {
          bleState = BleConnectionState.connecting;
          bleStatusMessage = "Reconnecting…";
          notifyListeners();
          await dev.connect(autoConnect: false, timeout: const Duration(seconds: 10));
          await _discoverAndSubscribe(dev);
          return;
        } catch (_) {}
      }

      await startScan();
    });
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _aiNotifySub?.cancel();
    _statusNotifySub?.cancel();
    _connStateSub?.cancel();
    _scanSub?.cancel();
    _postTimer?.cancel();
    _ecgWatchdog?.cancel();
    _reconnectTimer?.cancel();
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
