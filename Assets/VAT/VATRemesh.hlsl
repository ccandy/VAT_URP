#ifndef VAT_DYNREMESH_INCLUDED
#define VAT_DYNREMESH_INCLUDED

// ============================================================================
// VAT Dynamic Remeshing (Fluid-like) sampler
// "Load-equivalent" WITHOUT using Texture.Load:
//   - Integer texel addressing + texel-center UV + tex2Dlod(mip0)
//   - Deterministic: avoids filtering / mip selection / UV edge blending
//
// Target: GLES 3.x / SM3.x friendly (sampler2D + tex2Dlod only)
//
// Assumptions (matches most SideFX VAT3 Dynamic Remesh exports):
// - Lookup table at (vertexTexel, frameTexel) returns animUV01 in .rg
// - Position texture stores pos01 in .rgb, decoded by BoundMin/BoundMax
// - Rotation texture stores quaternion in [0..1], decoded to [-1..1] then normalized
//
// IMPORTANT IMPORT SETTINGS (ALL 3 textures: lookup/pos/rot):
// - sRGB OFF, MipMap OFF, Compression NONE, Filter = Point, Wrap = Clamp
// ============================================================================

// -------------------------- Compile-time switches ---------------------------
// #define VAT_ENABLE_INTERP 1

// -------------------------- Unity time --------------------------------------
float VAT_TimeSeconds()
{
    return _Time.y;
}

// -------------------------- Textures & samplers -----------------------------
sampler2D _VAT_LookupTable;
float4    _VAT_LookupTable_TexelSize; // x=1/w, y=1/h, z=w, w=h

sampler2D _VAT_PositionTex;
float4    _VAT_PositionTex_TexelSize;

sampler2D _VAT_PositionTex2;          // optional
float4    _VAT_PositionTex2_TexelSize;

sampler2D _VAT_RotationTex;
float4    _VAT_RotationTex_TexelSize;

// -------------------------- Material parameters -----------------------------
CBUFFER_START(UnityPerMaterial)

float _VAT_AutoPlayback;
float _VAT_GameTimeAtFirstFrame;
float _VAT_DisplayFrame;
float _VAT_PlaybackSpeed;
float _VAT_HoudiniFPS;

float _VAT_SupportSurfaceNormals;

// Data
float _VAT_FrameCount;

float _VAT_BoundMaxX, _VAT_BoundMaxY, _VAT_BoundMaxZ;
float _VAT_BoundMinX, _VAT_BoundMinY, _VAT_BoundMinZ;

// Optional switches
float _VAT_PositionsRequireTwoTextures;

// Axis control (0 = X is vertex / Y is frame, 1 = swapped: X=frame / Y=vertex)
float _VAT_LookupAxisSwapped;

CBUFFER_END

// -------------------------- Small math utilities ----------------------------
float3 VAT_BoundMin() { return float3(_VAT_BoundMinX, _VAT_BoundMinY, _VAT_BoundMinZ); }
float3 VAT_BoundMax() { return float3(_VAT_BoundMaxX, _VAT_BoundMaxY, _VAT_BoundMaxZ); }

float3 VAT_DecodePos(float3 pos01)
{
    return lerp(VAT_BoundMin(), VAT_BoundMax(), pos01);
}

float4 VAT_DecodeQuat(float4 q01)
{
    float4 q = q01 * 2.0 - 1.0;
    return q * rsqrt(max(dot(q, q), 1e-12));
}

