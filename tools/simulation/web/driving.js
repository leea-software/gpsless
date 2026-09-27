import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

function part(group, geometry, material, x, y, z) {
    const mesh = new THREE.Mesh(geometry, material);
    mesh.position.set(x, y, z);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    group.add(mesh);
    return mesh;
}

export function createVehicle(color) {
    const car = new THREE.Group();
    const paint = new THREE.MeshStandardMaterial({ color, metalness: 0.45, roughness: 0.27 });
    const glass = new THREE.MeshStandardMaterial({ color: 0x132834, metalness: 0.55, roughness: 0.17 });
    const rubber = new THREE.MeshStandardMaterial({ color: 0x11181d, roughness: 0.85 });
    const trim = new THREE.MeshStandardMaterial({ color: 0x202b32, metalness: 0.65, roughness: 0.35 });
    const alloy = new THREE.MeshStandardMaterial({ color: 0xa0adb5, metalness: 0.85, roughness: 0.22 });
    const rearLight = new THREE.MeshStandardMaterial({ color: 0xc92b35, emissive: 0xee273a, emissiveIntensity: 2.5 });
    const headLight = new THREE.MeshStandardMaterial({ color: 0xf7ffe9, emissive: 0xe9faff, emissiveIntensity: 1.6 });
    part(car, new RoundedBoxGeometry(1.93, 0.58, 4.35, 3, 0.13), paint, 0, 0.73, 0);
    part(car, new RoundedBoxGeometry(1.78, 0.24, 4.25, 2, 0.07), trim, 0, 0.43, 0);
    part(car, new RoundedBoxGeometry(1.76, 0.22, 1.3, 3, 0.08), paint, 0, 1.02, -1.33);
    // A tapered passenger cabin with a sloped windscreen and rear hatch.
    const vertices = new Float32Array([
        -0.83, 0.99, -1.05, 0.83, 0.99, -1.05, 0.83, 0.99, 1.55, -0.83, 0.99, 1.55,
        -0.66, 1.58, -0.52, 0.66, 1.58, -0.52, 0.66, 1.58, 0.84, -0.66, 1.58, 0.84,
    ]);
    const cabin = new THREE.BufferGeometry();
    cabin.setAttribute('position', new THREE.BufferAttribute(vertices, 3));
    cabin.setIndex([0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7, 4, 5, 6, 4, 6, 7]);
    cabin.computeVertexNormals();
    glass.side = THREE.DoubleSide;
    part(car, cabin, glass, 0, 0, 0);
    part(car, new RoundedBoxGeometry(1.4, 0.08, 1.5, 2, 0.04), paint, 0, 1.61, 0.15);
    part(car, new RoundedBoxGeometry(1.09, 0.025, 0.98, 2, 0.04), glass, 0, 1.66, 0.11);
    for (const x of [-0.83, 0.83]) {
        const pillar = part(car, new THREE.BoxGeometry(0.055, 0.64, 0.07), paint, x * 0.9, 1.3, 0.32);
        pillar.rotation.z = -Math.sign(x) * 0.23;
        part(car, new RoundedBoxGeometry(0.18, 0.035, 0.035, 1, 0.012), alloy, x * 1.13, 0.95, 0.46);
        part(car, new RoundedBoxGeometry(0.26, 0.12, 0.22, 2, 0.04), paint, x * 1.23, 1.13, -0.72);
    }
    part(car, new RoundedBoxGeometry(1.35, 0.17, 0.05, 2, 0.02), trim, 0, 0.61, -2.17);
    part(car, new RoundedBoxGeometry(1.75, 0.08, 0.12, 2, 0.025), rearLight, 0, 0.91, 2.16);
    part(car, new THREE.BoxGeometry(0.38, 0.13, 0.02), new THREE.MeshStandardMaterial({ color: 0xf0efe6 }), 0, 0.68, 2.19);
    for (const x of [-0.7, 0.7]) {
        part(car, new RoundedBoxGeometry(0.4, 0.095, 0.07, 2, 0.02), headLight, x, 0.93, -2.16);
        part(car, new THREE.BoxGeometry(0.23, 0.085, 0.18), alloy, x, 0.4, 2.16);
    }
    const wheels = [];
    for (const x of [-0.96, 0.96]) {
        for (const z of [-1.35, 1.35]) {
            const steering = new THREE.Group();
            steering.position.set(x, 0.4, z);
            const wheel = new THREE.Group();
            steering.add(wheel);
            car.add(steering);
            const tire = part(wheel, new THREE.CylinderGeometry(0.39, 0.39, 0.25, 24), rubber, 0, 0, 0);
            tire.rotation.z = Math.PI / 2;
            const rim = part(wheel, new THREE.CylinderGeometry(0.29, 0.29, 0.26, 20), trim, 0, 0, 0);
            rim.rotation.z = Math.PI / 2;
            for (let spoke = 0; spoke < 5; spoke += 1) {
                const angle = spoke * Math.PI * 2 / 5;
                const bar = part(wheel, new THREE.BoxGeometry(0.275, 0.045, 0.5), alloy, 0, 0, 0);
                bar.rotation.x = angle;
            }
            wheels.push({ steering, wheel, front: z < 0 });
        }
    }
    car.userData.wheels = wheels;
    return car;
}

