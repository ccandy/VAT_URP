#if UNITY_EDITOR
using System;
using UnityEditor;
using UnityEngine;

namespace VAT.Editor
{
    using VAT;

    public sealed class VATAssetGeneratorWindow : EditorWindow
    {
        [SerializeField] private Mesh sourceMesh;
        [SerializeField] private int frameCount = 120;
        [SerializeField] private float houdiniFPS = 24f;

        [Header("Deform (Cylinder Demo)")]
        [SerializeField] private float waveAmplitude = 0.08f;
        [SerializeField] private float waveFrequency = 2.0f;
        [SerializeField] private float twistDegrees = 30.0f;

        [Header("Output")]
        [SerializeField] private DefaultAsset outputFolder;

        [MenuItem("Tools/VAT/Generate Lookup VAT (Demo)")]
        public static void Open()
        {
            GetWindow<VATAssetGeneratorWindow>("VAT Generator");
        }

        private void OnGUI()
        {
            EditorGUILayout.LabelField("Source", EditorStyles.boldLabel);
            sourceMesh = (Mesh)EditorGUILayout.ObjectField("Mesh", sourceMesh, typeof(Mesh), false);

            EditorGUILayout.Space(8);
            EditorGUILayout.LabelField("Bake Settings", EditorStyles.boldLabel);
            frameCount = Mathf.Clamp(EditorGUILayout.IntField("Frame Count", frameCount), 2, 4096);
            houdiniFPS = Mathf.Clamp(EditorGUILayout.FloatField("Houdini FPS", houdiniFPS), 1f, 240f);

            EditorGUILayout.Space(8);
            EditorGUILayout.LabelField("Deform (Cylinder Demo)", EditorStyles.boldLabel);
            waveAmplitude = EditorGUILayout.FloatField("Wave Amplitude", waveAmplitude);
            waveFrequency = EditorGUILayout.FloatField("Wave Frequency", waveFrequency);
            twistDegrees = EditorGUILayout.FloatField("Twist Degrees", twistDegrees);

            EditorGUILayout.Space(8);
            EditorGUILayout.LabelField("Output", EditorStyles.boldLabel);
            outputFolder = (DefaultAsset)EditorGUILayout.ObjectField("Folder", outputFolder, typeof(DefaultAsset), false);

            EditorGUILayout.Space(16);

            using (new EditorGUI.DisabledScope(sourceMesh == null || outputFolder == null))
            {
                if (GUILayout.Button("Bake VAT Asset"))
                {
                    try
                    {
                        Bake();
                    }
                    catch (Exception e)
                    {
                        Debug.LogError(e);
                    }
                }
            }

            EditorGUILayout.HelpBox(
                "This generates lookup + pos/rot/col VAT with a simple cylinder-like deformation.\n" +
                "It also bakes uv2.x on the mesh as vertexCoord01 = (vertexTexel+0.5)/atlasWidth,\n" +
                "which matches common lookup-driven VAT usage.",
                MessageType.Info);
        }

