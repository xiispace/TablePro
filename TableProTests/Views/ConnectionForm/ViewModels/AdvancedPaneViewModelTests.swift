import Testing
@testable import TablePro
import TableProPluginKit

@Suite("Advanced pane external access persistence")
@MainActor
struct AdvancedPaneViewModelTests {
    @Test("Writes external access into persisted fields")
    func writesExternalAccessIntoPersistedFields() {
        let viewModel = AdvancedPaneViewModel()
        viewModel.externalAccess = .readWrite

        var fields: [String: String] = [:]
        viewModel.write(into: &fields)

        #expect(fields["externalAccess"] == ExternalAccessLevel.readWrite.rawValue)
    }

    @Test("Loads external access from persisted fields")
    func loadsExternalAccessFromPersistedFields() {
        let connection = DatabaseConnection(
            name: "Test",
            externalAccess: .readOnly,
            additionalFields: ["externalAccess": ExternalAccessLevel.readWrite.rawValue]
        )
        let viewModel = AdvancedPaneViewModel()

        viewModel.load(from: connection)

        #expect(viewModel.externalAccess == .readWrite)
    }
}