export function createScenery(roads, origin, extent) {
    const group = new THREE.Group();
    const size = Math.max(extent + 1800, 2200);
    const ground = new THREE.Mesh(new THREE.PlaneGeometry(size, size), new THREE.MeshStandardMaterial({ color: 0x667965, roughness: 1 }));
    ground.rotation.x = -Math.PI / 2;
    ground.position.y = -0.12;
    ground.receiveShadow = true;
    group.add(ground);
    const segments = [];
    for (const road of roads) {
        for (let index = 1; index < road.points.length; index += 1) {
            const a = road.points[index - 1];
            const b = road.points[index];
            const dx = b[0] - a[0];
            const dy = b[1] - a[1];
            const length = Math.hypot(dx, dy);
            if (length > 1) {
                segments.push({ a, b, dx, dy, length, id: road.id });
            }
        }
    }
    const occupied = new Set();
    const buildings = [];
    for (const segment of segments) {
        if (buildings.length >= 750) {
            break;
        }
        for (let s = 25; s < segment.length; s += 42) {
            for (const side of [-1, 1]) {
                const x = segment.a[0] + segment.dx * s / segment.length - segment.dy / segment.length * 22 * side;
                const y = segment.a[1] + segment.dy * s / segment.length + segment.dx / segment.length * 22 * side;
                const cell = `${Math.floor(x / 22)},${Math.floor(y / 22)}`;
                if (occupied.has(cell)) {
                    continue;
                }
                let clear = true;
                for (const other of segments) {
                    if (x < Math.min(other.a[0], other.b[0]) - 16 || x > Math.max(other.a[0], other.b[0]) + 16 || y < Math.min(other.a[1], other.b[1]) - 16 || y > Math.max(other.a[1], other.b[1]) + 16) {
                        continue;
                    }
                    const fraction = THREE.MathUtils.clamp(((x - other.a[0]) * other.dx + (y - other.a[1]) * other.dy) / other.length ** 2, 0, 1);
                    if (Math.hypot(x - other.a[0] - fraction * other.dx, y - other.a[1] - fraction * other.dy) < 15) {
                        clear = false;
                        break;
                    }
                }
                if (!clear) {
                    continue;
                }
                occupied.add(cell);
                const variation = Math.abs(Math.sin(segment.id * 1.73 + s + side) * 1000) % 1;
                buildings.push({ x: x - origin[0], z: -(y - origin[1]), height: 7 + Math.floor(variation * 6) * 3,
                    rotation: Math.atan2(segment.dy, segment.dx), variation });
            }
        }
    }
    const buildingMaterial = new THREE.MeshStandardMaterial({ roughness: 0.9 });
    const blocks = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), buildingMaterial, buildings.length);
    blocks.castShadow = true;
    blocks.receiveShadow = true;
    const windows = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ color: 0x365563, metalness: 0.3, roughness: 0.3 }), buildings.length * 28);
    const roofs = new THREE.InstancedMesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ color: 0x42535b, roughness: 0.8 }), buildings.length);
    const object = new THREE.Object3D();
    let windowIndex = 0;
    for (let index = 0; index < buildings.length; index += 1) {
        const building = buildings[index];
        object.position.set(building.x, building.height / 2, building.z);
        object.rotation.set(0, building.rotation, 0);
        object.scale.set(13, building.height, 15);
        object.updateMatrix();
        blocks.setMatrixAt(index, object.matrix);
        blocks.setColorAt(index, new THREE.Color().setHSL(0.08 + building.variation * 0.48, 0.09, 0.53 + building.variation * 0.19));
        object.position.y = building.height + 0.2;
        object.scale.set(13.5, 0.4, 15.5);
        object.updateMatrix();
        roofs.setMatrixAt(index, object.matrix);
        for (let floor = 2; floor < building.height - 1; floor += 3) {
            for (const side of [-1, 1]) {
                const z = side * 7.53;
                object.position.set(building.x + Math.sin(building.rotation) * z, floor, building.z + Math.cos(building.rotation) * z);
                object.scale.set(10.7, 1.3, 0.04);
                object.updateMatrix();
                windows.setMatrixAt(windowIndex, object.matrix);
                windowIndex += 1;
                const x = side * 6.53;
                object.position.set(building.x + Math.cos(building.rotation) * x, floor, building.z - Math.sin(building.rotation) * x);
                object.scale.set(0.04, 1.3, 12.7);
                object.updateMatrix();
                windows.setMatrixAt(windowIndex, object.matrix);
                windowIndex += 1;
            }
        }
    }
    windows.count = windowIndex;
    group.add(blocks, windows, roofs);
    // Stylized roadside trees add depth. They are illustrative scenery, not
    // imported Kyiv vegetation or surveyed building footprints.
    const trunks = new THREE.InstancedMesh(new THREE.CylinderGeometry(0.18, 0.26, 2.5, 7), new THREE.MeshStandardMaterial({ color: 0x695749 }), buildings.length);
    const crowns = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(2.7, 1), new THREE.MeshStandardMaterial({ color: 0x456c51, roughness: 1 }), buildings.length);
    crowns.castShadow = true;
    for (let index = 0; index < buildings.length; index += 1) {
        const building = buildings[index];
        object.rotation.set(0, 0, 0);
        object.scale.set(1, 1, 1);
        object.position.set(building.x + Math.cos(building.rotation) * 10, 1.25, building.z - Math.sin(building.rotation) * 10);
        object.updateMatrix();
        trunks.setMatrixAt(index, object.matrix);
        object.position.y = 4;
        object.scale.set(1, 1.3, 1);
        object.updateMatrix();
        crowns.setMatrixAt(index, object.matrix);
    }
    group.add(trunks, crowns);
    return group;
}
