// ═══════════════════════════════════════════════════════════════════════════════
//  ECG Firmware with On-Device Arrhythmia Detection (TFLite Micro)
//  Arduino Nano 33 BLE + MAX30001 + MIT-BIH Trained Model
// ═══════════════════════════════════════════════════════════════════════════════
//
//  This firmware extends the base ECG firmware with edge AI inference.
//  A TFLite Micro model (trained on the MIT-BIH Arrhythmia Database) runs
//  on the Nano 33 BLE's Cortex-M4 to classify each heartbeat in real-time.
//
//  Classes (MIT-BIH standard):
//    0 = N  (Normal)
//    1 = S  (Supraventricular ectopic)
//    2 = V  (Ventricular ectopic)
//    3 = F  (Fusion)
//    4 = Q  (Unknown / Unclassifiable)
//
//  Model input:  [1, 1, 256]  — 1 channel, 256 samples (one heartbeat at 128 Hz)
//  Model output: [1, 5]       — logits for each class
// ═══════════════════════════════════════════════════════════════════════════════

// ── Custom SPI (register-level nRF52840 SPIM0 driver) ────────────────────
#define USE_CUSTOM_SPI
#include "custom_spi.h"

#include <SD.h>

// USE_CUSTOM_SPI must be defined BEFORE this include
#include <protocentral_max30001.h>
#include <ArduinoBLE.h>

// ── TensorFlow Lite Micro (Chirale port for Arduino) ─────────────────────
// Install via Library Manager: search "Chirale_TensorFLowLite" by Spazio Chirale
#include <Chirale_TensorFlowLite.h>
#include "tensorflow/lite/micro/all_ops_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/schema/schema_generated.h"

// ── Model data (model_data_32.h — float32 TFLite, const → lives in flash) ──
#include "model_data_32.h"

// ─── Pin Definitions ─────────────────────────────────────────────────────────
#define MAX30001_CS_PIN 10
#define SD_CS_PIN       9

MAX30001 ecgSensor(MAX30001_CS_PIN, &customSPI);

// ─── DEBUG MODE ──────────────────────────────────────────────────────────────
#define DEBUG_MODE false

// ─── BLE Service & Characteristics ──────────────────────────────────────────
BLEService ecgService("12345678-1234-1234-1234-123456789ABC");

BLEStringCharacteristic ecgCharacteristic(
  "12345678-1234-1234-1234-123456789ABD",
  BLERead | BLENotify,
  128
);

BLEStringCharacteristic statusCharacteristic(
  "12345678-1234-1234-1234-123456789ABE",
  BLERead | BLENotify,
  32
);

BLEStringCharacteristic commandCharacteristic(
  "12345678-1234-1234-1234-123456789ABF",
  BLEWrite | BLEWriteWithoutResponse,
  128
);

// NEW: AI inference result characteristic
BLEStringCharacteristic aiCharacteristic(
  "12345678-1234-1234-1234-123456789AC0",
  BLERead | BLENotify,
  128
);

// ─── Filter Parameters ───────────────────────────────────────────────────────
#define FILTER_SIZE 5
#define MEDIAN_SIZE 5

int32_t filterBuffer[FILTER_SIZE];
int filterIndex = 0;

int32_t medianBuffer[MEDIAN_SIZE];
int medianIndex = 0;

int32_t baseline      = 0;
float   baselineAlpha = 0.001;

// ─── Heart Rate Detection (Hardware R-to-R) ─────────────────────────────────
int           heartRate     = 0;
unsigned int  rrInterval    = 0;
bool          rrDetected    = false;
#define RTOR_POLL_INTERVAL_MS 500
unsigned long lastRtoRPollTime = 0;

// ─── Simulator Mode ──────────────────────────────────────────────────────────
bool          simulatorMode    = false;
char          simCondition     = 'N';   // N, S, V, F, Q
unsigned long simSampleIndex   = 0;
int           simHeartRate     = 72;

// ─── BLE State ───────────────────────────────────────────────────────────────
bool bleConnected = false;

// ─── BLE send throttle ───────────────────────────────────────────────────────
#define BLE_SEND_EVERY_N_SAMPLES 4
int bleSampleCounter = 0;

