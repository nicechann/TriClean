//
//  OnboardingView.swift
//  TriClean
//

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var step = 0
    @State private var isGoingForward = true

    private struct Step {
        let icon: String
        let iconColor: Color
        let titleKey: String
        let descKey: String
    }

    private let steps: [Step] = [
        Step(icon: "sparkles.rectangle.stack",
             iconColor: .accentColor,
             titleKey: "onboarding.welcome.title",
             descKey:  "onboarding.welcome.desc"),
        Step(icon: "internaldrive",
             iconColor: Color(red: 0.2, green: 0.5, blue: 1.0),
             titleKey: "onboarding.storage.title",
             descKey:  "onboarding.storage.desc"),
        Step(icon: "memorychip",
             iconColor: Color(red: 0.3, green: 0.8, blue: 0.4),
             titleKey: "onboarding.memory.title",
             descKey:  "onboarding.memory.desc"),
        Step(icon: "app.dashed",
             iconColor: Color(red: 1.0, green: 0.6, blue: 0.2),
             titleKey: "onboarding.apps.title",
             descKey:  "onboarding.apps.desc"),
    ]

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - Content area
            ZStack {
                ForEach(steps.indices, id: \.self) { i in
                    if i == step {
                        stepContent(steps[i])
                            .transition(
                                isGoingForward
                                ? .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal:   .move(edge: .leading).combined(with: .opacity)
                                  )
                                : .asymmetric(
                                    insertion: .move(edge: .leading).combined(with: .opacity),
                                    removal:   .move(edge: .trailing).combined(with: .opacity)
                                  )
                            )
                    }
                }
            }
            .frame(height: 300)
            .clipped()

            // MARK: - Dot indicator
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 20 : 8, height: 8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
                }
            }
            .padding(.top, 16)

            // MARK: - Navigation buttons
            HStack {
                if step > 0 {
                    Button("onboarding.btn.back".localized) {
                        isGoingForward = false
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            step -= 1
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 60, height: 32)
                }

                Spacer()

                if step < steps.count - 1 {
                    Button("onboarding.btn.next".localized) {
                        isGoingForward = true
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            step += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)
                } else {
                    Button("onboarding.btn.start".localized) {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .frame(width: 480)
    }

    // MARK: - Step content builder
    private func stepContent(_ s: Step) -> some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(s.iconColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: s.icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(s.iconColor)
            }

            Text(s.titleKey.localized)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(s.descKey.localized)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
