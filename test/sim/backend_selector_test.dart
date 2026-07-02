import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:primordis/sim/backend_selector.dart';
import 'package:primordis/sim/models/capability_tier.dart';
import 'package:primordis/sim/models/sim_capabilities.dart';
import 'package:primordis/sim/models/sim_params.dart';
import 'package:primordis/sim/models/sim_seed.dart';
import 'package:primordis/sim/sim_backend.dart';

/// A fake GPU-tier [SimBackend] for [selectWebBackend] tests: constructible,
/// optionally throws on [init], and optionally implements [DeviceLossAware]
/// to simulate an immediate post-init device-loss race
/// ([PRIMORDIS-ADR-006] §2).
class _FakeGpuBackend implements SimBackend {
  _FakeGpuBackend({this.failInit = false});

  final bool failInit;
  bool initCalled = false;
  bool disposeCalled = false;

  @override
  SimBackendCapabilities get capabilities => const SimBackendCapabilities(
        isGpuAccelerated: true,
        maxParticles: 24000,
        defaultParticleCount: 24000,
        label: 'fake-web-gpu',
      );

  @override
  Future<void> init() async {
    initCalled = true;
    if (failInit) throw Exception('requestDevice() failed');
  }

  @override
  Future<void> seed(SimSeed seed) async {}

  @override
  void setParams(SimParams params) {}

  @override
  void step(double dt) {}

  @override
  void present() {}

  @override
  Future<void> dispose() async {
    disposeCalled = true;
  }
}

/// Same as [_FakeGpuBackend] but reports an already-observed device-loss
/// immediately after [init] completes successfully — the race the selector
/// must treat as a failed GPU attempt, not a success.
class _FakeGpuBackendDeviceLostAtInit implements SimBackend, DeviceLossAware {
  bool disposeCalled = false;

  @override
  SimBackendCapabilities get capabilities => const SimBackendCapabilities(
        isGpuAccelerated: true,
        maxParticles: 24000,
        defaultParticleCount: 24000,
        label: 'fake-web-gpu',
      );

  @override
  Future<void> init() async {}

  @override
  Future<void> seed(SimSeed seed) async {}

  @override
  void setParams(SimParams params) {}

  @override
  void step(double dt) {}

  @override
  void present() {}

  @override
  Future<void> dispose() async {
    disposeCalled = true;
  }

  @override
  bool get deviceLost => true;

  @override
  Future<void> get onDeviceLost => Completer<void>().future;
}

class _FakeCpuBackend implements SimBackend {
  bool initCalled = false;

  @override
  SimBackendCapabilities get capabilities => const SimBackendCapabilities(
        isGpuAccelerated: false,
        maxParticles: 4000,
        defaultParticleCount: 3500,
        label: 'fake-web-cpu',
      );

  @override
  Future<void> init() async {
    initCalled = true;
  }

  @override
  Future<void> seed(SimSeed seed) async {}

  @override
  void setParams(SimParams params) {}

  @override
  void step(double dt) {}

