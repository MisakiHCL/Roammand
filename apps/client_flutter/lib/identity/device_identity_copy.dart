// SPDX-License-Identifier: MPL-2.0

import 'package:roammand_protocol/roammand_protocol.dart';

/// Copies a public identity, including its mutable protobuf bytes fields.
DeviceIdentity copyDeviceIdentity(
  DeviceIdentity identity,
) => identity.deepCopy()
  // Protobuf deepCopy shares scalar bytes fields. Keep identity snapshots
  // independent while preserving all other fields, including unknown fields.
  ..deviceId = List<int>.of(identity.deviceId)
  ..publicKey = List<int>.of(identity.publicKey);
