import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mytree_webrtc_demo/ice_configuration.dart';
import 'package:mytree_webrtc_demo/main.dart';
import 'package:mytree_webrtc_demo/local/room_tabs.dart';
import 'package:mytree_webrtc_demo/room_document.dart';
import 'package:mytree_webrtc_demo/room_identity.dart';
import 'package:mytree_webrtc_demo/room_protocol.dart';
import 'package:mytree_webrtc_demo/room_session.dart';
import 'package:mytree_webrtc_demo/tree/tree_document.dart';
import 'package:mytree_webrtc_demo/ui/tree_editor.dart';
import 'package:mytree_webrtc_demo/signaling/peerjs_signaling.dart';
import 'package:mytree_webrtc_demo/storage/room_store.dart';
import 'package:mytree_webrtc_demo/ui/room_dialogs.dart';
import 'package:mytree_webrtc_demo/ui/room_page.dart';
import 'package:mytree_webrtc_demo/ui/tree_brand.dart';
import 'package:peer_rtc/peer_rtc.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _FakePeer implements Peer {
  _FakePeer(this.id, this.options);
  @override
  final String id;
  @override
  final PeerOptions options;
  final _events = <String?, StreamController<dynamic>>{};
  final outbound = <_FakeConnection>[];
  @override
  bool open = false;
  @override
  bool disconnected = false;
  @override
  bool destroyed = false;

  @override
  Stream<T> on<T>([String? type]) => _events
      .putIfAbsent(type, () => StreamController<dynamic>.broadcast(sync: true))
      .stream
      .cast<T>();

  void register() {
    open = true;
    _events['open']?.add(id);
  }

  void accept(DataConnection channel) => _events['connection']?.add(channel);

  void rejectAlias() => _events['error']?.add('ID $id is taken');

  @override
  DataConnection connect(String target, {PeerConnectOption? options}) {
    final channel = _FakeConnection(peerId: target);
    outbound.add(channel);
    return channel;
  }

  @override
  void cancelReconnect() {}
  @override
  void dispose() {
    destroyed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnection implements DataConnection {
  _FakeConnection({this.peerId = 'participant'});

  final String peerId;
  final sent = <Map<String, dynamic>>[];
  final _events = <String?, StreamController<dynamic>>{};
  @override
  String get peer => peerId;
  @override
  bool open = true;
  @override
  bool disposed = false;
  @override
  RTCPeerConnection? get peerConnection => null;

  @override
  Stream<T> on<T>([String? type]) => _events
      .putIfAbsent(type, () => StreamController<dynamic>.broadcast(sync: true))
      .stream
      .cast<T>();

  void receive(Map<String, dynamic> data) => _events['data']?.add(data);

  @override
  void close() {
    open = false;
    _events['close']?.add(null);
  }

  @override
  Future<void> send(dynamic data) async {
    sent.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map));
  }

  @override
  void dispose() {
    disposed = true;
    open = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalTabs implements RoomTabs {
  final roles = StreamController<void>.broadcast();
  final states = StreamController<RoomTabState>.broadcast();
  bool started = false;
  bool disposed = false;
  int requests = 0;

  @override
  bool get isLeader => false;
  @override
  Stream<void> get onRoleChanged => roles.stream;
  @override
  Stream<RoomTabState> get onState => states.stream;
  @override
  Future<void> start() async => started = true;
  @override
  void publish(RoomTabState state) =>
      throw StateError('Follower cannot publish');
  @override
  void requestState() => requests++;
  @override
  void dispose() {
    disposed = true;
    unawaited(roles.close());
    unawaited(states.close());
  }
}

class _HistoryFailingStore extends MemoryRoomStore {
  bool failWrites = false;
  Completer<void>? historyWrite;

  @override
  Future<void> appendHistory(
    String roomId,
    List<Map<String, dynamic>> operations,
  ) async {
    if (failWrites) throw StateError('History write blocked');
    await historyWrite?.future;
    await super.appendHistory(roomId, operations);
  }
}

class _CountingHistoryStore extends MemoryRoomStore {
  int historyLoads = 0;

  @override
  Future<List<Map<String, dynamic>>> loadHistory(String roomId) {
    historyLoads++;
    return super.loadHistory(roomId);
  }
}

class _MetadataFailingStore extends MemoryRoomStore {
  bool failMetadata = false;

  @override
  Future<void> saveMembership(String roomId) => failMetadata
      ? Future<void>.error(StateError('Metadata write blocked'))
      : super.saveMembership(roomId);
}

// Keep the text-demo cases as room lifecycle regressions without retaining a
// second, legacy editor in production.
class _LifecycleTestEditor extends StatefulWidget {
  const _LifecycleTestEditor({required this.session});

  final RoomSession session;

  @override
  State<_LifecycleTestEditor> createState() => _LifecycleTestEditorState();
}

class _LifecycleTestEditorState extends State<_LifecycleTestEditor> {
  final _controller = TextEditingController();
  String _observedText = '';

  @override
  void initState() {
    super.initState();
    _syncText();
    widget.session.addListener(_sessionChanged);
  }

  @override
  void didUpdateWidget(_LifecycleTestEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    oldWidget.session.removeListener(_sessionChanged);
    widget.session.addListener(_sessionChanged);
    _observedText = '';
    _controller.clear();
    _syncText();
  }

  void _syncText() {
    final text = widget.session.text;
    if (text == _observedText) return;
    _observedText = text;
    if (_controller.text != text) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  void _sessionChanged() {
    if (!mounted) return;
    setState(_syncText);
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return TextField(
      key: const Key('room-text'),
      controller: _controller,
      enabled: session.editable,
      readOnly: !session.canEdit,
      expands: true,
      minLines: null,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        labelText: 'Общее текстовое поле',
        hintText: 'Напишите что-нибудь…',
        helperText: session.canEdit ? null : 'Гость · только просмотр',
        border: const OutlineInputBorder(),
      ),
      onChanged: (text) => unawaited(session.edit(text)),
    );
  }
}

void main() {
  const roomId = '1234567890abcdef1234567890abcdef';
  late MemoryRoomStore store;
  late List<_FakePeer> peers;

  setUp(() {
    store = MemoryRoomStore();
    peers = [];
  });

  Future<void> finishSoloDiscovery(WidgetTester tester) async {
    for (final peer in peers.where(
      (peer) => !peer.destroyed && peer.id.startsWith('mytree-room-'),
    )) {
      if (!peer.open) peer.register();
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  Future<void> answerNamePrompt(
    WidgetTester tester, {
    String name = 'Участник',
  }) async {
    await tester.pump();
    if (find.byKey(const Key('participant-name')).evaluate().isEmpty) return;
    await tester.enterText(find.byKey(const Key('participant-name')), name);
    await tester.tap(find.text('Продолжить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    Uri? uri,
    bool discoverSolo = true,
    bool seedName = true,
    bool answerName = true,
    bool useDefaultEditor = false,
    RoomTabsFactory? roomTabsFactory,
  }) async {
    if (seedName && await store.hasMembership(roomId)) {
      final actor = await store.loadClientId();
      final history = decodeRoomHistory(await store.loadHistory(roomId));
      final document = RoomDocument()..merge(history);
      if (document.participantNames[actor] == null) {
        await store.appendHistory(roomId, [
          RoomEdit(
            id: 'local-profile',
            author: actor,
            clock: 0,
            createdAt: 0,
            text: 'Участник',
            kind: RoomEditKind.participantName,
          ).toJson(),
        ]);
      }
    }
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MyTreeDemoApp(
        store: store,
        roomTabsFactory: roomTabsFactory,
        roomEditorBuilder: useDefaultEditor
            ? null
            : (session) => _LifecycleTestEditor(session: session),
        applicationUri: uri ?? Uri.parse('https://current.example/app/'),
        iceConfiguration: const IceConfiguration(),
        peerFactory: (id, configuration) {
          final peer = _FakePeer(
            id,
            PeerOptions(autoReconnect: false, config: configuration),
          );
          peers.add(peer);
          return PeerJsSignalingPeer(peer);
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    if (answerName) await answerNamePrompt(tester);
    if (discoverSolo) await finishSoloDiscovery(tester);
  }

  Future<void> settings(WidgetTester tester, String item) async {
    await tester.tap(
      find.byKey(
        Key(
          item == 'Пригласить участников' ? 'participants-button' : 'room-menu',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.text(item));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Future<void> reopenLastRoom(WidgetTester tester) async {
    await tester.tap(find.text('Присоединиться'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Подключиться'));
    await tester.pump();
    await tester.pump();
    await finishSoloDiscovery(tester);
  }

  Future<String> seedGuestRoom() async {
    await store.saveMembership(roomId);
    final actor = await store.loadClientId();
    await store.appendHistory(roomId, [
      RoomEdit(
        id: 'guest-profile',
        author: actor,
        clock: 1,
        createdAt: 1,
        text: 'Мария',
        kind: RoomEditKind.participantName,
      ).toJson(),
      RoomEdit(
        id: 'guest-role',
        author: actor,
        clock: 2,
        createdAt: 2,
        text: 'guest',
        kind: RoomEditKind.participantRole,
        targetActor: actor,
      ).toJson(),
      const RoomEdit(
        id: 'editor-profile',
        author: 'editor',
        clock: 3,
        createdAt: 3,
        text: 'Анна',
        kind: RoomEditKind.participantName,
      ).toJson(),
      const RoomEdit(
        id: 'other-guest-profile',
        author: 'other-guest',
        clock: 4,
        createdAt: 4,
        text: 'Иван',
        kind: RoomEditKind.participantName,
      ).toJson(),
      const RoomEdit(
        id: 'other-guest-role',
        author: 'other-guest',
        clock: 5,
        createdAt: 5,
        text: 'guest',
        kind: RoomEditKind.participantRole,
        targetActor: 'other-guest',
      ).toJson(),
      const RoomEdit(
        id: 'shared-text',
        author: 'editor',
        clock: 6,
        createdAt: 6,
        text: 'Семейные заметки',
      ).toJson(),
    ]);
    return actor;
  }

  Future<String> seedBoundRoom({
    String alias = '',
    RoomRole role = RoomRole.editor,
  }) async {
    await store.saveMembership(roomId);
    final actor = await store.loadClientId();
    final tree = TreeDocument();
    final operations = [
      tree.editText(rootTreePersonId, TreeTextField.name, 'Анна')!,
      tree.setIndividualSurname(
        rootTreePersonId,
        text: 'Иванова',
        decline: false,
      ),
      tree.bindActor(actor, rootTreePersonId),
      tree.bindActor('other-device', rootTreePersonId),
      tree.bindActor('another-device', rootTreePersonId),
    ];
    await store.appendHistory(roomId, [
      RoomEdit(
        id: 'self-profile',
        author: actor,
        clock: 1,
        createdAt: 1,
        text: alias,
        kind: RoomEditKind.participantName,
      ).toJson(),
      RoomEdit(
        id: 'self-role',
        author: 'editor',
        clock: 2,
        createdAt: 2,
        text: role.name,
        kind: RoomEditKind.participantRole,
        targetActor: actor,
      ).toJson(),
      const RoomEdit(
        id: 'other-profile',
        author: 'other-device',
        clock: 3,
        createdAt: 3,
        text: 'Другое устройство',
        kind: RoomEditKind.participantName,
      ).toJson(),
      for (var index = 0; index < operations.length; index++)
        RoomEdit(
          id: 'identity-tree-$index',
          author: 'editor',
          clock: index + 4,
          createdAt: index + 4,
          kind: RoomEditKind.tree,
          text: jsonEncode(operations[index].toJson()),
        ).toJson(),
    ]);
    return actor;
  }

  testWidgets('tree toolbar sits flush under the room header', (tester) async {
    await mount(tester, useDefaultEditor: true);
    await tester.tap(find.text('Создать комнату'));
    await answerNamePrompt(tester);
    final header = tester.getRect(find.byType(AppBar));
    final toolbar = tester.getRect(find.byKey(const Key('tree-toolbar')));
    expect(toolbar.top, closeTo(header.bottom, .1));
    expect(toolbar.left, closeTo(header.left, .1));
    expect(toolbar.right, closeTo(header.right, .1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'default room editor shows the root and saves biography immediately',
    (tester) async {
      await mount(tester, useDefaultEditor: true);
      await tester.tap(find.text('Создать комнату'));
      await answerNamePrompt(tester);
      final saved = (await store.loadLastRoom())!;
      final editor = tester.widget<TreeEditor>(find.byType(TreeEditor));
      expect(editor.session.requireFamilyTree, isTrue);
      expect(editor.session.tree.people.keys, [rootTreePersonId]);
      expect(find.byKey(const Key('tree-person-root')), findsOneWidget);
      expect(find.byKey(const Key('room-text')), findsNothing);
      expect(find.text('Общее текстовое поле'), findsNothing);

      await tester.tap(find.byKey(const Key('open-biography')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tree-biography-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('biography-edit-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('person-name-field')),
        'Анна',
      );
      await tester.pumpAndSettle();
      final biography = find.byKey(const Key('person-biography-field'));
      await tester.scrollUntilVisible(
        biography,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('tree-biography-panel')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(
        biography,
        'Семейная история, сохранённая без закрытия.',
      );
      await tester.pumpAndSettle();
      expect(editor.session.durableTree.person(rootTreePersonId)!.name, 'Анна');
      expect(
        editor.session.durableTree.person(rootTreePersonId)!.biography,
        'Семейная история, сохранённая без закрытия.',
      );
      final history = decodeRoomHistory(await store.loadHistory(saved));
      expect(
        history.where((edit) => edit.kind == RoomEditKind.tree),
        hasLength(2),
      );
      expect(history.where((edit) => edit.kind == RoomEditKind.text), isEmpty);
      await tester.tap(find.byKey(const Key('biography-close')));
      await tester.pumpAndSettle();
      await settings(tester, 'Выход в меню');
      await reopenLastRoom(tester);
      final restored = tester
          .widget<TreeEditor>(find.byType(TreeEditor))
          .session;
      expect(restored.tree.person(rootTreePersonId)!.name, 'Анна');
      expect(
        restored.tree.person(rootTreePersonId)!.biography,
        'Семейная история, сохранённая без закрытия.',
      );
      expect(find.byKey(const Key('room-text')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('default guest can view the tree biography but cannot edit it', (
    tester,
  ) async {
    await seedGuestRoom();
    final tree = TreeDocument();
    await store.appendHistory(roomId, [
      for (final field in [TreeTextField.name, TreeTextField.biography])
        RoomEdit(
          id: 'tree-${field.name}',
          author: 'editor',
          clock: field == TreeTextField.name ? 7 : 8,
          createdAt: 8,
          kind: RoomEditKind.tree,
          text: jsonEncode(
            tree
                .editText(
                  rootTreePersonId,
                  field,
                  field == TreeTextField.name ? 'Анна' : 'История семьи',
                )!
                .toJson(),
          ),
        ).toJson(),
    ]);
    await mount(tester, useDefaultEditor: true);
    final session = tester.widget<TreeEditor>(find.byType(TreeEditor)).session;
    expect(session.requireFamilyTree, isTrue);
    expect(session.canEdit, isFalse);
    expect(find.byKey(const Key('tree-person-root')), findsOneWidget);
    expect(find.byKey(const Key('room-text')), findsNothing);
    final before = await store.loadHistory(roomId);
    await tester.tap(find.byKey(const Key('open-biography')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tree-biography-panel')), findsOneWidget);
    expect(find.text('История семьи'), findsOneWidget);
    expect(find.byKey(const Key('biography-edit-toggle')), findsNothing);
    expect(find.byKey(const Key('person-name-field')), findsNothing);
    expect(find.byKey(const Key('person-biography-field')), findsNothing);
    expect(find.byKey(const Key('add-relative')), findsNothing);
    expect(find.byKey(const Key('add-fact')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('tree-biography-panel')),
        matching: find.byType(TextField),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('tree-search-field')), findsOneWidget);
    expect(await store.loadHistory(roomId), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'default admission requires familyTree before the first tree edit',
    (tester) async {
      await mount(
        tester,
        uri: Uri.parse('https://current.example/#room=$roomId&role=guest'),
        discoverSolo: false,
        useDefaultEditor: true,
      );
      peers.single.register();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final channel = peers.single.outbound.single;
      expect(
        channel.sent.singleWhere(
          (message) => message['type'] == 'hello',
        )['familyTree'],
        isTrue,
      );
      expect(
        channel.sent.singleWhere(
          (message) => message['type'] == 'hello',
        )['explicitSiblings'],
        isTrue,
      );
      expect(await store.loadHistory(roomId), isEmpty);
      channel.receive(
        RoomMessage(
          roomId: roomId,
          type: RoomMessageType.welcome,
          actor: 'host',
          history: const [],
          hosting: true,
          online: 2,
          durableSync: true,
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          participantIdentity: true,
          personalSurnames: true,
          explicitSiblings: true,
          patronymics: true,
          marriageHistory: true,
        ).toJson(),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump();
      }
      expect(
        find.textContaining('ещё не поддерживает семейное дерево'),
        findsOneWidget,
      );
      expect(find.byType(TreeEditor), findsNothing);
      expect(await store.hasMembership(roomId), isFalse);
      expect(await store.loadHistory(roomId), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'default admission rejects a peer without explicit siblings before importing history',
    (tester) async {
      await mount(
        tester,
        uri: Uri.parse('https://current.example/#room=$roomId&role=guest'),
        discoverSolo: false,
        useDefaultEditor: true,
      );
      peers.single.register();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final channel = peers.single.outbound.single;
      expect(
        channel.sent.singleWhere(
          (message) => message['type'] == 'hello',
        )['explicitSiblings'],
        isTrue,
      );
      channel.receive(
        RoomMessage(
          roomId: roomId,
          type: RoomMessageType.welcome,
          actor: 'host',
          history: const [],
          hosting: true,
          online: 2,
          durableSync: true,
          roomMetadata: true,
          roomRoles: true,
          familyTree: true,
          familySurnames: true,
          personalSurnames: true,
          patronymics: true,
          marriageHistory: true,
          authorHistory: true,
          participantIdentity: true,
        ).toJson(),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump();
      }
      expect(find.byType(TreeEditor), findsNothing);
      expect(
        find.textContaining(
          'ещё не поддерживает прямые связи братьев и сестёр',
        ),
        findsOneWidget,
      );
      expect(await store.hasMembership(roomId), isFalse);
      expect(await store.loadHistory(roomId), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saved guest stays read-only until explicitly entering through an editor link',
    (tester) async {
      final actor = await seedGuestRoom();
      await mount(tester);
      final text = find.byKey(const Key('room-text'));
      final historyLength = (await store.loadHistory(roomId)).length;
      expect(tester.widget<TextField>(text).readOnly, isTrue);
      expect(
        tester.widget<TextField>(text).controller!.text,
        'Семейные заметки',
      );
      expect(find.text('Гость · только просмотр'), findsOneWidget);
      await tester.tap(text);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      expect((await store.loadHistory(roomId)).length, historyLength);
      await settings(tester, 'Настройки комнаты');
      expect(
        tester.widget<TextField>(find.byKey(const Key('room-name'))).readOnly,
        isTrue,
      );
      expect(find.text('Сохранить'), findsNothing);
      expect(find.text('Доступ только для просмотра'), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('participants-list')), findsOneWidget);
      expect(find.text('Редакторы'), findsNothing);
      expect(find.text('Гости'), findsNothing);
      expect(find.byKey(Key('guest-badge-$actor')), findsOneWidget);
      expect(find.byKey(const Key('guest-badge-other-guest')), findsOneWidget);
      expect(find.byKey(const Key('guest-badge-editor')), findsNothing);
      expect(find.text('Сделать редактором'), findsNothing);
      final otherGuest = find.byKey(const Key('participant-other-guest'));
      await tester.ensureVisible(otherGuest);
      await tester.tap(otherGuest);
      await tester.pump();
      expect(find.text('Сделать редактором?'), findsNothing);
      final ownAvatar = find.byKey(Key('participant-$actor'));
      await tester.ensureVisible(ownAvatar);
      await tester.tap(ownAvatar);
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(find.text('Вы'), findsNothing);
      expect(find.text('Изменить имя'), findsNothing);
      expect(
        find.descendant(
          of: ownAvatar,
          matching: find.byKey(const Key('self-participant-glow')),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await settings(tester, 'Изменить моё имя');
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(find.text('Изменить моё имя'), findsOneWidget);
      expect(find.text('Продолжить'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('participant-name')))
            .controller!
            .text,
        'Мария',
      );
      await tester.enterText(
        find.byKey(const Key('participant-name')),
        '  Мария Новая  ',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      expect(find.text('Мария Новая'), findsOneWidget);
      var document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantNames[actor], 'Мария Новая');
      expect(document.participantRoles[actor], RoomRole.guest);
      expect(document.text, 'Семейные заметки');
      await tester.tap(find.text('Пригласить участников'));
      await tester.pumpAndSettle();
      expect(find.byType(InviteParticipantsDialog), findsOneWidget);
      expect(
        tester
            .widget<InviteParticipantsDialog>(
              find.byType(InviteParticipantsDialog),
            )
            .canInviteEditors,
        isFalse,
      );
      await tester.tap(find.text('Редактор'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<RoomRole>>(
              find.byKey(const Key('invitation-role')),
            )
            .selected,
        {RoomRole.guest},
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(
        tester,
        uri: Uri.parse('https://current.example/#room=$roomId&role=editor'),
      );
      expect(tester.widget<TextField>(text).readOnly, isFalse);
      document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantRoles[actor], RoomRole.editor);
      expect(document.participantRoles['other-guest'], RoomRole.guest);
      expect(document.participantNames[actor], 'Мария Новая');
      expect(
        document.history.where(
          (edit) =>
              edit.kind == RoomEditKind.participantRole &&
              edit.targetActor == actor,
        ),
        hasLength(2),
      );
      final promotedHistory = await store.loadHistory(roomId);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester);
      expect(tester.widget<TextField>(text).readOnly, isFalse);
      expect(await store.loadHistory(roomId), promotedHistory);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final input in [
    roomId,
    'https://current.example/#room=$roomId&role=guest',
    'https://current.example/#room=$roomId&role=editor',
  ]) {
    testWidgets('saved guest enters pasted invitation $input', (tester) async {
      final actor = await seedGuestRoom();
      await mount(tester);
      await settings(tester, 'Выход в меню');
      await tester.tap(find.text('Присоединиться'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(JoinRoomDialog),
          matching: find.byType(TextField),
        ),
        input,
      );
      await tester.tap(find.text('Подключиться'));
      await tester.pump();
      await tester.pump();
      await finishSoloDiscovery(tester);
      final editor = input.endsWith('role=editor');
      expect(
        tester.widget<TextField>(find.byKey(const Key('room-text'))).readOnly,
        !editor,
      );
      final document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(
        document.participantRoles[actor],
        editor ? RoomRole.editor : RoomRole.guest,
      );
      expect(document.participantRoles['other-guest'], RoomRole.guest);
      expect(
        document.history.where(
          (e) =>
              e.kind == RoomEditKind.participantRole && e.targetActor == actor,
        ),
        hasLength(editor ? 2 : 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'guest menu name cancel is harmless and failed save retries durably before broadcast',
    (tester) async {
      final failing = _HistoryFailingStore();
      store = failing;
      final actor = await seedGuestRoom();
      await mount(tester);
      final channel = _FakeConnection(peerId: 'editor-peer');
      peers.single.accept(channel);
      await tester.pump();
      channel.receive(
        RoomMessage(
          roomId: roomId,
          type: RoomMessageType.hello,
          actor: 'editor',
          history: const [],
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          participantIdentity: true,
          personalSurnames: true,
          explicitSiblings: true,
          patronymics: true,
          marriageHistory: true,
        ).toJson(),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump();
      }
      channel.sent.clear();
      final originalHistory = await store.loadHistory(roomId);
      final field = find.byKey(const Key('participant-name'));
      await settings(tester, 'Изменить моё имя');
      expect(tester.widget<TextField>(field).controller!.text, 'Мария');
      await tester.enterText(field, 'Не сохранять');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(await store.loadHistory(roomId), originalHistory);
      expect(
        channel.sent.where((packet) => packet['type'] == 'edits'),
        isEmpty,
      );

      await settings(tester, 'Изменить моё имя');
      expect(tester.widget<TextField>(field).controller!.text, 'Мария');
      failing.failWrites = true;
      await tester.enterText(field, 'Мария Новая');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(find.textContaining('Не удалось сохранить имя:'), findsOneWidget);
      expect(find.textContaining('History write blocked'), findsWidgets);
      expect(tester.widget<TextField>(field).controller!.text, 'Мария Новая');
      expect(await store.loadHistory(roomId), originalHistory);
      expect(
        channel.sent.where((packet) => packet['type'] == 'edits'),
        isEmpty,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Не удалось сохранить имя:'), findsOneWidget);
      failing.failWrites = false;
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(find.textContaining('Не удалось сохранить имя:'), findsNothing);
      final document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantNames[actor], 'Мария Новая');
      expect(document.participantRoles[actor], RoomRole.guest);
      expect(document.text, 'Семейные заметки');
      expect(
        document.history.where(
          (edit) =>
              edit.kind == RoomEditKind.participantName &&
              edit.author == actor &&
              edit.text == 'Мария Новая',
        ),
        hasLength(1),
      );
      final sentNameEdits = channel.sent
          .where((packet) => packet['type'] == 'edits')
          .expand((packet) => decodeRoomHistory(packet['history']))
          .where(
            (edit) =>
                edit.kind == RoomEditKind.participantName &&
                edit.author == actor &&
                edit.text == 'Мария Новая',
          );
      expect(sentNameEdits, isNotEmpty);
      for (final edit in sentNameEdits) {
        expect(
          edit.toJson(),
          document.history.singleWhere((saved) => saved.id == edit.id).toJson(),
        );
      }
      expect(
        tester.widget<TextField>(find.byKey(const Key('room-text'))).readOnly,
        isTrue,
      );
      await settings(tester, 'Изменить моё имя');
      expect(tester.widget<TextField>(field).controller!.text, 'Мария Новая');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real promotion failure keeps guest until persisted retry and reload',
    (tester) async {
      final failing = _HistoryFailingStore();
      store = failing;
      final actor = await seedGuestRoom();
      await store.appendHistory(roomId, [
        RoomEdit(
          id: 'self-promotion',
          author: 'editor',
          clock: 7,
          createdAt: 7,
          text: 'editor',
          kind: RoomEditKind.participantRole,
          targetActor: actor,
        ).toJson(),
      ]);
      await mount(tester);
      expect(
        tester.widget<TextField>(find.byKey(const Key('room-text'))).readOnly,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      final target = find.byKey(const Key('participant-other-guest'));
      final list = find.byKey(const Key('participants-list'));
      final badge = find.byKey(const Key('guest-badge-other-guest'));
      expect(find.descendant(of: list, matching: target), findsOneWidget);
      expect(badge, findsOneWidget);
      expect(find.text('Сделать редактором'), findsNothing);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      failing.failWrites = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Сделать редактором'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось сохранить:'), findsOneWidget);
      expect(find.descendant(of: list, matching: target), findsOneWidget);
      expect(badge, findsOneWidget);
      var document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantRoles['other-guest'], RoomRole.guest);
      failing.failWrites = false;
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Сделать редактором'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось сохранить:'), findsNothing);
      expect(badge, findsNothing);
      expect(find.descendant(of: list, matching: target), findsOneWidget);
      document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantRoles['other-guest'], RoomRole.editor);
      expect(
        document.history.where(
          (edit) =>
              edit.kind == RoomEditKind.participantRole &&
              edit.targetActor == 'other-guest' &&
              edit.text == 'editor',
        ),
        hasLength(1),
      );
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await settings(tester, 'Журнал изменений');
      expect(find.text('Иван: Редактор'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester);
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      expect(find.descendant(of: list, matching: target), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final name in ['', 'Участник']) {
    for (final role in RoomRole.values) {
      testWidgets(
        'fresh ${role.name} invitation with alias "$name" applies only after durable welcome and survives reload',
        (tester) async {
          tester.binding.platformDispatcher.defaultRouteNameTestValue =
              '/?room=$roomId&role=${role.name}';
          addTearDown(
            tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
          );
          await mount(
            tester,
            uri: Uri.parse(
              'https://current.example/#room=$roomId&role=${role.name}',
            ),
            discoverSolo: false,
            answerName: false,
          );
          expect(find.byType(ParticipantNameDialog), findsOneWidget);
          expect(
            ModalRoute.of(tester.element(find.byType(RoomPage)))!.settings.name,
            '/',
            reason:
                'The platform invitation must not survive as a reported route.',
          );
          await answerNamePrompt(tester, name: name.isEmpty ? '   ' : name);
          expect(await store.hasMembership(roomId), isFalse);
          expect(await store.loadHistory(roomId), isEmpty);
          final actor = await store.loadClientId();
          peers.single.register();
          for (var i = 0; i < 8; i++) {
            await tester.pump();
          }
          final channel = peers.single.outbound.single;
          const hostHistory = [
            RoomEdit(
              id: 'host-text',
              author: 'host',
              clock: 1,
              createdAt: 1,
              text: 'Данные приглашения',
            ),
          ];
          channel.receive(
            RoomMessage(
              roomId: roomId,
              type: RoomMessageType.welcome,
              actor: 'host',
              history: hostHistory,
              hosting: true,
              online: 2,
              durableSync: true,
              roomMetadata: true,
              roomRoles: true,
              authorHistory: true,
              participantIdentity: true,
              personalSurnames: true,
              explicitSiblings: true,
              patronymics: true,
              marriageHistory: true,
            ).toJson(),
          );
          for (var i = 0; i < 12; i++) {
            await tester.pump();
          }
          expect(find.byKey(const Key('room-loading')), findsOneWidget);
          channel.receive(
            RoomMessage(
              roomId: roomId,
              type: RoomMessageType.checkpoint,
              actor: 'host',
              history: const [],
              syncId: 'd' * 32,
              syncDigest: roomHistoryDigest(hostHistory),
              inventory: roomHistoryInventory(hostHistory),
            ).toJson(),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump();
          }
          final checkpoint = channel.sent.lastWhere(
            (message) => message['type'] == 'checkpoint',
          );
          channel.receive(
            RoomMessage(
              roomId: roomId,
              type: RoomMessageType.syncAck,
              actor: 'host',
              history: const [],
              syncId: checkpoint['syncId'] as String,
              syncDigest: checkpoint['syncDigest'] as String,
              roomReady: true,
            ).toJson(),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump();
          }
          expect(await store.hasMembership(roomId), isTrue);
          var document = RoomDocument()
            ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
          expect(document.participantRoles[actor], role);
          expect(document.participantNames[actor], name);
          expect(document.text, 'Данные приглашения');
          expect(find.byKey(const Key('room-loading')), findsNothing);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('room-text')))
                .readOnly,
            role == RoomRole.guest,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await mount(tester, seedName: false, answerName: false);
          expect(
            ModalRoute.of(tester.element(find.byType(RoomPage)))!.settings.name,
            '/',
          );
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('room-text')))
                .readOnly,
            role == RoomRole.guest,
          );
          expect(find.byType(ParticipantNameDialog), findsNothing);
          document = RoomDocument()
            ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
          expect(document.participantRoles[actor], role);
          expect(document.participantNames[actor], name);
          expect(
            document.history.where(
              (edit) =>
                  edit.kind == RoomEditKind.participantName &&
                  edit.author == actor,
            ),
            hasLength(1),
          );
          expect(
            document.history.where(
              (edit) =>
                  edit.kind == RoomEditKind.participantRole &&
                  edit.targetActor == actor,
            ),
            hasLength(1),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final suffix in [
    'role=owner',
    'role=editor&role=guest',
    'role=editor&role=editor',
  ]) {
    testWidgets('invalid startup invitation $suffix never starts admission', (
      tester,
    ) async {
      await mount(
        tester,
        uri: Uri.parse('https://current.example/#room=$roomId&$suffix'),
      );
      expect(find.textContaining('неизвестная роль'), findsOneWidget);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(find.text('Создать комнату'), findsOneWidget);
      expect(peers, isEmpty);
      expect(await store.hasMembership(roomId), isFalse);
      expect(await store.loadHistory(roomId), isEmpty);
      expect(await store.loadLastRoom(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final fragment in [
    'room=$roomId&role=owner',
    'room=$roomId&role=editor&role=guest',
    'room=$roomId&role=editor&role=editor',
    'room=invalid-room&role=editor',
  ]) {
    testWidgets(
      'an invalid incoming invitation never falls back to a saved room: $fragment',
      (tester) async {
        final savedRoom = 'f' * 32;
        await store.saveMembership(savedRoom);
        await mount(
          tester,
          uri: Uri.parse('https://current.example/app/?theme=dark#$fragment'),
          discoverSolo: false,
          answerName: false,
        );
        expect(find.text('Создать комнату'), findsOneWidget);
        expect(find.byType(ParticipantNameDialog), findsNothing);
        expect(peers, isEmpty);
        expect(await store.loadLastRoom(), savedRoom);
        expect(await store.hasMembership(savedRoom), isTrue);
        expect(await store.hasMembership(roomId), isFalse);
        expect(await store.loadHistory(roomId), isEmpty);
        expect(
          ModalRoute.of(tester.element(find.byType(RoomPage)))!.settings.name,
          '/',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final invitation in [
    'https://current.example/#room=$roomId&role=owner',
    'https://current.example/#room=$roomId&role=editor&role=guest',
    '{"v":1,"peerId":"$roomId","role":"owner"}',
    '{"v":1,"peerId":"$roomId","role":"editor","role":"guest"}',
  ]) {
    testWidgets('manual invalid-role invitation rejects $invitation', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(find.text('Присоединиться'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), invitation);
      await tester.tap(find.text('Подключиться'));
      await tester.pumpAndSettle();
      expect(find.textContaining('корректный ID'), findsOneWidget);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(peers, isEmpty);
      expect(await store.hasMembership(roomId), isFalse);
      expect(await store.loadHistory(roomId), isEmpty);
      expect(await store.loadLastRoom(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('front page has exactly create and join, no editor or QR', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('Создать комнату'), findsOneWidget);
    expect(find.text('Присоединиться'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(QrImageView), findsNothing);
    expect(peers, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('create saves a stable room and allows offline text editing', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Создать комнату'));
    await answerNamePrompt(tester);
    final saved = await store.loadLastRoom();
    expect(saved, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(await store.hasMembership(saved!), isTrue);
    final actor = await store.loadClientId();
    final createdDocument = RoomDocument()
      ..merge(decodeRoomHistory(await store.loadHistory(saved)));
    expect(createdDocument.participantRoles[actor], RoomRole.editor);
    expect(peers.single.id, 'mytree-room-$saved');
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    await tester.enterText(
      find.byKey(const Key('room-text')),
      'Семья 👋\nВторая строка',
    );
    await tester.pump();
    final history = await store.loadHistory(saved);
    expect(history.last['text'], 'Семья 👋\nВторая строка');
    expect(find.textContaining('Сохранено на устройстве'), findsNothing);
    expect(find.textContaining('изменений:'), findsNothing);
    expect(find.byKey(const Key('save-status')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('accepted sibling opens locally without its own public peer', (
    tester,
  ) async {
    await store.saveMembership(roomId);
    final edit = const RoomEdit(
      id: 'saved',
      author: 'actor',
      clock: 1,
      createdAt: 1,
      text: 'Данные другой вкладки',
    );
    await store.appendHistory(roomId, [edit.toJson()]);
    final actor = await store.loadClientId();
    final tabs = _LocalTabs();
    await mount(
      tester,
      discoverSolo: false,
      roomTabsFactory: (room, client) {
        expect(room, roomId);
        expect(client, actor);
        return tabs;
      },
    );
    expect(tabs.started, isTrue);
    expect(peers, isEmpty);
    expect(find.byKey(const Key('room-text')), findsNothing);
    tabs.states.add(
      RoomTabState(
        roomId: roomId,
        actorId: actor,
        onlineCount: 1,
        initialSyncComplete: true,
        localCopyOpened: false,
        status: 'Комната готова',
        initialSyncStatus: 'История комнаты проверена',
        inventory: roomHistoryInventory(
          decodeRoomHistory(await store.loadHistory(roomId)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 0; i < 16; i++) {
      await tester.pump();
    }
    expect(peers, isEmpty);
    expect(find.byKey(const Key('room-loading')), findsNothing);
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('room-text')))
          .controller!
          .text,
      'Данные другой вкладки',
    );
    await tester.enterText(
      find.byKey(const Key('room-text')),
      'Локальная правка',
    );
    await tester.pump();
    expect((await store.loadHistory(roomId)).last['text'], 'Локальная правка');
    await settings(tester, 'Выход в меню');
    expect(tabs.disposed, isTrue);
    expect(await store.hasMembership(roomId), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'saved room hides its old text until online discovery completes',
    (tester) async {
      await store.saveMembership(roomId);
      await store.appendHistory(roomId, [
        const RoomEdit(
          id: 'saved',
          author: 'actor',
          clock: 1,
          createdAt: 1,
          text: 'Старая локальная версия',
        ).toJson(),
      ]);
      await mount(tester, discoverSolo: false);
      expect(find.byKey(const Key('room-loading')), findsOneWidget);
      expect(find.byType(TreeMark), findsOneWidget);
      expect(find.byKey(const Key('room-text')), findsNothing);
      expect(find.text('Старая локальная версия'), findsNothing);
      peers.single.register();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('room-loading')), findsOneWidget);
      await finishSoloDiscovery(tester);
      expect(find.byKey(const Key('room-loading')), findsNothing);
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-text')))
            .controller!
            .text,
        'Старая локальная версия',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'tree stays visible after latest welcome until durable history and acknowledgment',
    (tester) async {
      final shared = const RoomEdit(
        id: 'shared',
        author: 'actor',
        clock: 1,
        createdAt: 1,
        text: 'old',
      ).toJson();
      final missed = const RoomEdit(
        id: 'missed',
        author: 'host',
        clock: 2,
        createdAt: 2,
        text: 'intermediate',
      ).toJson();
      final latest = const RoomEdit(
        id: 'latest',
        author: 'host',
        clock: 3,
        createdAt: 3,
        text: 'Актуальный текст',
      ).toJson();
      await store.saveMembership(roomId);
      await store.appendHistory(roomId, [shared]);
      await mount(tester, discoverSolo: false);
      peers.single.rejectAlias();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final follower = peers.last;
      expect(follower.id, isNot('mytree-room-$roomId'));
      follower.register();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final channel = follower.outbound.single;
      final hostHistory = decodeRoomHistory([
        ...await store.loadHistory(roomId),
        missed,
        latest,
      ]);
      Map<String, dynamic> packet(String type) => {
        'v': 1,
        'roomId': roomId,
        'actor': 'host',
        'type': type,
        'history': [],
      };
      channel.receive({
        ...packet('welcome'),
        'history': [latest],
        'online': 2,
        'hosting': true,
        'fastSync': true,
        'historyDigest': roomHistoryDigest(hostHistory),
        'durableSync': true,
        'roomMetadata': true,
        'roomRoles': true,
        'authorHistory': true,
        'participantIdentity': true,
        'personalSurnames': true,
        'explicitSiblings': true,
        'patronymics': true,
        'marriageHistory': true,
      });
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('room-loading')), findsOneWidget);
      expect(find.byKey(const Key('room-text')), findsNothing);
      channel.receive({
        ...packet('inventory'),
        'inventory': roomHistoryInventory(hostHistory),
      });
      channel.receive({
        ...packet('checkpoint'),
        'syncId': 'a' * 32,
        'syncDigest': roomHistoryDigest(hostHistory),
        'inventory': roomHistoryInventory(hostHistory),
      });
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('room-text')), findsNothing);
      channel.receive({
        ...packet('edits'),
        'history': [missed],
      });
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect((await store.loadHistory(roomId)).length, 4);
      expect(find.byKey(const Key('room-text')), findsNothing);
      final checkpoint = channel.sent.lastWhere(
        (message) => message['type'] == 'checkpoint',
      );
      channel.receive({
        ...packet('syncAck'),
        'syncId': checkpoint['syncId'],
        'syncDigest': checkpoint['syncDigest'],
        'roomReady': true,
      });
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('room-loading')), findsNothing);
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-text')))
            .controller!
            .text,
        'Актуальный текст',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dialogOpen in [false, true]) {
    testWidgets(
      'resume loading covers stale editor and open dialog=$dialogOpen',
      (tester) async {
        await store.saveMembership(roomId);
        await mount(tester);
        final session = tester
            .widget<RoomDiskStatusButton>(find.byType(RoomDiskStatusButton))
            .session;
        expect(session.initialSyncComplete, isTrue);
        if (dialogOpen) await settings(tester, 'Настройки комнаты');
        final before = await store.loadHistory(roomId);
        session.setForeground(false);
        peers.last.disconnected = true;
        session.setForeground(true);
        expect(session.initialSyncComplete, isFalse);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('room-text')), findsNothing);
        expect(find.text('Сверяем изменения после возвращения…'), findsWidgets);
        if (dialogOpen) {
          expect(
            find.byKey(const Key('resume-loading-overlay')).hitTestable(),
            findsOneWidget,
          );
          expect(find.text('Сохранить').hitTestable(), findsNothing);
        }
        await tester.pump(const Duration(seconds: 31));
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(session.initialSyncComplete, isFalse);
        expect(find.textContaining('30 секунд'), findsWidgets);
        await tester.tap(
          find.text('Открыть локальную копию').hitTestable().last,
        );
        await tester.pump();
        await tester.pump();
        expect(session.localCopyOpened, isTrue);
        expect(find.byKey(const Key('resume-loading-overlay')), findsNothing);
        if (dialogOpen) {
          expect(find.byType(RoomSettingsDialog), findsOneWidget);
        } else {
          expect(find.byKey(const Key('sync-status')), findsOneWidget);
        }
        expect(await store.loadHistory(roomId), before);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final exit in [false, true]) {
    testWidgets(
      'phone biography survives resume or exits to menu, exit=$exit',
      (tester) async {
        await seedBoundRoom(alias: 'Анна');
        final tree = TreeDocument();
        await store.appendHistory(roomId, [
          RoomEdit(
            id: 'resume-parent',
            author: 'relative-author',
            clock: 100,
            createdAt: 100,
            kind: RoomEditKind.tree,
            text: jsonEncode(
              tree.createPerson('relative', name: 'Родитель').toJson(),
            ),
          ).toJson(),
          RoomEdit(
            id: 'resume-parent-link',
            author: 'relative-author',
            clock: 101,
            createdAt: 101,
            kind: RoomEditKind.tree,
            text: jsonEncode({
              'type': 'setValue',
              'personId': rootTreePersonId,
              'field': 'fatherId',
              'value': 'relative',
            }),
          ).toJson(),
        ]);
        await mount(tester, useDefaultEditor: true);
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        final editor = tester.state(find.byType(TreeEditor));
        final session = tester
            .widget<RoomDiskStatusButton>(find.byType(RoomDiskStatusButton))
            .session;
        await tester.tap(find.byKey(const Key('open-biography')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('tree-biography-route')), findsOneWidget);
        session.setForeground(false);
        peers.last.disconnected = true;
        session.setForeground(true);
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('resume-loading-overlay')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.state(find.byType(TreeEditor, skipOffstage: false)),
          same(editor),
        );
        expect(editor.mounted, isTrue);
        expect(
          tester
              .widget<PopupMenuButton<String>>(
                find.byKey(const Key('room-menu'), skipOffstage: false),
              )
              .enabled,
          isFalse,
        );
        if (exit) {
          await tester.tap(find.text('Вернуться в меню').hitTestable().last);
          await tester.pumpAndSettle();
          expect(find.text('Создать комнату'), findsOneWidget);
          expect(find.byKey(const Key('tree-biography-route')), findsNothing);
          expect(find.byKey(const Key('resume-loading-overlay')), findsNothing);
        } else {
          await tester.pump(const Duration(seconds: 31));
          for (var i = 0; i < 8; i++) {
            await tester.pump();
          }
          await tester.tap(
            find.text('Открыть локальную копию').hitTestable().last,
          );
          await tester.pumpAndSettle();
          expect(editor.mounted, isTrue);
          expect(find.byKey(const Key('resume-loading-overlay')), findsNothing);
          final relative = find.byKey(const ValueKey('relative-Отец-relative'));
          await tester.ensureVisible(relative);
          await tester.tap(
            find.descendant(of: relative, matching: find.text('Родитель')),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(editor.mounted, isTrue);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unavailable signaling shows retry instead of silently opening stale text',
    (tester) async {
      await store.saveMembership(roomId);
      await store.appendHistory(roomId, [
        const RoomEdit(
          id: 'saved',
          author: 'actor',
          clock: 1,
          createdAt: 1,
          text: 'Локальная копия',
        ).toJson(),
      ]);
      await mount(tester, discoverSolo: false);
      await tester.pump(const Duration(seconds: 46));
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('room-text')), findsNothing);
      expect(find.text('Повторить подключение'), findsOneWidget);
      expect(find.text('Открыть локальную копию'), findsOneWidget);
      await tester.tap(find.text('Открыть локальную копию'));
      await tester.pump();
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      final status = tester.widget<Text>(find.byKey(const Key('sync-status')));
      expect(status.data, matches(RegExp('локаль', caseSensitive: false)));
      await tester.enterText(
        find.byKey(const Key('room-text')),
        'Офлайн правка',
      );
      await tester.pump();
      expect((await store.loadHistory(roomId)).last['text'], 'Офлайн правка');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('saved alias and session reuse one initial history read', (
    tester,
  ) async {
    final counted = _CountingHistoryStore();
    store = counted;
    final actor = await counted.loadClientId();
    await counted.saveMembership(roomId);
    await counted.appendHistory(roomId, [
      RoomEdit(
        id: 'saved-alias',
        author: actor,
        clock: 1,
        createdAt: 1,
        text: '',
        kind: RoomEditKind.participantName,
      ).toJson(),
      const RoomEdit(
        id: 'saved-text',
        author: 'other',
        clock: 1,
        createdAt: 1,
        text: 'Сохранённый текст',
      ).toJson(),
    ]);
    counted.historyLoads = 0;
    await mount(tester, seedName: false, discoverSolo: false);
    expect(find.byType(ParticipantNameDialog), findsNothing);
    expect(
      counted.historyLoads,
      1,
      reason: 'Alias snapshot also loads the session',
    );
    expect(
      find.byKey(const Key('room-text')),
      findsNothing,
      reason: 'Reusing local data does not verify network synchronization',
    );
    await tester.pump(const Duration(milliseconds: 35));
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
    expect(
      counted.historyLoads,
      2,
      reason: 'The watch-gap refresh is retained',
    );
    await finishSoloDiscovery(tester);
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('room-text')))
          .controller!
          .text,
      'Сохранённый текст',
    );
    expect(counted.historyLoads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('last room and history restore after confirming solo discovery', (
    tester,
  ) async {
    await store.saveMembership(roomId);
    await store.appendHistory(roomId, [
      const RoomEdit(
        id: 'edit',
        author: 'actor',
        clock: 1,
        createdAt: 1,
        text: 'Сохранённый текст',
      ).toJson(),
    ]);
    await mount(tester);
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('room-text')))
          .controller!
          .text,
      'Сохранённый текст',
    );
    expect(find.text('Присоединиться'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'settings copy stable ID and current-domain URL; QR is on request',
    (tester) async {
      await store.saveMembership(roomId);
      await mount(tester);
      await settings(tester, 'Пригласить участников');
      expect(find.byKey(const Key('room-id')), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('Скопировать ID'));
      await tester.pump();
      expect(calls.last.arguments, {'text': roomId});
      await tester.tap(find.text('Скопировать URL'));
      await tester.pump();
      expect(calls.last.arguments, {
        'text': 'https://current.example/app/#room=$roomId&role=guest',
      });
      await tester.tap(find.text('Показать QR'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.textContaining('обычной камерой'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'exit is navigation, preserving membership, last room and history',
    (tester) async {
      await store.saveMembership(roomId);
      await mount(tester);
      await tester.enterText(find.byKey(const Key('room-text')), 'Не потерять');
      await tester.pump();
      await settings(tester, 'Выход в меню');
      expect(find.text('Создать комнату'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(await store.loadLastRoom(), roomId);
      expect(await store.hasMembership(roomId), isTrue);
      expect((await store.loadHistory(roomId)).last['text'], 'Не потерять');
      expect(peers.every((peer) => peer.destroyed), isTrue);
      await reopenLastRoom(tester);
      expect(peers.last.id, 'mytree-room-$roomId');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'online exit stops networking and briefly prefers the existing host on return',
    (tester) async {
      await store.saveMembership(roomId);
      await mount(tester);
      final host = peers.single;
      host.register();
      await tester.pump();
      final participant = _FakeConnection();
      host.accept(participant);
      await tester.pump();
      participant.receive({
        'v': 1,
        'roomId': roomId,
        'type': 'hello',
        'actor': 'participant',
        'history': [],
        'roomMetadata': true,
        'roomRoles': true,
        'authorHistory': true,
        'participantIdentity': true,
        'personalSurnames': true,
        'explicitSiblings': true,
        'patronymics': true,
        'marriageHistory': true,
      });
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(
        tester.widget<Text>(find.byKey(const Key('participants-count'))).data,
        '1',
      );
      expect(find.byKey(const Key('participants-online-dot')), findsOneWidget);
      await settings(tester, 'Выход в меню');
      expect(host.destroyed, isTrue);
      expect(participant.disposed, isTrue);
      expect(await store.hasMembership(roomId), isTrue);

      await reopenLastRoom(tester);
      expect(peers.last.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(find.byKey(const Key('room-text')), findsNothing);
      expect(find.byKey(const Key('room-loading')), findsOneWidget);
      // A later offline exit must clear the remembered online-host hint.
      await settings(tester, 'Выход в меню');
      await reopenLastRoom(tester);
      expect(peers.last.id, 'mytree-room-$roomId');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'join dialog accepts ID or URL and explains first-admission requirement',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Присоединиться'));
      await tester.pumpAndSettle();
      expect(find.text('ID комнаты или ссылка'), findsOneWidget);
      expect(
        find.textContaining('Для входа по ID нужен онлайн-участник'),
        findsOneWidget,
      );
      expect(
        find.textContaining('с доступом к Диску позволяет войти без него'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'not-a-room');
      await tester.tap(find.text('Подключиться'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.textContaining('корректный ID'), findsOneWidget);
      expect(await store.loadLastRoom(), isNull);
      expect(peers, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('fresh invitation does not become membership without welcome', (
    tester,
  ) async {
    await mount(
      tester,
      uri: Uri.parse('https://current.example/#room=$roomId'),
    );
    expect(find.byKey(const Key('room-text')), findsNothing);
    expect(find.textContaining('Первое подключение требует'), findsOneWidget);
    expect(await store.hasMembership(roomId), isFalse);
    await tester.pump(const Duration(seconds: 31));
    expect(await store.loadLastRoom(), isNull);
    expect(find.text('Повторить подключение'), findsOneWidget);
    await tester.tap(find.text('Вернуться в меню'));
    await tester.pump();
    expect(find.text('Создать комнату'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a last-room metadata failure does not discard readable history',
    (tester) async {
      final failing = _MetadataFailingStore();
      store = failing;
      await store.saveMembership(roomId);
      await store.appendHistory(roomId, [
        const RoomEdit(
          id: 'saved',
          author: 'actor',
          clock: 1,
          createdAt: 1,
          text: 'Данные доступны',
        ).toJson(),
      ]);
      failing.failMetadata = true;
      await mount(tester);
      await tester.pump();
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-text')))
            .controller!
            .text,
        'Данные доступны',
      );
      expect(find.textContaining('не удалось запомнить'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('rapid create clicks cannot create competing rooms', (
    tester,
  ) async {
    await mount(tester);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Создать комнату'),
    );
    button.onPressed!();
    button.onPressed!();
    await tester.pump();
    expect(find.byType(ParticipantNameDialog), findsOneWidget);
    await answerNamePrompt(tester);
    expect(peers, hasLength(1));
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('join dialog owns its controller and returns the raw input', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => const JoinRoomDialog(initialRoomId: roomId),
                );
              },
              child: const Text('Открыть диалог'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть диалог'));
    await tester.pumpAndSettle();
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    expect(controller.text, roomId);
    const input = ' https://current.example/app/#room=$roomId ';
    await tester.enterText(find.byType(TextField), input);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(result, input);
    expect(find.byType(JoinRoomDialog), findsNothing);
    expect(() => controller.addListener(() {}), throwsFlutterError);

    await tester.tap(find.text('Открыть диалог'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      roomId,
    );
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> mountDialog(WidgetTester tester, Widget dialog) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => dialog),
              child: const Text('Открыть диалог'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть диалог'));
    await tester.pumpAndSettle();
  }

  Future<void> expectQrPayload(WidgetTester tester, String payload) async {
    final qr = find.byType(QrImageView);
    final image = tester.widget<QrImageView>(qr);
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: qr,
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter is QrPainter,
        ),
      ),
    );
    final actual = paint.painter! as QrPainter;
    final expected = QrPainter(
      data: payload,
      version: image.version,
      errorCorrectionLevel: image.errorCorrectionLevel,
      gapless: image.gapless,
      eyeStyle: image.eyeStyle,
      dataModuleStyle: image.dataModuleStyle,
    );
    await tester.runAsync(() async {
      final actualBytes = await actual.toImageData(240);
      final expectedBytes = await expected.toImageData(240);
      expect(actualBytes, isNotNull);
      expect(expectedBytes, isNotNull);
      expect(
        actualBytes!.buffer.asUint8List(),
        orderedEquals(expectedBytes!.buffer.asUint8List()),
        reason: 'The displayed QR must encode the selected invitation role.',
      );
    });
  }

  testWidgets(
    'invite dialog reports exact clipboard success and failure messages',
    (tester) async {
      final messages = <String>[];
      final copied = <String>[];
      var failCopy = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (failCopy) {
              throw PlatformException(code: 'clipboard-unavailable');
            }
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mountDialog(
        tester,
        InviteParticipantsDialog(
          roomId: roomId,
          applicationUri: Uri.parse('https://current.example/app/'),
          onMessage: messages.add,
        ),
      );
      expect(
        find.text('При первом входе кто-то из комнаты должен быть онлайн.'),
        findsOneWidget,
      );
      expect(
        find.text('Гость может приглашать только гостей.'),
        findsOneWidget,
      );
      final roles = tester.widget<SegmentedButton<RoomRole>>(
        find.byKey(const Key('invitation-role')),
      );
      expect(roles.selected, {RoomRole.guest});
      expect(
        roles.segments
            .singleWhere((segment) => segment.value == RoomRole.editor)
            .enabled,
        isFalse,
      );
      await tester.ensureVisible(find.text('Скопировать ID'));
      await tester.tap(find.text('Скопировать ID'));
      await tester.pump();
      await tester.ensureVisible(find.text('Скопировать URL'));
      await tester.tap(find.text('Скопировать URL'));
      await tester.pump();
      failCopy = true;
      await tester.ensureVisible(find.text('Скопировать ID'));
      await tester.tap(find.text('Скопировать ID'));
      await tester.pump();
      expect(copied, [
        roomId,
        'https://current.example/app/#room=$roomId&role=guest',
      ]);
      expect(messages, [
        'ID комнаты скопирован. Вход по ID — как гость.',
        'Ссылка на комнату скопирована',
        'Не удалось скопировать. Выделите и скопируйте значение вручную.',
      ]);
      expect(find.byType(QrImageView), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'editor invite selection changes URL and QR, but raw ID stays guest',
    (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mountDialog(
        tester,
        InviteParticipantsDialog(
          roomId: roomId,
          applicationUri: Uri.parse('https://current.example/app/'),
          canInviteEditors: true,
          onMessage: (_) {},
        ),
      );
      final roleControl = find.byKey(const Key('invitation-role'));
      expect(tester.widget<SegmentedButton<RoomRole>>(roleControl).selected, {
        RoomRole.guest,
      });
      expect(find.text('Гость может приглашать только гостей.'), findsNothing);
      for (final role in [RoomRole.guest, RoomRole.editor, RoomRole.guest]) {
        await tester.ensureVisible(roleControl);
        await tester.tap(
          find.text(role == RoomRole.editor ? 'Редактор' : 'Гость'),
        );
        await tester.pumpAndSettle();
        final expectedLink =
            'https://current.example/app/#room=$roomId&role=${role.name}';
        expect(tester.widget<SegmentedButton<RoomRole>>(roleControl).selected, {
          role,
        });
        expect(
          tester
              .widget<SelectableText>(find.byKey(const Key('room-link')))
              .data,
          expectedLink,
        );
        await tester.ensureVisible(find.text('Скопировать URL'));
        await tester.tap(find.text('Скопировать URL'));
        await tester.pump();
        expect(copied.last, expectedLink);
        await tester.ensureVisible(find.text('Показать QR'));
        await tester.tap(find.text('Показать QR'));
        await tester.pumpAndSettle();
        expect(
          find.text(role == RoomRole.editor ? 'QR · Редактор' : 'QR · Гость'),
          findsOneWidget,
        );
        await expectQrPayload(tester, expectedLink);
        await tester.tap(find.text('Закрыть').last);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(roleControl);
      await tester.tap(find.text('Редактор'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Скопировать ID'));
      await tester.tap(find.text('Скопировать ID'));
      await tester.pump();
      expect(copied.last, roomId);
      expect(parseRoomInvitation(copied.last)!.role, RoomRole.guest);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'guest invitation cannot select editor or emit editor URL or QR',
    (tester) async {
      await mountDialog(
        tester,
        InviteParticipantsDialog(
          roomId: roomId,
          applicationUri: Uri.parse('https://current.example/app/'),
          onMessage: (_) {},
        ),
      );
      await tester.tap(find.text('Редактор'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<RoomRole>>(
              find.byKey(const Key('invitation-role')),
            )
            .selected,
        {RoomRole.guest},
      );
      const expectedLink =
          'https://current.example/app/#room=$roomId&role=guest';
      expect(
        tester.widget<SelectableText>(find.byKey(const Key('room-link'))).data,
        expectedLink,
      );
      await tester.ensureVisible(find.text('Показать QR'));
      await tester.tap(find.text('Показать QR'));
      await tester.pumpAndSettle();
      expect(find.text('QR · Гость'), findsOneWidget);
      await expectQrPayload(tester, expectedLink);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(390, 844), const Size(390, 300)]) {
    for (final canInviteEditors in [false, true]) {
      testWidgets(
        'invite role selector fits $size, editor access=$canInviteEditors',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await mountDialog(
            tester,
            InviteParticipantsDialog(
              roomId: roomId,
              applicationUri: Uri.parse('https://current.example/app/'),
              canInviteEditors: canInviteEditors,
              onMessage: (_) {},
            ),
          );
          final roleControl = find.byKey(const Key('invitation-role'));
          for (final role in [
            RoomRole.guest,
            if (canInviteEditors) RoomRole.editor,
          ]) {
            await tester.ensureVisible(roleControl);
            await tester.tap(
              find.text(role == RoomRole.editor ? 'Редактор' : 'Гость'),
            );
            await tester.pumpAndSettle();
            expect(
              tester.widget<SegmentedButton<RoomRole>>(roleControl).selected,
              {role},
            );
            final control = tester.getRect(roleControl);
            expect(control.left, greaterThanOrEqualTo(0));
            expect(control.right, lessThanOrEqualTo(size.width));
            expect(find.text('Закрыть').hitTestable(), findsOneWidget);
            await tester.ensureVisible(find.text('Скопировать URL'));
            expect(find.text('Скопировать URL').hitTestable(), findsOneWidget);
            await tester.ensureVisible(find.text('Показать QR'));
            expect(find.text('Показать QR').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          final panel = tester.getRect(find.byType(Material).last);
          expect(panel.left, greaterThanOrEqualTo(0));
          expect(panel.right, lessThanOrEqualTo(size.width));
          expect(panel.top, greaterThanOrEqualTo(0));
          expect(panel.bottom, lessThanOrEqualTo(size.height));
          await tester.tap(find.text('Закрыть'));
          await tester.pumpAndSettle();
          expect(find.byType(InviteParticipantsDialog), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'native invite shows QR only on request and closes it separately',
    (tester) async {
      await mountDialog(
        tester,
        InviteParticipantsDialog(
          roomId: roomId,
          applicationUri: Uri.parse('file:///app/'),
          onMessage: (_) {},
        ),
      );
      expect(find.byKey(const Key('room-id')), findsOneWidget);
      expect(find.byKey(const Key('room-link')), findsNothing);
      expect(find.text('Скопировать URL'), findsNothing);
      expect(find.byType(QrImageView), findsNothing);
      await tester.tap(find.text('Показать QR'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      await expectQrPayload(
        tester,
        '{"v":1,"peerId":"$roomId","role":"guest"}',
      );
      expect(
        find.text('Отсканируйте ID комнаты на другом устройстве.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Закрыть').last);
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byType(InviteParticipantsDialog), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(InviteParticipantsDialog), findsNothing);
      expect(find.text('Открыть диалог'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('new room shows an unconnected cloud that opens Disk settings', (
    tester,
  ) async {
    await mount(tester, seedName: false, answerName: false);
    await tester.tap(find.text('Создать комнату'));
    await answerNamePrompt(tester);
    final action = find.byKey(const Key('disk-sync-button'));
    expect(action, findsOneWidget);
    expect(find.byTooltip('Яндекс Диск: Не подключён'), findsOneWidget);
    expect(find.byKey(const Key('disk-sync-symbol')), findsNothing);
    expect(
      tester.getRect(action).right,
      lessThanOrEqualTo(
        tester.getRect(find.byKey(const Key('participants-button'))).left,
      ),
    );
    final created = (await store.loadLastRoom())!;
    final before = await store.loadHistory(created);
    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RoomSettingsDialog), findsOneWidget);
    expect(find.text('Подключить Яндекс Диск'), findsOneWidget);
    expect(await store.loadHistory(created), before);
    expect(await store.loadDiskCredentials(created), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final role in [RoomRole.editor, RoomRole.guest]) {
    testWidgets('Disk header action replaces the status row for ${role.name}', (
      tester,
    ) async {
      await store.saveMembership(roomId);
      final actor = await store.loadClientId();
      await store.appendHistory(roomId, [
        RoomEdit(
          id: 'saved-disk-name',
          author: actor,
          clock: 1,
          createdAt: 1,
          text: 'Участник',
          kind: RoomEditKind.participantName,
        ).toJson(),
        RoomEdit(
          id: 'saved-disk-role',
          author: actor,
          clock: 2,
          createdAt: 2,
          text: role.name,
          kind: RoomEditKind.participantRole,
          targetActor: actor,
        ).toJson(),
        RoomEdit(
          id: 'saved-disk-binding',
          author: actor,
          clock: 3,
          createdAt: 3,
          text: jsonEncode({'action': 'connect'}),
          kind: RoomEditKind.diskConnection,
        ).toJson(),
      ]);
      final before = await store.loadHistory(roomId);
      await mount(tester, seedName: false);
      final action = find.byKey(const Key('disk-sync-button'));
      expect(action, findsOneWidget);
      expect(
        tester.widget<IconButton>(action).onPressed,
        role == RoomRole.editor ? isNotNull : isNull,
      );
      expect(find.byKey(const Key('disk-sync-status')), findsNothing);
      expect(find.text('Ожидаем доступ от редактора'), findsNothing);
      if (role == RoomRole.editor) {
        expect(
          find.ancestor(of: action, matching: find.byType(AppBar)),
          findsOneWidget,
        );
        expect(
          tester.getRect(action).right,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const Key('participants-button'))).left,
          ),
        );
        expect(
          find.byTooltip('Яндекс Диск: Ожидаем доступ от редактора'),
          findsOneWidget,
        );
        await tester.tap(action);
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(
          find.byType(RoomSettingsDialog),
          findsNothing,
          reason: 'The cloud action synchronizes instead of opening settings.',
        );
        expect(
          tester.widget<Icon>(find.byKey(const Key('disk-sync-symbol'))).icon,
          Icons.close,
        );
      }
      expect(
        await store.loadHistory(roomId),
        before,
        reason:
            'Reading status and retrying without a key must not author history.',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('phone guest keeps a read-only Disk icon at $width', (
      tester,
    ) async {
      await seedGuestRoom();
      await mount(tester, useDefaultEditor: true);
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpAndSettle();
      final action = find.byKey(const Key('disk-sync-button'));
      expect(action, findsOneWidget);
      final rect = tester.getRect(action);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(width));
      expect(
        rect.right,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const Key('participants-button'))).left,
        ),
      );
      expect(tester.widget<IconButton>(action).onPressed, isNull);
      final before = await store.loadHistory(roomId);
      await tester.longPress(action);
      await tester.pumpAndSettle();
      expect(find.text('Яндекс Диск: Не подключён'), findsOneWidget);
      expect(find.byType(RoomSettingsDialog), findsNothing);
      expect(await store.loadHistory(roomId), before);
      expect(await store.loadDiskCredentials(roomId), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'participant panel reacts to real session admission and disconnect',
    (tester) async {
      await store.saveMembership(roomId);
      await store.appendHistory(roomId, [
        const RoomEdit(
          id: 'offline-profile',
          author: 'offline',
          clock: 1,
          createdAt: 1,
          text: 'Ольга',
          kind: RoomEditKind.participantName,
        ).toJson(),
      ]);
      await mount(tester);
      expect(
        tester.widget<Icon>(find.byKey(const Key('participants-icon'))).icon,
        Icons.person_outline,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('participants-count'))).data,
        '0',
      );
      expect(find.byKey(const Key('participants-online-dot')), findsNothing);
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      expect(find.byType(CircleAvatar), findsNWidgets(2));
      final channel = _FakeConnection(peerId: 'remote');
      peers.single.accept(channel);
      await tester.pump();
      channel.receive(
        RoomMessage(
          roomId: roomId,
          type: RoomMessageType.hello,
          actor: 'remote',
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          participantIdentity: true,
          personalSurnames: true,
          explicitSiblings: true,
          patronymics: true,
          marriageHistory: true,
          history: const [
            RoomEdit(
              id: 'remote-profile',
              author: 'remote',
              clock: 2,
              createdAt: 2,
              text: 'Иван',
              kind: RoomEditKind.participantName,
            ),
          ],
        ).toJson(),
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump();
      }
      final list = find.byKey(const Key('participants-list'));
      final remoteTile = find.byKey(const Key('participant-tile-remote'));
      final offlineTile = find.byKey(const Key('participant-tile-offline'));
      final colors = Theme.of(tester.element(list)).colorScheme;
      expect(find.byType(CircleAvatar), findsNWidgets(3));
      expect(
        find.descendant(of: list, matching: find.text('Иван')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: list, matching: find.text('Ольга')),
        findsOneWidget,
      );
      expect(
        (tester.widget<Ink>(remoteTile).decoration! as BoxDecoration).color,
        colors.primaryContainer,
      );
      expect(
        (tester.widget<Ink>(offlineTile).decoration! as BoxDecoration).color,
        isNull,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('participants-count'))).data,
        '1',
      );
      expect(find.byKey(const Key('participants-online-dot')), findsOneWidget);
      channel.close();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(
        find.descendant(of: list, matching: find.text('Иван')),
        findsOneWidget,
      );
      expect(
        (tester.widget<Ink>(remoteTile).decoration! as BoxDecoration).color,
        isNull,
      );
      expect(find.byType(CircleAvatar), findsNWidgets(3));
      expect(
        tester.widget<Text>(find.byKey(const Key('participants-count'))).data,
        '0',
      );
      expect(find.byKey(const Key('participants-online-dot')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(320, 568), const Size(1100, 850)]) {
    testWidgets(
      'room menu version is last and can be selected and copied at ${size.width}',
      (tester) async {
        await store.saveMembership(roomId);
        await mount(tester);
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final history = await store.loadHistory(roomId);
        final clipboard = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard.add((call.arguments as Map)['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byKey(const Key('room-menu')));
        await tester.pumpAndSettle();
        final items = tester
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .toList();
        expect(items.last.value, 'menu');
        final menu = tester.widget<PopupMenuButton<String>>(
          find.byKey(const Key('room-menu')),
        );
        final entries = menu.itemBuilder(
          tester.element(find.byKey(const Key('room-menu'))),
        );
        expect(entries.last.represents('version'), isFalse);
        final semantics = tester.ensureSemantics();
        await tester.pump();
        final version = find.byKey(const Key('room-build-version'));
        final data = tester.getSemantics(version).getSemanticsData();
        expect(data.flagsCollection.isTextField, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isTrue);
        semantics.dispose();
        const stamp = String.fromEnvironment(
          'MYTREE_BUILD_VERSION',
          defaultValue: 'dev',
        );
        expect(tester.widget<SelectableText>(version).data, 'Версия: $stamp');
        expect(
          tester.getRect(version).bottom,
          greaterThan(tester.getRect(find.text('Выход в меню')).bottom),
        );
        await tester.longPress(version);
        await tester.pumpAndSettle();
        final editable = find.descendant(
          of: version,
          matching: find.byType(EditableText),
        );
        expect(
          tester
              .widget<EditableText>(editable)
              .controller
              .selection
              .isCollapsed,
          isFalse,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(clipboard.last, 'Версия: $stamp');
        expect(find.byKey(const Key('room-build-version')), findsOneWidget);
        expect(await store.loadHistory(roomId), history);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'title menu has settings, history, own name, exit and version last; settings rename',
    (tester) async {
      await store.saveMembership(roomId);
      await mount(tester);
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
      expect(find.byTooltip('Настройки'), findsNothing);
      final semantics = tester.ensureSemantics();
      await tester.pump();
      final menuSemantics = tester.getSemantics(
        find.byKey(const Key('room-menu')),
      );
      final menuData = menuSemantics.getSemanticsData();
      expect(menuData.flagsCollection.isButton, isTrue);
      expect(menuData.flagsCollection.isHeader, isFalse);
      expect(menuData.hasAction(SemanticsAction.tap), isTrue);
      tester.binding.performSemanticsAction(
        SemanticsActionEvent(
          type: SemanticsAction.tap,
          nodeId: menuSemantics.id,
          viewId: tester.view.viewId,
        ),
      );
      semantics.dispose();
      await tester.pumpAndSettle();
      final menuItems = find.byType(PopupMenuItem<String>);
      expect(menuItems, findsNWidgets(5));
      expect(
        tester
            .widgetList<PopupMenuItem<String>>(menuItems)
            .map((item) => item.value),
        ['settings', 'patronymics', 'history', 'name', 'menu'],
      );
      expect(
        tester
            .widgetList<Text>(
              find.descendant(of: menuItems, matching: find.byType(Text)),
            )
            .map((text) => text.data),
        [
          'Настройки комнаты',
          'Словарь отчеств',
          'Журнал изменений',
          'Изменить моё имя',
          'Выход в меню',
        ],
      );
      expect(find.text('Пригласить участников'), findsNothing);
      await tester.tap(find.text('Настройки комнаты'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomSettingsDialog), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('room-name')), findsOneWidget);
      expect(find.byKey(const Key('room-id')), findsNothing);
      expect(find.text('Журнал изменений'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('room-name')),
        '  Наша семья  ',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(RoomSettingsDialog), findsNothing);
      expect(find.text('Наша семья'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-text')))
            .controller!
            .text,
        isEmpty,
      );
      final document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.roomName, 'Наша семья');
      await settings(tester, 'Журнал изменений');
      await tester.pumpAndSettle();
      expect(find.byType(RoomChangesDialog), findsOneWidget);
      expect(find.text('Название комнаты'), findsOneWidget);
      expect(find.text('Имя участника'), findsOneWidget);
      expect(find.byKey(const Key('room-name')), findsNothing);
      expect(find.text('Выход в меню'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'blank create saves one canonical alias and restores without prompting',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Создать комнату'));
      await answerNamePrompt(tester, name: '   ');
      final created = (await store.loadLastRoom())!;
      final actor = await store.loadClientId();
      final document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(created)));
      expect(document.participantNames[actor], '');
      expect(
        document.history.where(
          (edit) => edit.kind == RoomEditKind.participantName,
        ),
        hasLength(1),
      );
      expect(document.participantRoles[actor], RoomRole.editor);
      expect(await store.hasMembership(created), isTrue);
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      expect(find.text('Аноним'), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, seedName: false, answerName: false);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      expect(
        (await store.loadHistory(
          created,
        )).where((edit) => edit['kind'] == 'participantName'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'clearing own alias saves blank, shows anonymous and never reprompts',
    (tester) async {
      await store.saveMembership(roomId);
      await mount(tester);
      final actor = await store.loadClientId();
      await settings(tester, 'Изменить моё имя');
      final field = find.byKey(const Key('participant-name'));
      expect(tester.widget<TextField>(field).controller!.text, 'Участник');
      expect(find.byKey(const Key('participant-unbind')), findsNothing);
      await tester.enterText(field, '   ');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      var document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantNames[actor], '');
      expect(
        document.history.where(
          (edit) =>
              edit.kind == RoomEditKind.participantName &&
              edit.author == actor &&
              edit.text.isEmpty,
        ),
        hasLength(1),
      );
      await tester.tap(find.byKey(const Key('participants-button')));
      await tester.pumpAndSettle();
      expect(find.text('Аноним'), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      await settings(tester, 'Журнал изменений');
      expect(find.text('Имя не указано'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, seedName: false, answerName: false);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      await settings(tester, 'Изменить моё имя');
      expect(tester.widget<TextField>(field).controller!.text, '');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantNames[actor], '');
      expect(
        document.history.where(
          (edit) => edit.kind == RoomEditKind.participantName,
        ),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('own unbind waits for durable history and changes no other actor', (
    tester,
  ) async {
    final delayed = _HistoryFailingStore();
    store = delayed;
    final actor = await seedBoundRoom();
    await mount(tester, seedName: false, answerName: false);
    final session = tester
        .widget<_LifecycleTestEditor>(find.byType(_LifecycleTestEditor))
        .session;
    expect(
      session.participants.singleWhere((person) => person.isSelf).name,
      'Анна',
    );
    expect(session.boundPersonFullName, 'Анна Иванова');
    expect(find.byType(ParticipantNameDialog), findsNothing);
    final before = await store.loadHistory(roomId);
    await tester.tap(find.byKey(const Key('participants-button')));
    await tester.pumpAndSettle();
    expect(find.text('Анна'), findsOneWidget);
    expect(find.text('Анна Иванова'), findsNothing);
    expect(find.byTooltip('Анна Иванова'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    await settings(tester, 'Изменить моё имя');
    final field = find.byKey(const Key('participant-name'));
    final unbind = find.byKey(const Key('participant-unbind'));
    expect(tester.widget<TextField>(field).controller!.text, '');
    expect(find.textContaining('Это я:'), findsNothing);
    expect(find.byTooltip('Анна Иванова'), findsOneWidget);
    expect(find.text('Отменить «Это я»'), findsOneWidget);
    expect(find.textContaining('только это устройство'), findsNothing);
    await tester.enterText(field, 'Черновик псевдонима');
    delayed.historyWrite = Completer<void>();
    await tester.tap(unbind);
    await tester.pump();
    expect(session.tree.bindings.containsKey(actor), isFalse);
    // Reads share the pending author transaction's lock; inspect the durable
    // projection now and read persisted history only after completing the write.
    expect(session.durableTree.bindings[actor], rootTreePersonId);
    expect(session.canUnbindFromPerson, isTrue);
    expect(tester.widget<TextButton>(unbind).onPressed, isNull);
    expect(tester.widget<TextField>(field).enabled, isFalse);
    await tester.tapAt(const Offset(8, 8));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ParticipantNameDialog), findsOneWidget);
    delayed.historyWrite!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ParticipantNameDialog), findsOneWidget);
    expect(unbind, findsNothing);
    expect(find.byTooltip('Анна Иванова'), findsNothing);
    expect(find.textContaining('Это я:'), findsNothing);
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Черновик псевдонима',
    );
    expect(session.participantName, '');
    expect(
      session.participants.singleWhere((person) => person.isSelf).name,
      'Аноним',
    );
    expect(session.durableTree.bindings, {
      'other-device': rootTreePersonId,
      'another-device': rootTreePersonId,
    });
    expect(session.durableTree.people.keys, [rootTreePersonId]);
    expect(
      session.durableTree.person(rootTreePersonId)!.fullName,
      'Анна Иванова',
    );
    final after = decodeRoomHistory(await store.loadHistory(roomId));
    expect(after, hasLength(before.length + 1));
    final release = jsonDecode(after.last.text) as Map<String, dynamic>;
    expect(release['type'], 'unbindActor');
    expect(release['actorId'], actor);
    expect(release['personId'], rootTreePersonId);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, seedName: false, answerName: false);
    expect(find.byType(ParticipantNameDialog), findsNothing);
    final restored = tester
        .widget<_LifecycleTestEditor>(find.byType(_LifecycleTestEditor))
        .session;
    expect(restored.boundPersonId, isNull);
    expect(restored.durableTree.bindings, {
      'other-device': rootTreePersonId,
      'another-device': rootTreePersonId,
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unbind failure retries one release while preserving typed alias',
    (tester) async {
      final failing = _HistoryFailingStore();
      store = failing;
      final actor = await seedBoundRoom(alias: 'Свой псевдоним');
      await mount(tester, seedName: false, answerName: false);
      final session = tester
          .widget<_LifecycleTestEditor>(find.byType(_LifecycleTestEditor))
          .session;
      expect(
        session.participants.singleWhere((person) => person.isSelf).name,
        'Свой псевдоним',
      );
      expect(
        session.participants
            .singleWhere((person) => person.isSelf)
            .boundPersonFullName,
        'Анна Иванова',
      );
      final original = await store.loadHistory(roomId);
      await settings(tester, 'Изменить моё имя');
      final field = find.byKey(const Key('participant-name'));
      final unbind = find.byKey(const Key('participant-unbind'));
      await tester.enterText(field, 'Новое несохранённое имя');
      failing.failWrites = true;
      await tester.tap(unbind);
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось отменить связь:'), findsOneWidget);
      expect(find.textContaining('History write blocked'), findsWidgets);
      expect(await store.loadHistory(roomId), original);
      expect(session.durableTree.bindings[actor], rootTreePersonId);
      expect(session.boundPersonFullName, 'Анна Иванова');
      expect(unbind, findsOneWidget);
      expect(tester.widget<TextButton>(unbind).onPressed, isNotNull);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Новое несохранённое имя',
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('Не удалось отменить связь:'), findsOneWidget);
      failing.failWrites = false;
      await tester.tap(unbind);
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось отменить связь:'), findsNothing);
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(unbind, findsNothing);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Новое несохранённое имя',
      );
      expect(session.participantName, 'Свой псевдоним');
      expect(session.boundPersonId, isNull);
      expect(session.durableTree.bindings, {
        'other-device': rootTreePersonId,
        'another-device': rootTreePersonId,
      });
      final saved = decodeRoomHistory(await store.loadHistory(roomId));
      expect(saved, hasLength(original.length + 1));
      expect(
        saved.where(
          (edit) =>
              edit.kind == RoomEditKind.tree &&
              (jsonDecode(edit.text) as Map)['type'] == 'unbindActor',
        ),
        hasLength(1),
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(session.participantName, 'Новое несохранённое имя');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'legacy bound guest may rename but never sees own unbind button',
    (tester) async {
      final actor = await seedBoundRoom(alias: 'Гость', role: RoomRole.guest);
      await mount(tester, seedName: false, answerName: false);
      final session = tester
          .widget<_LifecycleTestEditor>(find.byType(_LifecycleTestEditor))
          .session;
      final original = await store.loadHistory(roomId);
      expect(session.durableTree.bindings[actor], rootTreePersonId);
      expect(session.boundPersonId, isNull);
      expect(session.canUnbindFromPerson, isFalse);
      await settings(tester, 'Изменить моё имя');
      expect(find.byKey(const Key('participant-unbind')), findsNothing);
      expect(find.textContaining('Это я:'), findsNothing);
      expect(find.text('Отменить «Это я»'), findsNothing);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await store.loadHistory(roomId), original);
      expect(session.durableTree.bindings[actor], rootTreePersonId);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'creating prompts before any membership and cancellation is harmless',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Создать комнату'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(await store.loadLastRoom(), isNull);
      expect(peers, isEmpty);
      expect(find.text('Как вас зовут?'), findsOneWidget);
      expect(find.text('Продолжить'), findsOneWidget);
      expect(find.text('Изменить моё имя'), findsNothing);
      expect(find.text('Сохранить'), findsNothing);
      await tester.enterText(find.byKey(const Key('participant-name')), 'Анна');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.text('Создать комнату'), findsOneWidget);
      expect(await store.loadLastRoom(), isNull);
      expect(peers, isEmpty);
      await tester.tap(find.text('Создать комнату'));
      await answerNamePrompt(tester, name: '  Анна  ');
      final created = (await store.loadLastRoom())!;
      final actor = await store.loadClientId();
      final document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(created)));
      expect(document.participantNames[actor], 'Анна');
      expect(
        document.history.where(
          (edit) => edit.kind == RoomEditKind.participantName,
        ),
        hasLength(1),
      );
      await settings(tester, 'Выход в меню');
      await reopenLastRoom(tester);
      expect(find.byType(ParticipantNameDialog), findsNothing);
      expect(find.byKey(const Key('room-text')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('saved old profile asks once and keeps its existing text', (
    tester,
  ) async {
    await store.saveMembership(roomId);
    await store.appendHistory(roomId, [
      const RoomEdit(
        id: 'old-text',
        author: 'old-actor',
        clock: 1,
        createdAt: 1,
        text: 'Семейные заметки',
      ).toJson(),
    ]);
    await mount(tester, seedName: false, answerName: false);
    expect(find.byType(ParticipantNameDialog), findsOneWidget);
    expect(peers, isEmpty);
    await answerNamePrompt(tester, name: 'Иван');
    await finishSoloDiscovery(tester);
    final actor = await store.loadClientId();
    final document = RoomDocument()
      ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
    expect(document.participantNames[actor], 'Иван');
    expect(document.text, 'Семейные заметки');
    await settings(tester, 'Выход в меню');
    await reopenLastRoom(tester);
    expect(find.byType(ParticipantNameDialog), findsNothing);
    expect(find.byKey(const Key('room-text')), findsOneWidget);
    expect(
      (await store.loadHistory(
        roomId,
      )).where((edit) => edit['kind'] == 'participantName'),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'fresh invitation name cancellation does not save or start networking',
    (tester) async {
      await mount(
        tester,
        uri: Uri.parse('https://current.example/#room=$roomId'),
        answerName: false,
      );
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(peers, isEmpty);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await store.hasMembership(roomId), isFalse);
      expect(await store.loadLastRoom(), isNull);
      expect(await store.loadHistory(roomId), isEmpty);
      expect(peers, isEmpty);
      expect(find.text('Создать комнату'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manual fresh join asks once and pending name is not a local membership',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Присоединиться'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), roomId);
      await tester.tap(find.text('Подключиться'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ParticipantNameDialog), findsOneWidget);
      expect(peers, isEmpty);
      await answerNamePrompt(tester, name: 'Мария');
      expect(peers, hasLength(1));
      expect(await store.hasMembership(roomId), isFalse);
      expect(await store.loadHistory(roomId), isEmpty);
      peers.single.register();
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      final channel = peers.single.outbound.single;
      channel.receive(
        RoomMessage(
          roomId: roomId,
          type: RoomMessageType.welcome,
          actor: 'host',
          history: const [],
          hosting: true,
          online: 2,
          roomMetadata: true,
          roomRoles: true,
          authorHistory: true,
          participantIdentity: true,
          personalSurnames: true,
          explicitSiblings: true,
          patronymics: true,
          marriageHistory: true,
        ).toJson(),
      );
      for (var i = 0; i < 16; i++) {
        await tester.pump();
      }
      expect(await store.hasMembership(roomId), isTrue);
      final actor = await store.loadClientId();
      final document = RoomDocument()
        ..merge(decodeRoomHistory(await store.loadHistory(roomId)));
      expect(document.participantNames[actor], 'Мария');
      expect(document.participantRoles[actor], RoomRole.guest);
      expect(document.history, hasLength(2));
      expect(find.byType(ParticipantNameDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real storage failure remains visible without the normal saved strip',
    (tester) async {
      final failing = _HistoryFailingStore();
      store = failing;
      await store.saveMembership(roomId);
      await mount(tester);
      expect(find.byKey(const Key('save-status')), findsNothing);
      failing.failWrites = true;
      await tester.enterText(
        find.byKey(const Key('room-text')),
        'Не терять данные',
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.textContaining('Не сохранено:'), findsOneWidget);
      expect(find.textContaining('History write blocked'), findsOneWidget);
      expect(find.text('Повторить сохранение'), findsOneWidget);
      expect(find.textContaining('Сохранено на устройстве'), findsNothing);
      failing.failWrites = false;
      await tester.tap(find.text('Повторить сохранение'));
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('save-status')), findsNothing);
      expect(
        (await store.loadHistory(roomId)).last['text'],
        'Не терять данные',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(390, 300),
  ]) {
    testWidgets('floating editor label stays below AppBar at $size', (
      tester,
    ) async {
      await store.saveMembership(roomId);
      await store.appendHistory(roomId, [
        const RoomEdit(
          id: 'floating-label-text',
          author: 'self',
          clock: 1,
          createdAt: 1,
          text: 'Текст под плавающей подписью',
        ).toJson(),
      ]);
      await mount(tester);
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final appBar = tester.getRect(find.byType(AppBar));
      final editor = tester.getRect(find.byKey(const Key('room-text')));
      final label = tester.getRect(find.text('Общее текстовое поле'));
      expect(editor.top - appBar.bottom, greaterThanOrEqualTo(12));
      expect(label.top, greaterThanOrEqualTo(appBar.bottom));
      expect(label.bottom, lessThan(editor.bottom));
      expect(editor.bottom, lessThanOrEqualTo(size.height));
      expect(find.byKey(const Key('save-status')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cursor selection is not a persisted edit', (tester) async {
    await store.saveMembership(roomId);
    await mount(tester);
    await tester.enterText(find.byKey(const Key('room-text')), 'abc');
    await tester.pump();
    final count = (await store.loadHistory(roomId)).length;
    final controller = tester
        .widget<TextField>(find.byKey(const Key('room-text')))
        .controller!;
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect((await store.loadHistory(roomId)).length, count);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
