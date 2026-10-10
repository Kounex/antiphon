import AntiphonDesign
import SwiftUI

/// The outcome in numbers, then the follow-ups in priority order.
struct SyncedView: View {
    let model: SyncFlowModel
    let result: SyncResult
    /// The next queued playlist, when several were picked.
    let nextName: String?
    let onReview: () -> Void
    var onConflicts: () -> Void = {}
    let onNext: () -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s5) {
                Image(systemName: result.status == .failed ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(result.status == .failed ? Color.statusFailed : Color.statusSynced)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityHidden(true)
                VStack(spacing: Space.s2) {
                    Text(title).font(.antiphonTitle1).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                    Text(summary).font(.body).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                }
                StatTiles([
                    StatTile(result.tracksAdded, "Added", tint: .statusSynced),
                    StatTile(model.reviewTitles.count, "Your call", tint: .statusReview),
                    StatTile(model.unavailableTitles.count, "Unavailable")
                ])
                if !model.reviewTitles.isEmpty {
                    Banner(tone: .review, symbol: "questionmark.circle.fill",
                           title: "\(PlanCopy.count(model.reviewTitles.count, "close match", "close matches"))",
                           message: "\(Self.list(model.reviewTitles)) \(model.reviewTitles.count == 1 ? "has" : "have") a different version on the other side.")
                }
                if model.conflictCount > 0 {
                    Banner(tone: .review, symbol: "questionmark.circle.fill",
                           title: "\(PlanCopy.count(model.conflictCount, "removal")) to decide",
                           message: "Nothing is removed until you choose.") {
                        Button("Decide", action: onConflicts)
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            .tint(.statusReview).foregroundStyle(Color.canvas)
                    }
                }
                if !model.unavailableTitles.isEmpty {
                    Banner(tone: .neutral, symbol: "circle.slash",
                           title: model.unavailableTitles.count == 1 ? model.unavailableTitles[0] : "\(model.unavailableTitles.count) tracks unavailable",
                           message: "Not on the other side yet. Antiphon tries again on later syncs.")
                }
            }
            .padding(Space.s4)
            .padding(.top, Space.s6)
        }
        .background(alignment: .top) {
            CoverPlaceholder(seed: model.seam?.name ?? "")
                .frame(height: 360).opacity(0.45)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
                .accessibilityHidden(true)
        }
        .background(Color.canvas)
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: Space.s2) {
                VStack(spacing: Space.s2) {
                    if !model.reviewTitles.isEmpty {
                        Button("Review \(PlanCopy.count(model.reviewTitles.count, "track"))", action: onReview)
                            .buttonSizing(.flexible).glassButton(.primary)
                    }
                    if let nextName {
                        Button("Next: \(nextName)", action: onNext)
                            .buttonSizing(.flexible).glassButton(model.reviewTitles.isEmpty ? .primary : .secondary)
                    } else {
                        Button("Done", action: onDone)
                            .buttonSizing(.flexible).glassButton(model.reviewTitles.isEmpty ? .primary : .secondary)
                    }
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s2)
        }
        .navigationBarBackButtonHidden()
    }

    private var title: String {
        result.status == .failed ? "The sync stopped" : NewSeamCopy.doneTitle(name: model.seam?.name ?? "The seam")
    }

    private var summary: String {
        if result.status == .failed {
            return result.message ?? "Something went wrong. Nothing that was added is lost; the next sync picks up the rest."
        }
        let seam = model.seam
        return NewSeamCopy.doneBody(added: result.tracksAdded, monitoring: seam?.isMonitored == true && seam?.isPaused == false,
                                    interval: seam?.monitorIntervalMinutes ?? 0)
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
