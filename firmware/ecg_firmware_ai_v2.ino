// ═══════════════════════════════════════════════════════════════════════════════
//  ECG Firmware v2 — Software HR + HRV + Edge AI Arrhythmia Detection
//  Arduino Nano 33 BLE + MAX30003 + TFLite Micro
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Combines:
//    • ECG streaming via protocentral_max30003 readEcgSample()
//    • Software-based R-peak detection with adaptive threshold & EMA smoothing
//    • SDNN / RMSSD computed from RR intervals on-device
//    • TFLite Micro arrhythmia classifier (MIT-BIH trained model)
//    • BLE communication to Flutter frontend
//    • SD card recording
//
//  Heart rate is derived from software peak detection on the filtered ECG
//  signal, with clamping (40–180 BPM) and EMA smoothing to avoid spikes.
//
//  AI Classes (MIT-BIH standard):
//    0 = N  (Normal)
//    1 = S  (Supraventricular ectopic)
//    2 = V  (Ventricular ectopic)
//    3 = F  (Fusion)
//    4 = Q  (Unknown / Unclassifiable)
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

// ═══════════════════════════════════════════════════════════════════════════════
//  BLE Service & Characteristics
// ═══════════════════════════════════════════════════════════════════════════════

BLEService ecgService("12345678-1234-1234-1234-123456789ABC");

// ECG data (JSON)
BLEStringCharacteristic ecgCharacteristic(
  "12345678-1234-1234-1234-123456789ABD",
  BLERead | BLENotify,
  128
);

// Status (CONNECTED / DISCONNECTED / REC_ON / etc.)
BLEStringCharacteristic statusCharacteristic(
  "12345678-1234-1234-1234-123456789ABE",
  BLERead | BLENotify,
  32
);

// Command input (START,<filename> / STOP)
BLEStringCharacteristic commandCharacteristic(
  "12345678-1234-1234-1234-123456789ABF",
  BLEWrite | BLEWriteWithoutResponse,
  128
);

// AI inference result (JSON)
BLEStringCharacteristic aiCharacteristic(
  "12345678-1234-1234-1234-123456789AC0",
  BLERead | BLENotify,
  128
);

// ═══════════════════════════════════════════════════════════════════════════════
//  Signal Processing Filters
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
//  Software Peak Detection & Heart Rate (replaces hardware RTOR)
// ═══════════════════════════════════════════════════════════════════════════════

// ── Adaptive threshold peak detection ────────────────────────────────────────
int32_t       peakThreshold     = 50;       // Initial threshold — adapts over time
float         adaptiveMax       = 50.0f;    // Running max of filtered signal
float         adaptiveAlpha     = 0.01f;    // Decay rate for adaptive max
float         thresholdFraction = 0.40f;    // Threshold = 40% of adaptive max

unsigned long lastPeakTime      = 0;
unsigned long peakInterval      = 0;
bool          peakDetected      = false;

// ── Heart rate with EMA smoothing ────────────────────────────────────────────
int           heartRate       = 0;          // Final smoothed BPM sent over BLE
float         smoothedHR      = 72.0f;      // EMA-smoothed HR (init to reasonable value)
float         hrAlpha         = 0.2f;       // EMA alpha — lower = more smoothing
#define       HR_MIN          40            // Minimum valid HR
#define       HR_MAX          180           // Maximum valid HR

// ═══════════════════════════════════════════════════════════════════════════════
//  RR Interval Tracking + HRV (SDNN / RMSSD)
// ═══════════════════════════════════════════════════════════════════════════════

#define RR_BUFFER_SIZE 20           // Circular buffer for last N RR intervals

unsigned long rrBuffer[RR_BUFFER_SIZE];
int           rrBufferIndex = 0;
int           rrBufferCount = 0;    // How many valid entries we have (up to RR_BUFFER_SIZE)

int           lastRRms = 0;        // Most recent RR interval in ms
float         sdnnValue  = 0.0f;   // Standard deviation of NN intervals
float         rmssdValue = 0.0f;   // Root mean square of successive differences

