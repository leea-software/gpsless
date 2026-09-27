import { ReplayScene } from './scene.js';
import { SignalChart, frameAt, timeLabel } from './charts.js';

const element = (id) => {
    return document.getElementById(id);
};
let runs = [];
let current = null;
let filter = 'all';
let playing = false;
let playhead = 0;
let lastTick = performance.now();
let loadRequest = 0;
let scene = null;
let lastJobState = '';
let roadNames = new Map();
let lastChartTick = -1;

function notice(message) {
    element('notice').textContent = message;
    element('notice').hidden = !message;
}

try {
    scene = new ReplayScene(element('scene'));
} catch (error) {
    element('scene-error').hidden = false;
    element('scene-error').textContent = `3D is unavailable: ${error.message}. The sensor charts and run diagnostics remain available.`;
}

const charts = ['a', 'b', 'c'].map((suffix) => {
    return new SignalChart(element(`chart-${suffix}`), element(`channel-${suffix}`), (time) => {
        pause();
        seek(time);
    });
});

async function request(url, options) {
    const response = await fetch(url, options);
    const data = await response.json();
    if (!response.ok) {
        throw new Error(data.error || `Request failed: ${response.status}`);
    }
    return data;
}

function pause() {
    playing = false;
    element('play').textContent = '▶';
    element('play').setAttribute('aria-label', 'Play replay');
}

function labelKind(kind) {
    if (kind === 'recorded') {
        return 'Field recording';
    }
    if (kind === 'reconstruction') {
        return 'Field comparison';
    }
    return 'Synthetic truth';
}

function renderLibrary() {
    element('run-count').textContent = runs.length;
    element('runs').replaceChildren();
    const visible = runs.filter((run) => {
        if (filter === 'recorded') {
            return run.kind !== 'synthetic';
        }
        if (filter === 'synthetic') {
            return run.kind === 'synthetic';
        }
        return true;
    });
    if (!visible.length) {
        const empty = document.createElement('p');
        empty.className = 'empty';
        empty.textContent = 'No runs here yet. Generate a simulation or import a recording with the local command-line tool.';
        element('runs').append(empty);
    }
    for (const run of visible) {
        const button = document.createElement('button');
        button.className = 'run-card';
        if (current && current.id === run.id) {
            button.classList.add('active');
            button.setAttribute('aria-current', 'true');
        }
        const top = document.createElement('div');
        top.className = 'run-card-top';
        const kind = document.createElement('span');
        kind.textContent = labelKind(run.kind);
        const state = document.createElement('span');
        state.className = 'ok';
        state.textContent = 'COMPLETE';
        if (run.metrics.failure) {
            state.className = 'fail';
            state.textContent = 'RESET';
        }
        top.append(kind, state);
        const title = document.createElement('strong');
        title.textContent = run.name;
        const detail = document.createElement('small');
        let metric = 'No field truth';
        if (run.metrics.p95Error !== null) {
            metric = `p95 ${run.metrics.p95Error.toFixed(1)} m`;
            if (run.kind === 'reconstruction') {
                metric = `simulated ${metric}`;
            }
        }
        detail.textContent = `${timeLabel(run.metrics.duration)} · ${run.metrics.acceptedTurns} corrections · ${metric}`;
        button.append(top, title, detail);
        button.addEventListener('click', () => {
            loadRun(run.id).catch((error) => {
                notice(error.message);
            });
        });
        element('runs').append(button);
    }
}

function renderEvents() {
    const container = element('events');
    container.replaceChildren();
    const events = current.events.filter((event) => {
        return event.stage !== 'detected';
    });
    element('event-count').textContent = events.length;
    if (!events.length) {
        const empty = document.createElement('p');
        empty.className = 'empty';
        empty.textContent = 'No completed turn decisions in this run. Continuous road weighting may still adjust position.';
        container.append(empty);
    }
    for (const event of events) {
        const button = document.createElement('button');
        button.className = 'event';
        const time = document.createElement('time');
        time.textContent = timeLabel(event.time);
        const details = document.createElement('div');
        const title = document.createElement('strong');
        let label = 'Rejected';
        if (event.stage === 'accepted') {
            label = 'Corrected';
        }
        title.textContent = `${label} · ${Math.round(event.observedTurnDegrees)}° turn`;
        const description = document.createElement('small');
        let adjustment = 0;
        if (event.roadMatch) {
            adjustment = event.roadMatch.positionAdjustmentMetres;
        }
        description.textContent = `Map ${Math.round(event.mappedTurnDegrees)}° · adjustment ${adjustment.toFixed(1)} m`;
        button.title = event.reason;
        details.append(title, description);
        button.append(time, details);
        button.addEventListener('click', () => {
            pause();
            seek(event.time);
        });
        container.append(button);
    }
    if (current.metrics.failure) {
        const button = document.createElement('button');
        button.className = 'event fail';
        button.textContent = `${timeLabel(current.metrics.failure.time)} · Tracking stopped: ${current.metrics.failure.reason}`;
        button.addEventListener('click', () => {
            pause();
            seek(current.metrics.failure.time);
        });
        container.append(button);
    }
}

