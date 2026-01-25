Shader "VAT/DynamicRemesh_URP_Lit_VAT3_WithRot"
{
    Properties
    {
        [Header(Playback)]
        [ToggleUI]_B_autoPlayback("Auto Playback", Float) = 1
        _displayFrame("Display Frame (0..N-1, fractional ok)", Float) = 0
        _playbackSpeed("Playback Speed", Float) = 1
        [ToggleUI]_B_reversePlayback("Reverse Playback", Float) = 0
        _houdiniFPS("Houdini FPS", Float) = 60
        _numFrames("Num Frames", Float) = 1
        [ToggleUI]_B_frameInterp("Frame Interp", Float) = 1

        [Header(VAT3 DynamicMesh Lookup)]
        [ToggleUI]_B_lookupTexIsHDR("Lookup Tex Is HDR (range=2048)", Float) = 0
        [ToggleUI]_B_lookupFlipV("Lookup Flip V", Float) = 0
        [ToggleUI]_B_animUVFlipV("Flip animUV V (1 - v)", Float) = 1
        [ToggleUI]_B_animUVSwapXY("Swap animUV XY", Float) = 0

        [Header(Position Decode)]
        [ToggleUI]_B_useBounds("Decode pos01 using Bounds", Float) = 1
        _posMin("Pos Min (xyz)", Vector) = (0,0,0,0)
        _posMax("Pos Max (xyz)", Vector) = (1,1,1,0)

        [NoScaleOffset]_lookupTexture("Lookup Texture (VAT3 RGBA)", 2D) = "black" {}
        [NoScaleOffset]_posTexture("Position Texture", 2D) = "black" {}

        [Header(Rotation Normal)]
        [ToggleUI]_B_useRot("Use Rot Texture", Float) = 1
        [ToggleUI]_B_isTexHdr("Rot/Pos Are HDR (skip 0.5->2 decode)", Float) = 0
        [ToggleUI]_B_supportSurfaceNormalMaps("Tangent Valid", Float) = 1
        [NoScaleOffset]_rotTexture("Rotation Texture (VAT3)", 2D) = "black" {}

        [Header(Lighting)]
        _BaseMap("Base Map", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
        _BaseUVSource("Base UV Source (0=uv0, 1=uv1)", Float) = 1

        [Header(Debug)]
        [ToggleUI]_B_debugNormal("Debug Output Normal", Float) = 0
    }

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" "RenderType"="Opaque" }

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex vert
            #pragma fragment frag

            // URP lighting/shadow variants
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fog

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_lookupTexture); SAMPLER(sampler_lookupTexture);
            TEXTURE2D(_posTexture);    SAMPLER(sampler_posTexture);
            TEXTURE2D(_rotTexture);    SAMPLER(sampler_rotTexture);
            TEXTURE2D(_BaseMap);       SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                float4 _BaseColor;
                float4 _posMin, _posMax;

                float _B_autoPlayback, _displayFrame, _playbackSpeed, _B_reversePlayback, _houdiniFPS, _numFrames, _B_frameInterp;
                float _B_lookupTexIsHDR, _B_lookupFlipV, _B_animUVFlipV, _B_animUVSwapXY;
                float _B_useBounds;
                float _BaseUVSource;

                float _B_useRot, _B_isTexHdr, _B_supportSurfaceNormalMaps;
                float _B_debugNormal;
            CBUFFER_END

            static const float3 kNormalDefault  = float3(0.0,  1.0, 0.0);
            static const float3 kTangentDefault = float3(-1.0, 0.0, 0.0);

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv0 : TEXCOORD0;
                float2 uv1 : TEXCOORD1;
                uint vertexID : SV_VertexID;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv          : TEXCOORD0;

                float3 positionWS  : TEXCOORD1;
                float3 normalWS    : TEXCOORD2;

                float4 shadowCoord : TEXCOORD3;
                half   fogFactor   : TEXCOORD4;
            };

            float3 DecodePos(float3 p01)
            {
                return (_B_useBounds > 0.5) ? lerp(_posMin.xyz, _posMax.xyz, p01) : p01;
            }

            void ComputeFrame(out float frame0, out float frame1, out float alpha)
            {
                float nFrames = max(_numFrames, 1.0);
                float t;

                if (_B_autoPlayback > 0.5)
                {
                    float sp = max(_playbackSpeed, 0.0);
                    t = _Time.y * sp * _houdiniFPS;
                    t = fmod(max(t, 0.0), nFrames);

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

            float2 BuildLookupUV_VAT3(float2 baseUV0, float animProgress01)
            {
                float2 uv = baseUV0 + float2(0.0, animProgress01);
                if (_B_lookupFlipV > 0.5) uv.y = 1.0 - uv.y;
                return uv;
            }

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
                float animProgress01 = frameIdx / nFrames;

                float2 lookupUV = BuildLookupUV_VAT3(baseUV0, animProgress01);
                float4 v = SAMPLE_TEXTURE2D_LOD(_lookupTexture, sampler_lookupTexture, lookupUV, 0);
                return DecodeAnimUV_VAT3(v);
            }

            float3 SamplePosRGB(float2 animUV01)
            {
                return SAMPLE_TEXTURE2D_LOD(_posTexture, sampler_posTexture, animUV01, 0).rgb;
            }

            float4 SampleRotRGBA(float2 animUV01)
            {
                return SAMPLE_TEXTURE2D_LOD(_rotTexture, sampler_rotTexture, animUV01, 0);
            }

            void DecodeRotationTexture(float4 rotTexData,
                                      out float3 outNormalOS,
                                      float3 normalDefaults)
            {
                // Godot 版本里 normal/tangent 都用同一套解码；这里我们只先拿 normal
                float3 crossNormal    = cross(rotTexData.rgb, normalDefaults);
                float3 normalLengMul  = rotTexData.aaa * normalDefaults;
                float3 normalToUnpack = cross(rotTexData.rgb, normalLengMul + crossNormal);
                outNormalOS = normalToUnpack * 2.0 + normalDefaults;
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
                float3 posOS = DecodePos(lerp(p0, p1, a));

                VertexPositionInputs vpi = GetVertexPositionInputs(posOS);
                OUT.positionHCS = vpi.positionCS;
                OUT.positionWS  = vpi.positionWS;

                OUT.uv = (_BaseUVSource > 0.5) ? IN.uv1 : IN.uv0;

                float3 normalOS = kNormalDefault;

                if (_B_useRot > 0.5)
                {
                    float4 r0 = SampleRotRGBA(animUV0);
                    float4 r1 = SampleRotRGBA(animUV1);

                    if (_B_isTexHdr < 0.5)
                    {
                        r0 = (r0 - 0.5) * 2.0;
                        r1 = (r1 - 0.5) * 2.0;
                    }

                    float4 r = lerp(r0, r1, a);

                    float3 nOS;
                    DecodeRotationTexture(r, nOS, kNormalDefault);
                    normalOS = normalize(nOS);
                }

                OUT.normalWS = TransformObjectToWorldNormal(normalOS);

                OUT.shadowCoord = TransformWorldToShadowCoord(OUT.positionWS);
                OUT.fogFactor = ComputeFogFactor(OUT.positionHCS.z);

                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half4 baseTex = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv);
                half4 albedo4 = baseTex * (half4)_BaseColor;
                half3 albedo = albedo4.rgb;
                half  alpha  = albedo4.a;

                half3 N = normalize((half3)IN.normalWS);

                if (_B_debugNormal > 0.5)
                {
                    return half4(N * 0.5h + 0.5h, 1.0h);
                }

                // Ambient from SH
                half3 ambient = SampleSH(N) * albedo;

                // Main light
                Light mainLight = GetMainLight(IN.shadowCoord);
                half3 Lm = normalize((half3)mainLight.direction);
                half  NdotLm = saturate(dot(N, Lm));
                half3 diffuseMain = albedo * (half3)mainLight.color * NdotLm
                                  * (half)mainLight.distanceAttenuation
                                  * (half)mainLight.shadowAttenuation;

                half3 color = ambient + diffuseMain;

                // Additional lights (pixel)
                #if defined(_ADDITIONAL_LIGHTS)
                uint lightCount = GetAdditionalLightsCount();
                for (uint li = 0u; li < lightCount; ++li)
                {
                    Light l = GetAdditionalLight(li, IN.positionWS);
                    half3 L = normalize((half3)l.direction);
                    half  ndl = saturate(dot(N, L));
                    color += albedo * (half3)l.color * ndl * (half)l.distanceAttenuation * (half)l.shadowAttenuation;
                }
                #endif

                // Fog
                color = MixFog(color, IN.fogFactor);

                return half4(color, alpha);
            }

            ENDHLSL
        }
    }
}
