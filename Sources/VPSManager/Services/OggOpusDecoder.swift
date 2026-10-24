import Foundation
import AVFoundation
import AudioToolbox

/// Errors specific to decoding an Ogg-Opus file, surfaced to the UI as plain,
/// specific sentences rather than a generic "couldn't play this file".
enum OpusDecodeError: LocalizedError {
    case notOggOpus
    case oggVorbisNotSupported
    case unsupportedChannelMapping(family: UInt8, channels: UInt8)
    case corruptStream
    case converterUnavailable
    case noAudioPackets

    var errorDescription: String? {
        switch self {
        case .notOggOpus:
            return "This isn't a valid Ogg Opus file."
        case .oggVorbisNotSupported:
            return "This is an Ogg Vorbis file (not Opus). Vorbis audio isn't supported — only Opus-in-Ogg is."
        case .unsupportedChannelMapping(let family, let channels):
            return "This Opus file uses a multichannel layout (mapping family \(family), \(channels) channels) that isn't supported — only mono and stereo Opus files can be played."
        case .corruptStream:
            return "The Opus stream looks truncated or corrupted."
        case .converterUnavailable:
            return "This Mac's system Opus decoder couldn't be created."
        case .noAudioPackets:
            return "No audio data was found in this Opus file."
        }
    }
}

/// Decodes standalone Ogg-Opus (`.opus`, and Opus-flavored `.ogg`/`.oga`) files into
/// PCM audio.
///
/// AVFoundation has no built-in Ogg demuxer, and neither `AVAudioPlayer` nor
/// `AVPlayer` can open a raw `.opus`/`.ogg` file directly — they fail with
/// `AVFoundationErrorDomain` error -11828, "This media format is not supported."
/// Core Audio *does* ship a real Opus decoder (`kAudioFormatOpus`, used internally
/// for CAF-wrapped Opus and WebRTC-style streams), it's just never wired up to
/// understand the Ogg container. So this type does the two missing pieces itself:
/// parse the Ogg container to pull out the raw Opus packets (RFC 3533 framing, RFC
/// 7845 Opus-in-Ogg mapping), then feed those packets through Core Audio's own Opus
/// codec via `AVAudioConverter` to get linear PCM, which is written out as a
/// temporary `.caf` file that `AVAudioPlayer` can open like any other supported
/// format.
///
/// Supports the overwhelming majority of real-world `.opus` files: mono and stereo,
/// channel mapping family 0 (the standard, single-stream case almost every encoder
/// — `opusenc`, ffmpeg, browsers' voice recorders, etc. — produces by default).
/// Multichannel/ambisonic Opus (mapping family 1 with >2 channels, or family 255)
/// needs a multistream decoder Core Audio doesn't expose and is reported as a clear,
/// specific error instead of silently failing.
enum OggOpusDecoder {
    static func decodeToTemporaryCAF(_ data: Data) throws -> URL {
        let packets = try parseOggPackets(data)
        guard packets.count >= 2 else { throw OpusDecodeError.noAudioPackets }

        let head = try parseOpusHead(packets[0])
        guard head.channelMappingFamily == 0 && head.channelCount <= 2 else {
            throw OpusDecodeError.unsupportedChannelMapping(family: head.channelMappingFamily, channels: head.channelCount)
        }

        // Packet 0 is OpusHead, packet 1 is the OpusTags comment header — neither
        // carries audio. Everything after that is audio data, one packet per frame.
        let audioPackets = Array(packets.dropFirst(2))
        guard !audioPackets.isEmpty else { throw OpusDecodeError.noAudioPackets }

        let pcmBuffer = try decode(audioPackets: audioPackets, channels: Int(head.channelCount), preSkip: Int(head.preSkip))
        return try write(pcmBuffer: pcmBuffer)
    }

    // MARK: - Ogg container parsing (RFC 3533)

    private struct OpusHead {
        let channelCount: UInt8
        let preSkip: UInt16
        let channelMappingFamily: UInt8
    }

