import Foundation
import Testing
@testable import ReviewBar

struct DecodingTests {
    @Test("Customer review page decodes included response and next link")
    func reviewPage() throws {
        let json = #"""
        {
          "data": [{
            "type": "customerReviews",
            "id": "review-1",
            "attributes": {
              "rating": 4,
              "title": "Useful",
              "body": "Works well",
              "reviewerNickname": "sample-user",
              "createdDate": "2026-07-31T10:15:20.123+00:00",
              "territory": "USA"
            },
            "relationships": {"response": {"data": {"type": "customerReviewResponses", "id": "response-1"}}}
          }],
          "included": [{
            "type": "customerReviewResponses",
            "id": "response-1",
            "attributes": {"responseBody": "Thanks", "lastModifiedDate": "2026-07-31T10:16:00Z", "state": "PUBLISHED"}
          }],
          "links": {"self": "https://api.appstoreconnect.apple.com/v1/apps/app/customerReviews", "next": "https://api.appstoreconnect.apple.com/v1/apps/app/customerReviews?cursor=next"}
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let page = try AppleAPIDecoder.make().decode(
            JSONAPIPage<CustomerReviewAPIResource, CustomerReviewResponseAPIResource>.self,
            from: data
        )
        #expect(page.data.first?.attributes.rating == 4)
        #expect(page.included?.first?.attributes.state == "PUBLISHED")
        #expect(page.links.next?.host == "api.appstoreconnect.apple.com")
    }

    @Test("Build response decodes mixed included resources")
    func buildIncluded() throws {
        let json = #"""
        {
          "data": [],
          "included": [
            {"type":"preReleaseVersions","id":"pre-1","attributes":{"version":"2.0","platform":"IOS"}},
            {"type":"buildBetaDetails","id":"detail-1","attributes":{"internalBuildState":"IN_BETA_TESTING","externalBuildState":"READY_FOR_BETA_SUBMISSION"}}
          ],
          "links": {"self":"https://api.appstoreconnect.apple.com/v1/builds"}
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let page = try AppleAPIDecoder.make().decode(
            JSONAPIPage<BuildAPIResource, BuildIncludedAPIResource>.self,
            from: data
        )
        #expect(page.included?.count == 2)
    }
}

