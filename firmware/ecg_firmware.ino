#include <SPI.h>
#include <SD.h>
#include <protocentral_max30001.h>
#include <ArduinoBLE.h>

#define MAX30001_CS_PIN 10
#define SD_CS_PIN 9

MAX30001 ecgSensor(MAX30001_CS_PIN);

// ─── DEBUG MODE ──────────────────────────────────────────────────────────────
// true  = Serial Monitor mode (shows text logs, BLE status, heart rate)
// false = Serial Plotter mode (clean numbers only, ECG graph always works)
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

// Command characteristic — Flutter writes START/STOP commands here
BLEStringCharacteristic commandCharacteristic(
  "12345678-1234-1234-1234-123456789ABF",
  BLEWrite | BLEWriteWithoutResponse,
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

// ─── Heart Rate Detection ────────────────────────────────────────────────────
int32_t       peakThreshold = 50;
unsigned long lastPeakTime  = 0;
unsigned long peakInterval  = 0;
int           heartRate     = 0;
bool          peakDetected  = false;

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

// ─── Debug print helper (only prints text in DEBUG_MODE) ─────────────────────
void debugPrint(const char* msg) {
  if (DEBUG_MODE) Serial.println(msg);
}

void debugPrint(const String& msg) {
  if (DEBUG_MODE) Serial.println(msg);
}

// ─── SD Card Helpers ─────────────────────────────────────────────────────────

void initSDCard() {
  Serial.println("[SD] Initializing SD card...");
  // Deselect MAX30001 before talking to SD
  digitalWrite(MAX30001_CS_PIN, HIGH);

  if (SD.begin(SD_CS_PIN)) {
    sdAvailable = true;
    Serial.println("[SD] OK - SD card ready.");
  } else {
    sdAvailable = false;
    Serial.println("[SD] FAILED - Check wiring/card format.");
  }

  // Re-select MAX30001 for SPI
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

  // Build filename: ensure .csv extension and 8.3 format compliance
  snprintf(recordingFilename, sizeof(recordingFilename), "%s.csv", filename);

  // Deselect MAX30001 while talking to SD
  digitalWrite(MAX30001_CS_PIN, HIGH);

  dataFile = SD.open(recordingFilename, FILE_WRITE);

  // Re-select MAX30001
  digitalWrite(MAX30001_CS_PIN, LOW);

  if (dataFile) {
    // Write CSV header
    digitalWrite(MAX30001_CS_PIN, HIGH);
    dataFile.println("timestamp,ecg_raw,ecg_filtered,ecg_mv,heart_rate,status");
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

  // Deselect MAX30001 while talking to SD
  digitalWrite(MAX30001_CS_PIN, HIGH);
  dataFile.flush();
  dataFile.close();
  digitalWrite(MAX30001_CS_PIN, LOW);

  isRecording = false;

  Serial.println("[SD] Stopped. Samples: " + String(recordingSampleCount));
  statusCharacteristic.writeValue("REC_OFF");
}

void writeToSD(const char* timestamp, int32_t rawValue, int32_t filtered, float ecgMv, int hr, const char* status) {
  if (!isRecording) return;

  // Deselect MAX30001 while talking to SD
  digitalWrite(MAX30001_CS_PIN, HIGH);

  char line[128];
  snprintf(line, sizeof(line), "%s,%ld,%ld,%.6f,%d,%s",
    timestamp, (long)rawValue, (long)filtered, ecgMv, hr, status);
  dataFile.println(line);

  recordingSampleCount++;

  // Flush every 32 samples to balance performance and safety
  if (recordingSampleCount % 32 == 0) {
    dataFile.flush();
  }

  // Re-select MAX30001
  digitalWrite(MAX30001_CS_PIN, LOW);
}

// ─── BLE Command Handler ─────────────────────────────────────────────────────
void handleBLECommand(const String& cmd) {
  debugPrint("BLE Command: " + cmd);

  if (cmd.startsWith("START,")) {
    // Extract filename from "START,myfilename"
    String filename = cmd.substring(6);
    filename.trim();
    if (filename.length() == 0) {
      filename = "ecg_data";
    }
    // Sanitize: remove spaces, limit length to 8 chars for 8.3 format
    filename.replace(" ", "_");
    if (filename.length() > 8) {
      filename = filename.substring(0, 8);
    }

    char fnBuf[16];
    filename.toCharArray(fnBuf, sizeof(fnBuf));
    startRecording(fnBuf);

  } else if (cmd.startsWith("STOP")) {
    stopRecording();

  } else {
    debugPrint("Unknown command: " + cmd);
  }
}

// ─── Setup ───────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(1000);

  // ── CRITICAL: Configure CS pins as OUTPUT before ANY SPI use ──────────────
  // Without this, digitalWrite() has no effect and SD.begin() silently fails!
  pinMode(MAX30001_CS_PIN, OUTPUT);
  pinMode(SD_CS_PIN, OUTPUT);
  digitalWrite(MAX30001_CS_PIN, HIGH);  // Deselect MAX30001
  digitalWrite(SD_CS_PIN, HIGH);        // Deselect SD card

  debugPrint("=================================");
  debugPrint("  MAX30001 ECG - BLE + SD Card");
  debugPrint("  Arduino Nano 33 BLE");
  debugPrint("=================================");

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

  BLE.setLocalName("ECG_Nano33");
  BLE.setAdvertisedService(ecgService);
  ecgService.addCharacteristic(ecgCharacteristic);
  ecgService.addCharacteristic(statusCharacteristic);
  ecgService.addCharacteristic(commandCharacteristic);
  BLE.addService(ecgService);

  ecgCharacteristic.writeValue("{}");
  statusCharacteristic.writeValue("WAITING");
  BLE.advertise();

  debugPrint("Advertising as ECG_Nano33");
  debugPrint("Service:  12345678-1234-1234-1234-123456789ABC");
  debugPrint("ECG Char: 12345678-1234-1234-1234-123456789ABD");
  debugPrint("Cmd Char: 12345678-1234-1234-1234-123456789ABF");

  // ── MAX30001 Init ─────────────────────────────────────────────────────────
  SPI.begin();
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

  // ── Init filter buffers ───────────────────────────────────────────────────
  for (int i = 0; i < FILTER_SIZE; i++) filterBuffer[i] = 0;
  for (int i = 0; i < MEDIAN_SIZE; i++) medianBuffer[i] = 0;

  debugPrint("Ready! ECG streaming...");

  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, HIGH);

  delay(100);
}

