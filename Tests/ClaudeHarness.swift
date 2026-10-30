import Foundation
@main struct ClaudeHarness {
    static func main() {
        if ClaudeBridge.runIfNeeded() { return }
        let args = CommandLine.arguments
        guard args.count >= 3 else { return }
        do { try ClaudeIntegration.configure(install: args[1] == "install", executable: URL(fileURLWithPath: args[2])) }
        catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
        print(ClaudeIntegration.installed ? "installed" : "removed")
    }
}
