# Serial Connect (Flutter)

A cross-platform Flutter application ported from the native Android [MCU Connect](file:///opt/mcu-connect) project, designed to work seamlessly on **Android** and **iOS** (as well as desktop/web environments).

---

## 🌟 Key Capabilities & Features

1. **Multi-Transport Serial Architecture (`SerialTransport` Interface)**:
   - **USB Serial (Android)**: Native Android USB Host implementation using [`usb-serial-for-android`](https://github.com/mik3y/usb-serial-for-android) via Flutter `MethodChannel` (`serial_connect/usb`) and `EventChannel` (`serial_connect/usb_stream`). Supports CP210x, CDC-ACM, FTDI, CH34x, and PL2303 chips.
   - **BLE Serial (Android & iOS)**: Nordic UART Service (NUS) Bluetooth Low Energy serial communication via `flutter_blue_plus`.
   - **TCP Serial (Android, iOS & Desktop)**: Network socket-based serial bridges (e.g., ESP-Link, telnet serial servers).
   - **Mock Serial**: In-memory loopback transport for unit and widget testing without physical hardware.

2. **MCU Firmware Flashing Engine**:
   - **ESP32 Flashing Protocol**:
     - ROM Bootloader synchronization (`0x08` sync sequence).
     - SPI attach, parameter configuration, memory flashing (`FLASH_BEGIN`, `FLASH_DATA`, `FLASH_END`), and software reboot.
   - **AVR / Arduino Flashing Protocol (STK500v1)**:
     - Optiboot / STK500v1 synchronization (`Cmnd_STK_GET_SYNC`).
     - Device signature checks, extended parameters, page-by-page flash programming (`Cmnd_STK_PROG_PAGE`), and exit bootloader.
   - **Intel HEX Parser**:
     - Complete Intel HEX record parser (`00` data, `01` EOF, `02` extended segment, `04` extended linear address).
     - Binary alignment and padding for 128-byte flash page boundaries.
   - **Dynamic Firmware Customization**:
     - Binary marker injection for `MASTER_ID` (replacing placeholder markers in pre-compiled binary images).

3. **In-App WebView & JavaScript Serial Bridge**:
   - Built-in browser with `AndroidView` / `WKWebView` support.
   - Injected JavaScript bridge `window.AndroidSerial` and `window.FlutterSerial` compatible with existing Web-to-MCU interfaces (such as `demo_serial.html`).

---

## 📁 Architecture Overview

```
lib/
├── main.dart                          # App initialization, routes, theme
├── models/
│   └── serial_transport_type.dart     # Transport enum (usb, ble, tcp, mock)
├── services/
│   ├── flasher/
│   │   ├── avr_flasher.dart           # STK500v1 AVR/Arduino bootloader protocol
│   │   ├── esp32_flasher.dart         # ESP32 ROM bootloader SLIP protocol
│   │   ├── firmware_generator.dart    # Binary firmware marker customization
│   │   └── intel_hex_parser.dart      # Intel HEX record decoder
│   ├── serial/
│   │   ├── ble_serial_transport.dart  # Nordic UART BLE transport (iOS & Android)
│   │   ├── mock_serial_transport.dart # Simulated serial transport for testing
│   │   ├── serial_manager.dart        # Transport manager & singleton hub
│   │   ├── serial_transport.dart      # Common transport interface
│   │   ├── tcp_serial_transport.dart  # TCP socket serial transport
│   │   └── usb_serial_transport.dart  # Android USB Host platform channel
│   └── serial_manager.dart            # Export helper
└── ui/
    ├── browser_screen.dart            # WebView interface with JS Serial bridge
    ├── flasher_screen.dart            # MCU Flasher UI (ESP32/AVR, baud rate, logs)
    └── transport_dialog.dart          # Transport selection & configuration modal
```

---

## 📱 Platform Configuration

### Android
- **USB Host Permissions**: `android.hardware.usb.host` feature enabled in [`AndroidManifest.xml`](file:///opt/serial-connect/android/app/src/main/AndroidManifest.xml).
- **Device Filter**: [`device_filter.xml`](file:///opt/serial-connect/android/app/src/main/res/xml/device_filter.xml) configured with vendor IDs for FTDI, Silicon Labs CP210x, Qinheng CH340/CH341, and Prolific PL2303.
- **Native Implementation**: Kotlin platform channel bridge in [`MainActivity.kt`](file:///opt/serial-connect/android/app/src/main/kotlin/com/mcu/serialconnect/serial_connect/MainActivity.kt).

### iOS
- **Bluetooth Permissions**: Configured in [`Info.plist`](file:///opt/serial-connect/ios/Runner/Info.plist):
  - `NSBluetoothAlwaysUsageDescription`
  - `NSBluetoothPeripheralUsageDescription`

---

## 🧪 Testing & Verification

Run tests:
```bash
flutter test
```

Run static analysis:
```bash
flutter analyze
```

Compile Android native target:
```bash
cd android && ./gradlew compileDebugKotlin
```
