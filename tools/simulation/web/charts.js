export function frameAt(frames, time) {
    let low = 0;
    let high = frames.length - 1;
    while (low < high) {
        const middle = Math.ceil((low + high) / 2);
        if (frames[middle].time <= time) {
            low = middle;
        } else {
            high = middle - 1;
        }
    }
    return low;
}

export function timeLabel(seconds, decimal = false) {
    const minutes = Math.floor(seconds / 60).toString().padStart(2, '0');
    let remainder = Math.floor(seconds % 60).toString().padStart(2, '0');
    if (decimal) {
        remainder = (seconds % 60).toFixed(1).padStart(4, '0');
    }
    return `${minutes}:${remainder}`;
}

function value(frame, channel) {
    if (channel === 'error' || channel === 'adjustment') {
        return frame[channel];
    }
    if (channel === 'speed') {
        return frame.speed * 3.6;
    }
    let number = frame.sample[channel];
    if (['yawRate', 'pitch', 'roll'].includes(channel)) {
        number *= 180 / Math.PI;
    }
    return number;
}

export class SignalChart {
    constructor(canvas, select, seek) {
        this.canvas = canvas;
        this.select = select;
        this.run = null;
        this.time = 0;
        select.addEventListener('change', () => {
            this.draw();
        });
        this.observer = new ResizeObserver(() => {
            this.draw();
        });
        this.observer.observe(canvas);
        canvas.addEventListener('pointerdown', (event) => {
            if (!this.run) {
                return;
            }
            const rect = canvas.getBoundingClientRect();
            const fraction = Math.max(0, Math.min(1, (event.clientX - rect.left - 35) / (rect.width - 43)));
            seek(fraction * this.run.metrics.duration);
        });
    }

    load(run) {
        this.run = run;
        this.draw();
    }

    draw(time = this.time) {
        this.time = time;
        const width = this.canvas.clientWidth;
        const height = this.canvas.clientHeight;
        if (!width || !height) {
            return;
        }
        const ratio = Math.min(devicePixelRatio, 2);
        this.canvas.width = width * ratio;
        this.canvas.height = height * ratio;
        const ctx = this.canvas.getContext('2d');
        ctx.scale(ratio, ratio);
        if (!this.run) {
            return;
        }
        const channel = this.select.value;
        const primary = this.run.frames.map((frame) => {
            return [frame.time, value(frame, channel)];
        });
        const comparison = [];
        if (this.run.comparison) {
            const column = this.run.comparison.columns.indexOf(channel);
            if (column >= 0) {
                for (const row of this.run.comparison.recordedSeries) {
                    let number = row[column];
                    if (['yawRate', 'pitch', 'roll'].includes(channel)) {
                        number *= 180 / Math.PI;
                    }
                    comparison.push([row[0], number]);
                }
            }
        }
        if (channel === 'speed') {
            for (const frame of this.run.frames) {
                if (frame.truthSpeed !== undefined) {
                    comparison.push([frame.time, frame.truthSpeed * 3.6]);
                }
            }
        }
        const values = primary.concat(comparison).map((row) => {
            return row[1];
        }).filter((number) => {
            return number !== null && Number.isFinite(number);
        });
        if (!values.length) {
            ctx.fillStyle = '#879bb0';
            ctx.font = '11px sans-serif';
            ctx.fillText('No measured field truth', 16, 50);
            return;
        }
        let min = Math.min(0, ...values);
        let max = Math.max(0.01, ...values);
        const padding = (max - min) * 0.1;
        min -= padding;
        max += padding;
        const left = 35;
        const bottom = height - 20;
        const x = (seconds) => {
            return left + seconds / this.run.metrics.duration * (width - left - 8);
        };
        const y = (number) => {
            return bottom - (number - min) / (max - min) * (bottom - 8);
        };
        ctx.font = '9px ui-monospace, monospace';
        ctx.strokeStyle = '#263241';
        ctx.fillStyle = '#8294a9';
        for (let i = 0; i <= 2; i += 1) {
            const number = min + (max - min) * i / 2;
            const position = y(number);
            ctx.beginPath();
            ctx.moveTo(left, position);
            ctx.lineTo(width - 8, position);
            ctx.stroke();
            ctx.fillText(number.toFixed(1), 0, position + 3);
        }
        ctx.fillText('0:00', left, height - 3);
        ctx.fillText(timeLabel(this.run.metrics.duration), width - 40, height - 3);
        const drawLine = (series, color, opacity) => {
            ctx.strokeStyle = color;
            ctx.globalAlpha = opacity;
            ctx.lineWidth = 1;
            ctx.beginPath();
            let started = false;
            for (const [seconds, number] of series) {
                if (number === null || !Number.isFinite(number)) {
                    started = false;
                    continue;
                }
                if (!started) {
                    ctx.moveTo(x(seconds), y(number));
                    started = true;
                } else {
                    ctx.lineTo(x(seconds), y(number));
                }
            }
            ctx.stroke();
            ctx.globalAlpha = 1;
        };
        drawLine(comparison, '#73e3cc', 0.65);
        drawLine(primary, '#ffbd69', 0.95);
        for (const event of this.run.events) {
            if (event.stage === 'accepted') {
                ctx.fillStyle = '#c4a1ff';
                ctx.fillRect(x(event.time) - 1, 3, 2, 5);
            }
        }
        ctx.strokeStyle = '#ecf5ff';
        ctx.globalAlpha = 0.65;
        ctx.beginPath();
        ctx.moveTo(x(time), 0);
        ctx.lineTo(x(time), bottom);
        ctx.stroke();
        ctx.globalAlpha = 1;
    }
}
