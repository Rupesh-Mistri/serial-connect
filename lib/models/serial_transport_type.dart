enum SerialTransportType {
  usbOtg,
  ble,
  tcp,
  simulator;

  String get label {
    switch (this) {
      case SerialTransportType.usbOtg:
        return 'USB OTG';
      case SerialTransportType.ble:
        return 'Bluetooth LE (BLE)';
      case SerialTransportType.tcp:
        return 'WiFi / TCP Bridge';
      case SerialTransportType.simulator:
        return 'MCU Simulator';
    }
  }

  String get iconName {
    switch (this) {
      case SerialTransportType.usbOtg:
        return 'usb';
      case SerialTransportType.ble:
        return 'bluetooth';
      case SerialTransportType.tcp:
        return 'wifi';
      case SerialTransportType.simulator:
        return 'devices';
    }
  }
}
