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
**V2.0: May 6, 2024**
- Paint directly on MeshInstance3Ds. StaticBodies are no longer required!
- This is thanks to an updated algorithm to find the 3D surface: https://twitter.com/_michaeljared/status/1787020920751579407
- Interface is improved
- Bucketfill is temporarily removed, let me know if you want this feature

---
## 🚀 Install & Use

1. Download this [repository](https://github.com/bikemurt/godot-vertex-painter/), or download from the [Godot Asset Library](https://godotengine.org/asset-library/asset/2470).
    - Import the addons folder into your project (if it already isn't present).
2. Activate the Vertex Painter addon under Project > Project Settings > Plugins. If an error dialog appears, restart the engine and try activating it again.
3. Add a MeshInstance3D to the scene which you wish to paint vertex colors]
4. Select the MeshInstance3D (in the Scene tree or by clicking it in the 3D view), check "Enable Vertex Painting", set the Color using the color picker, and paint by dragging with the left mouse button
    - While painting is enabled, left clicks in the 3D view paint instead of selecting or moving things; right and middle mouse still move the camera. Untick the checkbox to edit normally again.
    - **Ctrl+click** (Cmd+click on macOS) a mesh in the 3D view to switch to painting it without unticking the checkbox. A mesh inside a non-editable instanced scene selects that instance, like a normal click does.
    - While painting is enabled, the mesh's move/rotate/scale gizmo is hidden and a lock icon shows next to it in the Scene tree. The plugin removes that lock when you untick the checkbox, select something else, or disable the plugin, and it is never saved into the scene.
    - Meshes inside an instanced scene (for example an imported `.glb`): selecting the instance shows a note and an **Enable Editable Children** button in the dock. Press it (undo with Ctrl+Z) and the mesh is selected, ready to paint. The painted mesh is then stored in your scene, per instance, and no longer follows re-imports of the `.glb`.
    - The paint shows on the mesh's own material: the plugin gives the surface a copy of its StandardMaterial3D with "Vertex Color > Use as Albedo" on, so the texture is multiplied by the paint (paint white = unchanged, grey = darker). Meshes without vertex colors start all white. A ShaderMaterial is left alone and only shows the paint if it reads `COLOR`.
    - **Opacity** (dock slider): how much of the color each stroke applies. Going over the same spot within one stroke never exceeds it; each new stroke builds on the last, so a low opacity darkens gradually.
    - **Alt+click** a painted mesh to pick the color under the cursor into the picker; **Alt+drag** keeps picking as you move. Nothing is painted. (The picker's own eyedropper samples the screen instead: the lit, shaded color.) While painting, this overrides the editor's "Emulate 3 Button Mouse" Alt+drag orbit. Some Linux window managers (e.g. XFCE, some KDE setups) use Alt+drag to move windows before Godot sees it; Alt+click still works there.
    - Vertex colors are stored with 8 bits per channel, so very fine opacity steps round to the nearest 1/255.

## ⚠️ Limitations

- Only imported meshes will work (or ArrayMesh, which have a clear_surfaces() method). Built-in shapes such as PlaneMesh are not supported yet.
- Rotated and scaled meshes are supported.
- Only the first surface (material slot) of a mesh is painted.

## 🏠 Links

- [Homepage](https://www.michaeljared.ca/)
- [Youtube](https://www.youtube.com/@michaeljburt)
- [Blender Market](https://blendermarket.com/creators/michaeljared)

## 🗒️ License

[MIT License](/LICENSE)
