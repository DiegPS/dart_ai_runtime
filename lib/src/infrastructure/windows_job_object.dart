import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _jobObjectLimitKillOnJobClose = 0x00002000;

final class _BasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSetSize;
  @IntPtr()
  external int maximumWorkingSetSize;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _ExtendedLimitInformation extends Struct {
  external _BasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

class WindowsJobObject {
  WindowsJobObject._(this._handle);

  HANDLE? _handle;

  static WindowsJobObject attachToProcess(int processId) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows Job Objects require Windows.');
    }
    final created = CreateJobObject(null, null);
    final job = created.value;
    if (job.address == 0) {
      throw WindowsException(
        created.error.toHRESULT(),
        message: 'CreateJobObject',
      );
    }
    final information = calloc<_ExtendedLimitInformation>();
    try {
      information.ref.basicLimitInformation.limitFlags =
          _jobObjectLimitKillOnJobClose;
      final configured = SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        information.cast(),
        sizeOf<_ExtendedLimitInformation>(),
      );
      if (!configured.value) {
        throw WindowsException(
          configured.error.toHRESULT(),
          message: 'SetInformationJobObject',
        );
      }
      final opened = OpenProcess(
        PROCESS_ACCESS_RIGHTS(PROCESS_SET_QUOTA | PROCESS_TERMINATE),
        false,
        processId,
      );
      final process = opened.value;
      if (process.address == 0) {
        throw WindowsException(
          opened.error.toHRESULT(),
          message: 'OpenProcess',
        );
      }
      try {
        final assigned = AssignProcessToJobObject(job, process);
        if (!assigned.value) {
          throw WindowsException(
            assigned.error.toHRESULT(),
            message: 'AssignProcessToJobObject',
          );
        }
      } finally {
        CloseHandle(process);
      }
      return WindowsJobObject._(job);
    } catch (_) {
      CloseHandle(job);
      rethrow;
    } finally {
      calloc.free(information);
    }
  }

  void close() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    CloseHandle(handle);
  }
}
