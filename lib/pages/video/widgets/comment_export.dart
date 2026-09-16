import 'dart:convert' show utf8;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/utils/comment_crawl.dart';
import 'package:PiliPlus/utils/comment_utils.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 导出某个评论对象（视频 aid / 课程 epId）的全部评论，含楼中楼。
///
/// 真正的抓取跑在 [CommentCrawlManager] 的后台任务里，与这个弹窗无关：
/// 关掉弹窗、点空白处、返回上一页，抓取都继续。重新打开会挂回同一任务。
Future<void> showCommentExportDialog(
  BuildContext context, {
  required int oid,
  required int type,
  required String fileName,
}) => showDialog<void>(
  context: context,
  builder: (context) => CommentExportDialog(
    oid: oid,
    type: type,
    fileName: fileName,
  ),
);

class CommentExportDialog extends StatefulWidget {
  const CommentExportDialog({
    super.key,
    required this.oid,
    required this.type,
    required this.fileName,
  });

  /// 评论对象 id，视频为 aid，课程为 epId
  final int oid;

  /// 评论类型，见 VideoType.replyType
  final int type;

  /// 不含扩展名的文件名
  final String fileName;

  @override
  State<CommentExportDialog> createState() => _CommentExportDialogState();
}

class _CommentExportDialogState extends State<CommentExportDialog> {
  CommentExportFormat _format = CommentExportFormat.txt;
  late final CommentCrawlTask _task;

  @override
  void initState() {
    super.initState();
    _task = CommentCrawlManager.taskFor(
      oid: widget.oid,
      type: widget.type,
      fileName: widget.fileName,
    );
    _task.addListener(_onTaskChanged);
  }

  @override
  void dispose() {
    // 只退订，不停任务：抓取继续在后台跑
    _task.removeListener(_onTaskChanged);
    super.dispose();
  }

  void _onTaskChanged() {
    if (mounted) setState(() {});
  }

  /// 按当前选中的格式生成文本，复制和落盘共用
  String _buildText() => _format == CommentExportFormat.csv
      ? CommentUtils.toCsv(_task.state.comments)
      : CommentUtils.toTxt(_task.state.comments);

  void _copy() => Utils.copyText(_buildText());

  Future<void> _save() => StorageUtils.saveBytes2File(
    name: '${widget.fileName}.${_format.name}',
    bytes: utf8.encode(_buildText()),
    allowedExtensions: [_format.name],
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final secondary = colorScheme.secondary;
    final running = _task.running;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      constraints: Style.dialogFixedConstraints,
      title: const Text('导出评论'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('格式', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              for (final format in CommentExportFormat.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextButton(
                    onPressed: running
                        ? null
                        : () => setState(() => _format = format),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      foregroundColor: secondary,
                      backgroundColor: _format == format
                          ? secondary.withValues(alpha: 0.12)
                          : null,
                    ),
                    child: Text(
                      format.name.toUpperCase(),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _task.statusText,
            style: TextStyle(fontSize: 12, color: secondary),
          ),
          if (running)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '关闭此窗口不会中断抓取，可稍后回来查看',
                style: TextStyle(fontSize: 11, color: colorScheme.outline),
              ),
            ),
          if (!running && _task.hasResult)
            Row(
              children: [
                TextButton.icon(
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_all_outlined, size: 16),
                  label: const Text(
                    '复制到剪贴板',
                    style: TextStyle(fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                TextButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_alt, size: 16),
                  label: const Text(
                    '保存文件',
                    style: TextStyle(fontSize: 13),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text('关闭', style: TextStyle(color: colorScheme.outline)),
        ),
        // 已抓到末页：结果会一直保留，可复制/保存，也可清掉重抓
        if (_task.finished)
          TextButton(
            onPressed: () {
              _task.reset();
              _task.start();
            },
            child: const Text('重新抓取'),
          )
        else if (running)
          TextButton(onPressed: _task.stop, child: const Text('停止'))
        else
          TextButton(
            onPressed: _task.start,
            child: Text(_task.hasResult ? '继续抓取' : '开始抓取'),
          ),
      ],
    );
  }
}
