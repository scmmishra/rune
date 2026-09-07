import Foundation
import Darwin

nonisolated struct TerminalProcessStatus: Equatable, Sendable {
    let name: String
    let isRunning: Bool
    let isIdle: Bool
}

nonisolated enum TerminalProcessMonitor {
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "nu", "tcsh", "csh", "dash"]

    static func snapshot(roots: [UUID: TerminationTarget]) -> [UUID: TerminalProcessStatus] {
        var result: [UUID: TerminalProcessStatus] = [:]
        for (id, root) in roots {
            guard let shell = info(root.pid), root.stillMatches(shell) else { continue }
            let foregroundPID = shell.kp_eproc.e_tpgid
            guard foregroundPID > 0, let foreground = info(foregroundPID),
                  foreground.kp_eproc.e_tdev == shell.kp_eproc.e_tdev else { continue }
            let name = processName(foreground)
            guard !name.isEmpty else { continue }
            let isShell = shells.contains(name)
            let processArguments = arguments(foregroundPID) ?? []
            let agent = agentName(in: processArguments)
            let isIdle = isShell && (foregroundPID == root.pid || foreground.kp_eproc.e_ppid == root.pid)
            result[id] = TerminalProcessStatus(
                name: agent?.rawValue ?? name,
                isRunning: foreground.kp_proc.p_stat != SSTOP && !isIdle,
                isIdle: isIdle
            )
        }
        return result
    }

    struct TerminationTarget: Codable, Sendable {
        let pid: pid_t
        let startedSeconds: Int
        let startedMicroseconds: Int32

        init(_ process: kinfo_proc) {
            pid = process.kp_proc.p_pid
            startedSeconds = process.kp_proc.p_un.__p_starttime.tv_sec
            startedMicroseconds = process.kp_proc.p_un.__p_starttime.tv_usec
        }

        func stillMatches(_ process: kinfo_proc) -> Bool {
            let start = process.kp_proc.p_un.__p_starttime
            return process.kp_proc.p_pid == pid && start.tv_sec == startedSeconds && start.tv_usec == startedMicroseconds
        }
    }

    static func beginTermination(root: TerminationTarget?) -> [TerminationTarget] {
        guard let root, let rootInfo = info(root.pid), root.stillMatches(rootInfo),
              rootInfo.kp_eproc.e_ppid == getpid() else { return [] }
        let targets = descendants(of: [root])
        for target in targets.reversed() { signal(target, SIGTERM) }
        return targets
    }

    private static func descendants(of roots: [TerminationTarget]) -> [TerminationTarget] {
        var seen: Set<pid_t> = []
        var targets = roots.filter { seen.insert($0.pid).inserted }
        var index = 0
        while index < targets.count {
            let parent = targets[index]
            index += 1
            guard let parentInfo = info(parent.pid), parent.stillMatches(parentInfo) else { continue }
            for child in children(of: parent.pid) {
                guard let childInfo = info(child), childInfo.kp_eproc.e_ppid == parent.pid,
                      seen.insert(child).inserted else { continue }
                targets.append(TerminationTarget(childInfo))
            }
        }
        return targets
    }

    static func cleanSession(root: TerminationTarget, sessionID: pid_t, recoveryFile: URL) -> Bool {
        // Freeze the keeper before inspecting membership: it may have received
        // its ACK but not spawned the user command when Rune's lifeline closes.
        signal(root, SIGSTOP)
        let freezeDeadline = ProcessInfo.processInfo.systemUptime + 2
        while isAlive(root), let process = info(root.pid), process.kp_proc.p_stat != SSTOP,
              ProcessInfo.processInfo.systemUptime < freezeDeadline {
            usleep(1_000)
        }
        // Without a confirmed stop, the keeper could fork after the last sweep.
        if isAlive(root), (info(root.pid)?.kp_proc.p_stat ?? 0) != SSTOP { return false }
        var known: [pid_t: TerminationTarget] = [root.pid: root]
        if let data = try? Data(contentsOf: recoveryFile),
           let targets = try? JSONDecoder().decode([TerminationTarget].self, from: data) {
            for target in targets where isAlive(target) { known[target.pid] = target }
        }
        var terminated: Set<pid_t> = []
        let start = ProcessInfo.processInfo.systemUptime
        repeat {
            guard let processes = userProcesses() else {
                // Keep cleanup authority alive across transient inspection errors.
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            // Keep the original keeper alive until the final sweep. Session IDs
            // alone are not sufficient identity after their original members exit.
            let members = isAlive(root) ? processes.filter { getsid($0.kp_proc.p_pid) == sessionID }.map(TerminationTarget.init) : []
            for target in descendants(of: Array(known.values).filter(isAlive) + members) { known[target.pid] = target }
            let alive = known.values.filter(isAlive)
            if alive.isEmpty { return true }
            for target in alive where target.pid != root.pid {
                if ProcessInfo.processInfo.systemUptime - start >= 0.5 { signal(target, SIGKILL) }
                else if terminated.insert(target.pid).inserted { signal(target, SIGTERM) }
            }
            if alive.allSatisfy({ $0.pid == root.pid }) { signal(root, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime - start < 5
        // Preserve birth-time-checked targets for a later recovery attempt;
        // never leave Stop waiting forever on a kernel inspection failure.
        let remaining = descendants(of: Array(known.values).filter(isAlive))
        try? JSONEncoder().encode(remaining).write(to: recoveryFile, options: .atomic)
        return false
    }

    private static func userProcesses() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
            size = processes.count * MemoryLayout<kinfo_proc>.stride
            let result = processes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
            if result == 0 { return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride)) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    static func forceTermination(_ targets: [TerminationTarget]) {
        for target in targets.reversed() { signal(target, SIGKILL) }
    }

    private static func signal(_ target: TerminationTarget, _ signal: Int32) {
        // PIDs may be reused during the grace period. Only signal the exact
        // processes captured under this terminal, verified by their start times.
        guard let current = info(target.pid), target.stillMatches(current) else { return }
        kill(target.pid, signal)
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        let estimatedCount = proc_listchildpids(parent, nil, 0)
        guard estimatedCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 16)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, capacity) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    static func commandRoot(pid: pid_t, script: String) -> TerminationTarget? {
        guard arguments(pid)?.contains(script) == true else { return nil }
        return ownedRoot(pid: pid, owner: getpid())
    }

    static func ownedRoot(pid: pid_t, owner: pid_t) -> TerminationTarget? {
        guard owner > 1, var process = info(pid) else { return nil }
        for _ in 0..<16 {
            if process.kp_eproc.e_ppid == owner { return TerminationTarget(process) }
            guard process.kp_eproc.e_ppid > 1, let parent = info(process.kp_eproc.e_ppid) else { return nil }
            process = parent
        }
        return nil
    }

    static func isAlive(_ target: TerminationTarget) -> Bool {
        guard let process = info(target.pid), process.kp_proc.p_stat != SZOMB else { return false }
        return target.stillMatches(process)
    }

    static func target(pid: pid_t) -> TerminationTarget? { info(pid).map(TerminationTarget.init) }

    static func isLauncher(pid: pid_t, directory: URL) -> Bool {
        guard let argv = arguments(pid) else { return false }
        return argv.dropFirst().prefix(2).elementsEqual(["--rune-terminal-launch", directory.path])
    }

    private static func processName(_ process: kinfo_proc) -> String {
        var command = process.kp_proc.p_comm
        return withUnsafeBytes(of: &command) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func info(_ pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var value = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &value, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return value
    }

    private static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let success = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard success == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0 else { return nil }
        // KERN_PROCARGS2 contains argc, executable path, padding, then argv.
        var offset = MemoryLayout<Int32>.size
        while offset < size && bytes[offset] != 0 { offset += 1 }
        while offset < size && bytes[offset] == 0 { offset += 1 }
        var strings: [String] = []
        while offset < size && strings.count < argc {
            let start = offset
            while offset < size && bytes[offset] != 0 { offset += 1 }
            strings.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            offset += 1
        }
        guard strings.count >= argc else { return nil }
        return strings
    }

    private static func agentName(in argv: [String]) -> TerminalAgent? {
        guard let executable = argv.first else { return nil }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if let agent = TerminalAgent.detect(in: name) { return agent }
        // Node-based CLIs expose the script path as argv[1]. Do not inspect
        // arbitrary arguments, which may merely mention an agent in a prompt.
        guard ["node", "bun", "deno"].contains(name), argv.count > 1 else { return nil }
        let path = argv[1].lowercased()
        if path.contains("/@anthropic-ai/claude-code/") { return .claude }
        if path.contains("/@openai/codex/") { return .codex }
        if path.contains("/opencode-ai/") { return .openCode }
        if path.contains("/pi-coding-agent/") { return .pi }
        return TerminalAgent.detect(in: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }
}
