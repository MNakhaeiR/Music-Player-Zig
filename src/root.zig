pub const audio = struct {
    pub const format = @import("audio/format.zig");
    pub const ring = @import("audio/ring.zig");
    pub const backend = @import("audio/backend.zig");
    pub const wasapi = @import("audio/wasapi.zig");
    pub const winmm = @import("audio/winmm.zig");
    pub const null_sink = @import("audio/null_sink.zig");
    pub const wav_sink = @import("audio/wav_sink.zig");
};
pub const dsp = struct {
    pub const biquad = @import("dsp/biquad.zig");
    pub const fft = @import("dsp/fft.zig");
    pub const equalizer = @import("dsp/equalizer.zig");
    pub const resample = @import("dsp/resample.zig");
    pub const gain = @import("dsp/gain.zig");
    pub const limiter = @import("dsp/limiter.zig");
    pub const analyzer = @import("dsp/analyzer.zig");
    pub const chain = @import("dsp/chain.zig");
};
pub const decode = struct {
    pub const api = @import("decode/api.zig");
    pub const wav = @import("decode/wav.zig");
    pub const flac = @import("decode/flac.zig");
    pub const mp3 = @import("decode/mp3.zig");
    pub const tone = @import("decode/tone.zig");
    pub const source = @import("decode/source.zig");
    pub const decoder = @import("decode/decoder.zig");
};
pub const player = struct {
    pub const playlist = @import("player/playlist.zig");
    pub const library = @import("player/library.zig");
    pub const engine = @import("player/engine.zig");
};
pub const meta = struct {
    pub const tags = @import("meta/tags.zig");
};
pub const cli = @import("cli.zig");
pub const ui = struct {
    pub const term = @import("ui/term.zig");
    pub const screen = @import("ui/screen.zig");
    pub const theme = @import("ui/theme.zig");
    pub const app = @import("ui/app.zig");
};
pub const util = struct {
    pub const time = @import("util/time.zig");
    pub const bits = @import("util/bits.zig");
};
test {
    _ = audio.format;
    _ = audio.ring;
    _ = audio.backend;
    _ = audio.wasapi;
    _ = audio.winmm;
    _ = audio.null_sink;
    _ = audio.wav_sink;
    _ = dsp.biquad;
    _ = dsp.fft;
    _ = dsp.equalizer;
    _ = dsp.resample;
    _ = dsp.gain;
    _ = dsp.limiter;
    _ = dsp.analyzer;
    _ = dsp.chain;
    _ = decode.api;
    _ = decode.wav;
    _ = decode.flac;
    _ = decode.mp3;
    _ = decode.tone;
    _ = decode.source;
    _ = decode.decoder;
    _ = player.playlist;
    _ = player.library;
    _ = player.engine;
    _ = meta.tags;
    _ = cli;
    _ = ui.term;
    _ = ui.screen;
    _ = ui.theme;
    _ = ui.app;
    _ = util.time;
    _ = util.bits;
}
