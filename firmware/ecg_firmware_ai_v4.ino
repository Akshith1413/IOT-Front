// ═══════════════════════════════════════════════════════════════════════════════
//  ECG Firmware v4 — Live + Simulation + Replay Mode (ESP32 Bridge)
//  Arduino Nano 33 BLE + MAX30003 + TFLite Micro + ESP32 UART
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Changes from v3:
//    • NEW: Three operating modes — Live, Simulation, Replay
//    • NEW: UART bridge to ESP32 (Serial1: TX=1, RX=0) for sim/replay data
//    • NEW: BLE commands for mode switching forwarded to ESP32
//    • UNCHANGED: All signal processing (filtering, peak detection, HRV, AI)
//    • UNCHANGED: ECG register config, BLE service UUIDs, SD card recording
//
//  Modes:
//    LIVE       — ECG from MAX30003 (default, same as v3)
//    SIMULATION — ECG from ESP32 synthetic generator
//    REPLAY     — ECG from ESP32 dataset streamer
//
//  In Simulation/Replay modes, the Nano receives "ECG:<value>" lines from the
//  ESP32 over Serial1 and feeds them into the SAME processing pipeline
//  (median filter → moving average → baseline removal → peak detection → AI).
//
//  BLE Commands (new):
//    MODE_LIVE           — Switch to live MAX30003 mode
//    MODE_SIM,<class>    — Switch to simulation mode for class (N/S/V/F/Q)
//    MODE_REPLAY,<id>    — Switch to replay mode for dataset <id>
//    SIM_STOP            — Stop simulation, return to live
//    REPLAY_STOP         — Stop replay, return to live
//    REPLAY_LIST         — Request dataset list from ESP32
//    PING_ESP            — Ping ESP32 for connectivity check
//
//  All existing commands (START,<filename>, STOP) still work unchanged.
//
//  Model input:  [1, 1, 256] — 256 samples at 128 Hz (~2 seconds)
//  Model output: [1, 5]      — logits for each class
// ═══════════════════════════════════════════════════════════════════════════════

#include <SPI.h>
#include <SD.h>
#include "protocentral_max30003.h"
#include <ArduinoBLE.h>

// ── TensorFlow Lite Micro ────────────────────────────────────────────────────
#include <Chirale_TensorFlowLite.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"

// ── Model data (float32 TFLite, const → lives in flash) ─────────────────────
#include "model_data_32.h"

// ─── Pin Definitions ─────────────────────────────────────────────────────────
#define MAX30003_CS_PIN 10
#define SD_CS_PIN       9

MAX30003 max30003(MAX30003_CS_PIN);

// ─── DEBUG MODE ──────────────────────────────────────────────────────────────
#define DEBUG_MODE false

// ─── ESP32 Serial Bridge ─────────────────────────────────────────────────────
// Nano 33 BLE Serial1: TX = Pin 1, RX = Pin 0
// Connect: Nano TX(1) → ESP32 RX(16), Nano RX(0) → ESP32 TX(17), GND → GND
#define ESP32_SERIAL Serial1
#define ESP32_BAUD   115200

// ═══════════════════════════════════════════════════════════════════════════════
//  Operating Mode
// ═══════════════════════════════════════════════════════════════════════════════

enum OperatingMode {
  OP_MODE_LIVE,       // ECG from MAX30003
  OP_MODE_SIMULATION, // ECG from ESP32 synthetic generator
  OP_MODE_REPLAY      // ECG from ESP32 dataset replay
};

OperatingMode operatingMode = OP_MODE_LIVE;

// ESP32 serial receive buffer
String esp32RxBuffer = "";
int32_t esp32EcgValue = 0;
bool    esp32SampleReady = false;

// Forward ESP32 status/dataset responses to Flutter via BLE
// (stored until BLE can send)
String esp32PendingResponse = "";

// ═══════════════════════════════════════════════════════════════════════════════
//  BLE Service & Characteristics (UNCHANGED UUIDs)
// ═══════════════════════════════════════════════════════════════════════════════

BLEService ecgService("12345678-1234-1234-1234-123456789ABC");

BLEStringCharacteristic ecgCharacteristic(
  "12345678-1234-1234-1234-123456789ABD",
  BLERead | BLENotify,
  200
);

BLEStringCharacteristic statusCharacteristic(
  "12345678-1234-1234-1234-123456789ABE",
  BLERead | BLENotify,
  128   // Increased from 32 to hold dataset lists
);

BLEStringCharacteristic commandCharacteristic(
  "12345678-1234-1234-1234-123456789ABF",
  BLEWrite | BLEWriteWithoutResponse,
  128
);

BLEStringCharacteristic aiCharacteristic(
  "12345678-1234-1234-1234-123456789AC0",
  BLERead | BLENotify,
  128
);

// ═══════════════════════════════════════════════════════════════════════════════
//  Signal Processing Filters (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

#define FILTER_SIZE 5
#define MEDIAN_SIZE 5

int32_t filterBuffer[FILTER_SIZE];
int filterIndex = 0;

int32_t medianBuffer[MEDIAN_SIZE];
int medianIndex = 0;

int32_t baseline      = 0;
float   baselineAlpha = 0.001;

// ═══════════════════════════════════════════════════════════════════════════════
//  Software Peak Detection & Heart Rate (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

