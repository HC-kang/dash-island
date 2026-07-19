import SwiftUI

struct IslandRootView: View {
    var body: some View {
        Text("Dash Island")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.black))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