// Compute SDNN and RMSSD from the RR buffer
void computeHRV() {
  if (rrBufferCount < 2) {
    sdnnValue  = 0.0f;
    rmssdValue = 0.0f;
    return;
  }

  int n = rrBufferCount;

  // Collect valid entries from circular buffer
  float intervals[RR_BUFFER_SIZE];
  for (int i = 0; i < n; i++) {
    int idx = (rrBufferIndex - n + i + RR_BUFFER_SIZE) % RR_BUFFER_SIZE;
    intervals[i] = (float)rrBuffer[idx];
  }

  // Mean RR
  float mean = 0.0f;
  for (int i = 0; i < n; i++) mean += intervals[i];
  mean /= (float)n;

  // SDNN = sqrt(variance of RR intervals)
  float variance = 0.0f;
  for (int i = 0; i < n; i++) {
    float diff = intervals[i] - mean;
    variance += diff * diff;
  }
  sdnnValue = sqrtf(variance / (float)n);

  // RMSSD = sqrt(mean of squared successive differences)
  float sumSqDiff = 0.0f;
  for (int i = 1; i < n; i++) {
    float diff = intervals[i] - intervals[i - 1];
    sumSqDiff += diff * diff;
  }
  rmssdValue = sqrtf(sumSqDiff / (float)(n - 1));
}

// ═══════════════════════════════════════════════════════════════════════════════
//  BLE State
// ═══════════════════════════════════════════════════════════════════════════════

bool bleConnected = false;

// ── BLE send throttle ────────────────────────────────────────────────────────
#define BLE_SEND_EVERY_N_SAMPLES 4
int bleSampleCounter = 0;

// ═══════════════════════════════════════════════════════════════════════════════
//  SD Card Recording State
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
//  TFLite Micro — Arrhythmia Detection Engine
// ═══════════════════════════════════════════════════════════════════════════════

#define AI_INPUT_SIZE   256
#define AI_NUM_CLASSES  5

static const char* AI_CLASS_LABELS[AI_NUM_CLASSES] = {
  "Normal", "SupraVE", "VentricE", "Fusion", "Unknown"
};

static const char* AI_CLASS_SHORT[AI_NUM_CLASSES] = {
  "N", "S", "V", "F", "Q"
};

// Ring buffer for AI inference
float aiInputBuffer[AI_INPUT_SIZE];
int   aiBufferIndex = 0;
bool  aiBufferFull  = false;

#define AI_INFERENCE_INTERVAL_MS 3000
unsigned long lastInferenceTime = 0;

// Latest AI result
int   lastAiClass      = -1;
float lastAiConfidence = 0.0f;
char  lastAiLabel[16]  = "---";

// ── AI confidence threshold & majority voting ────────────────────────────────
#define AI_CONFIDENCE_THRESHOLD   0.70f   // Non-Normal class must exceed this
#define AI_VOTE_BUFFER_SIZE       3       // Majority voting over last N results

int aiVoteBuffer[AI_VOTE_BUFFER_SIZE];
int aiVoteIndex = 0;
int aiVoteCount = 0;                       // How many results we have so far