int32_t       peakThreshold     = 50;
float         adaptiveMax       = 50.0f;
float         adaptiveAlpha     = 0.01f;
float         thresholdFraction = 0.40f;

unsigned long lastPeakTime      = 0;
unsigned long peakInterval      = 0;
bool          peakDetected      = false;
bool          beatPending       = false;

int           heartRate       = 0;
float         smoothedHR      = 72.0f;
float         hrAlpha         = 0.2f;
#define       HR_MIN          40
#define       HR_MAX          180

// ═══════════════════════════════════════════════════════════════════════════════
//  RR Interval + HRV (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

#define RR_BUFFER_SIZE      20
#define RR_MIN_COUNT        5
#define HRV_SMOOTH_ALPHA    0.3f

unsigned long rrBuffer[RR_BUFFER_SIZE];
int           rrBufferIndex = 0;
int           rrBufferCount = 0;

int           lastRRms      = 0;
float         sdnnValue     = 0.0f;
float         rmssdValue    = 0.0f;
float         rawSdnn       = 0.0f;
float         rawRmssd      = 0.0f;
bool          hrvReady      = false;

void computeHRV() {
  if (rrBufferCount < RR_MIN_COUNT) {
    hrvReady   = false;
    sdnnValue  = 0.0f;
    rmssdValue = 0.0f;
    return;
  }

  hrvReady = true;
  int n = rrBufferCount;

  float intervals[RR_BUFFER_SIZE];
  for (int i = 0; i < n; i++) {
    int idx = (rrBufferIndex - n + i + RR_BUFFER_SIZE) % RR_BUFFER_SIZE;
    intervals[i] = (float)rrBuffer[idx];
  }

  float mean = 0.0f;
  for (int i = 0; i < n; i++) mean += intervals[i];
  mean /= (float)n;

  float variance = 0.0f;
  for (int i = 0; i < n; i++) {
    float diff = intervals[i] - mean;
    variance += diff * diff;
  }
  rawSdnn = sqrtf(variance / (float)n);

  float sumSqDiff = 0.0f;
  for (int i = 1; i < n; i++) {
    float diff = intervals[i] - intervals[i - 1];
    sumSqDiff += diff * diff;
  }
  rawRmssd = sqrtf(sumSqDiff / (float)(n - 1));

  if (sdnnValue < 0.01f && rmssdValue < 0.01f) {
    sdnnValue  = rawSdnn;
    rmssdValue = rawRmssd;
  } else {
    sdnnValue  = sdnnValue  * (1.0f - HRV_SMOOTH_ALPHA) + rawSdnn  * HRV_SMOOTH_ALPHA;
    rmssdValue = rmssdValue * (1.0f - HRV_SMOOTH_ALPHA) + rawRmssd * HRV_SMOOTH_ALPHA;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BLE State
// ═══════════════════════════════════════════════════════════════════════════════

bool bleConnected = false;

#define BLE_SEND_EVERY_N_SAMPLES 4
int bleSampleCounter = 0;

// ═══════════════════════════════════════════════════════════════════════════════
//  SD Card Recording State (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

bool sdAvailable  = false;
bool isRecording  = false;
File dataFile;
char recordingFilename[64];
unsigned long recordingSampleCount = 0;

// ═══════════════════════════════════════════════════════════════════════════════
//  Timestamp
// ═══════════════════════════════════════════════════════════════════════════════

unsigned long bootEpochMs = 0;

// ═══════════════════════════════════════════════════════════════════════════════
//  TFLite Micro — Arrhythmia Detection Engine (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

#define AI_INPUT_SIZE   256
#define AI_NUM_CLASSES  5

static const char* AI_CLASS_LABELS[AI_NUM_CLASSES] = {
  "Normal", "SupraVE", "VentricE", "Fusion", "Unknown"
};

static const char* AI_CLASS_SHORT[AI_NUM_CLASSES] = {
  "N", "S", "V", "F", "Q"
};

float aiInputBuffer[AI_INPUT_SIZE];
int   aiBufferIndex = 0;
bool  aiBufferFull  = false;

#define AI_INFERENCE_INTERVAL_MS 3000
unsigned long lastInferenceTime = 0;

int   lastAiClass      = -1;
float lastAiConfidence = 0.0f;
char  lastAiLabel[16]  = "---";

// ═══════════════════════════════════════════════════════════════════════════════
//  AI Robustness: Logit Bias + Confidence Gate + Majority Voting (UNCHANGED)
// ═══════════════════════════════════════════════════════════════════════════════

#define AI_NORMAL_LOGIT_BIAS      3.5f
#define AI_CONFIDENCE_THRESHOLD   0.85f
#define AI_VOTE_BUFFER_SIZE       5

int aiVoteBuffer[AI_VOTE_BUFFER_SIZE];
int aiVoteIndex = 0;
int aiVoteCount = 0;

int getAiMajorityClass() {
  if (aiVoteCount == 0) return 0;

  int counts[AI_NUM_CLASSES] = {0};
  int n = min(aiVoteCount, AI_VOTE_BUFFER_SIZE);
  for (int i = 0; i < n; i++) {
    int idx = (aiVoteIndex - n + i + AI_VOTE_BUFFER_SIZE) % AI_VOTE_BUFFER_SIZE;
    int cls = aiVoteBuffer[idx];
    if (cls >= 0 && cls < AI_NUM_CLASSES) {
      counts[cls]++;
    }
  }

  int bestClass = 0;
  int bestCount = counts[0];
  for (int i = 1; i < AI_NUM_CLASSES; i++) {
    if (counts[i] > bestCount) {
      bestCount = counts[i];
      bestClass = i;
    }
  }
  return bestClass;
}

// TFLite Micro objects
constexpr int kTensorArenaSize = 64 * 1024;
alignas(16) uint8_t tensorArena[kTensorArenaSize];

const tflite::Model* tfModel         = nullptr;
tflite::MicroInterpreter* interpreter = nullptr;
TfLiteTensor* inputTensor             = nullptr;
TfLiteTensor* outputTensor            = nullptr;

// ─── Initialize TFLite Micro (UNCHANGED) ─────────────────────────────────────
bool initTFLite() {
  tfModel = tflite::GetModel(ecg_model_float32_tflite);
  if (tfModel->version() != TFLITE_SCHEMA_VERSION) {
    debugPrint("ERROR: Model schema version mismatch!");
    return false;
  }

  static tflite::AllOpsResolver resolver;

  static tflite::MicroInterpreter static_interpreter(
    tfModel, resolver, tensorArena, kTensorArenaSize
  );
  interpreter = &static_interpreter;

  TfLiteStatus allocate_status = interpreter->AllocateTensors();
  if (allocate_status != kTfLiteOk) {
    debugPrint("ERROR: AllocateTensors() failed!");
    interpreter = nullptr;
    return false;
  }

  inputTensor  = interpreter->input(0);
  outputTensor = interpreter->output(0);

  if (inputTensor == nullptr || outputTensor == nullptr) {
    debugPrint("ERROR: Input/Output tensors are null!");
    interpreter = nullptr;
    return false;
  }

  if (DEBUG_MODE) {
    Serial.print("[AI] Input dims: ");
    for (int i = 0; i < inputTensor->dims->size; i++) {
      Serial.print(inputTensor->dims->data[i]);
      Serial.print(" ");
    }
    Serial.println();

    Serial.print("[AI] Output dims: ");
    for (int i = 0; i < outputTensor->dims->size; i++) {
      Serial.print(outputTensor->dims->data[i]);
      Serial.print(" ");
    }
    Serial.println();

    Serial.print("[AI] Arena used: ");
    Serial.print(interpreter->arena_used_bytes());
    Serial.println(" bytes");
  }

  debugPrint("[AI] TFLite Micro initialized OK");
  return true;
}

// ─── Run inference (UNCHANGED) ───────────────────────────────────────────────
void runInference() {
  if (interpreter == nullptr || inputTensor == nullptr || outputTensor == nullptr) return;

  unsigned long now = millis();
  if (now - lastInferenceTime < AI_INFERENCE_INTERVAL_MS) return;
  lastInferenceTime = now;

  // Z-score normalize
  float mean = 0.0f;
  for (int i = 0; i < AI_INPUT_SIZE; i++) mean += aiInputBuffer[i];
  mean /= (float)AI_INPUT_SIZE;

  float variance = 0.0f;
  for (int i = 0; i < AI_INPUT_SIZE; i++) {
    float diff = aiInputBuffer[i] - mean;
    variance += diff * diff;
  }
  float stddev = sqrtf(variance / (float)AI_INPUT_SIZE) + 1e-8f;

  for (int i = 0; i < AI_INPUT_SIZE; i++) {
    inputTensor->data.f[i] = (aiInputBuffer[i] - mean) / stddev;
  }

  unsigned long inferStart = micros();
  TfLiteStatus invoke_status = interpreter->Invoke();
  unsigned long inferTime = micros() - inferStart;

  if (invoke_status != kTfLiteOk) {
    debugPrint("[AI] Inference FAILED");
    return;
  }

  float logits[AI_NUM_CLASSES];
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    logits[i] = outputTensor->data.f[i];
  }

  // LAYER 1: Logit bias
  // In simulation/replay mode, disable the normal logit bias since the
  // synthetic data matches MIT-BIH distribution (no hardware mismatch)
  if (operatingMode == OP_MODE_LIVE) {
    logits[0] += AI_NORMAL_LOGIT_BIAS;
  }

  // Softmax
  float maxLogit = logits[0];
  for (int i = 1; i < AI_NUM_CLASSES; i++) {
    if (logits[i] > maxLogit) maxLogit = logits[i];
  }

  float probs[AI_NUM_CLASSES];
  float sumExp = 0.0f;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    probs[i] = exp(logits[i] - maxLogit);
    sumExp += probs[i];
  }
  if (sumExp <= 0.0f || isnan(sumExp)) sumExp = 1.0f;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    probs[i] /= sumExp;
    if (probs[i] > 1.0f) probs[i] = 1.0f;
    if (probs[i] < 0.0f) probs[i] = 0.0f;
  }

  float maxProb = -1.0f;
  int   maxIdx  = 0;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    if (probs[i] > maxProb) {
      maxProb = probs[i];
      maxIdx  = i;
    }
  }

  // LAYER 2: Confidence gate (only in live mode)
  int reportedClass = maxIdx;
  if (operatingMode == OP_MODE_LIVE) {
    if (maxIdx != 0 && maxProb < AI_CONFIDENCE_THRESHOLD) {
      reportedClass = 0;
    }
  }

  // LAYER 3: Majority voting
  aiVoteBuffer[aiVoteIndex] = reportedClass;
  aiVoteIndex = (aiVoteIndex + 1) % AI_VOTE_BUFFER_SIZE;
  if (aiVoteCount < AI_VOTE_BUFFER_SIZE) aiVoteCount++;

  int finalClass = getAiMajorityClass();

  lastAiClass      = finalClass;
  lastAiConfidence = probs[finalClass];
  strncpy(lastAiLabel, AI_CLASS_SHORT[finalClass], sizeof(lastAiLabel));

  if (DEBUG_MODE) {
    Serial.print("[AI] Probs: ");
    for (int i = 0; i < AI_NUM_CLASSES; i++) {
      Serial.print(AI_CLASS_SHORT[i]);
      Serial.print("=");
      Serial.print(probs[i] * 100.0f, 1);
      Serial.print("% ");
    }
    Serial.print(" → ");
    Serial.println(AI_CLASS_LABELS[finalClass]);
  }

  // Send AI result over BLE
  if (bleConnected) {
    // Include mode info in AI response — use same short code as ECG JSON
    const char* modeCode = "L";
    if (operatingMode == OP_MODE_SIMULATION) modeCode = "S";
    else if (operatingMode == OP_MODE_REPLAY) modeCode = "R";

    char aiJson[128];
    snprintf(aiJson, sizeof(aiJson),
      "{\"class\":\"%s\",\"label\":\"%s\",\"confidence\":%.2f,\"probs\":[%.3f,%.3f,%.3f,%.3f,%.3f],\"m\":\"%s\"}",
      AI_CLASS_SHORT[finalClass],
      AI_CLASS_LABELS[finalClass],
      lastAiConfidence,
      probs[0], probs[1], probs[2], probs[3], probs[4],
      modeCode
    );
    aiCharacteristic.writeValue(aiJson);
  }
}


