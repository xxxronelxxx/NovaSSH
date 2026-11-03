import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../bridge/model.dart';

/// Marker for "keep the current value" in [ServerCopy.copyWith].
const Object _keep = Object();

/// Field-preserving copy of a server.
///
/// The generated `Server` has no `copyWith`, and rebuilding it by hand dropped
/// half of its fields (protocol, S3 keys, FTPS flags, reachability) whenever a
/// server was moved to a group or edited, silently turning an S3 entry into an
/// SFTP one.
extension ServerCopy on Server {
  Server copyWith({
    String? id,
    Object? groupId = _keep,
    String? name,
    String? host,
    int? port,
    String? user,
    Auth? auth,
    Object? passwordRef = _keep,
    Object? jump = _keep,
    Object? encoding = _keep,
    Object? remotePath = _keep,
    Object? color = _keep,
    List<String>? tags,
    Object? terminalProfile = _keep,
    Object? notes = _keep,
    PlatformInt64? lastConnected,
    Object? hostKeyFingerprint = _keep,
    bool? authFailed,
    Object? protocol = _keep,
    Object? ftpsMode = _keep,
    Object? ftpsInsecure = _keep,
    Object? passive = _keep,
    Object? s3Endpoint = _keep,
    Object? s3Region = _keep,
    Object? s3Bucket = _keep,
    Object? s3Prefix = _keep,
    Object? s3PathStyle = _keep,
    Object? s3AccessRef = _keep,
    Object? s3SecretRef = _keep,
    Object? reachable = _keep,
    PlatformInt64? checkedAt,
  }) {
    T pick<T>(Object? value, T current) =>
        identical(value, _keep) ? current : value as T;

    return Server(
      id: id ?? this.id,
      groupId: pick<String?>(groupId, this.groupId),
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      auth: auth ?? this.auth,
      passwordRef: pick<String?>(passwordRef, this.passwordRef),
      jump: pick<JumpHost?>(jump, this.jump),
      encoding: pick<String?>(encoding, this.encoding),
      remotePath: pick<String?>(remotePath, this.remotePath),
      color: pick<String?>(color, this.color),
      tags: tags ?? this.tags,
      terminalProfile: pick<String?>(terminalProfile, this.terminalProfile),
      notes: pick<String?>(notes, this.notes),
      lastConnected: lastConnected ?? this.lastConnected,
      hostKeyFingerprint: pick<String?>(
        hostKeyFingerprint,
        this.hostKeyFingerprint,
      ),
      authFailed: authFailed ?? this.authFailed,
      protocol: pick<String?>(protocol, this.protocol),
      ftpsMode: pick<String?>(ftpsMode, this.ftpsMode),
      ftpsInsecure: pick<bool?>(ftpsInsecure, this.ftpsInsecure),
      passive: pick<bool?>(passive, this.passive),
      s3Endpoint: pick<String?>(s3Endpoint, this.s3Endpoint),
      s3Region: pick<String?>(s3Region, this.s3Region),
      s3Bucket: pick<String?>(s3Bucket, this.s3Bucket),
      s3Prefix: pick<String?>(s3Prefix, this.s3Prefix),
      s3PathStyle: pick<bool?>(s3PathStyle, this.s3PathStyle),
      s3AccessRef: pick<String?>(s3AccessRef, this.s3AccessRef),
      s3SecretRef: pick<String?>(s3SecretRef, this.s3SecretRef),
      reachable: pick<bool?>(reachable, this.reachable),
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}
