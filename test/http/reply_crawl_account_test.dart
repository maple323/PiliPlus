import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 回归测试：全量抓取评论必须走 NoAccount，不能挂本地伪造的 buvid3。
///
/// 背景（见 `lib/http/reply.dart` 中 [ReplyHttp.crawlComments] 的文档注释）：
/// 抓取走 REST wbi 接口。若请求落到 [AnonymousAccount]，拦截器会挂上
/// `IdUtils.genBuvid3` 生成的伪造 buvid3；服务端判定该 cookie 非法后，
/// 第 1 页就返回 `is_end=true`（实测只剩 3 条），抓取因此只拿到一页。
///
/// 这里不做网络请求，只钉死两件事：
///   1. 源码不变量 —— [ReplyHttp.options] 必须携带 `const NoAccount()`；
///   2. 拦截器行为 —— 带 `NoAccount` 的请求不会附加 buvid3；
///      带 [AnonymousAccount] 的请求会附加。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-crawl-test-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    // AccountManager 的 static 初始化会读 Pref.blockServer，需要 setting box；
    // AnonymousAccount 构造时会经 GrpcHeaders -> Pref.buvid 读 localCache。
    GStorage.setting = await Hive.openBox<dynamic>('setting');
    GStorage.localCache = await Hive.openBox<dynamic>('localCache');
    Accounts.account = await Hive.openBox<LoginAccount>('account');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('ReplyHttp.options', () {
    test('抓取用的 options 绑定 NoAccount 且不带 cookie', () {
      expect(ReplyHttp.options.extra!['account'], isA<NoAccount>());
      expect(ReplyHttp.options.extra!['account'], equals(const NoAccount()));
      expect(ReplyHttp.options.headers!['cookie'], '');
    });
  });

  group('AccountManager.onRequest', () {
    /// 捕获拦截器最终放行的 [RequestOptions]。
    Future<RequestOptions> run(Account account) {
      final interceptor = AccountManager();
      final options = RequestOptions(
        path: 'https://api.bilibili.com/x/v2/reply/wbi/main',
        extra: {'account': account},
      );
      final completer = Completer<RequestOptions>();
      interceptor.onRequest(options, _CaptureHandler(completer));
      return completer.future;
    }

    test('NoAccount 请求不附加 buvid3', () async {
      final opts = await run(const NoAccount());
      final cookie = opts.headers[HttpHeaders.cookieHeader] as String?;
      expect(cookie ?? '', isNot(contains('buvid3')));
    });

    test('AnonymousAccount 请求会附加本地伪造的 buvid3', () async {
      final opts = await run(AnonymousAccount());
      final cookie = opts.headers[HttpHeaders.cookieHeader] as String?;
      // 这条断言记录的是「旧行为为何会翻车」：伪造 buvid3 确实会被挂上。
      expect(cookie, contains('buvid3='));
    });
  });
}

class _CaptureHandler extends RequestInterceptorHandler {
  _CaptureHandler(this._completer);

  final Completer<RequestOptions> _completer;

  @override
  void next(RequestOptions requestOptions) => _completer.complete(requestOptions);

  @override
  void resolve(Response response, [bool callFollowingResponseInterceptor = false]) =>
      _completer.completeError(StateError('unexpected resolve'));

  @override
  void reject(DioException error, [bool callFollowingErrorInterceptor = false]) =>
      _completer.completeError(error);
}
