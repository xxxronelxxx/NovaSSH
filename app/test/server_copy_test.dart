import 'package:flutter_test/flutter_test.dart';
import 'package:nova/app/server_copy.dart';
import 'package:nova/bridge/model.dart';

void main() {
  Server s3Server() => const Server(
    id: 's_1',
    groupId: null,
    name: 'bucket',
    host: 'https://s3.example.com',
    port: 443,
    user: '',
    auth: Auth(kind: AuthKind.password),
    passwordRef: null,
    jump: null,
    encoding: 'utf-8',
    remotePath: '/data',
    color: '#ff0000',
    tags: ['prod'],
    terminalProfile: 'putty',
    notes: 'n',
    lastConnected: 123,
    hostKeyFingerprint: 'SHA256:abc',
    authFailed: false,
    protocol: 's3',
    ftpsMode: 'explicit',
    ftpsInsecure: true,
    passive: false,
    s3Endpoint: 'https://s3.example.com',
    s3Region: 'us-east-1',
    s3Bucket: 'bucket',
    s3Prefix: 'backups',
    s3PathStyle: true,
    s3AccessRef: 's3a_1',
    s3SecretRef: 's3s_1',
    reachable: true,
    checkedAt: 456,
  );

  test('moving to a group keeps every transport field', () {
    final moved = s3Server().copyWith(groupId: 'g_1');

    expect(moved.groupId, 'g_1');
    expect(moved.protocol, 's3');
    expect(moved.s3Endpoint, 'https://s3.example.com');
    expect(moved.s3Region, 'us-east-1');
    expect(moved.s3Bucket, 'bucket');
    expect(moved.s3Prefix, 'backups');
    expect(moved.s3PathStyle, isTrue);
    expect(moved.s3AccessRef, 's3a_1');
    expect(moved.s3SecretRef, 's3s_1');
    expect(moved.ftpsMode, 'explicit');
    expect(moved.ftpsInsecure, isTrue);
    expect(moved.passive, isFalse);
    expect(moved.reachable, isTrue);
    expect(moved.checkedAt, 456);
    expect(moved.hostKeyFingerprint, 'SHA256:abc');
    expect(moved.tags, ['prod']);
  });

  test('clearing a nullable field works, keeping the rest', () {
    final cleared = s3Server().copyWith(
      groupId: null,
      s3Bucket: null,
      ftpsInsecure: null,
    );

    expect(cleared.groupId, isNull);
    expect(cleared.s3Bucket, isNull);
    expect(cleared.ftpsInsecure, isNull);
    expect(cleared.protocol, 's3');
    expect(cleared.passive, isFalse);
    expect(cleared.s3PathStyle, isTrue);
  });
}
