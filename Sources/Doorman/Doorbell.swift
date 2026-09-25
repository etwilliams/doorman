import AppKit

/// A two-note "ding-dong", synthesized rather than shipped as a sound file:
/// each note is a sine with a few bell-like partials and a long exponential
/// ring-out. E5 then C5, a falling major third, like a classic door chime.
@MainActor
enum Doorbell {
    private static let notes: [(freq: Double, at: Double)] = [(659.25, 0), (523.25, 0.42)]

    // Relative frequency and level of each partial. The 2.76× partial is
    // slightly inharmonic, which is what makes a struck bar read as a bell,
    // not an organ.
    private static let partials: [(ratio: Double, level: Double)] = [(1, 1), (2, 0.28), (2.76, 0.12), (4.07, 0.05)]

    private static let masterGain = 0.22
    private static let sampleRate = 44_100.0

    private static var sound: NSSound?

    static func ring() {
        if sound == nil { sound = NSSound(data: wav()) }
        sound?.stop()
        sound?.play()
    }

    /// Renders the chime to 16-bit mono PCM, wrapped as a WAV file.
    private static func wav() -> Data {
        let start = 0.02
        let attack = 0.006
        let floor = 0.0001
        let longest = start + (notes.map(\.at).max() ?? 0) + 1.8 + 0.05
        let count = Int(longest * sampleRate)
        var samples = [Double](repeating: 0, count: count)

        for note in notes {
            for partial in partials {
                let frequency = note.freq * partial.ratio
                // Higher partials die away faster, as they do on a real chime.
                let decay = 1.8 / partial.ratio.squareRoot()
                let begin = start + note.at
                let first = Int(begin * sampleRate)
                let last = min(count, Int((begin + decay) * sampleRate))
                guard first < last else { continue }
                for index in first..<last {
                    let t = Double(index) / sampleRate - begin
                    // Exponential ramps, as Web Audio's exponentialRampToValueAtTime draws them.
                    let envelope = t < attack
                        ? floor * pow(partial.level / floor, t / attack)
                        : partial.level * pow(floor / partial.level, (t - attack) / (decay - attack))
                    samples[index] += envelope * sin(2 * .pi * frequency * t)
                }
            }
        }

        var pcm = Data(capacity: count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample * masterGain)) * Double(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)) // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2)); append(UInt16(16)) // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
