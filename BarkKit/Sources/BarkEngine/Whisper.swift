import Foundation
import MLX
import MLXNN

// Whisper on MLX, a line-for-line port of mlx_whisper 0.4.3 (whisper.py, audio.py) so the
// same fp16 weights give the same numbers as the Python proof in spike S1e.

let sampleRate = 16_000
let nFFT = 400
let hopLength = 160
let nSamples = 30 * sampleRate // one 30 s window
let nFrames = nSamples / hopLength

struct ModelDimensions: Decodable {
    let n_mels, n_audio_ctx, n_audio_state, n_audio_head, n_audio_layer: Int
    let n_vocab, n_text_ctx, n_text_state, n_text_head, n_text_layer: Int
    struct Quantization: Decodable { let group_size, bits: Int }
    let quantization: Quantization?
}

typealias KV = (MLXArray, MLXArray)

final class MultiHeadAttention: Module {
    let nHead: Int
    @ModuleInfo(key: "query") var query: Linear
    @ModuleInfo(key: "key") var keyProj: Linear
    @ModuleInfo(key: "value") var value: Linear
    @ModuleInfo(key: "out") var out: Linear

    init(_ nState: Int, _ nHead: Int) {
        self.nHead = nHead
        _query.wrappedValue = Linear(nState, nState)
        _keyProj.wrappedValue = Linear(nState, nState, bias: false)
        _value.wrappedValue = Linear(nState, nState)
        _out.wrappedValue = Linear(nState, nState)
    }

    /// Self-attention when `xa` is nil (the cache grows), cross-attention otherwise (the cache is
    /// projected once from the audio features and reused).
    func callAsFunction(_ x: MLXArray, xa: MLXArray? = nil, mask: MLXArray? = nil, cache: KV? = nil) -> (MLXArray, KV) {
        let q = query(x)
        var k: MLXArray
        var v: MLXArray
        if let xa {
            (k, v) = cache ?? (keyProj(xa), value(xa))
        } else {
            k = keyProj(x)
            v = value(x)
            if let cache {
                k = concatenated([cache.0, k], axis: 1)
                v = concatenated([cache.1, v], axis: 1)
            }
        }
        return (out(attention(q, k, v, mask)), (k, v))
    }

    private func attention(_ q: MLXArray, _ k: MLXArray, _ v: MLXArray, _ mask: MLXArray?) -> MLXArray {
        let (batch, nCtx, nState) = (q.dim(0), q.dim(1), q.dim(2))
        let scale = pow(Float(nState / nHead), -0.25)
        let qh = q.reshaped(batch, nCtx, nHead, -1).transposed(0, 2, 1, 3) * scale
        let kh = k.reshaped(batch, k.dim(1), nHead, -1).transposed(0, 2, 3, 1) * scale
        let vh = v.reshaped(batch, v.dim(1), nHead, -1).transposed(0, 2, 1, 3)
        var qk = matmul(qh, kh)
        if let mask { qk = qk + mask[0 ..< nCtx, 0 ..< nCtx] }
        let w = softmax(qk, axis: -1, precise: true)
        return matmul(w, vh).transposed(0, 2, 1, 3).reshaped(batch, nCtx, nState)
    }
}

typealias BlockCache = (selfKV: KV, crossKV: KV?)

final class ResidualAttentionBlock: Module {
    @ModuleInfo(key: "attn") var attn: MultiHeadAttention
    @ModuleInfo(key: "attn_ln") var attnLn: LayerNorm
    @ModuleInfo(key: "cross_attn") var crossAttn: MultiHeadAttention?
    @ModuleInfo(key: "cross_attn_ln") var crossAttnLn: LayerNorm?
    @ModuleInfo(key: "mlp1") var mlp1: Linear
    @ModuleInfo(key: "mlp2") var mlp2: Linear
    @ModuleInfo(key: "mlp_ln") var mlpLn: LayerNorm

    init(_ nState: Int, _ nHead: Int, crossAttention: Bool) {
        _attn.wrappedValue = MultiHeadAttention(nState, nHead)
        _attnLn.wrappedValue = LayerNorm(dimensions: nState)
        _crossAttn.wrappedValue = crossAttention ? MultiHeadAttention(nState, nHead) : nil
        _crossAttnLn.wrappedValue = crossAttention ? LayerNorm(dimensions: nState) : nil
        _mlp1.wrappedValue = Linear(nState, nState * 4)
        _mlp2.wrappedValue = Linear(nState * 4, nState)
        _mlpLn.wrappedValue = LayerNorm(dimensions: nState)
    }

