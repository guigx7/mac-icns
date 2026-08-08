enum CodeSigningRequirements {
    static let teamIdentifier = "DHAFYHA4FG"
    static let client = requirement(for: "com.guigx.macicns")
    static let helper = requirement(for: "com.guigx.macicns.helper")

    private static func requirement(for bundleIdentifier: String) -> String {
        "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