// ═══════════════════════════════════════════════════════════════════════════════
//  Helper Functions (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

void millisToISO8601(unsigned long ms, char* buf, size_t bufLen) {
  unsigned long epoch    = bootEpochMs + ms;
  unsigned long totalSec = epoch / 1000;
  unsigned long msRem    = epoch % 1000;
  unsigned long sec      = totalSec % 60;
  unsigned long min      = (totalSec / 60) % 60;
  unsigned long hour     = (totalSec / 3600) % 24;
  unsigned long days     = totalSec / 86400;

  int year = 1970;
  for (;;) {
    bool leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    int  diy  = leap ? 366 : 365;
    if ((int)days < diy) break;
    days -= diy;
    year++;
  }

  static const int dim[] = {31,28,31,30,31,30,31,31,30,31,30,31};
  int month = 1;
  for (;;) {
    bool leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    int  d    = dim[month - 1] + (month == 2 && leap ? 1 : 0);
    if ((int)days < d) break;
    days -= d;
    month++;
  }
  int day = (int)days + 1;

  snprintf(buf, bufLen,
    "%04d-%02d-%02dT%02lu:%02lu:%02lu.%03luZ",
    year, month, day, hour, min, sec, msRem);
}

void debugPrint(const char* msg) {
  if (DEBUG_MODE) Serial.println(msg);
}

