import 'dart:isolate';
import 'dart:ui';

import 'package:dharma_deshana/constant/app_constant.dart';
import 'package:dharma_deshana/models/download_info.dart';
import 'package:dharma_deshana/widgets/templates/templates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:persistent_bottom_nav_bar/persistent-tab-view.dart';
import 'package:tuple/tuple.dart';

class DownloadProvider with ChangeNotifier {
  static final String downloadPort = 'downloader_send_port';

  ReceivePort _port = ReceivePort();
  String _localPath = '';

  bool _portRegistered = false;
  bool _hasPermission = false;
  bool _initDownloads = false;

  String _taskDetail = '';
  List<DownloadInfo> _downloadingTasks = List();
  List<DownloadTask> _downloads = List();

  Future<Null> initDownloads() async {
    _downloads = await FlutterDownloader.loadTasks();
    _downloads.sort(
        (a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));
    setDownloadInitialized(true);
  }

  Future<Null> prepare(TargetPlatform platform) async {
    if (!_hasPermission) {
      _hasPermission = await Templates.checkPermission(platform);
    }

    if (_hasPermission) {
      if (_localPath == null || _localPath.isEmpty) {
        _localPath = (await Templates.findLocalPath(platform)) +
            Platform.pathSeparator +
            'Songs';
      }

      final savedDir = Directory(_localPath);
      bool hasExisted = await savedDir.exists();
      if (!hasExisted) {
        savedDir.create();
      }
    }

    await bindBackgroundIsolate();

    FlutterDownloader.registerCallback(downloadCallback);
  }

  Future<Null> bindBackgroundIsolate() async {
    dynamic val = IsolateNameServer.lookupPortByName('downloader_send_port');
    if (val == null) {
      bool isSuccess = IsolateNameServer.registerPortWithName(
          _port.sendPort, 'downloader_send_port');
      if (!isSuccess) {
        bindBackgroundIsolate();
        return;
      }

      _port.listen((dynamic data) {
        downloadNotifier(data);
      });
    }
    setDownloadPortRegistered(true);
  }

  void downloadNotifier(dynamic data) {
    String taskId = data[0];
    DownloadTaskStatus status = data[1];
    int progress = data[2];

    print(
        'Background Isolate Callback: task ($taskId) is in status ($status) and process ($progress)');

    DownloadInfo downloadInfo;
    for (DownloadInfo info in _downloadingTasks) {
      if (info.taskId == taskId) {
        info.progress = progress;
        info.status = status;
        downloadInfo = info;
      }
    }
    if (downloadInfo != null) {
      setTaskDetail(downloadInfo);
    }

    if (status == DownloadTaskStatus.complete) {
      initDownloads();
    }
  }

  static void downloadCallback(
      String id, DownloadTaskStatus status, int progress) {
    final SendPort send =
        IsolateNameServer.lookupPortByName('downloader_send_port');
    send.send([id, status, progress]);
  }

  Future<String> requestDownload(
      String url, String songName, TargetPlatform platform) async {
    await prepare(platform);

    String taskId = '';
    if (hasPermission && isDownloadPortRegistered) {
      taskId = await FlutterDownloader.enqueue(
        url: url,
        headers: {'auth': 'test_for_sql_encoding'},
        savedDir: _localPath,
        fileName: songName + '.mp3',
        showNotification: true,
        openFileFromNotification: true,
      );

      _downloadingTasks.removeWhere((task) => task.songName == songName);

      _downloadingTasks.add(DownloadInfo(taskId: taskId, songName: songName));
    }
    return taskId;
  }

  void deleteDownload(String taskId, String songName) async {
    await FlutterDownloader.remove(taskId: taskId, shouldDeleteContent: true);

    setDownloadInitialized(false);

    _downloadingTasks.removeWhere((info) => info.songName == songName);

    await initDownloads();

    setDummyTaskDetail(songName);
  }

  void cancelDownload(String taskId, String songName) async {
    await FlutterDownloader.pause(taskId: taskId);
    await FlutterDownloader.cancel(taskId: taskId);

    setDownloadInitialized(false);

    _downloadingTasks.removeWhere((info) => info.songName == songName);

    await initDownloads();

    setDummyTaskDetail(songName);
  }