        private void Bake()
        {
            string folderPath = AssetDatabase.GetAssetPath(outputFolder);
            if (string.IsNullOrEmpty(folderPath))
                throw new InvalidOperationException("Invalid output folder.");

            // Make a copy mesh we can modify (uv2.x for vertexCoord01)
            Mesh bakedMesh = Instantiate(sourceMesh);
            bakedMesh.name = sourceMesh.name + "_VATMesh";

            Vector3[] restPos = bakedMesh.vertices;
            Vector3[] restNrm = bakedMesh.normals;
            if (restNrm == null || restNrm.Length != restPos.Length)
            {
                bakedMesh.RecalculateNormals();
                restNrm = bakedMesh.normals;
            }

            int vCount = restPos.Length;
            int frames = frameCount;

            // Atlas layout: width = nextPow2(vertexCount), height = nextPow2(frameCount)
            // (Houdini may choose other packing, but lookup will match this atlas exactly.)
            int atlasW = NextPow2(Mathf.Max(2, vCount));
            int atlasH = NextPow2(Mathf.Max(2, frames));

            // Lookup layout: X=vertex, Y=frame (not swapped) in this generator
            bool lookupAxisSwapped = false;
            int lookupW = atlasW;   // we store one entry per vertex along X
            int lookupH = atlasH;   // frame along Y

            // Bake uv2.x = (vertexTexel + 0.5)/atlasW
            // (Only x is needed for our sample HLSL; you can extend to uv2.xy if you want 2D packed vertex indices.)
            var uv2 = new Vector2[vCount];
            for (int i = 0; i < vCount; i++)
            {
                float vertexCoord01 = ((float)i + 0.5f) / atlasW;
                uv2[i] = new Vector2(vertexCoord01, 0);
            }
            bakedMesh.uv2 = uv2;

            // Prepare textures (linear, no mip, point)
            Texture2D texLookup = NewTexRGHalf(lookupW, lookupH, "Lookup");
            Texture2D texPos    = NewTexRGBAHalf(atlasW, atlasH, "Pos");
            Texture2D texRot    = NewTexRGBAHalf(atlasW, atlasH, "Rot");
            Texture2D texCol    = NewTexRGBA32 (atlasW, atlasH, "Col");

            // Compute bounds for pos encoding
            // We'll bake the whole animation bounds so decode works like Houdini.
            Vector3 bMin = new Vector3(float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity);
            Vector3 bMax = new Vector3(float.NegativeInfinity, float.NegativeInfinity, float.NegativeInfinity);

            // First pass: find bounds
            for (int f = 0; f < frames; f++)
            {
                float t01 = (float)f / (frames - 1);
                for (int i = 0; i < vCount; i++)
                {
                    Vector3 p = Deform(restPos[i], t01);
                    bMin = Vector3.Min(bMin, p);
                    bMax = Vector3.Max(bMax, p);
                }
            }

            // Avoid degenerate bounds
            bMax = new Vector3(
                Mathf.Max(bMax.x, bMin.x + 1e-5f),
                Mathf.Max(bMax.y, bMin.y + 1e-5f),
                Mathf.Max(bMax.z, bMin.z + 1e-5f)
            );

            // Second pass: write lookup + pos/rot/col into atlases
            Color[] lookupPixels = new Color[lookupW * lookupH];
            Color[] posPixels    = new Color[atlasW * atlasH];
            Color[] rotPixels    = new Color[atlasW * atlasH];
            Color[] colPixels    = new Color[atlasW * atlasH];

            // Fill defaults
            for (int i = 0; i < posPixels.Length; i++) posPixels[i] = new Color(0,0,0,0);
            for (int i = 0; i < rotPixels.Length; i++) rotPixels[i] = new Color(0.5f,0.5f,0.5f,1f); // identity-ish
            for (int i = 0; i < colPixels.Length; i++) colPixels[i] = new Color(1,1,1,1);
            for (int i = 0; i < lookupPixels.Length; i++) lookupPixels[i] = new Color(0,0,0,1);

            for (int f = 0; f < frames; f++)
            {
                int y = f; // frame row
                float t01 = (float)f / (frames - 1);

                for (int i = 0; i < vCount; i++)
                {
                    int x = i; // vertex column

                    // animUV points to atlas texel center at (x,y)
                    float u = ((float)x + 0.5f) / atlasW;
                    float v = ((float)y + 0.5f) / atlasH;
                    // lookup stores animUV in RG
                    int lutIdx = y * lookupW + x;
                    if (lutIdx < lookupPixels.Length)
                        lookupPixels[lutIdx] = new Color(u, v, 0, 1);

                    // position: encode to [0..1] using bounds
                    Vector3 p = Deform(restPos[i], t01);
                    Vector3 p01 = new Vector3(
                        Mathf.InverseLerp(bMin.x, bMax.x, p.x),
                        Mathf.InverseLerp(bMin.y, bMax.y, p.y),
                        Mathf.InverseLerp(bMin.z, bMax.z, p.z)
                    );

                    // rotation: quaternion01 (rotate rest normal -> deformed normal)
                    Vector3 n = ApproxDeformedNormal(restPos[i], restNrm[i], t01);
                    Quaternion q = FromToRotationSafe(restNrm[i], n);
                    // store in [0..1]
                    Color q01 = new Color(q.x * 0.5f + 0.5f, q.y * 0.5f + 0.5f, q.z * 0.5f + 0.5f, q.w * 0.5f + 0.5f);

                    int atlasIdx = y * atlasW + x;
                    posPixels[atlasIdx] = new Color(p01.x, p01.y, p01.z, 0);
                    rotPixels[atlasIdx] = q01;

                    // color (demo): gradient by height + time tint
                    float h = Mathf.InverseLerp(bMin.y, bMax.y, p.y);
                    colPixels[atlasIdx] = Color.HSVToRGB(Mathf.Repeat(t01 + h * 0.2f, 1f), 0.7f, 1f);
                }
            }

            // Apply to textures
            texLookup.SetPixels(lookupPixels);
            texLookup.Apply(false, false);

            texPos.SetPixels(posPixels);
            texPos.Apply(false, false);

            texRot.SetPixels(rotPixels);
            texRot.Apply(false, false);

            texCol.SetPixels(colPixels);
            texCol.Apply(false, false);

            // Save assets
            string baseName = sourceMesh.name + "_VAT";
            string meshPath = $"{folderPath}/{baseName}_Mesh.asset";
            string lookupPath = $"{folderPath}/{baseName}_Lookup.asset";
            string posPath = $"{folderPath}/{baseName}_Pos.asset";
            string rotPath = $"{folderPath}/{baseName}_Rot.asset";
            string colPath = $"{folderPath}/{baseName}_Col.asset";
            string assetPath = $"{folderPath}/{baseName}_Asset.asset";

            AssetDatabase.CreateAsset(bakedMesh, meshPath);
            AssetDatabase.CreateAsset(texLookup, lookupPath);
            AssetDatabase.CreateAsset(texPos, posPath);
            AssetDatabase.CreateAsset(texRot, rotPath);
            AssetDatabase.CreateAsset(texCol, colPath);

            var vatAsset = ScriptableObject.CreateInstance<VATLookupAsset>();
            vatAsset.bakedMesh = bakedMesh;
            vatAsset.lookupTex = texLookup;
            vatAsset.positionTex = texPos;
            vatAsset.rotationTex = texRot;
            vatAsset.colorTex = texCol;
            vatAsset.frameCount = frames;
            vatAsset.houdiniFPS = houdiniFPS;
            vatAsset.boundMin = bMin;
            vatAsset.boundMax = bMax;
            vatAsset.lookupAxisSwapped = lookupAxisSwapped;
            vatAsset.atlasWidth = atlasW;
            vatAsset.atlasHeight = atlasH;
            vatAsset.lookupWidth = lookupW;
            vatAsset.lookupHeight = lookupH;

            AssetDatabase.CreateAsset(vatAsset, assetPath);

            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();

            Debug.Log($"VAT baked:\n{assetPath}\nMesh:{meshPath}\nLookup:{lookupPath}\nPos:{posPath}\nRot:{rotPath}\nCol:{colPath}");
        }

