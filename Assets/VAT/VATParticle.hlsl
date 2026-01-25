#ifndef VAT3_PARTICLES_GODOTLIKE_INCLUDED
#define VAT3_PARTICLES_GODOTLIKE_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

//============================================================
// SideFX VAT3 Particles (Godot-like implementation)
//
// EXPECTS (like Godot VAT3MODE_PARTICLES):
// - Position texture stores per-particle positions over time
// - Frames are laid out vertically inside an "active pixels" region
// - activePixelsRatioX/Y tells how much of the texture is valid (0..1)
// - Sample UV: (u*activeX, v*activeY + animProgress*activeY)
//
// Unity import settings (MUST):
// - sRGB OFF, MipMap OFF, Filter Point, Wrap Clamp
//============================================================

// If you want velocity from color RGB (Godot: VAT_VIEWXY_SOURCE_COLOR_RGB)
//#define VAT_VIEWXY_SOURCE_COLOR_RGB 1

TEXTURE2D(_VAT_PosTex); SAMPLER(sampler_VAT_PosTex);
TEXTURE2D(_VAT_ColTex); SAMPLER(sampler_VAT_ColTex); // optional

CBUFFER_START(VAT3ParticleParams)
    // Playback
float _VAT_AutoPlayback; // 0/1
float _VAT_DisplayFrame; // 0..N-1 (can fractional)
float _VAT_PlaybackSpeed; // positive
float _VAT_HoudiniFPS; // e.g. 60
float _VAT_FrameCount; // N
float _VAT_Interpolate; // 0/1

    // Decode
float _VAT_IsTexHDR; // 0/1
float3 _VAT_BoundMin;
float3 _VAT_BoundMax;

    // Godot-like active pixels ratio
    // If you don't know it: set X=1, Y=1/_VAT_FrameCount (most SideFX exports)
float2 _VAT_ActivePixelsRatio; // (activeX, activeY)

    // Particle options
float _VAT_OriginRadius;
float _VAT_HideOverlappingOrigin; // 0/1

float _VAT_ScaleByVelocityAmount;
float _VAT_HeightBaseScale;
float _VAT_WidthBaseScale;

float _VAT_ParticleTexUScale;
float _VAT_ParticleTexVScale;

    // pscale
float _VAT_PScaleInPosA; // 0/1
float _VAT_GlobalPScaleMul; // multiplier

    // Random scale ranges (optional)
float _VAT_RandScaleMin;
float _VAT_RandScaleMax;
float _VAT_RandVelScaleMin;
float _VAT_RandVelScaleMax;

    // Optional cull by input vatUV.y (Godot had: >=0.9 => off)
float _VAT_CullYThreshold; // set to 2 to disable
CBUFFER_END

struct VAT3_ParticleVertexIn
{
    float2 quadUV; // 0..1 (billboard corner)
    float2 vatUV; // per-particle address (like Godot texCoord1)
    float2 randUV; // random seed
};

struct VAT3_ParticleOut
{
    float3 positionOS;
    float3 normalWS;
    float3 tangentWS;
    float2 surfaceUV;
    float enabled;
};

// ---------- helpers ----------
inline float VAT_Rand01(float2 seed)
{
    return frac(sin(dot(seed, float2(22.9898, 178.24313))) * 12858.24161);
}

inline float3 VAT_DecodePos(float3 p)
{
    if (_VAT_IsTexHDR > 0.5)
        return p;
    return p * (_VAT_BoundMax - _VAT_BoundMin) + _VAT_BoundMin;
}

inline float2 VAT_TexelCenterClamp(float2 uv, float2 texSize)
{
    // clamp to [0.5/size, 1-0.5/size]
    float2 mn = 0.5 / texSize;
    float2 mx = 1.0 - mn;
    return clamp(uv, mn, mx);
}

inline void VAT_ComputeFrame_Godot(out float frame0, out float frame1, out float alpha, out float isLastFrame)
{
    float N = max(_VAT_FrameCount, 1.0);

    float t;
    if (_VAT_AutoPlayback > 0.5)
    {
        // Godot:
        // animationProgress = (houdiniFPS / (frameCount - 0.01)) * timeElapsed
        // looped = fract(animationProgress * playbackSpeed) * frameCount
        float animationProgress = (_VAT_HoudiniFPS / max(N - 0.01, 0.01)) * _Time.y;
        float looped = frac(animationProgress * max(_VAT_PlaybackSpeed, 0.0)) * N;
        t = looped;
    }
    else
    {
        t = clamp(_VAT_DisplayFrame, 0.0, N - 1.0);
    }

    frame0 = floor(t);
    frame1 = min(frame0 + 1.0, N - 1.0); // IMPORTANT: no wrap (Godot-style)

    alpha = (_VAT_Interpolate > 0.5) ? frac(t) : 0.0;

    isLastFrame = step(N - 1.0 - 1e-5, frame0); // 1 if frame0 >= N-1
}

// Godot-like UV build for particles (non dynamicmesh)
inline float2 VAT_BuildUV_Particles(float2 vatUV, float animProgress01)
{
    float2 active = _VAT_ActivePixelsRatio;
    // safe fallback if user didn't set it
    if (active.x <= 0.0)
        active.x = 1.0;
    if (active.y <= 0.0)
        active.y = 1.0 / max(_VAT_FrameCount, 1.0);

    float2 scaled = float2(vatUV.x * active.x, vatUV.y * active.y);
    float2 uv = float2(scaled.x, scaled.y + animProgress01 * active.y);
    return uv;
}

