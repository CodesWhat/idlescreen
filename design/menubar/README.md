# Menu bar glyphs

A small CRT monitor, drawn as a template glyph. It sits in the menu bar and follows the menu bar appearance (light,
dark, tinted) because the images are template images. The art is original to this project.

`generate.py` writes seven glyphs, each as an asset catalog imageset with a 16 x 15 (1x) and a 32 x 30 (2x) PNG and
`template-rendering-intent: template`, into `Products/IdleScreenApp/Assets.xcassets/MenuBarCRT*.imageset`. The 1x is on
the pixel grid; the 2x is hand drawn (rounded bezel, highlight notch, true ellipse eye), not pixel-doubled. It also
writes `preview.png` here: every state at 1x, 8x and the 2x at 4x, on light and dark. The generated files are checked
in, so the app builds without Python.

| Glyph | Imageset | Meaning |
| --- | --- | --- |
| idle | `MenuBarCRTIdle` | Ready. Three scanlines. |
| running0, running1 | `MenuBarCRTRunning0`, `MenuBarCRTRunning1` | The screen saver is running or Studio is previewing. Rain streaks fall one row between frames. |
| camera0, camera1 | `MenuBarCRTCamera0`, `MenuBarCRTCamera1` | The companion camera preview is streaming. An eye dot glances left to right. |
| attention | `MenuBarCRTAttention` | An agent signal needs attention. A bang. |
| setup | `MenuBarCRTSetup` | Needs setup or unavailable: extension not embedded, registered or selected, or the camera service failed. The tube is struck through. |

`IdleScreenMenuBarState` resolves the state with a fixed precedence, setup, attention, camera, running, idle, so a
failure outranks a phase. Running and camera alternate their two frames every 0.7 s, only while in that state. Idle,
setup and attention are still, and no timer runs. With Reduce Motion on, running and camera pin their first frame
(`running0`, `camera0`) and the timer stops. Each state sets the status item's accessibility description:
"IdleScreen, ready", "IdleScreen, screen saver running", "IdleScreen, camera on", "IdleScreen, needs attention" and
"IdleScreen needs setup".

Regenerate after changing the art (Python 3, standard library only; output is deterministic):

    python3 -I design/menubar/generate.py