        // -------------------- Demo deformation --------------------
        // A simple "cylinder-like" deformation:
        // - radial wave along height
        // - optional twist along height
        private Vector3 Deform(Vector3 p, float t01)
        {
            // Height normalized from mesh bounds assumption; if your cylinder isn't aligned, adjust.
            float y = p.y;
            float wave = Mathf.Sin((y * waveFrequency) + (t01 * Mathf.PI * 2f)) * waveAmplitude;

            // Push in/out in XZ
            Vector2 xz = new Vector2(p.x, p.z);
            float r = xz.magnitude;
            Vector2 dir = (r > 1e-6f) ? (xz / r) : Vector2.right;
            xz += dir * wave;

            // Twist around Y
            float twistRad = twistDegrees * Mathf.Deg2Rad * (y) * (Mathf.Sin(t01 * Mathf.PI * 2f));
            float cs = Mathf.Cos(twistRad);
            float sn = Mathf.Sin(twistRad);
            Vector2 xzTwisted = new Vector2(
                xz.x * cs - xz.y * sn,
                xz.x * sn + xz.y * cs
            );

            return new Vector3(xzTwisted.x, p.y, xzTwisted.y);
        }

        // Very rough normal approximation:
        // rotate rest normal by the same twist; plus small radial perturbation.
        // For a demo VAT it is good enough. For production you typically bake normals directly or store full quat.
        private Vector3 ApproxDeformedNormal(Vector3 restPos, Vector3 restN, float t01)
        {
            Vector3 n = restN.normalized;

            float y = restPos.y;
            float twistRad = twistDegrees * Mathf.Deg2Rad * (y) * (Mathf.Sin(t01 * Mathf.PI * 2f));
            Quaternion twistQ = Quaternion.AngleAxis(twistRad * Mathf.Rad2Deg, Vector3.up);
            n = (twistQ * n).normalized;

            return n;
        }

