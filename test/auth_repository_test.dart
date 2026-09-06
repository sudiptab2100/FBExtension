import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/network/api_exception.dart';
import 'package:localdrive_app/data/repositories/auth_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockDio extends Mock implements Dio {}

Response<dynamic> _res(dynamic data, {int status = 200}) => Response<dynamic>(
      requestOptions: RequestOptions(path: '/'),
      statusCode: status,
      data: data,
    );

void main() {
  late _MockDio dio;
  late AuthRepository repo;

  setUp(() {
    dio = _MockDio();
    repo = AuthRepository(dio);
  });

  test('login parses token and admin user', () async {
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => _res({
        'token': 'jwt-123',
        'user': {
          'id': 1,
          'username': 'root',
          'role': 'admin',
          'createdAt': '2024-01-01',
          'home': '',
          'status': 'active',
        },
      }),
    );

    final result = await repo.login('root', 'pw');
    expect(result.token, 'jwt-123');
    expect(result.user!.username, 'root');
    expect(result.user!.isAdmin, isTrue);
  });

  test('register surfaces the pending flag', () async {
    when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => _res({'pending': true, 'message': 'Await approval'}),
    );

    final result = await repo.register('alice', 'pw');
    expect(result.pending, isTrue);
    expect(result.token, isNull);
    expect(result.message, 'Await approval');
  });

  test('me() maps a 401 to an auth ApiException', () async {
    when(() => dio.get(any())).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        response: _res(null, status: 401),
        type: DioExceptionType.badResponse,
      ),
    );

    await expectLater(
      repo.me(),
      throwsA(isA<ApiException>()
          .having((e) => e.isAuth, 'isAuth', isTrue)
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
  });

  test('surfaces the server error body message', () async {
    when(() => dio.get(any())).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/'),
        response: _res({'error': 'Nope'}, status: 400),
        type: DioExceptionType.badResponse,
      ),
    );

    await expectLater(
      repo.me(),
      throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Nope')),
    );
  });
}