function renderComparison() {
    const comparison = current.comparison;
    element('comparison-panel').hidden = !comparison;
    element('comparison-legend').hidden = !comparison;
    element('comparison-table').replaceChildren();
    if (!comparison) {
        return;
    }
    element('comparison-note').textContent = comparison.interpretation;
    for (const metric of comparison.metrics) {
        const row = document.createElement('tr');
        const values = [metric.label + ` (${metric.units})`, metric.recordedRMS.toFixed(3), metric.simulatedRMS.toFixed(3), metric.recordedP95Absolute.toFixed(3), metric.simulatedP95Absolute.toFixed(3)];
        for (const value of values) {
            const cell = document.createElement('td');
            cell.textContent = value;
            row.append(cell);
        }
        element('comparison-table').append(row);
    }
}

async function loadRun(id) {
    const token = ++loadRequest;
    pause();
    element('run-title').textContent = 'Loading run…';
    const run = await request(`/runs/${encodeURIComponent(id)}/replay.json`);
    if (token !== loadRequest) {
        return;
    }
    current = run;
    roadNames = new Map(run.roads.map((road) => {
        return [road.id, road.name];
    }));
    element('run-title').textContent = run.name;
    element('run-type').textContent = `${labelKind(run.kind).toUpperCase()} / ${run.provenance.engine}`;
    element('truth-note').textContent = run.provenance.groundTruth;
    element('reference-label').textContent = 'Simulated car';
    element('error-label').textContent = 'Position error';
    element('error-unit').textContent = 'metres from synthetic truth';
    if (run.kind === 'recorded') {
        element('reference-label').textContent = `Original ${run.provenance.recordedEngine}`;
        element('error-label').textContent = 'Field error';
        element('error-unit').textContent = 'no independent truth';
    }
    element('scrubber').max = run.metrics.duration;
    element('scrubber').disabled = false;
    element('play').disabled = false;
    element('restart').disabled = false;
    element('duration').textContent = timeLabel(run.metrics.duration);
    element('export-run').href = `/runs/${encodeURIComponent(id)}/replay.json`;
    element('follow-view').setAttribute('aria-pressed', 'false');
    if (scene) {
        scene.load(run);
        element('drive-view').setAttribute('aria-pressed', 'true');
        document.querySelector('.drive-hud').hidden = false;
    }
    for (const chart of charts) {
        chart.load(run);
    }
    renderLibrary();
    renderEvents();
    renderComparison();
    seek(0);
}