        private static Quaternion FromToRotationSafe(Vector3 a, Vector3 b)
        {
            a = a.normalized;
            b = b.normalized;
            float d = Mathf.Clamp(Vector3.Dot(a, b), -1f, 1f);

            if (d > 0.99999f) return Quaternion.identity;
            if (d < -0.99999f)
            {
                // 180 deg: pick an orthogonal axis
                Vector3 axis = Vector3.Cross(a, Vector3.right);
                if (axis.sqrMagnitude < 1e-6f) axis = Vector3.Cross(a, Vector3.up);
                axis.Normalize();
                return Quaternion.AngleAxis(180f, axis);
            }

            Vector3 axis2 = Vector3.Cross(a, b);
            float s = Mathf.Sqrt((1f + d) * 2f);
            float invS = 1f / s;
            return new Quaternion(axis2.x * invS, axis2.y * invS, axis2.z * invS, s * 0.5f);
        }

        // -------------------- Texture helpers --------------------
        private static Texture2D NewTexRGBAHalf(int w, int h, string name)
        {
            var tex = new Texture2D(w, h, TextureFormat.RGBAHalf, mipChain: false, linear: true);
            tex.name = name;
            tex.wrapMode = TextureWrapMode.Clamp;
            tex.filterMode = FilterMode.Point;
            tex.anisoLevel = 0;
            return tex;
        }

        private static Texture2D NewTexRGHalf(int w, int h, string name)
        {
            // Unity supports RGHalf on most platforms; if a platform doesn't, you'll see import fallback.
            var tex = new Texture2D(w, h, TextureFormat.RGHalf, mipChain: false, linear: true);
            tex.name = name;
            tex.wrapMode = TextureWrapMode.Clamp;
            tex.filterMode = FilterMode.Point;
            tex.anisoLevel = 0;
            return tex;
        }

        private static Texture2D NewTexRGBA32(int w, int h, string name)
        {
            var tex = new Texture2D(w, h, TextureFormat.RGBA32, mipChain: false, linear: true);
            tex.name = name;
            tex.wrapMode = TextureWrapMode.Clamp;
            tex.filterMode = FilterMode.Point;
            tex.anisoLevel = 0;
            return tex;
        }

        private static int NextPow2(int x)
        {
            x = Mathf.Max(1, x);
            x--;
            x |= x >> 1;
            x |= x >> 2;
            x |= x >> 4;
            x |= x >> 8;
            x |= x >> 16;
            x++;
            return x;
        }
    }
}
#endif