    /// Walks the Ogg page stream and reassembles it into logical packets, keeping
    /// only the pages belonging to the first bitstream whose very first packet is an
    /// `OpusHead` (i.e. ignoring any other logical bitstreams multiplexed into the
    /// same file, which standalone `.opus` files exported by common tools don't
    /// have, but which the container format technically allows).
    private static func parseOggPackets(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        let count = bytes.count
        guard count >= 27 else { throw OpusDecodeError.notOggOpus }

        var packets: [Data] = []
        var current = Data()
        var offset = 0
        var sawAnyPage = false
        var lockedSerial: UInt32?
        var sawAnyOggPage = false

        while offset + 27 <= count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67,
                  bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                // Once we've successfully read at least one page, trailing garbage
                // after the last page is tolerated (just stop); before that, this
                // isn't an Ogg file at all.
                if sawAnyPage { break } else { throw OpusDecodeError.notOggOpus }
            }
            sawAnyOggPage = true

            let serial = UInt32(bytes[offset + 14])
                | (UInt32(bytes[offset + 15]) << 8)
                | (UInt32(bytes[offset + 16]) << 16)
                | (UInt32(bytes[offset + 17]) << 24)
            let segmentCount = Int(bytes[offset + 26])
            guard offset + 27 + segmentCount <= count else { throw OpusDecodeError.corruptStream }
            let segmentTable = bytes[(offset + 27)..<(offset + 27 + segmentCount)]
            var dataOffset = offset + 27 + segmentCount

            if lockedSerial == nil, dataOffset + 8 <= count,
               bytes[dataOffset] == 0x4F, bytes[dataOffset + 1] == 0x70, bytes[dataOffset + 2] == 0x75, bytes[dataOffset + 3] == 0x73,
               bytes[dataOffset + 4] == 0x48, bytes[dataOffset + 5] == 0x65, bytes[dataOffset + 6] == 0x61, bytes[dataOffset + 7] == 0x64 {
                lockedSerial = serial
            }

            let isOurStream = (lockedSerial != nil) && (serial == lockedSerial)
            sawAnyPage = true

            for segLen in segmentTable {
                let len = Int(segLen)
                guard dataOffset + len <= count else { throw OpusDecodeError.corruptStream }
                if isOurStream {
                    current.append(contentsOf: bytes[dataOffset..<(dataOffset + len)])
                    if segLen < 255 {
                        packets.append(current)
                        current = Data()
                    }
                }
                dataOffset += len
            }

