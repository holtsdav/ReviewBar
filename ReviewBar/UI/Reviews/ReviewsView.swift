import SwiftUI

struct ReviewsView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @State private var filter = ReviewFilter()
    @State private var showingFilters = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let dashboard {
                let filtered = filter.apply(to: dashboard.reviews)
                List {
                    SelectedAppHeader(name: dashboard.app.name)
                    if model.showingCachedData {
                        DataStatusBanner(lastUpdated: model.lastUpdated, issue: model.lastRefreshIssue)
                    }
                    if let issue = dashboard.sectionIssues[.reviews] {
                        Section {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                    }
                    if filtered.isEmpty, dashboard.sectionIssues[.reviews] == nil || !dashboard.reviews.isEmpty {
                        ContentUnavailableView {
                            Label(dashboard.reviews.isEmpty ? "No Reviews" : "No Matching Reviews", systemImage: "star.bubble")
                        } description: {
                            Text(dashboard.reviews.isEmpty
                                 ? "This app has no customer reviews available."
                                 : "Try clearing or changing the active filters.")
                        } actions: {
                            if !dashboard.reviews.isEmpty {
                                Button("Clear Filters") { filter = ReviewFilter() }
                            }
                            if dashboard.nextReviewsPage != nil {
                                Button("Load More Reviews") {
                                    Task { await model.loadMoreReviews(appID: dashboard.id) }
                                }
                            }
                        }
                    } else {
                        Section {
                            ForEach(filtered) { review in
                                NavigationLink(value: review) {
                                    ReviewRow(
                                        review: review,
                                        isUnread: model.unreadReviewIDs.contains(review.id)
                                    )
                                }
                            }

                            if model.isLoadingMoreReviews {
                                HStack {
                                    Spacer()
                                    ProgressView("Loading more reviews…")
                                    Spacer()
                                }
                            } else if dashboard.nextReviewsPage != nil {
                                Button("Load More Reviews") {
                                    Task { await model.loadMoreReviews(appID: dashboard.id) }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } footer: {
                            if dashboard.nextReviewsPage != nil && filter != ReviewFilter() {
                                Text("Filters currently apply to loaded reviews. Load all pages for a complete result.")
                            } else {
                                Text("Unread status is stored only on this device.")
                            }
                        }
                    }
                }
                .refreshable { await model.refresh() }
                .navigationDestination(for: CustomerReview.self) { review in
                    ReviewDetailView(model: model, review: review)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !dashboard.reviews.isEmpty {
                            Menu("Review actions", systemImage: "ellipsis.circle") {
                                Picker("Sort", selection: $filter.sort) {
                                    ForEach(ReviewFilter.Sort.allCases, id: \.self) { sort in
                                        Text(sort.title).tag(sort)
                                    }
                                }
                                if dashboard.reviews.contains(where: { model.unreadReviewIDs.contains($0.id) }) {
                                    Button("Mark All as Read", systemImage: "checkmark.circle") {
                                        Task { await model.markAllRead(in: dashboard) }
                                    }
                                }
                            }
                            Button("Filters", systemImage: filter == ReviewFilter() ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") {
                                showingFilters = true
                            }
                        }
                    }
                }
                .sheet(isPresented: $showingFilters) {
                    ReviewFilterView(filter: $filter, reviews: dashboard.reviews)
                }
            } else {
                ChooseAppView()
            }
        }
        .navigationTitle("Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { AppContextToolbar(dashboards: model.dashboards, selectedAppID: $selectedAppID) }
    }
}

private struct ReviewRow: View {
    let review: CustomerReview
    let isUnread: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) { rowMetadata }
            } else {
                HStack { rowMetadata }
            }
            Text(review.title)
                .font(.headline)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            Text(review.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 6 : 3)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 3) { authorMetadata }
                } else {
                    HStack(spacing: 6) { authorMetadata }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let responseState = review.developerResponseState {
                Label(responseState.title, systemImage: responseState.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "Unread" : "Read")
    }

    @ViewBuilder private var rowMetadata: some View {
                StarRatingView(rating: review.rating)
                if isUnread {
                    Label("New", systemImage: "circle.fill")
                        .font(.caption.bold()).foregroundStyle(.primary)
                }
                Spacer()
                Text(DisplayFormatters.relative(review.createdDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
    }

    @ViewBuilder private var authorMetadata: some View {
                Text(review.reviewerNickname)
                if let territory = DisplayFormatters.territory(review.territory) {
                    Text("·")
                    Text(territory)
                }
                if let version = review.appVersion {
                    Text("·")
                    Text("v\(version)")
                }
    }
}

struct ReviewDetailView: View {
    let model: AppModel
    let review: CustomerReview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    StarRatingView(rating: review.rating)
                    Text(review.title)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(review.reviewerNickname).font(.headline)
                    Text(metadata)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(review.body)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let responseState = review.developerResponseState {
                    Label(responseState.title, systemImage: responseState.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: review.id) {
            await model.markRead(review)
        }
    }

    private var metadata: String {
        var parts = [DisplayFormatters.dateTime(review.createdDate)]
        if let territory = DisplayFormatters.territory(review.territory) { parts.append(territory) }
        if let version = review.appVersion { parts.append("Version \(version)") }
        return parts.joined(separator: " · ")
    }
}

private struct ReviewFilterView: View {
    @Binding var filter: ReviewFilter
    let reviews: [CustomerReview]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Rating") {
                    ForEach((1...5).reversed(), id: \.self) { rating in
                        Toggle(isOn: Binding(
                            get: { filter.ratings.contains(rating) },
                            set: { enabled in
                                if enabled { filter.ratings.insert(rating) }
                                else { filter.ratings.remove(rating) }
                            }
                        )) {
                            StarRatingView(rating: rating)
                        }
                    }
                }

                if !territories.isEmpty {
                    Section("Territory") {
                        Picker("Territory", selection: $filter.territory) {
                            Text("All Territories").tag(String?.none)
                            ForEach(territories, id: \.self) { territory in
                                Text(DisplayFormatters.territory(territory) ?? territory).tag(Optional(territory))
                            }
                        }
                    }
                }

                if !versions.isEmpty {
                    Section("App Version") {
                        Picker("App Version", selection: $filter.appVersion) {
                            Text("All Versions").tag(String?.none)
                            ForEach(versions, id: \.self) { version in
                                Text(version).tag(Optional(version))
                            }
                        }
                    }
                }

                Section {
                    Button("Clear Filters") { filter = ReviewFilter() }
                }
            }
            .navigationTitle("Filter Reviews")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var territories: [String] {
        Set(reviews.compactMap(\.territory)).sorted()
    }

    private var versions: [String] {
        Set(reviews.compactMap(\.appVersion)).sorted(by: >)
    }
}
