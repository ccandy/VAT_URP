Shader "VAT/URP VAT Test"
{
    Properties
    {
        _BaseColor("Base Color", Color) = (1,1,1,1)

        // VAT textures
        _VAT_LookupTable("VAT Lookup", 2D) = "white" {}
        _VAT_PositionTex("VAT Position", 2D) = "black" {}
        _VAT_RotationTex("VAT Rotation", 2D) = "gray" {}
        _VAT_ColorTex("VAT Color", 2D) = "white" {}

        // Playback
        _VAT_AutoPlayback("Auto Playback", Float) = 1
        _VAT_GameTimeAtFirstFrame("GameTimeAtFirstFrame", Float) = 0
        _VAT_DisplayFrame("Display Frame", Float) = 0
        _VAT_PlaybackSpeed("Playback Speed", Float) = 1
        _VAT_HoudiniFPS("Houdini FPS", Float) = 24
        _VAT_FrameCount("Frame Count", Float) = 120

        // Bounds
        _VAT_BoundMinX("BoundMinX", Float) = -1
        _VAT_BoundMinY("BoundMinY", Float) = -1
        _VAT_BoundMinZ("BoundMinZ", Float) = -1
        _VAT_BoundMaxX("BoundMaxX", Float) = 1
        _VAT_BoundMaxY("BoundMaxY", Float) = 1
        _VAT_BoundMaxZ("BoundMaxZ", Float) = 1

        // Switches
        _VAT_SupportSurfaceNormals("Support Surface Normals", Float) = 1
        _VAT_PositionsRequireTwoTextures("PositionsRequireTwoTextures", Float) = 0
        _VAT_LookupAxisSwapped("LookupAxisSwapped", Float) = 0
    }

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "RenderType"="Opaque" "Queue"="Geometry" }

        Pass
        {
            Name "Forward"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            // URP core
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // ---- Your VAT include (change this path) ----
            #include "Assets/VAT/VATRemesh.hlsl"

            TEXTURE2D(_VAT_ColorTex);
            SAMPLER(sampler_VAT_ColorTex);

            float4 _BaseColor;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS   : NORMAL;
                float2 uv2        : TEXCOORD1; // Unity: UV2 is TEXCOORD1 by default import
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS   : TEXCOORD0;
                float3 color      : TEXCOORD1;
            };

            Varyings vert(Attributes v)
            {
                Varyings o;

                // vertexCoord01 baked in uv2.x by our generator
                float vertexCoord01 = v.uv2.x;

                float frameFloat = VAT_ComputeFrameFloat(); // from your include
                VAT_DynRemesh_Result r = VAT_DynRemesh_Sample(vertexCoord01, frameFloat);

                float3 posWS = TransformObjectToWorld(r.posOS);
                //float3 posWS = TransformObjectToWorld(v.positionOS);
                float3 nrmWS = TransformObjectToWorldNormal(r.nrmOS);

                o.positionCS = TransformWorldToHClip(posWS);
                o.normalWS = normalize(nrmWS);

                // Optional: sample color atlas via animUV
                float3 vatCol = SAMPLE_TEXTURE2D_LOD(_VAT_ColorTex, sampler_VAT_ColorTex, r.animUV, 0).rgb;
                o.color = vatCol;

                return o;
            }

            half4 frag(Varyings i) : SV_Target
            {
                // super simple lambert with main light
                Light mainLight = GetMainLight();
                float ndl = saturate(dot(i.normalWS, mainLight.direction));
                float3 lit = i.color * (_BaseColor.rgb) * (0.2 + ndl * mainLight.color.rgb);
                return half4(lit, 1);
            }
            ENDHLSL
        }
    }
}
