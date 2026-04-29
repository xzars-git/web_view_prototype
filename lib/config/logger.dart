import 'package:flutter/foundation.dart';

/// Utilitas logging terpusat yang mendukung konsol dan UI Tracker.
class AppLogger {
  const AppLogger._();

  /// Notifier untuk dipantau oleh UI Debug Tracker.
  static final ValueNotifier<List<String>> logsNotifier = ValueNotifier<List<String>>([]);

  /// Limit jumlah log yang disimpan di memori.
  static const int _maxLogs = 100;

  /// Mencetak log debug ke konsol dan menambahkannya ke tracker UI.
  static void d(String message) {
    final formattedMessage = _format(message);
    
    // 1. Cetak ke konsol debug
    debugPrint('DEBUG: $formattedMessage');

    // 2. Tambahkan ke list log UI (Hanya jika bukan mode release, atau sesuai kebutuhan)
    _addToTracker(formattedMessage);
  }

  /// Mencetak log error.
  static void e(String message, [dynamic error, StackTrace? stackTrace]) {
    final formattedMessage = _format('❌ ERROR: $message');
    
    debugPrint('ERROR: $formattedMessage');
    if (error != null) debugPrint('CAUSE: $error');
    if (stackTrace != null) debugPrint(stackTrace.toString());

    _addToTracker(formattedMessage);
  }

  static String _format(String message) {
    final now = DateTime.now();
    final time =
        "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    return "[$time] $message";
  }

  static void _addToTracker(String message) {
    // Kita tetap simpan log di memori agar Debug Tracker bisa muncul di HP
    // meskipun dalam mode release (jika flag _showDebug di UI diaktifkan).
    final currentLogs = List<String>.from(logsNotifier.value);
    currentLogs.insert(0, message);
    
    if (currentLogs.length > _maxLogs) {
      currentLogs.removeRange(_maxLogs, currentLogs.length);
    }
    
    logsNotifier.value = currentLogs;
  }

  /// Membersihkan semua log.
  static void clear() {
    logsNotifier.value = [];
  }
}
