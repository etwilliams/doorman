import Darwin
import Foundation

/// Starts a handler's command. It is spawned directly with no shell, so nothing
/// in a link can be interpreted as a command, in its own session so it outlives
/// Doorman, and with stdio pointed at /dev/null.
enum Launcher {
    // Children are reaped as they exit; a source per child keeps it alive until then.
    private static var reapers: [pid_t: DispatchSourceProcess] = [:]

    /// Returns nil on success, or why the command could not be started.
    @MainActor
    static func spawn(_ command: String, _ args: [String]) -> String? {
        guard !command.isEmpty else { return "No command set" }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Don't leak Doorman's own descriptors into a browser that may run for days.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([command] + args).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawnp(&pid, command, &actions, &attributes, argv, environ)
        guard status == 0 else { return "\(command): \(String(cString: strerror(status)))" }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            var ignored: Int32 = 0
            waitpid(pid, &ignored, 0)
            source.cancel()
            reapers[pid] = nil
        }
        reapers[pid] = source
        source.resume()
        return nil
    }
}