inline float3x3 VAT_ViewToObject3x3()
{
    float4x4 V2W = UNITY_MATRIX_I_V;
    float4x4 W2O = UNITY_MATRIX_I_M;
    return (float3x3) mul(W2O, V2W);
}

inline float3x3 VAT_ObjectToView3x3()
{
    float4x4 O2W = UNITY_MATRIX_M;
    float4x4 W2V = UNITY_MATRIX_V;
    return (float3x3) mul(W2V, O2W);
}

// ---------- main ----------
inline VAT3_ParticleOut VAT3_EvalParticle_GodotLike(in VAT3_ParticleVertexIn IN)
{
    VAT3_ParticleOut OUT;
    OUT.enabled = 1.0;

    if (IN.vatUV.y >= _VAT_CullYThreshold)
        OUT.enabled = 0.0;

    float f0, f1, a, isLast;
    VAT_ComputeFrame_Godot(f0, f1, a, isLast);

    float N = max(_VAT_FrameCount, 1.0);
    float prog0 = f0 / N;
    float prog1 = f1 / N;

    float2 uv0 = VAT_BuildUV_Particles(IN.vatUV, prog0);
    float2 uv1 = VAT_BuildUV_Particles(IN.vatUV, prog1);

    // texel-center clamp (prevents edge sampling explosions)
    float2 posTexSize = float2(_VAT_PosTex_TexelSize.z, _VAT_PosTex_TexelSize.w);
    uv0 = VAT_TexelCenterClamp(uv0, posTexSize);
    uv1 = VAT_TexelCenterClamp(uv1, posTexSize);

    float4 pos0 = SAMPLE_TEXTURE2D_LOD(_VAT_PosTex, sampler_VAT_PosTex, uv0, 0);
    float4 pos1 = SAMPLE_TEXTURE2D_LOD(_VAT_PosTex, sampler_VAT_PosTex, uv1, 0);

    float3 P0 = VAT_DecodePos(pos0.xyz);
    float3 P1 = VAT_DecodePos(pos1.xyz);

    // origin gating (Godot)
    float enabled0 = saturate(sign(length(P0) - _VAT_OriginRadius));
    float enabled1 = saturate(sign(length(P1) - _VAT_OriginRadius));

    float3 Plerp = lerp(P0, P1, a);

    float3 particleLocal;
    if (_VAT_Interpolate > 0.5)
    {
        if (_VAT_PScaleInPosA < 0.5)
        {
            float3 lepred = (enabled1 > 0.0) ? Plerp : P0;
            particleLocal = (enabled0 > 0.0) ? lepred : P1;
        }
        else
        {
            particleLocal = Plerp;
        }
    }
    else
    {
        particleLocal = P0;
    }

    float enabled = OUT.enabled;
    if (_VAT_HideOverlappingOrigin > 0.5)
        enabled *= enabled0;
    OUT.enabled = enabled;

    // randoms
    float r = VAT_Rand01(IN.randUV);
    float randScaleMul = lerp(_VAT_RandScaleMin, _VAT_RandScaleMax, r);
    float randVelMul = lerp(_VAT_RandVelScaleMin, _VAT_RandVelScaleMax, r);

    // pscale
    float pscale = (_VAT_PScaleInPosA > 0.5) ? pos0.a : 1.0;
    float particleScale = pscale * _VAT_GlobalPScaleMul * randScaleMul;
    if (_VAT_HideOverlappingOrigin > 0.5)
        particleScale *= enabled0;

    // velocity (for stretching)
    float3 deltaOS;
#if defined(VAT_VIEWXY_SOURCE_COLOR_RGB)
        float4 col0 = SAMPLE_TEXTURE2D_LOD(_VAT_ColTex, sampler_VAT_ColTex, uv0, 0);
        deltaOS = col0.xyz;
#else
    deltaOS = (P1 - P0);
#endif

    float3x3 O2V = VAT_ObjectToView3x3();
    float2 deltaVS2 = mul(O2V, deltaOS).xy;
    float velMag = length(deltaVS2);

    // Godot special-case for last frame: magnitude = 1.0
    float particleVelocityMagnitude = (isLast > 0.5) ? 1.0 : (_VAT_ScaleByVelocityAmount * randVelMul * velMag);
    particleVelocityMagnitude = max(particleVelocityMagnitude, 1e-4);

    float heightScale = _VAT_HeightBaseScale * particleVelocityMagnitude;

    // billboard basis (object space)
    float3x3 V2O = VAT_ViewToObject3x3();
    float3 normalOS = normalize(mul(V2O, float3(0, 0, 1)));
    float3 rightOS = normalize(mul(V2O, float3(-1, 0, 0)));
    float3 upOS = mul(V2O, float3(0, 1, 0));

    float3 relRight = rightOS * _VAT_WidthBaseScale * particleScale * (IN.quadUV.x - 0.5);
    float3 relUp = upOS * heightScale * particleScale * (IN.quadUV.y - 0.5);

    OUT.positionOS = particleLocal + relRight + relUp;

    OUT.normalWS = normalize(TransformObjectToWorldNormal(normalOS));
    OUT.tangentWS = normalize(TransformObjectToWorldDir(rightOS));

    // surface UV scaling (Godot)
    float2 uvScale = float2(_VAT_ParticleTexUScale, _VAT_ParticleTexVScale);
    float2 uvRemap = uvScale * (-0.5) + float2(0.5, 0.5);
    OUT.surfaceUV = uvRemap + IN.quadUV * uvScale;

    return OUT;
}

#endif
