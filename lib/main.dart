import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/browser_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Set immersive dark system overlay
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF121212),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const SerialConnectApp());
}

class SerialConnectApp extends StatelessWidget {
  const SerialConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Serial Connect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: const Color(0xFF1976D2),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1976D2),
          secondary: Color(0xFF64B5F6),
          surface: Color(0xFF1E1E1E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1F1F1F),
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: const BrowserScreen(),
    );
  }
}
