// File notifications for read-only startup diagnostics. Signing runs outside callbacks.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CdfObservedProcess {
    public string Path, State;
    public long Created;
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern SafeFileHandle OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetProcessTimes(SafeFileHandle process, out long created, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool QueryFullProcessImageName(SafeFileHandle process, uint flags, StringBuilder path, ref uint count);

    public static CdfObservedProcess Read(uint pid, long eventTime) {
        var result = new CdfObservedProcess { State = "unavailable" };
        using (var handle = OpenProcess(0x1000, false, pid)) { // PROCESS_QUERY_LIMITED_INFORMATION
            if (handle.IsInvalid) {
                if (Marshal.GetLastWin32Error() == 87) result.State = "exited";
                return result;
            }
            long exit, kernel, user;
            if (!GetProcessTimes(handle, out result.Created, out exit, out kernel, out user)) return result;
            if (exit != 0) { result.State = "exited"; return result; }
            if (result.Created > eventTime) { result.State = "pid-reused"; return result; }
            var path = new StringBuilder(32768);
            uint count = (uint)path.Capacity;
            if (QueryFullProcessImageName(handle, 0, path, ref count)) {
                result.Path = path.ToString(); result.State = "available";
            }
        }
        return result;
    }
}

public sealed class CdfStartupFileEvents : IDisposable {
    readonly object gate = new object();
    readonly Dictionary<string, DateTime> pending = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, List<FileSystemWatcher>> roots = new Dictionary<string, List<FileSystemWatcher>>(StringComparer.OrdinalIgnoreCase);
    bool closed, rescan;
    long losses;

    public long Losses { get { lock (gate) return losses; } }

    void Lost() {
        lock (gate) { if (!closed) { losses++; rescan = true; } }
    }

    void Changed(string path) {
        if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) path = path.Substring(4);
        lock (gate) {
            if (closed) return;
            if (pending.Count >= 2048 && !pending.ContainsKey(path)) {
                losses++;
                rescan = true;
                return;
            }
            pending[path] = DateTime.UtcNow.AddMilliseconds(200);
        }
    }

    // Only called by the file worker. Subscribing before seeding a new tree
    // covers files that arrive while its initial directory listing is running.
    public bool AddRoot(string root) {
        if (roots.ContainsKey(root)) return false;
        var watches = new List<FileSystemWatcher>();
        try {
            foreach (bool directory in new bool[] { false, true }) {
                var w = new FileSystemWatcher(root.Length >= 248 ? @"\\?\" + root : root, directory ? "*" : "*.exe");
                watches.Add(w);
                w.IncludeSubdirectories = true;
                w.NotifyFilter = directory ? NotifyFilters.DirectoryName :
                    NotifyFilters.FileName | NotifyFilters.Size | NotifyFilters.LastWrite;
                w.InternalBufferSize = 32768;
                w.Created += (s,e) => Changed(e.FullPath);
                if (!directory) {
                    w.Changed += (s,e) => Changed(e.FullPath);
                    w.Deleted += (s,e) => Changed(e.FullPath);
                }
                w.Renamed += (s,e) => { Changed(e.OldFullPath); Changed(e.FullPath); };
                w.Error += (s,e) => Lost();
                w.EnableRaisingEvents = true;
            }
            roots.Add(root, watches);
            return true;
        } catch {
            foreach (var w in watches) w.Dispose();
            throw;
        }
    }

    public string[] Roots { get { return new List<string>(roots.Keys).ToArray(); } }
    public void RemoveRoot(string root) {
        List<FileSystemWatcher> watches;
        if (roots.TryGetValue(root, out watches)) {
            roots.Remove(root);
            foreach (var w in watches) w.Dispose();
        }
    }

    public string[] TakeDue(int limit) {
        lock (gate) {
            var paths = new List<string>();
            var now = DateTime.UtcNow;
            foreach (var item in pending) {
                if (item.Value <= now) paths.Add(item.Key);
                if (paths.Count == limit) break;
            }
            foreach (var path in paths) pending.Remove(path);
            return paths.ToArray();
        }
    }

    public bool TakeRescan() {
        lock (gate) { bool value = rescan; rescan = false; return value; }
    }

    public void Dispose() {
        lock (gate) { closed = true; pending.Clear(); }
        foreach (var root in Roots) RemoveRoot(root);
    }
}