// ─── SD Card Recording State ─────────────────────────────────────────────────
bool sdAvailable  = false;
bool isRecording  = false;
File dataFile;
char recordingFilename[64];
unsigned long recordingSampleCount = 0;

// ─── Timestamp ───────────────────────────────────────────────────────────────
unsigned long bootEpochMs = 0;

// ═══════════════════════════════════════════════════════════════════════════════
//  TFLite Micro — Arrhythmia Detection Engine
// ═══════════════════════════════════════════════════════════════════════════════

// Model input size: 256 samples (one heartbeat window, 128 Hz, ~2 seconds)
#define AI_INPUT_SIZE   256
// Number of output classes
#define AI_NUM_CLASSES  5

// Class labels
static const char* AI_CLASS_LABELS[AI_NUM_CLASSES] = {
  "Normal",     // N
  "SupraVE",    // S — Supraventricular ectopic
  "VentricE",   // V — Ventricular ectopic
  "Fusion",     // F
  "Unknown"     // Q
};

// Short labels for BLE JSON
static const char* AI_CLASS_SHORT[AI_NUM_CLASSES] = {
  "N", "S", "V", "F", "Q"
};

// Ring buffer to collect 256 samples for inference
float aiInputBuffer[AI_INPUT_SIZE];
int   aiBufferIndex = 0;
bool  aiBufferFull  = false;

// How often to run inference (every N heartbeat windows)
#define AI_INFERENCE_INTERVAL_MS 3000   // at most once every 3 seconds
unsigned long lastInferenceTime = 0;

// Latest AI result
int   lastAiClass      = -1;          // -1 = no result yet
float lastAiConfidence = 0.0f;
char  lastAiLabel[16]  = "---";

// TFLite Micro objects
constexpr int kTensorArenaSize = 64 * 1024;   // 64 KB arena
alignas(16) uint8_t tensorArena[kTensorArenaSize];

const tflite::Model* tfModel        = nullptr;
tflite::MicroInterpreter* interpreter = nullptr;
TfLiteTensor* inputTensor            = nullptr;
TfLiteTensor* outputTensor           = nullptr;

