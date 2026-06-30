import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'models.dart';

const Map<String, dynamic> _rtcConfig = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
  'sdpSemantics': 'unified-plan',
};

ShareSource _sourceFromDesktop(DesktopCapturerSource source) => ShareSource(
  id: source.id,
  name: source.name,
  type: source.type.toString().split('.').last.toLowerCase(),
);

Map<String, dynamic> _descriptionToJson(RTCSessionDescription d) => {
  'type': d.type,
  'sdp': d.sdp,
};

RTCSessionDescription _descriptionFromJson(Object? value) {
  final m = value as Map;
  return RTCSessionDescription(m['sdp'] as String?, m['type'] as String?);
}

RTCIceCandidate _candidateFromJson(Object? value) {
  final m = value as Map;
  return RTCIceCandidate(
    m['candidate'] as String?,
    m['sdpMid'] as String?,
    (m['sdpMLineIndex'] as num?)?.toInt(),
  );
}

Future<MediaStream> _getDisplayStream(String sourceId) async {
  try {
    return await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'deviceId': {'exact': sourceId},
        'mandatory': {
          'frameRate': 24,
        },
      },
    });
  } catch (e) {
    final msg = '$e';
    if (!msg.contains('NotFoundError')) rethrow;
    return navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': true,
    });
  }
}

class NativeShareHost {
  NativeShareHost({required this.sendFrame});

  final void Function(Map<String, dynamic> frame) sendFrame;
  RTCPeerConnection? _pc;
  MediaStream? _stream;
  int? _viewer;

  Future<List<ShareSource>> listSources() async {
    if (kIsWeb) return const [];
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen, SourceType.Window],
    );
    return [for (final s in sources) _sourceFromDesktop(s)];
  }

  Future<void> start(int viewerConnId, String sourceId) async {
    await stop();
    _viewer = viewerConnId;
    final pc = await createPeerConnection(_rtcConfig);
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      sendFrame({
        't': 'share.ice',
        'to': viewerConnId,
        'candidate': candidate.toMap(),
      });
    };
    pc.onConnectionState = (state) {
      sendFrame({
        't': 'share.state',
        'to': viewerConnId,
        'state': state.toString().split('.').last,
      });
    };

    final stream = await _getDisplayStream(sourceId);
    _stream = stream;
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    final local = await pc.getLocalDescription();
    if (local != null) {
      sendFrame({
        't': 'share.offer',
        'to': viewerConnId,
        'sourceId': sourceId,
        'sdp': _descriptionToJson(local),
      });
    }
  }

  Future<void> applyAnswer(Object? sdp) async {
    final pc = _pc;
    if (pc == null || sdp == null) return;
    await pc.setRemoteDescription(_descriptionFromJson(sdp));
  }

  Future<void> addIce(Object? candidate) async {
    final pc = _pc;
    if (pc == null || candidate == null) return;
    await pc.addCandidate(_candidateFromJson(candidate));
  }

  Future<void> stop() async {
    _viewer = null;
    final pc = _pc;
    _pc = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    await pc?.close();
  }

  int? get viewer => _viewer;
}

class NativeShareViewer extends ChangeNotifier {
  NativeShareViewer({required this.sendFrame});

  final void Function(Map<String, dynamic> frame) sendFrame;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  int? _host;
  bool initialized = false;
  String status = '未连接';

  Future<void> init() async {
    if (initialized) return;
    await renderer.initialize();
    initialized = true;
  }

  Future<void> applyOffer(int hostConnId, Object? sdp) async {
    await init();
    await stop(closeRenderer: false);
    _host = hostConnId;
    final pc = await createPeerConnection(_rtcConfig);
    _pc = pc;
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
        status = '正在观看';
        notifyListeners();
      }
    };
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      sendFrame({
        't': 'share.ice',
        'to': hostConnId,
        'candidate': candidate.toMap(),
      });
    };
    pc.onConnectionState = (state) {
      status = state.toString().split('.').last;
      notifyListeners();
    };
    if (sdp != null) {
      await pc.setRemoteDescription(_descriptionFromJson(sdp));
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      final local = await pc.getLocalDescription();
      if (local != null) {
        sendFrame({
          't': 'share.answer',
          'to': hostConnId,
          'sdp': _descriptionToJson(local),
        });
      }
    }
  }

  Future<void> addIce(Object? candidate) async {
    final pc = _pc;
    if (pc == null || candidate == null) return;
    await pc.addCandidate(_candidateFromJson(candidate));
  }

  Future<void> stop({bool closeRenderer = true}) async {
    _host = null;
    final pc = _pc;
    _pc = null;
    renderer.srcObject = null;
    status = '已停止';
    notifyListeners();
    await pc?.close();
    if (closeRenderer && initialized) {
      initialized = false;
      await renderer.dispose();
    }
  }

  int? get host => _host;
}
