import SwiftUI

/// Animated shimmer placeholder — used for photo thumbnails while loading.
struct ShimmerView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width * 2.5
            Rectangle()
                // Dark-mode shimmer: base #222 → visible highlight #3A3A3A → base
                // surfaceElevated (#1A1A2E) is darker than surface (#222222), so
                // we use explicit grays to guarantee a visible sweep.
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(white: 0.13), location: 0),
                            .init(color: Color(white: 0.24), location: 0.4),
                            .init(color: Color(white: 0.13), location: 0.8),
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
