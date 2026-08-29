import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/online/mokuro_moe_tasks_section.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/tracking/bangumi_api_client.dart'
    show BangumiSubject;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/manual_download_task_dialog.dart';
import 'package:fushi/src/pages/implementations/download_backend_setup_dialog.dart';
import 'package:fushi/src/pages/implementations/downloads_resource_gap.dart';
import 'package:fushi/src/pages/implementations/media_sources_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_detail_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_download_jobs_panel.dart';
import 'package:fushi/src/pages/implementations/video_download_subscriptions_panel.dart';
import 'package:fushi/src/pages/implementations/video_external_provider_settings_section.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_services.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart'
    show MediaSourceRow, VideoDownloadJobRow;

String _safeSubtitleOnlySegment(String value, {required String fallback}) {
  final String cleaned = safeWindowsFileName(
    value,
  ).replaceAll(_trailingWindowsPathCharacters, '').trim();
  return cleaned.isEmpty ? fallback : cleaned;
}

final RegExp _trailingWindowsPathCharacters = RegExp(r'[. ]+$');
const Set<String> _subtitleOnlyExtensions = <String>{
  '.srt',
  '.ass',
  '.ssa',
  '.vtt',
  '.sub',
};

String _subtitleOnlyExtension(String fileName) {
  final String extension = p.extension(fileName).toLowerCase();
  return _subtitleOnlyExtensions.contains(extension) ? extension : '.srt';
}

String animeDownloadCanonicalTitle(AnimeDownloadPipelineSelection selection) {
  final String english = selection.media.english?.trim() ?? '';
  final String native = selection.media.native?.trim() ?? '';
  final BangumiSubject? bangumi = selection.bangumiSubject;
  final String bangumiJapanese = bangumi?.name.trim() ?? '';
  final String bangumiDisplay = bangumi?.displayName.trim() ?? '';
  return bangumiDisplay.isNotEmpty
      ? bangumiDisplay
      : english.isNotEmpty
      ? english
      : bangumiJapanese.isNotEmpty
      ? bangumiJapanese
      : native.isNotEmpty
      ? native
      : selection.media.displayTitle;
}

String animeDownloadTaskRootPath(AnimeDownloadPipelineSelection selection) =>
    p.join(
      selection.source.rootPath,
      _safeSubtitleOnlySegment(
        animeDownloadCanonicalTitle(selection),
        fallback: '动画',
      ),
    );

int? animeDownloadSeason(AnimeDownloadPipelineSelection selection) {
  final bool episodic =
      selection.torrent.isBatch ||
      selection.torrent.episode != null ||
      (selection.media.episodes ?? 0) > 1;
  if (!episodic) return null;
  final int season = selection.torrent.season ?? 1;
  return season > 0 ? season : 1;
}

typedef JimakuFileBytesDownloader = Future<List<int>> Function(JimakuFile file);

/// 将用户已经配对的 Jimaku 字幕直接写入最终任务目录。下载函数由调用方提供，
/// 使这里不依赖启动时缓存的 provider runtime，也便于验证命名和覆盖规则。
Future<List<String>> downloadAnimeSelectionSubtitles({
  required AnimeDownloadPipelineSelection selection,
  required JimakuFileBytesDownloader downloader,
}) async {
  if (selection.jimakuEntry == null || selection.subtitles.isEmpty) {
    throw StateError('所选集数没有可下载的 Jimaku 字幕。');
  }
  if (selection.source.transport != 'local') {
    throw UnsupportedError('仅字幕下载目前需要选择本地视频来源。');
  }
  final String taskRoot = animeDownloadTaskRootPath(selection);
  final int? season = animeDownloadSeason(selection);
  final String directoryPath = season == null
      ? taskRoot
      : p.join(taskRoot, 'Season ${season.toString().padLeft(2, '0')}');
  final Directory directory = Directory(directoryPath);
  await directory.create(recursive: true);
  final String safeTitle = p.basename(taskRoot);
  final List<String> installed = <String>[];
  for (final (int? selectedEpisode, JimakuFile file) in selection.subtitles) {
    final int? episode = selectedEpisode ?? file.episode;
    final String stem = episode == null
        ? _safeSubtitleOnlySegment(
            p.basenameWithoutExtension(file.name),
            fallback: safeTitle,
          )
        : '$safeTitle - S${(season ?? 1).toString().padLeft(2, '0')}'
              'E${episode.toString().padLeft(2, '0')}';
    final String language = _safeSubtitleOnlySegment(
      detectJimakuSubtitleLanguage(file.name).toLowerCase(),
      fallback: 'ja',
    );
    final File target = File(
      p.join(
        directory.path,
        '$stem.$language${_subtitleOnlyExtension(file.name)}',
      ),
    );
    if (await target.exists()) {
      final int length = await target.length();
      if (length > 0) {
        installed.add(target.path);
        continue;
      }
    }
    final List<int> bytes = await downloader(file);
    if (bytes.isEmpty) {
      throw StateError('Jimaku 字幕下载结果为空：${file.name}');
    }
    await target.writeAsBytes(bytes, flush: true);
    installed.add(target.path);
  }
  return installed;
}

