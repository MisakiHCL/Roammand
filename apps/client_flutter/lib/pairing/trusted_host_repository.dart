// SPDX-License-Identifier: MPL-2.0

import 'dart:async';
import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:roammand/identity/device_identity_copy.dart';
import 'package:roammand/identity/device_display_name.dart';
import 'package:roammand_protocol/roammand_protocol.dart';

import 'trusted_host_store.dart';

enum TrustedHostRepositoryError {
  notInitialized,
  duplicateHost,
  hostNotFound,
  invalidDisplayName,
  invalidTimestamp,
  persistence,
  closed,
}

final class TrustedHostRepositoryException implements Exception {
  const TrustedHostRepositoryException(this.code);

  final TrustedHostRepositoryError code;

  @override
  String toString() => 'TrustedHostRepositoryException(${code.name})';
}

final class TrustedHostRecord {
  TrustedHostRecord._(TrustedHostBinding binding)
    : _hostIdentity = copyDeviceIdentity(binding.hostIdentity),
      signalingEndpoint = Uri.parse(binding.signalingEndpoint),
      pairedAtUnixMs = binding.pairedAtUnixMs.toInt(),
      lastSuccessfulConnectionAtUnixMs = binding
          .lastSuccessfulConnectionAtUnixMs
          .toInt(),
      displayOrder = binding.displayOrder,
      _localAlias = binding.localAlias;

  final DeviceIdentity _hostIdentity;
  final Uri signalingEndpoint;
  final int pairedAtUnixMs;
  final int lastSuccessfulConnectionAtUnixMs;
  final int displayOrder;
  final String _localAlias;

  DeviceIdentity get hostIdentity => copyDeviceIdentity(_hostIdentity);
  String get displayName =>
      _localAlias.isEmpty ? _hostIdentity.displayName : _localAlias;
  String? get localAlias => _localAlias.isEmpty ? null : _localAlias;

  TrustedHostBinding toBinding() => TrustedHostBinding(
    hostIdentity: copyDeviceIdentity(_hostIdentity),
    signalingEndpoint: signalingEndpoint.toString(),
    pairedAtUnixMs: Int64(pairedAtUnixMs),
    lastSuccessfulConnectionAtUnixMs: Int64(lastSuccessfulConnectionAtUnixMs),
    displayOrder: displayOrder,
    localAlias: _localAlias,
  );
}

final class TrustedHostRepository {
  factory TrustedHostRepository({
    required TrustedHostPersistence persistence,
  }) => TrustedHostRepository._(persistence);

  TrustedHostRepository._(this._persistence);

  final TrustedHostPersistence _persistence;
  final StreamController<List<TrustedHostRecord>> _changes =
      StreamController<List<TrustedHostRecord>>.broadcast(sync: true);
  Future<void> _previousOperation = Future<void>.value();
  List<TrustedHostRecord> _hosts = const <TrustedHostRecord>[];
  bool _initialized = false;
  bool _closed = false;

  Stream<List<TrustedHostRecord>> get changes => _changes.stream;
  List<TrustedHostRecord> get hosts =>
      List<TrustedHostRecord>.unmodifiable(_hosts);