// ─── Initialize TFLite Micro ─────────────────────────────────────────────────
bool initTFLite() {
  // Load the model from the byte array (const → stored in flash, not RAM)
  tfModel = tflite::GetModel(ecg_model_float32_tflite);
  if (tfModel->version() != TFLITE_SCHEMA_VERSION) {
    debugPrint("ERROR: Model schema version mismatch!");
    return false;
  }

  // Create resolver with all ops (use MicroMutableOpResolver for smaller footprint)
  static tflite::AllOpsResolver resolver;

  // Build the interpreter
  static tflite::MicroInterpreter static_interpreter(
    tfModel, resolver, tensorArena, kTensorArenaSize
  );
  interpreter = &static_interpreter;

  // Allocate memory for tensors
  TfLiteStatus allocate_status = interpreter->AllocateTensors();
  if (allocate_status != kTfLiteOk) {
    debugPrint("ERROR: AllocateTensors() failed!");
    interpreter = nullptr;
    return false;
  }

  // Get input/output tensor pointers
  inputTensor  = interpreter->input(0);
  outputTensor = interpreter->output(0);

  if (inputTensor == nullptr || outputTensor == nullptr) {
    debugPrint("ERROR: Input/Output tensors are null!");
    interpreter = nullptr;
    return false;
  }

  // Validate shapes
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

  // ── Z-score normalize the input buffer (matches Python training) ──────────
  // z-score: (x - mean) / (std + 1e-8)
  float mean = 0.0f;
  for (int i = 0; i < AI_INPUT_SIZE; i++) mean += aiInputBuffer[i];
  mean /= (float)AI_INPUT_SIZE;

  float variance = 0.0f;
  for (int i = 0; i < AI_INPUT_SIZE; i++) {
    float diff = aiInputBuffer[i] - mean;
    variance += diff * diff;
  }
  float stddev = sqrtf(variance / (float)AI_INPUT_SIZE) + 1e-8f;

  // Copy z-score normalized data into the input tensor
  for (int i = 0; i < AI_INPUT_SIZE; i++) {
    inputTensor->data.f[i] = (aiInputBuffer[i] - mean) / stddev;
  }

  // ── Invoke the model ──────────────────────────────────────────────────────
  unsigned long inferStart = micros();
  TfLiteStatus invoke_status = interpreter->Invoke();
  unsigned long inferTime = micros() - inferStart;

  if (invoke_status != kTfLiteOk) {
    debugPrint("[AI] Inference FAILED");
    return;
  }

  // ── Read output logits and apply softmax ──────────────────────────────────
  float out_f[AI_NUM_CLASSES];
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    out_f[i] = outputTensor->data.f[i];
  }

  // Softmax (model outputs raw logits)
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

  // Find top class
  float maxProb = -1.0f;
  int   maxIdx  = 0;
  for (int i = 0; i < AI_NUM_CLASSES; i++) {
    if (probs[i] > maxProb) {
      maxProb = probs[i];
      maxIdx  = i;
    }
  }

  lastAiClass      = maxIdx;
  lastAiConfidence = maxProb;
  strncpy(lastAiLabel, AI_CLASS_SHORT[maxIdx], sizeof(lastAiLabel));

  // ── Debug output ──────────────────────────────────────────────────────────
  if (DEBUG_MODE) {
    Serial.print("[AI] Result: ");
    Serial.print(AI_CLASS_LABELS[maxIdx]);
    Serial.print(" (");
    Serial.print(maxProb * 100.0f, 1);
    Serial.print("%) | Inference: ");
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

  // ── Send AI result over BLE ───────────────────────────────────────────────
  if (bleConnected) {
    char aiJson[128];
    snprintf(aiJson, sizeof(aiJson),
      "{\"class\":\"%s\",\"label\":\"%s\",\"confidence\":%.2f,\"probs\":[%.3f,%.3f,%.3f,%.3f,%.3f]}",
      AI_CLASS_SHORT[maxIdx],
      AI_CLASS_LABELS[maxIdx],
      maxProb,
      probs[0], probs[1], probs[2], probs[3], probs[4]
    );
    aiCharacteristic.writeValue(aiJson);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Helper Functions (same as base firmware)
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
  digitalWrite(MAX30001_CS_PIN, HIGH);

  if (SD.begin(SD_CS_PIN)) {
    sdAvailable = true;
    Serial.println("[SD] OK - SD card ready.");
  } else {
    sdAvailable = false;
    Serial.println("[SD] FAILED - Check wiring/card format.");
  }

  digitalWrite(MAX30001_CS_PIN, LOW);
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

  digitalWrite(MAX30001_CS_PIN, HIGH);
  dataFile = SD.open(recordingFilename, FILE_WRITE);
  digitalWrite(MAX30001_CS_PIN, LOW);

  if (dataFile) {
    digitalWrite(MAX30001_CS_PIN, HIGH);
    dataFile.println("timestamp,ecg_raw,ecg_filtered,ecg_mv,heart_rate,status,ai_class,ai_confidence");
    dataFile.flush();
    digitalWrite(MAX30001_CS_PIN, LOW);

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

  digitalWrite(MAX30001_CS_PIN, HIGH);
  dataFile.flush();
  dataFile.close();
  digitalWrite(MAX30001_CS_PIN, LOW);

  isRecording = false;

  Serial.println("[SD] Stopped. Samples: " + String(recordingSampleCount));
  statusCharacteristic.writeValue("REC_OFF");
}

void writeToSD(const char* timestamp, int32_t rawValue, int32_t filtered,
               float ecgMv, int hr, const char* status) {
  if (!isRecording) return;

  digitalWrite(MAX30001_CS_PIN, HIGH);

  char line[160];
  snprintf(line, sizeof(line), "%s,%ld,%ld,%.6f,%d,%s,%s,%.2f",
    timestamp, (long)rawValue, (long)filtered, ecgMv, hr, status,
    lastAiLabel, lastAiConfidence);
  dataFile.println(line);

  recordingSampleCount++;

  if (recordingSampleCount % 32 == 0) {
    dataFile.flush();
  }

  digitalWrite(MAX30001_CS_PIN, LOW);
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

  } else if (cmd.startsWith("SIM,")) {
    // ── Simulator mode commands ──────────────────────────────────────────
    String arg = cmd.substring(4);
    arg.trim();
    arg.toUpperCase();

    if (arg == "OFF") {
      simulatorMode = false;
      simSampleIndex = 0;
      debugPrint("[SIM] Simulator OFF — returning to real ECG");
      statusCharacteristic.writeValue("SIM_OFF");
    } else if (arg.length() == 1 && String("NSVFQ").indexOf(arg[0]) >= 0) {
      simulatorMode  = true;
      simCondition   = arg[0];
      simSampleIndex = 0;
      // Reset AI buffer for fresh inference on new condition
      aiBufferIndex = 0;
      aiBufferFull  = false;
      lastInferenceTime = 0;
      if (DEBUG_MODE) {
        Serial.print("[SIM] Simulating condition: ");
        Serial.println(simCondition);
      }
      char statusBuf[16];
      snprintf(statusBuf, sizeof(statusBuf), "SIM_%c", simCondition);
      statusCharacteristic.writeValue(statusBuf);
    } else {
      debugPrint("[SIM] Unknown condition: " + arg);
    }

  } else {
    debugPrint("Unknown command: " + cmd);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Setup
// ═══════════════════════════════════════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  delay(1000);

  pinMode(MAX30001_CS_PIN, OUTPUT);
  pinMode(SD_CS_PIN, OUTPUT);
  digitalWrite(MAX30001_CS_PIN, HIGH);
  digitalWrite(SD_CS_PIN, HIGH);

  debugPrint("==========================================");
  debugPrint("  MAX30001 ECG + AI Arrhythmia Detection");
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
  ecgService.addCharacteristic(aiCharacteristic);      // NEW: AI results
  BLE.addService(ecgService);

  ecgCharacteristic.writeValue("{}");
  statusCharacteristic.writeValue("WAITING");
  aiCharacteristic.writeValue("{}");
  BLE.advertise();

  debugPrint("Advertising as ECG_Nano33_AI");
  debugPrint("AI Char: 12345678-1234-1234-1234-123456789AC0");

  // ── MAX30001 Init ─────────────────────────────────────────────────────────
  customSPI.begin();
  debugPrint("Initializing MAX30001...");

  max30001_error_t result = ecgSensor.begin();
  if (result != MAX30001_SUCCESS) {
    if (DEBUG_MODE) {
      Serial.print("ERROR: MAX30001 failed! Code: ");
      Serial.println(result);
    }
    while (1) delay(1000);
  }
  debugPrint("MAX30001 initialized");

  if (!ecgSensor.isConnected()) {
    debugPrint("ERROR: MAX30001 not responding!");
    while (1) delay(1000);
  }
  debugPrint("MAX30001 connected");

  result = ecgSensor.startECG(MAX30001_RATE_128);
  if (result != MAX30001_SUCCESS) {
    if (DEBUG_MODE) {
      Serial.print("ERROR: ECG start failed! Code: ");
      Serial.println(result);
    }
    while (1) delay(1000);
  }
  debugPrint("ECG started at 128 SPS");

  // ── SD Card Init ──────────────────────────────────────────────────────────
  initSDCard();

  // ── TFLite Micro Init ─────────────────────────────────────────────────────
  debugPrint("[AI] Loading arrhythmia detection model...");
  if (!initTFLite()) {
    debugPrint("[AI] WARNING: AI model failed to load! Running without AI.");
    // Continue without AI — ECG still works
  } else {
    debugPrint("[AI] Model loaded. Ready for inference.");
  }

  // ── Init filter buffers ───────────────────────────────────────────────────
  for (int i = 0; i < FILTER_SIZE; i++) filterBuffer[i] = 0;
  for (int i = 0; i < MEDIAN_SIZE; i++) medianBuffer[i] = 0;
  for (int i = 0; i < AI_INPUT_SIZE; i++) aiInputBuffer[i] = 0.0f;

  debugPrint("Ready! ECG + AI streaming...");

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
    debugPrint("Flutter disconnected");
  }

  // ── Check for BLE commands ────────────────────────────────────────────────
  if (commandCharacteristic.written()) {
    String cmd = commandCharacteristic.value();
    cmd.trim();
    if (cmd.length() > 0) {
      handleBLECommand(cmd);
    }
  }

  // ── ECG Sample Acquisition (Real or Simulated) ─────────────────────────
  float    ecgValueForAI = 0.0f;
  int32_t  filtered      = 0;
  bool     sampleReady   = false;

  if (simulatorMode) {
    // ── Simulator path: generate synthetic ECG ──────────────────────────
    ecgValueForAI = generateSimulatedECG(simCondition);
    filtered = (int32_t)(ecgValueForAI * 65536.0f);
    heartRate = simHeartRate;
    rrDetected = (ecgValueForAI > 0.5f);  // Approximate peak detection
    sampleReady = true;
    simSampleIndex++;

  } else {
    // ── Real MAX30001 path ──────────────────────────────────────────────
    max30001_ecg_sample_t ecgSample;
    max30001_error_t result = ecgSensor.getECGSample(&ecgSample);

    if (result == MAX30001_SUCCESS && ecgSample.sample_valid) {
      int32_t rawValue = ecgSample.ecg_sample;

      // ── Filtering pipeline ──────────────────────────────────────────
      int32_t medianFiltered = medianFilter(rawValue);
      int32_t smoothed       = movingAverage(medianFiltered);
      baseline = (int32_t)(baseline * (1.0 - baselineAlpha) + smoothed * baselineAlpha);
      filtered = smoothed - baseline;
      ecgValueForAI = (float)filtered / 65536.0f;

      // ── Hardware R-to-R heart rate polling ──────────────────────────
      if (millis() - lastRtoRPollTime >= RTOR_POLL_INTERVAL_MS) {
        lastRtoRPollTime = millis();
        max30001_rtor_data_t rtorData;
        if (ecgSensor.getRtoRData(&rtorData) == MAX30001_SUCCESS && rtorData.rr_detected) {
          heartRate  = rtorData.heart_rate_bpm;
          rrInterval = rtorData.rr_interval_ms;
          rrDetected = true;
        } else {
          rrDetected = false;
        }
      }
      sampleReady = true;
    }
  }

  // ── Common processing for both real and simulated ────────────────────────
  if (sampleReady) {
    // ── Feed AI buffer ──────────────────────────────────────────────────
    aiInputBuffer[aiBufferIndex] = ecgValueForAI;
    aiBufferIndex++;

    if (aiBufferIndex >= AI_INPUT_SIZE) {
      aiBufferFull = true;
      aiBufferIndex = 0;
      runInference();
    }

    // ── Serial output ───────────────────────────────────────────────────
    if (DEBUG_MODE) {
      Serial.print(simulatorMode ? "[SIM]" : "ECG:");
      Serial.print(filtered);
      Serial.print(",HR:");
      Serial.print(heartRate);
      Serial.print(",AI:");
      Serial.println(lastAiLabel);
    } else {
      Serial.println(filtered);
    }

    // ── Timestamp ───────────────────────────────────────────────────────
    char tsBuffer[32];
    millisToISO8601(millis(), tsBuffer, sizeof(tsBuffer));

    const char* peakStatus = rrDetected ? "peak" : "normal";

    // ── SD Card recording ───────────────────────────────────────────────
    if (isRecording && !simulatorMode) {
      float ecgMv = (float)filtered / 65536.0f;
      writeToSD(tsBuffer, 0, filtered, ecgMv, heartRate, peakStatus);
    }

    // ── BLE send (only when connected) ──────────────────────────────────
    if (bleConnected) {
      bleSampleCounter++;
      if (bleSampleCounter >= BLE_SEND_EVERY_N_SAMPLES) {
        bleSampleCounter = 0;
        sendECGoverBLE(filtered, tsBuffer, peakStatus);
      }
    }
  }

  delay(8); // ~128 SPS
}

// ─── Send ECG as JSON over BLE ───────────────────────────────────────────────
void sendECGoverBLE(int32_t filteredValue, const char* timestamp, const char* status) {
  float ecgFloat = (float)filteredValue / 65536.0f;
  if (ecgFloat >  3.0f) ecgFloat =  3.0f;
  if (ecgFloat < -3.0f) ecgFloat = -3.0f;

  char jsonBuffer[128];
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"timestamp\":\"%s\",\"ecg_value\":%.6f,\"heart_rate\":%d,\"status\":\"%s\"}",
    timestamp, ecgFloat, heartRate, status
  );

  ecgCharacteristic.writeValue(jsonBuffer);
}

