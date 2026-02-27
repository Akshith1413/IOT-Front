// ═══════════════════════════════════════════════════════════════════════════════
//  Custom SPI Driver for nRF52840 (Arduino Nano 33 BLE)
//  Direct register-level access to SPIM0 peripheral
// ═══════════════════════════════════════════════════════════════════════════════

#ifndef CUSTOM_SPI_H
#define CUSTOM_SPI_H

#include <Arduino.h>

// ── SPI Mode definitions ─────────────────────────────────────────────────────
#define CUSTOM_SPI_MODE0 0  // CPOL=0, CPHA=0
#define CUSTOM_SPI_MODE1 1  // CPOL=0, CPHA=1
#define CUSTOM_SPI_MODE2 2  // CPOL=1, CPHA=0
#define CUSTOM_SPI_MODE3 3  // CPOL=1, CPHA=1

#define CUSTOM_SPI_MSBFIRST 0
#define CUSTOM_SPI_LSBFIRST 1

// ── SPISettings equivalent ───────────────────────────────────────────────────
struct CustomSPISettings {
  uint32_t clockFreq;
  uint8_t  bitOrder;
  uint8_t  spiMode;

  CustomSPISettings(uint32_t clock = 1000000, uint8_t order = CUSTOM_SPI_MSBFIRST, uint8_t mode = CUSTOM_SPI_MODE0)
    : clockFreq(clock), bitOrder(order), spiMode(mode) {}
};

// ── CustomSPI Class ──────────────────────────────────────────────────────────
// Drop-in replacement for Arduino SPIClass using nRF52840 SPIM0 registers
class CustomSPI {
public:
  CustomSPI();

  /// Initialize the SPIM0 peripheral with default pin assignment
  /// SCK = D13 (P0.13), MOSI = D11 (P0.01), MISO = D12 (P0.33)
  void begin();

  /// Shutdown SPIM0 peripheral
  void end();

  /// Configure SPI parameters (clock, bit order, mode)
  void beginTransaction(CustomSPISettings settings);

  /// End a transaction (currently a no-op, peripheral stays configured)
  void endTransaction();

  /// Full-duplex single-byte transfer
  uint8_t transfer(uint8_t data);

private:
  bool    _initialized;
  uint8_t _sckPin;
  uint8_t _mosiPin;
  uint8_t _misoPin;

  /// Map Arduino digital pin to nRF52840 GPIO number
  uint32_t _pinToGpio(uint8_t arduinoPin);

  /// Convert clock frequency to nRF SPIM frequency register value
  uint32_t _freqToRegValue(uint32_t freq);

  /// Convert SPI mode to nRF SPIM CONFIG register bits
  uint32_t _modeToConfig(uint8_t mode, uint8_t bitOrder);
};

// Global instance (like Arduino's SPI object)
extern CustomSPI customSPI;

#endif // CUSTOM_SPI_H
