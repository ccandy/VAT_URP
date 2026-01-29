using System.IO;
using UnityEditor;
using UnityEngine;

public static class Texture2DAssetSaver
{
    private const string DefaultOutDir = "Assets/VAT_Baked";

    [MenuItem("Tools/VAT/Save Selected Texture2D as .asset (Overwrite If Exists)")]
    public static void SaveSelectedTexture2DAsAsset()
    {
        var src = Selection.activeObject as Texture2D;
        if (src == null)
        {
            Debug.LogError("Please select a Texture2D in Project view.");
            return;
        }

        // Default output path
        EnsureDir(DefaultOutDir);
        string outPath = $"{DefaultOutDir}/{SanitizeFileName(src.name)}.asset";

        // 如果用户想选路径，可以用 SaveFilePanelInProject
        string chosen = EditorUtility.SaveFilePanelInProject(
            "Save Texture2D as .asset",
            Path.GetFileNameWithoutExtension(outPath),
            "asset",
            "Choose where to save the Texture2D asset.",
            DefaultOutDir);

        if (string.IsNullOrEmpty(chosen))
            return;

        SaveOrOverwriteTexture2DAsset(src, chosen);

        Debug.Log($"Saved Texture2D asset: {chosen}");
        EditorGUIUtility.PingObject(AssetDatabase.LoadAssetAtPath<Object>(chosen));
    }

    /// <summary>
    /// Save src Texture2D as a .asset at assetPath.
    /// - If target exists: CopySerialized into it (keeps references stable)
    /// - Else: CreateAsset (creates a new asset)
    /// </summary>
    public static void SaveOrOverwriteTexture2DAsset(Texture2D src, string assetPath)
    {
        if (src == null) { Debug.LogError("src is null"); return; }

        if (string.IsNullOrEmpty(assetPath) || !assetPath.StartsWith("Assets/"))
        {
            Debug.LogError($"assetPath must be under Assets/. Got: {assetPath}");
            return;
        }

        // Ensure directory exists
        EnsureDir(Path.GetDirectoryName(assetPath));

        // IMPORTANT:
        // If src is already an imported asset (EXR/PNG/etc), we must clone it before saving,
        // otherwise CreateAsset will fail because src already lives in the AssetDatabase.
        Texture2D textureToSave = IsAssetObject(src) ? Object.Instantiate(src) : src;

        // Give it a stable name
        textureToSave.name = Path.GetFileNameWithoutExtension(assetPath);

        if (File.Exists(assetPath))
        {
            // Load existing target and overwrite its serialized data
            var dst = AssetDatabase.LoadAssetAtPath<Texture2D>(assetPath);
            if (dst == null)
            {
                Debug.LogWarning($"File exists but not a Texture2D at path: {assetPath}. Deleting and recreating.");
                AssetDatabase.DeleteAsset(assetPath);
                AssetDatabase.CreateAsset(textureToSave, assetPath);
            }
            else
            {
                // CopySerialized: 覆盖 dst 的内容，但保持 dst 的引用不变（材质/脚本引用不丢）
                EditorUtility.CopySerialized(textureToSave, dst);
                EditorUtility.SetDirty(dst);
                AssetDatabase.SaveAssetIfDirty(dst);

                // 如果我们 Instantiate 了 textureToSave，这个临时对象可以销毁
                if (textureToSave != src)
                    Object.DestroyImmediate(textureToSave);

                AssetDatabase.SaveAssets();
                AssetDatabase.Refresh();
                return;
            }
        }
        else
        {
            AssetDatabase.CreateAsset(textureToSave, assetPath);
        }

        AssetDatabase.SaveAssets();
        AssetDatabase.Refresh();
    }

    // -------------------- helpers --------------------

    private static bool IsAssetObject(Object obj)
    {
        // If obj exists in the AssetDatabase, it has a valid path.
        return !string.IsNullOrEmpty(AssetDatabase.GetAssetPath(obj));
    }

    private static void EnsureDir(string dir)
    {
        if (string.IsNullOrEmpty(dir)) return;
        if (!dir.StartsWith("Assets")) return;

        if (!AssetDatabase.IsValidFolder(dir))
        {
            // Create folders recursively under Assets
            string[] parts = dir.Split('/');
            string cur = parts[0]; // "Assets"
            for (int i = 1; i < parts.Length; i++)
            {
                string next = $"{cur}/{parts[i]}";
                if (!AssetDatabase.IsValidFolder(next))
                    AssetDatabase.CreateFolder(cur, parts[i]);
                cur = next;
            }
        }
    }

    private static string SanitizeFileName(string name)
    {
        foreach (char c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return string.IsNullOrEmpty(name) ? "Texture2D" : name;
    }
}
