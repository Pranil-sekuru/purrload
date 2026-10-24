// Notch mode: the bar lives in the MacBook notch and drops down on hover; the kitty sits in its right wing.
import SwiftUI
import AppKit

/// Sizes shared by the view (drawing) and the app delegate (click areas, window size).
struct NotchMetrics {
    let notchWidth: CGFloat
    let height: CGFloat                       // notch / menu bar height
    static let wing: CGFloat = 64             // black area each side of the notch when closed
    static let flashWing: CGFloat = 124       // wider while announcing a finished download
    static let openWidth: CGFloat = 400
    static let shoulder: CGFloat = 8          // concave curve where the shape meets the menu bar
    static let kittySize = CGSize(width: 38, height: 32)   // the small kitty in the right wing
    static let kittyScale: CGFloat = 0.52

    func closedWidth(flashing: Bool) -> CGFloat {
        notchWidth + 2 * (flashing ? Self.flashWing : Self.wing) + 2 * Self.shoulder
    }
    func width(open: Bool, flashing: Bool) -> CGFloat { open ? Self.openWidth : closedWidth(flashing: flashing) }

    /// The notched screen, if one is connected.
    static func find() -> (NSScreen, NotchMetrics)? {
        for s in NSScreen.screens where s.safeAreaInsets.top > 0 {
            guard let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { continue }
            return (s, NotchMetrics(notchWidth: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top))
        }
        return nil
    }
}

/// Black shape with concave top shoulders (blends into the menu bar) and rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let t = NotchMetrics.shoulder, b = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: Model
    let metrics: NotchMetrics
    var kittyAt: Date? = nil
    var measuring: Bool? = nil        // off-screen copies: true = open, false = closed

    var open: Bool { measuring ?? model.expanded }
    var flashing: Bool { model.wide }
    var spring: Animation { .spring(response: 0.38, dampingFraction: 0.82) }

    var body: some View {
        shape
            .frame(maxWidth: measuring != nil ? nil : .infinity, maxHeight: measuring != nil ? nil : .infinity, alignment: .top)
    }

    var shape: some View {
        VStack(alignment: .leading, spacing: 0) {
            wings
            if open { details.transition(.opacity) }
        }
        .padding(.horizontal, NotchMetrics.shoulder)
        .frame(width: metrics.width(open: open, flashing: flashing), alignment: .top)
        .background(NotchShape(bottomRadius: open ? 22 : 11).fill(Color.black))
        .contentShape(Rectangle())      // hover opens/closes it (see AppDelegate.handleHover); right-click for options
        .modifier(LinkDropTarget(model: model, enabled: measuring == nil && kittyAt == nil))
        .contextMenu {
            Button(model.status?.paused == true ? "Resume downloads" : "Pause downloads") { model.togglePause() }
            Button("Open folder") { model.openFolder() }
            Button(model.watchClipboard ? "✓ Offer copied download links" : "Offer copied download links") {
                model.watchClipboard.toggle()
            }
            Button("Move to corner") { model.switchMode?() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    // The strip either side of the notch, inside the menu bar.
    var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Gem(active: model.isActive)
                if !open { Text(leftText).lineLimit(1) }     // open: the header below carries the numbers
            }
            Spacer(minLength: metrics.notchWidth)
            HStack(spacing: 4) {
                if flashing && !open { Text(rightText).lineLimit(1).foregroundStyle(rightColor) }
                KittyView(model: model, frozenAt: measuring != nil ? Date() : kittyAt)
                    .scaleEffect(NotchMetrics.kittyScale)
                    .frame(width: NotchMetrics.kittySize.width, height: NotchMetrics.kittySize.height)
                    .offset(y: 1)
            }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(Color.white)
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: metrics.height)
        .overlay(alignment: .bottom) {
            if !open && !model.jobs.isEmpty {
                Line(fraction: model.overall, height: 2.5)      // stops short of the kitty
                    .padding(.leading, 12).padding(.trailing, 12 + NotchMetrics.kittySize.width).padding(.bottom, 3)
            }
        }
    }

    var leftText: String {
        if model.dropTarget { return "Drop to download" }
        if let f = model.flashTitle { return f }
        if let o = model.offer { return "Download \(Links.displayName(o).prefix(18))?" }
        if !model.guardRunning { return "off" }
        return model.jobs.isEmpty ? "✦" : "\(Int(model.overall * 100))%"
    }

    var rightText: String {
        if model.dropTarget { return "↓" }
        if let f = model.flashTitle { return f.hasPrefix("⚠") ? "check it" : f.hasPrefix("Added") || f.hasPrefix("Queued") ? "↓" : "ready ✓" }
        return model.offer != nil ? "hover ↓" : ""
    }
    var rightColor: Color { model.flashTitle?.hasPrefix("⚠") == true ? Color.gem : model.offer != nil ? Color.lilac : Color.mint }

    var details: some View {
        VStack(alignment: .leading, spacing: 13) {
            OfferRow(model: model)
            HStack {
                Text(headline).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer()
                Text("\(Int(model.overall * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.lilac)
            }
            Line(fraction: model.overall).padding(.top, -6)
            if !model.series.isEmpty {
                Text(model.series).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.soft)
                    .textCase(.uppercase).tracking(0.6).padding(.bottom, -5)
            }
            ForEach(model.jobs) { Row(job: $0, title: model.rowTitle($0)) }
            HStack(spacing: 16) {
                Button(model.status?.paused == true ? "Resume" : "Pause") { model.togglePause() }
                Button("Open folder") { model.openFolder() }
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.lilac)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 16)
    }

    var headline: String {
        if model.jobs.isEmpty && model.guardRunning { return "Drop a link here to download" }
        if !model.guardRunning { return "Engine isn't running" }
        if model.status?.paused == true { return "Paused" }
        let n = model.activeJobs.count
        if n == 0 { return model.jobs.isEmpty ? "All quiet ✦" : "All done ✦" }
        return "\(n) downloading · \(mbs(model.status?.speed ?? 0))"
    }
}
