import SwiftUI

/// Animated shimmer placeholder — used for photo thumbnails while loading.
struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * 2.5
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: NotoTheme.Colors.surface, location: 0),
                            .init(color: NotoTheme.Colors.surfaceElevated, location: 0.4),
                            .init(color: NotoTheme.Colors.surface, location: 0.8),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width)
                .offset(x: phase * width)
        }
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}
