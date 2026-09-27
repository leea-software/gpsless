import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { createVehicle, createScenery } from './driving.js';

const eastScale = 111320 * Math.cos(50.45 * Math.PI / 180);

function coordinatePoint(coordinate) {
    return [(coordinate.longitude - 30.52) * eastScale, (coordinate.latitude - 50.45) * 111320];
}

export class ReplayScene {
    constructor(container) {
        this.container = container;
        this.scene = new THREE.Scene();
        this.scene.background = new THREE.Color('#101923');
        this.camera = new THREE.PerspectiveCamera(45, 1, 0.5, 20000);
        this.renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'low-power' });
        this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
        this.renderer.setClearColor('#101923');
        this.renderer.shadowMap.enabled = true;
        this.renderer.shadowMap.type = THREE.PCFShadowMap;
        this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
        this.renderer.toneMappingExposure = 1.15;
        container.prepend(this.renderer.domElement);
        this.controls = new OrbitControls(this.camera, this.renderer.domElement);
        this.controls.enableDamping = false;
        this.controls.maxPolarAngle = Math.PI * 0.49;
        this.controls.minDistance = 12;
        this.controls.maxDistance = 7000;
        this.controls.addEventListener('change', () => {
            this.render();
        });
        this.scene.add(new THREE.HemisphereLight(0xcce8ff, 0x243349, 2.2));
        const sun = new THREE.DirectionalLight(0xffe3ba, 3);
        sun.position.set(-200, 600, 250);
        sun.castShadow = true;
        sun.shadow.mapSize.set(1024, 1024);
        sun.shadow.camera.left = -65;
        sun.shadow.camera.right = 65;
        sun.shadow.camera.top = 65;
        sun.shadow.camera.bottom = -65;
        sun.shadow.camera.near = 1;
        sun.shadow.camera.far = 300;
        sun.shadow.normalBias = 0.05;
        this.scene.add(sun);
        this.scene.add(sun.target);
        this.sun = sun;
        this.content = new THREE.Group();
        this.scene.add(this.content);
        this.follow = false;
        this.chase = false;
        this.clean = false;
        this.origin = [0, 0];
        this.corrections = [];
        this.resizeObserver = new ResizeObserver(() => {
            const width = container.clientWidth;
            const height = container.clientHeight;
            this.renderer.setSize(width, height);
            this.camera.aspect = width / height;
            this.camera.updateProjectionMatrix();
            this.render();
        });
        this.resizeObserver.observe(container);
        this.renderer.domElement.addEventListener('webglcontextlost', (event) => {
            event.preventDefault();
            const message = document.getElementById('scene-error');
            message.textContent = 'The 3D graphics context was lost. Reload this page to restore the viewer. Run data is saved locally.';
            message.hidden = false;
        });
    }

    point(xy, height = 0) {
        return new THREE.Vector3(xy[0] - this.origin[0], height, -(xy[1] - this.origin[1]));
    }

    clear() {
        this.content.traverse((object) => {
            if (object.geometry) {
                object.geometry.dispose();
            }
            if (object.material) {
                const materials = [].concat(object.material);
                for (const material of materials) {
                    if (material.map) {
                        material.map.dispose();
                    }
                    material.dispose();
                }
            }
        });
        this.content.clear();
        this.corrections = [];
    }

    line(points, color, height, opacity = 1) {
        const vertices = points.map((xy) => {
            return this.point(xy, height);
        });
        const geometry = new THREE.BufferGeometry().setFromPoints(vertices);
        const line = new THREE.Line(geometry, new THREE.LineBasicMaterial({ color, transparent: true, opacity }));
        this.content.add(line);
        return line;
    }

    car(color) {
        const group = createVehicle(color);
        this.content.add(group);
        return group;
    }

    load(run) {
        this.clear();
        this.run = run;
        const points = run.frames.map((frame) => {
            return frame.estimate;
        });
        const reference = [];
        for (const frame of run.frames) {
            if (frame.truth) {
                reference.push(frame.truth);
            }
        }
        if (run.original) {
            for (const row of run.original) {
                reference.push(row.position);
            }
        }
        const all = points.concat(reference);
        const minX = Math.min(...all.map((point) => {
            return point[0];
        }));
        const maxX = Math.max(...all.map((point) => {
            return point[0];
        }));
        const minY = Math.min(...all.map((point) => {
            return point[1];
        }));
        const maxY = Math.max(...all.map((point) => {
            return point[1];
        }));
        this.origin = [(minX + maxX) / 2, (minY + maxY) / 2];
        this.extent = Math.max(maxX - minX, maxY - minY, 120);
        this.scenery = createScenery(run.roads, this.origin, this.extent);
        this.content.add(this.scenery);
        const gridSize = Math.ceil((this.extent + 500) / 100) * 100;
        const grid = new THREE.GridHelper(gridSize, gridSize / 50, 0x273748, 0x1b2a39);
        grid.position.y = -0.2;
        this.content.add(grid);
        this.grid = grid;
        const vertices = [];
        const shoulders = [];
        const centerLines = [];
        for (const road of run.roads) {
            let width = 5;
            if (['primary', 'secondary', 'trunk', 'motorway'].includes(road.kind)) {
                width = 9;
            }
            for (let i = 1; i < road.points.length; i += 1) {
                const a = this.point(road.points[i - 1], 0.08);
                const b = this.point(road.points[i], 0.08);
                const direction = b.clone().sub(a).normalize();
                const perpendicular = new THREE.Vector3(-direction.z, 0, direction.x).multiplyScalar(width / 2);
                const corners = [a.clone().add(perpendicular), a.clone().sub(perpendicular), b.clone().add(perpendicular), b.clone().sub(perpendicular)];
                for (const index of [0, 2, 1, 1, 2, 3]) {
                    vertices.push(...corners[index].toArray());
                }
                const shoulder = perpendicular.clone().normalize().multiplyScalar(width / 2 + 1.5);
                const outer = [a.clone().add(shoulder), a.clone().sub(shoulder), b.clone().add(shoulder), b.clone().sub(shoulder)];
                for (const index of [0, 2, 1, 1, 2, 3]) {
                    shoulders.push(outer[index].x, 0.015, outer[index].z);
                }
                centerLines.push(a.x, 0.09, a.z, b.x, 0.09, b.z);
            }
        }
        const roadGeometry = new THREE.BufferGeometry();
        roadGeometry.setAttribute('position', new THREE.Float32BufferAttribute(vertices, 3));
        roadGeometry.computeVertexNormals();
        const shoulderGeometry = new THREE.BufferGeometry();
        shoulderGeometry.setAttribute('position', new THREE.Float32BufferAttribute(shoulders, 3));
        shoulderGeometry.computeVertexNormals();
        this.shoulders = new THREE.Mesh(shoulderGeometry, new THREE.MeshStandardMaterial({ color: 0x9b9f99, side: THREE.DoubleSide, roughness: 1 }));
        this.shoulders.receiveShadow = true;
        this.content.add(this.shoulders);
        const roadSurface = new THREE.Mesh(roadGeometry, new THREE.MeshStandardMaterial({ color: 0x30404f, side: THREE.DoubleSide, roughness: 1 }));
        roadSurface.receiveShadow = true;
        this.content.add(roadSurface);
        const centerGeometry = new THREE.BufferGeometry();
        centerGeometry.setAttribute('position', new THREE.Float32BufferAttribute(centerLines, 3));
        const center = new THREE.LineSegments(centerGeometry, new THREE.LineDashedMaterial({ color: 0x536477, dashSize: 3, gapSize: 4, transparent: true, opacity: 0.45 }));
        center.computeLineDistances();
        this.content.add(center);
        const ribbonVertices = [];
        for (let index = 1; index < reference.length; index += 1) {
            const a = this.point(reference[index - 1], 0.26);
            const b = this.point(reference[index], 0.26);
            const direction = b.clone().sub(a).normalize();
            const side = new THREE.Vector3(-direction.z, 0, direction.x).multiplyScalar(1.25);
            const corners = [a.clone().add(side), a.clone().sub(side), b.clone().add(side), b.clone().sub(side)];
            for (const corner of [0, 2, 1, 1, 2, 3]) {
                ribbonVertices.push(...corners[corner].toArray());
            }
        }
        const ribbon = new THREE.BufferGeometry();
        ribbon.setAttribute('position', new THREE.Float32BufferAttribute(ribbonVertices, 3));
        this.ribbon = new THREE.Mesh(ribbon, new THREE.MeshBasicMaterial({ color: 0x73e3cc, side: THREE.DoubleSide, transparent: true, opacity: 0.35 }));
        this.content.add(this.ribbon);
        this.referenceLine = this.line(reference, 0x73e3cc, 0.3, 0.95);
        this.fullEstimateTrail = this.line(points, 0xffbd69, 0.45, 0.22);
        this.estimateTrail = this.line(points, 0xffbd69, 0.55);
        this.truthCar = this.car(0x73e3cc);
        this.estimateCar = this.car(0xffbd69);
        this.disagreement = this.line([[0, 0], [0, 0]], 0xffbd69, 0.8, 0.8);
        this.disagreement.geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(6), 3));
        const uncertaintyGeometry = new THREE.RingGeometry(0.99, 1, 100);
        uncertaintyGeometry.rotateX(-Math.PI / 2);
        this.uncertainty = new THREE.Mesh(uncertaintyGeometry, new THREE.MeshBasicMaterial({ color: 0xffbd69, transparent: true, opacity: 0.35, side: THREE.DoubleSide }));
        this.content.add(this.uncertainty);
        for (const event of run.events) {
            if (event.stage !== 'accepted' || !event.roadMatch) {
                continue;
            }
            const match = event.roadMatch;
            const a = this.point(coordinatePoint(match.predictionBeforeRoadEvidence), 1.5);
            const b = this.point(coordinatePoint(match.result.coordinate), 1.5);
            const direction = b.clone().sub(a);
            const length = direction.length();
            const markerGeometry = new THREE.RingGeometry(3.1, 3.7, 28);
            markerGeometry.rotateX(-Math.PI / 2);
            const marker = new THREE.Mesh(markerGeometry, new THREE.MeshBasicMaterial({ color: 0xc4a1ff, side: THREE.DoubleSide }));
            marker.position.copy(b);
            marker.position.y = 0.2;
            this.content.add(marker);
            if (length > 0.05) {
                const arrow = new THREE.ArrowHelper(direction.normalize(), a, length, 0xc4a1ff, Math.min(4, length / 3), Math.min(2, length / 5));
                this.content.add(arrow);
                this.corrections.push({ time: event.time, marker: arrow });
            }
            this.corrections.push({ time: event.time, marker });
        }
        this.drive();
    }

    fit(top = false) {
        this.follow = false;
        this.chase = false;
        this.controls.enabled = true;
        this.camera.fov = 45;
        this.camera.updateProjectionMatrix();
        this.scene.background.set('#101923');
        this.scene.fog = null;
        this.scenery.visible = false;
        this.shoulders.visible = false;
        this.grid.visible = true;
        this.controls.target.set(0, 0, 0);
        const distance = this.extent / Math.min(1, this.camera.aspect) * 1.05;
        this.camera.position.set(distance * 0.25, distance * 0.95, distance * 0.7);
        if (top) {
            this.camera.position.set(0, distance * 1.35, 0.01);
        }
        this.controls.update();
        this.render();
    }

    drive() {
        this.chase = true;
        this.follow = false;
        this.controls.enabled = false;
        this.camera.fov = 62;
        this.camera.updateProjectionMatrix();
        this.scene.background.set('#aecad7');
        this.scene.fog = new THREE.Fog('#aecad7', 130, 680);
        this.scenery.visible = true;
        this.shoulders.visible = true;
        this.grid.visible = false;
        this.previousFrameTime = null;
    }

    update(frame, index, reference) {
        if (!this.run) {
            return;
        }
        this.estimateTrail.geometry.setDrawRange(0, index + 1);
        this.estimateCar.position.copy(this.point(frame.estimate, 0.07));
        this.estimateCar.rotation.set(0, -frame.heading, 0);
        let actual = frame.truth;
        let heading = frame.truthHeading;
        if (!actual && reference) {
            actual = reference.position;
            heading = reference.heading ?? frame.heading;
        }
        this.truthCar.visible = Boolean(actual);
        this.disagreement.visible = Boolean(actual);
        if (actual) {
            this.truthCar.position.copy(this.point(actual, 0.07 + (frame.truthHeight || 0)));
            this.truthCar.rotation.set(frame.truthPitch || 0, -heading, -(frame.truthRoll || 0), 'YXZ');
            const positions = this.disagreement.geometry.attributes.position;
            const a = this.point(actual, 1);
            const b = this.point(frame.estimate, 1);
            positions.setXYZ(0, a.x, a.y, a.z);
            positions.setXYZ(1, b.x, b.y, b.z);
            positions.needsUpdate = true;
            this.disagreement.geometry.computeBoundingSphere();
        }
        this.uncertainty.position.copy(this.point(frame.estimate, 0.15));
        this.uncertainty.scale.setScalar(Math.max(0.1, frame.uncertainty));
        this.estimateCar.visible = !this.clean;
        this.uncertainty.visible = !this.clean;
        this.disagreement.visible = Boolean(actual) && !this.clean;
        this.ribbon.visible = !this.clean;
        this.referenceLine.visible = !this.clean;
        this.estimateTrail.visible = !this.clean;
        this.fullEstimateTrail.visible = !this.clean;
        for (const event of this.corrections) {
            event.marker.visible = !this.clean;
            let scale = 1;
            if (Math.abs(event.time - frame.time) < 2) {
                scale = 2;
            }
            event.marker.scale.setScalar(scale);
        }
        for (const car of [this.truthCar, this.estimateCar]) {
            for (const wheel of car.userData.wheels) {
                let distance = frame.time * frame.speed;
                if (frame.truthProgress !== undefined) {
                    distance = frame.truthProgress;
                }
                wheel.wheel.rotation.x = -distance / 0.39;
                if (wheel.front) {
                    wheel.steering.rotation.y = -Math.atan(2.7 * frame.sample.yawRate / Math.max(1, frame.speed));
                }
            }
        }
        if (this.chase && actual) {
            const car = this.point(actual, 0);
            const forward = new THREE.Vector3(Math.sin(heading), 0, -Math.cos(heading));
            const desired = car.clone().addScaledVector(forward, -12.5).add(new THREE.Vector3(0, 4.8, 0));
            const target = car.clone().addScaledVector(forward, 10).add(new THREE.Vector3(0, 1.1, 0));
            let factor = 1;
            if (this.previousFrameTime !== null && Math.abs(frame.time - this.previousFrameTime) < 0.5) {
                factor = 1 - Math.exp(-Math.max(0.016, frame.time - this.previousFrameTime) / 0.12);
            }
            this.camera.position.lerp(desired, factor);
            this.camera.lookAt(target);
            this.controls.target.copy(target);
            this.sun.target.position.copy(car);
            this.sun.position.copy(car).add(new THREE.Vector3(-55, 90, 40));
            this.previousFrameTime = frame.time;
        }
        if (this.follow) {
            const target = this.estimateCar.position.clone();
            const delta = target.clone().sub(this.controls.target);
            this.camera.position.add(delta);
            this.controls.target.copy(target);
            this.controls.update();
        }
        this.render();
    }

    render() {
        const direction = new THREE.Vector3();
        this.camera.getWorldDirection(direction);
        const heading = Math.atan2(direction.x, -direction.z);
        const arrow = this.container.querySelector('.north span');
        if (arrow) {
            arrow.style.transform = `rotate(${-heading * 180 / Math.PI}deg)`;
        }
        if (this.estimateCar) {
            const distance = this.camera.position.distanceTo(this.controls.target);
            let scale = THREE.MathUtils.clamp(distance / 180, 1, 5);
            if (this.chase) {
                scale = 1;
            }
            this.estimateCar.scale.setScalar(scale);
            this.truthCar.scale.setScalar(scale);
        }
        this.renderer.render(this.scene, this.camera);
    }
}
