import 'package:flutter/material.dart';

import '../../application/hybrid_webview_controller.dart';

/// Toolbar simulasi pembayaran untuk keperluan testing/demo.
///
/// Menyediakan 3 tombol inject langsung tanpa menunggu timer atau alur
/// pembayaran sungguhan. Widget ini **hanya untuk development** — hapus
/// atau sembunyikan di build production.
class SimulationToolbar extends StatelessWidget {
  final HybridWebViewController controller;

  const SimulationToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey[900],
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(
        children: [
          // Label
          const Icon(Icons.science, color: Colors.amberAccent, size: 13),
          const SizedBox(width: 4),
          const Text(
            'SIM',
            style: TextStyle(
              color: Colors.amberAccent,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 8),

          // Tombol 1: Simulasi CC/VA (Jalur A)
          _SimButton(
            label: '💳 CC/VA Done',
            color: Colors.green[700]!,
            tooltip: 'Dispatch paymentCompleted langsung ke WebView\n(simulasi Finpay redirect sukses/gagal)',
            onTap: () => controller.simulatePaymentCompleted(),
          ),

          const SizedBox(width: 6),

          // Tombol 2: Simulasi E-Wallet Custom Tab (Jalur B)
          _SimButton(
            label: '📱 E-Wallet Close',
            color: Colors.blue[700]!,
            tooltip: 'Tutup Custom Tab (jika terbuka) lalu dispatch paymentCompleted\n(simulasi user tutup Custom Tab e-wallet)',
            onTap: () => controller.simulateCustomTabClose(),
          ),

          const SizedBox(width: 6),

          // Tombol 3: Simulasi Deep Link pocapp://
          _SimButton(
            label: '🔗 Deep Link',
            color: Colors.purple[700]!,
            tooltip: 'Simulasi deep link pocapp://payment/return\n(seperti diterima dari Finpay setelah bayar e-wallet)',
            onTap: () => controller.simulateDeepLink(),
          ),
        ],
      ),
    );
  }
}

class _SimButton extends StatelessWidget {
  final String label;
  final Color color;
  final String tooltip;
  final Future<void> Function() onTap;

  const _SimButton({
    required this.label,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () async => onTap(),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
