// ═══════════════════════════════════════════════════════════════════════════════
//  ESP32 ECG Simulator & Dataset Replay Module
//  Connects to Arduino Nano 33 BLE via UART (Serial2: TX=17, RX=16)
// ═══════════════════════════════════════════════════════════════════════════════
//
//  This ESP32 receives commands from the Nano 33 BLE over serial and responds
//  by generating synthetic ECG waveforms (simulation mode) or streaming stored
//  dataset arrays (replay mode).
//
//  Commands received (newline-terminated):
//    SIM_START,<class>   — Start simulation for class N, S, V, F, or Q
//    SIM_STOP            — Stop simulation
//    REPLAY_START,<id>   — Start replay of dataset <id> (0..N)
//    REPLAY_STOP         — Stop replay
//    REPLAY_LIST         — List available datasets
//    PING                — Health check (responds PONG)
//
//  Data sent (newline-terminated):
//    ECG:<value>         — One ECG sample (int32_t, same scale as MAX30003)
//    DATASETS:<json>     — JSON array of available dataset names
//    PONG                — Response to PING
//    STATUS:<msg>        — Status messages
//
//  Sampling rate: ~128 Hz (7.8125 ms per sample)
// ═══════════════════════════════════════════════════════════════════════════════

#include <Arduino.h>

// ─── UART to Nano 33 BLE ─────────────────────────────────────────────────────
// ESP32 Serial2: TX=GPIO17, RX=GPIO16
// Connect ESP32 TX(17) → Nano RX(0), ESP32 RX(16) → Nano TX(1), GND → GND
#define NANO_SERIAL Serial2
#define NANO_BAUD   115200
#define NANO_TX_PIN 17
#define NANO_RX_PIN 16

// ─── Sampling ────────────────────────────────────────────────────────────────
#define SAMPLE_RATE_HZ    128
#define SAMPLE_INTERVAL_US (1000000UL / SAMPLE_RATE_HZ)  // ~7813 us

// ─── Operating Modes ─────────────────────────────────────────────────────────
enum Mode {
  MODE_IDLE,
  MODE_SIMULATE,
  MODE_REPLAY
};

Mode currentMode = MODE_IDLE;
int  currentSimClass = 0;  // 0=N, 1=S, 2=V, 3=F, 4=Q
int  currentDatasetId = 0;

// ─── Timing ──────────────────────────────────────────────────────────────────
unsigned long lastSampleTime_us = 0;
unsigned long sampleIndex = 0;

// ─── Command buffer ──────────────────────────────────────────────────────────
String cmdBuffer = "";

// ═══════════════════════════════════════════════════════════════════════════════
//  ECG Waveform Generation — Synthetic signals for each arrhythmia class
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Each function generates ONE sample value (int32_t) at ~128 Hz.
//  The output scale matches the MAX30003 filtered output so that the Nano's
//  existing pipeline (median filter, moving average, baseline removal, peak
//  detection, AI inference) processes them identically.
//
//  Waveform models:
//    N — Normal sinus rhythm: clean P-QRS-T at ~72 BPM
//    S — Supraventricular ectopic: premature narrow QRS at ~95 BPM (irregular)
//    V — Ventricular ectopic: wide QRS, tall T at ~60 BPM
//    F — Fusion: mix of normal and ventricular morphology
//    Q — Unknown/noisy: baseline wander + noise bursts
// ═══════════════════════════════════════════════════════════════════════════════

// Helper: Gaussian bump
float gaussian(float x, float mu, float sigma) {
  float d = (x - mu) / sigma;
  return exp(-0.5f * d * d);
}

// Helper: Random noise
float noise(float amplitude) {
  return amplitude * ((float)random(-1000, 1001) / 1000.0f);
}

