import Foundation

/// Writes the zsh integration into Application Support and builds each pane's environment.
///
/// zsh is started with ZDOTDIR pointing at our folder. Our `.zshenv` puts the user's ZDOTDIR
/// back, sources their `.zshenv`, and loads `kabuk.zsh`, so the rest of their startup files
/// run exactly as in any other terminal.
enum ShellIntegration {
    /// KABUK_SUPPORT_DIR moves everything (state, socket, history) elsewhere, so a demo or
    /// debug copy can run next to the user's Kabuk without touching it.
    static var supportDir: URL {
        if let custom = ProcessInfo.processInfo.environment["KABUK_SUPPORT_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Kabuk", isDirectory: true)
    }

    static var shellDir: URL { supportDir.appendingPathComponent("shell", isDirectory: true) }
    static var socketPath: String { supportDir.appendingPathComponent("kabuk.sock").path }

    /// `kabuk-hook` ships next to the app binary.
    static var hookPath: String {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/usr/local/bin")
        return dir.appendingPathComponent("kabuk-hook").path
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: shellDir, withIntermediateDirectories: true)
        try zshenv.write(to: shellDir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try kabukZsh.write(to: shellDir.appendingPathComponent("kabuk.zsh"), atomically: true, encoding: .utf8)
    }

    static var userShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    static func environment(paneID: UUID) -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Kabuk",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "KABUK_PANE_ID": paneID.uuidString,
            "KABUK_SOCKET": socketPath,
            "KABUK_HOOK": hookPath,
            "KABUK_SHELL_DIR": shellDir.path,
        ]
        for key in ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LC_ALL", "LC_CTYPE",
                    "CODEX_HOME", "KABUK_DEMO_BIN", "KABUK_DEMO_DATA"] {
            if let value = inherited[key] { env[key] = value }
        }
        if userShell.hasSuffix("/zsh") {
            if let original = inherited["ZDOTDIR"] { env["KABUK_ORIG_ZDOTDIR"] = original }
            env["ZDOTDIR"] = shellDir.path
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static let zshenv = #"""
    # Kabuk: restore the user's ZDOTDIR, then load their .zshenv and the Kabuk integration.
    if [[ -n "${KABUK_ORIG_ZDOTDIR+X}" ]]; then
      export ZDOTDIR="$KABUK_ORIG_ZDOTDIR"
      unset KABUK_ORIG_ZDOTDIR
    else
      unset ZDOTDIR
    fi
    [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    [[ -o interactive && -r "$KABUK_SHELL_DIR/kabuk.zsh" ]] && source "$KABUK_SHELL_DIR/kabuk.zsh"
    """#

    private static let kabukZsh = #"""
    # Kabuk shell integration: reports each command's start, end and exit code to Kabuk.app.
    [[ -n "$KABUK_PANE_ID" && -n "$KABUK_SOCKET" ]] || return 0
    zmodload zsh/net/socket 2>/dev/null || return 0

    _kabuk_escape() {
      local s=$1
      s=${s//\\/\\\\}
      s=${s//\"/\\\"}
      s=${s//$'\n'/\\n}
      s=${s//$'\t'/\\t}
      s=${s//$'\r'/}
      s=${s//[[:cntrl:]]/ }
      REPLY=$s
    }

    _kabuk_send() {
      zsocket "$KABUK_SOCKET" 2>/dev/null || return 0
      local fd=$REPLY
      print -r -u $fd -- "$1"
      exec {fd}>&-
    }

    # OSC 6973 marks where a command's output starts (C) and ends (D;<exit code>) in the
    # terminal itself, so Kabuk can read back exactly what a failed command printed.
    _kabuk_preexec() {
      print -n "\e]6973;C\a"
      _kabuk_ran=1
      _kabuk_escape "$1"
      _kabuk_send "{\"pane\":\"$KABUK_PANE_ID\",\"source\":\"shell\",\"event\":\"start\",\"cmd\":\"$REPLY\"}"
    }

    _kabuk_precmd() {
      local code=$?
      _kabuk_escape "$PWD"
      if [[ -n $_kabuk_ran ]]; then
        print -n "\e]6973;D;$code\a"
        unset _kabuk_ran
        _kabuk_send "{\"pane\":\"$KABUK_PANE_ID\",\"source\":\"shell\",\"event\":\"end\",\"code\":$code,\"cwd\":\"$REPLY\"}"
      else
        _kabuk_send "{\"pane\":\"$KABUK_PANE_ID\",\"source\":\"shell\",\"event\":\"prompt\",\"cwd\":\"$REPLY\"}"
      fi
    }

    # The demo puts its stand-in tools first, after the user's startup files had their say,
    # and keeps its commands out of the user's history file.
    _kabuk_demo_path() {
      path=($KABUK_DEMO_BIN $path)
      [[ -n $KABUK_DEMO_DATA ]] && fc -p "$KABUK_DEMO_DATA/zsh_history" 1000 1000
      precmd_functions=(${precmd_functions:#_kabuk_demo_path})
    }
    [[ -n $KABUK_DEMO_BIN ]] && precmd_functions+=(_kabuk_demo_path)

    # Codex runs its turns on one shared background server, started from whichever terminal ran
    # codex first, and calls the notify hook from there, with that terminal's pane and socket or
    # none at all. In Kabuk each codex keeps its own, so its turns report from this pane.
    # `function` so an alias of the user's can't break the definition.
    function codex {
      case $1 in
        agents|app-server|remote-control) command codex "$@" ;;
        *)
          if (( ${@[(Ie)--no-daemon]} )); then
            command codex "$@"
          else
            command codex --no-daemon "$@"
          fi
          ;;
      esac
    }

    # Run first so $? is still the command's exit code.
    precmd_functions=(_kabuk_precmd $precmd_functions)
    preexec_functions+=(_kabuk_preexec)
    """#
}