  @override
  void present() {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('selectWebBackend', () {
    test('no navigator.gpu -> CPU-WASM tier with the reduced ceiling and a '
        'reason, without attempting GPU construction', () async {
      var gpuFactoryCalled = false;
      final cpu = _FakeCpuBackend();

      final selection = await selectWebBackend(
        probeSupported: () async => const WebGpuProbeResult(
          isSupported: false,
          reason: CapabilityTierReason.noNavigatorGpu,
        ),
        createGpuBackend: () {
          gpuFactoryCalled = true;
          return _FakeGpuBackend();
        },
        createCpuBackend: () => cpu,
      );

      expect(gpuFactoryCalled, isFalse,
          reason: 'unsupported probe must skip GPU construction entirely');
      expect(selection.backend, same(cpu));
      expect(cpu.initCalled, isTrue);
      expect(selection.tier.kind, CapabilityBackendKind.webCpuWasm);
      expect(selection.tier.reducedMode, isTrue);
      expect(selection.tier.capabilities.maxParticles, 4000);
      expect(selection.tier.reason, CapabilityTierReason.noNavigatorGpu);
    });

    test('GPU available and device acquired -> WebGPU tier, full ceiling',
        () async {
      final gpu = _FakeGpuBackend();

      final selection = await selectWebBackend(
        probeSupported: () async => const WebGpuProbeResult(
          isSupported: true,
          reason: CapabilityTierReason.webGpuOk,
        ),
        createGpuBackend: () => gpu,
        createCpuBackend: _FakeCpuBackend.new,
      );

      expect(selection.backend, same(gpu));
      expect(gpu.initCalled, isTrue);
      expect(gpu.disposeCalled, isFalse);
      expect(selection.tier.kind, CapabilityBackendKind.webGpu);
      expect(selection.tier.reducedMode, isFalse);
      expect(selection.tier.capabilities.maxParticles, 24000);
      expect(selection.tier.reason, CapabilityTierReason.webGpuOk);
    });

    test('navigator.gpu present but adapter null -> CPU-WASM fallback',
        () async {
      var gpuFactoryCalled = false;
      final cpu = _FakeCpuBackend();

      final selection = await selectWebBackend(
        probeSupported: () async => const WebGpuProbeResult(
          isSupported: false,
          reason: CapabilityTierReason.noAdapter,
        ),
        createGpuBackend: () {
          gpuFactoryCalled = true;
          return _FakeGpuBackend();
        },
        createCpuBackend: () => cpu,
      );

      expect(gpuFactoryCalled, isFalse);
      expect(selection.backend, same(cpu));
      expect(selection.tier.kind, CapabilityBackendKind.webCpuWasm);
      expect(selection.tier.reason, CapabilityTierReason.noAdapter);
    });

    test('requestDevice() throws during init -> CPU-WASM fallback, failed '
        'GPU backend disposed', () async {
      final gpu = _FakeGpuBackend(failInit: true);
      final cpu = _FakeCpuBackend();

      final selection = await selectWebBackend(
        probeSupported: () async => const WebGpuProbeResult(
          isSupported: true,
          reason: CapabilityTierReason.webGpuOk,
        ),
        createGpuBackend: () => gpu,
        createCpuBackend: () => cpu,
      );

      expect(gpu.initCalled, isTrue);
      expect(gpu.disposeCalled, isTrue,
          reason: 'the failed GPU attempt must release its resources');
      expect(selection.backend, same(cpu));
      expect(selection.tier.kind, CapabilityBackendKind.webCpuWasm);
      expect(selection.tier.reducedMode, isTrue);
      expect(selection.tier.reason, CapabilityTierReason.deviceRequestFailed,
          reason: 'the reason must reflect the actual init failure, not the '
              'earlier "supported" probe result');
    });

    test('createGpuBackend returns null despite a supported probe -> '
        'CPU-WASM fallback', () async {
      final cpu = _FakeCpuBackend();

      final selection = await selectWebBackend(
        probeSupported: () async => const WebGpuProbeResult(
          isSupported: true,
          reason: CapabilityTierReason.webGpuOk,
        ),
        createGpuBackend: () => null,
        createCpuBackend: () => cpu,
      );

      expect(selection.backend, same(cpu));
      expect(selection.tier.kind, CapabilityBackendKind.webCpuWasm);
      expect(
        selection.tier.reason,
        CapabilityTierReason.noGpuBackendConstructed,
      );
    });

    test('device lost immediately after a successful init -> CPU-WASM '
        'fallback, dead GPU backend disposed', () async {
      final gpu = _FakeGpuBackendDeviceLostAtInit();
      final cpu = _FakeCpuBackend();

      final selection = await selectWebBackend(
        probeSupported: () async => const WebGpuProbeResult(
          isSupported: true,
          reason: CapabilityTierReason.webGpuOk,
        ),
        createGpuBackend: () => gpu,
        createCpuBackend: () => cpu,
      );

      expect(gpu.disposeCalled, isTrue);
      expect(selection.backend, same(cpu));
      expect(selection.tier.kind, CapabilityBackendKind.webCpuWasm);
      expect(selection.tier.reducedMode, isTrue);
      expect(
        selection.tier.reason,
        CapabilityTierReason.deviceLostDuringInit,
      );
    });
  });

  group('CapabilityTier', () {
    test('isGpuTier is true for webGpu/nativeGpu and false for the CPU tiers',
        () {
      const caps = SimBackendCapabilities(
        isGpuAccelerated: true,
        maxParticles: 1,
        defaultParticleCount: 1,
        label: 'x',
      );
      for (final kind in [
        CapabilityBackendKind.webGpu,
        CapabilityBackendKind.nativeGpu,
      ]) {
        expect(
          CapabilityTier(
            kind: kind,
            capabilities: caps,
            reducedMode: false,
            reason: 'ok',
          ).isGpuTier,
          isTrue,
        );
      }
      for (final kind in [
        CapabilityBackendKind.webCpuWasm,
        CapabilityBackendKind.nativeCpu,
      ]) {
        expect(
          CapabilityTier(
            kind: kind,
            capabilities: caps,
            reducedMode: true,
            reason: 'fallback',
          ).isGpuTier,
          isFalse,
        );
      }
    });
  });
}