// ─── Normal Sinus Rhythm (N) ─────────────────────────────────────────────────
// Clean P-QRS-T morphology, ~72 BPM → period ~1.11s → ~142 samples at 128 Hz
int32_t generateNormal(unsigned long idx) {
  float period = 142.0f;  // ~72 BPM
  float phase = fmod((float)idx, period) / period;  // 0..1
  
  float value = 0.0f;
  
  // P wave (small, positive)
  value += 0.08f * gaussian(phase, 0.12f, 0.03f);
  
  // Q wave (small negative dip before R)
  value -= 0.05f * gaussian(phase, 0.28f, 0.012f);
  
  // R wave (tall, sharp peak)
  value += 1.0f * gaussian(phase, 0.32f, 0.015f);
  
  // S wave (negative dip after R)
  value -= 0.15f * gaussian(phase, 0.36f, 0.014f);
  
  // T wave (broad, positive)
  value += 0.20f * gaussian(phase, 0.55f, 0.05f);
  
  // Small noise
  value += noise(0.01f);
  
  // Scale to MAX30003 range (~65536 counts per mV)
  return (int32_t)(value * 50000.0f);
}

// ─── Supraventricular Ectopic (S) ────────────────────────────────────────────
// Premature narrow QRS with irregular rhythm, alternating normal and early beats
int32_t generateSupraVE(unsigned long idx) {
  // Alternating: normal beat (~142 samples) then premature beat (~100 samples)
  float cycle = 242.0f;  // total cycle for beat pair
  float pos = fmod((float)idx, cycle);
  float value = 0.0f;
  
  if (pos < 142.0f) {
    // Normal beat
    float phase = pos / 142.0f;
    value += 0.07f * gaussian(phase, 0.12f, 0.03f);
    value -= 0.04f * gaussian(phase, 0.28f, 0.012f);
    value += 0.95f * gaussian(phase, 0.32f, 0.015f);
    value -= 0.12f * gaussian(phase, 0.36f, 0.014f);
    value += 0.18f * gaussian(phase, 0.55f, 0.05f);
  } else {
    // Premature SVE beat: smaller P, narrow QRS, reduced T
    float phase = (pos - 142.0f) / 100.0f;
    // Absent or inverted P
    value -= 0.03f * gaussian(phase, 0.10f, 0.02f);
    // Narrow but slightly different QRS
    value -= 0.03f * gaussian(phase, 0.30f, 0.012f);
    value += 0.80f * gaussian(phase, 0.34f, 0.014f);
    value -= 0.10f * gaussian(phase, 0.38f, 0.013f);
    // Reduced T wave
    value += 0.10f * gaussian(phase, 0.58f, 0.045f);
  }
  
  value += noise(0.012f);
  return (int32_t)(value * 50000.0f);
}

// ─── Ventricular Ectopic (V) ─────────────────────────────────────────────────
// Wide, bizarre QRS with discordant T wave, ~60 BPM
int32_t generateVentricE(unsigned long idx) {
  float period = 170.0f;  // ~60 BPM (slower)
  float phase = fmod((float)idx, period) / period;
  float value = 0.0f;
  
  // No P wave (ventricular origin bypasses atria)
  
  // Wide QRS complex — much broader than normal
  value -= 0.1f * gaussian(phase, 0.25f, 0.02f);   // Q: deeper
  value += 1.2f * gaussian(phase, 0.32f, 0.035f);   // R: wide peak (sigma 0.035 vs 0.015)
  value -= 0.25f * gaussian(phase, 0.42f, 0.025f);  // S: deeper, wider
  
  // Discordant T wave (opposite direction to QRS)
  value -= 0.30f * gaussian(phase, 0.62f, 0.06f);
  
  // More baseline wander
  value += 0.04f * sin(2.0f * PI * phase * 2.3f);
  
  value += noise(0.015f);
  return (int32_t)(value * 50000.0f);
}

// ─── Fusion Beat (F) ─────────────────────────────────────────────────────────
// Mix of normal and ventricular: intermediate QRS width, hybrid morphology
int32_t generateFusion(unsigned long idx) {
  float period = 155.0f;  // ~75 BPM
  float phase = fmod((float)idx, period) / period;
  float value = 0.0f;
  
  // Small P wave (partially present — sinus impulse arrives)
  value += 0.04f * gaussian(phase, 0.12f, 0.025f);
  
  // Intermediate QRS — not as wide as V, not as narrow as N
  value -= 0.07f * gaussian(phase, 0.27f, 0.016f);
  value += 1.05f * gaussian(phase, 0.32f, 0.025f);  // Width between N and V
  value -= 0.18f * gaussian(phase, 0.39f, 0.019f);
  
  // T wave: partially discordant (mix of normal and VE T)
  value += 0.08f * gaussian(phase, 0.55f, 0.05f);
  value -= 0.10f * gaussian(phase, 0.60f, 0.04f);
  
  value += noise(0.013f);
  return (int32_t)(value * 50000.0f);
}

