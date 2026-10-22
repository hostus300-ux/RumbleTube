import SwiftUI

extension AppTab {
    /// Tab glyph: the Rumble-style outline from the asset catalog, or an SF Symbol for Me.
    var image: Image {
        if let asset { return Image(asset).renderingMode(.template) }
        return Image(systemName: icon)
    }
}
