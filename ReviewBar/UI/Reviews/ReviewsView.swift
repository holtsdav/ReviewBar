import SwiftUI

struct ReviewsView: View {
    let model: AppModel
    let isActive: Bool
    @State private var selectedReviewAppID: String?
    @State private var filter = ReviewFilter()
    @State private var showingFilters = false
    @State private var preparedEntries: [ReviewListEntry] = []
    @State private var preparedKey: ReviewPreparationKey?
    @State private var isPreparingReviews = false

    var body: some View {
        Group {
            if !isActive {
                // TabView keeps sibling tabs alive. Avoid rebuilding and
                // sorting every loaded review while this tab is off-screen.
                Color.clear.accessibilityHidden(true)
            } else if model.dashboards.isEmpty {
                ChooseAppView()
            } else {
                let reviews = scopedDashboards.flatMap(\.reviews)
                let preparationKey = reviewPreparationKey
                let filtered = preparedEntries
                List {
                Section {
                    AppSelectionPicker(
                        dashboards: model.dashboards,
                        selection: $selectedReviewAppID,
                        includesAllApps: true
                    )
                    .accessibilityLabel("Reviews app")
                    .accessibilityValue(selectedReviewAppID.flatMap { id in model.dashboards.first(where: { $0.id == id })?.app.name } ?? "All Apps")
                }

                if model.showingCachedData {
                    DataStatusBanner(lastUpdated: model.lastUpdated, issue: model.lastRefreshIssue)
                }

                ForEach(scopedDashboards.filter { $0.sectionIssues[.reviews] != nil }) { dashboard in
                    if let issue = dashboard.sectionIssues[.reviews] {
                        Section {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        } header: {
                            Text(dashboard.app.name)
                        }
                    }
                }

                if isPreparingReviews && preparedKey != preparationKey {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Updating reviews…")
                            Spacer()
                        }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(reviews.isEmpty ? "No Reviews" : "No Matching Reviews", systemImage: "star.bubble")
                    } description: {
                        Text(reviews.isEmpty
                             ? "No customer reviews are available across the selected apps."
                             : "Try clearing or changing the active filters.")
                    } actions: {
                        if !reviews.isEmpty {
                            Button("Clear Filters") { filter = ReviewFilter() }
                        }
                        if hasMoreReviews {
                            Button("Load More Reviews") { loadMoreReviews() }
                        }
                    }
                } else {
                    Section {
                        ForEach(filtered) { entry in
                            NavigationLink(value: entry.review) {
                                ReviewRow(
                                    review: entry.review,
                                    appName: selectedReviewAppID == nil ? entry.appName : nil,
                                    isUnread: model.unreadReviewIDs.contains(entry.review.id)
                                )
                            }
                        }

                        if model.isLoadingMoreReviews {
                            HStack {
                                Spacer()
                                ProgressView("Loading more reviews…")
                                Spacer()
                            }
                        } else if hasMoreReviews {
                            Button("Load More Reviews") { loadMoreReviews() }
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        if hasMoreReviews && filter != ReviewFilter() {
                            Text("Filters currently apply to loaded reviews. Load all pages for a complete result.")
                        } else {
                            Text("Showing reviews from \(selectedReviewAppID == nil ? "all apps" : "this app"). Unread status is stored only on this device.")
                        }
                    }
                }
                }
                .refreshable { await model.refresh() }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if !reviews.isEmpty && preparedKey == preparationKey {
                            Menu("Review actions", systemImage: "ellipsis.circle") {
                                Picker("Sort", selection: $filter.sort) {
                                    ForEach(ReviewFilter.Sort.allCases, id: \.self) { sort in
                                        Text(sort.title).tag(sort)
                                    }
                                }
                                if filtered.contains(where: { model.unreadReviewIDs.contains($0.review.id) }) {
                                    Button("Mark All as Read", systemImage: "checkmark.circle") {
                                        Task { await markAllRead() }
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
                    ReviewFilterView(filter: $filter, reviews: reviews)
                }
            }
        }
        .navigationTitle("Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: CustomerReview.self) { review in
            ReviewDetailView(model: model, review: review)
        }
        .onChange(of: model.dashboards.map(\.id), initial: true) { _, ids in
            if let selectedReviewAppID, !ids.contains(selectedReviewAppID) {
                self.selectedReviewAppID = nil
            }
        }
        .task(id: ReviewPreparationTaskID(key: reviewPreparationKey, isActive: isActive)) {
            guard isActive else { return }
            let key = reviewPreparationKey
            isPreparingReviews = true
            let entries = await ReviewListPreparer.shared.prepare(
                dashboards: model.dashboards,
                selectedAppID: selectedReviewAppID,
                filter: filter
            )
            guard !Task.isCancelled else {
                if reviewPreparationKey == key { isPreparingReviews = false }
                return
            }
            preparedEntries = entries
            preparedKey = key
            isPreparingReviews = false
        }
    }

    private var scopedDashboards: [AppDashboard] {
        guard let selectedReviewAppID else { return model.dashboards }
        return model.dashboards.filter { $0.id == selectedReviewAppID }
    }

    private var reviewPreparationKey: ReviewPreparationKey {
        ReviewPreparationKey(
            selectedAppID: selectedReviewAppID,
            filter: filter,
            dashboards: model.dashboards.map {
                DashboardReviewVersion(
                    id: $0.id,
                    fetchedAt: $0.fetchedAt,
                    reviewsCount: $0.reviews.count,
                    nextReviewsPage: $0.nextReviewsPage?.absoluteString
                )
            }
        )
    }

    private var hasMoreReviews: Bool {
        scopedDashboards.contains { $0.nextReviewsPage != nil }
    }

    private func loadMoreReviews() {
        Task {
            for dashboard in scopedDashboards where dashboard.nextReviewsPage != nil {
                await model.loadMoreReviews(appID: dashboard.id)
            }
        }
    }

    private func markAllRead() async {
        for dashboard in scopedDashboards {
            await model.markAllRead(in: dashboard)
        }
    }
}

private struct ReviewListEntry: Identifiable, Sendable {
    let review: CustomerReview
    let appName: String

    var id: String { review.id }
}

private struct DashboardReviewVersion: Equatable, Sendable {
    let id: String
    let fetchedAt: Date
    let reviewsCount: Int
    let nextReviewsPage: String?
}

private struct ReviewPreparationKey: Equatable, Sendable {
    let selectedAppID: String?
    let filter: ReviewFilter
    let dashboards: [DashboardReviewVersion]
}

private struct ReviewPreparationTaskID: Equatable, Sendable {
    let key: ReviewPreparationKey
    let isActive: Bool
}

private actor ReviewListPreparer {
    static let shared = ReviewListPreparer()

    func prepare(
        dashboards: [AppDashboard],
        selectedAppID: String?,
        filter: ReviewFilter
    ) -> [ReviewListEntry] {
        let scoped = if let selectedAppID {
            dashboards.filter { $0.id == selectedAppID }
        } else {
            dashboards
        }

        var entriesByID: [String: ReviewListEntry] = [:]
        for dashboard in scoped {
            for review in dashboard.reviews {
                entriesByID[review.id] = ReviewListEntry(review: review, appName: dashboard.app.name)
            }
        }

        return filter
            .apply(to: entriesByID.values.map(\.review))
            .compactMap { entriesByID[$0.id] }
    }
}

private struct ReviewRow: View {
    let review: CustomerReview
    let appName: String?
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
                if let appName {
                    Text(appName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
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
