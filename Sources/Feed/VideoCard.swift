//
//  VideoCard.swift
//  SolaPraise
//
//  Shared card views for both feeds.
//
//  Thumbnails use a fixed-aspect container with the image as an OVERLAY, then
//  clip. Putting `.aspectRatio(_, contentMode: .fill)` on the image itself
//  makes the view size itself to fill — it grows past the column width and
//  spills over neighbouring content instead of being cropped.
//

import SwiftUI

/// 16:9 thumbnail that always fits its column and crops the overflow.
private struct ThumbnailBox<Overlay: View>: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    @ViewBuilder var overlay: Overlay

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    default:
                        Rectangle().fill(.quaternary)
                    }
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay { overlay }
    }
}

private struct DurationBadge: View {
    let label: String
    var font: Font = .caption2

    var body: some View {
        Text(label)
            .font(font.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

// MARK: - Grid card

struct VideoCard: View {
    let video: CachedVideo
    /// True when a chord chart has already been made from this video.
    var hasSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailBox(url: video.thumbnailURL) {
                ZStack {
                    if let label = video.durationLabel {
                        DurationBadge(label: label)
                    }
                    if hasSheet {
                        // Marked on the card, because otherwise the only way
                        // to know a song had been worked out already was to
                        // open it and work it out again.
                        Image(systemName: "music.quarternote.3")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.accentColor, in: Circle())
                            .padding(5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                    }
                }
            }

            Text(video.title)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The actual date, not only "3개월 전". Which release a worship
            // upload is matters, and the title very often does not say.
            HStack(spacing: 4) {
                if let published = video.publishedAt {
                    Text(published, format: .dateTime.year().month().day())
                    Text(published, format: .relative(presentation: .named))
                        .foregroundStyle(.tertiary)
                }
                if let views = video.viewCount {
                    Text("·")
                    Text(WatchScreen.compactCount(views)).monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Pinned hero card

/// The pinned channel's newest upload — today's QT, sized so it is obviously
/// the thing you came for.
struct PinnedVideoCard: View {
    let video: CachedVideo

    /// Capped width.
    ///
    /// Full-bleed is right on a phone, where the screen IS the card. On an
    /// iPad the same rule blew today's episode up to the width of the window —
    /// a 480pt-wide thumbnail stretched past 1000pt, upscaled and dominating a
    /// screen it was only meant to lead.
    private let maxWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailBox(url: video.thumbnailURL, cornerRadius: 12) {
                ZStack {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white, .black.opacity(0.45))

                    if let label = video.durationLabel {
                        DurationBadge(label: label, font: .caption)
                    }
                }
            }

            Text(video.title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let channel = video.channelTitle {
                    Text(channel).lineLimit(1)
                }
                if let published = video.publishedAt {
                    Text("·")
                    Text(published, format: .dateTime.year().month().day())
                    Text(published, format: .relative(presentation: .named))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - End marker

/// The screen's explicit ending. This is the signal YouTube deliberately never
/// gives you, and it is the whole reason the feed is finite.
struct FeedEndMarker: View {
    let refreshedAt: Date?
    var text: String = "That's everything"

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(.quaternary).frame(height: 1)
            }
            if let refreshedAt {
                Text("Refreshed \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 40)
    }
}

// MARK: - Shared metadata row

/// Thumbnail + title + channel + date · length · views.
///
/// Every screen that names a video shows the same three facts, because
/// comparing uploads of one worship song is routine and the title alone never
/// distinguishes a studio cut from a live set. Defined once so the add-sheet,
/// the psalm lookup and the player queue cannot drift apart.
struct VideoMetaRow: View {
    let video: PlayableVideo
    var thumbnailWidth: CGFloat = 88

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: video.thumbnailURL,
                      width: thumbnailWidth,
                      height: thumbnailWidth * 9 / 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.footnote)
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)

                if let channel = video.channelTitle {
                    Text(channel).font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    if let published = video.publishedAt {
                        Text(published, format: .dateTime.year().month().day())
                    }
                    if let secs = video.durationSeconds {
                        Text("·")
                        Text(ISO8601Duration.format(secs)).monospacedDigit()
                    }
                    if let views = video.viewCount {
                        Text("·")
                        Text("조회 \(WatchScreen.compactCount(views))").monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Pinned set bar

/// A long-form set at the top of a feed.
///
/// Rendered as a bar rather than a card because it is not this week's upload
/// competing with the others — it is a thing you put on and leave on, and a
/// three-hour runtime is the detail that identifies it.
struct PinnedSetBar: View {
    let video: CachedVideo

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: video.thumbnailURL, width: 72, height: 41)

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.footnote)
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)
                HStack(spacing: 5) {
                    if let channel = video.channelTitle {
                        Text(channel).lineLimit(1)
                    }
                    if let label = video.durationLabel {
                        Text("·")
                        Text(label).monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
