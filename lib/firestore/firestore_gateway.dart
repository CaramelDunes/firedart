import 'dart:async';

import 'package:firedart/generated/google/firestore/v1/common.pb.dart';
import 'package:firedart/generated/google/firestore/v1/document.pb.dart' as fs;
import 'package:firedart/generated/google/firestore/v1/firestore.pbgrpc.dart';
import 'package:firedart/generated/google/firestore/v1/query.pb.dart';
import 'package:grpc/grpc.dart';

import '../firedart.dart';
import 'models.dart';
import 'token_authenticator.dart';

class _FirestoreGatewayStreamCache {
  void Function(String userInfo) onDone;
  String userInfo;

  StreamController<ListenRequest> _listenRequestStreamController;
  StreamController<ListenResponse> _listenResponseStreamController;
  Map<String, Document> _documentMap;

  bool _shouldCleanup;

  Stream<ListenResponse> get stream => _listenResponseStreamController.stream;
  Map<String, Document> get documentMap => _documentMap;

  _FirestoreGatewayStreamCache({this.onDone, this.userInfo});

  void setListenRequest(ListenRequest request, FirestoreClient client, String database) {
    // Close the request stream if this function is called for a second time;
    _listenRequestStreamController?.close();

    _documentMap = <String, Document>{};
    _listenRequestStreamController =
        StreamController<ListenRequest>(onListen: _handleListenOnRequestStream, onCancel: _handleCancelOnRequestStream);
    _listenResponseStreamController = StreamController<ListenResponse>.broadcast(
        onListen: _handleListenOnResponseStream, onCancel: _handleCancelOnResponseStream);
    _listenResponseStreamController.addStream(client.listen(_listenRequestStreamController.stream,
        options: CallOptions(metadata: {'google-cloud-resource-prefix': database})));
    _listenRequestStreamController.add(request);
  }

  void _handleListenOnRequestStream() {
    //print('request stream listen');
  }

  void _handleCancelOnRequestStream() {
    //print('request stream cancel');
  }

  void _handleListenOnResponseStream() {
    //print('response stream first listen');
    _shouldCleanup = false;
  }

  void _handleCancelOnResponseStream() {
    //print('response stream cancel');
    // Clean this up in the future
    _shouldCleanup = true;
    Future.microtask(_handleDone);
  }

  void _handleDone() {
    if (!_shouldCleanup) {
      return;
    }
    print('we should cleanup, calling done for $userInfo');
    onDone?.call(userInfo);
    // Clean up stream resources
    _listenRequestStreamController.close();
  }
}

class FirestoreGateway {
  final FirebaseAuth auth;
  final String database;

  final Map<String, _FirestoreGatewayStreamCache> _listenRequestStreamMap;

  FirestoreClient _client;

  FirestoreGateway(String projectId, {String databaseId, this.auth})
      : database = 'projects/$projectId/databases/${databaseId ?? '(default)'}/documents',
        _listenRequestStreamMap = <String, _FirestoreGatewayStreamCache>{} {
    _setupClient();
  }

  Future<Page<Document>> getCollection(String path, int pageSize, String nextPageToken) async {
    var request = ListDocumentsRequest()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..collectionId = path.substring(path.lastIndexOf('/') + 1)
      ..pageSize = pageSize
      ..pageToken = nextPageToken;
    var response = await _client.listDocuments(request).catchError(_handleError);
    var documents = response.documents.map((rawDocument) => Document(this, rawDocument));
    return Page(documents, response.nextPageToken);
  }

  Stream<List<Document>> streamCollection(String path) {
    if (_listenRequestStreamMap.containsKey(path)) {
      return _mapCollectionStream(_listenRequestStreamMap[path]);
    }

    var selector = StructuredQuery_CollectionSelector()..collectionId = path.substring(path.lastIndexOf('/') + 1);
    var query = StructuredQuery()..from.add(selector);
    final queryTarget = Target_QueryTarget()
      ..parent = path.substring(0, path.lastIndexOf('/'))
      ..structuredQuery = query;
    final target = Target()..query = queryTarget;
    final request = ListenRequest()
      ..database = database
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(onDone: _handleDone, userInfo: path);
    _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, database);

