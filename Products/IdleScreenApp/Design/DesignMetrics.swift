import SwiftUI

/// Spacing and radius constants shared by the Design components. Blueprint: corners are nearly square, the grid is 16 pt.
enum DesignMetrics {
  static let pageSideMargin: CGFloat = 32
  static let pageTopMargin: CGFloat = 40
  static let pageBottomMargin: CGFloat = 24
  static let sectionSpacing: CGFloat = 20
  static let rowHorizontalPadding: CGFloat = 14
  static let rowVerticalPadding: CGFloat = 9
  static let rowMinHeight: CGFloat = 48
  static let cardRadius: CGFloat = 3
  static let controlRadius: CGFloat = 2
  static let controlHeight: CGFloat = 28
  static let segmentRadius: CGFloat = 1.5
  /// Dot grid pitch on the page ground.
  static let gridPitch: CGFloat = 16
  /// Length of the corner ticks on cards.
  static let tickLength: CGFloat = 7
  /// The page content reads at a fixed measure on wide windows.
  static let pageMaxWidth: CGFloat = 880
}
