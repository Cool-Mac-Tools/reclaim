import SwiftUI
import SceneKit
import AppKit
import ReclaimCore

extension WorkspaceKind {
    var tint: NSColor {
        switch self {
        case .app: NSColor(red: 0.36, green: 0.65, blue: 1, alpha: 1)
        case .tab: NSColor(red: 0.3, green: 0.86, blue: 0.83, alpha: 1)
        case .file: NSColor(red: 1, green: 0.73, blue: 0.35, alpha: 1)
        case .terminal: NSColor(red: 0.4, green: 0.89, blue: 0.61, alpha: 1)
        case .agent: NSColor(red: 0.74, green: 0.6, blue: 1, alpha: 1)
        case .task: NSColor(red: 1, green: 0.53, blue: 0.66, alpha: 1)
        case .storage: NSColor(red: 0.5, green: 0.71, blue: 0.9, alpha: 1)
        }
    }
    var color: Color { Color(nsColor: tint) }
}

/// A real SceneKit world: orbit/pan/zoom, hit-tested objects, stable slots, and
/// incremental updates. It renders on demand rather than spinning at 60 fps.
struct WorkspaceScene: NSViewRepresentable {
    let objects: [WorkspaceObject]
    let selectedID: String?
    let focus: WorkspaceKind?
    let resetToken: Int
    let reduceMotion: Bool
    let select: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = NSColor(red: 0.035, green: 0.052, blue: 0.078, alpha: 1)
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = false
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.pointOfView = context.coordinator.camera
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        view.addGestureRecognizer(click)
        context.coordinator.view = view
        view.setAccessibilityLabel("Live workspace in 3D. Drag to orbit, scroll to zoom. Use the object list to select with a keyboard.")
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.select = select
        let focusChanged = context.coordinator.focus != focus
        context.coordinator.focus = focus
        context.coordinator.update(objects, selected: selectedID, reduceMotion: reduceMotion)
        if context.coordinator.resetToken != resetToken || focusChanged {
            context.coordinator.resetToken = resetToken
            context.coordinator.focus = focus
            view.pointOfView = context.coordinator.camera
            context.coordinator.home()
        }
    }
    @MainActor final class Coordinator: NSObject {
        let scene = SCNScene()
        let camera = SCNNode()
        weak var view: SCNView?
        var select: (String?) -> Void
        var resetToken = 0
        var focus: WorkspaceKind?
        private var nodes: [String: SCNNode] = [:]
        private var previous: [String: WorkspaceObject] = [:]
        private var slots: [String: Int] = [:]
        private var lastSelection: String?
        private var emptyLabels: [WorkspaceKind: SCNNode] = [:]
        private var zoneNodes: [WorkspaceKind: [SCNNode]] = [:]
        private var activeKinds: Set<WorkspaceKind> = []
        private let centers: [WorkspaceKind: SCNVector3] = [
            .app: SCNVector3(-4, 0, 0), .tab: SCNVector3(0, 0, -6),
            .file: SCNVector3(7, 0, -4), .terminal: SCNVector3(-7, 0, 4),
            .agent: SCNVector3(0, 0, 6), .task: SCNVector3(4, 0, 0), .storage: SCNVector3(0, 0, -5)
        ]
        init(select: @escaping (String?) -> Void) {
            self.select = select; super.init()
            camera.camera = SCNCamera(); camera.camera?.fieldOfView = 49
            camera.camera?.zFar = 160
            scene.rootNode.addChildNode(camera); home()
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
            ambient.light?.intensity = 700; ambient.light?.color = NSColor.white
            scene.rootNode.addChildNode(ambient)
            let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
            key.light?.intensity = 1100; key.position = SCNVector3(0, 15, 8)
            scene.rootNode.addChildNode(key)
            let floor = SCNBox(width: 24, height: 0.2, length: 20, chamferRadius: 0.35)
            floor.firstMaterial?.diffuse.contents = NSColor(red: 0.065, green: 0.09, blue: 0.125, alpha: 1)
            let floorNode = SCNNode(geometry: floor); floorNode.position.y = -0.25
            scene.rootNode.addChildNode(floorNode)
            // A small desktop computer anchors the world at the measured startup volume.
            let stand = SCNNode(geometry: SCNBox(width: 0.3, height: 0.7, length: 0.3, chamferRadius: 0.06))
            stand.geometry?.firstMaterial?.diffuse.contents = NSColor.gray
            stand.position = SCNVector3(0, 0.4, -0.25); scene.rootNode.addChildNode(stand)
            let foot = SCNNode(geometry: SCNBox(width: 1.6, height: 0.12, length: 0.75, chamferRadius: 0.08))
            foot.geometry?.firstMaterial?.diffuse.contents = NSColor.gray
            foot.position = SCNVector3(0, 0.12, -0.25); scene.rootNode.addChildNode(foot)
            zoneNodes[.storage] = [stand, foot]
            for x in stride(from: -11.0, through: 11.0, by: 1.0) {
                addLine(SCNVector3(x, -0.135, -9), SCNVector3(x, -0.135, 9), color: NSColor.white.withAlphaComponent(0.045))
            }
            for z in stride(from: -9.0, through: 9.0, by: 1.0) {
                addLine(SCNVector3(-11, -0.135, z), SCNVector3(11, -0.135, z), color: NSColor.white.withAlphaComponent(0.045))
            }
            for kind in WorkspaceKind.allCases {
                guard let center = centers[kind] else { continue }
                let base = SCNBox(width: kind == .storage ? 3.4 : 5.7, height: 0.14,
                                  length: kind == .storage ? 2.8 : 4.0, chamferRadius: 0.18)
                base.firstMaterial?.diffuse.contents = kind.tint.withAlphaComponent(0.10)
                let node = SCNNode(geometry: base); node.position = center
                scene.rootNode.addChildNode(node)
                zoneNodes[kind, default: []].append(node)
                let label = SCNText(string: kind == .storage ? "MY MAC" : kind == .task ? "BACKGROUND" : kind.title.uppercased(), extrusionDepth: 0)
                label.font = .systemFont(ofSize: 0.28, weight: .semibold)
                label.firstMaterial?.diffuse.contents = kind.tint
                let text = SCNNode(geometry: label)
                text.eulerAngles.x = -.pi / 2
                text.position = SCNVector3(center.x - 2.4, 0.09, center.z + 1.65)
                if kind == .storage { text.position.x = -1.1; text.position.z = 1.15 }
                scene.rootNode.addChildNode(text)
                zoneNodes[kind, default: []].append(text)
                if kind != .storage {
                    let caption = SCNText(string: "Connect a source above", extrusionDepth: 0)
                    caption.font = .systemFont(ofSize: 0.25)
                    caption.firstMaterial?.diffuse.contents = kind.tint.withAlphaComponent(0.5)
                    let empty = SCNNode(geometry: caption)
                    empty.eulerAngles.x = -.pi / 2
                    empty.position = SCNVector3(center.x - 1.8, 0.09, center.z)
                    scene.rootNode.addChildNode(empty); emptyLabels[kind] = empty
                    zoneNodes[kind, default: []].append(empty)
                }
                if kind != .storage {
                    let line = addLine(SCNVector3(0, -0.09, 0), center, color: kind.tint.withAlphaComponent(0.25))
                    zoneNodes[kind, default: []].append(line)
                }
            }
        }
        func home() {
            view?.defaultCameraController.stopInertia()
            if let focus, let target = centers[focus] {
                camera.position = SCNVector3(target.x + 1, 5, target.z + (focus == .storage ? 5 : 8))
                let aim = SCNVector3(target.x, 1.2, target.z)
                camera.look(at: aim); view?.defaultCameraController.target = aim
            } else {
                let points = activeKinds.compactMap { centers[$0] }
                let minX = points.map(\.x).min() ?? -7, maxX = points.map(\.x).max() ?? 7
                let minZ = points.map(\.z).min() ?? -4, maxZ = points.map(\.z).max() ?? 4
                let span = max(maxX - minX + 7, maxZ - minZ + 6)
                let target = SCNVector3((minX + maxX) / 2, 1, (minZ + maxZ) / 2)
                camera.position = SCNVector3(target.x + 2, Double(span) * 0.64, target.z + span * 0.91)
                camera.look(at: target); view?.defaultCameraController.target = target
            }
            view?.pointOfView = camera
            view?.needsDisplay = true
        }
        func update(_ objects: [WorkspaceObject], selected: String?, reduceMotion: Bool) {
            // Keep the scene legible; every object remains available in the list.
            let shown = WorkspaceKind.allCases.flatMap { kind in
                let group = objects.filter { $0.kind == kind }.sorted {
                    if $0.focused != $1.focused { return $0.focused }
                    if ($0.state == .active) != ($1.state == .active) { return $0.state == .active }
                    if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
                    if $0.memory != $1.memory { return $0.memory > $1.memory }
                    return $0.id < $1.id
                }
                var visible = Array(group.prefix(kind == .storage ? 1 : 12))
                if let selected, let chosen = group.first(where: { $0.id == selected }), !visible.contains(where: { $0.id == selected }) {
                    visible.removeLast(); visible.append(chosen)
                }
                return visible
            }
            let kinds = Set(objects.map(\.kind))
            let changed = kinds != activeKinds
            activeKinds = kinds
            for (kind, zone) in zoneNodes {
                let visible = focus.map { $0 == kind } ?? kinds.contains(kind)
                zone.forEach { $0.isHidden = !visible }
                emptyLabels[kind]?.isHidden = !visible || kinds.contains(kind)
            }
            let live = Set(shown.map(\.id))
            for id in Array(nodes.keys) where !live.contains(id) {
                nodes.removeValue(forKey: id)?.removeFromParentNode(); previous[id] = nil; slots[id] = nil
            }
            SCNTransaction.begin(); SCNTransaction.animationDuration = reduceMotion ? 0 : 0.25
            for object in shown {
                let node: SCNNode
                if let existing = nodes[object.id] { node = existing }
                else {
                    let taken = Set(shown.filter { $0.kind == object.kind }.compactMap { slots[$0.id] })
                    let slot = (0..<12).first { !taken.contains($0) } ?? 0
                    slots[object.id] = slot
                    let center = centers[object.kind] ?? SCNVector3Zero
                    node = SCNNode(); node.name = object.id
                    let slotX = object.kind == .storage ? 0 : Double(slot % 3 - 1) * 1.7
                    let slotZ = object.kind == .storage ? 0 : Double(slot / 3) * 0.82 - 1.15
                    let height = object.kind == .storage ? 0.9 : 0.8 + Double(3 - slot / 3) * 0.6
                    node.position = SCNVector3(Double(center.x) + slotX, height, Double(center.z) + slotZ)
                    let body = SCNBox(width: 1.52, height: 0.84, length: 0.12, chamferRadius: 0.06)
                    let material = SCNMaterial(); material.diffuse.contents = object.kind.tint.withAlphaComponent(0.24)
                    body.materials = [material]
                    let card = SCNNode(geometry: body); node.addChildNode(card)
                    let face = SCNNode(geometry: SCNPlane(width: 1.43, height: 0.75)); face.name = "face"
                    face.position.z = 0.066
                    face.geometry?.firstMaterial?.lightingModel = .constant
                    face.geometry?.firstMaterial?.isDoubleSided = true
                    node.addChildNode(face)
                    let billboard = SCNBillboardConstraint(); billboard.freeAxes = .Y
                    node.constraints = [billboard]
                    scene.rootNode.addChildNode(node); nodes[object.id] = node
                }
                let isSelected = selected == object.id
                node.scale = isSelected ? SCNVector3(1.22, 1.22, 1.22) : SCNVector3(1, 1, 1)
                let old = previous[object.id]
                if old?.title != object.title || old?.detail != object.detail || old?.state != object.state
                    || old?.focused != object.focused || lastSelection != selected {
                    node.childNode(withName: "face", recursively: false)?.geometry?.firstMaterial?.diffuse.contents = cardImage(object, selected: isSelected)
                    previous[object.id] = object
                }
            }
            lastSelection = selected
            SCNTransaction.commit()
            if changed { home() }
            view?.needsDisplay = true
        }
        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            for hit in view.hitTest(point, options: [:]) {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, nodes[name] != nil { select(name); return }
                    node = current.parent
                }
            }
            select(nil)
        }
        @discardableResult private func addLine(_ a: SCNVector3, _ b: SCNVector3, color: NSColor) -> SCNNode {
            let source = SCNGeometrySource(vertices: [a, b])
            let element = SCNGeometryElement(indices: [Int32(0), 1], primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = color
            geometry.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: geometry)
            scene.rootNode.addChildNode(node)
            return node
        }
        private func cardImage(_ object: WorkspaceObject, selected: Bool) -> NSImage {
            let image = NSImage(size: NSSize(width: 480, height: 250))
            image.lockFocus()
            NSColor(red: 0.065, green: 0.09, blue: 0.135, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 480, height: 250), xRadius: 20, yRadius: 20).fill()
            object.kind.tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 235, width: 480, height: 15), xRadius: 5, yRadius: 5).fill()
            if selected { object.kind.tint.setStroke(); let p = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 474, height: 244), xRadius: 18, yRadius: 18); p.lineWidth = 5; p.stroke() }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            func text(_ string: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
                (string as NSString).draw(in: NSRect(x: 24, y: y, width: 430, height: size * 1.5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
            }
            if let pid = object.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                icon.draw(in: NSRect(x: 396, y: 156, width: 58, height: 58))
            }
            text(object.focused ? "FOCUSED" : object.kind.title.uppercased(), y: 178, size: 19, color: object.kind.tint, weight: .bold)
            text(object.title, y: 112, size: 44, color: .white, weight: .semibold)
            text(object.detail, y: 72, size: 23, color: NSColor.white.withAlphaComponent(0.65))
            text(object.state == .active ? "●  ACTIVE" : object.state.rawValue.uppercased(), y: 22, size: 17, color: object.kind.tint)
            image.unlockFocus(); return image
        }
    }
}
