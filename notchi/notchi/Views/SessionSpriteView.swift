import SwiftUI

struct SessionSpriteView: View {
    let state: NotchiState
    let isSelected: Bool
    let onTap: () -> Void

    @State private var bobOffset: CGFloat = 0

    var body: some View {
        Button(action: onTap) {
            SpriteSheetView(
                spriteSheet: state.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true
            )
            .frame(width: 30, height: 30)
            .opacity(isSelected ? 1.0 : 0.5)
            .offset(y: bobOffset)
        }
        .buttonStyle(.plain)
        .onAppear {
            startBobAnimationIfNeeded()
        }
        .onChange(of: state) {
            bobOffset = 0
            startBobAnimationIfNeeded()
        }
    }

    private func startBobAnimationIfNeeded() {
        let amplitude = isSelected ? state.bobAmplitude : state.bobAmplitude * 0.67
        guard amplitude > 0 else { return }
        withAnimation(.easeInOut(duration: state.bobDuration).repeatForever(autoreverses: true)) {
            bobOffset = amplitude
        }
    }
}
