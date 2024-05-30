// Copyright (c) 2018, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:web/web.dart';

import '../../client/call.dart';
import '../../shared/message.dart';
import '../../shared/status.dart';
import '../connection.dart';
import 'cors.dart' as cors;
import 'transport.dart';
import 'web_streams.dart';

@JS('Uint8Array')
@staticInterop
class JSUint8Array {
  external factory JSUint8Array(JSAny data);
}

const _contentTypeKey = 'Content-Type';

class XhrTransportStream implements GrpcTransportStream {
  final XMLHttpRequest _request;
  final ErrorHandler _onError;
  final Function(XhrTransportStream stream) _onDone;
  bool _headersReceived = false;
  int _requestBytesRead = 0;
  final StreamController<ByteBuffer> _incomingProcessor = StreamController();
  final StreamController<GrpcMessage> _incomingMessages = StreamController();
  final StreamController<List<int>> _outgoingMessages = StreamController();

  @override
  Stream<GrpcMessage> get incomingMessages => _incomingMessages.stream;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoingMessages.sink;

  XhrTransportStream(this._request,
      {required ErrorHandler onError, required onDone})
      : _onError = onError,
        _onDone = onDone {
    _outgoingMessages.stream.map(frame).listen((data) {
      _sendRequest(data);
    }, cancelOnError: true);

    _request.onReadyStateChange.listen((_) {
      if (_incomingProcessor.isClosed) {
        return;
      }
      switch (_request.readyState) {
        case 2:
          _onHeadersReceived();
          break;
        case 4:
          _onRequestDone();
          _close();
          break;
      }
    });

    _request.onError.listen((ProgressEvent event) {
      if (_incomingProcessor.isClosed) {
        return;
      }
      _onError(GrpcError.unavailable('XhrConnection connection-error'),
          StackTrace.current);
      terminate();
    });

    _request.onProgress.listen((_) {
      if (_incomingProcessor.isClosed) {
        return;
      }
      final responseText = _request.responseText;
      final bytes = Uint8List.fromList(
              responseText.substring(_requestBytesRead).codeUnits)
          .buffer;
      _requestBytesRead = responseText.length;
      _incomingProcessor.add(bytes);
    });

    _incomingProcessor.stream
        .transform(GrpcWebDecoder())
        .transform(grpcDecompressor())
        .listen(_incomingMessages.add,
            onError: _onError, onDone: _incomingMessages.close);
  }

  void _sendRequest(List<int> data) {
    try {
      if (data.isEmpty) {
        data = List.filled(5, 0);
      }
      final uint8Data = Int8List.fromList(data).toJS; // 변환을 사용
      _request.send(uint8Data);
    } catch (e) {
      _onError(e, StackTrace.current);
    }
  }

  void _onHeadersReceived() {
    _headersReceived = true;
    final responseHeaders = _request.getAllResponseHeaders();
    final headersMap = parseHeaders(responseHeaders);
    final metadata = GrpcMetadata(headersMap);
    _incomingMessages.add(metadata);
  }

  void _onRequestDone() {
    if (!_headersReceived) {
      _onHeadersReceived();
    }
    if (_request.status != 200) {
      _onError(
          GrpcError.unavailable(
              'Request failed with status: ${_request.status}',
              null,
              _request.responseText),
          StackTrace.current);
    }
  }

  void _close() {
    _incomingProcessor.close();
    _outgoingMessages.close();
    _onDone(this);
  }

  @override
  Future<void> terminate() async {
    _close();
    _request.abort();
  }
}

class XhrClientConnection implements ClientConnection {
  final Uri uri;
  final _requests = <XhrTransportStream>{};

  XhrClientConnection(this.uri);

  @override
  String get authority => uri.authority;
  @override
  String get scheme => uri.scheme;

  void _initializeRequest(
      XMLHttpRequest request, Map<String, String> metadata) {
    metadata.forEach((key, value) {
      request.setRequestHeader(key, value);
    });
    request.overrideMimeType('text/plain; charset=x-user-defined');
    request.responseType = 'text';
  }

  @visibleForTesting
  XMLHttpRequest createHttpRequest() => XMLHttpRequest();

  @override
  GrpcTransportStream makeRequest(String path, Duration? timeout,
      Map<String, String> metadata, ErrorHandler onError,
      {CallOptions? callOptions}) {
    if (_getContentTypeHeader(metadata) == null) {
      metadata['Content-Type'] = 'application/grpc-web+proto';
      metadata['X-User-Agent'] = 'grpc-web-dart/0.1';
      metadata['X-Grpc-Web'] = '1';
    }

    var requestUri = uri.resolve(path);

    if (callOptions is WebCallOptions &&
        callOptions.bypassCorsPreflight == true) {
      requestUri = cors.moveHttpHeadersToQueryParam(metadata, requestUri);
    }

    final request = createHttpRequest();
    request.open('POST', requestUri.toString());

    if (callOptions is WebCallOptions && callOptions.withCredentials == true) {
      request.withCredentials = true;
    }

    _initializeRequest(request, metadata);

    final transportStream =
        XhrTransportStream(request, onError: onError, onDone: _removeStream);
    _requests.add(transportStream);
    return transportStream;
  }

  void _removeStream(XhrTransportStream stream) {
    _requests.remove(stream);
  }

  @override
  Future<void> terminate() async {
    for (var request in List.of(_requests)) {
      request.terminate();
    }
  }

  @override
  void dispatchCall(ClientCall call) {
    call.onConnectionReady(this);
  }

  @override
  Future<void> shutdown() async {}

  @override
  set onStateChanged(void Function(ConnectionState) cb) {
    // Do nothing.
  }
}

MapEntry<String, String>? _getContentTypeHeader(Map<String, String> metadata) {
  for (var entry in metadata.entries) {
    if (entry.key.toLowerCase() == _contentTypeKey.toLowerCase()) {
      return entry;
    }
  }
  return null;
}

Map<String, String> parseHeaders(String rawHeaders) {
  final headers = <String, String>{};
  final lines = rawHeaders.split('\r\n');
  for (var line in lines) {
    final index = line.indexOf(': ');
    if (index != -1) {
      final key = line.substring(0, index);
      final value = line.substring(index + 2);
      headers[key] = value;
    }
  }
  return headers;
}