    return _mapCollectionStream(listenRequestStream);
  }

  Future<Document> createDocument(String path, String documentId, fs.Document document) async {
    var split = path.split('/');
    var parent = split.sublist(0, split.length - 1).join('/');
    var collectionId = split.last;

    var request = CreateDocumentRequest()
      ..parent = parent
      ..collectionId = collectionId
      ..documentId = documentId ?? ''
      ..document = document;

    var response = await _client.createDocument(request).catchError(_handleError);
    return Document(this, response);
  }

  Future<Document> getDocument(path) async {
    var rawDocument = await _client.getDocument(GetDocumentRequest()..name = path).catchError(_handleError);
    return Document(this, rawDocument);
  }

  Future<void> updateDocument(String path, fs.Document document, bool update) async {
    document.name = path;

    var request = UpdateDocumentRequest()..document = document;

    if (update) {
      var mask = DocumentMask();
      document.fields.keys.forEach((key) => mask.fieldPaths.add(key));
      request.updateMask = mask;
    }

    await _client.updateDocument(request).catchError(_handleError);
  }

  Future<void> deleteDocument(String path) =>
      _client.deleteDocument(DeleteDocumentRequest()..name = path).catchError(_handleError);

  Stream<Document> streamDocument(String path) {
    if (_listenRequestStreamMap.containsKey(path)) {
      return _mapDocumentStream(_listenRequestStreamMap[path]);
    }

    final documentsTarget = Target_DocumentsTarget()..documents.add(path);
    final target = Target()..documents = documentsTarget;
    final request = ListenRequest()
      ..database = database
      ..addTarget = target;

    final listenRequestStream = _FirestoreGatewayStreamCache(onDone: _handleDone, userInfo: path);
    _listenRequestStreamMap[path] = listenRequestStream;

    listenRequestStream.setListenRequest(request, _client, database);

    return _mapDocumentStream(listenRequestStream);
  }

  Future<List<Document>> runQuery(StructuredQuery structuredQuery, String fullPath) async {
    final runQuery = RunQueryRequest()
      ..structuredQuery = structuredQuery
      ..parent = fullPath.substring(0, fullPath.lastIndexOf('/'));
    final response = _client.runQuery(runQuery);
    return await response.where((event) => event.hasDocument()).map((event) => Document(this, event.document)).toList();
  }

  void _setupClient() {
    _client = FirestoreClient(ClientChannel('firestore.googleapis.com'),
        options: TokenAuthenticator.from(auth)?.toCallOptions);
  }

  void _handleError(e) {
    if (e is GrpcError &&
        [
          StatusCode.unknown,
          StatusCode.unimplemented,
          StatusCode.internal,
          StatusCode.unavailable,
          StatusCode.dataLoss,
        ].contains(e.code)) {
      print('setup client because of error');
      _setupClient();
    }
    throw e;
  }

  void _handleDone(String path) {
    _listenRequestStreamMap.remove(path);
  }

  Stream<List<Document>> _mapCollectionStream(_FirestoreGatewayStreamCache listenRequestStream) {
    return listenRequestStream.stream
        .where((response) => response.hasDocumentChange() || response.hasDocumentRemove() || response.hasDocumentDelete())
        .map((response) {
      if (response.hasDocumentChange()) {
        listenRequestStream.documentMap[response.documentChange.document.name] = Document(this, response.documentChange.document);
      } else {
        listenRequestStream.documentMap.remove(response.documentDelete.document);
      }
      return listenRequestStream.documentMap.values.toList();
    });
  }

  Stream<Document> _mapDocumentStream(_FirestoreGatewayStreamCache listenRequestStream) {
    return listenRequestStream
        .stream
        .where((response) => response.hasDocumentChange() || response.hasDocumentRemove() || response.hasDocumentDelete())
        .map((response) => response.hasDocumentChange() ? Document(this, response.documentChange.document) : null);
  }

}
