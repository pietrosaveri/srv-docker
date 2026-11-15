import SwiftUI

/// One of the two payment ticks. Tapping the ticked one clears it.
struct PaymentTickRow: View {
    let payment: Payment
    @Binding var selection: Payment?

    var body: some View {
        let on = selection == payment
        Button {
            withAnimation(.snappy(duration: 0.2)) { selection = on ? nil : payment }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(on ? payment.color : Theme.stone)
                    .contentTransition(.symbolEffect(.replace))
                Text(payment.label)
                    .font(.system(size: 16, weight: on ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The two ticks in a card, for detail pages: changes save straight away.
struct PaymentCard: View {
    @Binding var selection: Payment?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Payment.allCases.enumerated()), id: \.element) { i, p in
                if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 50) }
                PaymentTickRow(payment: p, selection: $selection)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
    }
}

/// Small icon for timeline rows.
struct PaymentIcon: View {
    let payment: Payment?

    var body: some View {
        if let payment {
            Image(systemName: payment.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(payment.color)
                .accessibilityLabel(payment.short)
        }
    }
}