    func callAsFunction(_ x: MLXArray, xa: MLXArray? = nil, mask: MLXArray? = nil, cache: BlockCache? = nil) -> (MLXArray, BlockCache) {
        var x = x
        let (y, kv) = attn(attnLn(x), mask: mask, cache: cache?.selfKV)
        x = x + y
        var crossKV: KV?
        if let crossAttn, let crossAttnLn {
            let (y, ckv) = crossAttn(crossAttnLn(x), xa: xa, cache: cache?.crossKV)
            x = x + y
            crossKV = ckv
        }
        x = x + mlp2(gelu(mlp1(mlpLn(x))))
        return (x, (kv, crossKV))
    }
}

final class AudioEncoder: Module {
    @ModuleInfo(key: "conv1") var conv1: Conv1d
    @ModuleInfo(key: "conv2") var conv2: Conv1d
    @ModuleInfo(key: "blocks") var blocks: [ResidualAttentionBlock]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    let positionalEmbedding: MLXArray

    init(_ d: ModelDimensions) {
        _conv1.wrappedValue = Conv1d(inputChannels: d.n_mels, outputChannels: d.n_audio_state, kernelSize: 3, padding: 1)
        _conv2.wrappedValue = Conv1d(inputChannels: d.n_audio_state, outputChannels: d.n_audio_state, kernelSize: 3, stride: 2, padding: 1)
        _blocks.wrappedValue = (0 ..< d.n_audio_layer).map { _ in ResidualAttentionBlock(d.n_audio_state, d.n_audio_head, crossAttention: false) }
        _lnPost.wrappedValue = LayerNorm(dimensions: d.n_audio_state)
        // sinusoids(n_audio_ctx, n_audio_state), computed in float32 then cast like mlx_whisper.
        let half = d.n_audio_state / 2
        let invTimescales = exp(-(log(Float(10_000)) / Float(half - 1)) * MLXArray(0 ..< half).asType(.float32))
        let scaledTime = MLXArray(0 ..< d.n_audio_ctx).asType(.float32).expandedDimensions(axis: 1) * invTimescales.expandedDimensions(axis: 0)
        positionalEmbedding = concatenated([sin(scaledTime), cos(scaledTime)], axis: 1).asType(.float16)
    }

    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = gelu(conv1(mel))
        x = gelu(conv2(x))
        precondition(Array(x.shape.dropFirst()) == positionalEmbedding.shape, "incorrect audio shape")
        x = x + positionalEmbedding
        for block in blocks { x = block(x).0 }
        return lnPost(x)
    }
}

final class TextDecoder: Module {
    @ModuleInfo(key: "token_embedding") var tokenEmbedding: Embedding
    @ParameterInfo(key: "positional_embedding") var positionalEmbedding: MLXArray
    @ModuleInfo(key: "blocks") var blocks: [ResidualAttentionBlock]
    @ModuleInfo(key: "ln") var ln: LayerNorm
    let mask: MLXArray

    init(_ d: ModelDimensions) {
        _tokenEmbedding.wrappedValue = Embedding(embeddingCount: d.n_vocab, dimensions: d.n_text_state)
        _positionalEmbedding.wrappedValue = MLXArray.zeros([d.n_text_ctx, d.n_text_state])
        _blocks.wrappedValue = (0 ..< d.n_text_layer).map { _ in ResidualAttentionBlock(d.n_text_state, d.n_text_head, crossAttention: true) }
        _ln.wrappedValue = LayerNorm(dimensions: d.n_text_state)
        mask = MLXNN.MultiHeadAttention.createAdditiveCausalMask(d.n_text_ctx).asType(.float16)
    }

    /// Logits (float16) for every input position, plus the grown cache.
    func callAsFunction(_ tokens: MLXArray, xa: MLXArray, cache: [BlockCache]?) -> (MLXArray, [BlockCache]) {
        let offset = cache?.first?.selfKV.0.dim(1) ?? 0
        var x = tokenEmbedding(tokens) + positionalEmbedding[offset ..< offset + tokens.dim(-1)]
        var newCache: [BlockCache] = []
        for (i, block) in blocks.enumerated() {
            let (y, c) = block(x, xa: xa, mask: mask, cache: cache?[i])
            x = y
            newCache.append(c)
        }
        return (tokenEmbedding.asLinear(ln(x)), newCache)
    }
}

final class Whisper: Module {
    let dims: ModelDimensions
    @ModuleInfo(key: "encoder") var encoder: AudioEncoder
    @ModuleInfo(key: "decoder") var decoder: TextDecoder
    let melFilters: MLXArray
    let window: MLXArray

