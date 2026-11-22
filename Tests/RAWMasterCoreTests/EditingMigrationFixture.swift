import Foundation
@testable import RAWMasterCore

/// Existing migration fixtures construct an old catalogue by removing later schemas from a fresh one.
/// Keep their original data/assertions while removing the additive editing schema as well.
func removeEditingSchemaForLegacyFixture(_ store: LibraryStore) throws {
  try removeCatalogSchemaForLegacyFixture(store)
  for table in ["editing_works", "editing_versions", "editing_dispositions", "processing_jobs", "editing_commands", "provider_profiles", "archive_publications", "editing_exports"] {
    try store.exec("DROP TABLE \(table)")
  }
}

/// Older-version fixtures contain the historical schema and its original rows.
func removeCatalogSchemaForLegacyFixture(_ store: LibraryStore) throws {
  try store.exec("PRAGMA foreign_keys=OFF")
  defer { try? store.exec("PRAGMA foreign_keys=ON") }
  let objects = try store.rows("SELECT type,name FROM sqlite_master WHERE name GLOB 'lc_*' ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 ELSE 3 END")
  for row in objects {
    let identifier = row[1].replacingOccurrences(of: "\"", with: "\"\"")
    try store.exec("DROP " + row[0] + " IF EXISTS \"" + identifier + "\"")
  }
}
