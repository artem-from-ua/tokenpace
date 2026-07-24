import Foundation
import TokenPaceKit

// MARK: - ShellEnvironment

/// Reads an environment variable from the user's **login shell** configuration (`~/.zshrc`,
/// `~/.zprofile`), for variables the app must see even when it is auto-started at login.
///
/// TokenPace launches at login via `SMAppService`, i.e. **launchd** starts the `.app` binary
/// directly — no shell sits in between, so a plain `export FOO=…` in `~/.zshrc` never reaches
/// `ProcessInfo.processInfo.environment`. To honour such an `export`, we spawn the login shell
/// ourselves (`zsh -l -i -c 'printf %s "$VAR"'`) and read the value off stdout — `-i` sources
/// `~/.zshrc`, `-l` sources `~/.zprofile`, so a variable set in either is found (verified).
///
/// This is the same class of problem as locating `gh`/`claude` under launchd's minimal PATH, and uses
/// the same subprocess pattern as ``GHReleaseFetcher`` / ``ClaudeCLIRefresher``. It is a fallback:
/// callers should prefer `ProcessInfo`'s value (present when the app is launched from a terminal or
/// via `launchctl setenv`) and only ask here when that is absent.
enum ShellEnvironment {

    /// Locations probed for the user's shell, in order. The `SHELL` env var is preferred when it
    /// points at an executable; the explicit list is the launchd-minimal-PATH fallback.
    private static var shellCandidates: [String] {
        var candidates: [String] = []
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            candidates.append(shell)
        }
        candidates.append(contentsOf: ["/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh", "/bin/bash"])
        return candidates
    }

    /// Hard cap on the shell run — sourcing rc files should be sub-second; 5 s covers a slow profile.
    private static let timeout: TimeInterval = 5

    /// Unique markers wrapping the printed value. An **interactive** shell (`-i`) runs the user's full
    /// `~/.zshrc`, including prompt/shell-integration hooks (iTerm2, oh-my-zsh, …) that write escape
    /// sequences to stdout — so the raw output is noisy. Printing the value between these markers lets
    /// us extract exactly the value and discard everything else. The markers are unlikely to occur in
    /// any real integration output.
    private static let startMarker = "__TOKENPACE_ENV_START__"
    private static let endMarker = "__TOKENPACE_ENV_END__"

    /// Read `name` from the login+interactive shell environment, or `nil` if unset/empty or the shell
    /// could not be run. Synchronous and blocking — call off the main thread, or once at startup where
    /// a brief wait is acceptable.
    static func value(for name: String) -> String? {
        guard isValidName(name), let shell = locateShell() else { return nil }

        let box = ProcessBox()
        box.process.executableURL = URL(fileURLWithPath: shell)
        // `-l -i` sources both ~/.zprofile and ~/.zshrc. The value is wrapped in markers so shell-
        // integration escape codes printed by an interactive rc file can be stripped. The var name is
        // validated to [A-Za-z0-9_], so this interpolation cannot inject shell syntax.
        box.process.arguments = ["-l", "-i", "-c", "printf '%s%s%s' '\(startMarker)' \"$\(name)\" '\(endMarker)'"]
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = box.stdout
        box.process.standardError = FileHandle.nullDevice

        do {
            try box.process.run()
        } catch {
            AppLogger.lifecycle.error(
                "shell-env: failed to launch shell: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Read stdout to EOF, then wait — bounded by a watchdog that terminates a hung shell.
        let watchdog = DispatchWorkItem { box.process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = (try? box.stdout.fileHandleForReading.readToEnd()) ?? Data()
        box.process.waitUntilExit()
        watchdog.cancel()

        guard box.process.terminationStatus == 0 else { return nil }
        return Self.extractValue(from: String(decoding: data, as: UTF8.self))
    }

    /// Pull the value from between ``startMarker`` and ``endMarker`` in the shell's (possibly noisy)
    /// stdout. Returns `nil` when the markers are absent or the value is empty. Pure and unit-tested.
    static func extractValue(from output: String) -> String? {
        guard let start = output.range(of: startMarker),
              let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = output[start.upperBound..<end.lowerBound]
        return value.isEmpty ? nil : String(value)
    }

    // MARK: helpers

    /// Only allow variable names the login shell would accept, so the value is interpolated into the
    /// `-c` script without any shell-injection surface.
    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// The first existing executable among ``shellCandidates``.
    private static func locateShell() -> String? {
        shellCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `Process`/`Pipe` are not `Sendable`; this box confines one instance to a single call.
    private final class ProcessBox {
        let process = Process()
        let stdout = Pipe()
    }
}