// ─── Heart Rate (Hardware R-to-R) ────────────────────────────────────────────
// Heart rate is now read directly from the MAX30001 RTOR register.
// No software peak detection needed — the chip handles it in hardware.

// ═══════════════════════════════════════════════════════════════════════════════
//  ECG Simulator — Synthetic Waveform Generator
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Generates mathematically-modeled PQRST waveforms for 5 arrhythmia conditions.
//  Used to test the on-device AI model without needing a patient.
//
//  Each condition produces a distinct ECG morphology:
//    N = Normal sinus rhythm (72 BPM, regular PQRST)
//    S = Supraventricular ectopic (premature beats, ~100 BPM)
//    V = Ventricular ectopic (wide QRS, no P wave, irregular)
//    F = Fusion (alternating normal + ventricular morphology)
//    Q = Unknown/noisy (attenuated signal with artifacts)
// ═══════════════════════════════════════════════════════════════════════════════

static float simGaussian(float x, float mu, float sigma) {
  float d = (x - mu) / sigma;
  return exp(-0.5f * d * d);
}

float generateSimulatedECG(char condition) {
  // Sample rate = 128 Hz, so dt = 1/128 = 0.0078125 sec
  float t = (float)simSampleIndex / 128.0f;  // time in seconds
  float noise = ((float)(random(-100, 100))) / 10000.0f;  // ±0.01 mV noise

  switch (condition) {

    // ── Normal Sinus Rhythm (N) ─────────────────────────────────────────
    // 72 BPM = 0.833s period, standard PQRST morphology
    case 'N': {
      simHeartRate = 72;
      float period = 60.0f / 72.0f;  // ~0.833s
      float phase  = fmod(t, period) / period;

      float ecg = 0.0f;
      if (phase < 0.12f)      ecg =  0.15f * simGaussian(phase, 0.06f, 0.025f);  // P wave
      else if (phase < 0.17f) ecg = -0.10f * simGaussian(phase, 0.145f, 0.012f); // Q
      else if (phase < 0.24f) ecg =  1.20f * simGaussian(phase, 0.20f, 0.014f);  // R (tall)
      else if (phase < 0.30f) ecg = -0.20f * simGaussian(phase, 0.27f, 0.015f);  // S
      else if (phase < 0.58f) ecg =  0.25f * simGaussian(phase, 0.48f, 0.040f);  // T wave

      return ecg + noise;
    }

    // ── Supraventricular Ectopic (S) ────────────────────────────────────
    // Premature beats: shorter R-R intervals, slightly faster
    case 'S': {
      simHeartRate = 100;
      float period = 60.0f / 100.0f;  // 0.6s
      float cycle  = fmod(t, period * 3.0f);  // 3-beat pattern
      float localPhase;

      if (cycle < period) {
        localPhase = cycle / period;  // Normal beat
      } else if (cycle < period * 1.7f) {
        localPhase = (cycle - period) / (period * 0.7f);  // Premature beat
      } else {
        localPhase = (cycle - period * 1.7f) / (period * 1.3f);  // Compensatory pause
      }

      float ecg = 0.0f;
      if (localPhase < 0.12f)      ecg =  0.12f * simGaussian(localPhase, 0.06f, 0.020f);
      else if (localPhase < 0.17f) ecg = -0.08f * simGaussian(localPhase, 0.145f, 0.010f);
      else if (localPhase < 0.24f) ecg =  1.00f * simGaussian(localPhase, 0.20f, 0.013f);
      else if (localPhase < 0.30f) ecg = -0.15f * simGaussian(localPhase, 0.27f, 0.013f);
      else if (localPhase < 0.58f) ecg =  0.20f * simGaussian(localPhase, 0.48f, 0.035f);

      return ecg + noise;
    }

    // ── Ventricular Ectopic (V) ─────────────────────────────────────────
    // Wide QRS (2× normal width), no P wave, higher amplitude, irregular
    case 'V': {
      simHeartRate = 85;
      float period = 60.0f / 85.0f;
      float phase  = fmod(t, period) / period;

      float ecg = 0.0f;
      // No P wave — ventricular origin bypasses atria
      if (phase < 0.30f)      ecg =  1.80f * simGaussian(phase, 0.18f, 0.035f);  // Wide R
      else if (phase < 0.42f) ecg = -0.60f * simGaussian(phase, 0.36f, 0.030f);  // Deep S
      else if (phase < 0.70f) ecg = -0.30f * simGaussian(phase, 0.55f, 0.050f);  // Inverted T

      return ecg + noise * 2.0f;  // Slightly noisier
    }

    // ── Fusion (F) ──────────────────────────────────────────────────────
    // Alternating normal and ventricular beats (mixed morphology)
    case 'F': {
      simHeartRate = 78;
      float period = 60.0f / 78.0f;
      int   beatNum  = (int)(t / period);
      float phase    = fmod(t, period) / period;
      bool  isVBeat  = (beatNum % 2 == 1);  // Every other beat is ventricular

      float ecg = 0.0f;
      if (isVBeat) {
        // Ventricular-like beat (fusion — partial normal morphology)
        if (phase < 0.08f)      ecg =  0.05f * simGaussian(phase, 0.04f, 0.015f);  // Tiny P
        else if (phase < 0.28f) ecg =  1.40f * simGaussian(phase, 0.18f, 0.028f);  // Wide R
        else if (phase < 0.40f) ecg = -0.40f * simGaussian(phase, 0.34f, 0.025f);  // S
        else if (phase < 0.60f) ecg = -0.10f * simGaussian(phase, 0.50f, 0.040f);  // Flat T
      } else {
        // Normal beat
        if (phase < 0.12f)      ecg =  0.15f * simGaussian(phase, 0.06f, 0.025f);
        else if (phase < 0.17f) ecg = -0.10f * simGaussian(phase, 0.145f, 0.012f);
        else if (phase < 0.24f) ecg =  1.20f * simGaussian(phase, 0.20f, 0.014f);
        else if (phase < 0.30f) ecg = -0.20f * simGaussian(phase, 0.27f, 0.015f);
        else if (phase < 0.58f) ecg =  0.25f * simGaussian(phase, 0.48f, 0.040f);
      }

      return ecg + noise;
    }

    // ── Unknown / Noisy (Q) ─────────────────────────────────────────────
    // Attenuated signal with random artifacts — intentionally hard to classify
    case 'Q': {
      simHeartRate = 65;
      float period = 60.0f / 65.0f;
      float phase  = fmod(t, period) / period;

      float ecg = 0.0f;
      // Heavily attenuated normal PQRST
      if (phase < 0.12f)      ecg =  0.03f * simGaussian(phase, 0.06f, 0.025f);
      else if (phase < 0.17f) ecg = -0.02f * simGaussian(phase, 0.145f, 0.012f);
      else if (phase < 0.24f) ecg =  0.30f * simGaussian(phase, 0.20f, 0.014f);
      else if (phase < 0.30f) ecg = -0.05f * simGaussian(phase, 0.27f, 0.015f);
      else if (phase < 0.58f) ecg =  0.06f * simGaussian(phase, 0.48f, 0.040f);

      // Add random artifacts (motion noise, baseline wander)
      float artifact = ((float)(random(-500, 500))) / 1000.0f;
      float wander   = 0.1f * sin(t * 0.3f);  // Slow baseline drift

      return ecg + artifact * 0.3f + wander + noise * 5.0f;
    }

    default:
      return noise;
  }
}

// ─── Moving Average Filter ───────────────────────────────────────────────────
int32_t movingAverage(int32_t newValue) {
  filterBuffer[filterIndex] = newValue;
  filterIndex = (filterIndex + 1) % FILTER_SIZE;

  int64_t sum = 0;
  for (int i = 0; i < FILTER_SIZE; i++) sum += filterBuffer[i];
  return (int32_t)(sum / FILTER_SIZE);
}

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
