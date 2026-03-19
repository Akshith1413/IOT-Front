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
const int    _kMaxChartPoints  = 512; // ~4 sec with interpolation (4 points per poll)
const int    _kHrvWindowSize   = 60;  // last N R-R intervals for HRV

class EcgProvider extends ChangeNotifier {
  // ── BLE state ──────────────────────────────────────────────────────────
  BluetoothDevice? _device;
  BluetoothCharacteristic? _ecgChar;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _aiChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<List<int>>? _aiNotifySub;
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
  // Using ListQueue for O(1) add/remove
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

  // ── SD Recording state ─────────────────────────────────────────────────
  bool   isRecording     = false;
  String recordingFilename = "";
  bool   isStoppingRecording = false;

  // ── Disconnect guard ────────────────────────────────────────────────────
  bool isDisconnecting = false;



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
      Future.delayed(Duration(milliseconds: _kMinNotifyIntervalMs - elapsed), () {
        _notifyScheduled = false;
        _lastNotify = DateTime.now();
        notifyListeners();
      });
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
    _userInitiatedDisconnect = false;
    bleState = BleConnectionState.connecting;
    bleStatusMessage = "Connecting…";
    notifyListeners();

    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
    } catch (e) {
      bleState = BleConnectionState.error;
      bleStatusMessage = "Couldn’t connect. Tap to retry.";
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

    // connection completed
  }

  

  Future<void> _discoverAndSubscribe(BluetoothDevice device) async {
    // Keep showing the generic connecting message while discovering
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

    // DEBUG: print found services to console
    debugPrint("Found ${services.length} services...");
    await Future.delayed(const Duration(milliseconds: 500)); // Brief pause

    for (final service in services) {
      debugPrint("Checking service: ${service.uuid.toString().substring(0, 8)}...");
      await Future.delayed(const Duration(milliseconds: 300)); // Visual delay

      if (service.uuid.toString().toUpperCase() ==
          _kServiceUuid.toUpperCase()) {
        debugPrint("Service matched! Checking chars...");
        

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
              _kAiCharUuid.toUpperCase()) {
            _aiChar = char;
            debugPrint("AI characteristic found!");
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
    // Show a minimal error message if services/characteristics weren't found
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

  // ── RX framing (newline-delimited JSON) ────────────────────────────────
  final List<int> _ecgRxBuffer = <int>[];
  int _consecutiveEcgParseFailures = 0;
  static const int _kMaxRxBufferBytes = 16 * 1024;

  // ── Called for every BLE notification or poll read ─────────────────────
  void _onEcgData(List<int> bytes) {
    // Many BLE stacks can split/merge packets. Parse a rolling byte buffer
    // and extract full JSON objects either newline-delimited or concatenated.
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
      // Drop any leading noise before a JSON object starts.
      final start = _ecgRxBuffer.indexOf(123); // '{'
      if (start == -1) {
        // No JSON start found; keep buffer small.
        if (_ecgRxBuffer.length > 1024) _ecgRxBuffer.clear();
        break;
      }
      if (start > 0) {
        _ecgRxBuffer.removeRange(0, start);
      }

      // Fast path: newline-delimited JSON.
      final nl = _ecgRxBuffer.indexOf(10); // '\n'
      if (nl != -1) {
        final frameBytes = _ecgRxBuffer.sublist(0, nl);
        _ecgRxBuffer.removeRange(0, nl + 1);
        _tryProcessEcgFrame(frameBytes);
        continue;
      }

      // Delimiter-free path: scan for a complete JSON object by brace matching.
      int depth = 0;
      bool inString = false;
      bool escape = false;
      int end = -1;
      for (int i = 0; i < _ecgRxBuffer.length; i++) {
        final b = _ecgRxBuffer[i];
        if (escape) {
          escape = false;
          continue;
        }
        if (b == 92) { // '\'
          if (inString) escape = true;
          continue;
        }
        if (b == 34) { // '"'
          inString = !inString;
          continue;
        }
        if (inString) continue;

        if (b == 123) {
          depth++;
        } else if (b == 125) {
          depth--;
          if (depth == 0) {
            end = i;
            break;
          }
        }
      }

      if (end == -1) {
        // No full object yet; wait for more bytes.
        break;
      }

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

      // ── Interpolation: insert points between samples for density ───────
      // NO smoothing applied — preserves sharp QRS peaks
      // Catmull-Rom spline in chart handles visual smoothness
      // Only update the live waveform while NOT recording to avoid chart activity
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
            if (chartBuffer.length > _kMaxChartPoints) {
              chartBuffer.removeFirst();
            }
          }
        }
        // 1. Update waveform chart buffer (raw value, no smoothing)
        chartBuffer.addLast(sample);
        if (chartBuffer.length > _kMaxChartPoints) {
          chartBuffer.removeFirst();
        }
      }
      // Keep last raw value up-to-date for interpolation when charting resumes
      _lastRawValue = rawVal;

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
      _consecutiveEcgParseFailures++;
      if (_consecutiveEcgParseFailures >= 5) {
        _scheduleEcgRecovery();
      }
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
      await http.post(
        Uri.parse(_kBackendUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(sample.toJson()),
      ).timeout(const Duration(seconds: 5));
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

      aiClass      = (map['class']      as String?) ?? '---';
      aiLabel      = (map['label']      as String?) ?? 'Unknown';
      aiConfidence = (map['confidence'] as num?)?.toDouble() ?? 0.0;

      if (map['probs'] != null) {
        final probList = map['probs'] as List<dynamic>;
        aiProbs = probList.map((p) => (p as num).toDouble()).toList();
        // Pad to 5 if needed
        while (aiProbs.length < 5) {
          aiProbs.add(0.0);
        }
      }

      aiAvailable = true;
      _throttledNotify();
    } catch (_) {
      // Silently drop malformed AI packets
    }
  }

  // ── SD Recording control ────────────────────────────────────────────────

  Future<void> startSdRecording(String filename) async {
    if (_commandChar == null) {
      debugPrint("Command characteristic not available");
      return;
    }
    final cmd = "START,$filename";
    // Optimistically set recording state so UI can update immediately
    isRecording = true;
    recordingFilename = filename;
    isStoppingRecording = false;
    notifyListeners();
    try {
      // Send START first; pausing notifications before this can block START.
      await _commandChar!.write(utf8.encode(cmd), withoutResponse: true);

      // Now pause the live stream so recording can run without streaming load.
      // If this fails, recording should still continue.
      await pauseLiveEcg();
    } catch (e) {
      // Roll back UI state if the command fails
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

    // Optimistically update UI so a single tap feels responsive.
    // We'll still try to deliver STOP reliably below.
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
      // Always attempt to resume live ECG after a stop attempt.
      await resumeLiveEcg();
      isStoppingRecording = false;
      notifyListeners();
    }
  }

  Future<void> pauseLiveEcg() async {
    if (_livePaused) return;
    if (bleState != BleConnectionState.connected) return;
    _livePaused = true;
    _polling = false;
    _usingPolling = false;

    try {
      await _ecgChar?.setNotifyValue(false);
    } catch (_) {}

    await _notifySub?.cancel();
    _notifySub = null;
    _throttledNotify();
  }

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

        // If we were polling, restart polling; otherwise, re-enable notify.
        if (_usingPolling) {
          _polling = false;
          await Future.delayed(const Duration(milliseconds: 50));
          _startPolling(_ecgChar!);
        } else {
          try {
            await _ecgChar!.setNotifyValue(false);
          } catch (_) {}
          _notifySub?.cancel();
          _notifySub = _ecgChar!.onValueReceived.listen(
            _onEcgData,
            onError: (_) => _scheduleEcgRecovery(),
            onDone: _scheduleEcgRecovery,
            cancelOnError: false,
          );
          try {
            await _ecgChar!.setNotifyValue(true)
                .timeout(const Duration(seconds: 6));
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
    _connStateSub?.cancel();
    _ecgWatchdog?.cancel();
    _polling = false;
    _ecgRxBuffer.clear();
    _consecutiveEcgParseFailures = 0;
    // Keep `_device` reference for auto-reconnect attempts.
    _ecgChar = null;
    _commandChar = null;
    _aiChar = null;
    isRecording = false;
    recordingFilename = "";
    isStoppingRecording = false;
    aiAvailable = false;
    isDisconnecting = false;
    _livePaused = false;
    _usingPolling = false;
    _recovering = false;
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
    if (isDisconnecting) return; // guard against double-tap
    isDisconnecting = true;
    _userInitiatedDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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

      // Prefer reconnecting to the last known device if we have it.
      final dev = _device;
      if (dev != null) {
        try {
          bleState = BleConnectionState.connecting;
          bleStatusMessage = "Reconnecting…";
          notifyListeners();
          await dev.connect(autoConnect: false, timeout: const Duration(seconds: 10));
          await _discoverAndSubscribe(dev);
          return;
        } catch (_) {
          // fall through to scanning
        }
      }

      await startScan();
    });
  }


  @override
  void dispose() {
    _notifySub?.cancel();
    _aiNotifySub?.cancel();
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