// ─── Unknown / Unclassifiable (Q) ────────────────────────────────────────────
// Noisy, irregular, with baseline wander and artifact bursts
int32_t generateUnknown(unsigned long idx) {
  float t = (float)idx / (float)SAMPLE_RATE_HZ;  // time in seconds
  float value = 0.0f;
  
  // Irregular pseudo-QRS at varying intervals
  float period = 128.0f + 30.0f * sin(t * 0.7f);  // Variable rate
  float phase = fmod((float)idx, period) / period;
  
  // Distorted QRS
  value += 0.6f * gaussian(phase, 0.35f, 0.025f);
  value -= 0.15f * gaussian(phase, 0.42f, 0.02f);
  
  // Heavy baseline wander
  value += 0.15f * sin(2.0f * PI * t * 0.3f);
  value += 0.08f * sin(2.0f * PI * t * 0.15f);
  
  // Muscle artifact bursts
  if (fmod(t, 3.5f) < 0.8f) {
    value += noise(0.12f);
  }
  
  // 60 Hz powerline interference
  value += 0.05f * sin(2.0f * PI * t * 60.0f);
  
  value += noise(0.04f);
  return (int32_t)(value * 50000.0f);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Dataset Replay — Embedded MIT-BIH Excerpts
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Each dataset is a PROGMEM array of int32_t samples at 128 Hz.
//  These are representative excerpts; in production, you can extend with:
//    - More/larger arrays uploaded via SPIFFS/LittleFS
//    - SD card-based datasets
//    - OTA dataset upload from Flutter app
//
//  For demonstration, we include short synthetic dataset excerpts (~2 seconds
//  each = 256 samples) that mimic MIT-BIH record characteristics.
// ═══════════════════════════════════════════════════════════════════════════════

// Dataset 0: MIT-BIH Record 100 excerpt (Normal rhythm)
const int32_t PROGMEM dataset_100[] = {
  // ~2 seconds of normal sinus rhythm at 128 Hz (256 samples)
  // Pre-generated with the Normal generator, stored as constants
     0,   200,   450,   700,   950,  1150,  1300,  1350,
  1300,  1150,   900,   650,   400,   200,    50,  -100,
  -150,  -100,     0,   100,   250,   500,   800,  1200,
  1800,  2800,  5000, 10000, 22000, 38000, 48000, 45000,
 32000, 18000,  8000,  2000,  -500, -2500, -4500, -6000,
 -6500, -6000, -5000, -3500, -2000,  -800,   100,   800,
  1400,  1800,  2200,  2600,  3000,  3400,  3700,  4000,
  4200,  4300,  4300,  4200,  4000,  3700,  3300,  2900,
  2500,  2100,  1700,  1300,  1000,   750,   550,   400,
   300,   200,   150,   100,    50,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,   200,   450,   700,   950,  1150,  1300,  1350,
  1300,  1150,   900,   650,   400,   200,    50,  -100,
  -150,  -100,     0,   100,   250,   500,   800,  1200,
  1800,  2800,  5000, 10000, 22000, 38000, 48000, 45000,
 32000, 18000,  8000,  2000,  -500, -2500, -4500, -6000,
 -6500, -6000, -5000, -3500, -2000,  -800,   100,   800,
  1400,  1800,  2200,  2600,  3000,  3400,  3700,  4000,
  4200,  4300,  4300,  4200,  4000,  3700,  3300,  2900,
  2500,  2100,  1700,  1300,  1000,   750,   550,   400,
   300,   200,   150,   100,    50,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
};
const int dataset_100_len = sizeof(dataset_100) / sizeof(dataset_100[0]);

// Dataset 1: MIT-BIH Record 200 excerpt (Ventricular ectopy)
const int32_t PROGMEM dataset_200[] = {
     0,   100,   250,   400,   550,   650,   700,   650,
   550,   400,   250,   100,     0,  -100,  -150,  -100,
     0,   200,   500,  1000,  1800,  3000,  5500, 12000,
 25000, 42000, 55000, 58000, 52000, 38000, 22000, 10000,
  3000,  -500, -4000, -8000,-12000,-14000,-13000,-10000,
 -6500, -3000,  -500,  1500,  3000,  4000,  4500,  4500,
  4000,  3200,  2200,  1200,   500,     0,  -400,  -600,
  -700,  -600,  -400,  -200,     0,   200,   400,   500,
   500,   400,   300,   200,   100,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,   100,   200,   350,   500,   700,   900,  1200,
  1600,  2200,  3500,  6000, 12000, 22000, 35000, 48000,
 55000, 52000, 42000, 28000, 16000,  8000,  3000,   500,
 -1500, -3500, -5500, -7000, -7500, -7000, -5500, -3500,
 -1500,   100,  1200,  2000,  2500,  2800,  2800,  2500,
  2000,  1500,  1000,   600,   300,   100,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
     0,     0,     0,     0,     0,     0,     0,     0,
};
const int dataset_200_len = sizeof(dataset_200) / sizeof(dataset_200[0]);

// ─── Dataset registry ────────────────────────────────────────────────────────
struct DatasetEntry {
  const char* name;
  const int32_t* data;
  int length;
};

#define NUM_DATASETS 2

DatasetEntry datasets[NUM_DATASETS] = {
  { "MIT-BIH_100_Normal",   dataset_100, dataset_100_len },
  { "MIT-BIH_200_VentricE", dataset_200, dataset_200_len },
};

int replayIndex = 0;  // Current position in the replaying dataset

// ═══════════════════════════════════════════════════════════════════════════════
//  Generate one ECG sample based on current mode and class
// ═══════════════════════════════════════════════════════════════════════════════
int32_t generateSample() {
  switch (currentSimClass) {
    case 0: return generateNormal(sampleIndex);
    case 1: return generateSupraVE(sampleIndex);
    case 2: return generateVentricE(sampleIndex);
    case 3: return generateFusion(sampleIndex);
    case 4: return generateUnknown(sampleIndex);
    default: return generateNormal(sampleIndex);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Command Processing
// ═══════════════════════════════════════════════════════════════════════════════
void processCommand(String cmd) {
  cmd.trim();
  Serial.print("[ESP32] Received command: ");
  Serial.println(cmd);
  
  if (cmd == "PING") {
    NANO_SERIAL.println("PONG");
    Serial.println("[ESP32] Sent PONG");
    
  } else if (cmd.startsWith("SIM_START,")) {
    String classStr = cmd.substring(10);
    classStr.trim();
    
    int classId = -1;
    if (classStr == "N") classId = 0;
    else if (classStr == "S") classId = 1;
    else if (classStr == "V") classId = 2;
    else if (classStr == "F") classId = 3;
    else if (classStr == "Q") classId = 4;
    
    if (classId >= 0) {
      currentMode = MODE_SIMULATE;
      currentSimClass = classId;
      sampleIndex = 0;
      lastSampleTime_us = micros();
      
      NANO_SERIAL.println("STATUS:SIM_STARTED");
      Serial.print("[ESP32] Simulation started for class: ");
      Serial.println(classStr);
    } else {
      NANO_SERIAL.println("STATUS:INVALID_CLASS");
      Serial.println("[ESP32] Invalid class: " + classStr);
    }
    
  } else if (cmd == "SIM_STOP") {
    currentMode = MODE_IDLE;
    NANO_SERIAL.println("STATUS:SIM_STOPPED");
    Serial.println("[ESP32] Simulation stopped");
    
  } else if (cmd.startsWith("REPLAY_START,")) {
    String idStr = cmd.substring(13);
    idStr.trim();
    int id = idStr.toInt();
    
    if (id >= 0 && id < NUM_DATASETS) {
      currentMode = MODE_REPLAY;
      currentDatasetId = id;
      replayIndex = 0;
      sampleIndex = 0;
      lastSampleTime_us = micros();
      
      NANO_SERIAL.println("STATUS:REPLAY_STARTED");
      Serial.print("[ESP32] Replay started: ");
      Serial.println(datasets[id].name);
    } else {
      NANO_SERIAL.println("STATUS:INVALID_DATASET");
      Serial.println("[ESP32] Invalid dataset ID: " + idStr);
    }
    
  } else if (cmd == "REPLAY_STOP") {
    currentMode = MODE_IDLE;
    NANO_SERIAL.println("STATUS:REPLAY_STOPPED");
    Serial.println("[ESP32] Replay stopped");
    
  } else if (cmd == "REPLAY_LIST") {
    // Send dataset list as JSON
    String json = "DATASETS:[";
    for (int i = 0; i < NUM_DATASETS; i++) {
      json += "{\"id\":" + String(i) + ",\"name\":\"" + String(datasets[i].name) + "\",\"samples\":" + String(datasets[i].length) + "}";
      if (i < NUM_DATASETS - 1) json += ",";
    }
    json += "]";
    NANO_SERIAL.println(json);
    Serial.println("[ESP32] Sent dataset list");
    
  } else {
    Serial.println("[ESP32] Unknown command: " + cmd);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Setup
// ═══════════════════════════════════════════════════════════════════════════════
void setup() {
  // Debug serial (USB)
  Serial.begin(115200);
  delay(500);
  
  // UART to Nano 33 BLE
  NANO_SERIAL.begin(NANO_BAUD, SERIAL_8N1, NANO_RX_PIN, NANO_TX_PIN);
  
  Serial.println("═══════════════════════════════════════════");
  Serial.println("  ESP32 ECG Simulator & Replay Module");
  Serial.println("  UART: TX=GPIO17, RX=GPIO16");
  Serial.println("  Baud: 115200");
  Serial.println("═══════════════════════════════════════════");
  Serial.println("[ESP32] Ready. Waiting for commands from Nano...");
  
  // Seed random for noise generation
  randomSeed(analogRead(0));
  
  lastSampleTime_us = micros();
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Main Loop
// ═══════════════════════════════════════════════════════════════════════════════
void loop() {
  // ── Check for incoming commands from Nano ──────────────────────────────────
  while (NANO_SERIAL.available()) {
    char c = NANO_SERIAL.read();
    if (c == '\n' || c == '\r') {
      if (cmdBuffer.length() > 0) {
        processCommand(cmdBuffer);
        cmdBuffer = "";
      }
    } else {
      cmdBuffer += c;
      // Prevent buffer overflow
      if (cmdBuffer.length() > 128) {
        cmdBuffer = "";
      }
    }
  }
  
  // ── Generate/replay ECG samples at 128 Hz ─────────────────────────────────
  if (currentMode != MODE_IDLE) {
    unsigned long now_us = micros();
    if (now_us - lastSampleTime_us >= SAMPLE_INTERVAL_US) {
      lastSampleTime_us += SAMPLE_INTERVAL_US;
      
      // Handle timer overflow gracefully
      if (now_us - lastSampleTime_us > SAMPLE_INTERVAL_US * 10) {
        lastSampleTime_us = now_us;
      }
      
      int32_t sample = 0;
      
      if (currentMode == MODE_SIMULATE) {
        sample = generateSample();
        
      } else if (currentMode == MODE_REPLAY) {
        if (currentDatasetId >= 0 && currentDatasetId < NUM_DATASETS) {
          const DatasetEntry& ds = datasets[currentDatasetId];
          // Read from PROGMEM
          sample = pgm_read_dword(&ds.data[replayIndex]);
          replayIndex++;
          // Loop replay when reaching end
          if (replayIndex >= ds.length) {
            replayIndex = 0;
          }
        }
      }
      
      // Send sample to Nano
      NANO_SERIAL.print("ECG:");
      NANO_SERIAL.println(sample);
      
      sampleIndex++;
    }
  }
}