/// 把逐步选择界面的结果转换成 Fushi 原生持久下载任务。
///
/// 类型只依据 Nyaa 标题的本地解析和 AniList 集数，不依赖远端条目的类型字段；
/// 标题优先英文，缺少英文时使用日文原名。
VideoDownloadEnqueueRequest buildAnimeDownloadEnqueueRequest({
  required AnimeDownloadPipelineSelection selection,
  required VideoDownloadBackendTarget backendTarget,
  bool subtitlesPreinstalled = false,
}) {
  final bool episodic =
      selection.torrent.isBatch ||
      selection.torrent.episode != null ||
      (selection.media.episodes ?? 0) > 1;
  final int? parsedSeason = selection.torrent.season;
  final int? season = episodic
      ? (parsedSeason != null && parsedSeason > 0 ? parsedSeason : 1)
      : null;
  final String native = selection.media.native?.trim() ?? '';
  final String canonicalTitle = animeDownloadCanonicalTitle(selection);
  final List<String> aliases = animeTitleOptions(
    selection.media,
  ).where((String title) => title != canonicalTitle).toList(growable: false);
  final VideoMediaReference media = VideoMediaReference(
    providerId: 'anilist',
    mediaId: '${selection.media.id}',
    mediaKind: episodic
        ? VideoMetadataMediaKind.tv
        : VideoMetadataMediaKind.movie,
    discoveryCategory: VideoDiscoveryCategory.anime,
    title: canonicalTitle,
    originalTitle: native.isEmpty ? null : native,
    aliases: aliases,
    year: selection.media.seasonYear,
    season: season,
    anilistId: selection.media.id,
  );
  final List<VideoDownloadSubtitleSelection> subtitles =
      subtitlesPreinstalled || selection.jimakuEntry == null
      ? const <VideoDownloadSubtitleSelection>[]
      : <VideoDownloadSubtitleSelection>[
          for (final (int? episode, JimakuFile file) in selection.subtitles)
            VideoDownloadSubtitleSelection(
              candidate: videoSubtitleCandidateFromJimakuFile(
                entry: selection.jimakuEntry!,
                file: file,
                season: season,
              ),
              season: season,
              episode: episode,
            ),
        ];
  return VideoDownloadEnqueueRequest(
    media: media,
    resource: videoResourceCandidateFromNyaaTorrent(selection.torrent),
    backendTarget: backendTarget,
    targetSourceId: selection.source.id,
    subtitlePolicy: selection.includeSubtitles && !subtitlesPreinstalled
        ? VideoDownloadSubtitlePolicy.bestEffort
        : VideoDownloadSubtitlePolicy.none,
    subtitleSelections: subtitles,
    fileSelections: <VideoDownloadFileSelection>[
      for (final AnimeDownloadFileSelection file in selection.fileSelections)
        VideoDownloadFileSelection(
          relativePath: file.path,
          sizeBytes: file.sizeBytes,
          selected: file.selected,
        ),
    ],
    organizationPolicy: kBangumiNamedVideoDownloadOrganizationPolicy,
    coverUrl: selection.media.coverUrl,
  );
}

