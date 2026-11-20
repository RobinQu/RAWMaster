import Foundation
@testable import RAWMasterCore

/// Existing migration fixtures construct an old catalogue by removing later schemas from a fresh one.
/// Keep their original data/assertions while removing the additive editing schema as well.
func removeEditingSchemaForLegacyFixture(_ store: LibraryStore) throws {
  for table in ["editing_works", "editing_versions", "editing_dispositions", "processing_jobs", "editing_commands", "provider_profiles", "archive_publications", "editing_exports"] {
    try store.exec("DROP TABLE \(table)")
  }
}
