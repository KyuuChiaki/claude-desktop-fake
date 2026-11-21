// ConnectEx keeps the caller pending while the remote tunnel authenticates.
// A private OVERLAPPED belongs to the local bridge connect. Exactly one final
// status is published to the caller, including its event and IOCP contract.
struct ConnectJob {
  bool used, done;
  volatile LONG cancelled;
  ULONG refs, generation;
  SOCKET socket;
  sockaddr_storage target;
  int length;
  PVOID initial;
  DWORD initial_size;
  LPOVERLAPPED caller;
  OVERLAPPED local;
  HANDLE done_event;
  HANDLE completion_port;
  PVOID completion_key;
};
ConnectJob connect_jobs[256]{};
SRWLOCK connect_job_lock{};
NTSTATUS ConnectionStatus(ULONG error) {
  switch (error) {
  case 0:
    return 0;
  case ERROR_OPERATION_ABORTED:
    return static_cast<NTSTATUS>(0xc0000120u);
  case WSAETIMEDOUT:
    return static_cast<NTSTATUS>(0xc00000b5u);
  case WSAECONNREFUSED:
    return static_cast<NTSTATUS>(0xc0000236u);
  case WSAEHOSTUNREACH:
    return static_cast<NTSTATUS>(0xc000023du);
  case WSAENETUNREACH:
    return static_cast<NTSTATUS>(0xc000023cu);
  default:
    return access_denied;
  }
}
DWORD WINAPI ConnectWorker(PVOID context) {
  auto *job = static_cast<ConnectJob *>(context);
  DWORD transferred = 0;
  int result =
      job->cancelled
          ? Fail(ERROR_OPERATION_ABORTED)
          : ConnectBridge(job->socket,
                          reinterpret_cast<const sockaddr *>(&job->target),
                          job->length, &job->local, real_connect_ex,
                          job->initial, job->initial_size, &transferred);
  ULONG error = result == 0 ? 0 : RtlGetLastWin32Error();
  if (error == WSA_IO_PENDING) {
    DWORD flags = 0;
    auto wait = Original<decltype(&WSAGetOverlappedResult)>(
        winsock_thunks, "WSAGetOverlappedResult");
    if (!wait(job->socket, &job->local, &transferred, TRUE, &flags))
      error = RtlGetLastWin32Error();
    else
      error = 0;
  }
  if (job->cancelled)
    error = ERROR_OPERATION_ABORTED;
  auto socket = Snapshot(job->socket);
  if (!socket.used || socket.generation != job->generation || socket.closing)
    error = ERROR_OPERATION_ABORTED;
  if (!socket.used || socket.generation != job->generation) {
    socket.completion_port = job->completion_port;
    socket.completion_key = job->completion_key;
  }
  const NTSTATUS status = ConnectionStatus(error);
  Count(diagnostic.api_calls[socket.completion_port ? 25 : 24]);
  Api(error ? 23 : 22, error, static_cast<ULONG>(status),
      socket.completion_port ? 1 : 0);
  auto set = System<decltype(&SetEvent)>("SetEvent");
  // Publish data before signaling. A completion consumer may immediately reuse
  // OV.
  HANDLE event = reinterpret_cast<HANDLE>(
      reinterpret_cast<ULONG_PTR>(job->caller->hEvent) & ~ULONG_PTR(1));
  const bool skip_port =
      (reinterpret_cast<ULONG_PTR>(job->caller->hEvent) & 1) != 0;
  const auto caller = job->caller;
  job->caller->InternalHigh = error ? 0 : transferred;
  _InterlockedExchange64(
      reinterpret_cast<volatile LONG64 *>(&job->caller->Internal),
      static_cast<LONG64>(status));
  if (event && set)
    set(event);
  // Hold a worker reference until the completion is posted. Consumers may
  // retry immediately; they must not recycle the record while we still use it.
  RtlAcquireSRWLockExclusive(&connect_job_lock);
  job->done = true;
  if (set)
    set(job->done_event);
  RtlReleaseSRWLockExclusive(&connect_job_lock);
  using Complete = NTSTATUS(NTAPI *)(HANDLE, PVOID, PVOID, NTSTATUS, ULONG_PTR);
  if (socket.completion_port && !skip_port) {
    auto complete =
        reinterpret_cast<Complete>(Raw(L"ntdll.dll", "NtSetIoCompletion"));
    if (!complete || complete(socket.completion_port, socket.completion_key,
                              caller, status, error ? 0 : transferred) < 0)
      NtTerminateProcess(reinterpret_cast<HANDLE>(-1),
                         static_cast<NTSTATUS>(0xe0cdf701u));
  }
  RtlAcquireSRWLockExclusive(&connect_job_lock);
  --job->refs;
  RtlReleaseSRWLockExclusive(&connect_job_lock);
  return 0;
}
bool CancelPreparing(SOCKET socket, LPOVERLAPPED caller) {
  bool found = false;
  RtlAcquireSRWLockExclusive(&connect_job_lock);
  auto cancel = System<decltype(&CancelIoEx)>("CancelIoEx");
  for (auto &job : connect_jobs)
    if (job.used && !job.done && job.socket == socket &&
        (!caller || caller == job.caller)) {
      found = true;
      _InterlockedExchange(&job.cancelled, 1);
      if (cancel)
        cancel(reinterpret_cast<HANDLE>(socket), &job.local);
    }
  RtlReleaseSRWLockExclusive(&connect_job_lock);
  return found;
}
BOOL BeginConnectEx(SOCKET socket, const sockaddr *address, int length,
                    PVOID buffer, DWORD bytes, LPDWORD sent, LPOVERLAPPED ov) {
  const auto entry = Snapshot(socket);
  if (!entry.used || entry.closing || !ov || !address ||
      length < static_cast<int>(sizeof(ADDRESS_FAMILY)) ||
      length > sizeof(sockaddr_storage)) {
    Fail(WSAEFAULT);
    return FALSE;
  }
  if (LoaderLocked()) {
    Fail(WSAEACCES);
    return FALSE;
  }
  ConnectJob *job = nullptr;
  RtlAcquireSRWLockExclusive(&connect_job_lock);
  for (auto &item : connect_jobs)
    if (item.used && !item.done && item.socket == socket) {
      RtlReleaseSRWLockExclusive(&connect_job_lock);
      Fail(WSAEALREADY);
      return FALSE;
    }
  for (auto &item : connect_jobs)
    if (!item.used || (item.done && !item.refs)) {
      job = &item;
      break;
    }
  if (job) {
    const HANDLE done = job->done_event,
                 local = reinterpret_cast<HANDLE>(
                     reinterpret_cast<ULONG_PTR>(job->local.hEvent) &
                     ~ULONG_PTR(1));
    Zero(job, sizeof(*job));
    job->done_event = done;
    job->local.hEvent = local;
    auto create = System<decltype(&CreateEventW)>("CreateEventW");
    auto reset = System<decltype(&ResetEvent)>("ResetEvent");
    if (!job->done_event)
      job->done_event = create(nullptr, TRUE, FALSE, nullptr);
    else
      reset(job->done_event);
    if (!job->local.hEvent)
      job->local.hEvent = create(nullptr, TRUE, FALSE, nullptr);
    else
      reset(job->local.hEvent);
    if (job->local.hEvent)
      job->local.hEvent = reinterpret_cast<HANDLE>(
          reinterpret_cast<ULONG_PTR>(job->local.hEvent) | 1);
    job->used = true;
    job->generation = entry.generation;
    job->completion_port = entry.completion_port;
    job->completion_key = entry.completion_key;
    job->refs = 1;
    job->socket = socket;
    job->caller = ov;
    job->length = length;
    job->initial = buffer;
    job->initial_size = bytes;
    Copy(&job->target, address, length);
    ov->Internal = STATUS_PENDING;
    ov->InternalHigh = 0;
  }
  RtlReleaseSRWLockExclusive(&connect_job_lock);
  if (!job) {
    Fail(WSAENOBUFS);
    return FALSE;
  }
  if (!job->done_event || !job->local.hEvent) {
    job->done = true;
    job->refs = 0;
    Fail(WSAENOBUFS);
    return FALSE;
  }
  if (sent)
    *sent = 0;
  const HANDLE caller_event = reinterpret_cast<HANDLE>(
      reinterpret_cast<ULONG_PTR>(ov->hEvent) & ~ULONG_PTR(1));
  if (caller_event &&
      !System<decltype(&ResetEvent)>("ResetEvent")(caller_event)) {
    job->done = true;
    job->refs = 0;
    ov->Internal = static_cast<ULONG>(access_denied);
    Fail(WSAEINVAL);
    return FALSE;
  }
  auto create = System<decltype(&CreateThread)>("CreateThread");
  HANDLE worker =
      create ? create(nullptr, 0, ConnectWorker, job, 0, nullptr) : nullptr;
  if (!worker) {
    job->done = true;
    job->refs = 0;
    ov->Internal = static_cast<ULONG>(access_denied);
    Fail(WSAENOBUFS);
    return FALSE;
  }
  NtClose(worker);
  RtlSetLastWin32Error(WSA_IO_PENDING);
  return FALSE;
}
bool OwnConnectResult(SOCKET socket, LPOVERLAPPED ov, BOOL wait, LPDWORD bytes,
                      BOOL &result) {
  ConnectJob *own = nullptr;
  const auto generation = Snapshot(socket).generation;
  RtlAcquireSRWLockExclusive(&connect_job_lock);
  for (auto &job : connect_jobs)
    if (job.used && job.socket == socket && job.generation == generation &&
        job.caller == ov) {
      own = &job;
      if (!job.done)
        break;
    }
  if (own)
    ++own->refs;
  RtlReleaseSRWLockExclusive(&connect_job_lock);
  if (!own)
    return false;
  if (wait)
    System<decltype(&WaitForSingleObject)>("WaitForSingleObject")(
        own->done_event, INFINITE);
  const NTSTATUS status = static_cast<NTSTATUS>(ov->Internal);
  if (bytes)
    *bytes = static_cast<DWORD>(ov->InternalHigh);
  result = status == 0;
  if (status != 0)
    RtlSetLastWin32Error(status == STATUS_PENDING
                             ? ERROR_IO_INCOMPLETE
                             : RtlNtStatusToDosError(status));
  RtlAcquireSRWLockExclusive(&connect_job_lock);
  --own->refs;
  RtlReleaseSRWLockExclusive(&connect_job_lock);
  return true;
}
BOOL WSAAPI HookWSAGetOverlappedResult(SOCKET socket, LPWSAOVERLAPPED ov,
                                       LPDWORD bytes, BOOL wait,
                                       LPDWORD flags) {
  BOOL result;
  if (OwnConnectResult(socket, ov, wait, bytes, result)) {
    if (flags)
      *flags = 0;
    return result;
  }
  return Original<decltype(&WSAGetOverlappedResult)>(
      winsock_thunks, "WSAGetOverlappedResult")(socket, ov, bytes, wait, flags);
}
BOOL WINAPI HookGetOverlappedResult(HANDLE file, LPOVERLAPPED ov, LPDWORD bytes,
                                    BOOL wait) {
  BOOL result;
  if (OwnConnectResult(reinterpret_cast<SOCKET>(file), ov, wait, bytes, result))
    return result;
  return Original<decltype(&GetOverlappedResult)>(
      base_thunks, "GetOverlappedResult")(file, ov, bytes, wait);
}
BOOL WINAPI HookCancelIoEx(HANDLE file, LPOVERLAPPED ov) {
  const bool preparing = CancelPreparing(reinterpret_cast<SOCKET>(file), ov);
  const auto s = Snapshot(reinterpret_cast<SOCKET>(file));
  if (preparing)
    ReleaseSocket(s);
  const BOOL result =
      Original<decltype(&CancelIoEx)>(base_thunks, "CancelIoEx")(file, ov);
  return preparing ? TRUE : result;
}
NTSTATUS NTAPI HookNtSetInformationFile(HANDLE file, PIO_STATUS_BLOCK io,
                                        PVOID info, ULONG size,
                                        FILE_INFORMATION_CLASS type) {
  const NTSTATUS status = Original<decltype(&NtSetInformationFile)>(
      native_thunks, "NtSetInformationFile")(file, io, info, size, type);
  if (status >= 0 &&
      (static_cast<ULONG>(type) == 30 || static_cast<ULONG>(type) == 61) &&
      info && size >= 2 * sizeof(PVOID)) {
    auto *values = static_cast<PVOID *>(info);
    RtlAcquireSRWLockExclusive(&socket_lock);
    for (auto &s : sockets)
      if (s.used && s.handle == reinterpret_cast<SOCKET>(file)) {
        s.completion_port = values[0];
        s.completion_key = values[1];
        break;
      }
    RtlReleaseSRWLockExclusive(&socket_lock);
  }
  return status;
}
