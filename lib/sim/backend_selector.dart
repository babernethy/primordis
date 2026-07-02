import 'package:primordis/sim/models/capability_tier.dart';
import 'package:primordis/sim/sim_backend.dart';

/// The outcome of [selectWebBackend]: the constructed (but not yet
/// `init()`ed/`seed()`ed — see [SimBackend]) backend, and the [CapabilityTier]
/// it resolved to.
class SimBackendSelection {
  const SimBackendSelection({required this.backend, required this.tier});

  /// The chosen backend. Already `init()`ed by the selector (the hard-detect
  /// commitment point, [PRIMORDIS-ADR-006] §2) — the caller's next lifecycle
  /// step is `seed()`, per the [SimBackend] contract.
  final SimBackend backend;

  /// The resolved tier: kind, capabilities, reduced-mode flag, and reason.
  final CapabilityTier tier;
}

/// Reasons recorded on the resolved [CapabilityTier], factored out so the
/// selector and its tests share exact strings ([PRIMORDIS-ADR-006] §5,
/// "Logging").
abstract final class CapabilityTierReason {
  static const String webGpuOk = 'WebGPU device acquired';
  static const String noNavigatorGpu = 'navigator.gpu is unavailable';
  static const String noAdapter = 'WebGPU adapter unavailable';
  static const String deviceRequestFailed = 'WebGPU device request failed';
  static const String deviceLostDuringInit =
      'WebGPU device lost during initialization';
  static const String noGpuBackendConstructed =
      'WebGPU backend construction failed';
  static const String probeError = 'WebGPU feature probe failed';
}

/// Selects the web tier: browser WebGPU (T2) when a device can actually be
/// acquired, otherwise the Dart→WASM CPU fallback (T4) — the web half of the
/// [PRIMORDIS-ADR-006] detection order ([PRIMORDIS-TASK-797]).
///
/// This is the **hard-detect, then commit** contract: [probeSupported] answers
/// the cheap `navigator.gpu` + adapter feature-detect (already unit-tested in
/// isolation by [classifyWebGpuProbe]/`webgpu_support.dart`), but a `supported`
/// probe result is only a *necessary* precondition — [createGpuBackend] is
/// constructed and its `init()` (adapter → device → pipelines) is actually
/// awaited, and only a successful `init()` commits to the GPU tier. Any
/// failure — probe reports unsupported, `createGpuBackend` returns null,
/// `init()` throws, or `init()` completes but the backend already reports
/// device-loss via [DeviceLossAware] (an immediate device-loss race) —
/// disposes the failed attempt and falls through to [createCpuBackend].
///
/// Every dependency is injected so this is unit-testable on the Dart VM
/// without a browser: tests simulate "no `navigator.gpu`", "adapter null",
/// "`requestDevice()` throws", and "GPU available" by supplying fakes for
/// [probeSupported], [createGpuBackend], and [createCpuBackend].
Future<SimBackendSelection> selectWebBackend({
  required Future<WebGpuProbeResult> Function() probeSupported,
  required SimBackend? Function() createGpuBackend,
  required SimBackend Function() createCpuBackend,
}) async {
  final probe = await probeSupported();

  // The reason recorded on the CPU-WASM tier if the GPU attempt is skipped or
  // fails; starts as the probe's reason (the common "unsupported" case) and is
  // overwritten below with a more specific reason if a GPU attempt was made
  // and failed post-probe (ADR-006 §5, "Logging" — the reason must reflect
  // what actually happened, not just the initial feature-detect).
  var fallbackReason = probe.reason;

  if (probe.isSupported) {
    final gpuBackend = createGpuBackend();
    if (gpuBackend != null) {
      try {
        await gpuBackend.init();
        if (!_isDeviceLost(gpuBackend)) {
          return SimBackendSelection(
            backend: gpuBackend,
            tier: CapabilityTier(
              kind: CapabilityBackendKind.webGpu,
              capabilities: gpuBackend.capabilities,
              reducedMode: false,
              reason: CapabilityTierReason.webGpuOk,
            ),
          );
        }
        fallbackReason = CapabilityTierReason.deviceLostDuringInit;
      } catch (_) {
        // Adapter/device acquisition failed after the feature-detect said
        // WebGPU was present (e.g. requestDevice() rejected, or an immediate
        // device-lost during bring-up). Fall through to the CPU tier below.
        fallbackReason = CapabilityTierReason.deviceRequestFailed;
      }
      // The GPU attempt didn't commit (device-lost or threw): release
      // whatever it managed to acquire before building the CPU fallback.
      await gpuBackend.dispose();
    } else {
      fallbackReason = CapabilityTierReason.noGpuBackendConstructed;
    }
  }

  final cpuBackend = createCpuBackend();
  await cpuBackend.init();
  return SimBackendSelection(
    backend: cpuBackend,
    tier: CapabilityTier(
      kind: CapabilityBackendKind.webCpuWasm,
      capabilities: cpuBackend.capabilities,
      reducedMode: true,
      reason: fallbackReason,
    ),
  );
}

/// Reads an optional `deviceLost`-shaped getter off [backend] via the
/// [DeviceLossAware] marker interface, defaulting to `false` for backends that
/// don't expose one (e.g. a fake in tests). [SimBackend] and [DeviceLossAware]
/// are unrelated interfaces, so Dart does not flow-promote `backend` from an
/// `is` check alone — the explicit cast makes the optional-capability read
/// exact without depending on the concrete `WebWebGpuBackend` type.
bool _isDeviceLost(SimBackend backend) =>
    backend is DeviceLossAware && (backend as DeviceLossAware).deviceLost;

/// Optional capability a [SimBackend] may implement to report device-loss —
/// read by [selectWebBackend] to catch the race where the device is lost
/// during bring-up before the first frame, and by
/// `active_backend_provider.dart` to demote a *running* session when the
/// device is lost later ([PRIMORDIS-ADR-006] §2 "device-lost").
abstract interface class DeviceLossAware {
  /// True if the underlying GPU device has already been lost.
  bool get deviceLost;

  /// Completes the first time the device is lost, whether that happens during
  /// bring-up or after the tier has been running for a while. A live
  /// consumer (e.g. [PRIMORDIS-TASK-797]'s `activeBackendProvider`) awaits
  /// this to know when to re-select and degrade to the CPU-WASM tier rather
  /// than continuing to drive a dead GPU connection.
  Future<void> get onDeviceLost;
}

/// What [selectWebBackend]'s injected probe reports: whether the GPU tier is
/// worth attempting, and the reason to record if it isn't (or if the
/// subsequent attempt fails and the caller wants the probe's own reason as a
/// baseline). Decouples the selector from the concrete `WebGpuSupport` enum in
/// `webgpu_support.dart` so it can be driven by any injected probe in tests.
class WebGpuProbeResult {
  const WebGpuProbeResult({required this.isSupported, required this.reason});

  /// Probe reported a `navigator.gpu` + adapter combination worth attempting
  /// `init()` against.
  final bool isSupported;

  /// Human-readable reason, used verbatim as the tier's [CapabilityTier.reason]
  /// when the GPU attempt is skipped or fails outright.
  final String reason;
}
