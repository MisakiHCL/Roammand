// SPDX-License-Identifier: MPL-2.0

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roammand/pairing/trusted_host_repository.dart';
import 'package:roammand/pairing/trusted_host_store.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

void main() {
  test(
    'loads, publishes immutable views, and serializes concurrent additions',
    () async {
      final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
        _binding(1),
      ]);
      final repository = TrustedHostRepository(persistence: persistence);
      final events = <List<TrustedHostRecord>>[];
      final subscription = repository.changes.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        await repository.close();
      });

      await repository.initialize();
      await Future.wait(<Future<void>>[
        repository.add(_binding(2)),
        repository.add(_binding(3)),
      ]);

      expect(repository.hosts.map((host) => host.displayName), <String>[
        'Host 1',
        'Host 2',
        'Host 3',
      ]);
      expect(persistence.maximumConcurrentSaves, 1);
      expect(persistence.savedSnapshots.last, hasLength(3));
      expect(
        () => repository.hosts.add(repository.hosts.first),
        throwsUnsupportedError,
      );
      final mutatedIdentity = repository.hosts.first.hostIdentity
        ..displayName = 'Changed';
      expect(mutatedIdentity.displayName, 'Changed');
      expect(repository.hosts.first.displayName, 'Host 1');
      expect(events, hasLength(3));
    },
  );

  test('exported bindings cannot mutate the saved Host identity', () async {
    final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
      _binding(1),
    ]);
    final repository = TrustedHostRepository(persistence: persistence);
    addTearDown(repository.close);
    await repository.initialize();
    final record = repository.hosts.single;
    final originalIdentity = DeviceIdentity.fromBuffer(
      record.hostIdentity.writeToBuffer(),
    );

    final exported = record.toBinding();
    exported.hostIdentity
      ..displayName = 'Changed'
      ..publicKey[0] ^= 0xff
      ..deviceId[0] ^= 0xff;

    expect(record.hostIdentity, originalIdentity);
    expect(record.displayName, 'Host 1');
    await repository.renameLocal(
      originalIdentity.deviceId,
      displayName: 'Studio Mac',
    );
    expect(persistence.stored.single.hostIdentity, originalIdentity);
  });

  test('Host identity bytes are detached on import and access', () async {
    final binding = _binding(1);
    final originalIdentity = DeviceIdentity.fromBuffer(
      binding.hostIdentity.writeToBuffer(),
    );
    final repository = TrustedHostRepository(
      persistence: FakeTrustedHostPersistence(<TrustedHostBinding>[binding]),
    );
    addTearDown(repository.close);
    await repository.initialize();
    final record = repository.hosts.single;

    binding.hostIdentity
      ..publicKey[0] ^= 0xff
      ..deviceId[0] ^= 0xff;
    expect(record.hostIdentity, originalIdentity);

    record.hostIdentity
      ..publicKey[0] ^= 0xff
      ..deviceId[0] ^= 0xff;
    expect(record.hostIdentity, originalIdentity);
  });

  test(
    'rejects duplicate Hosts and keeps memory unchanged on save failure',
    () async {
      final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
        _binding(1),
      ]);
      final repository = TrustedHostRepository(persistence: persistence);
      addTearDown(repository.close);
      await repository.initialize();

      await expectLater(
        repository.add(_binding(1)),
        throwsA(
          isA<TrustedHostRepositoryException>().having(
            (error) => error.code,
            'code',
            TrustedHostRepositoryError.duplicateHost,
          ),
        ),
      );
      persistence.failSave = true;
      await expectLater(
        repository.add(_binding(2)),
        throwsA(isA<TrustedHostRepositoryException>()),
      );
      expect(repository.hosts.single.displayName, 'Host 1');
    },
  );

  test(
    'delete is local-only and successful connection timestamp is persisted',
    () async {
      final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
        _binding(1),
        _binding(2),
      ]);
      final repository = TrustedHostRepository(persistence: persistence);
      addTearDown(repository.close);
      await repository.initialize();
      final hostId = repository.hosts.first.hostIdentity.deviceId;

      await repository.markSuccessfulConnection(
        hostId,
        nowUnixMs: 1800000000000,
      );
      expect(
        repository.hosts.first.lastSuccessfulConnectionAtUnixMs,
        1800000000000,
      );
      expect(
        persistence.savedSnapshots.last.first.lastSuccessfulConnectionAtUnixMs,
        Int64(1800000000000),
      );

      expect(await repository.deleteLocal(hostId), isTrue);
      expect(repository.hosts.single.displayName, 'Host 2');
      expect(repository.hosts.single.displayOrder, 0);
      expect(await repository.deleteLocal(hostId), isFalse);
    },
  );

  test(
    'authenticated re-pairing updates the saved signaling address',
    () async {
      final original = _binding(1)
        ..lastSuccessfulConnectionAtUnixMs = Int64(1700000005000);
      final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
        original,
      ]);
      final repository = TrustedHostRepository(persistence: persistence);
      addTearDown(repository.close);
      await repository.initialize();

      await repository.renameLocal(
        repository.hosts.single.hostIdentity.deviceId,
        displayName: 'Editing Mac',
      );

      final replacement = _binding(1)
        ..signalingEndpoint = 'wss://new-signal.example.test/v1/connect'
        ..pairedAtUnixMs = Int64(1700000010000);
      await repository.savePairing(replacement);

      expect(repository.hosts, hasLength(1));
      expect(
        repository.hosts.single.signalingEndpoint,
        Uri.parse('wss://new-signal.example.test/v1/connect'),
      );
      expect(repository.hosts.single.lastSuccessfulConnectionAtUnixMs, 0);
      expect(repository.hosts.single.displayOrder, 0);
      expect(repository.hosts.single.displayName, 'Editing Mac');
      expect(repository.hosts.single.localAlias, 'Editing Mac');
    },
  );

  test('renames one Host locally without changing its identity', () async {
    final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
      _binding(1),
      _binding(2),
    ]);
    final repository = TrustedHostRepository(persistence: persistence);
    addTearDown(repository.close);
    await repository.initialize();
    final originalIdentity = repository.hosts.first.hostIdentity;

    await repository.renameLocal(
      originalIdentity.deviceId,
      displayName: '  Studio Mac  ',
    );

    expect(repository.hosts.first.displayName, 'Studio Mac');
    expect(repository.hosts.first.localAlias, 'Studio Mac');
    expect(repository.hosts.first.hostIdentity, originalIdentity);
    expect(persistence.stored.first.localAlias, 'Studio Mac');

    await repository.renameLocal(
      originalIdentity.deviceId,
      displayName: originalIdentity.displayName,
    );
    expect(repository.hosts.first.localAlias, isNull);
    expect(repository.hosts.first.displayName, originalIdentity.displayName);
  });

  test('rejects an invalid local Host name without saving', () async {
    final persistence = FakeTrustedHostPersistence(<TrustedHostBinding>[
      _binding(1),
    ]);
    final repository = TrustedHostRepository(persistence: persistence);
    addTearDown(repository.close);
    await repository.initialize();

    await expectLater(
      repository.renameLocal(
        repository.hosts.single.hostIdentity.deviceId,
        displayName: ' ',
      ),
      throwsA(
        isA<TrustedHostRepositoryException>().having(
          (error) => error.code,
          'code',
          TrustedHostRepositoryError.invalidDisplayName,
        ),
      ),
    );
    expect(persistence.savedSnapshots, isEmpty);
  });
}

