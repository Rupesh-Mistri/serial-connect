import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;

class FirmwareGenerator {
  static const String defaultMasterIdMarker = 'DDE000VW0003';
  static const String defaultAssetFirmware = 'assets/firmware/esp32_readout_v1.0.bin';

  /// Loads raw binary bytes from Flutter assets
  static Future<Uint8List> loadAssetFirmware([String assetPath = defaultAssetFirmware]) async {
    final byteData = await rootBundle.load(assetPath);
    return byteData.buffer.asUint8List();
  }

  /// Converts a user-selected C++/Arduino source file (.cpp, .ino) into a ready-to-flash binary on-device.
  static Future<Uint8List> convertSourceToFirmware(String sourceFileName, String sourceCode) async {
    final baseBinary = await loadAssetFirmware();

    if (sourceCode.trim().isEmpty) {
      return baseBinary;
    }

    // Search for #define MASTER_ID "..." in source code
    final pattern = RegExp('#define\\s+MASTER_ID\\s+["\']([^"\']+)["\']');
    final match = pattern.firstMatch(sourceCode);
    if (match != null) {
      final extractedMasterId = match.group(1);
      if (extractedMasterId != null) {
        return customizeMasterId(baseBinary, extractedMasterId);
      }
    }

    return baseBinary;
  }

  /// Dynamically updates/patches the Master ID marker string inside the ESP32 binary byte array on-device.
  static Uint8List customizeMasterId(Uint8List originalBytes, String newMasterId) {
    if (originalBytes.isEmpty || newMasterId.trim().isEmpty) {
      return originalBytes;
    }

    final searchMarker = ascii.encode(defaultMasterIdMarker);
    var newMarker = ascii.encode(newMasterId);

    if (newMarker.length > searchMarker.length) {
      newMarker = newMarker.sublist(0, searchMarker.length);
    } else if (newMarker.length < searchMarker.length) {
      final padded = Uint8List(searchMarker.length);
      padded.setRange(0, newMarker.length, newMarker);
      newMarker = padded;
    }

    final patchedBytes = Uint8List.fromList(originalBytes);
    final matchIndex = findSequenceIndex(patchedBytes, searchMarker);

    if (matchIndex != -1) {
      patchedBytes.setRange(matchIndex, matchIndex + newMarker.length, newMarker);
    }

    return patchedBytes;
  }

  static int findSequenceIndex(List<int> data, List<int> sequence) {
    if (data.length < sequence.length) return -1;
    for (int i = 0; i <= data.length - sequence.length; i++) {
      bool found = true;
      for (int j = 0; j < sequence.length; j++) {
        if (data[i + j] != sequence[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }

  static Future<File?> saveGeneratedBinFile(String sourceFileName, Uint8List binBytes) async {
    try {
      final tempDir = Directory.systemTemp;
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final cleanName = sourceFileName.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
      final outFile = File('${tempDir.path}/firmware_${cleanName}_$timestamp.bin');
      await outFile.writeAsBytes(binBytes);
      return outFile;
    } catch (_) {
      return null;
    }
  }
}
