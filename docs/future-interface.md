# Future MyTree Interface

## Base Palette

On October 15, 2026, the user supplied a reference image of green plants and five color swatches for the future interface. The HEX values below were sampled from the solid-color areas of the swatches, from left to right.

| Color | HEX | Suggested role |
| --- | --- | --- |
| Dark forest | `#11401B` | Primary text, headings, strong outlines, and key tree elements. |
| Green | `#397624` | Primary action color: buttons, active elements, and emphasis. |
| Light leaf | `#9FC55B` | Soft accents, selected-element backgrounds, and cards. |
| Olive ochre | `#948934` | Secondary decorative accents, markers, and details. |
| Wood brown | `#875826` | Additional accent for branches, connections, and tree details. |

The user selected the five base colors; their assigned roles are an initial recommendation, not an approved mockup. The overall character is natural and calm, combining greens with warm woody accents. This is not a requirement to use the photograph as a background or fill the interface with all five colors at once.

## Application

- Keep large surfaces light and neutral; choose the exact shade during mockup work. This background complements the palette but is not a sixth swatch from the reference.
- Highlight primary actions in green and use light green for soft emphasis. Apply ochre and brown sparingly so they do not compete with the family-tree content.
- Indicate synchronization states, errors, selection, and focus with more than color: also use text, an icon, or an outline. The decorative palette does not replace accessible semantic error and warning colors.
- Define semantic theme roles centrally rather than scattering HEX literals across widgets. Automatically generated shades must not silently replace the base colors where the exact reference colors are required.

## Text Contrast

Calculated for opaque sRGB colors using the WCAG formula. Aim for a contrast ratio of at least 4.5:1 for normal text.

| Text | Background | Contrast |
| --- | --- | --- |
| White `#FFFFFF` | Dark forest `#11401B` | 11.84:1 |
| White `#FFFFFF` | Green `#397624` | 5.54:1 |
| Dark forest `#11401B` | Light leaf `#9FC55B` | 5.99:1 |
| White `#FFFFFF` | Wood brown `#875826` | 6.08:1 |

White text is unsuitable on the light-green background. On the original ochre background, neither white nor dark forest reaches 4.5:1: normal text needs a different, verified pairing. Transparency, overlays, and derived shades require separate checks.

## Current Theme Refinement

On October 15, 2026, the user requested a calmer primary green matching the existing application icon. The original five swatches above remain as a reference; the current theme uses muted colors from the [tree icon](../assets/tree-mark.svg):

| Role | Color | Source |
| --- | --- | --- |
| Primary actions, icons, and outlines | `#28644B` | Dark end of the canopy gradient. |
| Light-green background | `#D9E9CD` | Light circle behind the canopy. |
| Text and headings | `#315E47` | Trunk color. |
| Main light background | `#F3F7ED` | Light icon background. |

White on the primary green has a contrast ratio of **6.97:1**, text on the light-green background **5.84:1**, and text on the main background **6.85:1**. The bright online dot remains a separate status accent, as previously requested; the calm palette does not mute it or the error colors.

## Scope of the Agreement

This is a reference for the future family-tree editor interface. Recording the palette initially did not change the application styling. A subsequent update to the room menu and participant list centrally assigned the main Flutter theme roles using this palette; the primary green and backgrounds were then refined to match the icon, as described above. The tree icon is retained. This document does not define the future tree editor's layout or imply that it must be implemented immediately.