/// 独立「下载」页（顶层底栏 tab）＝统一下载中心：番剧下载流程 **直接内联**
/// 铺在页面上（搜番 → 选种 → 配字幕 → 推送 + 下载任务），任务 tab 同时列出
/// 漫画「在线目录」（mokuro.moe）的卷下载队列；页头「添加任务」支持手动粘贴
/// 磁力 / 选 .torrent 文件入队（[ManualDownloadTaskDialog]）。设置 tab 配置
/// 后端/限速/上传/做种/内存。完成后按内容类型自动入库（视频→视频库、书籍/
/// 漫画/游戏/有声书→各域导入器，见 VideoDownloadPipelineService；漫画卷→
/// 书架，见 MokuroMoeDownloadQueue）。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({
    super.key,
    this.initialShowSettings = false,
    this.initialTabIndex = 0,
  });

  /// 初始即显示设置面板（「后端未配置」横幅的「去设置」从对话框入口 push
  /// 本页直落配置用）。默认 false = 正常下载流程。
  final bool initialShowSettings;

  /// 发现详情“管理订阅”等入口可直接落到对应子页。
  final int initialTabIndex;

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  late Future<_DownloadsResourceState> _resourceDependencies;
  VideoDownloadPipelineService? _resourcePipelineSnapshot;
  bool _hasLegacyAnimeTasks = false;

  void _setLegacyAnimeTaskPresence(bool present) {
    if (!mounted || _hasLegacyAnimeTasks == present) return;
    setState(() => _hasLegacyAnimeTasks = present);
  }

  @override
  void initState() {
    super.initState();
    final AppModel appModel = ref.read(appProvider);
    _resourcePipelineSnapshot = appModel.videoDownloadPipelineService;
    _resourceDependencies = _loadResourceDependencies(appModel);
  }

  Future<_DownloadsResourceState> _loadResourceDependencies([
    AppModel? current,
  ]) async {
    final AppModel appModel = current ?? ref.read(appProvider);
    final VideoResourceRegistry? registry = appModel.videoResourceRegistry;
    final VideoDownloadPipelineService? pipeline =
        appModel.videoDownloadPipelineService;
    final bool backendReady = registry != null && pipeline != null;
    final List<MediaSourceRow> sources = backendReady
        ? await appModel.getManagedVideoDownloadSources()
        : const <MediaSourceRow>[];
    VideoDownloadBackendTarget? target;
    Object? identityError;
    // 没来源就别去连后端了：身份解析要打真后端，白连一趟还会把「缺来源」
    // 盖成一条连接错误。
    if (backendReady && sources.isNotEmpty) {
      try {
        target = await appModel.currentVideoDownloadBackendTarget();
      } on Object catch (error) {
        identityError = error;
      }
    }
    final DownloadsResourceGap? gap = findDownloadsResourceGap(
      backendReady: backendReady,
      managedSourceCount: sources.length,
      identityError: identityError,
    );
    if (gap == null && registry != null && pipeline != null && target != null) {
      return _DownloadsResourceReady(
        pipeline: pipeline,
        target: target,
        sources: sources,
        defaultSourceId: appModel.prefsRepo.videoDownloadTargetSourceId,
      );
    }
    // gap == null 时上面三个必然非空，这条只是让类型收敛。
    return _DownloadsResourceBlocked(gap ?? const DownloadsResourceNoBackend());
  }

  /// 「缺受管视频来源」空态的动作：就地开来源管理对话框加一个本地视频文件夹，
  /// 关掉后重算前置条件——不用把用户支去别的页面再走回来。
  Future<void> _addVideoSource() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext _) => const MediaSourcesDialog(mediaKind: 'video'),
    );
    if (!mounted) return;
    setState(() {
      _resourceDependencies = _loadResourceDependencies();
    });
  }

  /// 「后端没配好」空态的动作：就地弹配置引导，配完重算前置条件——与
  /// [_addVideoSource] 同一姿态，不把用户支去设置 tab 再走回来。
  ///
  /// 返回「是否真配完了」：同一个出口还要接给资源 surface 的失败态按钮
  /// （[VideoDownloadBackendSetupPrompt]），那边据此决定要不要重试原提交。
  Future<bool> _openBackendSetup() async {
    final bool done = await promptDownloadBackendSetup(
      context: context,
      appModel: ref.read(appProvider),
    );
    if (!mounted || !done) return false;
    setState(() {
      _resourceDependencies = _loadResourceDependencies();
    });
    return true;
  }

  Widget _buildResourceTab() {
    return FutureBuilder<_DownloadsResourceState>(
      future: _resourceDependencies,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<_DownloadsResourceState> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final _DownloadsResourceState? state = snapshot.data;
            if (state is! _DownloadsResourceReady) {
              final DownloadsResourceGap gap =
                  state is _DownloadsResourceBlocked
                  ? state.gap
                  : const DownloadsResourceNoBackend();
              return switch (gap) {
                DownloadsResourceNoManagedSource() => _buildResourceGate(
                  message: t.download_no_managed_video_source,
                  icon: Icons.create_new_folder_outlined,
                  label: t.download_add_video_source,
                  onPressed: _addVideoSource,
                ),
                // 空态动作直接开配置引导（同 [_addVideoSource] 的就地补齐姿态）：
                // 「后端没配」缺的就是那三两个字段，不该把用户支到整页设置里找。
                DownloadsResourceNoBackend(detail: final String? detail) =>
                  _buildResourceGate(
                    message: detail ?? t.download_backend_not_configured,
                    icon: Icons.download_outlined,
                    label: t.download_backend_setup_start,
                    onPressed: _openBackendSetup,
                  ),
              };
            }
            final _DownloadsResourceReady dependencies = state;
            return AnimeDownloadDialog(
              key: const ValueKey<String>('downloads-resource-workflow'),
              embedded: true,
              showTasks: false,
              resourceWorkspace: true,
              pipelineSources: dependencies.sources,
              defaultPipelineSourceId: dependencies.defaultSourceId,
              onPipelineSubmit: (AnimeDownloadPipelineSelection selection) =>
                  _enqueueAnimeSelection(dependencies, selection),
            );
          },
    );
  }

  Future<void> _enqueueAnimeSelection(
    _DownloadsResourceReady dependencies,
    AnimeDownloadPipelineSelection selection,
  ) async {
    // 任务提交时就建立最终 Bangumi 根目录；视频下载完成后整理器会把原始
    // 容器直接移动进同一目录。这样视频-only 任务也不会等到整理阶段才出现目录。
    await Directory(
      animeDownloadTaskRootPath(selection),
    ).create(recursive: true);
    if (selection.contentMode == AnimeDownloadContentMode.subtitle) {
      await _downloadAnimeSubtitlesOnly(selection);
      return;
    }
    final bool subtitlesPreinstalled =
        selection.contentMode == AnimeDownloadContentMode.both &&
        selection.includeSubtitles &&
        selection.jimakuEntry != null &&
        selection.subtitles.isNotEmpty;
    // 用户已经在配对页明确选好了字幕：先下载并按最终 Bangumi/季度/集数名称
    // 落盘，再创建动画任务。视频完成后用同一命名规则进入这个目录；管线不再
    // 重复下载一次字幕。
    if (subtitlesPreinstalled) {
      await _downloadAnimeSubtitlesOnly(selection);
    }
    await dependencies.pipeline.enqueue(
      buildAnimeDownloadEnqueueRequest(
        selection: selection,
        backendTarget: dependencies.target,
        subtitlesPreinstalled: subtitlesPreinstalled,
      ),
    );
  }

  Future<void> _downloadAnimeSubtitlesOnly(
    AnimeDownloadPipelineSelection selection,
  ) async {
    final AppModel appModel = ref.read(appProvider);
    final String apiKey = appModel.jimakuApiKey.trim();
    if (apiKey.isEmpty) throw StateError('请先填写 Jimaku API Key。');
    // 不复用启动时创建的 registry：用户在本页刚保存 API Key 时 runtime 正在异步
    // 重建，旧 registry 可能还没有 Jimaku provider。这里用当前 Key 和当前代理配置
    // 建立一次短生命周期客户端，确保点击下载立即可用。
    final JimakuClient client = JimakuClient(
      apiKey: apiKey,
      client: await appModel.createDownloadHttpClient(),
    );
    try {
      await downloadAnimeSelectionSubtitles(
        selection: selection,
        downloader: (JimakuFile file) async {
          final List<int>? bytes = await client.downloadFile(
            file.url,
            throwOnError: true,
          );
          if (bytes == null) {
            throw StateError('Jimaku 字幕下载失败：${file.name}');
          }
          return bytes;
        },
      );
    } finally {
      client.close();
    }
  }

  /// 「资源」标签的空态：一句说清缺什么 + 一个直接补上它的按钮。
  Widget _buildResourceGate({
    required String message,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text(label),
            ),
          ],
        ),
      ),
    );
  }

  /// 手动添加任务（磁力链接 / .torrent 文件）：与搜索出的资源同走 v78 持久
  /// 管线，任务出现在任务 tab、同一套排序/搜索/优先级/删除操作。
  Future<void> _openManualTaskDialog() async {
    await showManualDownloadTaskDialog(
      context: context,
      appModel: ref.read(appProvider),
    );
  }

  /// 统一门头：分区导航（资源 / 任务 / 订阅 / 设置）作页头主位 + 页头动作，与其余
  /// 顶层库页同构；独立 push 进来（无 home 壳）时在 leading 位保留返回按钮——旧
  /// AppBar 的自动返回键由这里承接。
  ///
  /// 走 [LibrarySectionTabs.controlled]：本页的 [TabController] 同时驱动 [TabBarView]，
  /// 交给导航组件共用那一个即可。此前这里是「分段条镜像 controller」——外面套
  /// [AnimatedBuilder] 读 index、点段回调 animateTo，两处都只是把 controller 的状态
  /// 抄一遍；抄出来的指示器在横滑 TabBarView 时只能在越过一半时跳一下，共用同一个
  /// controller 才跟手连续滑动。
  Widget _buildHeader(BuildContext tabContext) {
    final bool canPop = Navigator.of(context).canPop();
    return FushiPageHeader.customTitle(
      leading: canPop
          ? FushiIconButton(
              icon: Icons.arrow_back,
              tooltip: t.back,
              onTap: () => Navigator.of(context).maybePop(),
            )
          : null,
      title: LibrarySectionTabs<int>.controlled(
        tabs: <LibrarySectionTab<int>>[
          LibrarySectionTab<int>(value: 0, label: t.download_resources_tab),
          LibrarySectionTab<int>(value: 1, label: t.download_tasks_tab),
          LibrarySectionTab<int>(value: 2, label: t.download_subscriptions_tab),
          LibrarySectionTab<int>(value: 3, label: t.settings),
        ],
        controller: DefaultTabController.of(tabContext),
        focusIdPrefix: 'downloads-tab',
      ),
      // 页头动作只留「添加任务」（2026-08-21 用户点名）：旧「放送日历」
      // 「在线目录」入口都不是下载动作，前者迁往发现页（独立改造），后者
      // 在漫画库页「浏览」视图仍然可达。
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.add,
          tooltip: t.download_task_add,
          label: t.download_task_add,
          onTap: _openManualTaskDialog,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    if (!identical(
      _resourcePipelineSnapshot,
      appModel.videoDownloadPipelineService,
    )) {
      _resourcePipelineSnapshot = appModel.videoDownloadPipelineService;
      _resourceDependencies = _loadResourceDependencies(appModel);
    }
    return DefaultTabController(
      initialIndex: widget.initialShowSettings
          ? 3
          : widget.initialTabIndex.clamp(0, 2),
      length: 4,
      child: Builder(
        builder: (BuildContext tabContext) => Scaffold(
          // BUG-1003：内联下载流程把 apikey/搜番等输入框全放在页面上半部，下载任务折叠区
          // 贴底、中段结果列表是唯一的 Expanded。默认 resizeToAvoidBottomInset:true 时，
          // 手机软键盘弹出会压掉 body 高度、顶掉贴底任务区，使其爬到顶部输入框边上（看似
          // 「下载任务被输入框挤上去」）。关掉 inset 让键盘只覆盖下半部结果/任务区（打字时
          // 本就不看），顶部输入框保持可见、布局不反流。
          resizeToAvoidBottomInset: false,
          // 统一门头（2026-08-13）：与书 / 漫画 / 视频 / 游戏库页同一范式——
          // FushiPageHeader.customTitle（左对齐分段条）+ FushiIconButton 动作，
          // 替代旧 AppBar + 居中 TabBar 的独有形态（本页此前是全 app 唯一还在
          // 用 AppBar 门头的顶层 tab）。分段条与 TabBarView 由同一个
          // TabController 驱动，横滑切页不受影响；旧 TabBar 的「窄屏可滚不裁
          // 字」（BUG-1184）由 FushiSegmentedStrip 的同一契约承接。作为 home
          // tab 时外层已有 SafeArea，这里的 SafeArea 兜的是独立 push 进来
          // （设置/对话框入口）失去 AppBar 后的状态栏避让，双层无副作用。
          body: SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                if (!isCupertinoPlatform(context)) _buildHeader(tabContext),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _buildResourceTab(),
                      // 任务 tab：漫画目录卷下载队列（有任务才占位）+ torrent 任务，
                      // 统一下载中心的同屏任务视图。
                      //
                      // 「同屏只留一份空态」由**旧计划列表**按需折叠实现（BUG-1512）：
                      // 新版任务面板常驻并自带空态与实时指标，旧 AnimeDownloadDialog
                      // 只在真有旧任务时按比例分高度，没有就整块收成 0 高。
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints constraints) {
                          final double legacyHeight =
                              (constraints.maxHeight * 0.38).clamp(180, 360);
                          return Column(
                            children: <Widget>[
                              const MokuroMoeTasksSection(),
                              Expanded(
                                child: VideoDownloadJobsPanel.database(
                                  database: ref.read(appProvider).database,
                                  metricsLoader: ref
                                      .read(appProvider)
                                      .videoDownloadPipelineService
                                      ?.loadTaskSnapshots,
                                  onRetry: (VideoDownloadJobRow job) async {
                                    await ref
                                        .read(appProvider)
                                        .videoDownloadPipelineService
                                        ?.retryJob(job.jobId);
                                  },
                                  onResume: (VideoDownloadJobRow job) async {
                                    await ref
                                        .read(appProvider)
                                        .videoDownloadPipelineService
                                        ?.resumeJob(job.jobId);
                                  },
                                  onCancel: (VideoDownloadJobRow job) async {
                                    await ref
                                        .read(appProvider)
                                        .videoDownloadPipelineService
                                        ?.cancelJob(job.jobId);
                                  },
                                  onOpenDetails: (VideoDownloadJobRow job) async {
                                    final appModel = ref.read(appProvider);
                                    final pipeline =
                                        appModel.videoDownloadPipelineService;
                                    final details = pipeline != null
                                        ? await pipeline.loadJobDetails(
                                            job.jobId,
                                          )
                                        : buildPersistedVideoDownloadJobDetails(
                                            job,
                                            await appModel.database
                                                .getVideoDownloadJobFiles(
                                                  job.jobId,
                                                ),
                                          );
                                    if (!context.mounted) return;
                                    final String torrentId =
                                        (job.backendTaskId ??
                                                job.torrentHash ??
                                                '')
                                            .trim();
                                    await showAppDialog<void>(
                                      context: context,
                                      builder: (BuildContext dialogContext) =>
                                          TorrentTaskDetailDialog.task(
                                            torrentId: torrentId,
                                            title: job.title,
                                            torrentTitle:
                                                job.resourceTitle
                                                        ?.trim()
                                                        .isNotEmpty ==
                                                    true
                                                ? job.resourceTitle!.trim()
                                                : job.title,
                                            backendOverride: details.backend,
                                            liveDataAbsence:
                                                details.liveDataAbsence,
                                            initialSnapshot: details.snapshot,
                                            initialFiles: details.files,
                                          ),
                                    );
                                  },
                                  onSetPriority:
                                      (
                                        VideoDownloadJobRow job,
                                        int priority,
                                      ) async {
                                        final pipeline = ref
                                            .read(appProvider)
                                            .videoDownloadPipelineService;
                                        await pipeline?.setJobPriority(
                                          job.jobId,
                                          priority,
                                        );
                                      },
                                  locationLoader:
                                      (VideoDownloadJobRow job) async {
                                        final pipeline = ref
                                            .read(appProvider)
                                            .videoDownloadPipelineService;
                                        return pipeline == null
                                            ? null
                                            : await pipeline.resolveJobLocation(
                                                job.jobId,
                                              );
                                      },
                                  onDelete:
                                      (job, {required bool deleteFiles}) async {
                                        final appModel = ref.read(appProvider);
                                        final pipeline = appModel
                                            .videoDownloadPipelineService;
                                        if (pipeline != null) {
                                          await pipeline.deleteJob(
                                            job.jobId,
                                            deleteFiles: deleteFiles,
                                          );
                                        } else {
                                          await deletePersistedVideoDownloadJob(
                                            database: appModel.database,
                                            job: job,
                                            deleteFiles: deleteFiles,
                                          );
                                        }
                                      },
                                ),
                              ),
                              SizedBox(
                                height: _hasLegacyAnimeTasks ? legacyHeight : 0,
                                child: Offstage(
                                  offstage: !_hasLegacyAnimeTasks,
                                  child: AnimeDownloadDialog(
                                    embedded: true,
                                    tasksOnly: true,
                                    showTasks: false,
                                    onTaskPresenceChanged:
                                        _setLegacyAnimeTaskPresence,
                                    onOpenSettings: () =>
                                        DefaultTabController.of(
                                          tabContext,
                                        ).animateTo(3),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const VideoDownloadSubscriptionsPanel(),
                      ListView(
                        children: <Widget>[
                          const TorrentSettingsSection(),
                          // 索引器 / 字幕来源 / 发现来源已迁到设置 → 在线服务
                          // （第三方凭据一个家）；下载页设置 tab 留一条跳转，
                          // 番剧下载对话框「去设置」落到这里仍能一步到达。
                          Builder(
                            builder: (BuildContext rowContext) =>
                                AdaptiveSettingsNavigationRow(
                                  title: t.settings_destination_services,
                                  subtitle: t.settings_services_link_subtitle,
                                  icon: Icons.cloud_outlined,
                                  showIcon: true,
                                  onTap: () => Navigator.of(rowContext).push(
                                    adaptivePageRoute(
                                      context: rowContext,
                                      builder: (_) => SettingsDetailPage(
                                        destination: buildServicesDestination(),
                                      ),
                                    ),
                                  ),
                                ),
                          ),
                          const VideoExternalProviderSettingsSection(
                            scope: VideoExternalProviderScope.downloadRouting,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「资源」标签的前置条件解析结果：要么齐备可用，要么缺了具体某一环。
/// 缺什么由 [findDownloadsResourceGap] 判定（BUG-1706）。
sealed class _DownloadsResourceState {
  const _DownloadsResourceState();
}

/// 前置条件没齐；[gap] 说清缺的是后端还是受管视频来源。
class _DownloadsResourceBlocked extends _DownloadsResourceState {
  const _DownloadsResourceBlocked(this.gap);

  final DownloadsResourceGap gap;
}

/// 前置条件齐备，可以搜资源并推送下载。
class _DownloadsResourceReady extends _DownloadsResourceState {
  const _DownloadsResourceReady({
    required this.pipeline,
    required this.target,
    required this.sources,
    required this.defaultSourceId,
  });

  final VideoDownloadPipelineService pipeline;
  final VideoDownloadBackendTarget target;
  final List<MediaSourceRow> sources;
  final int? defaultSourceId;
}