void debugPrint(const String& msg) {
  if (DEBUG_MODE) Serial.println(msg);
}

// ─── SD Card Helpers (UNCHANGED) ─────────────────────────────────────────────

void initSDCard() {
  Serial.println("[SD] Initializing SD card...");
  digitalWrite(MAX30003_CS_PIN, HIGH);

  if (SD.begin(SD_CS_PIN)) {
    sdAvailable = true;
    Serial.println("[SD] OK - SD card ready.");
  } else {
    sdAvailable = false;
    Serial.println("[SD] FAILED - Check wiring/card format.");
  }

  digitalWrite(MAX30003_CS_PIN, LOW);
}

void startRecording(const char* filename) {
  if (!sdAvailable) {
    Serial.println("[SD] Cannot record: SD not available.");
    statusCharacteristic.writeValue("SD_ERROR");
    return;
  }
  if (isRecording) {
    debugPrint("Already recording. Stop first.");
    return;
  }

  snprintf(recordingFilename, sizeof(recordingFilename), "%s.csv", filename);

  digitalWrite(MAX30003_CS_PIN, HIGH);
  dataFile = SD.open(recordingFilename, FILE_WRITE);
  digitalWrite(MAX30003_CS_PIN, LOW);

  if (dataFile) {
    digitalWrite(MAX30003_CS_PIN, HIGH);
    dataFile.println("timestamp,ecg_raw,ecg_filtered,ecg_mv,heart_rate,rr_ms,beat,sdnn,rmssd,ai_class,ai_confidence,mode");
    dataFile.flush();
    digitalWrite(MAX30003_CS_PIN, LOW);

    isRecording = true;
    recordingSampleCount = 0;

    Serial.println("[SD] Recording: " + String(recordingFilename));
    statusCharacteristic.writeValue("REC_ON");
  } else {
    Serial.println("[SD] File open FAILED: " + String(recordingFilename));
    statusCharacteristic.writeValue("FILE_ERROR");
  }
}

