import ScreenSaver
import AppKit
import Darwin

final class PlexScreensaverView: ScreenSaverView {
    private let viewModel = ScreensaverViewModel()
    private var configController: ConfigSheetController?
    private var frameCount: Int = 0

    struct Particle {
        var x: CGFloat
        var y: CGFloat
        var size: CGFloat
        var baseOpacity: Float
        var speed: CGFloat       // vertical speed multiplier
        var fades: Bool          // whether this particle fades as it rises
        var startY: CGFloat      // Y position when spawned (for fade calc)
    }
    private var particles: [Particle] = []
    private var metalRenderer: MetalBackgroundRenderer?

    // System monitoring
    private var currentCPU: Double = 0
    private var currentRAM: Double = 0
    private var prevCPUTicks: (user: Int64, system: Int64, idle: Int64, nice: Int64)?
    private var bandwidthHistory: [Double] = []
    private let maxBWHistory = 60

    // Card fade tracking
    private var cardOpacities: [String: CGFloat] = [:]
    private var lastStreamIDs: Set<String> = []

    // Poster color cache
    private var posterColors: [String: NSColor] = [:]

    // Cached formatters (DateFormatter is expensive — never allocate per-frame)
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"; return f
    }()
    private static let ampmFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "a"; return f
    }()
    private static let dateStringFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()

    // Cached color space (avoid per-frame allocation)
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    // Widget-matching colors
    private let plexGold   = NSColor(red: 229/255, green: 160/255, blue: 13/255, alpha: 1)
    private let plexCyan   = NSColor(red: 90/255,  green: 200/255, blue: 250/255, alpha: 1)
    private let plexPurple = NSColor(red: 191/255, green: 90/255,  blue: 242/255, alpha: 1)

    // Media-type fallback card colors
    private let movieColor = NSColor(red: 0.18, green: 0.25, blue: 0.55, alpha: 1)
    private let tvColor    = NSColor(red: 0.12, green: 0.40, blue: 0.35, alpha: 1)
    private let musicColor = NSColor(red: 0.40, green: 0.18, blue: 0.52, alpha: 1)

    // MARK: - Defaults
    private static let suiteID = "com.jasonbarton.PlexScreensaver"
    static var serverUrl: String {
        get { UserDefaults(suiteName: suiteID)?.string(forKey: "serverUrl") ?? "" }
        set { UserDefaults(suiteName: suiteID)?.set(newValue, forKey: "serverUrl") }
    }
    static var token: String {
        get { UserDefaults(suiteName: suiteID)?.string(forKey: "token") ?? "" }
        set { UserDefaults(suiteName: suiteID)?.set(newValue, forKey: "token") }
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        metalRenderer = MetalBackgroundRenderer()
        initParticles()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        metalRenderer = MetalBackgroundRenderer()
        initParticles()
    }

    private func initParticles() {
        let w = max(bounds.width, 400)
        let h = max(bounds.height, 400)
        for _ in 0..<125 {
            // Speed distribution: ~70% slow, ~20% medium, ~10% fast
            let roll = Float.random(in: 0...1)
            let depth: CGFloat
            if roll < 0.70 {
                depth = CGFloat.random(in: 0...0.25)      // slow drifters
            } else if roll < 0.90 {
                depth = CGFloat.random(in: 0.3...0.55)     // medium
            } else {
                depth = CGFloat.random(in: 0.7...1.0)      // fast
            }
            let size = 1.0 + depth * 4.0
            let speed = 0.1 + pow(depth, 1.5) * 4.0
            let opacity = Float(0.06 + depth * 0.30)
            let startY = CGFloat.random(in: 0...h)
            let fades = Float.random(in: 0...1) < 0.40
            particles.append(Particle(
                x: CGFloat.random(in: 0...w),
                y: startY,
                size: size,
                baseOpacity: opacity,
                speed: speed,
                fades: fades,
                startY: startY
            ))
        }
    }

    override func startAnimation() {
        super.startAnimation()
        viewModel.startPolling()
    }

    override func stopAnimation() {
        viewModel.stopPolling()
        // Release caches to free RAM when screensaver stops
        posterColors.removeAll()
        cardOpacities.removeAll()
        bandwidthHistory.removeAll()
        super.stopAnimation()
    }

    override func animateOneFrame() {
        frameCount += 1
        let h = bounds.height
        let w = bounds.width
        for i in particles.indices {
            particles[i].y += particles[i].speed
            particles[i].x += CGFloat.random(in: -0.2...0.2) * particles[i].speed
            if particles[i].y > h + 20 {
                particles[i].y = -20
                particles[i].x = CGFloat.random(in: 0...w)
                particles[i].startY = -20
            }
        }
        if frameCount % 30 == 0 {
            updateSystemStats()
            bandwidthHistory.append(viewModel.state.totalBandwidthMbps)
            if bandwidthHistory.count > maxBWHistory {
                bandwidthHistory.removeFirst()
            }
        }
        updateCardFades()
        setNeedsDisplay(bounds)
    }

    // MARK: - Card Fade Transitions

    private func updateCardFades() {
        let currentIDs = Set(viewModel.state.streams.map(\.id))

        for id in currentIDs {
            let current = cardOpacities[id] ?? 0
            cardOpacities[id] = min(current + 0.04, 1.0)
        }

        for id in lastStreamIDs.subtracting(currentIDs) {
            let current = cardOpacities[id] ?? 1
            let newVal = current - 0.04
            if newVal <= 0 {
                cardOpacities.removeValue(forKey: id)
            } else {
                cardOpacities[id] = newVal
            }
        }

        lastStreamIDs = currentIDs
    }

    // MARK: - Poster Color Sampling

    private func averageColor(of image: NSImage) -> NSColor {
        let size = NSSize(width: 1, height: 1)
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32
        ) else { return movieColor }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let color = bitmapRep.colorAt(x: 0, y: 0) else { return movieColor }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        let satBoost: CGFloat = 1.4
        let brightness: CGFloat = 0.35
        let gray = r * 0.299 + g * 0.587 + b * 0.114
        let sr = gray + (r - gray) * satBoost
        let sg = gray + (g - gray) * satBoost
        let sb = gray + (b - gray) * satBoost

        return NSColor(red: sr * brightness, green: sg * brightness, blue: sb * brightness, alpha: 1)
    }

    private func cardAccentColor(for stream: SSStream) -> NSColor {
        if let path = stream.thumbPath, let cached = posterColors[path] {
            return cached
        }
        if let path = stream.thumbPath, let img = viewModel.posterImages[path] {
            let sampled = averageColor(of: img)
            posterColors[path] = sampled
            return sampled
        }
        switch stream.mediaType {
        case .movie: return movieColor
        case .tv:    return tvColor
        case .music: return musicColor
        }
    }

    // MARK: - System Monitoring

    private func updateSystemStats() {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let cpuResult = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                            &numCPUs, &cpuInfo, &numCPUInfo)
        if cpuResult == KERN_SUCCESS, let info = cpuInfo {
            var user: Int64 = 0, system: Int64 = 0, idle: Int64 = 0, nice: Int64 = 0
            for i in 0..<Int(numCPUs) {
                let offset = Int(CPU_STATE_MAX) * i
                user   += Int64(info[offset + Int(CPU_STATE_USER)])
                system += Int64(info[offset + Int(CPU_STATE_SYSTEM)])
                idle   += Int64(info[offset + Int(CPU_STATE_IDLE)])
                nice   += Int64(info[offset + Int(CPU_STATE_NICE)])
            }
            if let prev = prevCPUTicks {
                let dUser   = Double(user - prev.user)
                let dSystem = Double(system - prev.system)
                let dIdle   = Double(idle - prev.idle)
                let dNice   = Double(nice - prev.nice)
                let total = dUser + dSystem + dIdle + dNice
                if total > 0 {
                    currentCPU = ((dUser + dSystem + dNice) / total) * 100
                }
            }
            prevCPUTicks = (user, system, idle, nice)
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ramResult = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ramResult == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let active     = Double(stats.active_count) * pageSize
            let wired      = Double(stats.wire_count) * pageSize
            let compressed = Double(stats.compressor_page_count) * pageSize
            let used = active + wired + compressed
            let total = Double(ProcessInfo.processInfo.physicalMemory)
            if total > 0 { currentRAM = (used / total) * 100 }
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width
        let h = bounds.height
        let state = viewModel.state

        // --- Background (Metal GPU-accelerated, CG fallback) ---
        let particleData: [(x: Float, y: Float, size: Float, opacity: Float)] = particles.map { p in
            let twinkle = Float(sin(Double(frameCount) * 0.05 + Double(p.x) * 0.1))
            var opacity = max(Float(0.02), p.baseOpacity + twinkle * 0.05)
            if p.fades {
                // Fade based on distance traveled from spawn point
                let traveled = abs(p.y - p.startY)
                let fadeDistance = h * 0.6  // fade over 60% of screen height
                let fadeFactor = Float(max(0, 1.0 - traveled / fadeDistance))
                opacity *= fadeFactor
            }
            return (Float(p.x), Float(p.y), Float(p.size), opacity)
        }

        if let renderer = metalRenderer,
           let bgImage = renderer.render(width: Int(w), height: Int(h),
                                          time: Float(frameCount) * 0.008,
                                          particles: particleData) {
            ctx.draw(bgImage, in: bounds)
        } else {
            // CG fallback if Metal unavailable
            ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1))
            ctx.fill(bounds)
            drawRadialGradient(ctx: ctx, w: w, h: h, frame: frameCount)
            for p in particles {
                let twinkle = Float(sin(Double(frameCount) * 0.05 + Double(p.x) * 0.1))
                var opacity = CGFloat(max(0.02, p.baseOpacity + twinkle * 0.05))
                if p.fades {
                    let traveled = abs(p.y - p.startY)
                    let fadeFactor = CGFloat(max(0, 1.0 - traveled / (h * 0.6)))
                    opacity *= fadeFactor
                }
                ctx.setFillColor(CGColor(red: 0.9, green: 0.95, blue: 1.0, alpha: opacity))
                ctx.fillEllipse(in: CGRect(x: p.x - p.size / 2, y: p.y - p.size / 2,
                                           width: p.size, height: p.size))
            }
        }

        let time = Double(frameCount) * 0.02

        // --- Clock (top-right, ghosted) ---
        drawClock(ctx: ctx, w: w, h: h)

        // --- Server name ---
        let nameY = h * 0.8575
        let nameFont = NSFont.systemFont(ofSize: 42, weight: .bold)
        let nameSize = (state.name as NSString).size(withAttributes: [.font: nameFont])
        drawCenteredText(state.name, y: nameY, dx: 0, width: w,
                         font: nameFont,
                         color: NSColor.white.withAlphaComponent(0.45))

        // --- Status dot ---
        let dotPhase = Double(frameCount) / 30.0
        let dotGlow = CGFloat(0.6 + 0.3 * sin(dotPhase * 0.5))
        let dotColor: NSColor
        if state.isConnected {
            dotColor = NSColor(red: 0.2, green: 0.75, blue: 0.3, alpha: dotGlow)
        } else {
            dotColor = NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: dotGlow)
        }
        let dotX = (w - nameSize.width) / 2 - 18
        let dotY = nameY + (nameSize.height - 10) / 2
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8, color: dotColor.withAlphaComponent(0.6).cgColor)
        dotColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: dotX, y: dotY, width: 10, height: 10)).fill()
        ctx.restoreGState()

        // --- Version ---
        if !state.version.isEmpty {
            drawCenteredText("v\(state.version)", y: nameY - 22, dx: 0, width: w,
                             font: .monospacedSystemFont(ofSize: 14, weight: .medium),
                             color: NSColor.white.withAlphaComponent(0.12))
        }

        // --- Stream count ---
        let n = state.streams.count
        let countText: String
        let countColor: NSColor
        if n > 0 {
            countText = "\(n) ACTIVE STREAM\(n == 1 ? "" : "S")"
            countColor = plexGold.withAlphaComponent(0.55)
        } else if !state.isConnected && !Self.token.isEmpty {
            countText = "CANNOT REACH SERVER"
            countColor = NSColor.orange.withAlphaComponent(0.25)
        } else if Self.token.isEmpty {
            countText = "CONFIGURE IN SCREEN SAVER OPTIONS"
            countColor = NSColor.white.withAlphaComponent(0.15)
        } else {
            countText = "NO ACTIVE STREAMS"
            countColor = NSColor.white.withAlphaComponent(0.15)
        }
        drawCenteredText(countText, y: nameY - 55, dx: 0, width: w,
                         font: .systemFont(ofSize: 14, weight: .semibold), color: countColor)

        // --- Cards (gentle drift, shadows, fade transitions) ---
        let streams = Array(state.streams)
        let cardW: CGFloat = 160
        let gap: CGFloat = min(max(w * 0.03, 20), 60)
        let rowGap: CGFloat = 30

        // Split into rows: up to 8 per row, 2 rows max (16 streams)
        let maxPerRow = 8
        let row1 = Array(streams.prefix(maxPerRow))
        let row2 = streams.count > maxPerRow ? Array(streams.dropFirst(maxPerRow).prefix(maxPerRow)) : []
        let hasSecondRow = !row2.isEmpty

        // Vertical positioning — shift up if 2 rows
        let posterH: CGFloat = cardW * 1.5
        let cardTotalH: CGFloat = posterH + 100  // poster + text + badge
        let cardBaseY: CGFloat
        if hasSecondRow {
            cardBaseY = h * 0.18
        } else {
            cardBaseY = h * 0.25
        }
        let row2BaseY = cardBaseY + cardTotalH + rowGap

        // Draw row 1
        let totalRow1W = CGFloat(row1.count) * cardW + CGFloat(max(row1.count - 1, 0)) * gap
        let startX1 = (w - totalRow1W) / 2
        for (i, stream) in row1.enumerated() {
            let cardPhase = time * 0.3 + Double(i) * 1.8
            let cdx = CGFloat(cos(cardPhase * 0.15) * 4)
            let cdy = CGFloat(sin(cardPhase * 0.2) * 3)
            let cx = startX1 + CGFloat(i) * (cardW + gap) + cdx
            let cy = cardBaseY + cdy
            let fadeOpacity = cardOpacities[stream.id] ?? 1.0
            drawCard(ctx: ctx, stream: stream, x: cx, y: cy,
                     cardW: cardW, cardH: 320, opacity: fadeOpacity)
        }

        // Draw row 2
        if hasSecondRow {
            let totalRow2W = CGFloat(row2.count) * cardW + CGFloat(max(row2.count - 1, 0)) * gap
            let startX2 = (w - totalRow2W) / 2
            for (i, stream) in row2.enumerated() {
                let cardPhase = time * 0.3 + Double(i + maxPerRow) * 1.8
                let cdx = CGFloat(cos(cardPhase * 0.15) * 4)
                let cdy = CGFloat(sin(cardPhase * 0.2) * 3)
                let cx = startX2 + CGFloat(i) * (cardW + gap) + cdx
                let cy = row2BaseY + cdy
                let fadeOpacity = cardOpacities[stream.id] ?? 1.0
                drawCard(ctx: ctx, stream: stream, x: cx, y: cy,
                         cardW: cardW, cardH: 320, opacity: fadeOpacity)
            }
        }

        // --- Bottom Panel (glass + meters) ---
        drawBottomPanel(ctx: ctx, w: w, h: h, state: state)
    }

    // MARK: - Clock

    private func drawClock(ctx: CGContext, w: CGFloat, h: CGFloat) {
        let now = Date()
        let timeStr = Self.timeFormatter.string(from: now)
        let ampm = Self.ampmFormatter.string(from: now)
        let dateStr = Self.dateStringFormatter.string(from: now)

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .thin)
        let ampmFont = NSFont.systemFont(ofSize: 12, weight: .light)
        let dateFont = NSFont.systemFont(ofSize: 12, weight: .light)

        let clockAlpha: CGFloat = 0.18

        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: timeFont,
            .foregroundColor: NSColor.white.withAlphaComponent(clockAlpha)
        ]
        let ampmAttrs: [NSAttributedString.Key: Any] = [
            .font: ampmFont,
            .foregroundColor: NSColor.white.withAlphaComponent(clockAlpha * 0.7)
        ]
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: dateFont,
            .foregroundColor: NSColor.white.withAlphaComponent(clockAlpha * 0.6)
        ]

        let margin: CGFloat = 30
        let timeSize = (timeStr as NSString).size(withAttributes: timeAttrs)
        let ampmSize = (ampm as NSString).size(withAttributes: ampmAttrs)

        let timeX = w - margin - timeSize.width - ampmSize.width - 4
        let timeY = h - margin - timeSize.height

        (timeStr as NSString).draw(at: CGPoint(x: timeX, y: timeY), withAttributes: timeAttrs)
        (ampm as NSString).draw(at: CGPoint(x: timeX + timeSize.width + 4,
                                             y: timeY + (timeSize.height - ampmSize.height) * 0.3),
                                 withAttributes: ampmAttrs)

        let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)
        let dateX = w - margin - dateSize.width
        (dateStr as NSString).draw(at: CGPoint(x: dateX, y: timeY - dateSize.height - 2),
                                    withAttributes: dateAttrs)
    }

    // MARK: - Bottom Panel

    private func drawBottomPanel(ctx: CGContext, w: CGFloat, h: CGFloat, state: SSServerState) {
        let gaugeRadius: CGFloat = 52
        let gaugeDiameter = gaugeRadius * 2
        let sparkW: CGFloat = 160
        let sectionSpacing: CGFloat = 36
        let panelPadH: CGFloat = 30
        let panelPadV: CGFloat = 22

        let cpuSectionW = gaugeDiameter + 8
        let ramSectionW = gaugeDiameter + 8

        let contentW = cpuSectionW + sectionSpacing + ramSectionW + sectionSpacing + sparkW
        let panelW = contentW + panelPadH * 2

        let gaugeAbove: CGFloat = gaugeRadius
        let gaugeBelow: CGFloat = 30
        let gaugeTotalH = gaugeAbove + gaugeBelow
        let sparkTotalH: CGFloat = 100

        let contentH = max(gaugeTotalH, sparkTotalH)
        let panelH = contentH + panelPadV * 2 + 20
        let panelX = (w - panelW) / 2
        let panelY: CGFloat = 24

        // --- Glass panel with shadow ---
        let panelRect = CGRect(x: panelX, y: panelY, width: panelW, height: panelH)
        let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 24,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.15))
        NSColor(white: 0.06, alpha: 0.18).setFill()
        panelPath.fill()
        ctx.restoreGState()

        let highlightRect = CGRect(x: panelX + 1, y: panelY + panelH - 2,
                                   width: panelW - 2, height: 1)
        NSColor(white: 1.0, alpha: 0.03).setFill()
        NSBezierPath(rect: highlightRect).fill()

        NSColor(white: 1.0, alpha: 0.05).setStroke()
        panelPath.lineWidth = 0.5
        panelPath.stroke()

        // --- Vertical centering ---
        let panelMidY = panelY + panelH / 2
        let contentStartX = panelX + panelPadH
        let arcCenterY = panelMidY - gaugeRadius + gaugeTotalH / 2

        let sepColor = NSColor(white: 1.0, alpha: 0.06)

        // --- CPU Gauge ---
        let cpuCenterX = contentStartX + cpuSectionW / 2
        drawArcGauge(ctx: ctx, centerX: cpuCenterX, bottomY: arcCenterY,
                     radius: gaugeRadius, value: currentCPU, color: plexCyan,
                     label: "CPU", detail: "Host",
                     valueText: "\(Int(currentCPU))", unit: "%")

        let sep1X = contentStartX + cpuSectionW + sectionSpacing / 2
        sepColor.setFill()
        NSBezierPath(rect: CGRect(x: sep1X, y: panelY + 14, width: 0.5, height: panelH - 28)).fill()

        // --- RAM Gauge ---
        let ramCenterX = contentStartX + cpuSectionW + sectionSpacing + ramSectionW / 2
        drawArcGauge(ctx: ctx, centerX: ramCenterX, bottomY: arcCenterY,
                     radius: gaugeRadius, value: currentRAM, color: plexPurple,
                     label: "RAM", detail: "Host",
                     valueText: "\(Int(currentRAM))", unit: "%")

        let sep2X = contentStartX + cpuSectionW + sectionSpacing + ramSectionW + sectionSpacing / 2
        sepColor.setFill()
        NSBezierPath(rect: CGRect(x: sep2X, y: panelY + 14, width: 0.5, height: panelH - 28)).fill()

        // --- Bandwidth Sparkline ---
        let bwStartX = contentStartX + cpuSectionW + sectionSpacing + ramSectionW + sectionSpacing
        let sparkBlockY = panelMidY - sparkTotalH / 2
        drawBandwidthSparkline(ctx: ctx, x: bwStartX, y: sparkBlockY,
                               width: sparkW, chartHeight: 56,
                               currentBW: state.totalBandwidthMbps)

        // --- Transcoding / Direct Play ---
        let trans = state.streams.filter(\.isTranscoding).count
        let direct = state.streams.count - trans
        var footerParts: [String] = []
        if trans > 0 { footerParts.append("\(trans) transcoding") }
        if direct > 0 { footerParts.append("\(direct) direct play") }
        let footerText = footerParts.joined(separator: "    ")
        if !footerText.isEmpty {
            let footerFont = NSFont.systemFont(ofSize: 10, weight: .medium)
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: footerFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.30)
            ]
            let footerSize = (footerText as NSString).size(withAttributes: footerAttrs)
            (footerText as NSString).draw(
                at: CGPoint(x: panelX + (panelW - footerSize.width) / 2, y: panelY + 8),
                withAttributes: footerAttrs)
        }
    }

    // MARK: - Arc Gauge

    private func drawArcGauge(ctx: CGContext, centerX: CGFloat, bottomY: CGFloat,
                              radius: CGFloat, value: Double, color: NSColor,
                              label: String, detail: String,
                              valueText: String, unit: String) {
        let center = CGPoint(x: centerX, y: bottomY)

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
        ctx.setLineWidth(5.5)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius,
                   startAngle: .pi, endAngle: 0, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

        let clampedValue = min(max(value, 0), 100)
        if clampedValue > 0.5 {
            let endAngle = CGFloat.pi * (1 - clampedValue / 100)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6,
                          color: color.withAlphaComponent(0.30).cgColor)
            ctx.setStrokeColor(color.withAlphaComponent(0.65).cgColor)
            ctx.setLineWidth(5.5)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: radius,
                       startAngle: .pi, endAngle: endAngle, clockwise: true)
            ctx.strokePath()
            ctx.restoreGState()
        }

        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        let unitFont  = NSFont.systemFont(ofSize: 12, weight: .medium)
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: unitFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.40)
        ]

        let valueSize = (valueText as NSString).size(withAttributes: valueAttrs)
        let unitSize  = (unit as NSString).size(withAttributes: unitAttrs)
        let combinedW = valueSize.width + unitSize.width + 2

        let textY = center.y + radius * 0.18
        let textX = centerX - combinedW / 2
        (valueText as NSString).draw(at: CGPoint(x: textX, y: textY), withAttributes: valueAttrs)
        (unit as NSString).draw(at: CGPoint(x: textX + valueSize.width + 2,
                                            y: textY + (valueSize.height - unitSize.height) * 0.35),
                                withAttributes: unitAttrs)

        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)
        (label as NSString).draw(at: CGPoint(x: centerX - labelSize.width / 2,
                                             y: center.y - labelSize.height - 4),
                                 withAttributes: labelAttrs)

        let detailFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: detailFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.25)
        ]
        let detailSize = (detail as NSString).size(withAttributes: detailAttrs)
        (detail as NSString).draw(at: CGPoint(x: centerX - detailSize.width / 2,
                                              y: center.y - labelSize.height - detailSize.height - 6),
                                  withAttributes: detailAttrs)
    }

    // MARK: - Bandwidth Sparkline (Catmull-Rom smoothed)

    private func drawBandwidthSparkline(ctx: CGContext, x: CGFloat, y: CGFloat,
                                        width: CGFloat, chartHeight: CGFloat,
                                        currentBW: Double) {
        let chartY = y
        let chartH = chartHeight

        let headerFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.40)
        ]
        ("BANDWIDTH - 60s" as NSString).draw(at: CGPoint(x: x, y: chartY + chartH + 32),
                                              withAttributes: headerAttrs)

        let bwText = String(format: "%.1f", currentBW)
        let bwFont = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        let unitFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let bwAttrs: [NSAttributedString.Key: Any] = [
            .font: bwFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: unitFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.40)
        ]
        let bwSize = (bwText as NSString).size(withAttributes: bwAttrs)
        (bwText as NSString).draw(at: CGPoint(x: x, y: chartY + chartH + 6), withAttributes: bwAttrs)
        ("Mbps" as NSString).draw(at: CGPoint(x: x + bwSize.width + 3,
                                               y: chartY + chartH + 6 + (bwSize.height - 14) * 0.35),
                                   withAttributes: unitAttrs)

        let history = bandwidthHistory
        guard history.count >= 2 else {
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: chartY))
            ctx.addLine(to: CGPoint(x: x + width, y: chartY))
            ctx.strokePath()
            ctx.restoreGState()
            return
        }

        let rawMax = history.max() ?? 1
        let maxVal = max(rawMax * 1.3, 1)
        let step = width / CGFloat(maxBWHistory - 1)

        var dataPoints: [CGPoint] = []
        let offset = maxBWHistory - history.count
        for (i, val) in history.enumerated() {
            let px = x + CGFloat(i + offset) * step
            let py = chartY + CGFloat(val / maxVal) * chartH
            dataPoints.append(CGPoint(x: px, y: py))
        }

        let smoothPoints = catmullRomPoints(dataPoints, subdivisions: 8)

        // Gradient fill under curve
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: CGPoint(x: smoothPoints[0].x, y: chartY))
        for pt in smoothPoints { ctx.addLine(to: pt) }
        ctx.addLine(to: CGPoint(x: smoothPoints.last!.x, y: chartY))
        ctx.closePath()
        ctx.clip()

        let gradColors = [
            plexGold.withAlphaComponent(0.25).cgColor,
            plexGold.withAlphaComponent(0.02).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: Self.deviceRGB, colors: gradColors, locations: [1, 0]) {
            ctx.drawLinearGradient(gradient,
                                  start: CGPoint(x: x, y: chartY + chartH),
                                  end: CGPoint(x: x, y: chartY),
                                  options: [])
        }
        ctx.restoreGState()

        // Smooth line stroke
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 3, color: plexGold.withAlphaComponent(0.25).cgColor)
        ctx.setStrokeColor(plexGold.withAlphaComponent(0.70).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: smoothPoints[0])
        for pt in smoothPoints.dropFirst() { ctx.addLine(to: pt) }
        ctx.strokePath()
        ctx.restoreGState()

        // Glowing dot at current value
        if let last = smoothPoints.last {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: plexGold.withAlphaComponent(0.50).cgColor)
            ctx.setFillColor(plexGold.withAlphaComponent(0.90).cgColor)
            ctx.fillEllipse(in: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7))
            ctx.restoreGState()
        }
    }

    // Catmull-Rom spline interpolation
    private func catmullRomPoints(_ points: [CGPoint], subdivisions: Int) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result: [CGPoint] = []

        for i in 0..<points.count - 1 {
            let p0 = i > 0 ? points[i - 1] : points[i]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

            for s in 0..<subdivisions {
                let t = CGFloat(s) / CGFloat(subdivisions)
                let t2 = t * t
                let t3 = t2 * t

                let px = 0.5 * ((2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
                    (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)

                let py = 0.5 * ((2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                    (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

                result.append(CGPoint(x: px, y: py))
            }
        }
        if let last = points.last { result.append(last) }
        return result
    }

    // MARK: - Drawing Helpers

    private func drawRadialGradient(ctx: CGContext, w: CGFloat, h: CGFloat, frame: Int) {
        let colorSpace = Self.deviceRGB
        let t = Double(frame) * 0.008
        let maxDim = max(w, h)

        // Magenta — upper left orbit
        let magX = w * (0.20 + 0.25 * CGFloat(cos(t * 0.41)))
        let magY = h * (0.75 + 0.20 * CGFloat(sin(t * 0.37)))
        let magAlpha = CGFloat(0.20 + 0.08 * sin(t * 0.67))
        let magColors = [
            CGColor(red: 1.0, green: 0.08, blue: 0.58, alpha: magAlpha),
            CGColor(red: 1.0, green: 0.08, blue: 0.58, alpha: 0)
        ] as CFArray
        if let g = CGGradient(colorsSpace: colorSpace, colors: magColors, locations: [0, 1]) {
            let c = CGPoint(x: magX, y: magY)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: maxDim * 0.55,
                                   options: .drawsAfterEndLocation)
        }

        // Deep blue — upper right orbit
        let blueX = w * (0.78 + 0.20 * CGFloat(sin(t * 0.53 + 1.0)))
        let blueY = h * (0.70 + 0.22 * CGFloat(cos(t * 0.31)))
        let blueAlpha = CGFloat(0.22 + 0.08 * sin(t * 0.83 + 0.5))
        let blueColors = [
            CGColor(red: 0.08, green: 0.18, blue: 1.0, alpha: blueAlpha),
            CGColor(red: 0.08, green: 0.18, blue: 1.0, alpha: 0)
        ] as CFArray
        if let g = CGGradient(colorsSpace: colorSpace, colors: blueColors, locations: [0, 1]) {
            let c = CGPoint(x: blueX, y: blueY)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: maxDim * 0.6,
                                   options: .drawsAfterEndLocation)
        }

        // Teal/green — lower right orbit
        let greenX = w * (0.72 - 0.22 * CGFloat(cos(t * 0.47 + 2.0)))
        let greenY = h * (0.28 + 0.18 * CGFloat(sin(t * 0.43 + 1.5)))
        let greenAlpha = CGFloat(0.16 + 0.07 * sin(t * 0.59 + 3.0))
        let greenColors = [
            CGColor(red: 0.02, green: 0.95, blue: 0.55, alpha: greenAlpha),
            CGColor(red: 0.02, green: 0.95, blue: 0.55, alpha: 0)
        ] as CFArray
        if let g = CGGradient(colorsSpace: colorSpace, colors: greenColors, locations: [0, 1]) {
            let c = CGPoint(x: greenX, y: greenY)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: maxDim * 0.55,
                                   options: .drawsAfterEndLocation)
        }

        // Warm yellow — lower left orbit
        let yellowX = w * (0.30 + 0.20 * CGFloat(sin(t * 0.37 + 3.5)))
        let yellowY = h * (0.25 - 0.18 * CGFloat(cos(t * 0.51 + 2.0)))
        let yellowAlpha = CGFloat(0.16 + 0.06 * sin(t * 0.73 + 1.0))
        let yellowColors = [
            CGColor(red: 1.0, green: 0.82, blue: 0.05, alpha: yellowAlpha),
            CGColor(red: 1.0, green: 0.82, blue: 0.05, alpha: 0)
        ] as CFArray
        if let g = CGGradient(colorsSpace: colorSpace, colors: yellowColors, locations: [0, 1]) {
            let c = CGPoint(x: yellowX, y: yellowY)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: maxDim * 0.5,
                                   options: .drawsAfterEndLocation)
        }
    }

    private func drawCenteredText(_ text: String, y: CGFloat, dx: CGFloat, width: CGFloat,
                                  font: NSFont, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: dx, y: y, width: width, height: size.height + 4)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func drawCard(ctx: CGContext, stream: SSStream, x: CGFloat, y: CGFloat,
                          cardW: CGFloat, cardH: CGFloat, opacity: CGFloat) {
        let posterH: CGFloat = cardW * 1.5
        let posterY = y + 70
        let accent = cardAccentColor(for: stream)

        // --- Shadow under card ---
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: Double(0.5 * opacity)))
        let shadowRect = CGRect(x: x - 4, y: posterY - 4, width: cardW + 8, height: posterH + 8)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.01))
        ctx.fill(shadowRect)
        ctx.restoreGState()

        // --- Colored backing card ---
        let backInset: CGFloat = 6
        let backRect = CGRect(x: x - backInset, y: posterY - backInset,
                              width: cardW + backInset * 2, height: posterH + backInset * 2)
        let backPath = NSBezierPath(roundedRect: backRect, xRadius: 16, yRadius: 16)

        ctx.saveGState()
        backPath.addClip()
        let topColor = accent.withAlphaComponent(0.65 * opacity).cgColor
        let bottomColor = accent.withAlphaComponent(0.20 * opacity).cgColor
        let gradColors = [topColor, bottomColor] as CFArray
        if let gradient = CGGradient(colorsSpace: Self.deviceRGB, colors: gradColors, locations: [1, 0]) {
            ctx.drawLinearGradient(gradient,
                                  start: CGPoint(x: x, y: posterY + posterH + backInset),
                                  end: CGPoint(x: x, y: posterY - backInset),
                                  options: [])
        }
        ctx.restoreGState()

        accent.withAlphaComponent(0.18 * opacity).setStroke()
        backPath.lineWidth = 1
        backPath.stroke()

        // --- Poster ---
        let posterRect = CGRect(x: x, y: posterY, width: cardW, height: posterH)
        let posterPath = NSBezierPath(roundedRect: posterRect, xRadius: 12, yRadius: 12)

        let hasPoster = stream.thumbPath != nil && viewModel.posterImages[stream.thumbPath!] != nil

        if hasPoster, let path = stream.thumbPath, let img = viewModel.posterImages[path] {
            NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: opacity).setFill()
            posterPath.fill()
            ctx.saveGState()
            posterPath.addClip()
            img.draw(in: posterRect, from: .zero, operation: .sourceOver, fraction: opacity)
            ctx.restoreGState()
        } else {
            // Animated shimmer placeholder
            NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: opacity).setFill()
            posterPath.fill()

            ctx.saveGState()
            posterPath.addClip()
            let shimmerPhase = CGFloat(frameCount % 120) / 120.0
            let shimmerX = posterRect.minX + (posterRect.width + 80) * shimmerPhase - 40
            let shimmerColors = [
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0.04 * opacity).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            if let shimGrad = CGGradient(colorsSpace: Self.deviceRGB, colors: shimmerColors,
                                          locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(shimGrad,
                                      start: CGPoint(x: shimmerX - 40, y: posterRect.minY),
                                      end: CGPoint(x: shimmerX + 40, y: posterRect.maxY),
                                      options: [])
            }
            ctx.restoreGState()
        }

        NSColor.white.withAlphaComponent(0.06 * opacity).setStroke()
        posterPath.lineWidth = 0.5
        posterPath.stroke()

        // --- Rounded progress bar (capsule) ---
        let progY = posterY + 1
        let progH: CGFloat = 4
        let progBgRect = CGRect(x: x + 8, y: progY, width: cardW - 16, height: progH)
        NSColor.black.withAlphaComponent(0.5 * opacity).setFill()
        NSBezierPath(roundedRect: progBgRect, xRadius: progH / 2, yRadius: progH / 2).fill()

        let pw = (cardW - 16) * CGFloat(stream.progress)
        if pw > 0 {
            let progFillRect = CGRect(x: x + 8, y: progY, width: pw, height: progH)
            plexGold.withAlphaComponent(0.85 * opacity).setFill()
            NSBezierPath(roundedRect: progFillRect, xRadius: progH / 2, yRadius: progH / 2).fill()
        }

        // --- Quality badge ---
        let badgeText = stream.quality
        let badgeFont = NSFont.systemFont(ofSize: 10, weight: .bold)
        let badgeSize = (badgeText as NSString).size(withAttributes: [.font: badgeFont])
        let badgeW = max(badgeSize.width + 16, 40)
        let badgeRect = CGRect(x: x + cardW - badgeW - 10, y: posterY + posterH - 2,
                               width: badgeW, height: 20)
        NSColor.black.withAlphaComponent(0.65 * opacity).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 8, yRadius: 8).fill()
        let badgePara = NSMutableParagraphStyle()
        badgePara.alignment = .center
        (badgeText as NSString).draw(in: badgeRect, withAttributes: [
            .font: badgeFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85 * opacity),
            .paragraphStyle: badgePara
        ])

        // --- Text below card ---
        let titleCenterX = x + cardW / 2
        drawCenteredText(stream.title, y: y + 44, dx: titleCenterX - bounds.width / 2,
                         width: bounds.width,
                         font: .systemFont(ofSize: 14, weight: .semibold),
                         color: NSColor.white.withAlphaComponent(0.85 * opacity))

        drawCenteredText(stream.subtitle, y: y + 26, dx: titleCenterX - bounds.width / 2,
                         width: bounds.width,
                         font: .systemFont(ofSize: 12, weight: .light),
                         color: NSColor.white.withAlphaComponent(0.35 * opacity))

        drawCenteredText(stream.user, y: y + 8, dx: titleCenterX - bounds.width / 2,
                         width: bounds.width,
                         font: .systemFont(ofSize: 11, weight: .medium),
                         color: plexGold.withAlphaComponent(0.5 * opacity))

        // --- Location (City, State) ---
        let location = stream.address.flatMap { viewModel.geoLocations[$0] }
        if let location {
            drawCenteredText(location, y: y - 6, dx: titleCenterX - bounds.width / 2,
                             width: bounds.width,
                             font: .systemFont(ofSize: 10, weight: .regular),
                             color: NSColor.white.withAlphaComponent(0.3 * opacity))
        }

        if stream.bandwidthMbps > 0 {
            let bwY: CGFloat = location != nil ? y - 20 : y - 6
            drawCenteredText(String(format: "%.1f Mbps", stream.bandwidthMbps),
                             y: bwY, dx: titleCenterX - bounds.width / 2,
                             width: bounds.width,
                             font: .monospacedSystemFont(ofSize: 10, weight: .medium),
                             color: NSColor.white.withAlphaComponent(0.15 * opacity))
        }
    }

    // MARK: - Config Sheet

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? {
        if configController == nil {
            configController = ConfigSheetController()
        }
        configController?.reloadFields()
        return configController?.window
    }
}
