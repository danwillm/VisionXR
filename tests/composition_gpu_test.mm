// Read back rendered pixels to validate the actual backend shader on macOS.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <cstdio>
#include <cstdlib>
#include <array>
#include "composition_shader.hpp"
#define CHECK(x) do { if (!(x)) { std::fprintf(stderr,"Failed at %d: %s\n",__LINE__,#x); std::abort(); } } while(0)
struct Uniforms { simd_float4x4 matrix; simd_float4 rect; uint32_t slice, flags; uint32_t padding[2]{}; };
int main() { @autoreleasepool {
    id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
    if (!gpu) { std::puts("No Metal device: skipped"); return 77; }
    NSError* error = nil;
    id<MTLLibrary> library = [gpu newLibraryWithSource:[NSString stringWithUTF8String:compositionShader] options:nil error:&error];
    if (!library) std::fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
    CHECK(library);
    id<MTLRenderPipelineState> pipelines[2];
    for (unsigned i = 0; i < 2; ++i) {
        auto desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"compositionVertex"];
        desc.fragmentFunction = [library newFunctionWithName:i ? @"compositionArray" : @"composition2D"];
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        auto color = desc.colorAttachments[0]; color.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        color.blendingEnabled = YES; color.sourceRGBBlendFactor = color.sourceAlphaBlendFactor = MTLBlendFactorOne;
        color.destinationRGBBlendFactor = color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelines[i] = [gpu newRenderPipelineStateWithDescriptor:desc error:&error]; CHECK(pipelines[i]);
    }
    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:4 height:4 mipmapped:NO];
    desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> atlas = [gpu newTextureWithDescriptor:desc];
    unsigned char pixels[64];
    for (unsigned y = 0; y < 4; ++y) for (unsigned x = 0; x < 4; ++x) {
        unsigned p = (y*4+x)*4; pixels[p] = 0; pixels[p+1] = x < 2 ? 0 : 255;
        pixels[p+2] = x < 2 ? 255 : 0; pixels[p+3] = 128;
    }
    [atlas replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    desc.textureType = MTLTextureType2DArray; desc.arrayLength = 2;
    id<MTLTexture> array = [gpu newTextureWithDescriptor:desc];
    for (unsigned p = 0; p < 64; p += 4) { pixels[p]=0; pixels[p+1]=255; pixels[p+2]=0; pixels[p+3]=255; }
    [array replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 slice:1 withBytes:pixels bytesPerRow:16 bytesPerImage:64];
    desc.textureType = MTLTextureType2D; desc.arrayLength = 1; desc.width = desc.height = 16;
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [gpu newTextureWithDescriptor:desc];
    auto depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:16 height:16 mipmapped:NO];
    depthDesc.storageMode = MTLStorageModePrivate; depthDesc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depth = [gpu newTextureWithDescriptor:depthDesc]; CHECK(depth);
    id<MTLBuffer> depthReadback = [gpu newBufferWithLength:16*256 options:MTLResourceStorageModeShared];
    auto depthStateDesc = [MTLDepthStencilDescriptor new];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways; depthStateDesc.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [gpu newDepthStencilStateWithDescriptor:depthStateDesc];
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    float lastDepth = -1;
    NSUInteger targetSlice = 0;
    auto render = [&](uint32_t flags, bool useArray, bool backface, bool overlay) {
        auto command = [queue commandBuffer]; auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.depthAttachment.texture = depth; pass.depthAttachment.slice = targetSlice;
        pass.depthAttachment.loadAction = MTLLoadActionClear; pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.depthAttachment.clearDepth = 0;
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].slice = targetSlice;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);
        auto encoder = [command renderCommandEncoderWithDescriptor:pass]; CHECK(encoder);
        [encoder setDepthStencilState:depthState];
        [encoder setFrontFacingWinding:MTLWindingCounterClockwise]; [encoder setCullMode:MTLCullModeBack];
        Uniforms u{}; u.matrix = matrix_identity_float4x4;
        u.matrix.columns[3].z = .25f;
        if (backface) { u.matrix.columns[0].x = -1; u.matrix.columns[2].z = -1; }
        u.rect = useArray ? simd_make_float4(0,0,1,1) : simd_make_float4(0,0,.5f,1);
        u.slice = 1; u.flags = flags;
        [encoder setRenderPipelineState:pipelines[useArray ? 1 : 0]];
        [encoder setVertexBytes:&u length:sizeof(u) atIndex:0]; [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [encoder setFragmentTexture:useArray ? array : atlas atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        if (overlay) {
            u.rect = {0,0,1,1}; u.flags = 0;
            u.matrix.columns[3].z = .125f; // A farther later layer still wins by submission order.
            [encoder setRenderPipelineState:pipelines[1]]; [encoder setFragmentTexture:array atIndex:0];
            [encoder setVertexBytes:&u length:sizeof(u) atIndex:0]; [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [encoder endEncoding];
        auto blit = [command blitCommandEncoder];
        [blit copyFromTexture:depth sourceSlice:targetSlice sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(16,16,1) toBuffer:depthReadback destinationOffset:0
            destinationBytesPerRow:256 destinationBytesPerImage:16*256];
        [blit endEncoding];
        [command commit]; [command waitUntilCompleted];
        lastDepth = *reinterpret_cast<float*>(static_cast<char*>(depthReadback.contents)+8*256+8*4);
        CHECK(command.status == MTLCommandBufferStatusCompleted);
        unsigned char output[4]; [target getBytes:output bytesPerRow:4 bytesPerImage:4 fromRegion:MTLRegionMake2D(8,8,1,1) mipmapLevel:0 slice:targetSlice];
        return std::array<unsigned char,4>{output[0],output[1],output[2],output[3]}; // BGRA
    };
    auto opaque = render(0,false,false,false); CHECK(opaque[0]==0 && opaque[1]==0 && opaque[2]==255); CHECK(lastDepth == .25f);
    auto straight = render(6,false,false,false); // Half-alpha red over blue, blended in linear colour.
    CHECK(straight[0]>=186 && straight[0]<=189 && straight[1]==0 && straight[2]>=186 && straight[2]<=189);
    // Store half-intensity linear red as sRGB 188, premultiplied by alpha 128.
    for (unsigned y = 0; y < 4; ++y) for (unsigned x = 0; x < 4; ++x) {
        unsigned p = (y*4+x)*4; pixels[p]=0; pixels[p+1]=0; pixels[p+2]=188; pixels[p+3]=128;
    }
    [atlas replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    auto premult = render(2,false,false,false);
    CHECK(premult[2]>=186 && premult[2]<=189 && premult[0]>=186 && premult[0]<=189);
    auto slice = render(0,true,false,false); CHECK(slice[0]==0 && slice[1]==255 && slice[2]==0);
    auto reversed = render(0,false,true,false); CHECK(reversed[0]==255 && reversed[1]==0 && reversed[2]==0); CHECK(lastDepth == 0);
    auto ordered = render(0,false,false,true); CHECK(ordered[0]==0 && ordered[1]==255 && ordered[2]==0); CHECK(lastDepth == .125f);
    // Verify top-left image orientation after sampling/rasterization.
    for (unsigned y = 0; y < 4; ++y) for (unsigned x = 0; x < 4; ++x) {
        unsigned p = (y*4+x)*4; pixels[p]= y<2 ? 0 : 255; pixels[p+1]=0;
        pixels[p+2]= y<2 ? 255 : 0; pixels[p+3]=255;
    }
    [atlas replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    render(0,false,false,false);
    unsigned char lower[4]; [target getBytes:lower bytesPerRow:4 fromRegion:MTLRegionMake2D(8,15,1,1) mipmapLevel:0];
    CHECK(lower[0]==255 && lower[2]==0);
    unsigned char top[4]; [target getBytes:top bytesPerRow:4 fromRegion:MTLRegionMake2D(8,0,1,1) mipmapLevel:0];
    CHECK(top[2]==255 && top[0]==0);
    // Zero-alpha pixels must not overwrite compositor colour or depth.
    for (unsigned p = 0; p < 64; p += 4) pixels[p+3] = 0;
    [atlas replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:pixels bytesPerRow:16];
    auto transparent = render(6,false,false,false);
    CHECK(transparent[0]==255 && transparent[1]==0 && transparent[2]==0 && lastDepth==0);
    // Exercise the headset's layered topology, writing colour and depth to
    // each eye slice separately with the same pipeline (no vertex amplification).
    desc.textureType = MTLTextureType2DArray; desc.arrayLength = 2;
    target = [gpu newTextureWithDescriptor:desc]; CHECK(target);
    depthDesc.textureType = MTLTextureType2DArray; depthDesc.arrayLength = 2;
    depth = [gpu newTextureWithDescriptor:depthDesc]; CHECK(depth);
    for (targetSlice = 0; targetSlice < 2; ++targetSlice) {
        auto eye = render(0,true,false,false);
        CHECK(eye[0]==0 && eye[1]==255 && eye[2]==0 && lastDepth==.25f);
    }
    std::puts("Metal composition: opaque/straight/premultiplied alpha, subrects, array slices, backface culling layer order, compositor depth and stereo slices: OK");
} }
