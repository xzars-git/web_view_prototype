// simulation_toolbar.dart — DEPRECATED
// Toolbar simulasi pembayaran sudah dihapus.
// File ini dipertahankan sebagai placeholder agar tidak merusak referensi.
// Dapat dihapus sepenuhnya jika tidak ada import lain yang merujuk.

import 'package:flutter/material.dart';

/// Widget placeholder — toolbar simulasi sudah dihapus.
/// Payment sekarang dihandle via console.log interception + API polling.
class SimulationToolbar extends StatelessWidget {
  final dynamic controller;
  const SimulationToolbar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
