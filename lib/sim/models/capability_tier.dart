import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:primordis/sim/models/sim_capabilities.dart';

part 'capability_tier.freezed.dart';

/// The four-tier graceful-degradation model from [PRIMORDIS-ADR-006] §1.
///
/// Platform-neutral on purpose: [PRIMORDIS-TASK-797] (this task) only ever
/// resolves to [webGpu] / [webCpuWasm], but the enum carries the native values
/// up front so [CapabilityTier] is the same currency [PRIMORDIS-TASK-805]
/// (cross-platform selection) composes on, rather than a second model.
enum CapabilityBackendKind {
  /// T1 — native macOS, Dawn/wgpu-over-Metal GPU init succeeded.
  nativeGpu,

  /// T2 — web, `navigator.gpu` present and a device was acquired.
  webGpu,

  /// T3 — native macOS, GPU init failed; isolate-based CPU fallback.
  nativeCpu,

  /// T4 — web, no usable WebGPU; single-thread Dart→WASM CPU fallback.
  webCpuWasm,
}

/// The resolved outcome of backend selection: which tier is live, its
/// [SimBackendCapabilities] (particle ceiling, GPU/CPU-ness), whether the
/// user-visible "reduced mode" indicator should show, and *why* this tier was
/// chosen — surfaced for diagnostics and the reduced-mode tooltip
/// ([PRIMORDIS-ADR-006] §4).
@freezed
abstract class CapabilityTier with _$CapabilityTier {
  const factory CapabilityTier({
    /// Which tier is live.
    required CapabilityBackendKind kind,

    /// The concrete backend's capabilities (particle ceiling, GPU/CPU).
    required SimBackendCapabilities capabilities,

    /// Whether the reduced-mode indicator should be shown. True for the CPU
    /// tiers (T3/T4); false for the GPU tiers (T1/T2). Kept as an explicit
    /// field (rather than deriving it every call site from `kind`) because the
    /// UI/tooltip layer should read intent directly, not re-derive policy.
    required bool reducedMode,

    /// Human-readable reason the selector landed on this tier (e.g. "no
    /// navigator.gpu", "adapter unavailable", "device lost", "GPU OK") — for
    /// the reduced-mode tooltip and support diagnostics.
    required String reason,
  }) = _CapabilityTier;

  /// True for the GPU tiers ([CapabilityBackendKind.nativeGpu] /
  /// [CapabilityBackendKind.webGpu]) — the same fact [reducedMode] encodes,
  /// exposed as a convenience derived from [kind] rather than a duplicate
  /// stored field.
  const CapabilityTier._();

  bool get isGpuTier =>
      kind == CapabilityBackendKind.nativeGpu ||
      kind == CapabilityBackendKind.webGpu;
}