void stopRecording() {
  if (!isRecording) return;

  digitalWrite(MAX30003_CS_PIN, HIGH);
  dataFile.flush();
  dataFile.close();
  digitalWrite(MAX30003_CS_PIN, LOW);

  isRecording = false;

  Serial.println("[SD] Stopped. Samples: " + String(recordingSampleCount));
  statusCharacteristic.writeValue("REC_OFF");
}

void writeToSD(const char* timestamp, int32_t rawValue, int32_t filtered,
               float ecgMv, int hr, int rrMs, const char* beat) {
  if (!isRecording) return;

  const char* modeStr = "live";
  if (operatingMode == OP_MODE_SIMULATION) modeStr = "sim";
  else if (operatingMode == OP_MODE_REPLAY) modeStr = "replay";

  digitalWrite(MAX30003_CS_PIN, HIGH);

  char line[220];
  snprintf(line, sizeof(line), "%s,%ld,%ld,%.6f,%d,%d,%s,%.1f,%.1f,%s,%.2f,%s",
    timestamp, (long)rawValue, (long)filtered, ecgMv, hr, rrMs, beat,
    sdnnValue, rmssdValue, lastAiLabel, lastAiConfidence, modeStr);
  dataFile.println(line);

  recordingSampleCount++;

  if (recordingSampleCount % 32 == 0) {
    dataFile.flush();
  }

  digitalWrite(MAX30003_CS_PIN, LOW);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ESP32 Serial Communication
// ═══════════════════════════════════════════════════════════════════════════════

// Send a command to the ESP32
void sendToESP32(const String& cmd) {
  ESP32_SERIAL.println(cmd);
  if (DEBUG_MODE) {
    Serial.println("[BRIDGE] Sent to ESP32: " + cmd);
  }
}

// Process incoming data from ESP32
void processESP32Data(const String& line) {
  if (line.startsWith("ECG:")) {
    // ECG sample from ESP32
    String valueStr = line.substring(4);
    esp32EcgValue = valueStr.toInt();
    esp32SampleReady = true;
    
  } else if (line.startsWith("STATUS:")) {
    // Status response from ESP32 — forward to Flutter via BLE
    String status = line.substring(7);
    if (bleConnected) {
      statusCharacteristic.writeValue(status.c_str());
    }
    if (DEBUG_MODE) {
      Serial.println("[BRIDGE] ESP32 status: " + status);
    }
    
  } else if (line.startsWith("DATASETS:")) {
    // Dataset list from ESP32 — forward to Flutter via BLE
    String datasets = line.substring(9);
    if (bleConnected) {
      statusCharacteristic.writeValue(("DATASETS:" + datasets).c_str());
    }
    if (DEBUG_MODE) {
      Serial.println("[BRIDGE] ESP32 datasets: " + datasets);
    }
    
  } else if (line == "PONG") {
    if (bleConnected) {
      statusCharacteristic.writeValue("ESP32_OK");
    }
    if (DEBUG_MODE) {
      Serial.println("[BRIDGE] ESP32 PONG received");
    }
  }
}

// Read from ESP32 serial (non-blocking, line-delimited)
void readESP32Serial() {
  while (ESP32_SERIAL.available()) {
    char c = ESP32_SERIAL.read();
    if (c == '\n' || c == '\r') {
      if (esp32RxBuffer.length() > 0) {
        processESP32Data(esp32RxBuffer);
        esp32RxBuffer = "";
      }
    } else {
      esp32RxBuffer += c;
      if (esp32RxBuffer.length() > 256) {
        esp32RxBuffer = "";  // Overflow protection
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Mode Switching — Reset pipeline state for clean transitions
// ═══════════════════════════════════════════════════════════════════════════════

void resetPipelineState() {
  // Reset filters
  for (int i = 0; i < FILTER_SIZE; i++) filterBuffer[i] = 0;
  for (int i = 0; i < MEDIAN_SIZE; i++) medianBuffer[i] = 0;
  filterIndex = 0;
  medianIndex = 0;
  baseline = 0;
  
  // Reset peak detection
  peakThreshold = 50;
  adaptiveMax = 50.0f;
  lastPeakTime = 0;
  peakInterval = 0;
  peakDetected = false;
  beatPending = false;
  heartRate = 0;
  smoothedHR = 72.0f;
  
  // Reset HRV
  for (int i = 0; i < RR_BUFFER_SIZE; i++) rrBuffer[i] = 0;
  rrBufferIndex = 0;
  rrBufferCount = 0;
  lastRRms = 0;
  sdnnValue = 0.0f;
  rmssdValue = 0.0f;
  hrvReady = false;
  
  // Reset AI
  for (int i = 0; i < AI_INPUT_SIZE; i++) aiInputBuffer[i] = 0.0f;
  aiBufferIndex = 0;
  aiBufferFull = false;
  lastInferenceTime = 0;
  for (int i = 0; i < AI_VOTE_BUFFER_SIZE; i++) aiVoteBuffer[i] = 0;
  aiVoteIndex = 0;
  aiVoteCount = 0;
  lastAiClass = -1;
  lastAiConfidence = 0.0f;
  strncpy(lastAiLabel, "---", sizeof(lastAiLabel));
}

void switchToMode(OperatingMode newMode) {
  if (newMode == operatingMode) return;
  
  // Stop any previous ESP32 activity
  if (operatingMode == OP_MODE_SIMULATION) {
    sendToESP32("SIM_STOP");
  } else if (operatingMode == OP_MODE_REPLAY) {
    sendToESP32("REPLAY_STOP");
  }
  
  operatingMode = newMode;
  resetPipelineState();
  esp32SampleReady = false;
  
  const char* modeStr = "LIVE";
  if (newMode == OP_MODE_SIMULATION) modeStr = "SIMULATION";
  else if (newMode == OP_MODE_REPLAY) modeStr = "REPLAY";
  
  if (bleConnected) {
    char modeMsg[32];
    snprintf(modeMsg, sizeof(modeMsg), "MODE_%s", modeStr);
    statusCharacteristic.writeValue(modeMsg);
  }
  
  Serial.print("[MODE] Switched to: ");
  Serial.println(modeStr);
}

// ─── BLE Command Handler (EXTENDED) ─────────────────────────────────────────
void handleBLECommand(const String& cmd) {
  debugPrint("BLE Command: " + cmd);

  // ── Existing commands ──
  if (cmd.startsWith("START,")) {
    String filename = cmd.substring(6);
    filename.trim();
    if (filename.length() == 0) filename = "ecg_data";
    filename.replace(" ", "_");
    if (filename.length() > 8) filename = filename.substring(0, 8);

    char fnBuf[16];
    filename.toCharArray(fnBuf, sizeof(fnBuf));
    startRecording(fnBuf);

  } else if (cmd.startsWith("STOP")) {
    stopRecording();

  // ── NEW: Mode switching commands ──
  } else if (cmd == "MODE_LIVE") {
    switchToMode(OP_MODE_LIVE);
    
  } else if (cmd.startsWith("MODE_SIM,")) {
    String classStr = cmd.substring(9);
    classStr.trim();
    switchToMode(OP_MODE_SIMULATION);
    // Forward to ESP32
    sendToESP32("SIM_START," + classStr);
    
  } else if (cmd.startsWith("MODE_REPLAY,")) {
    String idStr = cmd.substring(12);
    idStr.trim();
    switchToMode(OP_MODE_REPLAY);
    // Forward to ESP32
    sendToESP32("REPLAY_START," + idStr);
    
  } else if (cmd == "SIM_STOP") {
    sendToESP32("SIM_STOP");
    switchToMode(OP_MODE_LIVE);
    
  } else if (cmd == "REPLAY_STOP") {
    sendToESP32("REPLAY_STOP");
    switchToMode(OP_MODE_LIVE);
    
  } else if (cmd == "REPLAY_LIST") {
    sendToESP32("REPLAY_LIST");
    
  } else if (cmd == "PING_ESP") {
    sendToESP32("PING");

  } else {
    debugPrint("Unknown command: " + cmd);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Signal Processing (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

int32_t medianFilter(int32_t newValue) {
  medianBuffer[medianIndex] = newValue;
  medianIndex = (medianIndex + 1) % MEDIAN_SIZE;

  int32_t sorted[MEDIAN_SIZE];
  for (int i = 0; i < MEDIAN_SIZE; i++) sorted[i] = medianBuffer[i];

  for (int i = 0; i < MEDIAN_SIZE - 1; i++)
    for (int j = 0; j < MEDIAN_SIZE - i - 1; j++)
      if (sorted[j] > sorted[j + 1]) {
        int32_t t    = sorted[j];
        sorted[j]    = sorted[j + 1];
        sorted[j + 1] = t;
      }

  return sorted[MEDIAN_SIZE / 2];
}

int32_t movingAverage(int32_t newValue) {
  filterBuffer[filterIndex] = newValue;
  filterIndex = (filterIndex + 1) % FILTER_SIZE;

  int64_t sum = 0;
  for (int i = 0; i < FILTER_SIZE; i++) sum += filterBuffer[i];
  return (int32_t)(sum / FILTER_SIZE);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Software Peak Detection (UNCHANGED from v3)
// ═══════════════════════════════════════════════════════════════════════════════

void detectPeak(int32_t value) {
  unsigned long now = millis();

  float absVal = (float)abs(value);
  if (absVal > adaptiveMax) {
    adaptiveMax = absVal;
  } else {
    adaptiveMax = adaptiveMax * (1.0f - adaptiveAlpha) + absVal * adaptiveAlpha;
  }

  peakThreshold = (int32_t)(adaptiveMax * thresholdFraction);
  if (peakThreshold < 30) peakThreshold = 30;

  if (value > peakThreshold && !peakDetected) {
    unsigned long elapsed = now - lastPeakTime;

    if (elapsed > 300) {
      peakInterval = elapsed;
      lastPeakTime = now;

      if (peakInterval > 0) {
        int rawHR = 60000 / (int)peakInterval;

        if (rawHR >= HR_MIN && rawHR <= HR_MAX) {
          smoothedHR = smoothedHR * (1.0f - hrAlpha) + (float)rawHR * hrAlpha;
          heartRate = (int)(smoothedHR + 0.5f);

          lastRRms = (int)peakInterval;
          rrBuffer[rrBufferIndex] = peakInterval;
          rrBufferIndex = (rrBufferIndex + 1) % RR_BUFFER_SIZE;
          if (rrBufferCount < RR_BUFFER_SIZE) rrBufferCount++;

          computeHRV();
        }
      }
    }
    peakDetected = true;
    beatPending  = true;
  }

  if (value < peakThreshold / 2) {
    peakDetected = false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Send ECG data as JSON over BLE (EXTENDED with mode field)
// ═══════════════════════════════════════════════════════════════════════════════

void sendECGoverBLE(int32_t filteredValue, const char* timestamp, const char* beat) {
  float ecgFloat = (float)filteredValue / 65536.0f;
  if (ecgFloat >  3.0f) ecgFloat =  3.0f;
  if (ecgFloat < -3.0f) ecgFloat = -3.0f;

  float sendSdnn  = hrvReady ? sdnnValue  : 0.0f;
  float sendRmssd = hrvReady ? rmssdValue : 0.0f;

  // Mode short code: "L" = live, "S" = simulation, "R" = replay
  const char* modeCode = "L";
  if (operatingMode == OP_MODE_SIMULATION) modeCode = "S";
  else if (operatingMode == OP_MODE_REPLAY) modeCode = "R";

  // NOTE: Total payload MUST stay under 200 bytes (BLE characteristic limit).
  // Shortened keys: ts=timestamp, v=ecg_value, b=beat, m=mode
  char jsonBuffer[200];
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"ts\":\"%s\",\"v\":%.6f,\"b\":\"%s\",\"hr\":%d,\"rr\":%d,\"sdnn\":%.1f,\"rmssd\":%.1f,\"m\":\"%s\"}",
    timestamp, ecgFloat, beat, heartRate, lastRRms, sendSdnn, sendRmssd, modeCode
  );

  ecgCharacteristic.writeValue(jsonBuffer);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Setup
// ═══════════════════════════════════════════════════════════════════════════════

void setup() {
  Serial.begin(115200);
  delay(1000);

  // ── ESP32 Serial Init ─────────────────────────────────────────────────────
  ESP32_SERIAL.begin(ESP32_BAUD);
  Serial.println("[BRIDGE] ESP32 Serial1 initialized at 115200 baud");

  pinMode(MAX30003_CS_PIN, OUTPUT);
  pinMode(SD_CS_PIN, OUTPUT);
  digitalWrite(MAX30003_CS_PIN, HIGH);
  digitalWrite(SD_CS_PIN, HIGH);

  debugPrint("==========================================");
  debugPrint("  MAX30003 ECG + Software HR + AI v4");
  debugPrint("  Arduino Nano 33 BLE + ESP32 Bridge");
  debugPrint("==========================================");

  // ── BLE Init ──────────────────────────────────────────────────────────────
  if (!BLE.begin()) {
    debugPrint("ERROR: BLE init failed!");
    pinMode(LED_BUILTIN, OUTPUT);
    while (1) {
      digitalWrite(LED_BUILTIN, HIGH); delay(200);
      digitalWrite(LED_BUILTIN, LOW);  delay(200);
    }
  }
  debugPrint("BLE initialized");

  BLE.setLocalName("ECG_Nano33_AI");
  BLE.setAdvertisedService(ecgService);
  ecgService.addCharacteristic(ecgCharacteristic);
  ecgService.addCharacteristic(statusCharacteristic);
  ecgService.addCharacteristic(commandCharacteristic);
  ecgService.addCharacteristic(aiCharacteristic);
  BLE.addService(ecgService);

  ecgCharacteristic.writeValue("{}");
  statusCharacteristic.writeValue("WAITING");
  aiCharacteristic.writeValue("{}");
  BLE.advertise();

  debugPrint("Advertising as ECG_Nano33_AI");

  // ── SPI + MAX30003 Init ───────────────────────────────────────────────────
  SPI.begin();

  debugPrint("Initializing MAX30003...");

  bool ret = max30003.readDeviceID();
  if (ret) {
    Serial.println("MAX30003 read ID Success");
  } else {
    while (!ret) {
      ret = max30003.readDeviceID();
      Serial.println("Failed to read ID, please make sure all pins are connected");
      delay(5000);
    }
  }

  Serial.println("Initialising the chip ...");
  max30003.begin();

  // ── ECG register config (UNCHANGED) ───────────────────────────────────────
  max30003.writeRegister(REG_CNFG_GEN,   0x080004);
  max30003.writeRegister(REG_CNFG_CAL,   0x720000);
  max30003.writeRegister(REG_CNFG_EMUX,  0x0B0000);
  max30003.writeRegister(REG_CNFG_ECG,   0x805000);
  max30003.writeRegister(REG_SYNCH,      0x000000);

  debugPrint("MAX30003 ECG initialized (software peak detection)");

  // ── SD Card Init ──────────────────────────────────────────────────────────
  initSDCard();

  // ── TFLite Micro Init ─────────────────────────────────────────────────────
  debugPrint("[AI] Loading arrhythmia detection model...");
  if (!initTFLite()) {
    debugPrint("[AI] WARNING: AI model failed to load! Running without AI.");
  } else {
    debugPrint("[AI] Model loaded. Ready for inference.");
  }

  // ── Init all buffers ──────────────────────────────────────────────────────
  for (int i = 0; i < FILTER_SIZE; i++) filterBuffer[i] = 0;
  for (int i = 0; i < MEDIAN_SIZE; i++) medianBuffer[i] = 0;
  for (int i = 0; i < AI_INPUT_SIZE; i++) aiInputBuffer[i] = 0.0f;
  for (int i = 0; i < RR_BUFFER_SIZE; i++) rrBuffer[i] = 0;
  for (int i = 0; i < AI_VOTE_BUFFER_SIZE; i++) aiVoteBuffer[i] = 0;

  debugPrint("Ready! ECG + Software HR + AI + ESP32 Bridge streaming...");

  // ── Ping ESP32 on startup ─────────────────────────────────────────────────
  sendToESP32("PING");

  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);

  delay(100);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Main Loop
// ═══════════════════════════════════════════════════════════════════════════════

void loop() {
  // ── Always read ESP32 serial (non-blocking) ───────────────────────────────
  readESP32Serial();

  // ── Poll BLE ──────────────────────────────────────────────────────────────
  BLEDevice central = BLE.central();

  if (central && !bleConnected) {
    bleConnected = true;
    statusCharacteristic.writeValue("CONNECTED");
    debugPrint("Flutter connected: " + central.address());
    digitalWrite(LED_BUILTIN, LOW);  delay(100);
    digitalWrite(LED_BUILTIN, HIGH);
  }

  if (!central && bleConnected) {
    bleConnected = false;
    if (isRecording) {
      stopRecording();
      debugPrint("Auto-stopped recording due to disconnect.");
    }
    // Return to live mode on disconnect
    if (operatingMode != OP_MODE_LIVE) {
      switchToMode(OP_MODE_LIVE);
    }
    statusCharacteristic.writeValue("DISCONNECTED");
  }

  // ── Check for BLE commands ────────────────────────────────────────────────
  if (commandCharacteristic.written()) {
    String cmd = commandCharacteristic.value();
    cmd.trim();
    if (cmd.length() > 0) {
      handleBLECommand(cmd);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ECG Sample Acquisition — Mode-dependent source
  // ═══════════════════════════════════════════════════════════════════════════
  int32_t rawSample = 0;
  bool    sampleAvailable = false;

  if (operatingMode == OP_MODE_LIVE) {
    // ── LIVE MODE: Read from MAX30003 ──
    max30003.readEcgSample(rawSample);
    sampleAvailable = (rawSample != 0);
    
  } else {
    // ── SIMULATION / REPLAY MODE: Read from ESP32 serial ──
    if (esp32SampleReady) {
      rawSample = esp32EcgValue;
      esp32SampleReady = false;
      sampleAvailable = true;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  UNIFIED Processing Pipeline (UNCHANGED — same for all modes)
  // ═══════════════════════════════════════════════════════════════════════════
  
  if (sampleAvailable) {
    // ── Filtering pipeline ──────────────────────────────────────────────
    int32_t medianFiltered = medianFilter(rawSample);
    int32_t smoothed       = movingAverage(medianFiltered);
    baseline = (int32_t)(baseline * (1.0 - baselineAlpha) + smoothed * baselineAlpha);
    int32_t filtered = smoothed - baseline;

    // ── Software peak detection ─────────────────────────────────────────
    detectPeak(filtered);

    // ── Feed AI buffer ──────────────────────────────────────────────────
    float ecgMvForAI = (float)filtered / 65536.0f;
    aiInputBuffer[aiBufferIndex] = ecgMvForAI;
    aiBufferIndex++;

    if (aiBufferIndex >= AI_INPUT_SIZE) {
      aiBufferFull = true;
      aiBufferIndex = 0;
      runInference();
    }

    // ── Serial output ───────────────────────────────────────────────────
    if (DEBUG_MODE) {
      Serial.print("ECG:");
      Serial.print(filtered);
      Serial.print(",HR:");
      Serial.print(heartRate);
      Serial.print(",Mode:");
      Serial.println(operatingMode == OP_MODE_LIVE ? "LIVE" : 
                     operatingMode == OP_MODE_SIMULATION ? "SIM" : "REPLAY");
    } else {
      Serial.println(filtered);
    }

    // ── Timestamp ───────────────────────────────────────────────────────
    char tsBuffer[32];
    millisToISO8601(millis(), tsBuffer, sizeof(tsBuffer));

    const char* beatFlag = beatPending ? "peak" : "normal";

    // ── SD Card recording ───────────────────────────────────────────────
    if (isRecording) {
      float ecgMv = (float)filtered / 65536.0f;
      writeToSD(tsBuffer, rawSample, filtered, ecgMv, heartRate, lastRRms, beatFlag);
    }

    // ── BLE send (throttled) ────────────────────────────────────────────
    if (bleConnected) {
      bleSampleCounter++;
      if (bleSampleCounter >= BLE_SEND_EVERY_N_SAMPLES) {
        bleSampleCounter = 0;
        sendECGoverBLE(filtered, tsBuffer, beatFlag);

        beatPending = false;
      }
    } else {
      beatPending = false;
    }
  }

  // ── Delay based on mode ───────────────────────────────────────────────────
  if (operatingMode == OP_MODE_LIVE) {
    delay(8); // ~128 SPS for MAX30003
  } else {
    // In sim/replay mode, the ESP32 sends at 128 Hz.
    // We just need to keep polling fast enough to not miss samples.
    delay(1);
  }
}
