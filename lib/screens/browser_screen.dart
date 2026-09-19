import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/serial_transport_type.dart';
import '../services/serial_manager.dart';
import '../widgets/transport_dialog.dart';
import 'flasher_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final SerialManager _serialManager = SerialManager();

  static const String defaultWebUrl = 'https://geosensetrack.com/';
  static const String demoAssetPath = 'assets/demo_serial.html';

  late final WebViewController _webController;
  final TextEditingController _urlController =
      TextEditingController(text: defaultWebUrl);
  final ScrollController _logScrollController = ScrollController();

  bool _isDemoTabActive = false;
  double _loadingProgress = 0.0;
  bool _isLoading = false;

  final List<String> _baudRates = [
    '9600',
    '115200',
    '57600',
    '38400',
    '19200',
    '4800',
  ];
  String _selectedBaud = '115200';

  bool _showLogPanel = false;
  final List<String> _terminalLogs = ['-- Ready --'];

  late final StreamSubscription _connSub;
  late final StreamSubscription _dataSub;
  late final StreamSubscription _errSub;
  late final StreamSubscription _logSub;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _initSerialListeners();
  }

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF121212))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            setState(() {
              _loadingProgress = progress / 100.0;
              _isLoading = progress < 100;
            });
          },
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              if (url != 'about:blank' && !_isDemoTabActive) {
                _urlController.text = url;
              }
            });
            _injectBridgeAndPolyfill();
          },
          onPageFinished: (url) {
            setState(() {
              _isLoading = false;
              if (url != 'about:blank' && !_isDemoTabActive) {
                _urlController.text = url;
              }
            });
            _injectBridgeAndPolyfill();
          },
        ),
      )
      ..addJavaScriptChannel(
        'GeoSenseBridgeChannel',
        onMessageReceived: _handleJsMessage,
      );

    _loadUrl(defaultWebUrl);
  }

  void _initSerialListeners() {
    _connSub = _serialManager.onConnectionChanged.listen((connected) {
      if (!mounted) return;
      setState(() {});
      if (connected) {
        _runJs(
          "window.dispatchEvent(new CustomEvent('geosense-usb-connected',{detail:{driver:${jsonEncode(_serialManager.driverName)}}}));",
        );
      } else {
        _runJs("window.dispatchEvent(new Event('geosense-usb-disconnected'));");
      }
    });

    _dataSub = _serialManager.onData.listen((data) {
      _runJs(
        "window.dispatchEvent(new CustomEvent('geosense-usb-data',{detail:{data:${jsonEncode(data)}}}));",
      );
    });

    _errSub = _serialManager.onError.listen((err) {
      _runJs(
        "window.dispatchEvent(new CustomEvent('geosense-usb-error',{detail:{error:${jsonEncode(err)}}}));",
      );
    });

    _logSub = _serialManager.onLog.listen((log) {
      _appendLog(log);
    });
  }

  @override
  void dispose() {
    _connSub.cancel();
    _dataSub.cancel();
    _errSub.cancel();
    _logSub.cancel();
    _urlController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _appendLog(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final line = '[$timeStr] $message';

    setState(() {
      _terminalLogs.add(line);
      if (_terminalLogs.length > 500) {
        _terminalLogs.removeRange(0, 100);
      }
    });

    if (_showLogPanel) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScrollController.hasClients) {
          _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
        }
      });
    }
  }

  void _handleJsMessage(JavaScriptMessage message) {
    try {
      final json = jsonDecode(message.message) as Map<String, dynamic>;
      final action = json['action'] as String?;

      switch (action) {
        case 'connect':
          final baud = int.tryParse(_selectedBaud) ?? 115200;
          _serialManager.connect(baudRate: baud);
          break;
        case 'disconnect':
          _serialManager.disconnect();
          break;
        case 'send':
          final data = json['data'] as String? ?? '';
          _serialManager.send(data);
          break;
        case 'setBaudRate':
          final baud = json['baudRate'] as int? ?? 115200;
          setState(() {
            _selectedBaud = baud.toString();
          });
          _serialManager.setBaudRate(baud);
          break;
      }
    } catch (_) {
      // Fallback plain string
      _serialManager.send(message.message);
    }
  }

  void _runJs(String code) {
    _webController.runJavaScript(code).catchError((_) {});
  }

  void _injectBridgeAndPolyfill() {
    final isConnected = _serialManager.isConnected;
    final baud = _serialManager.currentBaudRate;
    final driver = _serialManager.driverName;

    final bridgeScript = '''
(function() {
  window.GeoSenseUSB = {
    connect: function() {
      if (window.GeoSenseBridgeChannel) {
        window.GeoSenseBridgeChannel.postMessage(JSON.stringify({action: 'connect'}));
      }
    },
    disconnect: function() {
      if (window.GeoSenseBridgeChannel) {
        window.GeoSenseBridgeChannel.postMessage(JSON.stringify({action: 'disconnect'}));
      }
    },
    send: function(data) {
      if (window.GeoSenseBridgeChannel) {
        window.GeoSenseBridgeChannel.postMessage(JSON.stringify({action: 'send', data: data}));
      }
    },
    setBaudRate: function(baud) {
      if (window.GeoSenseBridgeChannel) {
        window.GeoSenseBridgeChannel.postMessage(JSON.stringify({action: 'setBaudRate', baudRate: baud}));
      }
    },
    status: function() {
      return 'native-usb-bridge';
    },
    isConnected: function() {
      return $isConnected;
    },
    getBaudRate: function() {
      return $baud;
    },
    getDriverName: function() {
      return ${jsonEncode(driver)};
    }
  };

  if (!navigator.serial) {
    let _activePort = null;
    class NativeSerialPort {
      constructor() {
        this.connected = true;
        let _onDataListener = null;
        let _onDiscListener = null;
        this.readable = new ReadableStream({
          start(controller) {
            _onDataListener = (e) => {
              try {
                const dataStr = (e.detail && e.detail.data != null) ? String(e.detail.data) : '';
                if (dataStr) {
                  const enc = new TextEncoder();
                  controller.enqueue(enc.encode(dataStr + '\\n'));
                }
              } catch(err){}
            };
            _onDiscListener = () => {
              try { controller.close(); } catch(err){}
            };
            window.addEventListener('geosense-usb-data', _onDataListener);
            window.addEventListener('geosense-usb-disconnected', _onDiscListener);
          },
          cancel() {
            if (_onDataListener) window.removeEventListener('geosense-usb-data', _onDataListener);
            if (_onDiscListener) window.removeEventListener('geosense-usb-disconnected', _onDiscListener);
          }
        });
        this.writable = new WritableStream({
          write(chunk) {
            return new Promise((resolve) => {
              let text = '';
              if (typeof chunk === 'string') {
                text = chunk;
              } else {
                const dec = new TextDecoder();
                text = dec.decode(chunk);
              }
              if (window.GeoSenseUSB) {
                window.GeoSenseUSB.send(text);
              }
              resolve();
            });
          }
        });
      }
      async open(options) {
        if (options && options.baudRate && window.GeoSenseUSB) {
          window.GeoSenseUSB.setBaudRate(options.baudRate);
        }
        if (window.GeoSenseUSB) {
          window.GeoSenseUSB.connect();
        }
        return Promise.resolve();
      }
      async close() {
        return Promise.resolve();
      }
      async getInfo() {
        return { usbVendorId: 0x10C4, usbProductId: 0xEA60 };
      }
      async getSignals() { return { dtr: true, rts: true }; }
      async setSignals(signals) { return Promise.resolve(); }
    }
    class NativeSerial {
      async requestPort(options) {
        if (!_activePort) {
          _activePort = new NativeSerialPort();
        }
        if (window.GeoSenseUSB) {
          window.GeoSenseUSB.connect();
        }
        return Promise.resolve(_activePort);
      }
      async getPorts() {
        if (!_activePort) {
          _activePort = new NativeSerialPort();
        }
        return Promise.resolve([_activePort]);
      }
    }
    const _serialInst = new NativeSerial();
    window.addEventListener('geosense-usb-connected', (e) => {
      try {
        if (!_activePort) _activePort = new NativeSerialPort();
        _serialInst.dispatchEvent(new CustomEvent('connect', { detail: { port: _activePort } }));
      } catch(err){}
    });
    window.addEventListener('geosense-usb-disconnected', () => {
      try {
        if (_activePort) {
          _serialInst.dispatchEvent(new CustomEvent('disconnect', { detail: { port: _activePort } }));
        }
        _activePort = null;
      } catch(err){}
    });
    navigator.serial = _serialInst;
  }
})();
''';

    _runJs(bridgeScript);
  }

  void _loadUrl(String url) {
    var target = url.trim();
    if (target.isEmpty) return;

    if (!target.startsWith('http://') &&
        !target.startsWith('https://') &&
        !target.startsWith('file://')) {
      if (target.contains('.') && !target.contains(' ')) {
        target = 'https://$target';
      } else {
        target = 'https://www.google.com/search?q=${Uri.encodeComponent(target)}';
      }
    }

    _urlController.text = target;
    _webController.loadRequest(Uri.parse(target));
  }

  void _switchTab(bool isDemo) {
    setState(() {
      _isDemoTabActive = isDemo;
    });

    if (isDemo) {
      _urlController.text = 'demo_serial.html';
      _webController.loadFlutterAsset(demoAssetPath);
    } else {
      _loadUrl(defaultWebUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _serialManager.isConnected;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Column(
          children: [
            // Top Tabs: Web Browser vs Demo Serial HTML
            Container(
              color: const Color(0xFF1A1A1A),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: !_isDemoTabActive
                              ? const Color(0xFF1976D2)
                              : const Color(0xFF2C2C2C),
                          foregroundColor: !_isDemoTabActive
                              ? Colors.white
                              : const Color(0xFF9E9E9E),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          elevation: 0,
                        ),
                        onPressed: () => _switchTab(false),
                        child: const Text(
                          '🌐 Web Browser',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isDemoTabActive
                              ? const Color(0xFF1976D2)
                              : const Color(0xFF2C2C2C),
                          foregroundColor: _isDemoTabActive
                              ? Colors.white
                              : const Color(0xFF9E9E9E),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          elevation: 0,
                        ),
                        onPressed: () => _switchTab(true),
                        child: const Text(
                          '⚡ Demo Serial HTML',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // URL Search Bar
            Container(
              color: const Color(0xFF242424),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _urlController,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'Enter URL (e.g. https://...)',
                          hintStyle: const TextStyle(color: Color(0xFF757575), fontSize: 12),
                          filled: true,
                          fillColor: const Color(0xFF181818),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (val) => _loadUrl(val),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    height: 38,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(50, 38),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => _loadUrl(_urlController.text),
                      child: const Text('Go', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    height: 38,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF37474F),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(42, 38),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => _webController.reload(),
                      child: const Text('↻', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
              ),
            ),

            // Loading Progress Bar
            if (_isLoading)
              LinearProgressIndicator(
                value: _loadingProgress,
                minHeight: 3,
                backgroundColor: const Color(0xFF181818),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF64B5F6)),
              ),

            // WebView
            Expanded(
              child: WebViewWidget(controller: _webController),
            ),

            // Bottom Status / Controls Bar
            Container(
              color: const Color(0xFF212121),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isConnected
                          ? 'Connected (${_serialManager.driverName})'
                          : 'Status: Disconnected',
                      style: TextStyle(
                        color: isConnected ? const Color(0xFF00E676) : const Color(0xFFE0E0E0),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),

                  // Baud Rate Dropdown
                  Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF333333),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedBaud,
                        dropdownColor: const Color(0xFF333333),
                        items: _baudRates
                            .map((b) => DropdownMenuItem(
                                  value: b,
                                  child: Text(b, style: const TextStyle(color: Colors.white, fontSize: 11)),
                                ))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedBaud = val);
                            final baud = int.tryParse(val) ?? 115200;
                            _serialManager.setBaudRate(baud);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),

                  // Transport Selector Button
                  IconButton(
                    icon: Icon(
                      _serialManager.selectedType == SerialTransportType.usbOtg
                          ? Icons.usb
                          : (_serialManager.selectedType == SerialTransportType.ble
                              ? Icons.bluetooth
                              : (_serialManager.selectedType == SerialTransportType.tcp
                                  ? Icons.wifi
                                  : Icons.devices)),
                      color: const Color(0xFF64B5F6),
                      size: 20,
                    ),
                    tooltip: 'Transport (${_serialManager.selectedType.label})',
                    onPressed: () => TransportDialog.show(context),
                  ),

                  // Connect / Disconnect Button
                  SizedBox(
                    height: 34,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isConnected
                            ? const Color(0xFFD32F2F)
                            : const Color(0xFF1565C0),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(65, 34),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () {
                        if (isConnected) {
                          _serialManager.disconnect();
                        } else {
                          final baud = int.tryParse(_selectedBaud) ?? 115200;
                          _serialManager.connect(baudRate: baud);
                        }
                      },
                      child: Text(
                        isConnected ? 'Disconnect' : 'Connect',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),

                  // Flasher Button
                  SizedBox(
                    height: 34,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(65, 34),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const FlasherScreen()),
                        );
                      },
                      child: const Text('Flasher ⚡', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 4),

                  // Toggle Log Button
                  SizedBox(
                    height: 34,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF424242),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(55, 34),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: () {
                        setState(() {
                          _showLogPanel = !_showLogPanel;
                        });
                      },
                      child: Text(
                        _showLogPanel ? 'Log ▼' : 'Log ▲',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Collapsible Log Panel
            if (_showLogPanel)
              Container(
                height: 180,
                color: const Color(0xFF121212),
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Text(
                          'USB / Serial Terminal Output',
                          style: TextStyle(
                            color: Color(0xFF9E9E9E),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () {
                            setState(() {
                              _terminalLogs.clear();
                              _terminalLogs.add('-- Log cleared --');
                            });
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Text(
                              'Clear',
                              style: TextStyle(
                                color: Color(0xFF64B5F6),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0D1117),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.all(6),
                        child: ListView.builder(
                          controller: _logScrollController,
                          itemCount: _terminalLogs.length,
                          itemBuilder: (ctx, i) {
                            final log = _terminalLogs[i];
                            Color col = const Color(0xFF00FF66);
                            if (log.contains('TX:')) col = const Color(0xFF00E5FF);
                            if (log.contains('SYS:') || log.contains('FLASHER:')) {
                              col = const Color(0xFFFFD600);
                            }
                            if (log.contains('ERR:')) col = const Color(0xFFFF5252);
                            return Text(
                              log,
                              style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: col),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
