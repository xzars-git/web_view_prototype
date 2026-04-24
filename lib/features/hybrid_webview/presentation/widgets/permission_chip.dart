import 'package:flutter/material.dart';

/// Komponen UI ringkas untuk menampilkan status izin hardware.
/// 
/// Memberikan indikasi visual (Warna Hijau/Merah) apakah akses ke
/// kamera atau lokasi saat ini diizinkan oleh sistem operasi.
class PermissionChip extends StatelessWidget {
  /// Nama izin (misal: 'Cam', 'Loc').
  final String label;
  
  /// Status izin saat ini.
  final bool granted;

  const PermissionChip({
    super.key,
    required this.label,
    required this.granted,
  });

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        granted ? Icons.check_circle : Icons.cancel,
        color: granted ? Colors.green : Colors.red,
        size: 14,
      ),
      label: Text(label, style: const TextStyle(fontSize: 10)),
      backgroundColor: granted 
          ? Colors.green.withValues(alpha: 0.1) 
          : Colors.red.withValues(alpha: 0.1),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }
}