    init(_ dims: ModelDimensions) {
        self.dims = dims
        _encoder.wrappedValue = AudioEncoder(dims)
        _decoder.wrappedValue = TextDecoder(dims)
        melFilters = slaneyMelFilters(nMels: dims.n_mels)
        // np.hanning(n_fft + 1)[:-1]
        window = MLXArray((0 ..< nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT))) })
    }

    /// Loads mlx_whisper's layout: config.json + weights.safetensors, fp16 or quantized.
    static func load(_ folder: URL) throws -> Whisper {
        let dims = try JSONDecoder().decode(ModelDimensions.self, from: Data(contentsOf: folder.appending(path: "config.json")))
        let model = Whisper(dims)
        var weights = try loadArrays(url: folder.appending(path: "weights.safetensors"))
        weights["alignment_heads"] = nil // word timestamps only
        if let q = dims.quantization {
            quantize(model: model, groupSize: q.group_size, bits: q.bits) { path, _ in weights["\(path).scales"] != nil }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.noUnusedKeys, .shapeMismatch])
        eval(model)
        return model
    }

    /// mlx_whisper.audio.log_mel_spectrogram(audio, padding: N_SAMPLES) cut to the first window
    /// exactly like transcribe(): content frames, zero-padded (in the log-mel domain) to 3000.
    /// Shape [1, 3000, n_mels], float16.
    func melSegment(_ samples: [Float]) -> MLXArray {
        let mel = logMel(samples)
        return melWindow(mel, from: 0, frames: min(nFrames, mel.dim(0) - nFrames))
    }

    /// transcribe()'s mel_segment for a seek: `frames` content frames from `seek`, zero-padded to
    /// 3000. Shape [1, 3000, n_mels], float16.
    func melWindow(_ mel: MLXArray, from seek: Int, frames: Int) -> MLXArray {
        let segment = frames < nFrames
            ? concatenated([mel[seek ..< seek + frames], MLXArray.zeros([nFrames - frames, dims.n_mels])], axis: 0)
            : mel[seek ..< seek + nFrames]
        return segment.asType(.float16).expandedDimensions(axis: 0)
    }

    /// mlx_whisper.audio.log_mel_spectrogram(audio, padding: N_SAMPLES): float32 [frames, n_mels],
    /// of which the first `frames - 3000` hold the audio (transcribe's content_frames).
    func logMel(_ samples: [Float]) -> MLXArray {
        let x = samples + [Float](repeating: 0, count: nSamples)
        let pad = nFFT / 2
        let padded = Array(x[1 ... pad].reversed()) + x + Array(x[(x.count - pad - 1) ..< (x.count - 1)].reversed())
        let frames = (padded.count - nFFT + hopLength) / hopLength
        let windows = asStrided(MLXArray(padded), [frames, nFFT], strides: [hopLength, 1])
        let magnitudes = abs(rfft(windows * window))[0 ..< (frames - 1)].square()
        var logSpec = log10(maximum(matmul(magnitudes, melFilters.T), Float(1e-10)))
        logSpec = maximum(logSpec, logSpec.max() - 8)
        return (logSpec + 4) / 4
    }
}

/// librosa.filters.mel(sr=16000, n_fft=400, n_mels=n, htk=False, norm="slaney"), float32, the
/// filterbank mlx_whisper ships in assets/mel_filters.npz. Shape [n_mels, n_fft / 2 + 1].
func slaneyMelFilters(nMels: Int) -> MLXArray {
    let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = 1000.0 / fSp, logStep = log(6.4) / 27
    func hzToMel(_ f: Double) -> Double { f >= minLogHz ? minLogMel + log(f / minLogHz) / logStep : f / fSp }
    func melToHz(_ m: Double) -> Double { m >= minLogMel ? minLogHz * exp(logStep * (m - minLogMel)) : fSp * m }
    let maxMel = hzToMel(Double(sampleRate) / 2)
    let step = maxMel / Double(nMels + 1) // np.linspace(0, maxMel, nMels + 2)
    let melF = (0 ..< nMels + 2).map { melToHz($0 == nMels + 1 ? maxMel : Double($0) * step) }
    let binHz = 1.0 / (Double(nFFT) * (1.0 / Double(sampleRate))) // np.fft.rfftfreq
    let nBins = nFFT / 2 + 1
    var weights = [Float](repeating: 0, count: nMels * nBins)
    for i in 0 ..< nMels {
        let enorm = 2.0 / (melF[i + 2] - melF[i])
        for k in 0 ..< nBins {
            let f = Double(k) * binHz
            let lower = -(melF[i] - f) / (melF[i + 1] - melF[i])
            let upper = (melF[i + 2] - f) / (melF[i + 2] - melF[i + 1])
            // librosa writes into a float32 array, then scales it in place.
            weights[i * nBins + k] = Float(Double(Float(max(0, min(lower, upper)))) * enorm)
        }
    }
    return MLXArray(weights, [nMels, nBins])
}