function seek(time) {
    if (!current) {
        return;
    }
    playhead = Math.max(0, Math.min(current.metrics.duration, time));
    const index = frameAt(current.frames, playhead);
    const frame = current.frames[index];
    let reference = null;
    if (current.original && current.original.length) {
        const referenceIndex = frameAt(current.original, playhead);
        const first = current.original[referenceIndex];
        const next = current.original[Math.min(referenceIndex + 1, current.original.length - 1)];
        const fraction = Math.max(0, Math.min(1, (playhead - first.time) / Math.max(0.001, next.time - first.time)));
        reference = { ...first };
        reference.position = first.position.map((coordinate, axis) => {
            return coordinate + (next.position[axis] - coordinate) * fraction;
        });
        if (first.heading !== undefined && next.heading !== undefined) {
            reference.heading = first.heading + Math.atan2(Math.sin(next.heading - first.heading), Math.cos(next.heading - first.heading)) * fraction;
        }
    }
    element('scrubber').value = playhead;
    element('time').textContent = timeLabel(playhead, true);
    element('speed-value').textContent = (frame.speed * 3.6).toFixed(1);
    element('truth-speed').textContent = 'km/h · estimated';
    if (frame.truthSpeed !== undefined) {
        element('truth-speed').textContent = `true ${(frame.truthSpeed * 3.6).toFixed(1)} km/h`;
    }
    element('error-value').textContent = '—';
    if (frame.error !== null) {
        element('error-value').textContent = frame.error.toFixed(1);
    }
    element('probability').textContent = `${(frame.probability * 100).toFixed(1)}%`;
    element('uncertainty').textContent = `${frame.uncertainty.toFixed(1)} m`;
    element('anchors').textContent = frame.anchors;
    element('edge').textContent = frame.edge;
    element('tracking-state').textContent = frame.status;
    element('road-name').textContent = roadNames.get(frame.edge) || 'KYIV · LOCAL ROAD';
    element('hypotheses').replaceChildren();
    for (const hypothesis of frame.hypotheses) {
        const row = document.createElement('div');
        row.textContent = `${hypothesis.edge} · ${(hypothesis.probability * 100).toFixed(1)}% · ${(hypothesis.speed * 3.6).toFixed(1)} km/h`;
        element('hypotheses').append(row);
    }
    if (scene) {
        const display = { ...frame, time: playhead };
        const next = current.frames[Math.min(index + 1, current.frames.length - 1)];
        const fraction = Math.min(1, Math.max(0, (playhead - frame.time) / Math.max(0.001, next.time - frame.time)));
        if (frame.truth && next.truth) {
            display.truth = frame.truth.map((coordinate, axis) => {
                return coordinate + (next.truth[axis] - coordinate) * fraction;
            });
            display.truthHeading = frame.truthHeading + Math.atan2(Math.sin(next.truthHeading - frame.truthHeading), Math.cos(next.truthHeading - frame.truthHeading)) * fraction;
            for (const key of ['truthSpeed', 'truthPitch', 'truthRoll', 'truthProgress']) {
                if (frame[key] !== undefined) {
                    display[key] = frame[key] + (next[key] - frame[key]) * fraction;
                }
            }
        }
        scene.update(display, index, reference);
    }
    let displayedSpeed = frame.speed;
    element('hud-kind').textContent = 'REPLAYED ESTIMATE';
    if (frame.truthSpeed !== undefined) {
        displayedSpeed = frame.truthSpeed;
        element('hud-kind').textContent = 'SIMULATED DRIVE';
    }
    element('hud-speed').textContent = Math.round(displayedSpeed * 3.6);
    if (!document.body.classList.contains('cinema') && (!playing || Math.floor(playhead * 10) !== lastChartTick)) {
        for (const chart of charts) {
            chart.draw(playhead);
        }
        lastChartTick = Math.floor(playhead * 10);
    }
}

function animate(now) {
    const elapsed = Math.min((now - lastTick) / 1000, 0.25);
    lastTick = now;
    if (playing && current) {
        seek(playhead + elapsed * Number(element('speed').value));
        if (playhead >= current.metrics.duration) {
            pause();
        }
    }
    requestAnimationFrame(animate);
}

element('play').addEventListener('click', () => {
    if (playing) {
        pause();
        return;
    }
    if (playhead >= current.metrics.duration) {
        seek(0);
    }
    playing = true;
    lastTick = performance.now();
    element('play').textContent = 'Ⅱ';
    element('play').setAttribute('aria-label', 'Pause replay');
});
element('restart').addEventListener('click', () => {
    pause();
    seek(0);
});
element('scrubber').addEventListener('input', (event) => {
    pause();
    seek(Number(event.target.value));
});
document.addEventListener('keydown', (event) => {
    if (['INPUT', 'SELECT', 'TEXTAREA', 'BUTTON'].includes(event.target.tagName) || document.querySelector('dialog[open]')) {
        return;
    }
    if (event.code === 'Space' && current) {
        event.preventDefault();
        element('play').click();
    }
    if (event.code === 'ArrowRight' || event.code === 'ArrowLeft') {
        event.preventDefault();
        pause();
        let step = 1;
        if (event.code === 'ArrowLeft') {
            step = -1;
        }
        seek(playhead + step);
    }
});
for (const button of document.querySelectorAll('[data-filter]')) {
    button.addEventListener('click', () => {
        filter = button.dataset.filter;
        for (const item of document.querySelectorAll('[data-filter]')) {
            item.classList.toggle('selected', item === button);
        }
        renderLibrary();
    });
}
element('fit-view').addEventListener('click', () => {
    if (scene && current) {
        scene.fit();
        element('follow-view').setAttribute('aria-pressed', 'false');
        element('drive-view').setAttribute('aria-pressed', 'false');
        element('scene-caption').textContent = 'Drag to orbit · scroll to zoom · right-drag to pan';
        document.querySelector('.drive-hud').hidden = true;
    }
});
element('top-view').addEventListener('click', () => {
    if (scene && current) {
        scene.fit(true);
        element('follow-view').setAttribute('aria-pressed', 'false');
        element('drive-view').setAttribute('aria-pressed', 'false');
        document.querySelector('.drive-hud').hidden = true;
    }
});
element('follow-view').addEventListener('click', () => {
    if (!scene || !current) {
        return;
    }
    const follow = !scene.follow;
    scene.fit();
    scene.follow = follow;
    if (scene.follow) {
        scene.camera.position.copy(scene.controls.target).add({ x: 20, y: 65, z: 55 });
    }
    element('follow-view').setAttribute('aria-pressed', String(scene.follow));
    element('drive-view').setAttribute('aria-pressed', 'false');
    document.querySelector('.drive-hud').hidden = true;
    seek(playhead);
});
element('drive-view').addEventListener('click', () => {
    if (!scene || !current) {
        return;
    }
    scene.drive();
    element('drive-view').setAttribute('aria-pressed', 'true');
    element('follow-view').setAttribute('aria-pressed', 'false');
    element('scene-caption').textContent = 'Third-person camera · select Fit route to orbit freely';
    document.querySelector('.drive-hud').hidden = false;
    seek(playhead);
});
element('cinema-view').addEventListener('click', () => {
    if (!scene || !current) {
        return;
    }
    const enabled = document.body.classList.toggle('cinema');
    scene.clean = enabled;
    element('cinema-view').textContent = 'Cinema ↗';
    if (enabled) {
        element('cinema-view').textContent = 'Exit cinema ↙';
    }
    element('cinema-view').setAttribute('aria-pressed', String(enabled));
    element('drive-view').click();
});
element('new-run').addEventListener('click', () => {
    pause();
    element('simulation-dialog').showModal();
});
for (const button of document.querySelectorAll('[data-close]')) {
    button.addEventListener('click', () => {
        element(button.dataset.close).close();
    });
}
element('details-button').addEventListener('click', () => {
    if (!current) {
        return;
    }
    pause();
    const container = element('run-details');
    container.replaceChildren();
    const note = document.createElement('p');
    note.textContent = current.provenance.groundTruth;
    container.append(note);
    let files = ['replay.json', 'engine.jsonl.gz'];
    if (current.kind !== 'recorded') {
        files = files.concat(['scenario.json', 'sensors.jsonl.gz', 'truth.npz']);
    }
    for (const file of files) {
        const link = document.createElement('a');
        link.href = `/runs/${encodeURIComponent(current.id)}/${file}`;
        link.download = file;
        link.textContent = `${file} ↓`;
        container.append(link);
    }
    const pre = document.createElement('pre');
    pre.textContent = JSON.stringify({ metrics: current.metrics, provenance: current.provenance, reconstruction: current.reconstruction }, null, 2);
    container.append(pre);
    element('details-dialog').showModal();
});

