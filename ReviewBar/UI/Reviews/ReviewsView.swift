import SwiftUI

struct ReviewsView: View {
    let model: AppModel
    let dashboard: AppDashboard?
    @Binding var selectedAppID: String?
    @State private var filter = ReviewFilter()
    @State private var showingFilters = false

    var body: some View {
        Group {
            if let dashboard {
                let filtered = filter.apply(to: dashboard.reviews)
                List {
                    if let issue = dashboard.sectionIssues[.reviews], dashboard.reviews.isEmpty {
                        Section {
                            SectionIssueView(issue: issue) { Task { await model.refresh() } }
                        }
                    } else if filtered.isEmpty {
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
                                .onAppear {
                                    guard review.id == filtered.last?.id,
                                          dashboard.nextReviewsPage != nil else { return }
                                    Task { await model.loadMoreReviews(appID: dashboard.id) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StarRatingView(rating: review.rating)
                if isUnread {
                    Text("New")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                }
                Spacer()
                Text(DisplayFormatters.relative(review.createdDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(review.title)
                .font(.headline)
                .lineLimit(2)
            Text(review.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 6) {
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            if review.hasDeveloperResponse {
                Label("Developer responded", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "Unread" : "Read")
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

                if review.hasDeveloperResponse {
                    Label("A developer response is published", systemImage: "arrowshape.turn.up.left.fill")
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
                    Button("Clear Filters", role: .destructive) { filter = ReviewFilter() }
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