  bool get isDownloadPortRegistered => _portRegistered;
  setDownloadPortRegistered(bool registered) {
    _portRegistered = registered;
    notifyListeners();
  }

  bool get hasPermission => _hasPermission;

  bool get isDownloadsInitialized => _initDownloads;
  setDownloadInitialized(bool initialized) {
    _initDownloads = initialized;
    notifyListeners();
  }

  List<DownloadInfo> get downloadInfoList => _downloadingTasks;
  setDownloadInfoList(List<DownloadInfo> infoList) {
    _downloadingTasks = infoList;
    notifyListeners();
  }

  String get taskDetail => _taskDetail;
  setTaskDetail(DownloadInfo info) {
    _taskDetail = info.taskId +
        '-' +
        info.songName +
        '-' +
        info.progress.toString() +
        '-' +
        info.status.value.toString();
    notifyListeners();
  }

  setDummyTaskDetail(String songName) {
    _taskDetail = _taskDetail == songName ? songName + '1' : songName;
    notifyListeners();
  }

  List<DownloadTask> get downloadTaskList => _downloads;

  bool hasDownloads(String songName) {
    String fileName = songName + '.mp3';
    bool hasDownloads = false;

    for (DownloadTask task in _downloads) {
      if (!hasDownloads &&
          task.filename == fileName &&
          task.status == DownloadTaskStatus.complete) {
        hasDownloads = true;
        break;
      }
    }
    return hasDownloads;
  }

  DownloadTask getDownloadedSongTask(String songName) {
    String fileName = songName + '.mp3';
    DownloadTask downloadTask;

    for (DownloadTask task in _downloads) {
      if (task.filename == fileName &&
          task.status == DownloadTaskStatus.complete) {
        downloadTask = task;
        break;
      }
    }
    return downloadTask;
  }

  Tuple3<int, DownloadInfo, DownloadTask> getDownloadState(String songName) {
    String fileName = songName + '.mp3';
    DownloadTask downloadTask;
    DownloadInfo downloadInfo;

    for (DownloadInfo infoItem in _downloadingTasks) {
      if (infoItem.songName == songName) {
        downloadInfo = infoItem;
        break;
      }
    }

    if (downloadInfo != null) {
      DownloadTaskStatus status = downloadInfo.status;

      int downloadState;
      if (DownloadTaskStatus.complete == status) {
        downloadState = AppConstant.DOWNLOADED_STATE;
      } else if (DownloadTaskStatus.enqueued == status ||
          DownloadTaskStatus.running == status ||
          DownloadTaskStatus.paused == status ||
          DownloadTaskStatus.undefined == status) {
        downloadState = AppConstant.DOWNLOADING_STATE;
      } else if (DownloadTaskStatus.canceled == status) {
        downloadState = AppConstant.DOWNLOADABLE_STATE;
      } else {
        downloadState = AppConstant.DOWNLOAD_FAIL;
      }
      return Tuple3(downloadState, downloadInfo, null);
    }

    for (DownloadTask task in _downloads) {
      if (task.filename == fileName) {
        downloadTask = task;
        break;
      }
    }

    if (downloadTask != null) {
      DownloadTaskStatus status = downloadTask.status;

      int downloadState;
      if (DownloadTaskStatus.complete == status) {
        downloadState = AppConstant.DOWNLOADED_STATE;
      } else if (DownloadTaskStatus.enqueued == status ||
          DownloadTaskStatus.running == status ||
          DownloadTaskStatus.paused == status ||
          DownloadTaskStatus.undefined == status) {
        downloadState = AppConstant.DOWNLOADING_STATE;
      } else if (DownloadTaskStatus.canceled == status) {
        downloadState = AppConstant.DOWNLOADABLE_STATE;
      } else {
        downloadState = AppConstant.DOWNLOAD_FAIL;
      }
      return Tuple3(downloadState, null, downloadTask);
    }
    return Tuple3(AppConstant.DOWNLOADABLE_STATE, null, null);
  }
}
