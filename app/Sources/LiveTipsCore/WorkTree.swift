import Foundation

/// Pacenote 0.8.7 (L3): "Create the structure for me" in the welcome tour: <work folder>/My workspace/First project.
/// Nothing existing is touched; returns the three lines of the tree to show.
public enum WorkTree {
    @discardableResult
    public static func create(root: String, workspace: String = "My workspace", project: String = "First project") throws -> [String] {
        let fm = FileManager.default
        let r = (root as NSString).expandingTildeInPath
        let p = ((r as NSString).appendingPathComponent(workspace) as NSString).appendingPathComponent(project)
        try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        return [(r as NSString).lastPathComponent + "/", "  " + workspace + "/", "    " + project + "/"]
    }
}
