// YouTube chooses which codec to send from what the browser claims it can play,
// and it prefers VP9. Nothing on a Pi decodes VP9 in hardware, so every frame of
// it is assembled on the processor — that is what made 1080p stutter after a few
// hours, and what dropping to 720p was papering over.
//
// H.264 is different: a Pi 4 has a dedicated decoder for it, and even without
// one it is far cheaper to decode than VP9. So deny VP9 and AV1 and YouTube
// falls back to H.264 on its own, and the panel keeps its full resolution.
//
// Only the video codecs are denied. Audio stays untouched, or we would be
// picking a fight over Opus for no reason.
const DENIED = /vp0?[89]|av01/i;

const isTypeSupported = window.MediaSource && MediaSource.isTypeSupported;
if (isTypeSupported) {
  MediaSource.isTypeSupported = type =>
    DENIED.test(type) ? false : isTypeSupported.call(MediaSource, type);
}

const canPlayType = HTMLMediaElement.prototype.canPlayType;
HTMLMediaElement.prototype.canPlayType = function (type) {
  return DENIED.test(type) ? '' : canPlayType.call(this, type);
};