// Returns the majority class from the vote buffer
int getAiMajorityClass() {
  if (aiVoteCount == 0) return 0; // Default to Normal

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
constexpr int kTensorArenaSize = 64 * 1024;   // 64 KB arena
alignas(16) uint8_t tensorArena[kTensorArenaSize];

const tflite::Model* tfModel         = nullptr;
tflite::MicroInterpreter* interpreter = nullptr;
TfLiteTensor* inputTensor             = nullptr;
TfLiteTensor* outputTensor            = nullptr;

// ─── Initialize TFLite Micro ─────────────────────────────────────────────────
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

// ─── Run inference on the 256-sample buffer ──────────────────────────────────
void runInference() {
  if (interpreter == nullptr || inputTensor == nullptr || outputTensor == nullptr) return;

  unsigned long now = millis();
  if (now - lastInferenceTime < AI_INFERENCE_INTERVAL_MS) return;
  lastInferenceTime = now;

  // ── Z-score normalize (matches Python training pipeline) ──────────────
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

  // ── Invoke the model ──────────────────────────────────────────────────
  unsigned long inferStart = micros();
  TfLiteStatus invoke_status = interpreter->Invoke();
  unsigned long inferTime = micros() - inferStart;

  if (invoke_status != kTfLiteOk) {
    debugPrint("[AI] Inference FAILED");
    return;
  }

  // ── Read output logits and apply softmax ──────────────────────────────
  float out_f[AI_NUM_CLASSES];
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    out_f[i] = outputTensor->data.f[i];
  }

  float maxLogit = out_f[0];
  for (int i = 1; i < AI_NUM_CLASSES; i++) {
    if (out_f[i] > maxLogit) maxLogit = out_f[i];
  }

  float probs[AI_NUM_CLASSES];
  float sumExp = 0.0f;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    probs[i] = exp(out_f[i] - maxLogit);
    sumExp += probs[i];
  }
  if (sumExp <= 0.0f || isnan(sumExp)) sumExp = 1.0f;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    probs[i] /= sumExp;
    if (probs[i] > 1.0f) probs[i] = 1.0f;
    if (probs[i] < 0.0f) probs[i] = 0.0f;
  }

  // Find top class from raw softmax
  float maxProb = -1.0f;
  int   maxIdx  = 0;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    if (probs[i] > maxProb) {
      maxProb = probs[i];
      maxIdx  = i;
    }
  }

  // ── Confidence gating: non-Normal class must exceed threshold ─────────
  // If the model's top class is NOT Normal (class 0) but confidence is low,
  // default to Normal. This prevents false "VentricE" classifications.
  int reportedClass = maxIdx;
  if (maxIdx != 0 && maxProb < AI_CONFIDENCE_THRESHOLD) {
    reportedClass = 0;  // Default to Normal if not confident enough
  }

  // ── Majority voting: add to vote buffer ───────────────────────────────
  aiVoteBuffer[aiVoteIndex] = reportedClass;
  aiVoteIndex = (aiVoteIndex + 1) % AI_VOTE_BUFFER_SIZE;
  if (aiVoteCount < AI_VOTE_BUFFER_SIZE) aiVoteCount++;

  int finalClass = getAiMajorityClass();

  lastAiClass      = finalClass;
  lastAiConfidence = probs[finalClass];
  strncpy(lastAiLabel, AI_CLASS_SHORT[finalClass], sizeof(lastAiLabel));

  if (DEBUG_MODE) {
    Serial.print("[AI] Raw: ");
    Serial.print(AI_CLASS_LABELS[maxIdx]);
    Serial.print(" (");
    Serial.print(maxProb * 100.0f, 1);
    Serial.print("%) → Voted: ");
    Serial.print(AI_CLASS_LABELS[finalClass]);
    Serial.print(" | Inference: ");
    Serial.print(inferTime / 1000.0f, 1);
    Serial.println(" ms");

    Serial.print("[AI] Probs: ");
    for (int i = 0; i < AI_NUM_CLASSES; i++) {
      Serial.print(AI_CLASS_SHORT[i]);
      Serial.print("=");
      Serial.print(probs[i] * 100.0f, 1);
      Serial.print("% ");
    }
    Serial.println();
  }

  // ── Send AI result over BLE ───────────────────────────────────────────
  if (bleConnected) {
    char aiJson[128];
    snprintf(aiJson, sizeof(aiJson),
      "{\"class\":\"%s\",\"label\":\"%s\",\"confidence\":%.2f,\"probs\":[%.3f,%.3f,%.3f,%.3f,%.3f]}",
      AI_CLASS_SHORT[finalClass],
      AI_CLASS_LABELS[finalClass],
      lastAiConfidence,
      probs[0], probs[1], probs[2], probs[3], probs[4]
    );
    aiCharacteristic.writeValue(aiJson);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Helper Functions
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

// ─── SD Card Helpers ─────────────────────────────────────────────────────────

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
    dataFile.println("timestamp,ecg_raw,ecg_filtered,ecg_mv,heart_rate,rr_ms,beat,sdnn,rmssd,ai_class,ai_confidence");
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

  digitalWrite(MAX30003_CS_PIN, HIGH);

  char line[200];
  snprintf(line, sizeof(line), "%s,%ld,%ld,%.6f,%d,%d,%s,%.1f,%.1f,%s,%.2f",
    timestamp, (long)rawValue, (long)filtered, ecgMv, hr, rrMs, beat,
    sdnnValue, rmssdValue, lastAiLabel, lastAiConfidence);
  dataFile.println(line);

  recordingSampleCount++;

  if (recordingSampleCount % 32 == 0) {
    dataFile.flush();
  }

  digitalWrite(MAX30003_CS_PIN, LOW);
}

