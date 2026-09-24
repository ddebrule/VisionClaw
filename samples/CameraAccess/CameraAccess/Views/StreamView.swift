/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var wearablesVM: WearablesViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel

  // Glasses-problem announcements wait until the problem has lasted a moment,
  // so a brief Bluetooth gap is not read out; "back" follows only an announced problem.
  @State private var pendingGlassesAnnouncement: Task<Void, Never>?
  @State private var announcedGlassesProblem = false
  // Scout reconnects happen routinely (the server hands over about every 10
  // minutes); only announce one that is still going after a few seconds.
  @State private var pendingScoutAnnouncement: Task<Void, Never>?
  @State private var announcedScoutReconnect = false

  var body: some View {
    ZStack {
      Color.black.edgesIgnoringSafeArea(.all)

      if webrtcVM.isActive && webrtcVM.connectionState == .connected {
        PiPVideoView(
          localFrame: viewModel.currentVideoFrame,
          remoteVideoTrack: webrtcVM.remoteVideoTrack,
          hasRemoteVideo: webrtcVM.hasRemoteVideo
        )
      } else if viewModel.streamingMode == .iPhone, let session = viewModel.iPhoneCaptureSession {
        // Straight off the capture session: hardware-composited at sensor
        // resolution, rather than a converted frame stretched to fit.
        IPhoneCameraPreviewView(session: session)
          .ignoresSafeArea()
          .gesture(
            MagnifyGesture()
              .onChanged { value in viewModel.updateIPhoneZoom(scale: value.magnification) }
              .onEnded { _ in viewModel.beginIPhoneZoomGesture() }
          )
          .onAppear { viewModel.beginIPhoneZoomGesture() }
          .overlay(alignment: .topTrailing) {
            // Only while zoomed: at 1x the label is noise on top of the scene.
            if viewModel.iPhoneZoom > 1.05 {
              Text(String(format: "%.1f×", viewModel.iPhoneZoom))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.top, 60)
                .padding(.trailing, 16)
                .accessibilityLabel(String(format: "Zoom %.1f times", viewModel.iPhoneZoom))
            }
          }
          .accessibilityLabel("Camera preview. Pinch to zoom.")
      } else if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .accessibilityHidden(true)
        }
        .edgesIgnoringSafeArea(.all)
      } else if viewModel.streamingMode == .iPhone {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.white)
      }

      if geminiVM.isGeminiActive {
        VStack {
          GeminiStatusBar(geminiVM: geminiVM)
          Spacer()
          VStack(spacing: 8) {
            if !geminiVM.userTranscript.isEmpty || !geminiVM.aiTranscript.isEmpty {
              TranscriptView(userText: geminiVM.userTranscript, aiText: geminiVM.aiTranscript)
            }
            if geminiVM.isModelSpeaking {
              HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                  .foregroundColor(.white)
                  .font(.system(size: 14))
                SpeakingIndicator()
              }
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(Color.black.opacity(0.5))
              .cornerRadius(20)
            }
            if geminiVM.isSendingScoutReport {
              HStack(spacing: 8) {
                ProgressView()
                  .progressViewStyle(CircularProgressViewStyle(tint: .white))
                  .scaleEffect(0.8)
                Text("Sending scout report to Setup_IQ...")
                  .foregroundColor(.white)
                  .font(.system(size: 13))
              }
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(Color.black.opacity(0.6))
              .cornerRadius(20)
            }
          }
          .padding(.bottom, 80)
        }
        .padding(.all, 24)
      }

      if webrtcVM.isActive {
        VStack {
          WebRTCStatusBar(webrtcVM: webrtcVM)
          Spacer()
        }
        .padding(.all, 24)
      }

      if viewModel.streamingMode == .glasses, viewModel.glassesStatus != .live {
        GlassesStatusPlaceholder(
          status: viewModel.glassesStatus,
          isReconnecting: viewModel.isReconnectingGlasses)
      }

      VStack {
        Spacer()
        ControlsView(viewModel: viewModel, geminiVM: geminiVM, webrtcVM: webrtcVM)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      pendingGlassesAnnouncement?.cancel()
      pendingScoutAnnouncement?.cancel()
      Task {
        if viewModel.streamingStatus != .stopped { await viewModel.stopSession() }
        if geminiVM.isGeminiActive { geminiVM.stopSession() }
        if webrtcVM.isActive { webrtcVM.stopSession() }
      }
    }
    .onChange(of: viewModel.glassesStatus) { _, newStatus in
      guard viewModel.streamingMode == .glasses else { return }
      pendingGlassesAnnouncement?.cancel()
      pendingGlassesAnnouncement = nil
      switch newStatus {
      case .putThemOn, .folded:
        pendingGlassesAnnouncement = Task { @MainActor in
          try? await Task.sleep(for: .seconds(3))
          guard !Task.isCancelled, viewModel.glassesStatus == newStatus else { return }
          let caption = GlassesStatusText.caption(for: newStatus) ?? ""
          A11y.announce("\(GlassesStatusText.title(for: newStatus)). \(caption)", assertive: true)
          announcedGlassesProblem = true
        }
      case .live:
        if announcedGlassesProblem {
          announcedGlassesProblem = false
          A11y.announce("Glasses video is back")
        }
      case .connecting:
        break
      }
    }
    .onChange(of: geminiVM.isGeminiActive) { _, isActive in
      A11y.announce(isActive ? "Race started" : "Race ended")
    }
    .onChange(of: geminiVM.isReconnecting) { _, isReconnecting in
      pendingScoutAnnouncement?.cancel()
      pendingScoutAnnouncement = nil
      if isReconnecting {
        pendingScoutAnnouncement = Task { @MainActor in
          try? await Task.sleep(for: .seconds(5))
          guard !Task.isCancelled, geminiVM.isReconnecting else { return }
          A11y.announce("Scout connection lost. Reconnecting.", assertive: true)
          announcedScoutReconnect = true
        }
      } else if announcedScoutReconnect {
        announcedScoutReconnect = false
        if geminiVM.isGeminiActive {
          A11y.announce("Scout reconnected")
        }
      }
    }
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(photo: photo, onDismiss: { viewModel.dismissPhotoPreview() })
      }
    }
    .alert("AI Assistant", isPresented: Binding(
      get: { geminiVM.errorMessage != nil },
      set: { if !$0 { geminiVM.errorMessage = nil } }
    )) {
      Button("OK") { geminiVM.errorMessage = nil }
    } message: {
      Text(geminiVM.errorMessage ?? "")
    }
    .alert("Live Stream", isPresented: Binding(
      get: { webrtcVM.errorMessage != nil },
      set: { if !$0 { webrtcVM.errorMessage = nil } }
    )) {
      Button("OK") { webrtcVM.errorMessage = nil }
    } message: {
      Text(webrtcVM.errorMessage ?? "")
    }
  }
}

struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @ObservedObject var geminiVM: GeminiSessionViewModel
  @ObservedObject var webrtcVM: WebRTCSessionViewModel
  @State private var showEndScoutConfirm = false

  var body: some View {
    HStack(spacing: 8) {
      CustomButton(title: "Stop streaming", style: .destructive, isDisabled: false) {
        Task { await viewModel.stopSession() }
      }

      if viewModel.streamingMode == .glasses {
        CircleButton(icon: "camera.fill", text: nil, label: "Capture photo") {
          viewModel.capturePhoto()
        }
        .accessibilityHint("Takes a photo through your glasses")
      }

      CircleButton(
        icon: geminiVM.isGeminiActive ? "waveform.circle.fill" : "waveform.circle",
        text: "Race"
      ) {
        Task {
          if geminiVM.isGeminiActive { geminiVM.stopSession() }
          else { await geminiVM.startSession() }
        }
      }
      .opacity(webrtcVM.isActive ? 0.4 : 1.0)
      .disabled(webrtcVM.isActive)

      if geminiVM.isGeminiActive || geminiVM.hasUnsentReport {
        CircleButton(
          icon: geminiVM.isSendingScoutReport ? "arrow.up.circle" : "flag.checkered.circle.fill",
          text: "End"
        ) {
          showEndScoutConfirm = true
        }
        .disabled(geminiVM.isSendingScoutReport)
        .confirmationDialog(
          "End Race?",
          isPresented: $showEndScoutConfirm,
          titleVisibility: .visible
        ) {
          Button("Send Report to Setup_IQ", role: .none) {
            Task { await geminiVM.endScout() }
          }
          Button("Discard report", role: .destructive) {
            geminiVM.stopSession()
            geminiVM.discardReport()
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Your field observations will be delivered to Setup_IQ at the pit table.")
        }
      }

      CircleButton(
        icon: webrtcVM.isActive
          ? "antenna.radiowaves.left.and.right.circle.fill"
          : "antenna.radiowaves.left.and.right.circle",
        text: "Live"
      ) {
        Task {
          if webrtcVM.isActive { webrtcVM.stopSession() }
          else { await webrtcVM.startSession() }
        }
      }
      .opacity(geminiVM.isGeminiActive ? 0.4 : 1.0)
      .disabled(geminiVM.isGeminiActive)
    }
  }
}

/// Centered message for a glasses stream that is not showing live video.
private struct GlassesStatusPlaceholder: View {
  let status: GlassesStatus
  let isReconnecting: Bool

  var body: some View {
    VStack(spacing: 10) {
      if status == .connecting {
        ProgressView()
          .scaleEffect(1.5)
          .tint(.white)
      } else {
        Image(systemName: "eyeglasses")
          .font(.system(size: 40))
          .foregroundStyle(.white)
          .accessibilityHidden(true)
      }
      Text(GlassesStatusText.title(for: status))
        .font(.headline)
        .foregroundStyle(.white)
      if let caption = GlassesStatusText.caption(for: status) {
        Text(caption)
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.8))
          .multilineTextAlignment(.center)
      }
      if isReconnecting, status != .connecting {
        Text("Reconnecting automatically…")
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .padding(24)
    .frame(maxWidth: 320)
    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    .accessibilityElement(children: .combine)
  }
}

/// Wording for the glasses placeholder and its announcements.
enum GlassesStatusText {
  static func title(for status: GlassesStatus) -> String {
    switch status {
    case .live: return ""
    case .connecting: return "Connecting to your glasses"
    case .putThemOn: return "Put on your glasses"
    case .folded: return "Glasses folded"
    }
  }

  static func caption(for status: GlassesStatus) -> String? {
    switch status {
    case .live, .connecting: return nil
    case .putThemOn:
      return "Open the hinges and put them on. The camera turns off when they're folded or off your face."
    case .folded: return "Unfold them to start streaming."
    }
  }
}
