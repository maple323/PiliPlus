import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/comment_crawl.dart';
import 'package:PiliPlus/utils/comment_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// 后台抓取任务与弹窗解耦：同一个 oid 必须复用同一个任务实例。
///
/// 这是「关掉弹窗 / 点空白 / 返回上一页后抓取继续」的地基——
/// 只要弹窗和抓取共享同一个 [CommentCrawlTask]，重开弹窗就能接着看进度。
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('piliplus-crawl-task-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.localCache = await Hive.openBox<dynamic>('localCache');
  });

  setUp(() => GStorage.localCache.clear());

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('有数据的任务在同一 oid 上复用同一实例', () async {
    const oid = 1;
    final a = CommentCrawlManager.taskFor(oid: oid, type: 1, fileName: 'a');
    a.state.comments.add(
      const CommentRecord(
        message: 'x',
        uname: 'u',
        like: 0,
        ctime: 0,
        isSub: false,
      ),
    );
    final b = CommentCrawlManager.taskFor(oid: oid, type: 1, fileName: 'a');
    expect(identical(a, b), isTrue);
  });

  test('空任务不占用内存，会重建', () {
    final a = CommentCrawlManager.taskFor(oid: 99, type: 1, fileName: 'a');
    final b = CommentCrawlManager.taskFor(oid: 99, type: 1, fileName: 'a');
    expect(identical(a, b), isFalse);
  });

  test('不同 oid 得到不同任务', () {
    final a = CommentCrawlManager.taskFor(oid: 2, type: 1, fileName: 'a');
    final b = CommentCrawlManager.taskFor(oid: 3, type: 1, fileName: 'b');
    expect(identical(a, b), isFalse);
  });

  test('未完成的断点会在新建任务时恢复到 state', () async {
    const oid = 4;
    final saved = CommentCrawlState(
      cursor: 'cursor-1',
      comments: const [
        CommentRecord(
          message: '断点里的一条评论',
          uname: '某用户',
          like: 3,
          ctime: 1700000000,
          isSub: false,
        ),
      ],
    );
    await GStorage.localCache.put(
      '${LocalCacheKey.commentExportPrefix}$oid',
      _encode(saved),
    );

    final task = CommentCrawlManager.taskFor(oid: oid, type: 1, fileName: 'a');
    expect(task.state.cursor, 'cursor-1');
    expect(task.count, 1);
    expect(task.state.comments.first.message, '断点里的一条评论');
    expect(task.hasResult, isTrue);
    expect(task.running, isFalse);
  });

  test('有结果的任务会被复用，不会丢记录', () async {
    const oid = 5;
    await GStorage.localCache.put(
      '${LocalCacheKey.commentExportPrefix}$oid',
      _encode(
        CommentCrawlState(
          comments: const [
            CommentRecord(
              message: '已抓到的记录',
              uname: 'u',
              like: 0,
              ctime: 0,
              isSub: false,
            ),
          ],
        ),
      ),
    );

    final first = CommentCrawlManager.taskFor(oid: oid, type: 1, fileName: 'a');
    // 模拟「关掉弹窗再打开」：再次请求同一个 oid
    final second = CommentCrawlManager.taskFor(
      oid: oid,
      type: 1,
      fileName: 'a',
    );
    expect(identical(first, second), isTrue);
    expect(second.count, 1);
    expect(second.hasResult, isTrue);
  });

  test('reset 清空结果与断点', () async {
    const oid = 6;
    final task = CommentCrawlManager.taskFor(oid: oid, type: 1, fileName: 'a');
    task.state.comments.add(
      const CommentRecord(
        message: 'x',
        uname: 'u',
        like: 0,
        ctime: 0,
        isSub: false,
      ),
    );

    task.reset();
    expect(task.count, 0);
    expect(task.hasResult, isFalse);
    expect(
      GStorage.localCache.get('${LocalCacheKey.commentExportPrefix}$oid'),
      isNull,
    );
  });
}

String _encode(CommentCrawlState state) => jsonEncode(state.toJson());
