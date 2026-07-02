import 'dart:typed_data';

import 'package:primordis/sim/parity/frame_metrics.dart';
import 'package:primordis/sim/parity/parity_fingerprint.dart';
import 'package:primordis/sim/parity/parity_metrics.dart';

/// A raw SoA snapshot of one simulation frame: the exact particle buffers,
/// unreduced.
///
/// This is the ingestion format for backends the harness cannot drive in-process
/// — chiefly the standalone WGSL kernel ([PRIMORDIS-TASK-003]), which runs on a
/// real WebGPU device under Node, and later the Dawn/Metal FFI tier. Those
/// backends export their positions/velocities/types at each checkpoint as JSON;
/// the Dart side then computes the **same** [FrameMetrics] from them via
/// [buildFingerprintFromSnapshots]. Computing the metrics in one place (Dart)
/// rather than re-implementing them per backend is what makes the comparison
/// apples-to-apples — a metric bug can't hide on one side.
class RawSnapshot {
  const RawSnapshot({
    required this.positions,
    required this.velocities,
    required this.types,
    required this.particleCount,
  });

  /// Interleaved `x, y` positions; length `2 * particleCount`.
  final Float32List positions;

  /// Interleaved `x, y` velocities; length `2 * particleCount`.
  final Float32List velocities;

  /// Per-particle type index; length `particleCount`.
  final Int32List types;

  /// Number of particles.
  final int particleCount;

  /// Parses one snapshot from its JSON form (flat number arrays).
  ///
  /// Validates the buffer lengths against `particleCount` up front — positions
  /// and velocities must each be `2 * particleCount`, types must be
  /// `particleCount` — so a malformed export fails fast here with a clear
  /// message rather than surfacing later as a `RangeError` or, worse, metrics
  /// silently computed from truncated data.
  factory RawSnapshot.fromJson(Map<String, dynamic> json) {
    final particleCount = (json['particleCount'] as num).toInt();
    final pos = (json['positions'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
    final vel = (json['velocities'] as List<dynamic>)
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
    final typ = (json['types'] as List<dynamic>)
        .map((e) => (e as num).toInt())
        .toList(growable: false);
    if (particleCount < 0) {
      throw FormatException('particleCount must be non-negative, '
          'got $particleCount');
    }
    if (pos.length != particleCount * 2) {
      throw FormatException('positions length ${pos.length} != '
          '2 * particleCount ${particleCount * 2}');
    }
    if (vel.length != particleCount * 2) {
      throw FormatException('velocities length ${vel.length} != '
          '2 * particleCount ${particleCount * 2}');
    }
    if (typ.length != particleCount) {
      throw FormatException('types length ${typ.length} != '
          'particleCount $particleCount');
    }
    return RawSnapshot(
      positions: Float32List.fromList(pos),
      velocities: Float32List.fromList(vel),
      types: Int32List.fromList(typ),
      particleCount: particleCount,
    );
  }
}

/// Builds a [ParityFingerprint] from a backend's exported raw checkpoint
/// snapshots, computing every metric with the shared Dart metric code.
///
/// [snapshots] maps checkpoint name → raw SoA snapshot (in simulation order).
/// The resulting fingerprint is directly comparable to the reference under a
/// [ParityBands] preset — the standalone WGSL kernel is checked against the
/// *looser* cross-backend band, acknowledging GPU nondeterminism.
ParityFingerprint buildFingerprintFromSnapshots({
  required String label,
  required int seed,
  required int typeCount,
  required double attractionK,
  required double repulsionK,
  required double friction,
  required MetricGrid grid,
  required Map<String, RawSnapshot> snapshots,
}) {
  if (snapshots.isEmpty) {
    throw ArgumentError('at least one snapshot is required');
  }
  final particleCount = snapshots.values.first.particleCount;
  // All checkpoints must agree on the population — an exporter that writes
  // inconsistent counts would otherwise yield a fingerprint with a misleading
  // particleCount and unpredictable comparisons. Fail fast instead.
  for (final entry in snapshots.entries) {
    if (entry.value.particleCount != particleCount) {
      throw ArgumentError(
        'snapshot "${entry.key}" particleCount ${entry.value.particleCount} '
        '!= first snapshot particleCount $particleCount',
      );
    }
  }
  final checkpoints = <String, FrameMetrics>{
    for (final entry in snapshots.entries)
      entry.key: FrameMetrics.from(
        positions: entry.value.positions,
        velocities: entry.value.velocities,
        types: entry.value.types,
        particleCount: entry.value.particleCount,
        typeCount: typeCount,
        grid: grid,
      ),
  };
  return ParityFingerprint(
    label: label,
    seed: seed,
    particleCount: particleCount,
    typeCount: typeCount,
    attractionK: attractionK,
    repulsionK: repulsionK,
    friction: friction,
    checkpoints: checkpoints,
  );
}
