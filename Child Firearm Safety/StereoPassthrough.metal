//
//  StereoPassthrough.metal
//  Child Firearm Safety
//
//  Metal shaders for GPU-accelerated stereo camera passthrough
//

#include <metal_stdlib>
using namespace metal;

// Vertex input structure
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// Vertex output / Fragment input structure
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader for stereo passthrough
vertex VertexOut stereoPassthroughVertex(uint vertexID [[vertex_id]],
                                          constant float4* vertexData [[buffer(0)]]) {
    VertexOut out;

    // Each vertex has 4 floats: x, y, u, v
    float4 data = vertexData[vertexID];
    out.position = float4(data.xy, 0.0, 1.0);
    out.texCoord = data.zw;

    return out;
}

// Fragment shader for YCbCr to RGB conversion
// ARKit camera provides frames in YCbCr (420v/420f) format
fragment float4 stereoPassthroughFragment(VertexOut in [[stage_in]],
                                           texture2d<float> yTexture [[texture(0)]],
                                           texture2d<float> cbcrTexture [[texture(1)]],
                                           sampler textureSampler [[sampler(0)]]) {
    // Sample Y and CbCr textures
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;

    // YCbCr to RGB conversion (BT.601 standard used by iOS cameras)
    // Y is in range [0, 1], Cb and Cr are in range [0, 1] (centered at 0.5)
    float cb = cbcr.r - 0.5;
    float cr = cbcr.g - 0.5;

    float3 rgb;
    rgb.r = y + 1.402 * cr;
    rgb.g = y - 0.344136 * cb - 0.714136 * cr;
    rgb.b = y + 1.772 * cb;

    return float4(rgb, 1.0);
}

// Fragment shader for occlusion overlay
// Renders camera feed only where the segmentation mask indicates a person
fragment float4 stereoOcclusionFragment(VertexOut in [[stage_in]],
                                         texture2d<float> yTexture [[texture(0)]],
                                         texture2d<float> cbcrTexture [[texture(1)]],
                                         texture2d<float> segmentationTexture [[texture(2)]],
                                         sampler textureSampler [[sampler(0)]]) {
    // Sample segmentation mask (person = 1.0, background = 0.0)
    // The segmentation texture may have different dimensions, so we sample at the same UV
    float segmentation = segmentationTexture.sample(textureSampler, in.texCoord).r;
    
    // If no person detected at this pixel, make fully transparent
    if (segmentation < 0.5) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    
    // Sample Y and CbCr textures
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;

    // YCbCr to RGB conversion
    float cb = cbcr.r - 0.5;
    float cr = cbcr.g - 0.5;

    float3 rgb;
    rgb.r = y + 1.402 * cr;
    rgb.g = y - 0.344136 * cb - 0.714136 * cr;
    rgb.b = y + 1.772 * cb;

    // Return with full opacity where person is detected
    return float4(rgb, 1.0);
}