// ─── Main Loop ───────────────────────────────────────────────────────────────
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
    // Auto-stop recording on disconnect to prevent data loss
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

  // ── ECG Sample Acquisition ────────────────────────────────────────────────
  max30001_ecg_sample_t ecgSample;
  max30001_error_t result = ecgSensor.getECGSample(&ecgSample);

  if (result == MAX30001_SUCCESS && ecgSample.sample_valid) {
    int32_t rawValue = ecgSample.ecg_sample;

    // ── Filtering pipeline ────────────────────────────────────────────────
    int32_t medianFiltered = medianFilter(rawValue);
    int32_t smoothed       = movingAverage(medianFiltered);
    baseline = (int32_t)(baseline * (1.0 - baselineAlpha) + smoothed * baselineAlpha);
    int32_t filtered = smoothed - baseline;

    // ── Peak detection ────────────────────────────────────────────────────
    detectPeak(filtered);

    // ── Serial output ─────────────────────────────────────────────────────
    if (DEBUG_MODE) {
      Serial.print("ECG:");
      Serial.print(filtered);
      Serial.print(",HR:");
      Serial.println(heartRate);
    } else {
      Serial.println(filtered);
    }

    // ── Timestamp ─────────────────────────────────────────────────────────
    char tsBuffer[32];
    millisToISO8601(millis(), tsBuffer, sizeof(tsBuffer));

    const char* peakStatus = peakDetected ? "peak" : "normal";

    // ── SD Card recording ─────────────────────────────────────────────────
    if (isRecording) {
      float ecgMv = (float)filtered / 65536.0f;
      writeToSD(tsBuffer, rawValue, filtered, ecgMv, heartRate, peakStatus);
    }

    // ── BLE send (only when connected) ────────────────────────────────────
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
    "{\"timestamp\":\"%s\",\"ecg_value\":%.6f,\"status\":\"%s\"}",
    timestamp, ecgFloat, status
  );

  ecgCharacteristic.writeValue(jsonBuffer);
}

// ─── Peak Detection ──────────────────────────────────────────────────────────
void detectPeak(int32_t value) {
  unsigned long now = millis();

  if (value > peakThreshold && !peakDetected) {
    if (now - lastPeakTime > 300) {
      peakInterval = now - lastPeakTime;
      lastPeakTime = now;
      if (peakInterval > 0) {
        heartRate = 60000 / peakInterval;
      }
    }
    peakDetected = true;
  }

  if (value < peakThreshold * 0.5) {
    peakDetected = false;
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
