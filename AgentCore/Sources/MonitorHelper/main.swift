import AgentCore

// Privileged helper daemon entry point. launchd starts this as root via the
// SMAppService LaunchDaemon; it serves the agent over a code-signing-pinned XPC
// Mach service and never returns.
HelperListenerDelegate.runForever()
