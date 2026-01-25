Shader "VAT/Particles_URP_Unlit_VAT3"
{
    Properties
    {
        [Header(Playback)]
        [ToggleUI]_B_autoPlayback("Auto Playback", Float) = 1
        _displayFrame("Display Frame (0..N-1, can be fractional)", Float) = 0
        _playbackSpeed("Playback Speed", Float) = 1
        _houdiniFPS("Houdini FPS", Float) = 60
        _numFrames("Num Frames", Float) = 1
        _cutoff("Cut off", Float) = 0.1
        [ToggleUI]_B_frameInterp("Frame Interp", Float) = 1
        _gameTimeAtFirstFrame("Game Time at First Frame", Float) = 0

        [Header(VAT Textures)]
        [NoScaleOffset]_posTexture("Position Texture", 2D) = "black" {}
        [NoScaleOffset]_colTexture("Color/Velocity Texture (optional)", 2D) = "black" {}
        [ToggleUI]_B_useColTex("Use Col Tex", Float) = 0

        [Header(Decode)]
        [ToggleUI]_B_isTexHdr("Pos Tex is HDR", Float) = 0
        _boundMin("Bound Min", Vector) = (0,0,0,0)
        _boundMax("Bound Max", Vector) = (1,1,1,0)

        [Header(Particles)]
        [ToggleUI]_B_spinFromHeading("Spin From Heading Vector", Float) = 0
        _originRadius("Origin Effective Radius", Float) = 0
        [ToggleUI]_B_hideOverlappingOrigin("Hide Particles Overlapping Origin", Float) = 0

        _scaleByVelAmount("Scale By Velocity Amount", Float) = 1
        _heightBaseScale("Particle Height Base Scale", Float) = 1
        _widthBaseScale("Particle Width Base Scale", Float) = 1

        _particleTexUScale("Particle Texture U Scale", Float) = 1
        _particleTexVScale("Particle Texture V Scale", Float) = 1

        [Header(Pscale)]
        [ToggleUI]_B_pscaleInPosA("Pscale Are In Position Alpha", Float) = 1
        _globalPscaleMul("Global Pscale Mul", Float) = 1

        [Header(Render)]
        _BaseMap("Base Map", 2D) = "white" {}
        _BaseColor("Base Color", Color) = (1,1,1,1)
    }

    SubShader
    {
        Tags { "RenderPipeline"="UniversalPipeline" "Queue"="Transparent" "RenderType"="Transparent" }
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        Cull Off

        Pass
        {
            Name "VAT3ParticlesUnlit"
            Tags { "LightMode"="UniversalForward" }

            HLSLPROGRAM
            #pragma target 3.0
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            TEXTURE2D(_posTexture); SAMPLER(sampler_posTexture);
            TEXTURE2D(_colTexture); SAMPLER(sampler_colTexture);
            TEXTURE2D(_BaseMap);    SAMPLER(sampler_BaseMap);

            float4 _BaseColor;
            float4 _boundMin, _boundMax;

            float _B_autoPlayback, _displayFrame, _playbackSpeed, _houdiniFPS, _numFrames, _B_frameInterp, _gameTimeAtFirstFrame;
            float _B_useColTex, _B_isTexHdr;

            float _B_spinFromHeading, _originRadius, _B_hideOverlappingOrigin;
            float _scaleByVelAmount, _heightBaseScale, _widthBaseScale;
            float _particleTexUScale, _particleTexVScale;

            float _B_pscaleInPosA, _globalPscaleMul;

            float _cutoff;

            struct Attributes
            {
                float4 positionOS : POSITION; // quad vertex (usually centered around 0, or 0..1 - doesn't matter)
                float2 uv0 : TEXCOORD0;       // sprite uv
                float2 uv1 : TEXCOORD1;       // VAT data base uv (per particle)
                float3 normal: NORMAL;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                half4  col : TEXCOORD1;
                half3 normal:TEXCOORD2;
            };

            // hash for per-particle randomness (stable)
            float Hash21(float2 p)
            {
                p = frac(p * float2(123.34, 456.21));
                p += dot(p, p + 34.345);
                return frac(p.x * p.y);
            }

            void ComputeFrame(out float frame0, out float frame1, out float alpha, out float anim01_0, out float anim01_1)
            {
                float nFrames = max(_numFrames, 1.0);

                float timeElapsed = _Time.y - _gameTimeAtFirstFrame;
                float animationProgress = (_houdiniFPS / (nFrames - 0.01)) * timeElapsed;
                float looped = frac(animationProgress * _playbackSpeed) * nFrames;

                float t = (_B_autoPlayback > 0.5) ? looped : _displayFrame;
                t = clamp(t, 0.0, nFrames - 1e-4);

                frame0 = floor(t);
                frame1 = fmod(frame0 + 1.0, nFrames);
                alpha  = (_B_frameInterp > 0.5) ? frac(t) : 0.0;

                // Godot 里 animProgressThisFrame 用的是 (currentFramePlusOne-1)/N 的那套，
                // 对粒子这种“V 轴堆帧”的典型导出，直接 frame/N 是等价且更直观。
                anim01_0 = frame0 / nFrames;
                anim01_1 = frame1 / nFrames;
            }

            float3 DecodePos(float3 p01)
            {
                // Godot：HDR 时不走 bounds；非 HDR 才用 bounds range + min
                if (_B_isTexHdr > 0.5) return p01;
                return lerp(_boundMin.xyz, _boundMax.xyz, p01);
            }

            float4 SampleCol(float2 uv)
            {
                return SAMPLE_TEXTURE2D_LOD(_colTexture, sampler_colTexture, uv, 0);
            }

            float4 SamplePos(float2 uv)
            {
                return SAMPLE_TEXTURE2D_LOD(_posTexture, sampler_posTexture, uv, 0);
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;

                // === frame ===
                float f0, f1, a, anim01_0, anim01_1;
                ComputeFrame(f0, f1, a, anim01_0, anim01_1);

                // === data UVs: uv1 is base; V += anim01 ===
                float2 uvData0 = IN.uv1 + float2(0.0, anim01_0);
                float2 uvData1 = IN.uv1 + float2(0.0, anim01_1);

                float4 pos0 = SamplePos(uvData0);
                float4 pos1 = SamplePos(uvData1);

                float3 P0 = DecodePos(pos0.xyz);
                float3 P1 = DecodePos(pos1.xyz);

                // lerp position
                float3 P = lerp(P0, P1, a);

                // === particle enabled / hide origin overlap ===
                float enabled0 = saturate(sign(length(P0) - _originRadius));
                float enabled1 = saturate(sign(length(P1) - _originRadius));
                float enabled  = (_B_frameInterp > 0.5) ? lerp(enabled0, enabled1, a) : enabled0;

                // === pscale ===
                float rand01 = Hash21(IN.uv1);
                float additionalScaleMul = (rand01 + 1.0); // Godot: additionalParticleScaleUniformMultiplier = rand+1
                float particleScaleMul = _globalPscaleMul * additionalScaleMul;

                float pscale0 = pos0.a;
                float pscale1 = pos1.a;
                float pscale  = lerp(pscale0, pscale1, a);

                float particleScale = (_B_pscaleInPosA > 0.5) ? (pscale * particleScaleMul) : particleScaleMul;
                if (_B_hideOverlappingOrigin > 0.5)
                    particleScale *= enabled;

                // === velocity / heading (view space) ===
                float3 deltaOS = (P1 - P0);

                // modelViewMatrix & viewToModelMatrix 等价实现
                float4x4 modelView = mul(GetWorldToViewMatrix(), GetObjectToWorldMatrix());
                float4x4 viewToObj = mul(GetWorldToObjectMatrix(), GetViewToWorldMatrix());

                float3 deltaVS = mul(modelView, float4(deltaOS, 0)).xyz;
                float2 deltaVS2 = deltaVS.xy;
                float velMag = (_scaleByVelAmount * (rand01 * 0.5 + 1.0) * length(deltaVS2));
                // Godot 里有 currentFramePlusOne>=frameCount 的特判；这里我们直接让最后一帧也正常工作

                float heightScale = (_B_spinFromHeading > 0.5) ? (velMag * _heightBaseScale) : _heightBaseScale;

                // === right/up dirs (object space) ===
                float3 rightOS;
                float3 upOS;

                if (_B_spinFromHeading > 0.5)
                {
                    float3 headingVS = (length(deltaVS2) > 1e-6) ? normalize(float3(deltaVS2, 0)) : float3(1,0,0);
                    float3 rightVS = normalize(cross(headingVS, float3(0,0,1))); // camera facing plane
                    float3 upVS    = cross(rightVS, float3(0,0,1));

                    rightOS = normalize(mul(viewToObj, float4(rightVS, 0)).xyz);
                    upOS    = normalize(mul(viewToObj, float4(upVS,    0)).xyz);
                }
                else
                {
                    // random spin in view plane
                    float spin = frac(_Time.y * 1.0 + rand01) * TWO_PI;
                    float3 rightVS = float3(sin(spin), cos(spin), 0);
                    float3 upVS    = cross(rightVS, float3(0,0,1));

                    rightOS = normalize(mul(viewToObj, float4(rightVS, 0)).xyz);
                    upOS    = normalize(mul(viewToObj, float4(upVS,    0)).xyz);
                }

                // === build billboard vertex in object space ===
                float2 quad = (IN.uv0 - 0.5); // center quad
                float3 relRight = rightOS * (_widthBaseScale * particleScale * quad.x);
                float3 relUp    = upOS    * (heightScale     * particleScale * quad.y);

                float3 finalOS = P + relRight + relUp;

                VertexPositionInputs vpi = GetVertexPositionInputs(finalOS);
                OUT.positionHCS = vpi.positionCS;

                // === surface UV (Godot: scale around center) ===
                float2 uvScale = float2(_particleTexUScale, _particleTexVScale);
                float2 uvRemap = uvScale * (-0.5) + 0.5;
                OUT.uv = uvRemap + IN.uv0 * uvScale;

                // === color ===
                half4 col = half4(1,1,1,1);
                if (_B_useColTex > 0.5)
                {
                    float4 c0 = SampleCol(uvData0);
                    float4 c1 = SampleCol(uvData1);
                    col = (half4)lerp(c0, c1, a);
                }
                OUT.col = col * (half4)_BaseColor;

                OUT.normal = TransformObjectToWorldNormal(IN.normal);

                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                
                Light mainLight = GetMainLight();
                float ndl = saturate(dot(IN.normal, mainLight.direction));
                float3 lit = IN.col * ndl * mainLight.color;
                return half4(lit, 1);
            }

            ENDHLSL
        }
    }
}
