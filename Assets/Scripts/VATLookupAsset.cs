using UnityEngine;

namespace VAT
{
    /// <summary>
    /// Lookup-driven VAT asset: lookup -> animUV -> pos/rot/col atlases
    /// This mirrors common SideFX VAT (lookup + pos/rot/col) usage.
    /// </summary>
    [CreateAssetMenu(menuName = "VAT/Lookup VAT Asset", fileName = "VAT_LookupAsset")]
    public sealed class VATLookupAsset : ScriptableObject
    {
        [Header("Baked Outputs")]
        public Mesh bakedMesh;               // Same topology mesh (rest pose) that uses uv2.x as vertexCoord01
        public Texture2D lookupTex;          // RG = animUV01
        public Texture2D positionTex;        // RGB = pos01 in bounds, A unused
        public Texture2D rotationTex;        // RGBA = quat01
        public Texture2D colorTex;           // RGB = color (optional)

        [Header("Playback")]
        public int frameCount = 120;
        public float houdiniFPS = 24.0f;

        [Header("Decode Bounds (pos01 -> posOS)")]
        public Vector3 boundMin;
        public Vector3 boundMax;

        [Header("Lookup Layout")]
        [Tooltip("0: X=vertex, Y=frame. 1: X=frame, Y=vertex.")]
        public bool lookupAxisSwapped = false;

        [Header("Atlas Size (for debug/validation)")]
        public int atlasWidth;
        public int atlasHeight;
        public int lookupWidth;
        public int lookupHeight;
    }
}