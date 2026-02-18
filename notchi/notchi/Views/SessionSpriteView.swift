import SwiftUI

struct SessionSpriteView: View {
    let state: NotchiState
    let isSelected: Bool

    private var bobAmplitude: CGFloat {
        guard state.bobAmplitude > 0 else { return 0 }
        return isSelected ? state.bobAmplitude : state.bobAmplitude * 0.67
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: bobAmplitude == 0)) { timeline in
            SpriteSheetView(
                spriteSheet: state.spriteSheetName,
                frameCount: state.frameCount,
                columns: state.columns,
                fps: state.animationFPS,
                isAnimating: true
            )
            .frame(width: 30, height: 30)
            .offset(y: bobOffset(at: timeline.date, duration: state.bobDuration, amplitude: bobAmplitude))
        }
    }
}
