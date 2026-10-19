import 'package:flutter_test/flutter_test.dart';
import 'package:mytree_webrtc_demo/ice_configuration.dart';

void main() {
  group('IceConfiguration', () {
    test(
      'an explicit empty configuration only uses the two Google STUN servers',
      () {
        const configuration = IceConfiguration();

        expect(configuration.validationError, isNull);
        expect(configuration.hasTurn, isFalse);
        expect(configuration.turnUrls, isEmpty);
        expect(configuration.turnUsername, isEmpty);
        expect(configuration.turnCredential, isEmpty);
        expect(configuration.toRtcConfiguration(), <String, dynamic>{
          'iceServers': <Map<String, dynamic>>[
            {
              'urls': <String>['stun:stun.l.google.com:19302'],
            },
            {
              'urls': <String>['stun:stun1.l.google.com:19302'],
            },
          ],
          'sdpSemantics': 'unified-plan',
          'iceTransportPolicy': 'all',
        });
      },
    );

    const hasTurnOverrides =
        bool.hasEnvironment('TURN_URLS') ||
        bool.hasEnvironment('TURN_USERNAME') ||
        bool.hasEnvironment('TURN_CREDENTIAL');

    test('uses the public guest TURN by default', () {
      const configuration = IceConfiguration.fromEnvironment();

      expect(configuration.validationError, isNull);
      expect(configuration.hasTurn, isTrue);
      expect(
        configuration.turnUrls,
        'turn:turn.evan-brass.net,'
        'turn:turn.evan-brass.net?transport=tcp,'
        'turns:turn.evan-brass.net:443?transport=tcp',
      );
      expect(configuration.turnUsername, 'guest');
      expect(configuration.turnCredential, 'password');
      final rtcConfiguration = configuration.toRtcConfiguration();
      final servers = rtcConfiguration['iceServers'] as List;
      expect(servers, hasLength(3));
      expect(servers.last, {
        'urls': [
          'turn:turn.evan-brass.net',
          'turn:turn.evan-brass.net?transport=tcp',
          'turns:turn.evan-brass.net:443?transport=tcp',
        ],
        'username': 'guest',
        'credential': 'password',
      });
      expect(
        rtcConfiguration['iceTransportPolicy'],
        const bool.fromEnvironment('TURN_FORCE_RELAY') ? 'relay' : 'all',
      );
    }, skip: hasTurnOverrides);

    test('reads TURN overrides without inheriting public credentials', () {
      const configuration = IceConfiguration.fromEnvironment();

      expect(configuration.turnUrls, const String.fromEnvironment('TURN_URLS'));
      expect(
        configuration.turnUsername,
        const String.fromEnvironment('TURN_USERNAME'),
      );
      expect(
        configuration.turnCredential,
        const String.fromEnvironment('TURN_CREDENTIAL'),
      );
      if (configuration.turnUrls.isNotEmpty &&
          (configuration.turnUsername.isEmpty ||
              configuration.turnCredential.isEmpty)) {
        expect(configuration.validationError, isNotNull);
        expect(configuration.toRtcConfiguration, throwsArgumentError);
      }
      if (configuration.turnUrls.isEmpty &&
          configuration.turnUsername.isEmpty &&
          configuration.turnCredential.isEmpty &&
          !configuration.forceRelay) {
        expect(configuration.hasTurn, isFalse);
        expect(configuration.toRtcConfiguration()['iceServers'], hasLength(2));
      }
    }, skip: !hasTurnOverrides);

    test('reads the compile-time forced-relay setting', () {
      const configuration = IceConfiguration.fromEnvironment();

      expect(
        configuration.forceRelay,
        const bool.fromEnvironment('TURN_FORCE_RELAY'),
      );
    });

    test('adds supplied TURN credentials with UDP, TCP and TLS URLs', () {
      const configuration = IceConfiguration(
        turnUrls:
            'turn:relay.example.com:3478?transport=udp,'
            'turn:relay.example.com:3478?transport=tcp,'
            'turns:relay.example.com:443?transport=tcp',
        turnUsername: 'fixture-user',
        turnCredential: 'fixture-credential',
      );

      expect(configuration.validationError, isNull);
      expect(configuration.hasTurn, isTrue);
      final rtcConfiguration = configuration.toRtcConfiguration();
      final servers = rtcConfiguration['iceServers'] as List;
      expect(servers, hasLength(3));
      expect(servers[0], {
        'urls': ['stun:stun.l.google.com:19302'],
      });
      expect(servers[1], {
        'urls': ['stun:stun1.l.google.com:19302'],
      });
      expect(servers[2], {
        'urls': [
          'turn:relay.example.com:3478?transport=udp',
          'turn:relay.example.com:3478?transport=tcp',
          'turns:relay.example.com:443?transport=tcp',
        ],
        'username': 'fixture-user',
        'credential': 'fixture-credential',
      });
      expect(rtcConfiguration['sdpSemantics'], 'unified-plan');
      expect(rtcConfiguration['iceTransportPolicy'], 'all');
    });

    test('trims list separators without accepting whitespace inside a URL', () {
      const configuration = IceConfiguration(
        turnUrls: ' turn:relay.example.com , turns:relay.example.com:443 ',
        turnUsername: 'fixture-user',
        turnCredential: 'fixture-credential',
      );

      expect(configuration.validationError, isNull);
      final servers = configuration.toRtcConfiguration()['iceServers'] as List;
      expect(servers.last['urls'], [
        'turn:relay.example.com',
        'turns:relay.example.com:443',
      ]);
    });

    for (final url in [
      'turn:relay.example.com',
      'turns:relay.example.com',
      'turn:relay.example.com.:3478',
      'turn:192.0.2.1:3478?transport=udp',
      'turn:[2001:db8::1]:3478?transport=tcp',
      'turns:[::1]:443?transport=tcp',
      'turn:[::ffff:192.0.2.1]:3478',
    ]) {
      test('accepts a valid TURN host in $url', () {
        final configuration = IceConfiguration(
          turnUrls: url,
          turnUsername: 'fixture-user',
          turnCredential: 'fixture-credential',
        );

        expect(configuration.validationError, isNull);
        expect(configuration.hasTurn, isTrue);
      });
    }

    const partialConfigurations = <String, IceConfiguration>{
      'URLs alone': IceConfiguration(turnUrls: 'turn:relay.example.com:3478'),
      'username alone': IceConfiguration(turnUsername: 'fixture-user'),
      'credential alone': IceConfiguration(
        turnCredential: 'fixture-credential',
      ),
      'credentials without URLs': IceConfiguration(
        turnUsername: 'fixture-user',
        turnCredential: 'fixture-credential',
      ),
      'missing username': IceConfiguration(
        turnUrls: 'turn:relay.example.com:3478',
        turnCredential: 'fixture-credential',
      ),
      'missing credential': IceConfiguration(
        turnUrls: 'turn:relay.example.com:3478',
        turnUsername: 'fixture-user',
      ),
      'blank username': IceConfiguration(
        turnUrls: 'turn:relay.example.com:3478',
        turnUsername: ' ',
        turnCredential: 'fixture-credential',
      ),
      'blank credential': IceConfiguration(
        turnUrls: 'turn:relay.example.com:3478',
        turnUsername: 'fixture-user',
        turnCredential: '\t',
      ),
      'blank URLs': IceConfiguration(
        turnUrls: ' ',
        turnUsername: 'fixture-user',
        turnCredential: 'fixture-credential',
      ),
    };
    for (final entry in partialConfigurations.entries) {
      test('rejects partial TURN configuration: ${entry.key}', () {
        expect(entry.value.validationError, isNotNull);
        expect(entry.value.validationError, contains('TURN_'));
        expect(entry.value.hasTurn, isFalse);
        expect(entry.value.toRtcConfiguration, throwsArgumentError);
      });
    }

    for (final url in [
      'stun:stun.example.com:3478',
      'https://relay.example.com',
      'relay.example.com:3478',
      'turn:',
      'turn::3478',
      'turn://relay.example.com:3478',
      'turn:relay example.com:3478',
      'turn:relay.example.com :3478',
      'turn:relay.example.com:3478\n?transport=tcp',
      'turn:relay.example.com/path',
      'turn:relay.example.com#fragment',
      'turn:user@relay.example.com:3478',
      'turn:relay.example.com:0',
      'turn:relay.example.com:65536',
      'turn:relay.example.com:abc',
      'turn:relay.example.com:',
      'turn:relay.example.com?transport=sctp',
      'turn:relay.example.com?transport=tcp&extra=value',
      'turn:.',
      'turn:-relay.example.com',
      'turn:relay..example.com',
      'turn:999.0.2.1:3478',
      'turn:2001:db8::1:3478',
      'turn:[2001:::1]:3478',
      'turn:[12345::1]:3478',
      'turn:[192.0.2.1]:3478',
      'turn:relay.example.com:3478,',
      ',turn:relay.example.com:3478',
      'turn:relay.example.com:3478,,turns:relay.example.com:443',
      'turn:relay.example.com:3478,stun:stun.example.com:3478',
    ]) {
      test('rejects malformed TURN URLs: ${url.replaceAll('\n', r'\n')}', () {
        final configuration = IceConfiguration(
          turnUrls: url,
          turnUsername: 'fixture-user',
          turnCredential: 'fixture-credential',
        );

        expect(configuration.validationError, isNotNull);
        expect(configuration.hasTurn, isFalse);
        expect(configuration.toRtcConfiguration, throwsArgumentError);
      });
    }

    test('forces relay only with a valid complete TURN configuration', () {
      const configuration = IceConfiguration(
        turnUrls: 'turns:relay.example.com:443?transport=tcp',
        turnUsername: 'fixture-user',
        turnCredential: 'fixture-credential',
        forceRelay: true,
      );

      expect(configuration.validationError, isNull);
      expect(configuration.hasTurn, isTrue);
      expect(configuration.toRtcConfiguration()['iceTransportPolicy'], 'relay');
    });

    test(
      'rejects forced relay without TURN instead of falling back to STUN',
      () {
        const configuration = IceConfiguration(forceRelay: true);

        expect(configuration.validationError, contains('TURN_FORCE_RELAY'));
        expect(configuration.hasTurn, isFalse);
        expect(configuration.toRtcConfiguration, throwsArgumentError);
      },
    );

    test(
      'does not include supplied credentials or URLs in validation errors',
      () {
        const configuration = IceConfiguration(
          turnUrls: 'turn:fixture-user:fixture-secret@relay.example.com:3478',
          turnUsername: 'fixture-user',
          turnCredential: 'fixture-secret',
        );

        final error = configuration.validationError!;
        expect(error, isNot(contains(configuration.turnUsername)));
        expect(error, isNot(contains(configuration.turnCredential)));
        expect(error, isNot(contains(configuration.turnUrls)));
        expect(
          configuration.toRtcConfiguration,
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.toString(),
              'message',
              allOf(
                isNot(contains(configuration.turnUsername)),
                isNot(contains(configuration.turnCredential)),
                isNot(contains(configuration.turnUrls)),
              ),
            ),
          ),
        );
      },
    );

    test('returns independent RTC configuration maps', () {
      const configuration = IceConfiguration();
      final first = configuration.toRtcConfiguration();
      final firstServers = first['iceServers'] as List;
      (firstServers.first['urls'] as List).clear();
      firstServers.clear();
      first['iceTransportPolicy'] = 'relay';

      final second = configuration.toRtcConfiguration();
      expect(second['iceTransportPolicy'], 'all');
      final secondServers = second['iceServers'] as List;
      expect(secondServers, hasLength(2));
      expect(secondServers.first['urls'], ['stun:stun.l.google.com:19302']);
    });
  });
}