  Future<void> initialize() => _serialized(() async {
    _ensureOpen();
    if (_initialized) {
      return;
    }
    try {
      final bindings = await _persistence.load();
      _hosts = _records(bindings);
      _initialized = true;
      _publish();
    } catch (_) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.persistence,
      );
    }
  });

  Future<void> add(TrustedHostBinding binding) => _serialized(() async {
    _ensureReady();
    final normalized = binding.deepCopy()..displayOrder = _hosts.length;
    try {
      validateTrustedHostBindings(<TrustedHostBinding>[normalized]);
    } catch (_) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.persistence,
      );
    }
    final key = _deviceKey(normalized.hostIdentity.deviceId);
    if (_hosts.any((host) => _deviceKey(host._hostIdentity.deviceId) == key)) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.duplicateHost,
      );
    }
    await _commit(<TrustedHostRecord>[
      ..._hosts,
      TrustedHostRecord._(normalized),
    ]);
  });

  /// Saves a successfully authenticated pairing.
  ///
  /// Re-pairing the same public Host identity replaces its signaling address
  /// while preserving list order. This is the explicit first-version migration
  /// path when a Host changes signaling services.
  Future<void> savePairing(TrustedHostBinding binding) => _serialized(() async {
    _ensureReady();
    final normalized = binding.deepCopy();
    try {
      validateTrustedHostBindings(<TrustedHostBinding>[
        normalized..displayOrder = 0,
      ]);
    } catch (_) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.persistence,
      );
    }
    final key = _deviceKey(normalized.hostIdentity.deviceId);
    final existingIndex = _hosts.indexWhere(
      (host) => _deviceKey(host._hostIdentity.deviceId) == key,
    );
    if (existingIndex < 0) {
      normalized.displayOrder = _hosts.length;
      await _commit(<TrustedHostRecord>[
        ..._hosts,
        TrustedHostRecord._(normalized),
      ]);
      return;
    }
    normalized
      ..displayOrder = _hosts[existingIndex].displayOrder
      ..lastSuccessfulConnectionAtUnixMs = Int64.ZERO
      ..localAlias = _hosts[existingIndex]._localAlias;
    final next = List<TrustedHostRecord>.of(_hosts)
      ..[existingIndex] = TrustedHostRecord._(normalized);
    await _commit(next);
  });

  Future<void> renameLocal(
    List<int> hostDeviceId, {
    required String displayName,
  }) => _serialized(() async {
    _ensureReady();
    final normalized = normalizeDeviceDisplayName(displayName);
    if (normalized == null) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.invalidDisplayName,
      );
    }
    final key = _deviceKey(hostDeviceId);
    final index = _hosts.indexWhere(
      (host) => _deviceKey(host._hostIdentity.deviceId) == key,
    );
    if (index < 0) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.hostNotFound,
      );
    }
    final current = _hosts[index];
    final localAlias = normalized == current._hostIdentity.displayName
        ? ''
        : normalized;
    if (localAlias == current._localAlias) return;
    final updated = current.toBinding()..localAlias = localAlias;
    final next = List<TrustedHostRecord>.of(_hosts)
      ..[index] = TrustedHostRecord._(updated);
    await _commit(next);
  });

  Future<bool> deleteLocal(List<int> hostDeviceId) => _serialized(() async {
    _ensureReady();
    final key = _deviceKey(hostDeviceId);
    final retained = _hosts
        .where((host) => _deviceKey(host._hostIdentity.deviceId) != key)
        .toList(growable: false);
    if (retained.length == _hosts.length) {
      return false;
    }
    final normalized = <TrustedHostRecord>[
      for (var index = 0; index < retained.length; index += 1)
        TrustedHostRecord._(retained[index].toBinding()..displayOrder = index),
    ];
    await _commit(normalized);
    return true;
  });

  Future<void> markSuccessfulConnection(
    List<int> hostDeviceId, {
    required int nowUnixMs,
  }) => _serialized(() async {
    _ensureReady();
    final key = _deviceKey(hostDeviceId);
    final index = _hosts.indexWhere(
      (host) => _deviceKey(host._hostIdentity.deviceId) == key,
    );
    if (index < 0) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.hostNotFound,
      );
    }
    final current = _hosts[index];
    if (nowUnixMs < current.pairedAtUnixMs ||
        nowUnixMs < current.lastSuccessfulConnectionAtUnixMs) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.invalidTimestamp,
      );
    }
    final updated = current.toBinding()
      ..lastSuccessfulConnectionAtUnixMs = Int64(nowUnixMs);
    final next = List<TrustedHostRecord>.of(_hosts)
      ..[index] = TrustedHostRecord._(updated);
    await _commit(next);
  });

  Future<void> close() => _serialized(() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _changes.close();
  });

  Future<void> _commit(List<TrustedHostRecord> next) async {
    try {
      await _persistence.save(next.map((host) => host.toBinding()));
    } catch (_) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.persistence,
      );
    }
    _hosts = List<TrustedHostRecord>.unmodifiable(next);
    _publish();
  }

  List<TrustedHostRecord> _records(List<TrustedHostBinding> bindings) {
    validateTrustedHostBindings(bindings);
    final sorted = bindings.map((binding) => binding.deepCopy()).toList()
      ..sort((left, right) => left.displayOrder.compareTo(right.displayOrder));
    return List<TrustedHostRecord>.unmodifiable(
      sorted.map(TrustedHostRecord._),
    );
  }

  void _publish() {
    if (!_changes.isClosed) {
      _changes.add(List<TrustedHostRecord>.unmodifiable(_hosts));
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.closed,
      );
    }
  }

  void _ensureReady() {
    _ensureOpen();
    if (!_initialized) {
      throw const TrustedHostRepositoryException(
        TrustedHostRepositoryError.notInitialized,
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final preceding = _previousOperation;
    final done = Completer<void>();
    _previousOperation = done.future;
    await preceding;
    try {
      return await operation();
    } finally {
      done.complete();
    }
  }
}

String _deviceKey(List<int> deviceId) => base64UrlEncode(deviceId);
