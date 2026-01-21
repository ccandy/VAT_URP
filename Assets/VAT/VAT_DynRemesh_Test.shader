Shader "VAT/DynamicRemesh_URP_Unlit_VAT3_Final"
{
    Properties
    {
        [Header(Playback)]
        [ToggleUI]_B_autoPlayback("Auto Playback", Float) = 1
        _displayFrame("Display Frame (0..N-1, can be fractional)", Float) = 0
        _playbackSpeed("Playback Speed (use positive)", Float) = 1
        [ToggleUI]_B_reversePlayback("Reverse Playback", Float) = 1
        _houdiniFPS("Houdini FPS", Float) = 60
        _numFrames("Num Frames", Float) = 1
        [ToggleUI]_B_frameInterp("Frame Interp", Float) = 1

        [Header(VAT3 DynamicMesh Lookup)]
        [ToggleUI]_B_lookupTexIsHDR("Lookup Tex Is HDR (range=2048)", Float) = 0
        [ToggleUI]_B_lookupFlipV("Lookup Flip V", Float) = 0

        // ✅ 你确认必须开
        [ToggleUI]_B_animUVFlipV("Flip animUV V (OneMinus)", Float) = 1
        [ToggleUI]_B_animUVSwapXY("Swap animUV XY", Float) = 0

        [Header(Position Decode)]
        [ToggleUI]_B_useBounds("Decode pos01 using Bounds", Float) = 1
        _posMin("Pos Min (xyz)", Vector) = (0,0,0,0)
        _posMax("Pos Max (xyz)", Vector) = (1,1,1,0)

        [NoScaleOffset]_lookupTexture("Lookup Texture (VAT3 RGBA)", 2D) = "black" {}
        [NoScaleOffset]_posTexture("Position Texture", 2D) = "black" {}

        [Header(Base Color)]
        _BaseMap("Base Map", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
        _BaseUVSource("Base UV Source (0=uv0, 1=uv1)", Float) = 1
    }

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" "RenderType"="Opaque" }

        Pass
        {
            Name "SRPDefaultUnlit"
            Tags { "LightMode"="SRPDefaultUnlit" }

            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            TEXTURE2D(_lookupTexture); SAMPLER(sampler_lookupTexture);
            TEXTURE2D(_posTexture);    SAMPLER(sampler_posTexture);
            TEXTURE2D(_BaseMap);       SAMPLER(sampler_BaseMap);

            float4 _BaseColor;
            float4 _posMin, _posMax;

            float _B_autoPlayback, _displayFrame, _playbackSpeed, _B_reversePlayback, _houdiniFPS, _numFrames, _B_frameInterp;
            float _B_lookupTexIsHDR, _B_lookupFlipV, _B_animUVFlipV, _B_animUVSwapXY;
            float _B_useBounds;
            float _BaseUVSource;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv0 : TEXCOORD0;   // VAT address UV (lookup base UV)
                float2 uv1 : TEXCOORD1;   // surface UV (if present)
                float4 color : COLOR;
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            float3 DecodePos(float3 p01)
            {
                return (_B_useBounds > 0.5) ? lerp(_posMin.xyz, _posMax.xyz, p01) : p01;
            }

            // frame0/frame1 in [0..N-1], alpha in [0..1)
            void ComputeFrame(out float frame0, out float frame1, out float alpha)
            {
                float nFrames = max(_numFrames, 1.0);

                float t;
                if (_B_autoPlayback > 0.5)
                {
                    float sp = max(_playbackSpeed, 0.0); // always positive
                    t = _Time.y * sp * _houdiniFPS;
                    t = fmod(max(t, 0.0), nFrames);

                    // ✅ reverse by mirroring progress inside the loop
                    if (_B_reversePlayback > 0.5)
                    {
                        t = (nFrames - t);
                        if (t >= nFrames) t -= nFrames;
                    }
                }
                else
                {
                    t = clamp(_displayFrame, 0.0, nFrames - 1.0);
                }

                frame0 = floor(t);
                frame1 = fmod(frame0 + 1.0, nFrames);
                alpha  = (_B_frameInterp > 0.5) ? frac(t) : 0.0;
            }

            // VAT3 DynamicMesh: lookupUV = uv0 + (0, animProgress01)
            float2 BuildLookupUV_VAT3(float2 baseUV0, float animProgress01)
            {
                float2 uv = baseUV0 + float2(0.0, animProgress01);
                if (_B_lookupFlipV > 0.5) uv.y = 1.0 - uv.y;
                return uv;
            }

            // VAT3 DynamicMesh decode: animUV = (R + G/range, B + A/range)
            float2 DecodeAnimUV_VAT3(float4 lookupRGBA01)
            {
                float range = (_B_lookupTexIsHDR > 0.5) ? 2048.0 : 255.0;

                float2 uv = float2(
                    lookupRGBA01.r + lookupRGBA01.g / range,
                    lookupRGBA01.b + lookupRGBA01.a / range
                );

                if (_B_animUVSwapXY > 0.5) uv = uv.yx;
                if (_B_animUVFlipV > 0.5)  uv.y = 1.0 - uv.y;

                return uv;
            }

            float2 SampleAnimUV(float2 baseUV0, float frameIdx)
            {
                float nFrames = max(_numFrames, 1.0);
                float animProgress01 = frameIdx / nFrames; // 0..(N-1)/N

                float2 lookupUV = BuildLookupUV_VAT3(baseUV0, animProgress01);
                float4 v = SAMPLE_TEXTURE2D_LOD(_lookupTexture, sampler_lookupTexture, lookupUV, 0);
                return DecodeAnimUV_VAT3(v);
            }

            float3 SamplePosRGB(float2 animUV01)
            {
                return SAMPLE_TEXTURE2D_LOD(_posTexture, sampler_posTexture, animUV01, 0).rgb;
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;

                float f0, f1, a;
                ComputeFrame(f0, f1, a);

                float2 baseUV0 = IN.uv0;

                float2 animUV0 = SampleAnimUV(baseUV0, f0);
                float2 animUV1 = SampleAnimUV(baseUV0, f1);

                float3 p0 = SamplePosRGB(animUV0);
                float3 p1 = SamplePosRGB(animUV1);

                float3 p01 = lerp(p0, p1, a);
                float3 posOS = DecodePos(p01);

                VertexPositionInputs vpi = GetVertexPositionInputs(posOS);
                OUT.positionHCS = vpi.positionCS;

                OUT.uv = (_BaseUVSource > 0.5) ? IN.uv1 : IN.uv0;
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half4 baseTex = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv);
                return baseTex * _BaseColor;
            }

            ENDHLSL
        }
    }
}
