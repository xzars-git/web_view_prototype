import 'package:flutter/material.dart';

/// Widget overlay untuk menampilkan log sistem secara real-time.
/// 
/// Digunakan oleh developer untuk memantau navigasi URL, status perizinan,
/// dan pesan dari bridge JavaScript tanpa harus terhubung ke kabel USB debug.
class DebugTrackerOverlay extends StatelessWidget {
  /// Daftar pesan log yang akan ditampilkan (diurutkan dari yang terbaru).
  final List<String> logs;

  const DebugTrackerOverlay({
    super.key,
    required this.logs,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      color: Colors.black.withValues(alpha: 0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header panel debug.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            color: Colors.grey[800],
            child: const Row(
              children: [
                Icon(Icons.terminal, color: Colors.white, size: 14),
                SizedBox(width: 4),
                Text(
                  "DEBUG TRACKER",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // Daftar log scrollable.
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(4),
              itemCount: logs.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    logs[index],
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 9,
                      fontFamily: 'monospace',
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
