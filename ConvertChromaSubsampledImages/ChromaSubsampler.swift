//
//  ConvertChromaSubsampler.swift
//  ConvertChromaSubsampledImages
//
//  Created by mark lim pak mun on 06/05/2024.
//  Copyright © 2024 Incremental Innovations. All rights reserved.
//

import AppKit
import Accelerate.vImage

class ChromaSubsampler
{

    private var rgbSourceBuffer = vImage_Buffer()

    // srcYpCbCr8PlanarBuffers is an array of vImage_Buffers objects.
    private var srcYpCbCr8PlanarBuffers: [vImage_Buffer]!
    private var dstYpCbCr8PlanarBuffers: [vImage_Buffer]!

    // bitmapInfo: RGB
    private var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: 8,
        bitsPerPixel: 8 * 3,
        colorSpace: nil,        // default to srgb colorspace
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent)

    // <RGB Base colorspace missing>
    // Return Unmanaged<vImageCVImageFormat>
    private var cvImageFormat = vImageCVImageFormat_Create(
        kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4,
        kCVImageBufferChromaLocation_Center,
        CGColorSpaceCreateDeviceRGB(),
        0).takeRetainedValue()

    init?(cgImage: CGImage)
    {
        var error = vImage_Error()
 
        guard error == vImage_Error(kvImageNoError)
        else {
            return nil
        }

        error = vImageBuffer_InitWithCGImage(
            &rgbSourceBuffer,
            &cgImageFormat,
            nil,
            cgImage,
            vImage_Flags(kvImageNoFlags))

        guard error == vImage_Error(kvImageNoError)
        else {
            return nil
        }

     }
    
    deinit {
        // We don't know the alignment which is usually 16 bytes
        rgbSourceBuffer.data.deallocate(bytes: rgbSourceBuffer.rowBytes * Int(rgbSourceBuffer.height),
                                        alignedTo: 1)
        let numberOfDestinationBuffers = srcYpCbCr8PlanarBuffers.count
        for i in 0..<numberOfDestinationBuffers {
            let rowBytes = srcYpCbCr8PlanarBuffers[i].rowBytes
            let height = srcYpCbCr8PlanarBuffers[i].height
            let size = rowBytes * Int(height)
            srcYpCbCr8PlanarBuffers[i].data.deallocate(bytes: size, alignedTo: 1)
            dstYpCbCr8PlanarBuffers[i].data.deallocate(bytes: size, alignedTo: 1)
        }
    }

    // Convert the RGB buffer to the color planes that make up the result image.
    func convert() -> Bool
    {
        let backGroundColor: [CGFloat] = [0.0, 0.0, 0.0, 0.0]

        var error = vImage_Error()

        // Create a vImageConverter object that can convert an instance of CGImage
        // to a CoreVideo formatted image.
        let unmanagedConverter = vImageConverter_CreateForCGToCVImageFormat(
            &cgImageFormat,
            cvImageFormat,
            backGroundColor,
            vImage_Flags(kvImagePrintDiagnosticsToConsole),
            &error)!
 
        // Converts an instance of CGImage to several vImage_Buffer objects.
        let cgToCvConverter = unmanagedConverter.takeUnretainedValue()

        defer {
            unmanagedConverter.release()
        }

        let numberOfDestinationBuffers = Int(vImageConverter_GetNumberOfDestinationBuffers(cgToCvConverter))

        srcYpCbCr8PlanarBuffers = [vImage_Buffer](repeating: vImage_Buffer(),
                                                  count: numberOfDestinationBuffers)
        dstYpCbCr8PlanarBuffers = [vImage_Buffer](repeating: vImage_Buffer(),
                                                  count: numberOfDestinationBuffers)

        // Allocate memory to the 3 source planar (vImage) buffers and
        // the 3 destination planar (vImage) buffers

        // srcYpCbCr8PlanarBuffers[0] is the vImage_Buffer of the luminance plane
        // srcYpCbCr8PlanarBuffers[1] is the vImage_Buffer of the Cb plane
        // srcYpCbCr8PlanarBuffers[2] is the vImage_Buffer of the Cr plane
        // Setting the widths and heights of Chrominance (Cb and Cr) planes to half those
        // of luminance (Yp) plane does not work. The widths and heights of the Cb and Cr
        // planes must be the same as those of the Yp plane.
        // The width and height of all planar buffers are the same as those of the RGB source buffer.
        for i in 0..<numberOfDestinationBuffers {
            var buffer = vImage_Buffer()

            error = vImageBuffer_Init(
                &buffer,
                vImagePixelCount(rgbSourceBuffer.height),
                vImagePixelCount(rgbSourceBuffer.width),
                8,          // # of bits per colour component
                vImage_Flags(kvImageNoFlags))

            srcYpCbCr8PlanarBuffers[i] = buffer
 
            // At the same time, we create 3 destination planes, two of which
            // will receive the results of the vImageMatrixMultiply_Planar8 operation.
            buffer = vImage_Buffer()
            error = vImageBuffer_Init(
                &buffer,
                vImagePixelCount(rgbSourceBuffer.height),
                vImagePixelCount(rgbSourceBuffer.width),
                8,          // # of bits per colour component
                vImage_Flags(kvImageNoFlags))
            dstYpCbCr8PlanarBuffers[i] = buffer
        }

        guard error == vImage_Error(kvImageNoError)
        else {
            return false
        }

        // Convert the RGB pixels in the RGB source vImage_Buffer to luma,
        // blue-difference and red-difference chroma components and store them
        // in 3 separate planes.
        error = vImageConvert_AnyToAny(
            cgToCvConverter,
            &rgbSourceBuffer,
            &srcYpCbCr8PlanarBuffers!,
            nil,
            vImage_Flags(kvImagePrintDiagnosticsToConsole))

        guard error == vImage_Error(kvImageNoError)
            else {
                return false
        }

        // Copy the pixel data from the source luma plane to the destination luma plane.
        // This step is necessary and is once only.
        // We could have executed the above call vImageConvert_AnyToAny with
        // dstYpCbCr8PlanarBuffers as the destination of the conversion
        let size = Int(srcYpCbCr8PlanarBuffers[0].height) * srcYpCbCr8PlanarBuffers[0].rowBytes
        memcpy(dstYpCbCr8PlanarBuffers[0].data,
               srcYpCbCr8PlanarBuffers[0].data,
               size)

        return true
    }

    // Desaturate/Saturate the chrominance sub-samples
    // Input: 0.0 - 1.0
    func applySaturation(_ saturation: Float)
    {
        var preBias: Int16 = -128
        let divisor: Int32 = 0x1000
        var postBias: Int32 = 128 * divisor

        // The saturation is passed to the matrix multiply function as a single-element matrix
        var matrix = [ Int16(saturation * Float(divisor)) ]

        // Note: the data in the 3 source planes as well as the luma destination plane
        // will not be modified.
        for index in [1, 2] {
 
            var source = srcYpCbCr8PlanarBuffers[index]
            var destination = dstYpCbCr8PlanarBuffers[index]

            _ = withUnsafePointer(to: &destination) {
                (dest: UnsafePointer<vImage_Buffer>) in
                withUnsafePointer(to: &source) {
                    (src: UnsafePointer<vImage_Buffer>) in

                    var sources: UnsafePointer<vImage_Buffer>? = src
                    var destinations: UnsafePointer<vImage_Buffer>? = dest

                    vImageMatrixMultiply_Planar8(&sources,
                                                 &destinations,
                                                 1,
                                                 1,
                                                 &matrix,
                                                 divisor,
                                                 &preBias,
                                                 &postBias,
                                                 vImage_Flags(kvImageNoFlags))
                }
            }
         } // for
    }

    // Create an instance of CGImage from the 3 destination planes
    func result() -> CGImage?
    {
        var error = vImage_Error()

        let backGroundColor: [CGFloat] = [0.0, 0.0, 0.0, 0.0]
        let unmanagedConverter = vImageConverter_CreateForCVToCGImageFormat(
            cvImageFormat,
            &cgImageFormat,
            backGroundColor,
            vImage_Flags(kvImagePrintDiagnosticsToConsole),
            &error)
 
        let cvToCGConverter = unmanagedConverter!.takeUnretainedValue()

        defer {
            unmanagedConverter!.release()
        }

        guard error == vImage_Error(kvImageNoError)
        else {
            return nil
        }

        let width = rgbSourceBuffer.width
        let height = rgbSourceBuffer.height
        let size = Int(rgbSourceBuffer.height) * rgbSourceBuffer.rowBytes

        let memoryPtr = UnsafeMutableRawPointer.allocate(bytes: size,
                                                         alignedTo: 1)
        defer {
            memoryPtr.deallocate(bytes: size, alignedTo: 1)
        }

        // Create a vImage_Buffer object that has the same height and width
        // as the RGB source vImage_Buffer object
        var rgbDestinationBuffer = vImage_Buffer(
            data: memoryPtr,
            height: height,
            width: width,
            rowBytes: rgbSourceBuffer.rowBytes)

        // Convert the YpCbCr pixels to RGB pixels.
        error = vImageConvert_AnyToAny(
            cvToCGConverter,
            &dstYpCbCr8PlanarBuffers!,
            &rgbDestinationBuffer,
            nil,
            vImage_Flags(kvImageNoFlags))

        guard error == vImage_Error(kvImageNoError)
        else {
            return nil
        }

        // Instantiate an instance of CGImage from vImage_Buffer object.
        let outputCGImage = vImageCreateCGImageFromBuffer(
            &rgbDestinationBuffer,
            &cgImageFormat,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &error).takeUnretainedValue()
 
        guard error == vImage_Error(kvImageNoError)
        else {
            return nil
        }
        return outputCGImage
    }
}
