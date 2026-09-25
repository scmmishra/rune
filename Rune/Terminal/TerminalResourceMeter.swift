import AppKit
import SwiftUI

/// A terminal's ports, memory and CPU, shown in its header beside the panel.
@MainActor
final class TerminalResourceMeter: ObservableObject {
    struct Reading: Equatable {
        let ports: [Int]
        /// Rounded to a megabyte so small fluctuations don't redraw the header.
        let memoryMegabytes: Int
        /// Nil until a second sample gives a rate. Can exceed 100 across several cores.
        let cpuPercent: Int?
    }

    @Published private(set) var reading: Reading?
    private var previous: (cpu: UInt64, at: ContinuousClock.Instant)?

    func record(_ sample: TerminalResourceSample?, at now: ContinuousClock.Instant) {
        guard let sample else { return reset() }
        var cpuPercent: Int?
        if let previous, sample.cpuNanoseconds >= previous.cpu {
            let elapsed = (now - previous.at).components
            let wall = Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9
            if wall > 0 { cpuPercent = Int((Double(sample.cpuNanoseconds - previous.cpu) / wall * 100).rounded()) }
        }
        previous = (sample.cpuNanoseconds, now)
        let next = Reading(ports: sample.ports,
                           memoryMegabytes: Int((Double(sample.memoryBytes) / 1_048_576).rounded()),
                           cpuPercent: cpuPercent)
        if next != reading { reading = next }
    }

    func reset() {
        previous = nil
        if reading != nil { reading = nil }
    }
}

struct TerminalResourceLabel: View {
    @ObservedObject var meter: TerminalResourceMeter

    var body: some View {
        if let reading = meter.reading {
            HStack(spacing: 8) {
                ForEach(reading.ports.prefix(2), id: \.self) { port in
                    Button(":\(port)") { open(port) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Open http://localhost:\(port)")
                        .accessibilityLabel("Open port \(port) in the browser")
                }
                if reading.ports.count > 2 {
                    Text("+\(reading.ports.count - 2)")
                        .foregroundStyle(.tertiary)
                        .help(reading.ports.dropFirst(2).map { ":\($0)" }.joined(separator: " "))
                }
                Text(Self.memory(reading.memoryMegabytes))
                    .help("Memory used by this terminal's processes")
                if let cpu = reading.cpuPercent {
                    Text("\(cpu)%")
                        .foregroundStyle(cpu >= 80 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .help("CPU used by this terminal's processes")
                }
            }
            .runeFont(size: 11)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
    }

    private static func memory(_ megabytes: Int) -> String {
        megabytes < 1024 ? "\(megabytes) MB" : String(format: "%.1f GB", Double(megabytes) / 1024)
    }

    private func open(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }
}
