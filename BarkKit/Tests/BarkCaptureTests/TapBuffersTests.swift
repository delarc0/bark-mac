import CoreAudio
@testable import BarkCapture
import Testing

struct TapBuffersTests {
    @Test func aDeviceWithoutInputsLeavesOnlyTheTap() {
        #expect(TapBuffers.range(bufferChannels: [1], tapChannels: 1) == 0 ..< 1)
        #expect(TapBuffers.range(bufferChannels: [2], tapChannels: 2) == 0 ..< 1)
    }

    @Test func theTapComesAfterTheDevicesInputs() {
        #expect(TapBuffers.range(bufferChannels: [2, 1], tapChannels: 1) == 1 ..< 2)
        #expect(TapBuffers.range(bufferChannels: [8, 1], tapChannels: 1) == 1 ..< 2)
        #expect(TapBuffers.range(bufferChannels: [2, 2, 2, 2, 1], tapChannels: 1) == 4 ..< 5)
        #expect(TapBuffers.range(bufferChannels: [1, 1, 1, 1, 1, 1, 1, 1, 1], tapChannels: 1) == 8 ..< 9)
    }

    @Test func aDeinterleavedTapSpansSeveralBuffers() {
        #expect(TapBuffers.range(bufferChannels: [8, 1, 1], tapChannels: 2) == 1 ..< 3)
        #expect(TapBuffers.range(bufferChannels: [2, 2], tapChannels: 2) == 1 ..< 2)
    }

    @Test func aLayoutWithoutTheTapAtItsEndIsRefused() {
        #expect(TapBuffers.range(bufferChannels: [], tapChannels: 1) == nil)
        #expect(TapBuffers.range(bufferChannels: [8], tapChannels: 1) == nil)
        #expect(TapBuffers.range(bufferChannels: [1, 2], tapChannels: 1) == nil)
        #expect(TapBuffers.range(bufferChannels: [1], tapChannels: 2) == nil)
        #expect(TapBuffers.range(bufferChannels: [1], tapChannels: 0) == nil)
    }

    /// An IOProc input list: an 8-channel interface's buffer, then the mono tap's.
    @Test func selectHandsOverTheTapBufferOnly() throws {
        let interface = UnsafeMutablePointer<Float>.allocate(capacity: 8 * 4)
        let tap = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { interface.deallocate(); tap.deallocate() }
        let input = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(input.unsafeMutablePointer) }
        input[0] = AudioBuffer(mNumberChannels: 8, mDataByteSize: 8 * 4 * 4, mData: interface)
        input[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4 * 4, mData: tap)

        let buffers = TapBuffers(range: try #require(TapBuffers.range(bufferChannels: [8, 1], tapChannels: 1)), of: 2)
        let selected = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: try #require(buffers.select(from: input.unsafePointer))))
        #expect(selected.count == 1)
        #expect(selected[0].mData == UnsafeMutableRawPointer(tap))
        #expect(selected[0].mNumberChannels == 1)

        // The device grew a stream since it was built: refused rather than read from the wrong buffer.
        let grown = AudioBufferList.allocate(maximumBuffers: 3)
        defer { free(grown.unsafeMutablePointer) }
        #expect(buffers.select(from: grown.unsafePointer) == nil)
    }
}
