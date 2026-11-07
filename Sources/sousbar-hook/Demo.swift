import Foundation
import SousCore

/// Fake Claude Code events, so the Touch Bar can be tried without a real session.
enum Demo {
    static let sessionId = "sousbar-demo"

    static func base(_ event: String) -> [String: Any] {
        [
            "hook_event_name": event,
            "session_id": sessionId,
            "cwd": NSHomeDirectory() + "/sousbar-demo",
            "transcript_path": "",
        ]
    }

    static func send(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any]? {
        var input = base(event)
        for (k, v) in extra { input[k] = v }
        return HookMode.send(event: event, input: input, env: HookMode.currentEnv())
    }

    static func report(_ reply: [String: Any]?) {
        guard let output = reply?["output"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print("→ No decision (passed to the terminal, timed out, or app not running).")
            return
        }
        print("→ Decision returned to Claude Code:\n\(text)")
    }

    static let sampleResponse = """
    ## Done: the build is fixed

    The failure came from **two** things. First, `vite.config.ts` pointed at an old alias, so imports from `@/lib` broke. Second, the test script ran before the build finished.

    - Updated the alias to `src/lib`
    - Made `test` depend on `build`

    ```ts
    resolve: { alias: { "@": path.resolve(__dirname, "src") } }
    ```

    All 48 tests pass now. Want me to also add a CI step that catches this next time?
    """

    static func run(_ args: [String]) -> Int32 {
        guard UnixSocket.connect(path: SousPaths.socketPath).map({ close($0); return true }) ?? false else {
            print("SousBar isn't running. Open ~/Applications/SousBar.app first.")
            return 1
        }
        let kind = args.first ?? "flow"
        // Approval and question demos end their fake session afterwards, so it doesn't sit in the
        // session lists as "Working" forever. (flow and response keep it: there's a reply to read.)
        defer {
            if ["permission", "always", "safe", "question"].contains(kind) {
                _ = send("SessionEnd", ["reason": "other"])
            }
        }
        switch kind {
        case "permission":
            print("Sent a Bash permission request. Answer it on the Touch Bar…")
            report(send("PermissionRequest", [
                "tool_name": "Bash",
                "tool_input": ["command": "rm -rf ./dist && npm run build", "description": "Clean build"],
            ]))
        case "always":
            print("Sent a Bash request with an 'always allow' suggestion. Hold Always on the Touch Bar…")
            report(send("PermissionRequest", [
                "tool_name": "Bash",
                "tool_input": ["command": "npm run build", "description": "Build"],
                "permission_suggestions": [[
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "npm run build:*"]],
                    "behavior": "allow",
                    "destination": "localSettings",
                ]],
            ]))
        case "safe":
            print("Sent a read-only permission request (single tap allows)…")
            report(send("PermissionRequest", [
                "tool_name": "WebFetch",
                "tool_input": ["url": "https://example.com/docs", "prompt": "Summarize"],
            ]))
        case "question":
            print("Sent a question. Pick answers on the Touch Bar…")
            report(send("PermissionRequest", [
                "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [
                    [
                        "question": "Which package manager should I use?",
                        "header": "Package manager",
                        "multiSelect": false,
                        "options": [
                            ["label": "pnpm", "description": "Fast, strict"],
                            ["label": "npm", "description": "Default"],
                            ["label": "bun", "description": "Fastest installs"],
                        ],
                    ],
                    [
                        "question": "Which checks should run in CI?",
                        "header": "CI checks",
                        "multiSelect": true,
                        "options": [
                            ["label": "Lint", "description": ""],
                            ["label": "Unit tests", "description": ""],
                            ["label": "E2E", "description": ""],
                        ],
                    ],
                ]],
            ]))
        case "response":
            _ = send("Stop", ["last_assistant_message": sampleResponse, "stop_hook_active": false])
            print("Sent a finished response. Tap the pill on the Touch Bar and swipe to read it.")
        default: // flow
            print("Running a short fake session…")
            _ = send("SessionStart", ["source": "startup"])
            _ = send("UserPromptSubmit", ["prompt": "fix the build"])
            Thread.sleep(forTimeInterval: 1.5)
            _ = send("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/tmp/demo/vite.config.ts"]])
            Thread.sleep(forTimeInterval: 1.5)
            _ = send("PostToolUse", ["tool_name": "Read"])
            _ = send("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm run build"]])
            print("Permission request is on the Touch Bar…")
            report(send("PermissionRequest", [
                "tool_name": "Bash",
                "tool_input": ["command": "npm run build", "description": "Build"],
            ]))
            Thread.sleep(forTimeInterval: 1.5)
            _ = send("PostToolUse", ["tool_name": "Bash"])
            Thread.sleep(forTimeInterval: 1)
            _ = send("Stop", ["last_assistant_message": sampleResponse, "stop_hook_active": false])
            print("Finished. The response is waiting on the Touch Bar (green pill).")
        }
        return 0
    }
}
