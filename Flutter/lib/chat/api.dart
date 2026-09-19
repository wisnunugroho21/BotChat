import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

typedef Json = Map<String, dynamic>;
const apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://192.168.1.4:5080',
);

class Api {
  Api() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            options.headers['Authorization'] = 'Bearer ${await token()}';
            handler.next(options);
          } catch (e) {
            handler.reject(DioException(requestOptions: options, error: e));
          }
        },
      ),
    );
  }
  final dio = Dio(
    BaseOptions(
      baseUrl: '$apiUrl/api',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
    ),
  );
  Future<String> token() async =>
      await FirebaseAuth.instance.currentUser?.getIdToken() ?? '';
  Future<dynamic> get(String path, [Json? query]) async =>
      (await dio.get<dynamic>(path, queryParameters: query)).data;
  Future<dynamic> post(String path, [Object? body]) async =>
      (await dio.post<dynamic>(path, data: body)).data;
  Future<dynamic> put(String path, Object body) async =>
      (await dio.put<dynamic>(path, data: body)).data;
  Future<void> delete(String path, [Object? body]) async =>
      dio.delete<dynamic>(path, data: body);
  static String error(Object error) {
    if (error is DioException) {
      final body = error.response?.data;
      if (body is Map && body['error'] is String) {
        return body['error'] as String;
      }
      if (error.response?.statusCode == 401) {
        return 'Your session expired. Sign in again.';
      }
      if (error.response?.statusCode == 429) {
        return 'Too many requests. Please wait a moment.';
      }
      if (error.type == DioExceptionType.cancel) {
        return 'Upload canceled. You can retry.';
      }
      return 'Could not connect. Check your connection and retry.';
    }
    if (error is FirebaseAuthException) {
      return error.message ?? 'Sign-in failed.';
    }
    return 'Something went wrong. Please retry.';
  }
}

extension JsonValues on Json {
  String str(String key) => this[key]?.toString() ?? '';
  List<Json> objects(String key) => (this[key] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}