            offset = dataOffset
        }

        guard sawAnyOggPage else { throw OpusDecodeError.notOggOpus }

        if packets.isEmpty {
            // We parsed valid Ogg pages but never locked onto an OpusHead-led
            // stream. The single most common reason: this is Ogg Vorbis, not Opus.
            if count >= 27 + 7, let firstSegOffset = firstPacketVorbisCheckOffset(bytes: bytes),
               firstSegOffset + 7 <= count,
               bytes[firstSegOffset] == 0x01,
               bytes[firstSegOffset + 1] == 0x76, bytes[firstSegOffset + 2] == 0x6F, bytes[firstSegOffset + 3] == 0x72,
               bytes[firstSegOffset + 4] == 0x62, bytes[firstSegOffset + 5] == 0x69, bytes[firstSegOffset + 6] == 0x73 {
                throw OpusDecodeError.oggVorbisNotSupported
            }
            throw OpusDecodeError.notOggOpus
        }

        return packets
    }

    /// Best-effort offset of the very first page's payload, used only to sniff for
    /// a Vorbis identification header when no Opus stream was found, so the error
    /// message can be specific instead of a generic "not Opus".
    private static func firstPacketVorbisCheckOffset(bytes: [UInt8]) -> Int? {
        guard bytes.count >= 27 else { return nil }
        let segmentCount = Int(bytes[26])
        guard 27 + segmentCount <= bytes.count else { return nil }
        return 27 + segmentCount
    }

    private static func parseOpusHead(_ packet: Data) throws -> OpusHead {
        let bytes = [UInt8](packet)
        guard bytes.count >= 19,
              bytes[0] == 0x4F, bytes[1] == 0x70, bytes[2] == 0x75, bytes[3] == 0x73,
              bytes[4] == 0x48, bytes[5] == 0x65, bytes[6] == 0x61, bytes[7] == 0x64
        else { throw OpusDecodeError.notOggOpus }

        let channelCount = bytes[9]
        let preSkip = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
        let channelMappingFamily = bytes[18]
        guard channelCount >= 1 else { throw OpusDecodeError.corruptStream }
        return OpusHead(channelCount: channelCount, preSkip: preSkip, channelMappingFamily: channelMappingFamily)
    }

    // MARK: - Opus → PCM via Core Audio

    /// Opus always decodes internally at 48kHz regardless of the input hint in
    /// OpusHead, so that's the only sample rate that makes sense to decode to.
    private static let opusSampleRate: Double = 48_000

    /// Max Opus frame is 120ms @ 48kHz = 5760 frames; pulling a few frames' worth at
    /// a time keeps the number of `convert` calls reasonable without ballooning
    /// memory for long files.
    private static let framesPerPull: AVAudioFrameCount = 5760 * 8

    private static func decode(audioPackets: [Data], channels: Int, preSkip: Int) throws -> AVAudioPCMBuffer {
        var opusDesc = AudioStreamBasicDescription(
            mSampleRate: opusSampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &opusDesc) else {
            throw OpusDecodeError.converterUnavailable
        }
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: opusSampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else {
            throw OpusDecodeError.converterUnavailable
        }
        guard let converter = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw OpusDecodeError.converterUnavailable
        }

        var packetIndex = 0
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard packetIndex < audioPackets.count else {
                outStatus.pointee = .endOfStream
                return nil
            }
            let packet = audioPackets[packetIndex]
            packetIndex += 1

            let compressed = AVAudioCompressedBuffer(
                format: opusFormat,
                packetCapacity: 1,
                maximumPacketSize: max(packet.count, 1)
            )
            compressed.packetCount = 1
            compressed.byteLength = UInt32(packet.count)
            if packet.count > 0 {
                packet.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        compressed.data.copyMemory(from: base, byteCount: packet.count)
                    }
                }
            }
            compressed.packetDescriptions?[0] = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
            )

            outStatus.pointee = .haveData
            return compressed
        }

        var decodedChunks: [AVAudioPCMBuffer] = []
        var conversionError: NSError?

        while packetIndex < audioPackets.count {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: framesPerPull) else {
                throw OpusDecodeError.converterUnavailable
            }
            let status = converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)
            if let conversionError {
                throw conversionError
            }
            if outBuffer.frameLength > 0 {
                decodedChunks.append(outBuffer)
            }
            if status == .endOfStream || status == .error {
                break
            }
        }

        guard !decodedChunks.isEmpty else { throw OpusDecodeError.noAudioPackets }

        // RFC 7845 §4.2: the first `preSkip` decoded samples are priming/pre-roll
        // for the encoder and must be trimmed from the front, not played.
        let totalFrames = decodedChunks.reduce(0) { $0 + Int($1.frameLength) }
        let trimmedStart = min(preSkip, totalFrames)
        let finalFrameCount = totalFrames - trimmedStart
        guard finalFrameCount > 0,
              let finalBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(finalFrameCount))
        else { throw OpusDecodeError.noAudioPackets }
        finalBuffer.frameLength = AVAudioFrameCount(finalFrameCount)

        var written = 0
        var skipRemaining = trimmedStart
        for chunk in decodedChunks {
            let chunkFrames = Int(chunk.frameLength)
            guard chunkFrames > 0 else { continue }

            var sourceStart = 0
            if skipRemaining > 0 {
                let skipHere = min(skipRemaining, chunkFrames)
                sourceStart = skipHere
                skipRemaining -= skipHere
                if sourceStart >= chunkFrames { continue }
            }

            let framesToCopy = chunkFrames - sourceStart
            for ch in 0..<channels {
                guard let src = chunk.floatChannelData?[ch], let dst = finalBuffer.floatChannelData?[ch] else { continue }
                (dst + written).update(from: src + sourceStart, count: framesToCopy)
            }
            written += framesToCopy
        }

        return finalBuffer
    }

    private static func write(pcmBuffer: AVAudioPCMBuffer) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpsmanager-opus-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: pcmBuffer.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: pcmBuffer)
        return url
    }
}