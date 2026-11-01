<img src="addons/vertex_painter/icon.png" width="64" align="left" />

## godot-vertex-painter
 
**A simple tool to paint vertex colors on MeshInstance3Ds.**

[YouTube Video](https://www.youtube.com/watch?v=Qx7UtIk32i8)

---


https://github.com/bikemurt/godot-vertex-painter/assets/23486102/fea58b3f-8b71-48c5-840b-d1ae87ef0f7e



---

**Godot Versions Tested**
- v4.4.1 stable: automated checks on the `godot-4.4` branch, see [docs/verification](docs/verification/)
- v4.3 stable: automated checks on the `godot-4.3` branch
- v4.2.2 stable: automated checks on the `godot-4.2` branch
- v4.3.5 dev release
- v4.1.1

---
**V2.1: November 1, 2026**
- Ported to Godot 4.2 through 4.7, with a branch per version (`godot-4.2` … `godot-4.7`)
- Painting uses the editor's 3D input: while painting, left clicks paint instead of selecting or moving things, the camera still works with right/middle mouse, and it works in any of the split 3D views
- **Ctrl+click** switches to another mesh without leaving paint mode
- The selected mesh's move/rotate/scale gizmo is hidden while painting is enabled
- Rotated and scaled meshes paint in the right place
- Meshes inside instanced scenes (e.g. imported `.glb` files) can be painted via an **Enable Editable Children** button in the dock
- The paint is shown on the mesh's own material instead of replacing it with a debug shader, in one of two modes per mesh: **Multiply** (texture × paint) or **Normal** (paint covers the texture); switching a painted mesh converts it
- Full color picker; its **A** (alpha) slider is the brush opacity, so strokes can build up gradually
- **Alt+click / Alt+drag** picks a color from the painted mesh
- Brush size is a slider with an adjustable maximum
- Fixes: the brush painted the wrong vertices on small meshes, the mesh stayed locked after painting, and clicking empty space could paint the mesh
- Automated test harness for development (`tests/`, not part of the addon)

---
**V2.0: May 6, 2024**
- Paint directly on MeshInstance3Ds. StaticBodies are no longer required!
- This is thanks to an updated algorithm to find the 3D surface: https://twitter.com/_michaeljared/status/1787020920751579407
- Interface is improved
- Bucketfill is temporarily removed, let me know if you want this feature

---
## 🚀 Install & Use

1. Copy the `addons/vertex_painter` folder into your project. Use the `godot-4.X` branch that matches your Godot version; `main` follows the newest.
2. Enable **VertexPainter** under Project > Project Settings > Plugins. If an error appears the first time, restart the editor.
3. Select a MeshInstance3D, tick **Enable Vertex Painting** in the dock, pick a color and paint by dragging with the left mouse button.

**While painting is enabled**
- Left drag: paint. Right/middle mouse still move the camera.
- **Ctrl+click**: switch to another mesh.
- **Alt+click / Alt+drag** on the mesh: pick a color from it.
- The color picker's **A** slider is the opacity; low values build up over several strokes.
- **Brush Size**: how many vertices each dab paints. Raise **Max** for dense meshes.
- **Mode**: Multiply or Normal (see below), per mesh.
- Untick the checkbox to select and move things normally again.

**Notes**
- **Multiply**: the mesh's texture is multiplied by the paint, so white leaves it unchanged and darker colors darken it (good for ambient occlusion).
- **Normal**: the paint covers the texture, by the brush opacity; unpainted areas show the texture.
- The mode is stored per mesh. Switching it on a painted mesh converts the paint (Ctrl+Z undoes it). Multiply → Normal → Multiply gives back the same colors; going Normal → Multiply bakes partly covering paint into the color.
- Meshes painted with the old debug shader keep it until you pick a Mode for them; the colors are kept.
- For a mesh inside an instanced scene (e.g. an imported `.glb`), press **Enable Editable Children** in the dock first. The painted mesh is then saved in your scene.

## ⚠️ Limitations

- Only imported meshes will work (or ArrayMesh, which have a clear_surfaces() method). Built-in shapes such as PlaneMesh are not supported yet.
- Only the first surface (material slot) of a mesh is painted.

## 🏠 Links

- [Homepage](https://www.michaeljared.ca/)
- [Youtube](https://www.youtube.com/@michaeljburt)
- [Blender Market](https://blendermarket.com/creators/michaeljared)

## 🗒️ License

[MIT License](/LICENSE)