final class FakeTrustedHostPersistence implements TrustedHostPersistence {
  FakeTrustedHostPersistence(List<TrustedHostBinding> initial)
    : stored = initial.map((binding) => binding.deepCopy()).toList();

  List<TrustedHostBinding> stored;
  final List<List<TrustedHostBinding>> savedSnapshots =
      <List<TrustedHostBinding>>[];
  bool failSave = false;
  int activeSaves = 0;
  int maximumConcurrentSaves = 0;

  @override
  Future<List<TrustedHostBinding>> load() async =>
      stored.map((binding) => binding.deepCopy()).toList();

  @override
  Future<void> save(Iterable<TrustedHostBinding> bindings) async {
    activeSaves += 1;
    maximumConcurrentSaves = maximumConcurrentSaves < activeSaves
        ? activeSaves
        : maximumConcurrentSaves;
    await Future<void>.delayed(Duration.zero);
    try {
      if (failSave) {
        throw const TrustedHostStoreException(
          TrustedHostStoreError.unavailable,
        );
      }
      stored = bindings.map((binding) => binding.deepCopy()).toList();
      savedSnapshots.add(stored.map((binding) => binding.deepCopy()).toList());
    } finally {
      activeSaves -= 1;
    }
  }
}

TrustedHostBinding _binding(int marker) {
  final publicKey = List<int>.generate(32, (index) => (marker + index) & 0xff);
  return TrustedHostBinding(
    hostIdentity: DeviceIdentity(
      deviceId: deriveDeviceIdV1(publicKey),
      publicKeyAlgorithm: PublicKeyAlgorithm.PUBLIC_KEY_ALGORITHM_ED25519,
      publicKey: publicKey,
      displayName: 'Host $marker',
      platform: DevicePlatform.DEVICE_PLATFORM_MACOS,
    ),
    signalingEndpoint: 'wss://signal.example.test/v1/ws',
    pairedAtUnixMs: Int64(1700000000000 + marker),
    displayOrder: marker - 1,
  );
}
