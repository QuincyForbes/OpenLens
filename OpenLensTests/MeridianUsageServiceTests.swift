import Foundation
import Testing
@testable import OpenLens

@MainActor
struct MeridianUsageServiceTests {
    @Test func decodesQuotaProfilesAnd24hTelemetryAndComputesRemainingPercentage() throws {
        let quotaJSON = Data(#"""
        {
          "profiles": [
            {
              "id": "claude-personal",
              "isActive": true,
              "type": "claude-max",
              "windows": [
                {"type": "five_hour", "utilization": 0.08, "resetsAt": 1793404199544},
                {"type": "seven_day", "utilization": 0.87, "resetsAt": 1793541599544},
                {"type": "seven_day_fable", "utilization": 1.0, "resetsAt": 1793541599545}
              ],
              "stale": false
            },
            {
              "id": "chatgpt-team",
              "isActive": false,
              "type": "chatgpt",
              "provider": "chatgpt",
              "planTier": "paid",
              "windows": [
                {"type": "seven_day", "utilization": 0.18, "resetsAt": 1793990426000}
              ]
            }
          ],
          "activeProfile": "claude-personal",
          "activeProfiles": {"claude": "claude-personal", "chatgpt": "chatgpt-team"}
        }
        """#.utf8)

        let profilesJSON = Data(#"""
        {
          "profiles": [
            {
              "id": "claude-personal",
              "type": "claude-max",
              "isActive": true,
              "email": "dev@example.com",
              "allowance": "20x",
              "planLabel": "Personal Max",
              "planName": "Max 20x"
            }
          ],
          "routing": "priority"
        }
        """#.utf8)

        let healthJSON = Data(#"{"status":"healthy","version":"1.85.0"}"#.utf8)
        let telemetryJSON = Data(#"""
        {
          "totalRequests": 420,
          "byModel": {
            "claude-opus-5-5": {"count": 300},
            "gpt-6-astra": {"count": 120}
          },
          "tokenUsage": {"avgCacheHitRate": 0.89},
          "costEstimate": {
            "totalUsd": 128.5,
            "byModel": {
              "claude-opus-5-5": {"estimatedUsd": 90.25},
              "gpt-6-astra": {"estimatedUsd": 38.25}
            }
          }
        }
        """#.utf8)

        let snapshot = try MeridianUsageService.decodeSnapshot(
            baseURL: URL(string: "http://100.114.113.63:3456")!,
            quotaData: quotaJSON,
            profilesData: profilesJSON,
            healthData: healthJSON,
            telemetryData: telemetryJSON
        )

        #expect(snapshot.engineVersion == "1.85.0")
        #expect(snapshot.routingMode == "priority")
        #expect(snapshot.totalRequests24h == 420)
        #expect(snapshot.totalUsd24h == 128.5)
        #expect(snapshot.cacheHitRate24h == 0.89)
        #expect(snapshot.profiles.count == 2)
        #expect(snapshot.profiles[0].displayName == "dev@example.com")
        #expect(snapshot.profiles[0].subtitle == "Claude · Max 20x · 20x")
        #expect(snapshot.profiles[0].windows.map(\.remainingPercent) == [92, 13, 0])
        #expect(snapshot.profiles[0].windows.map(\.label) == ["5h", "7d", "Fable 7d"])
        #expect(snapshot.profiles[1].isActive)
        #expect(snapshot.profiles[1].providerBadge == "ChatGPT")
        #expect(snapshot.models24h.map(\.id) == ["claude-opus-5-5", "gpt-6-astra"])
    }

    @Test func resolvesCustomAndConnectedServerCandidateURLs() {
        let urls = MeridianUsageService.resolveCandidateURLs(
            customEndpoint: "100.114.113.63:3456",
            connectedServerURL: URL(string: "http://192.168.1.25:4096")
        )

        #expect(urls.map(\.absoluteString) == [
            "http://100.114.113.63:3456",
            "http://192.168.1.25:3456"
        ])
    }
}
