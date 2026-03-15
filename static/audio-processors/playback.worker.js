/**
 * Audio Worklet Processor for playing PCM audio (24kHz typically)
 * Dedicated interrupt handling to clear buffer instantly.
 */
class PlaybackProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.audioQueue = [];
    this.port.onmessage = (event) => {
      if (event.data === "clear") {
        this.audioQueue = []; // Instant interruption
      } else if (event.data instanceof Float32Array) {
        this.audioQueue.push(event.data);
      }
    };
  }

  process(inputs, outputs, parameters) {
    const output = outputs[0];
    const channel = output[0];
    let outputIndex = 0;

    // Fill the current hardware output buffer from our internal queue
    while (outputIndex < channel.length && this.audioQueue.length > 0) {
      const currentBuffer = this.audioQueue[0];
      const itemsToCopy = Math.min(channel.length - outputIndex, currentBuffer.length);

      for (let i = 0; i < itemsToCopy; i++) {
        channel[outputIndex++] = currentBuffer[i];
      }

      // If we finished the current buffer in the queue, remove it.
      // Otherwise, slice it for the next process call.
      if (itemsToCopy < currentBuffer.length) {
        this.audioQueue[0] = currentBuffer.slice(itemsToCopy);
      } else {
        this.audioQueue.shift();
      }
    }

    // Fill remaining space with silence if queue is empty
    while (outputIndex < channel.length) {
      channel[outputIndex++] = 0;
    }

    return true;
  }
}

registerProcessor("playback-processor", PlaybackProcessor);
