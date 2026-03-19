import 'package:flutter/foundation.dart';
import 'package:fl_chart/fl_chart.dart';

class SimulatorProvider extends ChangeNotifier {
  // Condition selection
  int selectedCondition = 0;         // 0=Normal 1=SVE 2=VE 3=Fusion 4=Unknown

  // Sim state — set to true only after firmware confirms via statusCharacteristic "SIM_ON:..."
  bool simRunning = false;

  // ECG ring buffer — keep last 640 points (5 seconds at 128 Hz)
  final List<FlSpot> ecgPoints = [];
  int _sampleIndex = 0;
  // Track which sample indices are R-peaks for chart markers
  final Set<int> peakIndices = {};

  // Vitals
  int heartRate = 0;
  int rrMs = 0;

  // AI result
  String aiClass = '---';
  String aiLabel = '---';
  double aiConfidence = 0.0;
  List<double> aiProbs = [0, 0, 0, 0, 0];

  // Override
  bool overrideEnabled = false;

  // Expected class per condition — indexed same as selectedCondition
  static const List<String> expectedClasses = ['N', 'S', 'V', 'F', 'Q'];
  static const List<String> expectedLabels  = ['Normal','SupraVE','VentricE','Fusion','Unknown'];
  // BLE commands sent for each condition index
  static const List<String> bleCommands = ['Normal','Tachycardia','PVC','Bradycardia','AFib'];

  String get expectedClass => expectedClasses[selectedCondition];
  String get expectedLabel => expectedLabels[selectedCondition];

  // Called by UI to add incoming ECG samples
  void addEcgSample(double value, bool isPeak) {
    ecgPoints.add(FlSpot(_sampleIndex.toDouble(), value));
    if (isPeak) peakIndices.add(_sampleIndex);
    _sampleIndex++;
    if (ecgPoints.length > 640) {
      final removed = ecgPoints.removeAt(0);
      peakIndices.remove(removed.x.toInt());
    }
    notifyListeners();
  }

  void updateAi(String cls, String label, double conf, List<double> probs) {
    aiClass = cls; aiLabel = label; aiConfidence = conf; aiProbs = probs;
    notifyListeners();
  }

  void updateVitals(int hr, int rr) {
    heartRate = hr; rrMs = rr; notifyListeners();
  }

  void setCondition(int index) {
    selectedCondition = index;
    overrideEnabled = false;
    notifyListeners();
  }

  void setSimRunning(bool val) {
    simRunning = val;
    if (!val) { ecgPoints.clear(); peakIndices.clear(); _sampleIndex = 0; }
    notifyListeners();
  }

  void toggleOverride() {
    overrideEnabled = !overrideEnabled;
    notifyListeners();
  }
}
