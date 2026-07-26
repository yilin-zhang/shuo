import Foundation
import Testing

@testable import Shuo

@Test
func everySupportedLanguageContainsTheSameLocalizationKeys() throws {
  let localizations = ["en", "zh-Hans", "zh-Hant"]
  let tables = try localizations.map { localization -> Set<String> in
    let url = try #require(
      L10n.bundle.url(
        forResource: "Localizable",
        withExtension: "strings",
        subdirectory: nil,
        localization: localization
      )
    )
    let data = try Data(contentsOf: url)
    let values = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: String]
    )
    return Set(values.keys)
  }

  for table in tables.dropFirst() {
    #expect(table == tables[0])
  }
}