float3 VAT_Rotate(float3 v, float4 q)
{
    float3 t = 2.0 * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

// -------------------------- Frame computation -------------------------------
float VAT_ComputeFrameFloat()
{
    float frames = max(_VAT_FrameCount, 1.0);

    if (_VAT_AutoPlayback > 0.5)
    {
        float t = (VAT_TimeSeconds() - _VAT_GameTimeAtFirstFrame) * _VAT_PlaybackSpeed;
        float f = t * _VAT_HoudiniFPS;

        // Loop in [0, frames)
        f = f - floor(f / frames) * frames;
        return f;
    }

    return clamp(_VAT_DisplayFrame, 0.0, frames - 1.0);
}

// -------------------------- "Load-equivalent" fetch -------------------------
int2 VAT_TexSizeWH(float4 texelSize)
{
    return int2((int)max(texelSize.z, 1.0), (int)max(texelSize.w, 1.0));
}

int2 VAT_ClampTexel(int2 p, int2 sizeWH)
{
    return clamp(p, int2(0,0), sizeWH - 1);
}

// Exact-texel-like fetch: integer texel -> texel center uv -> tex2Dlod mip0
float4 VAT_FetchTexel_LOD0(sampler2D tex, int2 p, int2 sizeWH)
{
    p = VAT_ClampTexel(p, sizeWH);
    float2 uvCenter = ((float2)p + 0.5) / (float2)sizeWH;
    return tex2Dlod(tex, float4(uvCenter, 0, 0));
}

// Convert animUV01 -> integer texel coord (clamped)
int2 VAT_UV01_ToTexel(float2 uv01, int2 sizeWH)
{
    // If uv01 hits 1.0, floor(size) would equal size => clamp fixes it.
    int2 p = (int2)floor(uv01 * (float2)sizeWH);
    return VAT_ClampTexel(p, sizeWH);
}

// -------------------------- Lookup table addressing -------------------------
// vertexCoord01 is baked as (vertexTexel + 0.5) / vertexAxisLen
// We convert it back to integer vertex texel based on lookup texture dims.
int2 VAT_LookupTexel_FromVertexCoordAndFrame(float vertexCoord01, int frameIndex)
{
    int2 lutWH = VAT_TexSizeWH(_VAT_LookupTable_TexelSize);

    if (_VAT_LookupAxisSwapped > 0.5)
    {
        // swapped: X = frame, Y = vertex
        int vertexTexel = (int)floor(vertexCoord01 * (float)lutWH.y);
        vertexTexel = clamp(vertexTexel, 0, lutWH.y - 1);

        int frameTexel  = clamp(frameIndex, 0, lutWH.x - 1);
        return int2(frameTexel, vertexTexel);
    }
    else
    {
        // normal: X = vertex, Y = frame
        int vertexTexel = (int)floor(vertexCoord01 * (float)lutWH.x);
        vertexTexel = clamp(vertexTexel, 0, lutWH.x - 1);

        int frameTexel  = clamp(frameIndex, 0, lutWH.y - 1);
        return int2(vertexTexel, frameTexel);
    }
}

float2 VAT_DecodeAnimUV(float4 lookupSample)
{
    return lookupSample.rg;
}

// -------------------------- Public API -------------------------------------
struct VAT_DynRemesh_Result
{
    float3 posOS;
    float3 nrmOS;
    float2 animUV;
};

VAT_DynRemesh_Result VAT_DynRemesh_SampleAtFrameI(float vertexCoord01, int frameI)
{
    VAT_DynRemesh_Result r;

    // 1) Lookup -> animUV
    int2 lutWH = VAT_TexSizeWH(_VAT_LookupTable_TexelSize);
    int2 lutP  = VAT_LookupTexel_FromVertexCoordAndFrame(vertexCoord01, frameI);
    float4 lk  = VAT_FetchTexel_LOD0(_VAT_LookupTable, lutP, lutWH);
    float2 uv  = VAT_DecodeAnimUV(lk);

    r.animUV = uv;

    // 2) Position
    int2 posWH = VAT_TexSizeWH(_VAT_PositionTex_TexelSize);
    int2 posP  = VAT_UV01_ToTexel(uv, posWH);
    float3 pos01 = VAT_FetchTexel_LOD0(_VAT_PositionTex, posP, posWH).rgb;

    // Optional second position texture:
    // Without your exact SideFX mode, we do NOT guess a combine rule.
    // Keep for compatibility; default behavior is ignore.
    if (_VAT_PositionsRequireTwoTextures > 0.5)
    {
        // If you later confirm your export mode, we can implement a correct combine.
        // int2 pos2WH = VAT_TexSizeWH(_VAT_PositionTex2_TexelSize);
        // int2 pos2P  = VAT_UV01_ToTexel(uv, pos2WH);
        // float3 pos01_2 = VAT_FetchTexel_LOD0(_VAT_PositionTex2, pos2P, pos2WH).rgb;
        // pos01 = Combine(pos01, pos01_2);
    }

    r.posOS = VAT_DecodePos(pos01);

    // 3) Normal from rotation quat
    r.nrmOS = float3(0, 1, 0);
    if (_VAT_SupportSurfaceNormals > 0.5)
    {
        int2 rotWH = VAT_TexSizeWH(_VAT_RotationTex_TexelSize);
        int2 rotP  = VAT_UV01_ToTexel(uv, rotWH);
        float4 q01 = VAT_FetchTexel_LOD0(_VAT_RotationTex, rotP, rotWH);
        float4 q   = VAT_DecodeQuat(q01);

        // Default basis; if lighting looks rotated, try float3(0,1,0)
        r.nrmOS = normalize(VAT_Rotate(float3(0,0,1), q));
    }

    return r;
}

VAT_DynRemesh_Result VAT_DynRemesh_Sample(float vertexCoord01, float frameFloat)
{
    float frames = max(_VAT_FrameCount, 1.0);
    int f0 = clamp((int)floor(frameFloat), 0, (int)frames - 1);

#if defined(VAT_ENABLE_INTERP)
    int f1 = (f0 + 1 < (int)frames) ? (f0 + 1) : 0;
    float a = frac(frameFloat);

    VAT_DynRemesh_Result r0 = VAT_DynRemesh_SampleAtFrameI(vertexCoord01, f0);
    VAT_DynRemesh_Result r1 = VAT_DynRemesh_SampleAtFrameI(vertexCoord01, f1);

    VAT_DynRemesh_Result r;
    r.animUV = r0.animUV;
    r.posOS = lerp(r0.posOS, r1.posOS, a);
    r.nrmOS = normalize(lerp(r0.nrmOS, r1.nrmOS, a));
    return r;
#else
    return VAT_DynRemesh_SampleAtFrameI(vertexCoord01, f0);
#endif
}

#endif // VAT_DYNREMESH_INCLUDED