// ─── BLE Command Handler ─────────────────────────────────────────────────────
void handleBLECommand(const String& cmd) {
  debugPrint("BLE Command: " + cmd);

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

  } else {
    debugPrint("Unknown command: " + cmd);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Signal Processing
// ═══════════════════════════════════════════════════════════════════════════════

// ─── Median Filter ───────────────────────────────────────────────────────────
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

// ─── Moving Average Filter ───────────────────────────────────────────────────
int32_t movingAverage(int32_t newValue) {
  filterBuffer[filterIndex] = newValue;
  filterIndex = (filterIndex + 1) % FILTER_SIZE;

  int64_t sum = 0;
  for (int i = 0; i < FILTER_SIZE; i++) sum += filterBuffer[i];
  return (int32_t)(sum / FILTER_SIZE);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Software Peak Detection — Adaptive Threshold + EMA Smoothing
// ═══════════════════════════════════════════════════════════════════════════════

void detectPeak(int32_t value) {
  unsigned long now = millis();

  // Track the running max of the absolute filtered signal for adaptive threshold
  float absVal = (float)abs(value);
  if (absVal > adaptiveMax) {
    adaptiveMax = absVal;  // Instantly track new peaks
  } else {
    adaptiveMax = adaptiveMax * (1.0f - adaptiveAlpha) + absVal * adaptiveAlpha;  // Slow decay
  }

  // Adaptive threshold: fraction of the running max (minimum floor of 30)
  peakThreshold = (int32_t)(adaptiveMax * thresholdFraction);
  if (peakThreshold < 30) peakThreshold = 30;

  // Detect rising edge crossing the threshold
  if (value > peakThreshold && !peakDetected) {
    unsigned long elapsed = now - lastPeakTime;

    // Refractory period: at least 300ms between peaks (max 200 BPM)
    if (elapsed > 300) {
      peakInterval = elapsed;
      lastPeakTime = now;

      if (peakInterval > 0) {
        int rawHR = 60000 / (int)peakInterval;

        // Clamp to valid physiological range
        if (rawHR >= HR_MIN && rawHR <= HR_MAX) {
          // EMA smoothing to prevent spikes
          smoothedHR = smoothedHR * (1.0f - hrAlpha) + (float)rawHR * hrAlpha;
          heartRate = (int)(smoothedHR + 0.5f);  // Round to nearest int

          // Store RR interval for HRV computation
          lastRRms = (int)peakInterval;
          rrBuffer[rrBufferIndex] = peakInterval;
          rrBufferIndex = (rrBufferIndex + 1) % RR_BUFFER_SIZE;
          if (rrBufferCount < RR_BUFFER_SIZE) rrBufferCount++;

          // Recompute HRV metrics
          computeHRV();
        }
        // If rawHR is outside [HR_MIN, HR_MAX], we simply ignore this beat
        // — heartRate keeps its previous value (no spike)
      }
    }
    peakDetected = true;
  }

  // Reset detector when signal drops below half the threshold
  if (value < peakThreshold / 2) {
    peakDetected = false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Send ECG data as JSON over BLE
// ═══════════════════════════════════════════════════════════════════════════════

void sendECGoverBLE(int32_t filteredValue, const char* timestamp, const char* beat) {
  float ecgFloat = (float)filteredValue / 65536.0f;
  if (ecgFloat >  3.0f) ecgFloat =  3.0f;
  if (ecgFloat < -3.0f) ecgFloat = -3.0f;

  // JSON includes hr, rr, sdnn, rmssd — all computed by software
  char jsonBuffer[128];
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"timestamp\":\"%s\",\"ecg_value\":%.6f,\"beat\":\"%s\",\"hr\":%d,\"rr\":%d,\"sdnn\":%.1f,\"rmssd\":%.1f}",
    timestamp, ecgFloat, beat, heartRate, lastRRms, sdnnValue, rmssdValue
  );

  ecgCharacteristic.writeValue(jsonBuffer);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Setup
// ═══════════════════════════════════════════════════════════════════════════════

void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(MAX30003_CS_PIN, OUTPUT);
  pinMode(SD_CS_PIN, OUTPUT);
  digitalWrite(MAX30003_CS_PIN, HIGH);
  digitalWrite(SD_CS_PIN, HIGH);

  debugPrint("==========================================");
  debugPrint("  MAX30003 ECG + Software HR + AI v2");
  debugPrint("  Arduino Nano 33 BLE");
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
  debugPrint("AI Char: 12345678-1234-1234-1234-123456789AC0");

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

  // ── Configure ECG registers (NO RTOR — software peak detection only) ──
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

  // ── Init filter buffers ───────────────────────────────────────────────────
  for (int i = 0; i < FILTER_SIZE; i++) filterBuffer[i] = 0;
  for (int i = 0; i < MEDIAN_SIZE; i++) medianBuffer[i] = 0;
  for (int i = 0; i < AI_INPUT_SIZE; i++) aiInputBuffer[i] = 0.0f;
  for (int i = 0; i < RR_BUFFER_SIZE; i++) rrBuffer[i] = 0;
  for (int i = 0; i < AI_VOTE_BUFFER_SIZE; i++) aiVoteBuffer[i] = 0;

  debugPrint("Ready! ECG + Software HR + AI streaming...");

  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);

  delay(100);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Main Loop
// ═══════════════════════════════════════════════════════════════════════════════

void loop() {
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

  // ── ECG Sample Acquisition ────────────────────────────────────────────────
  int32_t rawSample = 0;
  max30003.readEcgSample(rawSample);

  // Only process non-zero samples (MAX30003 returns 0 when FIFO is empty)
  if (rawSample != 0) {
    // ── Filtering pipeline ──────────────────────────────────────────────
    int32_t medianFiltered = medianFilter(rawSample);
    int32_t smoothed       = movingAverage(medianFiltered);
    baseline = (int32_t)(baseline * (1.0 - baselineAlpha) + smoothed * baselineAlpha);
    int32_t filtered = smoothed - baseline;

    // ── Software peak detection ─────────────────────────────────────────
    bool wasPeak = peakDetected;
    detectPeak(filtered);
    bool isPeak = peakDetected && !wasPeak;  // Rising edge only

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
      Serial.print(",SDNN:");
      Serial.print(sdnnValue, 1);
      Serial.print(",RMSSD:");
      Serial.print(rmssdValue, 1);
      Serial.print(",AI:");
      Serial.println(lastAiLabel);
    } else {
      Serial.println(filtered);
    }

    // ── Timestamp ───────────────────────────────────────────────────────
    char tsBuffer[32];
    millisToISO8601(millis(), tsBuffer, sizeof(tsBuffer));

    const char* beatFlag = isPeak ? "peak" : "normal";

    // ── SD Card recording ───────────────────────────────────────────────
    if (isRecording) {
      float ecgMv = (float)filtered / 65536.0f;
      writeToSD(tsBuffer, rawSample, filtered, ecgMv, heartRate, lastRRms, beatFlag);
    }

    // ── BLE send (throttled, only when connected) ───────────────────────
    if (bleConnected) {
      bleSampleCounter++;
      if (bleSampleCounter >= BLE_SEND_EVERY_N_SAMPLES) {
        bleSampleCounter = 0;
        sendECGoverBLE(filtered, tsBuffer, beatFlag);
      }
    }
  }

  delay(8); // ~128 SPS
}
