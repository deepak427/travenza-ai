/**
 * mediaUtils.js - Optimized Audio handling logic for Travenza AI
 */

export class AudioStreamer {
    constructor() {
        this.audioContext = null;
        this.stream = null;
        this.workletNode = null;
    }

    async start(onAudioData) {
        this.audioContext = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 16000 });
        this.stream = await navigator.mediaDevices.getUserMedia({ 
            audio: {
                sampleRate: 16000,
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true
            } 
        });
        
        await this.audioContext.audioWorklet.addModule('/static/audio-processors/capture.worker.js');
        this.workletNode = new AudioWorkletNode(this.audioContext, 'audio-capture-processor');
        
        const source = this.audioContext.createMediaStreamSource(this.stream);
        source.connect(this.workletNode);

        this.workletNode.port.onmessage = (event) => {
            const float32Data = event.data;
            const pcm16 = this.convertToPCM16(float32Data);
            onAudioData(pcm16);
        };

        return source; // Return source for visualizer
    }

    convertToPCM16(float32Array) {
        const int16Array = new Int16Array(float32Array.length);
        for (let i = 0; i < float32Array.length; i++) {
            const sample = Math.max(-1, Math.min(1, float32Array[i]));
            int16Array[i] = sample < 0 ? sample * 0x8000 : sample * 0x7FFF;
        }
        return int16Array.buffer;
    }

    stop() {
        this.stream?.getTracks().forEach(t => t.stop());
        this.audioContext?.close();
    }
}

export class AudioPlayer {
    constructor() {
        this.audioContext = null;
        this.workletNode = null;
        this.sampleRate = 24000;
    }

    async init() {
        this.audioContext = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: this.sampleRate });
        await this.audioContext.audioWorklet.addModule('/static/audio-processors/playback.worker.js');
        this.workletNode = new AudioWorkletNode(this.audioContext, 'playback-processor');
        this.workletNode.connect(this.audioContext.destination);
        return this.workletNode; // Return node for visualizer
    }

    play(arrayBuffer) {
        if (!this.audioContext) return;
        if (this.audioContext.state === 'suspended') this.audioContext.resume();

        const pcm16 = new Int16Array(arrayBuffer);
        const float32 = new Float32Array(pcm16.length);

        const hardwareRate = this.audioContext.sampleRate;
        const ratio = hardwareRate / this.sampleRate;

        if (ratio === 1) {
            for (let i = 0; i < pcm16.length; i++) float32[i] = pcm16[i] / 32768;
            this.workletNode.port.postMessage(float32);
        } else {
            const newLen = Math.floor(pcm16.length * ratio);
            const resampled = new Float32Array(newLen);
            for (let i = 0; i < newLen; i++) {
                const pos = i / ratio;
                const idx = Math.floor(pos);
                const frac = pos - idx;
                const s1 = pcm16[idx] / 32768;
                const s2 = (idx + 1 < pcm16.length) ? pcm16[idx + 1] / 32768 : s1;
                resampled[i] = s1 + (s2 - s1) * frac;
            }
            this.workletNode.port.postMessage(resampled);
        }
    }

    interrupt() {
        this.workletNode?.port.postMessage("clear");
    }

    stop() {
        this.audioContext?.close();
    }
}
