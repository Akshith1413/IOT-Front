// ═══════════════════════════════════════════════════════════════════════════════
//  Custom SPI Driver — nRF52840 SPIM0 Register-Level Implementation
// ═══════════════════════════════════════════════════════════════════════════════
//
//  Replaces Arduino SPI.h with direct nRF52840 hardware register access.
//  Uses the SPIM0 (SPI Master with EasyDMA) peripheral.
//
//  Reference: nRF52840 Product Specification, Section 6.23 (SPIM)
//  Register base address: 0x40003000 (SPIM0 / SPI0)
//
// ═══════════════════════════════════════════════════════════════════════════════

#include "custom_spi.h"
#include <nrf.h>    // nRF52840 register definitions (NRF_SPIM0, etc.)

// ─── Global instance ─────────────────────────────────────────────────────────
CustomSPI customSPI;

// ─── Pin mapping: Arduino Nano 33 BLE digital pins → nRF52840 GPIO ──────────
//  D11 (MOSI) = P0.13  → GPIO 13
//  D12 (MISO) = P1.01  → GPIO 33  (32 + 1)
//  D13 (SCK)  = P0.14  → GPIO 14
//
//  Note: nRF52840 uses P0.xx (0-31) and P1.xx (32-47)
//  The Arduino variant file maps these; we hardcode for Nano 33 BLE board.

// nRF GPIO numbers for Arduino Nano 33 BLE SPI pins
#define NRF_SCK_GPIO   14   // P0.14 = Arduino D13
#define NRF_MOSI_GPIO  13   // P0.13 = Arduino D11
#define NRF_MISO_GPIO  33   // P1.01 = Arduino D12

// ═══════════════════════════════════════════════════════════════════════════════
//  Constructor
// ═══════════════════════════════════════════════════════════════════════════════

CustomSPI::CustomSPI()
  : _initialized(false), _sckPin(13), _mosiPin(11), _misoPin(12) {}

// ═══════════════════════════════════════════════════════════════════════════════
//  begin() — Initialize SPIM0 peripheral
// ═══════════════════════════════════════════════════════════════════════════════

