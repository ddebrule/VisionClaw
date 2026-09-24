/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// Accessibility.swift
//
// Shared helpers for the app's accessibility layer. `A11y.announce` posts the
// state changes VoiceOver would not otherwise speak (session start and end,
// reconnecting, glasses status); `a11yLabel` names icon-only controls that
// would otherwise be read as their SF Symbol.
//

import SwiftUI

enum A11y {
  /// Announces a status change. Use `assertive` for states that should
  /// interrupt -- a dropped connection -- and leave it off for routine
  /// updates so they queue behind whatever VoiceOver is already speaking.
  static func announce(_ message: String, assertive: Bool = false) {
    guard !message.isEmpty else { return }
    var announcement = AttributedString(message)
    announcement.accessibilitySpeechAnnouncementPriority = assertive ? .high : .default
    AccessibilityNotification.Announcement(announcement).post()
  }
}

/// Applies an accessibility label only when one is supplied, so a component
/// that draws a visible `Text` keeps its implicit label while its icon-only
/// variant can still name itself.
struct OptionalAccessibilityLabel: ViewModifier {
  private let label: String?

  init(_ label: String?) {
    self.label = label
  }

  func body(content: Content) -> some View {
    if let label, !label.isEmpty {
      content.accessibilityLabel(Text(label))
    } else {
      content
    }
  }
}

extension View {
  func a11yLabel(_ label: String?) -> some View {
    modifier(OptionalAccessibilityLabel(label))
  }
}
