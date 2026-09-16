import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/reply.dart';
import 'package:PiliPlus/utils/comment_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// 一次后台评论抓取任务。
///
/// 抓取过程与导出弹窗的生命周期完全解耦：关掉弹窗、点空白处、
/// 返回上一页，任务都继续在后台跑。重新打开同一视频的导出弹窗会
/// 挂回同一个任务，接着显示进度和结果。
///
/// 状态变化通过 [ChangeNotifier] 广播，弹窗只是它的一个视图；
/// 抓取本身不持有任何 [BuildContext]。
class CommentCrawlTask extends ChangeNotifier {
  CommentCrawlTask({
    required this.oid,
    required this.type,
    required this.fileName,
  }) : state = CommentCrawlState() {
    _restore();
  }

  /// 评论对象 id，视频为 aid，课程为 epId
  final int oid;

  /// 评论类型，见 VideoType.replyType
  final int type;

  /// 不含扩展名的文件名，保存时使用
  final String fileName;

  /// 抓取进度与已抓内容，可序列化落盘做断点
  final CommentCrawlState state;

  final Stopwatch _watch = Stopwatch();
  Timer? _ticker;

  bool _running = false;
  bool _stopRequested = false;
  bool _completed = false;
  CommentCrawlException? _risk;
  Object? _error;

  String get resumeKey => '${LocalCacheKey.commentExportPrefix}$oid';

  bool get running => _running;
  bool get completed => _completed;
  bool get stopped => _stopRequested && !_running && !_completed;
  bool get hasResult => state.comments.isNotEmpty;

  int get count => state.comments.length;
  Duration get elapsed => _watch.elapsed;
  CommentCrawlException? get risk => _risk;
  Object? get error => _error;

  /// 弹窗标题下方的一行状态文案
  String get statusText {
    if (_running) return '正在抓取...已获取 $count 条';
    if (_risk case final e?) {
      return '触发B站风控：${e.message}\n'
          '已抓 $count 条，断点已保存，稍后可点"继续抓取"续爬';
    }
    if (_error case final e?) {
      return '抓取失败：$e\n断点已保存，稍后可点"继续抓取"续爬';
    }
    if (_completed) {
      return '抓取完成：共 $count 条评论，耗时 ${elapsed.inSeconds} 秒，可复制或保存';
    }
    if (_stopRequested && count > 0) {
      return '已暂停：已抓 $count 条，可复制或保存，也可继续抓取';
    }
    if (count > 0) {
      return '检测到上次未完成的抓取，已恢复 $count 条，可继续';
    }
    return '将抓取全部评论（含楼中楼），预计需要一会儿';
  }

  void _restore() {
    final saved = GStorage.localCache.get(resumeKey);
    if (saved is! String) return;
    try {
      final restored = CommentCrawlState.fromJson(
        jsonDecode(saved) as Map<String, dynamic>,
      );
      state
        ..cursor = restored.cursor
        ..mode = restored.mode
        ..comments.addAll(restored.comments);
    } catch (_) {
      // 断点损坏就当作没有，重新从头抓
    }
  }

  void _checkpoint() =>
      GStorage.localCache.put(resumeKey, jsonEncode(state.toJson()));

  /// 开始（或续爬）。已在跑时调用等同于 [stop]。
  Future<void> start() async {
    if (_running) {
      stop();
      return;
    }
    _running = true;
    _stopRequested = false;
    _completed = false;
    _risk = null;
    _error = null;
    _watch
      ..reset()
      ..start();
    // onProgress 触发很密（每条评论一次），用定时器限到约 4 次/秒广播，
    // 避免弹窗所在的 widget 树被高频重建。
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => notifyListeners(),
    );
    notifyListeners();

    try {
      await ReplyHttp.crawlComments(
        oid: oid,
        type: type,
        state: state,
        isCancelled: () => _stopRequested,
        onCheckpoint: (_) => _checkpoint(),
      );
      if (_stopRequested) {
        _checkpoint();
      } else {
        _completed = true;
        // 抓完的结果也要落盘：退出页面、重开弹窗、甚至重启 app 后
        // 仍能拿到上次抓到的内容去复制/保存。想重新抓用 [reset]。
        _checkpoint();
      }
    } on CommentCrawlException catch (e) {
      _checkpoint();
      if (e.isRiskControl) {
        _risk = e;
      } else {
        _error = e;
      }
    } catch (e) {
      _checkpoint();
      _error = e;
    } finally {
      _ticker?.cancel();
      _ticker = null;
      _watch.stop();
      _running = false;
      notifyListeners();
      // 弹窗可能已经关了，完成情况用 toast 告知
      if (_completed) {
        SmartDialog.showToast('评论抓取完成：共 $count 条');
      } else if (_risk != null) {
        SmartDialog.showToast('评论抓取触发风控，已保存断点，可稍后续爬');
      }
    }
  }

  /// 请求停止，正在跑的循环会在下个检查点退出
  void stop() {
    if (!_running) return;
    _stopRequested = true;
    notifyListeners();
  }

  /// 清空已有结果，回到从头抓的状态。
  ///
  /// 抓完之后结果会一直保留，用户想重新抓一遍时才需要调这个。
  void reset() {
    if (_running) return;
    state
      ..cursor = ''
      ..mode = ReplyFetchMode.auto
      ..comments.clear();
    _completed = false;
    _stopRequested = false;
    _risk = null;
    _error = null;
    _watch.reset();
    GStorage.localCache.delete(resumeKey);
    notifyListeners();
  }

  /// 抓取是否已彻底结束（正常跑完，且当前没在跑）
  bool get finished => _completed && !_running;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

/// 后台抓取任务的注册表，按 oid 复用同一个任务。
abstract final class CommentCrawlManager {
  static final Map<int, CommentCrawlTask> _tasks = {};

  /// 取（或新建）某个评论对象的抓取任务。
  ///
  /// 同一个 oid 在有数据（含已抓完的结果）时始终返回同一个实例，
  /// 所以关掉弹窗再打开、返回上一页再回来，都能看到之前抓到的记录，
  /// 「复制到剪贴板」「保存文件」也一直可用。
  static CommentCrawlTask taskFor({
    required int oid,
    required int type,
    required String fileName,
  }) {
    final existing = _tasks[oid];
    // 有结果或正在跑就复用；空的且不在跑才重建
    if (existing != null && (existing.hasResult || existing.running)) {
      return existing;
    }
    final task = CommentCrawlTask(oid: oid, type: type, fileName: fileName);
    _tasks[oid] = task;
    return task;
  }

  /// 丢弃某个评论对象的任务（含内存结果），下次进入重新开始
  static void discard(int oid) {
    final task = _tasks.remove(oid);
    if (task == null) return;
    GStorage.localCache.delete(task.resumeKey);
    task.dispose();
  }
}
