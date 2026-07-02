import 'dart:async';

import 'package:primordis/sim/backend_selector.dart';
import 'package:primordis/sim/backends/cpu/cpu_wasm_backend.dart';
import 'package:primordis/sim/backends/web/web_backend.dart';
import 'package:primordis/sim/models/capability_tier.dart';
import 'package:primordis/sim/providers/web_backend_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'active_backend_provider.g.dart';

/// The web backend-selection seam ([PRIMORDIS-TASK-797] /
/// [PRIMORDIS-ADR-006]): resolves once at startup to either the browser
/// WebGPU tier (T2) or the Dart→WASM CPU fallback (T4), behind the single
/// [SimBackendSelection.backend] — the UI never branches on WebGPU vs. CPU
/// directly.
///
/// This provider owns *web* selection only. Cross-platform composition (macOS
/// native GPU/CPU tiers, and driving this result into the app's live
/// `simBackendProvider` + the reduced-mode UI indicator) is
/// [PRIMORDIS-TASK-805]; wiring this into `simBackendProvider`/the frame-loop
/// driver is intentionally left to that task so this one stays confined to
/// `lib/sim/**` per [PRIMORDIS-ADR-001].
///
/// Async and non-blocking by construction (a Riverpod `AsyncNotifier`): a
/// consumer sees `AsyncLoading` while the probe/`init()` sequence runs, then
/// `AsyncData` with the resolved [SimBackendSelection] — no blocking/white-
/// screen hang if WebGPU bring-up stalls.
///
/// The resolved backend has already been `init()`ed by [selectWebBackend]; the
/// caller's next step is `seed()`, per the [SimBackend] lifecycle contract.
///
/// **Device-lost after a successful selection.** If the resolved backend is
/// [DeviceLossAware] (the WebGPU tier), [build] also races
/// [DeviceLossAware.onDeviceLost] in the background. When the device is lost
/// mid-session this does NOT re-probe WebGPU (the same adapter/device is
/// likely still broken, and looping back into `init()` risks spinning on a
/// dead GPU); instead it swaps [state] directly to a fresh CPU-WASM backend,
/// satisfying "degrade rather than crash" ([PRIMORDIS-ADR-006] §2).
@riverpod
class ActiveBackend extends _$ActiveBackend {
  @override
  Future<SimBackendSelection> build() async {
    final selection = await selectWebBackend(
      probeSupported: () async {
        final support = await ref.watch(webGpuSupportProvider.future);
        return WebGpuProbeResult(
          isSupported: support.isSupported,
          reason: switch (support) {
            WebGpuSupport.supported => CapabilityTierReason.webGpuOk,
            WebGpuSupport.unsupportedNoApi =>
              CapabilityTierReason.noNavigatorGpu,
            WebGpuSupport.unsupportedNoAdapter =>
              CapabilityTierReason.noAdapter,
            WebGpuSupport.error => CapabilityTierReason.probeError,
          },
        );
      },
      createGpuBackend: createWebSimBackend,
      createCpuBackend: CpuWasmBackend.new,
    );
    ref.onDispose(() => unawaited(selection.backend.dispose()));

    final backend = selection.backend;
    // SimBackend and DeviceLossAware are unrelated interfaces, so Dart does
    // not flow-promote `backend` from the `is` check alone; the explicit cast
    // makes the optional-capability read exact.
    if (backend is DeviceLossAware) {
      final lossAware = backend as DeviceLossAware;
      unawaited(lossAware.onDeviceLost.then((_) => _degradeToCpuWasm()));
    }

    return selection;
  }

  /// Replaces a lost GPU backend with a fresh CPU-WASM one, disposing the dead
  /// backend first. A no-op if this notifier has since been disposed/replaced
  /// (e.g. the container tore down before the device-lost callback fired).
  Future<void> _degradeToCpuWasm() async {
    if (!ref.mounted) return;
    final previous = state.value;
    if (previous == null) return;

    await previous.backend.dispose();
    final cpuBackend = CpuWasmBackend();
    await cpuBackend.init();
    final degraded = SimBackendSelection(
      backend: cpuBackend,
      tier: CapabilityTier(
        kind: CapabilityBackendKind.webCpuWasm,
        capabilities: cpuBackend.capabilities,
        reducedMode: true,
        reason: 'WebGPU device lost',
      ),
    );
    if (!ref.mounted) {
      // Lost the race with container teardown; don't leak the just-built
      // CPU backend.
      await cpuBackend.dispose();
      return;
    }
    state = AsyncData(degraded);
  }
}