void CustomSPI::begin() {
  if (_initialized) return;

  // ── Step 1: Disable SPIM0 before configuration ────────────────────────────
  NRF_SPIM0->ENABLE = (SPIM_ENABLE_ENABLE_Disabled << SPIM_ENABLE_ENABLE_Pos);

  // ── Step 2: Configure GPIO pins ───────────────────────────────────────────
  // SCK: output
  nrf_gpio_cfg_output(NRF_SCK_GPIO);
  nrf_gpio_pin_clear(NRF_SCK_GPIO);   // Idle low (Mode 0)

  // MOSI: output
  nrf_gpio_cfg_output(NRF_MOSI_GPIO);
  nrf_gpio_pin_clear(NRF_MOSI_GPIO);

  // MISO: input with pull-down
  nrf_gpio_cfg_input(NRF_MISO_GPIO, NRF_GPIO_PIN_NOPULL);

  // ── Step 3: Assign pins to SPIM0 peripheral ───────────────────────────────
  NRF_SPIM0->PSEL.SCK  = NRF_SCK_GPIO;
  NRF_SPIM0->PSEL.MOSI = NRF_MOSI_GPIO;
  NRF_SPIM0->PSEL.MISO = NRF_MISO_GPIO;

  // ── Step 4: Default configuration — 1 MHz, MSB first, Mode 0 ─────────────
  NRF_SPIM0->FREQUENCY = SPIM_FREQUENCY_FREQUENCY_M1;  // 1 MHz
  NRF_SPIM0->CONFIG    = (SPIM_CONFIG_ORDER_MsbFirst << SPIM_CONFIG_ORDER_Pos) |
                          (SPIM_CONFIG_CPHA_Leading   << SPIM_CONFIG_CPHA_Pos)  |
                          (SPIM_CONFIG_CPOL_ActiveHigh << SPIM_CONFIG_CPOL_Pos);

  // ── Step 5: Configure ORC (Over-Read Character) — sent when RX only ───────
  NRF_SPIM0->ORC = 0xFF;

  // ── Step 6: Enable SPIM0 ──────────────────────────────────────────────────
  NRF_SPIM0->ENABLE = (SPIM_ENABLE_ENABLE_Enabled << SPIM_ENABLE_ENABLE_Pos);

  _initialized = true;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  end() — Disable SPIM0
// ═══════════════════════════════════════════════════════════════════════════════

void CustomSPI::end() {
  if (!_initialized) return;

  NRF_SPIM0->ENABLE = (SPIM_ENABLE_ENABLE_Disabled << SPIM_ENABLE_ENABLE_Pos);

  // Disconnect pins
  NRF_SPIM0->PSEL.SCK  = SPIM_PSEL_SCK_CONNECT_Disconnected;
  NRF_SPIM0->PSEL.MOSI = SPIM_PSEL_MOSI_CONNECT_Disconnected;
  NRF_SPIM0->PSEL.MISO = SPIM_PSEL_MISO_CONNECT_Disconnected;

  _initialized = false;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  beginTransaction() — Configure SPI parameters
// ═══════════════════════════════════════════════════════════════════════════════

void CustomSPI::beginTransaction(CustomSPISettings settings) {
  if (!_initialized) begin();

  // Disable while reconfiguring
  NRF_SPIM0->ENABLE = (SPIM_ENABLE_ENABLE_Disabled << SPIM_ENABLE_ENABLE_Pos);

  // Set frequency
  NRF_SPIM0->FREQUENCY = _freqToRegValue(settings.clockFreq);

  // Set mode and bit order
  NRF_SPIM0->CONFIG = _modeToConfig(settings.spiMode, settings.bitOrder);

  // Re-enable
  NRF_SPIM0->ENABLE = (SPIM_ENABLE_ENABLE_Enabled << SPIM_ENABLE_ENABLE_Pos);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  endTransaction() — End SPI transaction
// ═══════════════════════════════════════════════════════════════════════════════

void CustomSPI::endTransaction() {
  // No-op: peripheral stays configured between transactions
  // CS pin management is handled by the calling code
}

// ═══════════════════════════════════════════════════════════════════════════════
//  transfer() — Full-duplex single-byte exchange via SPIM0 EasyDMA
// ═══════════════════════════════════════════════════════════════════════════════
//
//  The nRF52840 SPIM uses EasyDMA, which requires RAM-based buffers.
//  We use single-byte static buffers for compatibility with the MAX30001
//  library's byte-at-a-time transfer pattern.

uint8_t CustomSPI::transfer(uint8_t data) {
  // EasyDMA buffers MUST be in RAM (not flash/stack in some edge cases)
  static uint8_t txBuf;
  static uint8_t rxBuf;

  txBuf = data;
  rxBuf = 0;

  // ── Point DMA to our buffers ──────────────────────────────────────────────
  NRF_SPIM0->TXD.PTR    = (uint32_t)&txBuf;
  NRF_SPIM0->TXD.MAXCNT = 1;
  NRF_SPIM0->RXD.PTR    = (uint32_t)&rxBuf;
  NRF_SPIM0->RXD.MAXCNT = 1;

  // ── Clear the END event ───────────────────────────────────────────────────
  NRF_SPIM0->EVENTS_END = 0;

  // ── Start the transfer ────────────────────────────────────────────────────
  NRF_SPIM0->TASKS_START = 1;

  // ── Wait for transfer to complete (polling) ───────────────────────────────
  while (NRF_SPIM0->EVENTS_END == 0) {
    // Spin — single byte takes ~8 µs at 1 MHz, well within tolerance
  }

  // ── Clear event for next transfer ─────────────────────────────────────────
  NRF_SPIM0->EVENTS_END = 0;

  return rxBuf;
}

// ═══════════════════════════════════════════════════════════════════════════════
//  Private helpers
// ═══════════════════════════════════════════════════════════════════════════════

uint32_t CustomSPI::_pinToGpio(uint8_t arduinoPin) {
  // Arduino Nano 33 BLE specific mapping
  switch (arduinoPin) {
    case 11: return NRF_MOSI_GPIO;
    case 12: return NRF_MISO_GPIO;
    case 13: return NRF_SCK_GPIO;
    default: return arduinoPin;  // Fallback
  }
}

uint32_t CustomSPI::_freqToRegValue(uint32_t freq) {
  // nRF52840 SPIM frequency register values (from datasheet Table 121)
  if (freq >= 8000000) return SPIM_FREQUENCY_FREQUENCY_M8;   // 8 MHz
  if (freq >= 4000000) return SPIM_FREQUENCY_FREQUENCY_M4;   // 4 MHz
  if (freq >= 2000000) return SPIM_FREQUENCY_FREQUENCY_M2;   // 2 MHz
  if (freq >= 1000000) return SPIM_FREQUENCY_FREQUENCY_M1;   // 1 MHz
  if (freq >= 500000)  return SPIM_FREQUENCY_FREQUENCY_K500;  // 500 kHz
  if (freq >= 250000)  return SPIM_FREQUENCY_FREQUENCY_K250;  // 250 kHz
  return SPIM_FREQUENCY_FREQUENCY_K125;                       // 125 kHz
}

uint32_t CustomSPI::_modeToConfig(uint8_t mode, uint8_t bitOrder) {
  uint32_t config = 0;

  // Bit order
  if (bitOrder == CUSTOM_SPI_LSBFIRST) {
    config |= (SPIM_CONFIG_ORDER_LsbFirst << SPIM_CONFIG_ORDER_Pos);
  } else {
    config |= (SPIM_CONFIG_ORDER_MsbFirst << SPIM_CONFIG_ORDER_Pos);
  }

  // SPI Mode (CPOL + CPHA)
  switch (mode) {
    case CUSTOM_SPI_MODE0:  // CPOL=0, CPHA=0 (sample on leading/rising edge)
      config |= (SPIM_CONFIG_CPOL_ActiveHigh << SPIM_CONFIG_CPOL_Pos);
      config |= (SPIM_CONFIG_CPHA_Leading    << SPIM_CONFIG_CPHA_Pos);
      break;
    case CUSTOM_SPI_MODE1:  // CPOL=0, CPHA=1 (sample on trailing/falling edge)
      config |= (SPIM_CONFIG_CPOL_ActiveHigh << SPIM_CONFIG_CPOL_Pos);
      config |= (SPIM_CONFIG_CPHA_Trailing   << SPIM_CONFIG_CPHA_Pos);
      break;
    case CUSTOM_SPI_MODE2:  // CPOL=1, CPHA=0
      config |= (SPIM_CONFIG_CPOL_ActiveLow  << SPIM_CONFIG_CPOL_Pos);
      config |= (SPIM_CONFIG_CPHA_Leading    << SPIM_CONFIG_CPHA_Pos);
      break;
    case CUSTOM_SPI_MODE3:  // CPOL=1, CPHA=1
      config |= (SPIM_CONFIG_CPOL_ActiveLow  << SPIM_CONFIG_CPOL_Pos);
      config |= (SPIM_CONFIG_CPHA_Trailing   << SPIM_CONFIG_CPHA_Pos);
      break;
  }

  return config;
}