async function launch(options) {
    await request('/api/run', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(options) });
    lastJobState = '';
    await pollJob();
}

element('simulation-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const data = new FormData(event.target);
    const options = {};
    for (const [key, value] of data.entries()) {
        if (key === 'profile') {
            options[key] = value;
        } else {
            options[key] = Number(value);
        }
    }
    element('form-error').textContent = '';
    try {
        await launch(options);
        element('simulation-dialog').close();
    } catch (error) {
        element('form-error').textContent = error.message;
    }
});
element('start-area').addEventListener('change', (event) => {
    document.querySelector('input[name="startEdge"]').value = event.target.value;
});
element('batch-run').addEventListener('click', () => {
    launch({ seed: 100, count: 6, length: 1000, speedKmh: 40 }).catch((error) => {
        notice(error.message);
    });
});

async function refreshLibrary() {
    runs = await request('/api/runs');
    renderLibrary();
}

async function pollJob() {
    try {
        const job = await request('/api/job');
        const running = job.state === 'running';
        element('new-run').disabled = running;
        element('batch-run').disabled = running;
        if (running) {
            element('job-status').textContent = `Simulating · ${job.completed} / ${job.total} completed`;
        } else if (job.state !== 'idle') {
            element('job-status').textContent = `${job.completed} / ${job.total} trials completed`;
        }
        if (job.state !== lastJobState && ['complete', 'completed_with_errors', 'failed'].includes(job.state)) {
            await refreshLibrary();
            const errors = job.results.filter((result) => {
                return Boolean(result.error);
            });
            if (job.error || errors.length) {
                let message = job.error;
                if (!message) {
                    message = errors.map((result) => {
                        return result.error;
                    }).join(' · ');
                }
                notice(message);
            } else {
                notice('Simulation finished. The new runs are saved in your library.');
            }
            const valid = job.results.find((result) => {
                return Boolean(result.id);
            });
            if (valid) {
                await loadRun(valid.id);
            }
        }
        lastJobState = job.state;
    } catch (error) {
        element('job-status').textContent = 'Local server unavailable';
    }
}

async function initialize() {
    await refreshLibrary();
    let selected = runs.find((run) => {
        return run.kind === 'synthetic' && run.provenance.profile.name === 'nominal';
    });
    if (!selected) {
        selected = runs[0];
    }
    if (selected) {
        await loadRun(selected.id);
    }
    await pollJob();
}

initialize().catch((error) => {
    notice(error.message);
    element('run-title').textContent = 'Unable to load local runs';
});
setInterval(pollJob, 3000);
requestAnimationFrame(animate);
