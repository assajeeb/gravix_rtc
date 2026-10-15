// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Fast joining with GravixJoin (0.4.19): a room list that warms the rooms on
// screen, a tap that starts the join at once, a room screen that takes the
// connected Room, and a switch to another room from inside a room. Not wired
// into main.dart; copy what you need.
//
//   Navigator.push(context, MaterialPageRoute(builder: (_) => FastJoinListPage(join: fastJoin, me: uid)));

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

/// One per app (or per signed-in user): the token cache and the standby memory
/// live in it. Your backend mints the token (the API secret stays there).
GravixJoin makeFastJoin(Future<Map<String, dynamic>> Function(GravixTokenRequest r) fetchToken) => GravixJoin(
  tokenProvider: GravixTokenProvider.callback(fetchToken, reuse: GravixTokenReuse.fastJoin),
  onEvent: (e) => debugPrint('join: $e'), // timings on the tap's clock (no token in them)
);

class FastJoinListPage extends StatelessWidget {
  const FastJoinListPage({super.key, required this.join, required this.me, required this.rooms});

  final GravixJoin join;
  final String me;
  final List<String> rooms;

  GravixTokenRequest _request(String room) => GravixTokenRequest(room: room, identity: me);

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Rooms')),
    body: ListView.builder(
      itemCount: rooms.length,
      itemBuilder: (context, i) {
        final room = rooms[i];
        // on screen: token + the server's standby pre-connect (no connect)
        unawaited(join.warm(_request(room), role: GravixStandbyRole.visible, rank: i));
        return Listener(
          // finger-down: this room's server first
          onPointerDown: (_) => unawaited(join.warm(_request(room))),
          child: ListTile(
            title: Text(room),
            onTap: () {
              // the tap: the join starts now, beside the navigation
              join.prepare(_request(room));
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FastJoinRoomPage(join: join, request: _request(room)),
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class FastJoinRoomPage extends StatefulWidget {
  const FastJoinRoomPage({super.key, required this.join, required this.request});

  final GravixJoin join;
  final GravixTokenRequest request;

  @override
  State<FastJoinRoomPage> createState() => _FastJoinRoomPageState();
}

class _FastJoinRoomPageState extends State<FastJoinRoomPage> {
  Room? _room;
  String _status = 'connecting…';

  @override
  void initState() {
    super.initState();
    unawaited(_attach());
  }

  Future<void> _attach() async {
    // the tap's connect (no second one); a cold join when the screen was opened
    // another way
    final room = await widget.join.attach(widget.request);
    if (!mounted) return;
    final handle = widget.join.pending(widget.request);
    // the app went to the background before this screen was ever shown: the
    // SDK has left the room; close the screen too
    unawaited(
      handle?.ended.then((why) {
        if (why == GravixPrejoinEndReason.neverShown && mounted) Navigator.of(context).maybePop();
      }),
    );
    setState(() {
      _room = room;
      // events before the attach are not replayed: read the room's state now
      _status = room == null ? 'could not join' : '${room.remoteParticipants.length} in the room';
    });
  }

  Future<void> _switchTo(String next) async {
    final request = GravixTokenRequest(room: next, identity: widget.request.identity);
    // the old session stops now, the new one connects right after it closed
    widget.join.switchTo(request);
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => FastJoinRoomPage(join: widget.join, request: request),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.request.room)),
    body: Center(child: Text(_status)),
    floatingActionButton: _room == null
        ? null
        : FloatingActionButton(
            onPressed: () => _switchTo('${widget.request.room}-next'),
            child: const Icon(Icons.skip_next),
          ),
  );

  @override
  void dispose() {
    // the real exit (a switch already replaced the session: nothing to leave)
    if (widget.join.current?.key == GravixPrejoin.sessionKey(widget.request)) unawaited(widget.join.leave());
    super.dispose();
  }
}
