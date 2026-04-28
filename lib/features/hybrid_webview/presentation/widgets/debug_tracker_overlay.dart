import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Widget overlay untuk menampilkan log sistem secara real-time.
///
/// Digunakan oleh developer untuk memantau navigasi URL, status perizinan,
/// dan pesan dari bridge JavaScript tanpa harus terhubung ke kabel USB debug.
class DebugTrackerOverlay extends StatelessWidget {
  /// Daftar pesan log yang akan ditampilkan (diurutkan dari yang terbaru).
  final List<String> logs;

  const DebugTrackerOverlay({super.key, required this.logs});

  void _copyLogsToClipboard() {
    final logsText = logs.join('\n');
    Clipboard.setData(ClipboardData(text: logsText));
    print("DEBUG_TRACKER: ✅ Logs copied to clipboard (${logsText.length} chars)");
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      color: Colors.black.withValues(alpha: 0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header panel debug dengan copy button.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            color: Colors.grey[800],
            child: Row(
              children: [
                const Icon(Icons.terminal, color: Colors.white, size: 14),
                const SizedBox(width: 4),
                const Text(
                  "DEBUG TRACKER",
                  style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Tooltip(
                  message: 'Copy all logs to clipboard',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _copyLogsToClipboard,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue[600],
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.content_copy, color: Colors.white, size: 10),
                            SizedBox(width: 2),
                            Text(
                              'COPY',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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
