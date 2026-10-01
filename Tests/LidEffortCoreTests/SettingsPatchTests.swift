import Testing
@testable import LidEffortCore

struct SettingsPatchTests {
    @Test func insertsIntoEmptyFile() {
        let result = SettingsPatch.applyEffortLevel(.high, to: "")
        #expect(SettingsPatch.isValidJSONObject(result))
        #expect(result.contains(#""effortLevel": "high""#))
    }

    @Test func insertsIntoEmptyObject() {
        for source in ["{}", "{ }", "{\n}\n", "  {}  \n"] {
            let result = SettingsPatch.applyEffortLevel(.max, to: source)
            #expect(SettingsPatch.isValidJSONObject(result), "failed for source: \(source.debugDescription)")
            #expect(result.contains(#""effortLevel": "max""#))
        }
    }

    @Test func insertsAsNewKeyPreservingExistingContent() {
        let source = """
        {
          "model": "fable",
          "autoUpdatesChannel": "latest"
        }
        """
        let result = SettingsPatch.applyEffortLevel(.low, to: source)
        #expect(SettingsPatch.isValidJSONObject(result))
        #expect(result.contains(#""model": "fable""#))
        #expect(result.contains(#""autoUpdatesChannel": "latest""#))
        #expect(result.contains(#""effortLevel": "low""#))
    }

    @Test func replacesExistingEffortLevelInPlace() {
        let source = """
        {
          "model": "fable",
          "effortLevel": "xhigh",
          "theme": "light"
        }
        """
        let result = SettingsPatch.applyEffortLevel(.low, to: source)
        #expect(SettingsPatch.isValidJSONObject(result))
        #expect(result.contains(#""effortLevel": "low""#))
        #expect(!result.contains("xhigh"))
        #expect(result.contains(#""model": "fable""#))
        #expect(result.contains(#""theme": "light""#))
        // Only the effortLevel line should change; everything else keeps its
        // exact position and formatting.
        let originalLineCount = source.components(separatedBy: "\n").count
        let resultLineCount = result.components(separatedBy: "\n").count
        #expect(originalLineCount == resultLineCount)
    }

    @Test func realWorldSettingsFileShapeSurvivesInsertAndReplace() {
        let source = """
        {
          "env": {
            "API_TIMEOUT_MS": "3000000"
          },
          "permissions": {
            "allow": [],
            "deny": [],
            "defaultMode": "auto"
          },
          "model": "fable",
          "autoUpdatesChannel": "latest",
          "switchModelsOnFlag": false
        }
        """
        let inserted = SettingsPatch.applyEffortLevel(.high, to: source)
        #expect(SettingsPatch.isValidJSONObject(inserted))
        #expect(inserted.contains(#""switchModelsOnFlag": false"#))
        #expect(inserted.contains(#""effortLevel": "high""#))

        let replaced = SettingsPatch.applyEffortLevel(.max, to: inserted)
        #expect(SettingsPatch.isValidJSONObject(replaced))
        #expect(replaced.contains(#""effortLevel": "max""#))
        #expect(!replaced.contains(#""effortLevel": "high""#))
    }

    @Test func doesNotTouchUnrecognizedNonObjectContent() {
        let source = "not json at all"
        let result = SettingsPatch.applyEffortLevel(.medium, to: source)
        #expect(result == source)
    }
}
